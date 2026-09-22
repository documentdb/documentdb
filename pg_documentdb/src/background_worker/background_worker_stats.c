/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/background_worker/background_worker_stats.c
 *
 * Statistics surfaces for registered background worker jobs. The registry
 * accessor reads the querying backend's fork-inherited copy, while the
 * cumulative accessor reads one coherent snapshot from shared memory.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <fmgr.h>
#include <funcapi.h>
#include <nodes/execnodes.h>
#include <executor/executor.h>
#include <utils/builtins.h>
#include <utils/tuplestore.h>

#include "background_worker/background_worker_job.h"
#include "background_worker/background_worker_private.h"
#include "io/bson_core.h"

#define BGWORKER_JOB_REGISTRY_COLUMNS 7
#define BGWORKER_JOB_STATS_COLUMNS 2

/*
 * Fallback schedule interval reported when a job's schedule hook throws.
 * Mirrors the registry's execution default (GetDefaultScheduleIntervalInSeconds).
 */
#define DEFAULT_SCHEDULE_INTERVAL_SECONDS 60

static Tuplestorestate * SetupBgworkerStatsTuplestore(FunctionCallInfo fcinfo,
													  TupleDesc *tupleDescriptor,
													  int expectedColumnCount,
													  const char *resultName);
static void StoreAllBgworkerJobRegistryRows(Tuplestorestate *tupleStore,
											TupleDesc tupleDescriptor);
static void StoreAllBgworkerJobStatsRows(Tuplestorestate *tupleStore,
										 TupleDesc tupleDescriptor);
static int64 GetExecutionAttempts(const BackgroundWorkerJobStats *jobStats);
static const char * JobResultName(BackgroundWorkerJobResult result);
static pgbson * BuildJobStatistics(const BackgroundWorkerJobStats *jobStats,
								   TimestampTz statsResetTimestamp);
static bool ResolveJobEnabled(const BackgroundWorkerJob *job);
static int ResolveJobScheduleIntervalSeconds(const BackgroundWorkerJob *job);
static pgbson * BuildJobOptions(const BackgroundWorkerJob *job);
static const char * RoleExecutionProfileName(BackgroundWorkerJobRoleExecutionProfile
											 roleExecutionProfile);

PG_FUNCTION_INFO_V1(bgworker_job_registry);
PG_FUNCTION_INFO_V1(bgworker_job_stats);
PG_FUNCTION_INFO_V1(documentdb_stat_reset_shared);


/*
 * bgworker_job_registry returns one row per registered background worker job. The
 * static columns are read directly from the registry; schedule_interval_seconds
 * and enabled are resolved from the job's hooks at query time.
 */
Datum
bgworker_job_registry(PG_FUNCTION_ARGS)
{
	TupleDesc tupleDescriptor = NULL;
	Tuplestorestate *tupleStore = SetupBgworkerStatsTuplestore(
		fcinfo, &tupleDescriptor, BGWORKER_JOB_REGISTRY_COLUMNS,
		"background worker job registry");

	StoreAllBgworkerJobRegistryRows(tupleStore, tupleDescriptor);

	PG_RETURN_VOID();
}


/*
 * bgworker_job_stats returns one row per registered background worker job. All
 * rows are serialized from one coherent shared-memory snapshot of cumulative
 * terminal-attempt statistics in the current reset epoch.
 */
Datum
bgworker_job_stats(PG_FUNCTION_ARGS)
{
	TupleDesc tupleDescriptor = NULL;
	Tuplestorestate *tupleStore = SetupBgworkerStatsTuplestore(
		fcinfo, &tupleDescriptor, BGWORKER_JOB_STATS_COLUMNS,
		"background worker job statistics");

	StoreAllBgworkerJobStatsRows(tupleStore, tupleDescriptor);

	PG_RETURN_VOID();
}


/*
 * documentdb_stat_reset_shared validates and resets the requested shared
 * statistics subsystem.
 */
