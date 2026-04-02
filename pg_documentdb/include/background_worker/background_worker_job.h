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
 * Define a hook that clients can supply. This can be used to dynamically
 * change the schedule interval of the job.
 */
typedef int (*get_schedule_interval_in_seconds_hook_type)(void);


/* Background worker job definition */
typedef struct
{
	/* Job id. */
	int jobId;

	/* Job name, this will be used in log emission. */
	const char *jobName;

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
} BackgroundWorkerJob;

/*
 * Function to register a new BackgroundWorkerJob to-be scheduled.
 */
void RegisterBackgroundWorkerJob(BackgroundWorkerJob job);


/*
 * Callback for background worker init jobs. Native C functions that run
 * one time initialization before the periodic job loop, and before
 * extensions/roles exist.
 * Returns true if completed (will not be retried), false to retry.
 */
typedef bool (*BackgroundWorkerInitJobCallback)(void);


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
