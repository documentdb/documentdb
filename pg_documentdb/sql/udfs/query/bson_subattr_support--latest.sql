CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_subattr_support(internal)
 RETURNS internal
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_subattr_support$function$;
