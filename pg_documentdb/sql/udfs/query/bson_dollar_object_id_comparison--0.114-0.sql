CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.dollar_support_object_id(internal)
 RETURNS internal
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $$dollar_support_object_id$$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_dollar_eq(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
 SUPPORT __API_CATALOG_SCHEMA__.dollar_support_object_id
AS 'MODULE_PATHNAME', $function$bson_dollar_eq_object_id$function$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_dollar_lt(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
 SUPPORT __API_CATALOG_SCHEMA__.dollar_support_object_id
AS 'MODULE_PATHNAME', $function$bson_dollar_lt_object_id$function$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_dollar_lte(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
 SUPPORT __API_CATALOG_SCHEMA__.dollar_support_object_id
AS 'MODULE_PATHNAME', $function$bson_dollar_lte_object_id$function$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_dollar_gt(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
 SUPPORT __API_CATALOG_SCHEMA__.dollar_support_object_id
AS 'MODULE_PATHNAME', $function$bson_dollar_gt_object_id$function$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_dollar_gte(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
 SUPPORT __API_CATALOG_SCHEMA__.dollar_support_object_id
AS 'MODULE_PATHNAME', $function$bson_dollar_gte_object_id$function$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_dollar_in(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
 SUPPORT __API_CATALOG_SCHEMA__.dollar_support_object_id
AS 'MODULE_PATHNAME', $function$bson_dollar_in_object_id$function$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_dollar_regex(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
 SUPPORT __API_CATALOG_SCHEMA__.dollar_support_object_id
AS 'MODULE_PATHNAME', $function$bson_dollar_regex_object_id$function$;