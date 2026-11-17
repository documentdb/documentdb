SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 29500;
SET documentdb.next_collection_index_id TO 29500;

SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

-- ============================================================================
-- Tests for the RUM index-only scan projection wrapper custom scan
-- (DocumentDBApiRumIndexOnlyScan). The wrapper is gated behind
-- documentdb.enable_rum_index_only_scan_projection_wrapper and, when enabled,
-- sits directly on top of an eligible RUM index-only scan. All data below is
-- scalar (no arrays) so the composite index stays non-multi-key and covered
-- count / count-like aggregates lower to an Index Only Scan.
-- ============================================================================

-- Non-multi-key composite index over (zone, band).
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumidxonly_db',
    '{ "createIndexes": "records", "indexes": [ { "key": { "zone": 1, "band": 1 }, "name": "idx_zone_band", "enableOrderedIndex": 1 } ] }', TRUE);

-- Seed scalar-only data. Wrapped in COUNT() to avoid per-row output spew.
SELECT COUNT(documentdb_api.insert_one('rumidxonly_db', 'records',
    ('{ "_id": ' || i::text ||
     ', "zone": "z' || (i % 4)::text || '"' ||
     ', "band": "b' || (i % 3)::text || '" }')::bson))
FROM generate_series(1, 200) i;

-- Scoped VACUUM (ANALYZE) so the visibility map is populated alongside fresh
-- statistics, keeping the index-only-scan plan choice stable across PostgreSQL
-- versions.
VACUUM (ANALYZE) documentdb_data.documents_29501;

-- ============================================================================
-- 1. Flag ON, extended explain OFF: covered count / count-like aggregates lower
--    to an Index Only Scan, which the wrapper (DocumentDBApiRumIndexOnlyScan)
--    wraps. Each query's result is printed and must be correct.
-- ============================================================================
SET documentdb.enable_rum_index_only_scan_projection_wrapper TO on;

-- 1a. count command over a covered equality filter.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }');

-- 1b. aggregate pipeline $match + $count.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('rumidxonly_db',
        '{ "aggregate": "records", "pipeline": [ { "$match": { "zone": "z2" } }, { "$count": "count" } ], "cursor": {}, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('rumidxonly_db',
    '{ "aggregate": "records", "pipeline": [ { "$match": { "zone": "z2" } }, { "$count": "count" } ], "cursor": {}, "hint": "idx_zone_band" }');

-- 1c. aggregate pipeline $match (range) + $count over a covered range bound.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('rumidxonly_db',
        '{ "aggregate": "records", "pipeline": [ { "$match": { "zone": { "$gte": "z1" } } }, { "$count": "count" } ], "cursor": {}, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('rumidxonly_db',
    '{ "aggregate": "records", "pipeline": [ { "$match": { "zone": { "$gte": "z1" } } }, { "$count": "count" } ], "cursor": {}, "hint": "idx_zone_band" }');

-- 1d. A covered $group { _id: 1, n: { $sum: 1 } } through the wrapper still
--     returns the correct grouped result (result-only; the GroupAggregate EXPLAIN
--     Group Key line is elided on some PostgreSQL versions, so plan shape is
--     asserted via the count-like cases above instead).
SELECT document FROM bson_aggregation_pipeline('rumidxonly_db',
    '{ "aggregate": "records", "pipeline": [ { "$match": { "zone": { "$gte": "z1" } } }, { "$group": { "_id": 1, "n": { "$sum": 1 } } } ], "cursor": {}, "hint": "idx_zone_band" }');

-- ============================================================================
-- 2. Flag ON, extended explain ON: the extended-explain wrapper
--    (DocumentDBApiExplainQueryScan) sits on top of the RUM index-only wrapper,
--    which in turn wraps the Index Only Scan. The nesting is visible in EXPLAIN.
-- ============================================================================
SET documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
RESET documentdb.enableExtendedExplainPlans;

-- ============================================================================
-- 3. Flag OFF: the same covered count still lowers to an Index Only Scan, but
--    it is NOT wrapped (no DocumentDBApiRumIndexOnlyScan node). This is the
--    contrast case proving the wrapper is gated by the feature flag.
-- ============================================================================
SET documentdb.enable_rum_index_only_scan_projection_wrapper TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);

