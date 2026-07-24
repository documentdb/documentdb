
CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_expression_get(document __CORE_SCHEMA__.bson, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool default false)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_get$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_get(document __CORE_SCHEMA_V2__.bson, expressionSpec __CORE_SCHEMA_V2__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA_V2__.bson)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_get$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_get(document __CORE_SCHEMA_V2__.bson, expressionSpec __CORE_SCHEMA_V2__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA_V2__.bson, collationString text)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_get$function$;

-- On-disk-bson variants of bson_expression_get (reuse the same C symbol). Take/return
-- the stored document type (__CORE_SCHEMA__.bson) so the planner can pass the document
-- straight through without relabeling.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_get_catalog(document __CORE_SCHEMA__.bson, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_get$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_get_catalog(document __CORE_SCHEMA__.bson, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA__.bson, collationString text)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_get$function$;

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_expression_map(document __CORE_SCHEMA__.bson, sourceArrayName text, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool default false)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_map$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_map(document __CORE_SCHEMA_V2__.bson, sourceArrayName text, expressionSpec __CORE_SCHEMA_V2__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA_V2__.bson)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_map$function$;

-- On-disk-bson variants of bson_expression_map (reuse the same C symbol). Take/return
-- the stored document type (__CORE_SCHEMA__.bson) so the planner can pass the document
-- straight through without relabeling.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_map_catalog(document __CORE_SCHEMA__.bson, sourceArrayName text, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_map$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_partition_get(document __CORE_SCHEMA__.bson, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool default false)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_partition_get$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_partition_get(document __CORE_SCHEMA_V2__.bson, expressionSpec __CORE_SCHEMA_V2__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA_V2__.bson)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_partition_get$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_partition_get(document __CORE_SCHEMA_V2__.bson, expressionSpec __CORE_SCHEMA_V2__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA_V2__.bson, collationString text)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_partition_get$function$;

-- On-disk-bson variants of bson_expression_partition_get (reuse the same C symbol). Take/return
-- the stored document type (__CORE_SCHEMA__.bson) so the planner can pass the document
-- straight through without relabeling.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_partition_get_catalog(document __CORE_SCHEMA__.bson, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_partition_get$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_partition_get_catalog(document __CORE_SCHEMA__.bson, expressionSpec __CORE_SCHEMA__.bson, isNullOnEmpty bool, variableSpec __CORE_SCHEMA__.bson, collationString text)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_partition_get$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_expression_partition_by_fields_get(document __CORE_SCHEMA__.bson, expressionSpec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_expression_partition_by_fields_get$function$;