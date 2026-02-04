CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.validate(database text, validateSpec __CORE_SCHEMA__.bson, OUT document __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C
VOLATILE PARALLEL UNSAFE STRICT
AS 'MODULE_PATHNAME', $function$command_validate$function$;
COMMENT ON FUNCTION __API_SCHEMA_V2__.validate(text, __CORE_SCHEMA__.bson)
    IS 'Validates the indexes for a given collection';

CREATE OR REPLACE FUNCTION documentdb_api_v2.validate(database text, validateSpec __CORE_SCHEMA__.bson, OUT document __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C
VOLATILE PARALLEL UNSAFE STRICT
AS 'MODULE_PATHNAME', $function$command_validate$function$;
COMMENT ON FUNCTION documentdb_api_v2.validate(text, __CORE_SCHEMA__.bson)
    IS 'Validates the indexes for a given collection';