-- ============================================================================
-- 4. A plain find returns the full document body, so it needs heap access and
--    does NOT lower to an Index Only Scan. With the flag ON the wrapper is
--    therefore absent -- it only wraps eligible index-only scan paths.
-- ============================================================================
SET documentdb.enable_rum_index_only_scan_projection_wrapper TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "zone": "z1", "band": "b1" }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
RESET documentdb.enable_rum_index_only_scan_projection_wrapper;

-- ============================================================================
-- 5. Flag ON, but the covered index-only scan carries a runtime residual filter:
--    the multi-key $in predicates supply the index bounds while the residual $or
--    of composite equalities lands in the scan's Filter. Because that filter is
--    evaluated at runtime against the reconstructed document, the wrapper must
--    NOT inject the index-projection-metadata clause (no @<> marker appears in
--    the Index Cond); the result count must still be correct.
-- ============================================================================
SET documentdb.enable_rum_index_only_scan_projection_wrapper TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "zone": { "$in": [ "z1", "z2" ] }, "band": { "$in": [ "b1", "b2" ] }, "$or": [ { "zone": "z1", "band": "b1" }, { "zone": "z2", "band": "b2" } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "zone": { "$in": [ "z1", "z2" ] }, "band": { "$in": [ "b1", "b2" ] }, "$or": [ { "zone": "z1", "band": "b1" }, { "zone": "z2", "band": "b2" } ] }, "hint": "idx_zone_band" }');
RESET documentdb.enable_rum_index_only_scan_projection_wrapper;

-- ============================================================================
-- 6. Flag ON, a $group with no accumulators (a distinct-style group by on the
--    leading indexed field). This is index-only-scan eligible, but the grouped
--    _id expression reads the field from the reconstructed document, so the raw
--    index tuple must NOT be projected. The plan lowers to a distinct query scan
--    over the Index Only Scan and NO index-projection-metadata (@<>) marker is
--    injected into the Index Cond; the distinct result must still be correct.
-- ============================================================================
SET documentdb.enable_rum_index_only_scan_projection_wrapper TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('rumidxonly_db',
        '{ "aggregate": "records", "pipeline": [ { "$group": { "_id": "$zone" } } ], "cursor": {}, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('rumidxonly_db',
    '{ "aggregate": "records", "pipeline": [ { "$group": { "_id": "$zone" } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "hint": "idx_zone_band" }');
RESET documentdb.enable_rum_index_only_scan_projection_wrapper;

-- Native path generation supplies a parallel IOS alternative with bitmap scans enabled.
ALTER TABLE documentdb_data.documents_29501 SET (parallel_workers = 2);
SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.enableDynamicCursors TO off;
SET documentdb.forceUseIndexIfAvailable TO off;
SET enable_bitmapscan TO on;
SET max_parallel_workers_per_gather TO 2;
SET min_parallel_table_scan_size TO 0;
SET min_parallel_index_scan_size TO 0;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
-- On PG19 this tiny fixture costs 10.18 for bitmap versus 10.59 for parallel IOS.
-- Lower random_page_cost for plan stability while keeping bitmap paths enabled.
SET random_page_cost TO 1;

SET documentdb.enable_native_planner_index_only_scan TO on;
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "zone": { "$gte": "z0" } } }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "zone": { "$gte": "z0" } } }');

RESET documentdb.enable_native_planner_index_only_scan;
RESET documentdb.enableCompositeParallelIndexScan;
RESET documentdb.enableDynamicCursors;
RESET documentdb.forceUseIndexIfAvailable;
RESET enable_bitmapscan;
RESET max_parallel_workers_per_gather;
RESET min_parallel_table_scan_size;
RESET min_parallel_index_scan_size;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET random_page_cost;

