/* with BSON */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.drop_database(
    p_commandspec __CORE_SCHEMA_V2__.bson)
RETURNS __CORE_SCHEMA_V2__.bson
LANGUAGE c
AS 'MODULE_PATHNAME', $function$command_drop_database_by_bson_spec$function$;
COMMENT ON FUNCTION __API_SCHEMA_V2__.drop_database(__CORE_SCHEMA_V2__.bson)
    IS 'drops a logical document database';

CREATE OR REPLACE FUNCTION documentdb_api_v2.drop_database(
    p_commandspec __CORE_SCHEMA_V2__.bson)
RETURNS __CORE_SCHEMA_V2__.bson
LANGUAGE c
AS 'MODULE_PATHNAME', $function$command_drop_database_by_bson_spec$function$;
COMMENT ON FUNCTION documentdb_api_v2.drop_database(__CORE_SCHEMA_V2__.bson)
    IS 'drops a logical document database';
