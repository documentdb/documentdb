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

SELECT documentdb_api_internal.documentdb_stat_reset_shared('bgworker');

SELECT documentdb_api_internal.documentdb_stat_reset_shared(NULL);
SELECT documentdb_api_internal.documentdb_stat_reset_shared('invalid');
