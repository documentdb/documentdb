-- documentdb_stat_bgworker_jobs surfaces the background worker job registry. The
-- registry is populated during shared_preload_libraries (in the postmaster, before any
-- backend is forked), so every backend inherits it and can read the view from a normal
-- connection without contacting the background worker.

-- Ensure the background worker subsystem has finished starting before reading the view.
CALL documentdb_test_helpers.wait_for_background_worker();

-- Backing functions are executable only by the background worker role. Roles that have
-- USAGE on the internal schema must not bypass the views' SELECT privileges.
SELECT p.proname,
       has_function_privilege('documentdb_bg_worker_role', p.oid, 'EXECUTE') AS bgworker_has_exec,
       has_function_privilege('documentdb_readonly_role', p.oid, 'EXECUTE') AS readonly_has_exec,
       has_function_privilege('documentdb_readwrite_role', p.oid, 'EXECUTE') AS readwrite_has_exec
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'documentdb_api_internal'
      AND p.proname IN ('bgworker_job_registry', 'bgworker_job_stats')
    ORDER BY p.proname;

SELECT p.proname,
       has_function_privilege('documentdb_bg_worker_role', p.oid, 'EXECUTE') AS bgworker_has_exec,
       has_function_privilege('documentdb_readonly_role', p.oid, 'EXECUTE') AS readonly_has_exec,
       has_function_privilege('documentdb_readwrite_role', p.oid, 'EXECUTE') AS readwrite_has_exec
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'documentdb_api_internal'
      AND p.proname = 'cursor_directory_cleanup_background';

-- Column contracts: name + type of every column, in order.
SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod) AS type
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'documentdb_api_internal'
      AND c.relname IN ('documentdb_stat_bgworker_jobs',
                        'documentdb_stat_bgworker_job_stats')
      AND a.attnum > 0
      AND NOT a.attisdropped
    ORDER BY c.relname, a.attnum;

