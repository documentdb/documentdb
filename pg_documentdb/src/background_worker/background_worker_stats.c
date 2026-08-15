/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/background_worker/background_worker_stats.c
 *
 * Statistics surface for registered background worker jobs. Backs the
 * documentdb_stat_bgworker_jobs view by reading the job registry from the
 * querying backend's own (fork-inherited) copy and resolving the two
 * runtime-derived columns via the jobs' hooks at query time.
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
#include "io/bson_core.h"


#define BGWORKER_JOB_REGISTRY_COLUMNS 7

/*
 * Fallback schedule interval reported when a job's schedule hook throws.
 * Mirrors the registry's execution default (GetDefaultScheduleIntervalInSeconds).
 */
#define DEFAULT_SCHEDULE_INTERVAL_SECONDS 60

static Tuplestorestate * SetupBgworkerJobRegistryTuplestore(FunctionCallInfo fcinfo,
															TupleDesc *tupleDescriptor);
static void StoreAllBgworkerJobRegistryRows(Tuplestorestate *tupleStore,
											TupleDesc tupleDescriptor);
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
	Tuplestorestate *tupleStore = SetupBgworkerJobRegistryTuplestore(fcinfo,
																	 &tupleDescriptor);

	StoreAllBgworkerJobRegistryRows(tupleStore, tupleDescriptor);

	PG_RETURN_VOID();
}


/*
 * The SQL contract lands before runtime collection. Keep the placeholder
 * failure-shaped so an unsupported binary cannot look like a healthy empty set.
 */
Datum
bgworker_job_stats(PG_FUNCTION_ARGS)
{
	ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					errmsg("background worker job statistics are not available "
						   "in this binary version")));
}


/*
 * documentdb_stat_reset_shared validates the shared statistics subsystem to
 * reset. Runtime collection is not active yet, so the accepted target remains
 * a no-op until its shared state is implemented.
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
 * SetupBgworkerJobRegistryTuplestore prepares a materialize-mode tuplestore
 * matching the function's declared result type.
 */
static Tuplestorestate *
SetupBgworkerJobRegistryTuplestore(FunctionCallInfo fcinfo, TupleDesc *tupleDescriptor)
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

	if ((*tupleDescriptor)->natts != BGWORKER_JOB_REGISTRY_COLUMNS)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("background worker job registry return type has %d columns; "
						"expected %d",
						(*tupleDescriptor)->natts,
						BGWORKER_JOB_REGISTRY_COLUMNS)));
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
