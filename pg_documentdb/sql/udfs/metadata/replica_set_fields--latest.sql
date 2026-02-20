/*
 * Returns replica set fields for hello/isMaster responses.
 *
 * Returns NULL when no replica set hook is set, or a BSON document with replica set
 * fields (hosts, setName, primary, me, isWritablePrimary, secondary, etc.) when a hook
 * is configured. The gateway calls this periodically and merges the result into hello responses.
 *
 * Internal gateway use only.
 */
CREATE OR REPLACE FUNCTION documentdb_api_internal.get_replica_set_fields()
RETURNS __CORE_SCHEMA__.bson
STABLE
LANGUAGE c
AS 'MODULE_PATHNAME', $function$get_replica_set_fields$function$;

COMMENT ON FUNCTION documentdb_api_internal.get_replica_set_fields()
	IS 'Returns replica set information as single BSON document.';
