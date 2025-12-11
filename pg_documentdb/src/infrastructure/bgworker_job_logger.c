/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/oss/infrastructure/bgworker_job_logger.c
 *
 * Utilities to log background worker job execution events.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <storage/lwlock.h>
#include <storage/shmem.h>

#include "infrastructure/bgworker_job_logger.h"
#include "io/bson_core.h"
#include "utils/list_utils.h"

static pgbson * BuildBgWorkerJobExecutionMetricLog(BgWorkerJobExecutionEvent
												   event);

/*
 * 1 job execution -> 7 events per execution cycle.
 * 5 jobs max -> 35 events per cycle.
 * Job execution frequency -> at most every second.
 * So, 1 minute of events -> 35 * 60 = 2100 events
 * We will store ~5 minutes of events.
 * Have a buffer of 16384 events to be safe.
 */
#define MAX_BGWORKER_JOB_EXECUTION_EVENTS 16384

#define MAX_METRICS_EVENT_MESSAGE_LENGTH 512

/*
 * Shared telemetry store for the background worker job execution events.
 */
typedef struct BgWorkerSharedTelemetryStore
{
	int sharedTelemetryStoreTrancheId;
	char *sharedTelemetryStoreTrancheName;

	LWLock sharedTelemetryStoreLock;

	/* circular buffer holding background worker job execution telemetry. */
	BgWorkerJobExecutionEvent events[MAX_BGWORKER_JOB_EXECUTION_EVENTS];

	/* We use the classic producer/consumer pointers to manage the circular buffer. */
	uint16_t writeIndex;
	uint16_t readIndex;
} BgWorkerSharedTelemetryStore;

static BgWorkerSharedTelemetryStore *SharedTelemetryStore = NULL;


Size
BgWorkerJobLoggerShmemSize(void)
{
	return MAXALIGN(sizeof(BgWorkerSharedTelemetryStore));
}


void
InitializeBgWorkerJobLoggerShmem(void)
{
	bool found = false;

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
	SharedTelemetryStore = (BgWorkerSharedTelemetryStore *) ShmemInitStruct(
		"DocumentDB BgWorker Job Telemetry Store",
		BgWorkerJobLoggerShmemSize(),
		&found);

	if (!found)
	{
		/* First time through, so initialize */
		MemSet(SharedTelemetryStore, 0, BgWorkerJobLoggerShmemSize());

		SharedTelemetryStore->sharedTelemetryStoreTrancheId = LWLockNewTrancheId();
		SharedTelemetryStore->sharedTelemetryStoreTrancheName =
			"BgWorkerJobLoggerTranche";
		LWLockRegisterTranche(SharedTelemetryStore->sharedTelemetryStoreTrancheId,
							  SharedTelemetryStore->sharedTelemetryStoreTrancheName);

		SharedTelemetryStore->writeIndex = 0;
		SharedTelemetryStore->readIndex = 0;
		LWLockInitialize(&SharedTelemetryStore->sharedTelemetryStoreLock,
						 SharedTelemetryStore->sharedTelemetryStoreTrancheId);
	}

	LWLockRelease(AddinShmemInitLock);
	Assert(SharedTelemetryStore->sharedTelemetryStoreTrancheId != 0);
}


/*
 * Record a background worker job execution event in shared memory.
 * In the (unlikely) case of a buffer overrun, the oldest event is overwritten.
 */
void
RecordBgWorkerEvent(BgWorkerJobExecutionEvent event)
{
	if (SharedTelemetryStore == NULL)
	{
		/* Shared memory not initialized yet. */
		return;
	}

	LWLockAcquire(&SharedTelemetryStore->sharedTelemetryStoreLock, LW_EXCLUSIVE);

	uint16_t nextWriteIndex = (SharedTelemetryStore->writeIndex + 1) %
							  MAX_BGWORKER_JOB_EXECUTION_EVENTS;
	if (nextWriteIndex == SharedTelemetryStore->readIndex)
	{
		/* Buffer full, overwrite the oldest event by advancing readIndex */
		SharedTelemetryStore->readIndex = (SharedTelemetryStore->readIndex + 1) %
										  MAX_BGWORKER_JOB_EXECUTION_EVENTS;
	}

	SharedTelemetryStore->events[SharedTelemetryStore->writeIndex] = event;
	SharedTelemetryStore->writeIndex = nextWriteIndex;

	LWLockRelease(&SharedTelemetryStore->sharedTelemetryStoreLock);
}


/*
 * Get the background worker job execution metrics from shared memory for metrics emission.
 * Consumes events up to the current write index.
 * XXX This function takes an exclusive lock on the shared telemetry store, yielding only
 * after the event is serialized into a pgbson. This is deliberate -- without this we will
 * need to create a copy of the event struct to avoid use-after-free issues.
 */
List *
GetBgWorkerJobExecutionMetricData(void)
{
	List *eventList = NIL;
	if (SharedTelemetryStore == NULL)
	{
		/* Shared memory not initialized yet. */
		return eventList;
	}

	pg_memory_barrier();
	LWLockAcquire(&SharedTelemetryStore->sharedTelemetryStoreLock, LW_EXCLUSIVE);

	uint16_t readIndex = SharedTelemetryStore->readIndex;
	uint16_t writeIndex = SharedTelemetryStore->writeIndex;

	while (readIndex != writeIndex)
	{
		BgWorkerJobExecutionEvent event = SharedTelemetryStore->events[readIndex];
		pgbson *bgWorkerMetricLog = BuildBgWorkerJobExecutionMetricLog(event);
		eventList = lappend(eventList, bgWorkerMetricLog);
		readIndex = (readIndex + 1) % MAX_BGWORKER_JOB_EXECUTION_EVENTS;
	}

	/* Advance the shared readIndex to mark all events as consumed */
	SharedTelemetryStore->readIndex = readIndex;

	LWLockRelease(&SharedTelemetryStore->sharedTelemetryStoreLock);
	return eventList;
}


/*
 * Convert a BackgroundWorkerJobExecutionEvent to a pgbson for logging.
 */
static pgbson *
BuildBgWorkerJobExecutionMetricLog(BgWorkerJobExecutionEvent event)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	PgbsonWriterAppendDateTime(&writer, "eventTime", -1, event.eventTime);
	PgbsonWriterAppendInt32(&writer, "jobId", -1, event.jobId);
	PgbsonWriterAppendInt32(&writer, "instanceId", -1, event.instanceId);
	PgbsonWriterAppendInt32(&writer, "state", -1, event.state);
	if (event.message != NULL)
	{
		char msgBuffer[MAX_METRICS_EVENT_MESSAGE_LENGTH];
		strncpy(msgBuffer, event.message, sizeof(msgBuffer) - 1);
		msgBuffer[sizeof(msgBuffer) - 1] = '\0';
		PgbsonWriterAppendUtf8(&writer, "message", -1, msgBuffer);
	}

	pgbson *bgWorkerMetricsLog = PgbsonWriterGetPgbson(&writer);
	return bgWorkerMetricsLog;
}
