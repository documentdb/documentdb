SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal,public;

-- ============================================================
-- Setup: a collection whose leading index key is the distinct
-- path and a secondary key carries a range filter. The
-- distinct-exists filter lowers to "distinctPath >= MinKey" so the
-- ordered index can be used even when the distinct path itself has
-- no equality/range bound in the query.
-- ============================================================
SET documentdb.defaultUseCompositeOpClass TO on;

SELECT documentdb_api.insert_one('db', 'setup_sentinel_distinct_exists', '{ "_id": 0 }');
SELECT documentdb_api.drop_collection('db', 'setup_sentinel_distinct_exists');

SET documentdb.next_collection_id TO 90200;
SET documentdb.next_collection_index_id TO 90200;

-- Leading key is the distinct path (category), secondary key is the range path (ts).
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_exists", "indexes": [ { "key": { "category": 1, "ts": 1 }, "name": "idx_category_ts" } ] }', true);

SELECT COUNT(documentdb_api.insert_one('db', 'dist_exists', bson_build_document('_id', i, 'category', i % 8, 'ts', i, 'extra', concat('data_', i)))) FROM generate_series(1, 400) AS i;

ANALYZE;

-- ============================================================
-- Test 1: distinct with a range filter, exists-filter pushdown ON.
-- The distinct-exists filter is appended and lowered to a
-- "category >= MinKey" index condition, so the ordered index is used.
-- ============================================================
BEGIN;
SET LOCAL documentdb.enable_distinct_exists_filter_pushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 2: same distinct, exists-filter pushdown OFF.
-- No distinct-exists filter is appended.
-- ============================================================
BEGIN;
SET LOCAL documentdb.enable_distinct_exists_filter_pushdown TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 3: correctness - the distinct results are identical whether
-- the exists filter is on or off (documents without the path
-- contribute no distinct value, so filtering them changes nothing).
-- ============================================================
SET documentdb.enable_distinct_exists_filter_pushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }');

SET documentdb.enable_distinct_exists_filter_pushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }');

RESET documentdb.enable_distinct_exists_filter_pushdown;

-- ============================================================
-- Test 4: documents missing the distinct path are excluded by the
-- exists filter but were never part of distinct output anyway.
-- ============================================================
SELECT documentdb_api.insert_one('db', 'dist_exists', '{ "_id": 5001, "ts": 500 }');

SET documentdb.enable_distinct_exists_filter_pushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 490 } } }');

SET documentdb.enable_distinct_exists_filter_pushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 490 } } }');

RESET documentdb.enable_distinct_exists_filter_pushdown;

-- ============================================================
-- Test 5: scan-type validation matrix. With the exists-filter pushdown
-- ON, verify how the distinct-exists marker renders across scan types:
--   * Index / Bitmap Index scans: lowered to "category >= MinKey"
--     and pushed to the index (not a runtime FuncExpr recheck).
--   * Seq scans: trimmed entirely (distinct already drops docs that
--     are missing the path, so no runtime filter is needed).
-- ============================================================
SET documentdb.enable_distinct_exists_filter_pushdown TO on;

-- 5a: Index Scan - exists lowered to "category >= MinKey" on the index.
BEGIN;
SET LOCAL enable_indexonlyscan TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

-- 5b: Bitmap Heap Scan (serial) - the recheck uses the lowered OpExpr,
-- matching the bitmap index cond, and there is no distinct-exists FuncExpr.
BEGIN;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

-- 5c: Parallel Bitmap Heap Scan - same lowered OpExpr recheck under parallelism.
BEGIN;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_seqscan TO off;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

-- 5d: Seq Scan - the distinct-exists marker is trimmed (only the ts filter remains).
BEGIN;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

-- 5e: Parallel Seq Scan - the marker is trimmed under parallelism too.
BEGIN;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

-- 5f: correctness parity across the forced scan types (the trimmed seq
-- scan must still exclude the missing-path _id 5001 doc inserted above).
BEGIN;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_seqscan TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }');
ROLLBACK;

BEGIN;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }');
ROLLBACK;

-- 5g: Parallel Index Scan - the lowered "category >= MinKey" bound (injected
-- at the parser into the base restriction) survives on the parallel index
-- sibling, so the parallel index path carries the same Index Cond as the
-- serial one. Unlike the old in-place index-clause mutation, a base
-- restriction is distributed to every sibling path by the core planner, so no
-- shared-list copy is needed for the boundary to reach the parallel scan.
BEGIN;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enableCompositeParallelIndexScan TO on;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_exists", "key": "category", "query": { "ts": { "$gte": 100 } } }')
$cmd$);
ROLLBACK;

RESET documentdb.enable_distinct_exists_filter_pushdown;
