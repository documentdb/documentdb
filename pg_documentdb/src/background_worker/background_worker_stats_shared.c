/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * src/background_worker/background_worker_stats_shared.c
 *
 * Shared-memory storage for cumulative background worker statistics.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <math.h>
#include <miscadmin.h>
#include <storage/lwlock.h>
#include <storage/shmem.h>
#include <utils/timestamp.h>

#include "background_worker/background_worker_private.h"

#define MICROSECONDS_PER_MILLISECOND 1000

typedef struct BackgroundWorkerJobStatsSharedState
{
	int lockTrancheId;
	LWLock lock;
	BackgroundWorkerJobStatsSnapshot snapshot;
} BackgroundWorkerJobStatsSharedState;

static bool TryGetExecutionAttempts(const BackgroundWorkerJobStats *jobStats,
									uint64 *executionAttempts);
static BackgroundWorkerJobStatsSharedState *SharedState = NULL;
static int RegisteredJobIds[MAX_BACKGROUND_WORKER_JOBS];
static int RegisteredJobCount = 0;
static const char *BackgroundWorkerStatsLockTrancheName =
	"DocumentDB Background Worker Statistics";


Size
BackgroundWorkerJobStatsShmemSize(void)
{
	return MAXALIGN(sizeof(BackgroundWorkerJobStatsSharedState));
}


void
InitializeBackgroundWorkerJobStatsShmem(void)
{
	bool found = false;

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
	SharedState = (BackgroundWorkerJobStatsSharedState *) ShmemInitStruct(
		"DocumentDB Background Worker Statistics",
		BackgroundWorkerJobStatsShmemSize(),
		&found);

	/*
	 * PostgreSQL completes shared-preload initialization before invoking
	 * shared-memory startup hooks. EXEC_BACKEND children replay the same
	 * preload initialization before attaching to existing shared memory.
	 * Job registration is therefore complete and deterministic here.
	 */
	if (!found)
	{
		MemSet(SharedState, 0, BackgroundWorkerJobStatsShmemSize());
#if PG_VERSION_NUM >= 190000
		SharedState->lockTrancheId = LWLockNewTrancheId(
			BackgroundWorkerStatsLockTrancheName);
#else
		SharedState->lockTrancheId = LWLockNewTrancheId();
#endif
	}

#if PG_VERSION_NUM < 190000

	/*
	 * Tranche names were process-local, so EXEC_BACKEND children must
	 * register the postmaster-allocated ID after attaching.
	 */
	LWLockRegisterTranche(SharedState->lockTrancheId,
						  BackgroundWorkerStatsLockTrancheName);
#endif

	if (!found)
	{
		LWLockInitialize(&SharedState->lock, SharedState->lockTrancheId);

		SharedState->snapshot.statsResetTimestamp = GetCurrentTimestamp();
		SharedState->snapshot.jobCount = RegisteredJobCount;
		for (int i = 0; i < RegisteredJobCount; i++)
		{
			SharedState->snapshot.jobs[i].jobId = RegisteredJobIds[i];
		}
	}
	else
	{
		Assert(SharedState->snapshot.jobCount == RegisteredJobCount);
		for (int i = 0; i < RegisteredJobCount; i++)
		{
			Assert(SharedState->snapshot.jobs[i].jobId == RegisteredJobIds[i]);
		}
	}

	LWLockRelease(AddinShmemInitLock);
}


void
RegisterBackgroundWorkerJobStats(int jobId)
{
	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"Registering background worker statistics must happen during shared_preload_libraries")));
	}

	if (RegisteredJobCount >= MAX_BACKGROUND_WORKER_JOBS)
	{
		ereport(ERROR,
				(errmsg("Only %d background worker statistics entries are permitted",
						MAX_BACKGROUND_WORKER_JOBS)));
	}

	for (int i = 0; i < RegisteredJobCount; i++)
	{
		if (RegisteredJobIds[i] == jobId)
		{
			ereport(ERROR,
					(errmsg("Background worker job id %d is already registered",
							jobId)));
		}
	}

	RegisteredJobIds[RegisteredJobCount++] = jobId;
}


/*
 * GetBackgroundWorkerJobStatsSnapshot copies one coherent shared snapshot
 * into caller-owned memory. It is intended for statistics readers, including
 * the cumulative SQL accessor, so validation and row materialization happen
 * after the shared lock has been released.
 */
void
GetBackgroundWorkerJobStatsSnapshot(BackgroundWorkerJobStatsSnapshot *snapshot)
{
	Assert(snapshot != NULL);
	Assert(SharedState != NULL);

	LWLockAcquire(&SharedState->lock, LW_SHARED);
	memcpy(snapshot, &SharedState->snapshot, sizeof(*snapshot));
	LWLockRelease(&SharedState->lock);

	Assert(snapshot->jobCount >= 0);
	Assert(snapshot->jobCount <= MAX_BACKGROUND_WORKER_JOBS);
}


