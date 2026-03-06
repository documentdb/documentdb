CREATE TYPE __API_SCHEMA_INTERNAL_V2__.bsonaggvalue;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_in(cstring)
 RETURNS __API_SCHEMA_INTERNAL_V2__.bsonaggvalue
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonaggvalue_in$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_out(__API_SCHEMA_INTERNAL_V2__.bsonaggvalue)
 RETURNS cstring
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonaggvalue_out$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_send(__API_SCHEMA_INTERNAL_V2__.bsonaggvalue)
 RETURNS bytea
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonaggvalue_send$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_recv(internal)
 RETURNS __API_SCHEMA_INTERNAL_V2__.bsonaggvalue
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonaggvalue_recv$function$;

CREATE TYPE __API_SCHEMA_INTERNAL_V2__.bsonaggvalue (
    input = __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_in,
    output = __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_out,
    send = __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_send,
    receive = __API_SCHEMA_INTERNAL_V2__.bsonaggvalue_recv,
    alignment = int4,
    storage = extended
);
