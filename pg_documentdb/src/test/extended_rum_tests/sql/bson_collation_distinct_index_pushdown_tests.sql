-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal,public;

-- Pin the default-on custom scan off; each custom-scan case enables it locally.
SET documentdb.enableDistinctCustomScan TO off;

SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;

-- Keep the fixed ID range stable when this file runs alone.
SELECT documentdb_api.insert_one('db', 'collation_distinct_setup_sentinel', '{ "_id": 0 }');
SELECT documentdb_api.drop_collection('db', 'collation_distinct_setup_sentinel');

SET documentdb.next_collection_id TO 20200;
SET documentdb.next_collection_index_id TO 20200;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation", "indexes": [ { "key": { "value": 1 }, "name": "idx_value_en_s1", "collation": { "locale": "en", "strength": 1 } } ] }',
  true);
SELECT COUNT(documentdb_api.insert_one(
  'db',
  'dist_collation',
  bson_build_document(
    '_id', i,
    'value', CASE i % 4
               WHEN 0 THEN 'cafe'
               WHEN 1 THEN convert_from(decode('434146c389', 'hex'), 'UTF8')
               WHEN 2 THEN 'tea'
               ELSE 'TEA'
             END)))
FROM generate_series(1, 400) AS i;
ANALYZE documentdb_data.documents_20200;

-- Test 1: Ordered pushdown without the custom scan.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
ROLLBACK;

-- Test 2: The custom scan skips duplicate collated index entries.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 3: A strength mismatch falls back to a runtime Sort.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 2 } }')
$cmd$);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 2 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 4: A binary distinct cannot use collated index ordering.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value" }')
$cmd$);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value" }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 5: Disabling collated ordered indexes forces a runtime Sort.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 6: Truncated index terms preserve two collation equivalence classes.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation_truncated", "indexes": [ { "key": { "value": 1 }, "name": "idx_value_en_s1_truncated", "collation": { "locale": "en", "strength": 1 } } ] }',
  true);
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_truncated',
  bson_build_document('_id', 1, 'value', concat(repeat('A', 4000), 'one')));
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_truncated',
  bson_build_document('_id', 2, 'value', concat(repeat('a', 4000), 'two')));
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_truncated',
  bson_build_document('_id', 3, 'value', concat(repeat('a', 4000), 'ONE')));
ANALYZE documentdb_data.documents_20201;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_truncated", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_truncated", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 7: A multikey collated index falls back to sorting unwound array values.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation_array", "indexes": [ { "key": { "value": 1 }, "name": "idx_value_en_s1_array", "collation": { "locale": "en", "strength": 1 } } ] }',
  true);
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_array',
  '{ "_id": 1, "value": [ "cafe", "tea" ] }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_array',
  '{ "_id": 2, "value": [ "CAFE", "coffee" ] }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_array',
  '{ "_id": 3, "value": [ "TEA", "cafe" ] }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_array',
  '{ "_id": 4, "value": [ "cafe", "coffee", "CAFE" ] }');
ANALYZE documentdb_data.documents_20202;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_array", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_array", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 8: Disabling distinct pushdown retains the runtime Sort.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
ROLLBACK;

-- Test 9: A matching collated index supports a dotted distinct path.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation_nested", "indexes": [ { "key": { "nested.value": 1 }, "name": "idx_nested_value_en_s1", "collation": { "locale": "en", "strength": 1 } } ] }',
  true);
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_nested',
  '{ "_id": 1, "nested": { "value": "cafe" } }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_nested',
  '{ "_id": 2, "nested": { "value": "CAFE" } }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_nested',
  '{ "_id": 3, "nested": { "value": "tea" } }');
ANALYZE documentdb_data.documents_20203;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_nested", "key": "nested.value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_nested", "key": "nested.value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_nested", "key": "nested.value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 10: A collated predicate and distinct ordering share one index.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "query": { "value": { "$gte": "cafe" } }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "query": { "value": { "$gte": "cafe" } }, "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "query": { "value": { "$gte": "cafe" } }, "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 11: A lossy collated term requires Index Scan, not Index Only Scan.
ALTER TABLE documentdb_data.documents_20200 SET (autovacuum_enabled = off);
VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_20200;
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;
ALTER TABLE documentdb_data.documents_20200 RESET (autovacuum_enabled);

-- Test 12: Mixed types preserve type boundaries while strings collate.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation_mixed", "indexes": [ { "key": { "value": 1 }, "name": "idx_value_en_s1_mixed", "collation": { "locale": "en", "strength": 1 } } ] }',
  true);
SELECT documentdb_api.insert_one('db', 'dist_collation_mixed', '{ "_id": 1, "value": null }');
SELECT documentdb_api.insert_one('db', 'dist_collation_mixed', '{ "_id": 2, "value": 1 }');
SELECT documentdb_api.insert_one('db', 'dist_collation_mixed', '{ "_id": 3, "value": "cafe" }');
SELECT documentdb_api.insert_one('db', 'dist_collation_mixed', '{ "_id": 4, "value": "CAFE" }');
SELECT documentdb_api.insert_one('db', 'dist_collation_mixed', '{ "_id": 5 }');
ANALYZE documentdb_data.documents_20204;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_mixed", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_mixed", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_mixed", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 13: An incompatible distinct-exists index cannot supply ordering.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enable_distinct_exists_filter_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 2 } }')
$cmd$);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 2 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 14: Each collation selects its matching index.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation", "indexes": [ { "key": { "value": 1 }, "name": "idx_value_en_s2", "collation": { "locale": "en", "strength": 2 } } ] }',
  true);
