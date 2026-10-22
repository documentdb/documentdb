-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 3100;
SET documentdb.next_collection_index_id TO 3100;
SET documentdb_core.enableCollation TO on;
SET documentdb.enable_collation_with_create_collection TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.enable_collated_unique_indexes TO on;
SET documentdb.enable_composite_unique_optional_key TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.use_pg_stats_live_tuples_for_count TO off;

SELECT documentdb_api.create_collection_with_options(
    'collation_collection_ordering_db', 'count_values',
    '{"collation":{"locale":"fr","strength":1}}');
SELECT 'documentdb_data.documents_' || collection_id AS ordering_table
FROM documentdb_api_catalog.collections
WHERE database_name = 'collation_collection_ordering_db'
  AND collection_name = 'count_values' \gset

\d :ordering_table

-- The binary primary key and collated backing are one logical _id_ index.
SELECT document FROM bson_aggregation_pipeline(
    'collation_collection_ordering_db',
    '{"aggregate":"count_values","pipeline":[{"$collStats":{"count":{},"storageStats":{}}},{"$project":{"_id":0,"count":1,"logical_indexes":"$storageStats.nindexes","index_size_entries":{"$size":{"$objectToArray":"$storageStats.indexSizes"}}}}]}');

SELECT COUNT(documentdb_api.insert_one(
    'collation_collection_ordering_db',
    'count_values',
    bson_build_document('_id', id, 'value', value)))
FROM (VALUES
    (1, 'cafe'),
    (2, 'CAFE'),
    (3, convert_from(decode('636166c3a9', 'hex'), 'UTF8')),
    (4, convert_from(decode('434146c389', 'hex'), 'UTF8'))
) AS docs(id, value);

SELECT document FROM bson_aggregation_pipeline(
    'collation_collection_ordering_db',
    '{"aggregate":"count_values","pipeline":[{"$collStats":{"count":{},"storageStats":{}}},{"$project":{"_id":0,"count":1,"logical_indexes":"$storageStats.nindexes","index_size_entries":{"$size":{"$objectToArray":"$storageStats.indexSizes"}},"id_index_has_storage":{"$gt":["$storageStats.indexSizes._id_",0]}}}]}');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'collation_collection_ordering_db',
    '{
      "createIndexes": "count_values",
      "indexes": [
        {
          "key": { "value": 1 },
          "name": "idx_value_fr_s1",
          "collation": { "locale": "fr", "strength": 1 },
          "storageEngine": { "enableOrderedIndex": true }
        },
        {
          "key": { "value": 1 },
          "name": "idx_value_fr_s2",
          "collation": { "locale": "fr", "strength": 2 },
          "storageEngine": { "enableOrderedIndex": true }
        },
        {
          "key": { "value": 1 },
          "name": "idx_value_simple",
          "collation": { "locale": "simple" },
          "storageEngine": { "enableOrderedIndex": true }
        }
      ]
    }',
    true);

\d :ordering_table

SELECT document FROM bson_aggregation_pipeline(
    'collation_collection_ordering_db',
    '{"aggregate":"count_values","pipeline":[{"$collStats":{"count":{},"storageStats":{}}},{"$project":{"_id":0,"count":1,"logical_indexes":"$storageStats.nindexes","index_size_entries":{"$size":{"$objectToArray":"$storageStats.indexSizes"}},"id_index_has_storage":{"$gt":["$storageStats.indexSizes._id_",0]}}}]}');

SET enable_seqscan TO off;
SET enable_bitmapscan TO off;
SET documentdb.forceIndexOnlyScanIfAvailable TO on;

-- Omitted, null, and empty command collations inherit the collection default.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" } }')
$cmd$);
SELECT document FROM documentdb_api.count_query(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": null }')
$cmd$);
SELECT document FROM documentdb_api.count_query(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": null }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": {} }')
$cmd$);
SELECT document FROM documentdb_api.count_query(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": {} }');

-- Meaningful explicit collations select their matching ordered indexes.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": { "locale": "fr", "strength": 2 } }')
$cmd$);
SELECT document FROM documentdb_api.count_query(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": { "locale": "fr", "strength": 2 } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": { "locale": "simple" } }')
$cmd$);
SELECT document FROM documentdb_api.count_query(
    'collation_collection_ordering_db',
    '{ "count": "count_values", "query": { "value": "cafe" }, "collation": { "locale": "simple" } }');

CALL documentdb_api.drop_indexes('collation_collection_ordering_db',
    '{"dropIndexes":"count_values","index":"idx_value_simple"}');
SELECT document FROM bson_aggregation_pipeline(
    'collation_collection_ordering_db',
    '{"aggregate":"count_values","pipeline":[{"$collStats":{"count":{},"storageStats":{}}},{"$project":{"_id":0,"count":1,"logical_indexes":"$storageStats.nindexes","index_size_entries":{"$size":{"$objectToArray":"$storageStats.indexSizes"}}}}]}');

-- A simple-collation control needs only the binary primary key.
SELECT documentdb_api.create_collection_with_options(
    'collation_collection_ordering_db', 'simple_control',
    '{"collation":{"locale":"simple"}}');
SELECT 'documentdb_data.documents_' || collection_id AS simple_table
FROM documentdb_api_catalog.collections
WHERE database_name = 'collation_collection_ordering_db'
  AND collection_name = 'simple_control' \gset

\d :simple_table

SELECT document FROM bson_aggregation_pipeline(
    'collation_collection_ordering_db',
    '{"aggregate":"simple_control","pipeline":[{"$collStats":{"count":{},"storageStats":{}}},{"$project":{"_id":0,"count":1,"logical_indexes":"$storageStats.nindexes","index_size_entries":{"$size":{"$objectToArray":"$storageStats.indexSizes"}}}}]}');

RESET documentdb.use_pg_stats_live_tuples_for_count;
RESET documentdb.forceIndexOnlyScanIfAvailable;
RESET enable_bitmapscan;
RESET enable_seqscan;
RESET documentdb.enableExtendedExplainPlans;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.enable_composite_unique_optional_key;
RESET documentdb.enable_collated_unique_indexes;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.enable_collation_with_create_collection;
RESET documentdb_core.enableCollation;
RESET search_path;