-- Registered jobs execute concurrently with this regression test. Accept either zero
-- state or completed state while requiring one coherent cumulative snapshot.
WITH job_stats AS
(
    SELECT job_id,
           documentdb_core.bson_get_value(statistics, 'firstAttemptTs')
               AS first_attempt_ts,
           documentdb_core.bson_get_value(statistics, 'lastAttemptTs')
               AS last_attempt_ts,
           documentdb_core.bson_get_value(statistics, 'lastObservedResolutionTs')
               AS last_observed_resolution_ts,
           documentdb_core.bson_get_value(statistics, 'lastSuccessTs')
               AS last_success_ts,
           documentdb_core.bson_get_value(statistics, 'lastFailureTs')
               AS last_failure_ts,
           NULLIF(documentdb_core.bson_get_value_text(
               statistics, 'lastExecutionResult'), 'null') AS last_execution_result,
           documentdb_core.bson_get_value_text(
               statistics, 'executionAttempts')::bigint AS execution_attempts,
           documentdb_core.bson_get_value_text(
               statistics, 'successfulExecutions')::bigint AS successful_executions,
           documentdb_core.bson_get_value_text(
               statistics, 'failedExecutions')::bigint AS failed_executions,
           documentdb_core.bson_get_value_text(
               statistics, 'timedOutExecutions')::bigint AS timed_out_executions,
           documentdb_core.bson_get_value_text(
               statistics, 'unobservedExecutions')::bigint AS unobserved_executions,
           documentdb_core.bson_get_value_text(
               statistics, 'consecutiveFailures')::bigint AS consecutive_failures,
           NULLIF(documentdb_core.bson_get_value_text(
               statistics, 'lastObservedAttemptDurationMs'), 'null')::double precision
               AS last_observed_attempt_duration_ms,
           NULLIF(documentdb_core.bson_get_value_text(
               statistics, 'totalObservedAttemptDurationMs'), 'null')::double precision
               AS total_observed_attempt_duration_ms,
           NULLIF(documentdb_core.bson_get_value_text(
               statistics, 'minObservedAttemptDurationMs'), 'null')::double precision
               AS min_observed_attempt_duration_ms,
           NULLIF(documentdb_core.bson_get_value_text(
               statistics, 'maxObservedAttemptDurationMs'), 'null')::double precision
               AS max_observed_attempt_duration_ms,
           NULLIF(documentdb_core.bson_get_value_text(
               statistics, 'meanObservedAttemptDurationMs'), 'null')::double precision
               AS mean_observed_attempt_duration_ms,
           documentdb_core.bson_get_value_text(
               statistics, 'lastAttemptDurationMs') = 'null'
               AND documentdb_core.bson_get_value_text(
                   statistics, 'totalAttemptDurationMs') = 'null'
               AND documentdb_core.bson_get_value_text(
                   statistics, 'minAttemptDurationMs') = 'null'
               AND documentdb_core.bson_get_value_text(
                   statistics, 'maxAttemptDurationMs') = 'null'
               AND documentdb_core.bson_get_value_text(
                   statistics, 'meanAttemptDurationMs') = 'null'
               AS event_driven_durations_are_null,
           NULLIF(documentdb_core.bson_get_value_text(
               statistics, 'attemptObservationIntervalMs'), 'null')::bigint
               AS attempt_observation_interval_ms,
           documentdb_core.bson_get_value(statistics, 'statsResetTs')
               AS stats_reset_ts
        FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats
)
SELECT job_id,
       execution_attempts =
           successful_executions + failed_executions + timed_out_executions +
           unobserved_executions
           AS counter_invariant_holds,
       consecutive_failures >= 0
           AND consecutive_failures <= failed_executions + timed_out_executions
           AS failure_streak_is_valid,
       CASE
           WHEN execution_attempts = 0 THEN
               consecutive_failures = 0
               AND first_attempt_ts OPERATOR(documentdb_core.=)
                   '{"": null}'::documentdb_core.bson
               AND last_attempt_ts OPERATOR(documentdb_core.=)
                   '{"": null}'::documentdb_core.bson
               AND last_observed_resolution_ts OPERATOR(documentdb_core.=)
                   '{"": null}'::documentdb_core.bson
               AND last_success_ts OPERATOR(documentdb_core.=)
                   '{"": null}'::documentdb_core.bson
               AND last_failure_ts OPERATOR(documentdb_core.=)
                   '{"": null}'::documentdb_core.bson
               AND last_execution_result IS NULL
               AND last_observed_attempt_duration_ms IS NULL
               AND total_observed_attempt_duration_ms IS NULL
               AND min_observed_attempt_duration_ms IS NULL
               AND max_observed_attempt_duration_ms IS NULL
               AND mean_observed_attempt_duration_ms IS NULL
               AND attempt_observation_interval_ms IS NULL
           ELSE
               first_attempt_ts OPERATOR(documentdb_core.<>)
                   '{"": null}'::documentdb_core.bson
               AND last_attempt_ts OPERATOR(documentdb_core.<>)
                   '{"": null}'::documentdb_core.bson
               AND last_observed_resolution_ts OPERATOR(documentdb_core.<>)
                   '{"": null}'::documentdb_core.bson
               AND first_attempt_ts OPERATOR(documentdb_core.<=) last_attempt_ts
               AND last_attempt_ts OPERATOR(documentdb_core.<=)
                   last_observed_resolution_ts
               AND last_execution_result IN
                   ('succeeded', 'failed', 'timed_out', 'unobserved')
               AND last_observed_attempt_duration_ms >= 0
               AND total_observed_attempt_duration_ms >=
                   last_observed_attempt_duration_ms
               AND min_observed_attempt_duration_ms >= 0
               AND min_observed_attempt_duration_ms <=
                   last_observed_attempt_duration_ms
               AND max_observed_attempt_duration_ms >=
                   last_observed_attempt_duration_ms
               AND mean_observed_attempt_duration_ms >= 0
               AND attempt_observation_interval_ms >= 0
       END AS cumulative_state_is_coherent,
       event_driven_durations_are_null,
       stats_reset_ts OPERATOR(documentdb_core.<>)
           '{"": null}'::documentdb_core.bson AS reset_ts_is_set
    FROM job_stats
    ORDER BY job_id;

SELECT count(*) AS job_count,
       count(DISTINCT documentdb_core.bson_get_value(
                          statistics, 'statsResetTs'))
           AS reset_epoch_count
    FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats;