Datum
documentdb_stat_reset_shared(PG_FUNCTION_ARGS)
{
	char *target = PG_ARGISNULL(0) ? NULL : text_to_cstring(PG_GETARG_TEXT_PP(0));

	if (target == NULL || strcmp(target, "bgworker") != 0)
	{
		const char *targetName = target == NULL ? "<NULL>" : target;

		ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						errmsg("unrecognized reset target: \"%s\"", targetName),
						errdetail_log("Target must be \"bgworker\".")));
	}

	ResetBackgroundWorkerJobStats();

	PG_RETURN_VOID();
}


/*
 * StoreAllBgworkerJobRegistryRows walks the registered jobs and appends one row
 * per job to the tuplestore.
 */
static void
StoreAllBgworkerJobRegistryRows(Tuplestorestate *tupleStore, TupleDesc tupleDescriptor)
{
	int jobCount = GetBackgroundWorkerJobCount();

	for (int i = 0; i < jobCount; i++)
	{
		const BackgroundWorkerJob *job = GetBackgroundWorkerJob(i);
		if (job == NULL)
		{
			continue;
		}

		Datum values[BGWORKER_JOB_REGISTRY_COLUMNS] = { 0 };
		bool nulls[BGWORKER_JOB_REGISTRY_COLUMNS] = { 0 };

		char *command = quote_qualified_identifier(job->command.schema,
												   job->command.name);

		values[0] = Int32GetDatum(job->jobId);
		values[1] = CStringGetTextDatum(job->jobName);
		values[2] = CStringGetTextDatum(command);
		values[3] = Int32GetDatum(ResolveJobScheduleIntervalSeconds(job));
		values[4] = Int32GetDatum(job->timeoutInSeconds);
		values[5] = BoolGetDatum(ResolveJobEnabled(job));
		values[6] = PointerGetDatum(BuildJobOptions(job));

		tuplestore_putvalues(tupleStore, tupleDescriptor, values, nulls);
	}
}


/*
 * StoreAllBgworkerJobStatsRows copies one coherent shared snapshot and appends
 * one cumulative row per registered job.
 */
static void
StoreAllBgworkerJobStatsRows(Tuplestorestate *tupleStore, TupleDesc tupleDescriptor)
{
	BackgroundWorkerJobStatsSnapshot snapshot = { 0 };
	GetBackgroundWorkerJobStatsSnapshot(&snapshot);

	int jobCount = GetBackgroundWorkerJobCount();
	if (snapshot.jobCount != jobCount)
	{
		ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
						errmsg(
							"Background worker statistics row count does not match the job registry")));
	}

	for (int i = 0; i < jobCount; i++)
	{
		const BackgroundWorkerJob *job = GetBackgroundWorkerJob(i);
		if (job == NULL)
		{
			ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
							errmsg("Background worker job registry entry %d is invalid",
								   i)));
		}

		int jobStatsIndex = FindBackgroundWorkerJobStatsIndex(job->jobId, &snapshot);
		if (jobStatsIndex < 0)
		{
			ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
							errmsg(
								"Background worker statistics entry for job id %d is missing",
								job->jobId)));
		}

		const BackgroundWorkerJobStats *jobStats = &snapshot.jobs[jobStatsIndex];
		Datum values[BGWORKER_JOB_STATS_COLUMNS] = { 0 };
		bool nulls[BGWORKER_JOB_STATS_COLUMNS] = { 0 };

		values[0] = Int32GetDatum(jobStats->jobId);
		values[1] = PointerGetDatum(BuildJobStatistics(jobStats,
													   snapshot.statsResetTimestamp));

		tuplestore_putvalues(tupleStore, tupleDescriptor, values, nulls);
	}
}


static int64
GetExecutionAttempts(const BackgroundWorkerJobStats *jobStats)
{
	if (jobStats->successfulExecutions > PG_INT64_MAX ||
		jobStats->failedExecutions > PG_INT64_MAX ||
		jobStats->timedOutExecutions > PG_INT64_MAX ||
		jobStats->unobservedExecutions > PG_INT64_MAX)
	{
		ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
						errmsg("Background worker statistics counter exceeds bigint")));
	}

	uint64 executionAttempts = jobStats->successfulExecutions;
	if (jobStats->failedExecutions > PG_INT64_MAX - executionAttempts)
	{
		ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
						errmsg(
							"Background worker execution attempt count exceeds bigint")));
	}
	executionAttempts += jobStats->failedExecutions;

	if (jobStats->timedOutExecutions > PG_INT64_MAX - executionAttempts)
	{
		ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
						errmsg(
							"Background worker execution attempt count exceeds bigint")));
	}
	executionAttempts += jobStats->timedOutExecutions;

	if (jobStats->unobservedExecutions > PG_INT64_MAX - executionAttempts)
	{
		ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
						errmsg(
							"Background worker execution attempt count exceeds bigint")));
	}
	executionAttempts += jobStats->unobservedExecutions;

	return (int64) executionAttempts;
}


