-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_external_in(cstring)
 RETURNS __CORE_SCHEMA__.bson_external
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_external_in$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_external_out(__CORE_SCHEMA__.bson_external)
 RETURNS cstring
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_external_out$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_external_send(__CORE_SCHEMA__.bson_external)
 RETURNS bytea
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_external_send$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_external_recv(internal)
 RETURNS __CORE_SCHEMA__.bson_external
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_external_recv$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_to_bson_external(__CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson_external
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_to_bson_external$function$;

COMMENT ON FUNCTION __CORE_SCHEMA__.bson_to_bson_external(__CORE_SCHEMA__.bson) IS
    'Always compress BSON using dictionary-free Zstandard at the default level. pg_column_size of the result includes a four-byte varlena header and a one-byte format flag; small documents can grow.';

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_external_to_bson(__CORE_SCHEMA__.bson_external)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_external_to_bson$function$;