-- schedule_interval_seconds is resolved from each job's hook at query time. Pin the GUC
-- the index-build jobs' schedule hook reads so this snapshot is deterministic.
SET documentdb.indexBuildScheduleInSec TO 17;

SELECT job_id, job_name, command, schedule_interval_seconds, timeout_seconds, enabled,
       job_options
    FROM documentdb_api_internal.documentdb_stat_bgworker_jobs
    ORDER BY job_id;

-- The two hook-resolved columns are point-in-time lookups, not cached values: changing
-- the underlying GUC is reflected on the next read.
SET documentdb.indexBuildScheduleInSec TO 42;

SELECT job_id, schedule_interval_seconds
    FROM documentdb_api_internal.documentdb_stat_bgworker_jobs
    ORDER BY job_id;

RESET documentdb.indexBuildScheduleInSec;

SET documentdb.enable_cursor_cleanup_in_recovery TO true;

SELECT job_id, enabled
    FROM documentdb_api_internal.documentdb_stat_bgworker_jobs
    WHERE job_id = 92;

RESET documentdb.enable_cursor_cleanup_in_recovery;

-- The reset entry point is C-backed so the later shared-state implementation can land
-- without requiring another SQL definition.
SELECT l.lanname AS language,
       p.provolatile = 'v' AS is_volatile,
       p.proparallel = 'u' AS is_parallel_unsafe,
       has_function_privilege('documentdb_bg_worker_role', p.oid, 'EXECUTE')
           AS bgworker_has_exec,
       has_function_privilege('documentdb_readonly_role', p.oid, 'EXECUTE')
           AS readonly_has_exec,
       has_function_privilege('documentdb_readwrite_role', p.oid, 'EXECUTE')
           AS readwrite_has_exec
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language l ON l.oid = p.prolang
    WHERE n.nspname = 'documentdb_api_internal'
      AND p.proname = 'documentdb_stat_reset_shared';

SELECT documentdb_core.bson_get_value(statistics, 'statsResetTs')
           AS stats_reset_ts_before
    FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats
    ORDER BY job_id
    LIMIT 1
    \gset

SELECT documentdb_api_internal.documentdb_stat_reset_shared('bgworker');

SELECT string_agg(job_id::text, ',' ORDER BY job_id) AS job_ids,
       bool_and(documentdb_core.bson_get_value_text(
                    statistics, 'executionAttempts')::bigint =
                documentdb_core.bson_get_value_text(
                    statistics, 'successfulExecutions')::bigint +
                documentdb_core.bson_get_value_text(
                    statistics, 'failedExecutions')::bigint +
                documentdb_core.bson_get_value_text(
                    statistics, 'timedOutExecutions')::bigint +
                documentdb_core.bson_get_value_text(
                    statistics, 'unobservedExecutions')::bigint)
           AS counter_invariant_holds,
       count(DISTINCT documentdb_core.bson_get_value(
                          statistics, 'statsResetTs')) = 1
           AS common_reset_epoch,
       bool_and(documentdb_core.bson_get_value(statistics, 'statsResetTs')
                    OPERATOR(documentdb_core.>)
                :'stats_reset_ts_before'::documentdb_core.bson)
           AS reset_epoch_advanced
    FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats;

SELECT documentdb_core.bson_get_value(statistics, 'statsResetTs')
           AS stats_reset_ts_before
    FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats
    ORDER BY job_id
    LIMIT 1
    \gset

SELECT documentdb_api_internal.documentdb_stat_reset_shared('bgworker');

SELECT count(DISTINCT documentdb_core.bson_get_value(
                          statistics, 'statsResetTs')) = 1
           AS common_reset_epoch,
       bool_and(documentdb_core.bson_get_value(statistics, 'statsResetTs')
                    OPERATOR(documentdb_core.>)
                :'stats_reset_ts_before'::documentdb_core.bson)
           AS reset_epoch_advanced
    FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats;

SELECT documentdb_api_internal.documentdb_stat_reset_shared(NULL);
SELECT documentdb_api_internal.documentdb_stat_reset_shared('invalid');
