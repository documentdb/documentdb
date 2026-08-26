/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/background_worker/background_worker_job.h
 *
 * Common declarations related to pg_documentdb background worker.
 *
 *-------------------------------------------------------------------------
 */

 #include <postgres.h>

 #ifndef DOCUMENTS_BACKGROUND_WORKER_JOB_H
 #define DOCUMENTS_BACKGROUND_WORKER_JOB_H

/*
 * Background worker job command.
 */
typedef struct
{
	/*
	 * Function/Procedure schema.
	 */
	const char *schema;

	/*
	 * Function/Procedure name.
	 */
	const char *name;
} BackgroundWorkerJobCommand;

/*
 * Background worker job argument.
 */
typedef struct
{
	/*
	 * Argument Oid.
	 */
	Oid argType;

	/*
	 * Argument value as a string.
	 */
	const char *argValue;

	/*
	 * Boolean for null argument.
	 */
	bool isNull;
} BackgroundWorkerJobArgument;

/*
 * Server roles in which a periodic job may be dispatched.
 * RecoveryEligible includes both primary and recovery.
 */
typedef enum BackgroundWorkerJobRoleExecutionProfile
{
	BackgroundWorkerJobRoleExecutionProfile_Unspecified = 0,
	BackgroundWorkerJobRoleExecutionProfile_PrimaryOnly,
	BackgroundWorkerJobRoleExecutionProfile_RecoveryEligible,
} BackgroundWorkerJobRoleExecutionProfile;


/*
 * Define a hook that clients can supply. This can be used to dynamically
 * change the schedule interval of the job.
 */
typedef int (*get_schedule_interval_in_seconds_hook_type)(void);

typedef bool (*is_job_enabled_hook_type)(void);

/* Background worker job definition */
typedef struct
{
	/* Job id. */
	int jobId;

	/* Job name, this will be used in log emission. */
	const char *jobName;

	/* Server roles in which the job may be dispatched. */
	BackgroundWorkerJobRoleExecutionProfile roleExecutionProfile;

	/* Pair of schema and function/procedure name to be executed. */
	BackgroundWorkerJobCommand command;

	/*
	 * Argument for the command. The number of arguments
	 * is currently limited to 1.
	 */
	BackgroundWorkerJobArgument argument;

	/*
	 * Hook to get the schedule interval in seconds.
	 * This can be used to dynamically change the schedule interval.
	 */
	get_schedule_interval_in_seconds_hook_type get_schedule_interval_in_seconds_hook;

	/*
	 * Command timeout in seconds. The job will be canceled if it runs for longer than this.
	 */
	int timeoutInSeconds;

	/* Flag to decide whether to run the job on metadata coordinator only or on all nodes. */
	bool toBeExecutedOnMetadataCoordinatorOnly;

	/*
	 * Hook to determine if the job is enabled.
	 * This can be used to dynamically enable or disable the job.
	 * If the hook is not set, the job is enabled by default.
	 */
	is_job_enabled_hook_type is_job_enabled_hook;
} BackgroundWorkerJob;

/*
 * Register a periodic job.
 */
void RegisterBackgroundWorkerJob(BackgroundWorkerJob job);

/*
 * Number of background worker jobs registered during shared_preload_libraries.
 * Stable for the life of the process: the registry is populated once at
 * extension init (pre-fork) and never mutated afterward.
 */
int GetBackgroundWorkerJobCount(void);


/*
 * Read-only access to the registered job at `index`, where
 * 0 <= index < GetBackgroundWorkerJobCount().
 *
 * Returns a pointer into the process-lifetime-stable registry, or NULL if
 * `index` is out of range. The caller must treat the target as immutable. The
 * pointer is valid for the life of the process (static storage, never freed or
 * resized).
 */
const BackgroundWorkerJob * GetBackgroundWorkerJob(int index);


/*
 * Callback for background worker init jobs. Native C functions that run
 * one time initialization before the periodic job loop, and before
 * extensions/roles exist.
 * A normal return indicates success (will not be retried).
 * Throwing an error indicates failure (will be retried).
 */
typedef void (*BackgroundWorkerInitJobCallback)(void);


/*
 * Definition of a background worker init job.
 */
typedef struct BackgroundWorkerInitJob
{
	/* Job name, this will be used in log emission. */
	const char *jobName;

	/* C function pointer to execute. */
	BackgroundWorkerInitJobCallback callback;
} BackgroundWorkerInitJob;


/*
 * Register a background worker init job to be executed during background
 * worker initialization.
 *
 * Must be called during shared_preload_libraries and is executed in
 * registration order.
 */
void RegisterBackgroundWorkerInitJob(BackgroundWorkerInitJob job);

#endif /* DOCUMENTS_BACKGROUND_WORKER_JOB_H */