-- Object-ID support functions must not leave an object_id dependency on covered scans.
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.enable_support_function_id_pushdown TO on;
SET documentdb.enable_native_planner_index_only_scan TO on;
SET documentdb.forceIndexOnlyScanIfAvailable TO off;
SET documentdb.forceUseIndexIfAvailable TO off;
SET documentdb.enableDynamicCursors TO off;
SET max_parallel_workers_per_gather TO 0;
SET enable_bitmapscan TO off;

SELECT documentdb_api.insert_one('rumidxonly_db', 'records', '{ "_id": "Alpha", "zone": "z0", "band": "b0" }');
SELECT documentdb_api.insert_one('rumidxonly_db', 'records', '{ "_id": "alpha", "zone": "z0", "band": "b0" }');
SELECT documentdb_api.insert_one('rumidxonly_db', 'records', '{ "_id": "Beta", "zone": "z1", "band": "b1" }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumidxonly_db',
    '{ "createIndexes": "records", "indexes": [
        { "key": { "_id": 1, "zone": 1 }, "name": "idx_id_zone", "enableOrderedIndex": 1 },
        { "key": { "_id": 1, "zone": 1 }, "name": "idx_id_zone_ci", "enableOrderedIndex": 1, "collation": { "locale": "en", "strength": 1 } }
    ] }', TRUE);
VACUUM (ANALYZE) documentdb_data.documents_29501;

-- Equality, two-sided ranges, membership and regex all use covered object-ID predicates.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": 17 }, "hint": "idx_id_zone" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": 17 }, "hint": "idx_id_zone" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": { "$gte": 20, "$lt": 25 } }, "hint": "idx_id_zone" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": { "$gte": 20, "$lt": 25 } }, "hint": "idx_id_zone" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": { "$gt": 19, "$lte": 24 } }, "hint": "idx_id_zone" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": { "$gt": 19, "$lte": 24 } }, "hint": "idx_id_zone" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": { "$in": [17, 18, 19] } }, "hint": "idx_id_zone" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": { "$in": [17, 18, 19] } }, "hint": "idx_id_zone" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": { "$regex": "^alpha$" } }, "hint": "idx_id_zone" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": { "$regex": "^alpha$" } }, "hint": "idx_id_zone" }');

-- The rewritten equality must retain case-insensitive matching.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": "ALPHA" }, "hint": "idx_id_zone_ci", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": "ALPHA" }, "hint": "idx_id_zone_ci", "collation": { "locale": "en", "strength": 1 } }');

-- Neither an uncovered _id nor an uncovered additional filter may become index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": { "$gte": 20, "$lt": 25 }, "zone": "z0" }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": { "$gte": 20, "$lt": 25 }, "zone": "z0" }, "hint": "idx_zone_band" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('rumidxonly_db',
        '{ "count": "records", "query": { "_id": { "$gt": 189, "$lte": 199 }, "band": "b1" }, "hint": "idx_id_zone" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "records", "query": { "_id": { "$gt": 189, "$lte": 199 }, "band": "b1" }, "hint": "idx_id_zone" }');

-- Unhinted finds must choose covered paths without pruning competing scan alternatives.
SET enable_seqscan TO on;
SET enable_bitmapscan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "_id": { "$gte": 20, "$lt": 25 } }, "projection": { "_id": 1, "zone": 1 }, "sort": { "_id": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('rumidxonly_db',
    '{ "find": "records", "filter": { "_id": { "$gte": 20, "$lt": 25 } }, "projection": { "_id": 1, "zone": 1 }, "sort": { "_id": 1 } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "zone": "z1", "band": "b1" }, "projection": { "zone": 1, "band": 1, "_id": 0 }, "limit": 2 }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('rumidxonly_db',
    '{ "find": "records", "filter": { "zone": "z1", "band": "b1" }, "projection": { "zone": 1, "band": 1, "_id": 0 }, "limit": 2 }');

-- Leaving _id implicit requires coverage of that field too.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "zone": "z1", "band": "b1" }, "projection": { "zone": 1, "band": 1 }, "sort": { "_id": 1 }, "limit": 2 }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('rumidxonly_db',
    '{ "find": "records", "filter": { "zone": "z1", "band": "b1" }, "projection": { "zone": 1, "band": 1 }, "sort": { "_id": 1 }, "limit": 2 }');