static const char *
JobResultName(BackgroundWorkerJobResult result)
{
	switch (result)
	{
		case JOB_RESULT_SUCCEEDED:
		{
			return "succeeded";
		}

		case JOB_RESULT_FAILED:
		{
			return "failed";
		}

		case JOB_RESULT_TIMED_OUT:
		{
			return "timed_out";
		}

		case JOB_RESULT_UNOBSERVED:
		{
			return "unobserved";
		}

		default:
		{
			ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
							errmsg("Background worker statistics result is invalid")));
		}
	}
}


/*
 * BuildJobStatistics serializes cumulative completed-attempt statistics for a
 * registered job. Event-dependent fields remain present as BSON null until the
 * qualifying event occurs in the current statistics epoch.
 */
static pgbson *
BuildJobStatistics(const BackgroundWorkerJobStats *jobStats,
				   TimestampTz statsResetTimestamp)
{
	int64 executionAttempts = GetExecutionAttempts(jobStats);
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	if (executionAttempts == 0)
	{
		PgbsonWriterAppendNull(&writer, "firstAttemptTs", strlen("firstAttemptTs"));
		PgbsonWriterAppendNull(&writer, "lastAttemptTs", strlen("lastAttemptTs"));
		PgbsonWriterAppendNull(&writer, "lastObservedResolutionTs",
							   strlen("lastObservedResolutionTs"));
		PgbsonWriterAppendNull(&writer, "lastSuccessTs", strlen("lastSuccessTs"));
		PgbsonWriterAppendNull(&writer, "lastFailureTs", strlen("lastFailureTs"));
		PgbsonWriterAppendNull(&writer, "lastExecutionResult",
							   strlen("lastExecutionResult"));
	}
	else
	{
		PgbsonWriterAppendDateTime(&writer, "firstAttemptTs", strlen("firstAttemptTs"),
								   jobStats->firstAttemptTimestamp);
		PgbsonWriterAppendDateTime(&writer, "lastAttemptTs", strlen("lastAttemptTs"),
								   jobStats->lastAttemptTimestamp);
		PgbsonWriterAppendDateTime(&writer, "lastObservedResolutionTs",
								   strlen("lastObservedResolutionTs"),
								   jobStats->lastObservedResolutionTimestamp);

		if (jobStats->successfulExecutions == 0)
		{
			PgbsonWriterAppendNull(&writer, "lastSuccessTs", strlen("lastSuccessTs"));
		}
		else
		{
			PgbsonWriterAppendDateTime(&writer, "lastSuccessTs", strlen("lastSuccessTs"),
									   jobStats->lastSuccessTimestamp);
		}

		if (jobStats->failedExecutions == 0 && jobStats->timedOutExecutions == 0)
		{
			PgbsonWriterAppendNull(&writer, "lastFailureTs", strlen("lastFailureTs"));
		}
		else
		{
			PgbsonWriterAppendDateTime(&writer, "lastFailureTs", strlen("lastFailureTs"),
									   jobStats->lastFailureTimestamp);
		}

		PgbsonWriterAppendUtf8(&writer, "lastExecutionResult",
							   strlen("lastExecutionResult"),
							   JobResultName(jobStats->lastResult));
	}

	PgbsonWriterAppendInt64(&writer, "executionAttempts", strlen("executionAttempts"),
							executionAttempts);
	PgbsonWriterAppendInt64(&writer, "successfulExecutions",
							strlen("successfulExecutions"),
							(int64) jobStats->successfulExecutions);
	PgbsonWriterAppendInt64(&writer, "failedExecutions", strlen("failedExecutions"),
							(int64) jobStats->failedExecutions);
	PgbsonWriterAppendInt64(&writer, "timedOutExecutions",
							strlen("timedOutExecutions"),
							(int64) jobStats->timedOutExecutions);
	PgbsonWriterAppendInt64(&writer, "unobservedExecutions",
							strlen("unobservedExecutions"),
							(int64) jobStats->unobservedExecutions);
	PgbsonWriterAppendInt64(&writer, "consecutiveFailures",
							strlen("consecutiveFailures"),
							(int64) jobStats->consecutiveFailures);

	if (executionAttempts == 0)
	{
		PgbsonWriterAppendNull(&writer, "lastObservedAttemptDurationMs",
							   strlen("lastObservedAttemptDurationMs"));
		PgbsonWriterAppendNull(&writer, "totalObservedAttemptDurationMs",
							   strlen("totalObservedAttemptDurationMs"));
		PgbsonWriterAppendNull(&writer, "minObservedAttemptDurationMs",
							   strlen("minObservedAttemptDurationMs"));
		PgbsonWriterAppendNull(&writer, "maxObservedAttemptDurationMs",
							   strlen("maxObservedAttemptDurationMs"));
		PgbsonWriterAppendNull(&writer, "meanObservedAttemptDurationMs",
							   strlen("meanObservedAttemptDurationMs"));
	}
	else
	{
		PgbsonWriterAppendDouble(&writer, "lastObservedAttemptDurationMs",
								 strlen("lastObservedAttemptDurationMs"),
								 jobStats->lastObservedAttemptDurationMilliseconds);
		PgbsonWriterAppendDouble(&writer, "totalObservedAttemptDurationMs",
								 strlen("totalObservedAttemptDurationMs"),
								 jobStats->totalObservedAttemptDurationMilliseconds);
		PgbsonWriterAppendDouble(&writer, "minObservedAttemptDurationMs",
								 strlen("minObservedAttemptDurationMs"),
								 jobStats->minObservedAttemptDurationMilliseconds);
		PgbsonWriterAppendDouble(&writer, "maxObservedAttemptDurationMs",
								 strlen("maxObservedAttemptDurationMs"),
								 jobStats->maxObservedAttemptDurationMilliseconds);
		PgbsonWriterAppendDouble(&writer, "meanObservedAttemptDurationMs",
								 strlen("meanObservedAttemptDurationMs"),
								 jobStats->totalObservedAttemptDurationMilliseconds /
								 executionAttempts);
	}

	/*
	 * XXX: Populate these fields when terminal completion is observed through
	 * connection readiness instead of scheduler polling. Establish a fresh
	 * statistics epoch, then publish the event-driven measurement under both
	 * field families without maintaining duplicate shared-memory aggregates.
	 */
	PgbsonWriterAppendNull(&writer, "lastAttemptDurationMs",
						   strlen("lastAttemptDurationMs"));
	PgbsonWriterAppendNull(&writer, "totalAttemptDurationMs",
						   strlen("totalAttemptDurationMs"));
	PgbsonWriterAppendNull(&writer, "minAttemptDurationMs",
						   strlen("minAttemptDurationMs"));
	PgbsonWriterAppendNull(&writer, "maxAttemptDurationMs",
						   strlen("maxAttemptDurationMs"));
	PgbsonWriterAppendNull(&writer, "meanAttemptDurationMs",
						   strlen("meanAttemptDurationMs"));

	if (jobStats->hasAttemptObservationInterval)
	{
		PgbsonWriterAppendInt64(&writer, "attemptObservationIntervalMs",
								strlen("attemptObservationIntervalMs"),
								jobStats->attemptObservationIntervalMilliseconds);
	}
	else
	{
		PgbsonWriterAppendNull(&writer, "attemptObservationIntervalMs",
							   strlen("attemptObservationIntervalMs"));
	}

	PgbsonWriterAppendDateTime(&writer, "statsResetTs", strlen("statsResetTs"),
							   statsResetTimestamp);

	return PgbsonWriterGetPgbson(&writer);
}


