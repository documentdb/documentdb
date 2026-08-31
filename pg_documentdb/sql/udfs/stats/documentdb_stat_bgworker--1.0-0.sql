-- The documentdb_stat_bgworker_jobs view lists the background worker jobs
-- registered during shared_preload_libraries, one row per job. It is backed by
-- the bgworker_job_registry() function. Fields from the base job definition
-- remain relational columns; versioned registration fields are serialized in
-- job_options so the SQL row type does not change with each contract revision.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bgworker_job_registry(
	OUT job_id int,
	OUT job_name text,
	OUT command text,
	OUT schedule_interval_seconds int,
	OUT timeout_seconds int,
	OUT enabled bool,
	OUT job_options __CORE_SCHEMA__.bson)
RETURNS SETOF RECORD
LANGUAGE C VOLATILE PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $$bgworker_job_registry$$;

REVOKE EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL_V2__.bgworker_job_registry() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL_V2__.bgworker_job_registry()
	TO __API_BG_WORKER_ROLE__;

CREATE OR REPLACE VIEW __API_SCHEMA_INTERNAL_V2__.documentdb_stat_bgworker_jobs AS
SELECT job_id, job_name, command, schedule_interval_seconds, timeout_seconds, enabled,
	   job_options
FROM __API_SCHEMA_INTERNAL_V2__.bgworker_job_registry();

-- The internal schema grants USAGE only to specific roles, and planning any query over
-- this view resolves the documentdb_core bson type through an ACL-checked lookup, so the
-- reader needs USAGE on both this schema and documentdb_core. Grant SELECT to the
-- background worker role, which already holds USAGE on both. The backing function's
-- EXECUTE privilege is restricted to the same role.
GRANT SELECT ON __API_SCHEMA_INTERNAL_V2__.documentdb_stat_bgworker_jobs TO __API_BG_WORKER_ROLE__;

-- Completed-attempt statistics for recurring jobs registered through the
-- background worker job framework. The statistics document is extensible
-- without changing the SQL row type. Current activity is intentionally
-- excluded from this cumulative surface.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bgworker_job_stats(
	OUT job_id int,
	OUT statistics __CORE_SCHEMA__.bson)
RETURNS SETOF RECORD
LANGUAGE C VOLATILE PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $$bgworker_job_stats$$;

REVOKE EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL_V2__.bgworker_job_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL_V2__.bgworker_job_stats()
	TO __API_BG_WORKER_ROLE__;

CREATE OR REPLACE VIEW __API_SCHEMA_INTERNAL_V2__.documentdb_stat_bgworker_job_stats AS
SELECT job_id, statistics
FROM __API_SCHEMA_INTERNAL_V2__.bgworker_job_stats();

GRANT SELECT ON __API_SCHEMA_INTERNAL_V2__.documentdb_stat_bgworker_job_stats TO __API_BG_WORKER_ROLE__;
