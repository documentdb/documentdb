SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET citus.next_shard_id TO 198460000;
SET documentdb.next_collection_id TO 1984600;
SET documentdb.next_collection_index_id TO 1984600;

-- Enable extended_rum for composite index ordering support
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

SET documentdb.defaultUseCompositeOpClass TO on;

-- ============================================================
-- Setup: Create collection with composite index for distinct pushdown
-- ============================================================
SELECT documentdb_api.create_collection('dist_idx_db', 'dist_push');

SELECT documentdb_api_internal.create_indexes_non_concurrently('dist_idx_db', '{ "createIndexes": "dist_push", "indexes": [ { "key": { "a": 1 }, "name": "idx_a" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dist_idx_db', '{ "createIndexes": "dist_push", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "idx_a_b" } ] }', true);

-- Insert non-array data (non-multikey) with duplicates for distinct
SELECT COUNT(documentdb_api.insert_one('dist_idx_db', 'dist_push', bson_build_document('_id', i, 'a', i % 10, 'b', chr(65 + (i % 5)), 'extra', concat('data_', i)))) FROM generate_series(1, 200) AS i;

SELECT collection_id FROM documentdb_api_catalog.collections WHERE collection_name = 'dist_push' AND database_name = 'dist_idx_db' \gset
ANALYZE documentdb_data.documents_:collection_id;

-- ============================================================
-- Test 1: EXPLAIN distinct on indexed field - pushdown ON
-- Sort should be absent, index provides ordering via Order By
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 2: EXPLAIN distinct on indexed field - pushdown OFF
-- Sort should be present
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 3: EXPLAIN distinct with filter - pushdown ON
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$gte": 5 } } }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 4: Correctness - pushdown ON vs OFF should give same results
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a" }');

-- ============================================================
-- Test 5: Correctness with filter - pushdown ON vs OFF
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$lt": 3 } } }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$lt": 3 } } }');

-- ============================================================
-- Test 6: Correctness on field "b"
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "b" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "b" }');

-- ============================================================
-- Test 7: Multikey transition - insert array, pushdown should stop
-- ============================================================
SELECT documentdb_api.insert_one('dist_idx_db', 'dist_push', '{ "_id": 999, "a": [100, 200, 300], "b": "Z" }');
ANALYZE documentdb_data.documents_:collection_id;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

-- After multikey insertion, Sort should reappear even with pushdown ON
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$);
ROLLBACK;

-- Remove the array doc
SELECT documentdb_api.delete('dist_idx_db', '{ "delete": "dist_push", "deletes": [ { "q": { "_id": 999 }, "limit": 1 } ] }');

-- Verify correctness after multikey (index remains multikey)
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push", "key": "a" }');

-- ============================================================
-- Test 8: Collection with multikey index from start - no pushdown
-- ============================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dist_idx_db', '{ "createIndexes": "dist_push_mk", "indexes": [ { "key": { "arr": 1 }, "name": "idx_arr" } ] }', true);

SELECT documentdb_api.insert_one('dist_idx_db', 'dist_push_mk', '{ "_id": 1, "arr": [1, 2, 3] }');
SELECT documentdb_api.insert_one('dist_idx_db', 'dist_push_mk', '{ "_id": 2, "arr": [2, 3, 4] }');
SELECT documentdb_api.insert_one('dist_idx_db', 'dist_push_mk', '{ "_id": 3, "arr": [3, 4, 5] }');

SELECT collection_id FROM documentdb_api_catalog.collections WHERE collection_name = 'dist_push_mk' AND database_name = 'dist_idx_db' \gset
ANALYZE documentdb_data.documents_:collection_id;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

-- Multikey from the start: Sort should be present
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_mk", "key": "arr" }')
$cmd$);
ROLLBACK;

-- Correctness
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_mk", "key": "arr" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_mk", "key": "arr" }');

-- ============================================================
-- Test 9: Sharded collection - distinct pushdown ON
-- Shard the collection and verify pushdown works per-shard
-- ============================================================
SELECT documentdb_api.create_collection('dist_idx_db', 'dist_push_sharded');
SELECT documentdb_api_internal.create_indexes_non_concurrently('dist_idx_db', '{ "createIndexes": "dist_push_sharded", "indexes": [ { "key": { "a": 1 }, "name": "idx_a" } ] }', true);

SELECT COUNT(documentdb_api.insert_one('dist_idx_db', 'dist_push_sharded', bson_build_document('_id', i, 'a', i % 10, 'b', chr(65 + (i % 5))))) FROM generate_series(1, 200) AS i;

SELECT documentdb_api.shard_collection('dist_idx_db', 'dist_push_sharded', '{ "_id": "hashed" }', false);

SELECT collection_id FROM documentdb_api_catalog.collections WHERE collection_name = 'dist_push_sharded' AND database_name = 'dist_idx_db' \gset
ANALYZE documentdb_data.documents_:collection_id;

SET citus.propagate_set_commands TO 'local';

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL citus.explain_analyze_sort_method TO taskId;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

-- Pushdown ON: each shard should use Index Scan with Order By, no Sort
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_sharded", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 10: Sharded collection - distinct pushdown OFF
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL citus.explain_analyze_sort_method TO taskId;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;

-- Pushdown OFF: Sort should be present in each shard's plan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_sharded", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 11: Sharded collection - correctness ON vs OFF
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_sharded", "key": "a" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_sharded", "key": "a" }');

-- ============================================================
-- Test 12: Sharded collection - distinct with filter
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_sharded", "key": "a", "query": { "a": { "$gte": 7 } } }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_sharded", "key": "a", "query": { "a": { "$gte": 7 } } }');

-- ============================================================
-- Test 13: Sharded collection - multikey blocks pushdown
-- ============================================================
SELECT documentdb_api.insert_one('dist_idx_db', 'dist_push_sharded', '{ "_id": 999, "a": [100, 200] }');
ANALYZE documentdb_data.documents_:collection_id;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL citus.explain_analyze_sort_method TO taskId;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

-- After multikey, Sort should reappear even with pushdown ON
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_idx_db', '{ "distinct": "dist_push_sharded", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Cleanup
-- ============================================================
SELECT documentdb_api.drop_collection('dist_idx_db', 'dist_push');
SELECT documentdb_api.drop_collection('dist_idx_db', 'dist_push_mk');
SELECT documentdb_api.drop_collection('dist_idx_db', 'dist_push_sharded');
