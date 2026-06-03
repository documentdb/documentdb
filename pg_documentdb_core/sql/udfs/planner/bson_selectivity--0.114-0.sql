CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_operator_selectivity(internal, oid, internal, integer)
 RETURNS double precision
 LANGUAGE c
 STABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_operator_selectivity$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_eqsel(internal, oid, internal, integer)
 RETURNS double precision
 LANGUAGE c
 STABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_eqsel$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_scalargtsel(internal, oid, internal, integer)
 RETURNS double precision
 LANGUAGE c
 STABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_scalargtsel$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_scalargesel(internal, oid, internal, integer)
 RETURNS double precision
 LANGUAGE c
 STABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_scalargesel$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_scalarltsel(internal, oid, internal, integer)
 RETURNS double precision
 LANGUAGE c
 STABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_scalarltsel$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_scalarlesel(internal, oid, internal, integer)
 RETURNS double precision
 LANGUAGE c
 STABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_scalarlesel$function$;

CREATE OR REPLACE FUNCTION __CORE_SCHEMA__.bson_neqsel(internal, oid, internal, integer)
 RETURNS double precision
 LANGUAGE c
 STABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bson_neqsel$function$;