/*
 * BuildJobOptions serializes registration options that are not relational
 * columns, allowing the SQL row type to remain stable as options evolve.
 */
static pgbson *
BuildJobOptions(const BackgroundWorkerJob *job)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	const char *roleExecutionProfile = RoleExecutionProfileName(
		job->roleExecutionProfile);
	PgbsonWriterAppendUtf8(&writer, "roleExecutionProfile",
						   strlen("roleExecutionProfile"),
						   roleExecutionProfile);
	PgbsonWriterAppendBool(&writer, "execCoordinatorOnly",
						   strlen("execCoordinatorOnly"),
						   job->toBeExecutedOnMetadataCoordinatorOnly);

	return PgbsonWriterGetPgbson(&writer);
}


/*
 * RoleExecutionProfileName returns the stable BSON representation of a job's
 * declared role eligibility.
 */
static const char *
RoleExecutionProfileName(BackgroundWorkerJobRoleExecutionProfile roleExecutionProfile)
{
	switch (roleExecutionProfile)
	{
		case BackgroundWorkerJobRoleExecutionProfile_PrimaryOnly:
		{
			return "primaryOnly";
		}

		case BackgroundWorkerJobRoleExecutionProfile_RecoveryEligible:
		{
			return "recoveryEligible";
		}

		case BackgroundWorkerJobRoleExecutionProfile_RecoveryOnly:
		{
			return "recoveryOnly";
		}

		default:
			return "invalid";
	}
}