/*
 * FindBackgroundWorkerJobStatsIndex returns the matching snapshot index, or -1.
 * Callers are responsible for synchronizing access to a live shared snapshot.
 */
int
FindBackgroundWorkerJobStatsIndex(int jobId,
								  const BackgroundWorkerJobStatsSnapshot *snapshot)
{
	Assert(snapshot != NULL);
	Assert(snapshot->jobCount >= 0);
	Assert(snapshot->jobCount <= MAX_BACKGROUND_WORKER_JOBS);

	for (int i = 0; i < snapshot->jobCount; i++)
	{
		if (snapshot->jobs[i].jobId == jobId)
		{
			return i;
		}
	}

	return -1;
}


void
PublishBackgroundWorkerJobCompletion(int jobId, BackgroundWorkerJobResult result,
									 TimestampTz attemptStartTimestamp,
									 instr_time attemptStartTime,
									 bool hasAttemptObservationInterval,
									 int64 attemptObservationIntervalMilliseconds)
{
	if (result != JOB_RESULT_SUCCEEDED &&
		result != JOB_RESULT_FAILED &&
		result != JOB_RESULT_TIMED_OUT &&
		result != JOB_RESULT_UNOBSERVED)
	{
		ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						errmsg("Background worker statistics result is invalid")));
	}

	if (hasAttemptObservationInterval && attemptObservationIntervalMilliseconds < 0)
	{
		ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						errmsg(
							"Background worker attempt observation interval must be nonnegative")));
	}

	Assert(SharedState != NULL);

	/*
	 * Reset and publication linearize on this lock. Capture terminal clocks
	 * only after publication has entered its reset epoch.
	 */
	LWLockAcquire(&SharedState->lock, LW_EXCLUSIVE);

	instr_time observedAttemptDuration;
	INSTR_TIME_SET_CURRENT(observedAttemptDuration);
	INSTR_TIME_SUBTRACT(observedAttemptDuration, attemptStartTime);
	double observedAttemptDurationMilliseconds =
		INSTR_TIME_GET_MILLISEC(observedAttemptDuration);
	TimestampTz observedResolutionTimestamp = GetCurrentTimestamp();

	if (!isfinite(observedAttemptDurationMilliseconds) ||
		observedAttemptDurationMilliseconds < 0)
	{
		LWLockRelease(&SharedState->lock);
		ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						errmsg(
							"Background worker observed attempt duration must be finite and nonnegative")));
	}

	Assert(SharedState->snapshot.jobCount >= 0);
	Assert(SharedState->snapshot.jobCount <= MAX_BACKGROUND_WORKER_JOBS);

	int jobStatsIndex = FindBackgroundWorkerJobStatsIndex(jobId, &SharedState->snapshot);
	if (jobStatsIndex < 0)
	{
		LWLockRelease(&SharedState->lock);
		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT),
						errmsg("Background worker job id %d is not registered", jobId)));
	}

	BackgroundWorkerJobStats *jobStats = &SharedState->snapshot.jobs[jobStatsIndex];
	BackgroundWorkerJobStats updatedStats = *jobStats;
	uint64 executionAttempts = 0;
	if (!TryGetExecutionAttempts(&updatedStats, &executionAttempts))
	{
		LWLockRelease(&SharedState->lock);
		ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
						errmsg("Background worker statistics counter exceeds bigint")));
	}

	if (executionAttempts == PG_INT64_MAX)
	{
		LWLockRelease(&SharedState->lock);
		ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
						errmsg(
							"Background worker execution attempt count exceeds bigint")));
	}

	switch (result)
	{
		case JOB_RESULT_SUCCEEDED:
		{
			if (updatedStats.successfulExecutions == PG_INT64_MAX)
			{
				LWLockRelease(&SharedState->lock);
				ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
								errmsg(
									"Background worker successful execution count exceeds bigint")));
			}

			updatedStats.successfulExecutions++;
			updatedStats.consecutiveFailures = 0;
			updatedStats.lastSuccessTimestamp = observedResolutionTimestamp;
			break;
		}

		case JOB_RESULT_FAILED:
		{
			if (updatedStats.failedExecutions == PG_INT64_MAX ||
				updatedStats.consecutiveFailures == PG_INT64_MAX)
			{
				LWLockRelease(&SharedState->lock);
				ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
								errmsg(
									"Background worker failure count exceeds bigint")));
			}

			updatedStats.failedExecutions++;
			updatedStats.consecutiveFailures++;
			updatedStats.lastFailureTimestamp = observedResolutionTimestamp;
			break;
		}

		case JOB_RESULT_TIMED_OUT:
		{
			if (updatedStats.timedOutExecutions == PG_INT64_MAX ||
				updatedStats.consecutiveFailures == PG_INT64_MAX)
			{
				LWLockRelease(&SharedState->lock);
				ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
								errmsg(
									"Background worker timeout count exceeds bigint")));
			}

			updatedStats.timedOutExecutions++;
			updatedStats.consecutiveFailures++;
			updatedStats.lastFailureTimestamp = observedResolutionTimestamp;
			break;
		}

		case JOB_RESULT_UNOBSERVED:
		{
			if (updatedStats.unobservedExecutions == PG_INT64_MAX)
			{
				LWLockRelease(&SharedState->lock);
				ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
								errmsg(
									"Background worker unobserved execution count exceeds bigint")));
			}

			updatedStats.unobservedExecutions++;
			break;
		}

		default:
		{
			pg_unreachable();
		}
	}

	double totalObservedAttemptDurationMilliseconds =
		updatedStats.totalObservedAttemptDurationMilliseconds +
		observedAttemptDurationMilliseconds;
	if (!isfinite(totalObservedAttemptDurationMilliseconds))
	{
		LWLockRelease(&SharedState->lock);
		ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
						errmsg(
							"Background worker total observed attempt duration exceeds double precision")));
	}

	if (executionAttempts == 0)
	{
		updatedStats.firstAttemptTimestamp = attemptStartTimestamp;
		updatedStats.minObservedAttemptDurationMilliseconds =
			observedAttemptDurationMilliseconds;
		updatedStats.maxObservedAttemptDurationMilliseconds =
			observedAttemptDurationMilliseconds;
	}
	else
	{
		updatedStats.minObservedAttemptDurationMilliseconds =
			Min(updatedStats.minObservedAttemptDurationMilliseconds,
				observedAttemptDurationMilliseconds);
		updatedStats.maxObservedAttemptDurationMilliseconds =
			Max(updatedStats.maxObservedAttemptDurationMilliseconds,
				observedAttemptDurationMilliseconds);
	}

	updatedStats.lastAttemptTimestamp = attemptStartTimestamp;
	updatedStats.lastObservedResolutionTimestamp = observedResolutionTimestamp;
	updatedStats.lastResult = result;
	updatedStats.lastObservedAttemptDurationMilliseconds =
		observedAttemptDurationMilliseconds;
	updatedStats.totalObservedAttemptDurationMilliseconds =
		totalObservedAttemptDurationMilliseconds;
	updatedStats.hasAttemptObservationInterval = hasAttemptObservationInterval;
	updatedStats.attemptObservationIntervalMilliseconds =
		attemptObservationIntervalMilliseconds;

	*jobStats = updatedStats;

	LWLockRelease(&SharedState->lock);
}


