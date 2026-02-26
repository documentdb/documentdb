CREATE TYPE __API_SCHEMA_INTERNAL_V2__.bsonindexterm;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_in(cstring)
 RETURNS __API_SCHEMA_INTERNAL_V2__.bsonindexterm
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_in$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_out(__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS cstring
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_out$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_send(__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS bytea
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_send$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_recv(internal)
 RETURNS __API_SCHEMA_INTERNAL_V2__.bsonindexterm
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_recv$function$;

CREATE TYPE __API_SCHEMA_INTERNAL_V2__.bsonindexterm (
    input = __API_SCHEMA_INTERNAL_V2__.bsonindexterm_in,
    output = __API_SCHEMA_INTERNAL_V2__.bsonindexterm_out,
    send = __API_SCHEMA_INTERNAL_V2__.bsonindexterm_send,
    receive = __API_SCHEMA_INTERNAL_V2__.bsonindexterm_recv,
    alignment = int4,
    storage = extended
);

CREATE CAST (__API_SCHEMA_INTERNAL_V2__.bsonindexterm AS bytea)
    WITHOUT FUNCTION AS IMPLICIT;
CREATE CAST (bytea AS __API_SCHEMA_INTERNAL_V2__.bsonindexterm)
    WITHOUT FUNCTION AS IMPLICIT;