-- An uncovered projected field or filter still requires the heap.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "_id": { "$gte": 20, "$lt": 25 } }, "projection": { "_id": 1, "band": 1 }, "sort": { "_id": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('rumidxonly_db',
    '{ "find": "records", "filter": { "_id": { "$gte": 20, "$lt": 25 } }, "projection": { "_id": 1, "band": 1 }, "sort": { "_id": 1 } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "_id": { "$gte": 20, "$lt": 25 }, "band": "b1" }, "projection": { "_id": 1, "zone": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('rumidxonly_db',
    '{ "find": "records", "filter": { "_id": { "$gte": 20, "$lt": 25 }, "band": "b1" }, "projection": { "_id": 1, "zone": 1 } }');

-- A collated index cannot reconstruct the original projected strings.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "_id": "ALPHA" }, "projection": { "zone": 1, "_id": 0 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('rumidxonly_db',
    '{ "find": "records", "filter": { "_id": "ALPHA" }, "projection": { "zone": 1, "_id": 0 }, "collation": { "locale": "en", "strength": 1 } }');

-- Returning the full document still requires the heap for the unindexed band field.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumidxonly_db',
        '{ "find": "records", "filter": { "_id": 17 } }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('rumidxonly_db',
    '{ "find": "records", "filter": { "_id": 17 } }');

RESET documentdb.enable_support_function_id_pushdown;
RESET documentdb_core.enableCollation;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.enable_native_planner_index_only_scan;
RESET documentdb.forceIndexOnlyScanIfAvailable;
RESET documentdb.forceUseIndexIfAvailable;
RESET documentdb.enableDynamicCursors;
RESET max_parallel_workers_per_gather;
RESET enable_seqscan;
RESET enable_bitmapscan;

-- An unbounded native IOS must retain sparse-hint inclusion semantics.
SET documentdb.enable_native_planner_index_only_scan TO on;
SET max_parallel_workers_per_gather TO 0;
SELECT documentdb_api.insert_one('rumidxonly_db', 'sparse_records', '{ "_id": 1, "a": 10 }');
SELECT documentdb_api.insert_one('rumidxonly_db', 'sparse_records', '{ "_id": 2, "a": null }');
SELECT documentdb_api.insert_one('rumidxonly_db', 'sparse_records', '{ "_id": 3 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumidxonly_db',
    '{ "createIndexes": "sparse_records", "indexes": [ { "key": { "b": 1 }, "name": "idx_other" } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumidxonly_db',
    '{ "createIndexes": "sparse_records", "indexes": [ { "key": { "a": 1 }, "name": "idx_sparse", "sparse": true } ] }', TRUE);

EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": {}, "hint": "idx_sparse" }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": {}, "hint": "idx_sparse" }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": {}, "hint": { "a": 1 } }');
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": { "a": 10 }, "hint": "idx_sparse" }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": { "a": 10 }, "hint": "idx_sparse" }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": { "a": null }, "hint": { "a": 1 } }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": {} }');

SET documentdb.enable_native_planner_index_only_scan TO off;
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": {}, "hint": "idx_sparse" }');

SET documentdb.enable_native_planner_index_only_scan TO on;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumidxonly_db',
    '{ "createIndexes": "sparse_records", "indexes": [ { "key": { "a": 1 }, "name": "idx_sparse_ci", "sparse": true, "collation": { "locale": "en", "strength": 1 } } ] }', TRUE);
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": {}, "hint": "idx_sparse_ci", "collation": { "locale": "en", "strength": 1 } }');
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": { "a": 10 }, "hint": "idx_sparse_ci", "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": { "a": 10 }, "hint": "idx_sparse_ci", "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_count('rumidxonly_db',
    '{ "count": "sparse_records", "query": {}, "hint": "idx_sparse_ci", "collation": { "locale": "en", "strength": 1 } }');
RESET documentdb.enable_native_planner_index_only_scan;
RESET documentdb_core.enableCollation;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET max_parallel_workers_per_gather;