ANALYZE documentdb_data.documents_20200;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 2 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation", "key": "value", "collation": { "locale": "en", "strength": 2 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Test 15: A collated leading equality enables the compound index.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation_compound", "indexes": [ { "key": { "category": 1, "value": 1 }, "name": "idx_category_value_en_s1", "collation": { "locale": "en", "strength": 1 } } ] }',
  true);
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_compound',
  '{ "_id": 1, "category": "group", "value": "cafe" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_compound',
  '{ "_id": 2, "category": "GROUP", "value": "CAFE" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_compound',
  '{ "_id": 3, "category": "group", "value": "tea" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_compound',
  '{ "_id": 4, "category": "other", "value": "coffee" }');
ANALYZE documentdb_data.documents_20205;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_compound", "key": "value", "query": { "category": "group" }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_compound", "key": "value", "query": { "category": "group" }, "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_compound", "key": "value", "query": { "category": "group" }, "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Full-response checks.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation_response", "indexes": [
      { "key": { "value": 1 }, "name": "idx_value_fr_s2", "collation": { "locale": "fr", "strength": 2 } },
      { "key": { "nested.value": 1 }, "name": "idx_nested_value_fr_s2", "collation": { "locale": "fr", "strength": 2 } },
      { "key": { "numeric": 1 }, "name": "idx_numeric_en_s1_numeric", "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }
    ] }',
  true);
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response',
  '{ "_id": 1, "value": "cafe", "nested": { "value": "cafe" }, "numeric": "2" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response',
  '{ "_id": 2, "value": "caf\u00e9", "nested": { "value": "caf\u00e9" }, "numeric": "10" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response',
  '{ "_id": 3, "value": "th\u00e9", "nested": { "value": "th\u00e9" }, "numeric": "20" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response',
  '{ "_id": 4, "value": "cafe", "nested": { "value": "cafe" }, "numeric": "2" }');
ANALYZE documentdb_data.documents_20206;

-- Test 16: Scalar results match with ordered pushdown and a runtime Sort.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_response", "key": "value", "collation": { "locale": "fr", "strength": 2 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM documentdb_api.distinct_query(
  'db',
  '{ "distinct": "dist_collation_response", "key": "value", "collation": { "locale": "fr", "strength": 2 } }');
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM documentdb_api.distinct_query(
  'db',
  '{ "distinct": "dist_collation_response", "key": "value", "collation": { "locale": "fr", "strength": 2 } }');
ROLLBACK;

-- Test 17: Dotted values use their matching collated index.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_response", "key": "nested.value", "collation": { "locale": "fr", "strength": 2 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM documentdb_api.distinct_query(
  'db',
  '{ "distinct": "dist_collation_response", "key": "nested.value", "collation": { "locale": "fr", "strength": 2 } }');
ROLLBACK;

-- Test 18: Numeric ordering controls the physical result order.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_response", "key": "numeric", "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM documentdb_api.distinct_query(
  'db',
  '{ "distinct": "dist_collation_response", "key": "numeric", "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }');
ROLLBACK;

-- Test 19: A leading equality enables the compound collated index.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{ "createIndexes": "dist_collation_response_compound", "indexes": [
      { "key": { "category": 1, "value": 1 }, "name": "idx_category_value_fr_s2", "collation": { "locale": "fr", "strength": 2 } }
    ] }',
  true);
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response_compound',
  '{ "_id": 1, "category": "group", "value": "cafe" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response_compound',
  '{ "_id": 2, "category": "GROUP", "value": "caf\u00e9" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response_compound',
  '{ "_id": 3, "category": "group", "value": "th\u00e9" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response_compound',
  '{ "_id": 4, "category": "group", "value": "cafe" }');
SELECT documentdb_api.insert_one(
  'db', 'dist_collation_response_compound',
  '{ "_id": 5, "category": "other", "value": "coffee" }');
ANALYZE documentdb_data.documents_20207;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_response_compound", "key": "value", "query": { "category": "group" }, "collation": { "locale": "fr", "strength": 2 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM documentdb_api.distinct_query(
  'db',
  '{ "distinct": "dist_collation_response_compound", "key": "value", "query": { "category": "group" }, "collation": { "locale": "fr", "strength": 2 } }');
ROLLBACK;

-- Test 20: A collated _id distinct cannot use binary primary-key ordering.
SELECT documentdb_api.insert_one('db', 'dist_collation_id', '{ "_id": "cafe" }');
SELECT documentdb_api.insert_one('db', 'dist_collation_id', '{ "_id": "CAFE" }');
SELECT documentdb_api.insert_one('db', 'dist_collation_id', '{ "_id": "tea" }');
SELECT documentdb_api.insert_one('db', 'dist_collation_id', '{ "_id": "TEA" }');
ANALYZE documentdb_data.documents_20208;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_id", "key": "_id", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
WITH result AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_collation_id", "key": "_id", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM result;
ROLLBACK;

-- Cleanup.
SELECT documentdb_api.drop_collection('db', 'dist_collation');
SELECT documentdb_api.drop_collection('db', 'dist_collation_truncated');
SELECT documentdb_api.drop_collection('db', 'dist_collation_array');
SELECT documentdb_api.drop_collection('db', 'dist_collation_nested');
SELECT documentdb_api.drop_collection('db', 'dist_collation_mixed');
SELECT documentdb_api.drop_collection('db', 'dist_collation_compound');
SELECT documentdb_api.drop_collection('db', 'dist_collation_response');
SELECT documentdb_api.drop_collection('db', 'dist_collation_response_compound');
SELECT documentdb_api.drop_collection('db', 'dist_collation_id');
