/* with BSON */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.drop_collection(
    p_commandspec __CORE_SCHEMA_V2__.bson,
    p_collection_uuid uuid DEFAULT NULL,
    p_track_changes bool DEFAULT true)
RETURNS bool
LANGUAGE C
AS 'MODULE_PATHNAME', $function$command_drop_collection_by_bson_spec$function$;
COMMENT ON FUNCTION __API_SCHEMA_V2__.drop_collection(__CORE_SCHEMA_V2__.bson, uuid, bool)
    IS 'drop a collection';

CREATE OR REPLACE FUNCTION documentdb_api_v2.drop_collection(
    p_commandspec __CORE_SCHEMA_V2__.bson,
    p_collection_uuid uuid DEFAULT NULL,
    p_track_changes bool DEFAULT true)
RETURNS bool
LANGUAGE C
AS 'MODULE_PATHNAME', $function$command_drop_collection_by_bson_spec$function$;
COMMENT ON FUNCTION documentdb_api_v2.drop_collection(__CORE_SCHEMA_V2__.bson, uuid, bool)
    IS 'drop a collection';
