DROP AGGREGATE IF EXISTS __API_CATALOG_SCHEMA__.bsonaverage(__CORE_SCHEMA__.bson);
DROP AGGREGATE IF EXISTS __API_CATALOG_SCHEMA__.bsonmax(__CORE_SCHEMA__.bson);
DROP AGGREGATE IF EXISTS __API_CATALOG_SCHEMA__.bsonmin(__CORE_SCHEMA__.bson);
DROP AGGREGATE IF EXISTS __API_CATALOG_SCHEMA__.bsonfirstonsorted(__CORE_SCHEMA__.bson);
DROP AGGREGATE IF EXISTS __API_CATALOG_SCHEMA__.bsonlastonsorted(__CORE_SCHEMA__.bson);
DROP AGGREGATE IF EXISTS __API_SCHEMA_INTERNAL_V2__.bsonfirstonsorted(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);
DROP AGGREGATE IF EXISTS __API_SCHEMA_INTERNAL_V2__.bsonlastonsorted(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);

DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_min_max_final(__CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_max_transition(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_min_transition(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_min_combine(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_max_combine(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_first_transition_on_sorted(bytea, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_last_transition_on_sorted(bytea, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_SCHEMA_INTERNAL_V2__.bson_first_transition_on_sorted(bytea, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_SCHEMA_INTERNAL_V2__.bson_last_transition_on_sorted(bytea, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson);
DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_first_last_final_on_sorted(bytea);