
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_eq(__API_SCHEMA_INTERNAL_V2__.bsonindexterm,__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_eq$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_gt(__API_SCHEMA_INTERNAL_V2__.bsonindexterm,__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_gt$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_lt(__API_SCHEMA_INTERNAL_V2__.bsonindexterm,__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_lt$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_lte(__API_SCHEMA_INTERNAL_V2__.bsonindexterm,__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_lte$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_gte(__API_SCHEMA_INTERNAL_V2__.bsonindexterm,__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS bool
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_gte$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_compare(__API_SCHEMA_INTERNAL_V2__.bsonindexterm,__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS int4
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$gin_bson_compare$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_to_bson(__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$gin_bson_index_term_to_bson$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_to_bsonindexterm(__CORE_SCHEMA__.bson)
 RETURNS __API_SCHEMA_INTERNAL_V2__.bsonindexterm
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$gin_bson_to_bsonindexterm$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bsonindexterm_compare_btree(__API_SCHEMA_INTERNAL_V2__.bsonindexterm,__API_SCHEMA_INTERNAL_V2__.bsonindexterm)
 RETURNS int4
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$bsonindexterm_compare_btree$function$;
