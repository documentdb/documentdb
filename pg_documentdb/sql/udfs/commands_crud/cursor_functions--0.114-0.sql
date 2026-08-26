DROP FUNCTION IF EXISTS __API_SCHEMA_V2__.current_cursor_state(__CORE_SCHEMA_V2__.bson);

DROP FUNCTION IF EXISTS __API_SCHEMA_V2__.cursor_state(__CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bson);

-- This function is STABLE (Not Volatile) as within 1 transaction snapshot
-- The value given the "document" does not change.
-- However it's not guaranteed to be the same across transaction snapshots.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.current_cursor_state(__CORE_SCHEMA_V2__.bson)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 STABLE
AS 'MODULE_PATHNAME', $function$command_current_cursor_state$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.cursor_state(__CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bson)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE STRICT
AS 'MODULE_PATHNAME', $function$command_cursor_state$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.cursor_tracker(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE STRICT
AS 'MODULE_PATHNAME', $function$command_cursor_tracker$function$;

-- Worker-side UDF for remote dynamic cursor pushdown.
-- Runs the full drain operation on the worker where the shard is local.
--
-- The coordinator issues this as a normal shard query
--   SELECT <internal>.cursor_dynamic_drain_page(...) FROM <data>.documents_<id>
--   WHERE shard_key_value = <id>;
-- A planner hook rewrites the shard scan into a function scan so the UDF runs
-- exactly once regardless of shard row count (so it still runs on an empty
-- collection). The hook injects the local shard OID into p_shard_oid; the
-- coordinator passes an invalid OID placeholder.
--
-- The result is a bson[] array (schema-independent: it avoids a custom
-- composite type) so the coordinator can forward the batch (already
-- materialized in outbound cursor-page shape) without re-serializing it, and
-- treat the worker continuation as opaque. Elements occupy fixed positions:
--   [1] result_batch : full cursor page { cursor: { id, ns, firstBatch|nextBatch }, ok }
--   [2] continuation : opaque worker continuation (SQL NULL when drained)
--   [3] meta         : { "ct": <int> } where ct is the cursor type,
--                      0 = drained, non-zero = remote dynamic cursor has more data
--
-- p_extra is a forward-compatible options bag, currently carrying
-- { "p_use_file_based_cursor": <bool> }.

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.cursor_dynamic_drain_page(
    p_database_name text,
    p_query_spec __CORE_SCHEMA__.bson,
    p_shard_oid regclass,
    p_continuation __CORE_SCHEMA__.bson,
    p_query_kind int4,
    p_extra __CORE_SCHEMA__.bson DEFAULT NULL)
 RETURNS __CORE_SCHEMA__.bson[]
 LANGUAGE c
 VOLATILE
AS 'MODULE_PATHNAME', $function$command_cursor_dynamic_drain_page$function$;

#ifdef __RBAC_SCHEMA_ENABLED__
CREATE OR REPLACE FUNCTION documentdb_api_internal_readonly.cursor_state(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE STRICT
AS 'MODULE_PATHNAME', $function$command_cursor_state$function$;

CREATE OR REPLACE FUNCTION documentdb_api_internal_readonly.current_cursor_state(__CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 STABLE
AS 'MODULE_PATHNAME', $function$command_current_cursor_state$function$;


CREATE OR REPLACE FUNCTION documentdb_api_internal_readonly.cursor_tracker(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE STRICT
AS 'MODULE_PATHNAME', $function$command_cursor_tracker$function$;
#endif