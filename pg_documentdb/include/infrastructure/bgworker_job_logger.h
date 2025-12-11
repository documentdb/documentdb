/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/infrastructure/bgworker_job_logger.h
 *
 * Utilities for background worker job execution logging.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BGWORKER_JOB_LOGGER_H
#define BGWORKER_JOB_LOGGER_H

#include <postgres.h>
#include <datatype/timestamp.h>
#include <sys/time.h>
#include <nodes/pg_list.h>

/* Telemetry event for background worker job execution. */
typedef struct BgWorkerJobExecutionEvent
{
	/* Timestamp for this event. */
	TimestampTz eventTime;

	/* Job ID that generated this event.*/
	int32_t jobId;

	/* Job execution instance ID (pointer value for uniqueness/logging) */
	uintptr_t instanceId;

	/* Job execution state. */
	int32_t state;

	/* (Optional) message. Mostly for debugging failures. */
	char *message;
} BgWorkerJobExecutionEvent;

/* Shared memory management */
Size BgWorkerJobLoggerShmemSize(void);
void InitializeBgWorkerJobLoggerShmem(void);

/* Event logging API */
void RecordBgWorkerEvent(BgWorkerJobExecutionEvent event);
List * GetBgWorkerJobExecutionMetricData(void);

/* Helper/utils */
int GetBgWorkerRegisteredJobsCount(void);

#endif
