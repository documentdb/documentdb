SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 49500;
SET documentdb.next_collection_index_id TO 49500;

SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

-- ============================================================================
-- Order-by pushdown gating on a REDUCED-CORRELATED ordered composite index.
--
-- The collection carries a three-column ordered composite key:
--     [ arr.k, arr.v, s ]   with s as the trailing (ordered) sort key.
-- arr is an ARRAY, so arr.k and arr.v are MULTI-KEY paths and s is a scalar.
-- The index is built with reduced-correlated common-subpath terms, so it does
-- NOT store the full cross-product of (arr.k, arr.v) pairs. An intermediate
-- equality qual on the middle key (arr.v) is therefore only sound to keep when
-- the planner can certify it binds to the SAME array element as the leading
-- key; otherwise it is pruned at runtime and the middle key collapses to
-- (MinKey, MaxKey), leaving the trailing s key non-contiguous in index order.
--
-- The pushdown decision is gated by
-- enable_composite_reduced_correlated_bounds_planning:
--   * A single-element $elemMatch pins arr.k AND arr.v to one element. With the
--     flag ON the planner certifies the middle bound (rctBoundsPlanApplied) and
--     the trailing s order-by is served by the index order -- no Sort.
--   * With the flag OFF the middle bound cannot be certified, arr.v collapses to
--     (MinKey, MaxKey), and the s order-by MUST NOT be pushed -- an explicit
--     Sort is required for correctness.
-- Field names and values are neutral, and every query carries a "hint" so the
-- index choice is deterministic.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('rct_order_db',
    '{ "createIndexes": "coll", "indexes": [ { "key": { "arr.k": 1, "arr.v": 1, "s": -1 }, "name": "idx_rct", "enableOrderedIndex": 1 } ] }', TRUE);

-- Matching rows: arr = [ { k: "k1", v: "v1" } ].
SELECT COUNT(documentdb_api.insert_one('rct_order_db', 'coll',
    FORMAT('{ "_id": %s, "arr": [ { "k": "k1", "v": "v1" } ], "s": %s }', i, i * 10)::documentdb_core.bson))
FROM generate_series(1, 8) i;
-- Same leading key, different middle key: exercises the middle-key bound.
SELECT COUNT(documentdb_api.insert_one('rct_order_db', 'coll',
    FORMAT('{ "_id": %s, "arr": [ { "k": "k1", "v": "v2" } ], "s": %s }', 100 + i, i * 10)::documentdb_core.bson))
FROM generate_series(1, 4) i;

-- VACUUM (ANALYZE) the collection heap (scoped, not a bare global ANALYZE) so
-- the visibility map and statistics are populated and the plan choice is stable
-- across PostgreSQL versions.
VACUUM (ANALYZE) documentdb_data.documents_49501;

-- ============================================================================
-- 1. $elemMatch pins BOTH correlated keys to one array element + flag ON.
--    The planner certifies the middle bound (arr.v = ["v1","v1"],
--    rctBoundsPlanApplied) so the trailing s order-by is served by the index
--    order: expect the s "Order By" pushed onto the ordered Index Scan and NO
--    separate Sort node.
-- ============================================================================
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rct_order_db',
        '{ "find": "coll", "filter": { "arr": { "$elemMatch": { "k": "k1", "v": "v1" } } }, "sort": { "s": -1 }, "hint": "idx_rct" }')
$cmd$);
SELECT document FROM bson_aggregation_find('rct_order_db',
    '{ "find": "coll", "filter": { "arr": { "$elemMatch": { "k": "k1", "v": "v1" } } }, "sort": { "s": -1 }, "hint": "idx_rct" }');

-- ============================================================================
-- 2. Same $elemMatch query, flag OFF. The middle bound cannot be certified so
--    arr.v collapses to (MinKey, MaxKey) and the s order-by must NOT be pushed:
--    expect an explicit Sort above the ordered Index Scan and NO "Order By".
--    The returned rows are identical to section 1 -- only the plan differs.
-- ============================================================================
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rct_order_db',
        '{ "find": "coll", "filter": { "arr": { "$elemMatch": { "k": "k1", "v": "v1" } } }, "sort": { "s": -1 }, "hint": "idx_rct" }')
$cmd$);
SELECT document FROM bson_aggregation_find('rct_order_db',
    '{ "find": "coll", "filter": { "arr": { "$elemMatch": { "k": "k1", "v": "v1" } } }, "sort": { "s": -1 }, "hint": "idx_rct" }');

-- ============================================================================
-- 3. $elemMatch on the LEADING key only (middle key arr.v unconstrained) + flag
--    ON. There is no equality to certify for the middle key, so it collapses to
--    (MinKey, MaxKey) and the s order-by must NOT be pushed even with the flag
--    on: expect an explicit Sort and NO "Order By".
-- ============================================================================
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rct_order_db',
        '{ "find": "coll", "filter": { "arr": { "$elemMatch": { "k": "k1" } } }, "sort": { "s": -1 }, "hint": "idx_rct" }')
$cmd$);

-- ============================================================================
-- 4. Direct dotted-path equality on BOTH keys (NOT $elemMatch) + flag ON. A
--    dotted-path filter does not require the two keys to match the SAME array
--    element, so the middle bound still cannot be certified: arr.v collapses to
--    (MinKey, MaxKey) and the s order-by must NOT be pushed. This isolates
--    $elemMatch as the specific shape that certifies the middle bound.
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rct_order_db',
        '{ "find": "coll", "filter": { "arr.k": "k1", "arr.v": "v1" }, "sort": { "s": -1 }, "hint": "idx_rct" }')
$cmd$);

SELECT documentdb_api.drop_collection('rct_order_db', 'coll');