/*
 * ResolveJobEnabled returns the current enabled state of a job. An absent hook
 * means enabled.
 */
static bool
ResolveJobEnabled(const BackgroundWorkerJob *job)
{
	if (job->is_job_enabled_hook == NULL)
	{
		return true;
	}

	return job->is_job_enabled_hook();
}


/*
 * ResolveJobScheduleIntervalSeconds returns the current schedule interval of a
 * job. The registry substitutes a default hook when none is supplied, so the
 * hook is expected to be non-NULL. Keep the fallback for defensive callers.
 */
static int
ResolveJobScheduleIntervalSeconds(const BackgroundWorkerJob *job)
{
	if (job->get_schedule_interval_in_seconds_hook == NULL)
	{
		return DEFAULT_SCHEDULE_INTERVAL_SECONDS;
	}

	return job->get_schedule_interval_in_seconds_hook();
}


/*
 * SetupBgworkerStatsTuplestore prepares a materialize-mode tuplestore matching
 * the function's declared result type.
 */
static Tuplestorestate *
SetupBgworkerStatsTuplestore(FunctionCallInfo fcinfo, TupleDesc *tupleDescriptor,
							 int expectedColumnCount, const char *resultName)
{
	ReturnSetInfo *resultSet = (ReturnSetInfo *) fcinfo->resultinfo;

	if (resultSet == NULL || !IsA(resultSet, ReturnSetInfo))
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg(
					 "set-valued function called in context that cannot accept a set")));
	}

	if ((resultSet->allowedModes & SFRM_Materialize) == 0)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg(
					 "set-valued function called in context that does not support materialization")));
	}

	if (resultSet->econtext == NULL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("set-valued function called without an execution context")));
	}

	switch (get_call_result_type(fcinfo, NULL, tupleDescriptor))
	{
		case TYPEFUNC_COMPOSITE:
		{
			/* success */
			break;
		}

		case TYPEFUNC_RECORD:
		{
			/* failed to determine actual type of RECORD */
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("function returning record called in context "
							"that cannot accept type record")));
			break;
		}

		default:
		{
			/* result type isn't composite */
			elog(ERROR, "return type must be a row type");
			break;
		}
	}

	if ((*tupleDescriptor)->natts != expectedColumnCount)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("%s return type has %d columns; "
						"expected %d",
						resultName,
						(*tupleDescriptor)->natts,
						expectedColumnCount)));
	}

	MemoryContext perQueryContext = resultSet->econtext->ecxt_per_query_memory;

	MemoryContext oldContext = MemoryContextSwitchTo(perQueryContext);
	Tuplestorestate *tupstore = tuplestore_begin_heap(true, false, work_mem);
	resultSet->returnMode = SFRM_Materialize;
	resultSet->setResult = tupstore;
	resultSet->setDesc = *tupleDescriptor;
	MemoryContextSwitchTo(oldContext);

	return tupstore;
}
