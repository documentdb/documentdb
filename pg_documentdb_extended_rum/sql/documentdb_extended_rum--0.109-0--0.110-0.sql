GRANT USAGE ON SCHEMA documentdb_extended_rum_catalog TO documentdb_readwrite_role;
-- add the operators for the single path ops that match the regular index.
ALTER OPERATOR FAMILY documentdb_extended_rum_catalog.bson_extended_rum_single_path_ops USING documentdb_extended_rum
    ADD OPERATOR 25 documentdb_api_catalog.@<>(documentdb_core.bson, documentdb_core.bson),
    OPERATOR 26 documentdb_api_internal.@!>(documentdb_core.bson, documentdb_core.bson),
    OPERATOR 27 documentdb_api_internal.@!>=(documentdb_core.bson, documentdb_core.bson),
    OPERATOR 28 documentdb_api_internal.@!<(documentdb_core.bson, documentdb_core.bson),
    OPERATOR 29 documentdb_api_internal.@!<=(documentdb_core.bson, documentdb_core.bson);

#include "pg_documentdb/sql/schema/bson_hash_operator_class--0.23-0.sql"

ALTER OPERATOR FAMILY documentdb_extended_rum_catalog.bson_extended_rum_composite_path_ops USING documentdb_extended_rum
    ADD FUNCTION 6 (__CORE_SCHEMA__.bson) __API_SCHEMA_INTERNAL_V2__.gin_bson_composite_rum_config(internal);