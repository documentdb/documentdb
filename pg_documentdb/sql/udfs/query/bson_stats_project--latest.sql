
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_stats_project(document __CORE_SCHEMA__.bson, field text)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_stats_project$function$;