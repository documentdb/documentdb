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
#include <miscadmin.h>
#include <storage/lwlock.h>
#include <storage/shmem.h>
#include <utils/timestamp.h>

#include "background_worker/background_worker_private.h"

typedef struct BackgroundWorkerJobStatsSharedState
{
	int lockTrancheId;
	LWLock lock;
	BackgroundWorkerJobStatsSnapshot snapshot;
} BackgroundWorkerJobStatsSharedState;

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
