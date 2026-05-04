/* Command: update */

-- Drop the legacy composite-returning bson_update_document UDF.
-- All callers must use the scalar update_bson_document UDF instead.
DROP FUNCTION IF EXISTS __API_SCHEMA_INTERNAL__.bson_update_document;


-- Base overload of update_bson_document without update tracking params.
-- Used by callers that do not pass physical row identifiers (ctid/tableOid).
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.update_bson_document(
    document __CORE_SCHEMA__.bson,
    updateSpec __CORE_SCHEMA__.bson,
    querySpec __CORE_SCHEMA__.bson,
    arrayFilters __CORE_SCHEMA__.bson,
    variableSpec __CORE_SCHEMA__.bson,
    collationString text,
    OUT newDocument __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE
AS 'MODULE_PATHNAME', $function$bson_update_document$function$;


-- Extended overload of update_bson_document with sourceCTID and sourceTableOid
-- for identification of documents getting updated at the physical storage level.
-- Used for change stream update description tracking.
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.update_bson_document(
    document __CORE_SCHEMA__.bson,
    updateSpec __CORE_SCHEMA__.bson,
    querySpec __CORE_SCHEMA__.bson,
    arrayFilters __CORE_SCHEMA__.bson,
    variableSpec __CORE_SCHEMA__.bson,
    collationString text,
    sourceCTID tid,
    sourceTableOid oid,
    OUT newDocument __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE
AS 'MODULE_PATHNAME', $function$bson_update_document$function$;
