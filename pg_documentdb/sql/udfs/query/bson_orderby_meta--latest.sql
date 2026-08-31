-- Order by function that computes the text score ($meta: "textScore") for a
-- document from an explicitly supplied text index options blob and TSQuery.
-- Declared non-strict so that null options or query surface a descriptive
-- error rather than a silent null result.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_orderby_meta(__CORE_SCHEMA__.bson, bytea, tsquery)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE
AS 'MODULE_PATHNAME', $function$bson_orderby_meta$function$;
