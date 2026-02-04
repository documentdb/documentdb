
CREATE OR REPLACE FUNCTION __API_SCHEMA__.count_query(database text, countSpec __CORE_SCHEMA__.bson, OUT document __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C
VOLATILE PARALLEL UNSAFE STRICT
AS 'MODULE_PATHNAME', $function$command_count_query$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA__.distinct_query(database text, distinctSpec __CORE_SCHEMA__.bson, OUT document __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C
VOLATILE PARALLEL UNSAFE STRICT
AS 'MODULE_PATHNAME', $function$command_distinct_query$function$;

CREATE OR REPLACE FUNCTION documentdb_api_v2.count_query(database text, countSpec __CORE_SCHEMA__.bson, OUT document __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C
VOLATILE PARALLEL UNSAFE STRICT
AS 'MODULE_PATHNAME', $function$command_count_query$function$;

CREATE OR REPLACE FUNCTION documentdb_api_v2.distinct_query(database text, distinctSpec __CORE_SCHEMA__.bson, OUT document __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C
VOLATILE PARALLEL UNSAFE STRICT
AS 'MODULE_PATHNAME', $function$command_distinct_query$function$;