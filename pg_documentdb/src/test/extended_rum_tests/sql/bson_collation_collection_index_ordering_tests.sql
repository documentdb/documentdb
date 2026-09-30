-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 3100;
SET documentdb.next_collection_index_id TO 3100;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_api.create_collection(
    'collation_collection_ordering_db', 'count_values');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "fr", "strength": 1 } }'::bson
WHERE database_name = 'collation_collection_ordering_db'
  AND collection_name = 'count_values';

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

RESET documentdb.forceIndexOnlyScanIfAvailable;
RESET enable_bitmapscan;
RESET enable_seqscan;
RESET documentdb.enableExtendedExplainPlans;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;
RESET search_path;
