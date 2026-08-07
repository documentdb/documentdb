/*
 * Cross-type bson (left) OP bsonquery (right) comparison functions. bsonquery is
 * binary-identical to bson, so these reuse the raw bson comparison entrypoints;
 * they back the native-stats operators (see bson_query_btree_operators).
 */

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_compare(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS int
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$extension_bson_compare$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_equal(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$extension_bson_equal$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_not_equal(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$extension_bson_not_equal$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_lt(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$extension_bson_lt$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_lte(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$extension_bson_lte$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_gt(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$extension_bson_gt$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_gte(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$extension_bson_gte$function$;