void
ResetBackgroundWorkerJobStats(void)
{
	Assert(SharedState != NULL);

	LWLockAcquire(&SharedState->lock, LW_EXCLUSIVE);

	Assert(SharedState->snapshot.jobCount >= 0);
	Assert(SharedState->snapshot.jobCount <= MAX_BACKGROUND_WORKER_JOBS);

	TimestampTz resetTimestamp = GetCurrentTimestamp();
	TimestampTz previousResetTimestamp = SharedState->snapshot.statsResetTimestamp;
	if (previousResetTimestamp > PG_INT64_MAX - MICROSECONDS_PER_MILLISECOND)
	{
		LWLockRelease(&SharedState->lock);
		ereport(ERROR, (errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
						errmsg(
							"Background worker statistics reset timestamp overflow")));
	}

	TimestampTz minimumResetTimestamp =
		previousResetTimestamp + MICROSECONDS_PER_MILLISECOND;
	if (resetTimestamp < minimumResetTimestamp)
	{
		/*
		 * The statistics surface publishes BSON dates at millisecond precision.
		 * Advance by one visible unit so rapid resets establish distinct epochs.
		 */
		resetTimestamp = minimumResetTimestamp;
	}

	for (int i = 0; i < SharedState->snapshot.jobCount; i++)
	{
		int jobId = SharedState->snapshot.jobs[i].jobId;
		MemSet(&SharedState->snapshot.jobs[i], 0, sizeof(BackgroundWorkerJobStats));
		SharedState->snapshot.jobs[i].jobId = jobId;
	}
	SharedState->snapshot.statsResetTimestamp = resetTimestamp;

	LWLockRelease(&SharedState->lock);
}


static bool
TryGetExecutionAttempts(const BackgroundWorkerJobStats *jobStats,
						uint64 *executionAttempts)
{
	if (jobStats->successfulExecutions > PG_INT64_MAX ||
		jobStats->failedExecutions > PG_INT64_MAX ||
		jobStats->timedOutExecutions > PG_INT64_MAX ||
		jobStats->unobservedExecutions > PG_INT64_MAX)
	{
		return false;
	}

	uint64 attempts = jobStats->successfulExecutions;
	if (jobStats->failedExecutions > PG_INT64_MAX - attempts)
	{
		return false;
	}
	attempts += jobStats->failedExecutions;

	if (jobStats->timedOutExecutions > PG_INT64_MAX - attempts)
	{
		return false;
	}
	attempts += jobStats->timedOutExecutions;

	if (jobStats->unobservedExecutions > PG_INT64_MAX - attempts)
	{
		return false;
	}
	attempts += jobStats->unobservedExecutions;

	*executionAttempts = attempts;
	return true;
}
