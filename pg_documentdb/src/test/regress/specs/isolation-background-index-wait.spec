# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

setup
{
    CREATE TABLE public.index_build_wait_jobs AS
    SELECT jobid, active FROM cron.job
    WHERE jobname LIKE 'documentdb_index_build_task_%';
    UPDATE cron.job SET active = false
    WHERE jobname LIKE 'documentdb_index_build_task_%';
    CREATE TABLE public.index_build_wait_timing (released_at timestamptz);
    INSERT INTO public.index_build_wait_timing VALUES (NULL);
}

teardown
{
    UPDATE cron.job AS job SET active = saved.active
    FROM public.index_build_wait_jobs AS saved WHERE job.jobid = saved.jobid;
    DROP TABLE public.index_build_wait_jobs;
    DROP TABLE public.index_build_wait_timing;
}

session "builder"
setup
{
    SET documentdb.enable_background_index_build_notify TO on;
    SET documentdb.indexBuildScheduleInSec TO 3;
}

step "build"
{
    CALL documentdb_api_internal.build_index_concurrently(1);
}

step "check-budget"
{
    SELECT clock_timestamp() - released_at < interval '2 seconds'
        AS queue_wait_consumed_invocation_budget
    FROM public.index_build_wait_timing;
}

session "blocker"

step "lock-queue"
{
    BEGIN;
    LOCK TABLE documentdb_api_catalog.documentdb_index_queue IN ACCESS EXCLUSIVE MODE;
}

step "spend-budget"
{
    SELECT pg_sleep(3.1);
    UPDATE public.index_build_wait_timing SET released_at = clock_timestamp();
}

step "release-queue"
{
    COMMIT;
}

permutation "lock-queue" "build" "spend-budget" "release-queue" "check-budget"
