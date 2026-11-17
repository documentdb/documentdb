-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_indexopt_scan_support(internal)
 RETURNS internal
 LANGUAGE C
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_indexopt_scan_support$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_indexopt_scan(__CORE_SCHEMA__.bson)
 RETURNS boolean
 LANGUAGE C
 IMMUTABLE PARALLEL SAFE
 SUPPORT __API_CATALOG_SCHEMA__.bson_indexopt_scan_support
AS 'MODULE_PATHNAME', $function$bson_indexopt_scan$function$;
