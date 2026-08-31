-- Shared reset entry point for the documentdb_stat_* statistics family,
-- mirroring the shape of Postgres core pg_stat_reset_shared(text). The only
-- supported target this iteration is 'bgworker', which resets the node-local
-- cumulative background-worker statistics. Runtime collection for that surface
-- lands separately, so the call remains a no-op against observable state in
-- this iteration. Unsupported targets are rejected.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.documentdb_stat_reset_shared(
	IN target text)
RETURNS void
LANGUAGE C VOLATILE PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $$documentdb_stat_reset_shared$$;

-- Follow the Postgres core pg_stat_reset_shared(text) precedent: restrict execution
-- to superusers by revoking the default PUBLIC grant. Superusers bypass the ACL check;
-- granting EXECUTE to other roles is deferred to a later iteration.
REVOKE ALL ON FUNCTION __API_SCHEMA_INTERNAL_V2__.documentdb_stat_reset_shared(text) FROM PUBLIC;
