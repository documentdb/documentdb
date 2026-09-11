/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * include/background_worker/background_worker_private.h
 *
 * Private declarations for the background worker implementation.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_BACKGROUND_WORKER_PRIVATE_H
#define DOCUMENTDB_BACKGROUND_WORKER_PRIVATE_H

#include <postgres.h>
#include <utils/timestamp.h>

#include "background_worker/background_worker_job.h"

#define MAX_BACKGROUND_WORKER_JOBS 5

typedef enum
{
	/* A terminal command result reported failure. */
	JOB_RESULT_FAILED = 0,

	/* Every terminal command result reported success. */
	JOB_RESULT_SUCCEEDED = 1,

	/* The configured execution timeout elapsed before completion. */
	JOB_RESULT_TIMED_OUT = 2,

	/* Connection loss prevented authoritative result classification. */
	JOB_RESULT_UNOBSERVED = 3,
} BackgroundWorkerJobResult;

typedef struct BackgroundWorkerJobStats
{
	/* Registered background worker job identity. */
	int jobId;

	/* Start time of the first completed attempt in the current epoch. */
	TimestampTz firstAttemptTimestamp;

	/* Start time of the most recently completed attempt. */
	TimestampTz lastAttemptTimestamp;

	/* Completion time of the most recent terminal attempt. */
	TimestampTz lastCompletionTimestamp;

	/* Completion time of the most recent successful attempt. */
	TimestampTz lastSuccessTimestamp;

	/* Completion time of the most recent failed or timed-out attempt. */
	TimestampTz lastFailureTimestamp;

	/* Terminal result of the most recently completed attempt. */
	BackgroundWorkerJobResult lastResult;

	/* Number of completed successful attempts. */
	uint64 successfulExecutions;

	/* Number of completed failed attempts, excluding timeouts. */
	uint64 failedExecutions;

	/* Number of attempts terminated by the framework timeout. */
	uint64 timedOutExecutions;

	/* Number of failures or timeouts since the most recent success. */
	uint64 consecutiveFailures;

	/* Duration of the most recently completed attempt. */
	double lastExecutionTimeMilliseconds;

	/* Sum of completed-attempt durations. */
	double totalExecutionTimeMilliseconds;

	/* Minimum completed-attempt duration. */
	double minExecutionTimeMilliseconds;

	/* Maximum completed-attempt duration. */
	double maxExecutionTimeMilliseconds;
} BackgroundWorkerJobStats;

typedef struct BackgroundWorkerJobStatsSnapshot
{
	/* Time at which the current statistics epoch was established. */
	TimestampTz statsResetTimestamp;

	/* Number of initialized entries in jobs. */
	int jobCount;

	/* Fixed-capacity cumulative statistics entries. */
	BackgroundWorkerJobStats jobs[MAX_BACKGROUND_WORKER_JOBS];
} BackgroundWorkerJobStatsSnapshot;

Size BackgroundWorkerJobStatsShmemSize(void);
void InitializeBackgroundWorkerJobStatsShmem(void);
void RegisterBackgroundWorkerJobStats(int jobId);
void GetBackgroundWorkerJobStatsSnapshot(BackgroundWorkerJobStatsSnapshot *snapshot);

#endif
