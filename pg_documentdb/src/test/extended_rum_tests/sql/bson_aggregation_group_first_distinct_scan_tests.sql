SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

-- Composite op class required for RUM index to expose skip-tids primitive.
SET documentdb.defaultUseCompositeOpClass TO on;

-- Ensure database 'db' exists so the system sentinel does not consume a test
-- collection id when running in standalone mode.
SELECT documentdb_api.insert_one('db', 'setup_sentinel_first', '{ "_id": 0 }');
SELECT documentdb_api.drop_collection('db', 'setup_sentinel_first');

-- Use a fresh id range so this file does not collide with the sibling
-- bson_aggregation_group_distinct_scan_tests.sql (which uses 20000-range).
SET documentdb.next_collection_id TO 21000;
SET documentdb.next_collection_index_id TO 21000;

-- Primary collection: 8 documents with three distinct values of x in
-- insertion order. The first y-value seen per x (and thus what $first
-- should return when ordered by x) is:
--   a -> 10
--   b -> 20
--   c -> 40
-- The maximum y per x is:
--   a -> 60
--   b -> 80
--   c -> 70
-- This asymmetry makes the C3/C4 sort-aware $first tests "loud":
-- if the wrapper incorrectly fires, the result will be the insertion-
-- order first (10/20/40) instead of the sort-required first (60/80/70).
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 1, "x": "a", "y": 10 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 2, "x": "b", "y": 20 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 3, "x": "a", "y": 30 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 4, "x": "c", "y": 40 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 5, "x": "b", "y": 50 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 6, "x": "a", "y": 60 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 7, "x": "c", "y": 70 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first', '{ "_id": 8, "x": "b", "y": 80 }', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "grp_first", "indexes": [{ "key": { "x": 1 }, "name": "idx_x" }] }', true);

-- Composite index used by B8 / B10 (compound _id positive case + $match-before-
-- compound-$group correctness pin).
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "grp_first", "indexes": [{ "key": { "x": 1, "y": 1 }, "name": "idx_xy" }] }', true);

-- Wrong-index target for C10.
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "grp_first", "indexes": [{ "key": { "y": 1 }, "name": "idx_y" }] }', true);

-- Multikey collection for C6 (array-valued indexed field).
SELECT documentdb_api.insert_one('db', 'grp_first_mk', '{ "_id": 1, "tags": ["t1", "t2"], "v": 10 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_mk', '{ "_id": 2, "tags": ["t1"],       "v": 20 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_mk', '{ "_id": 3, "tags": ["t3", "t2"], "v": 30 }', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "grp_first_mk", "indexes": [{ "key": { "tags": 1 }, "name": "idx_tags" }] }', true);

-- Companion collection used by C9 ($unwind).
SELECT documentdb_api.insert_one('db', 'grp_first_unwind', '{ "_id": 1, "x": "a", "vals": [1, 2] }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_unwind', '{ "_id": 2, "x": "b", "vals": [3] }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_unwind', '{ "_id": 3, "x": "a", "vals": [4] }', NULL);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "grp_first_unwind", "indexes": [{ "key": { "x": 1 }, "name": "idx_x" }] }', true);

-- Companion collection used by B11 (partial-filter index used safely).
-- Distinct x = {a,b,c,d}; partial-visible subset under y>50 = {a,b,d}.
-- Only the safe shape ($match subsumes the partial filter) is tested;
-- the divergent shape (no $match) is a known hazard if the planner ever
-- lets the partial index serve a non-subsuming predicate.
SELECT documentdb_api.insert_one('db', 'grp_first_part', '{ "_id": 1, "x": "a", "y": 60 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_part', '{ "_id": 2, "x": "b", "y": 10 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_part', '{ "_id": 3, "x": "b", "y": 80 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_part', '{ "_id": 4, "x": "c", "y": 5 }', NULL);
SELECT documentdb_api.insert_one('db', 'grp_first_part', '{ "_id": 5, "x": "d", "y": 70 }', NULL);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "grp_first_part", "indexes": [{
     "key": { "x": 1 }, "name": "idx_x_partial",
     "partialFilterExpression": { "y": { "$gt": 50 } }
  }] }', true);

ANALYZE;

-- ============================================================
-- Group A — Feature flag interaction: confirm the new GUC
-- (enableDistinctScanForGroupFirst) and the pre-existing
-- enableGroupByDistinctScan GUC gate independent code paths.
-- ============================================================
-- ============================================================
-- A1: GUC off (default) + $first => plain IndexScan, rows=8.
-- Baseline: confirms nothing changes when the new GUC is off.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO off;
SET LOCAL documentdb.enableGroupByDistinctScan TO off;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- A2: enableGroupByDistinctScan ON, enableDistinctScanForGroupFirst OFF
-- => no-accumulator distinct scan fires for the bare $group; the
-- $first variant does NOT.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableGroupByDistinctScan TO on;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO off;

-- No-accumulator: wrapper must fire (rows=3 below the GroupAggregate).
SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x" } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);

-- $first: wrapper must NOT fire (rows=8 below the GroupAggregate).
SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- A3: enableDistinctScanForGroupFirst ON, enableGroupByDistinctScan OFF
-- Independence check: the new GUC fires for $first; the no-accumulator
-- variant remains plain (because its GUC is OFF).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableGroupByDistinctScan TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

-- No-accumulator $group: wrapper must NOT fire (rows=8 below).
SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x" } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);

-- $first: wrapper must fire (rows=3 below).
SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- Group B — Positive cases: with the GUC ON, the distinct-scan
-- wrapper must fire for safe $first shapes and produce correct
-- per-group results.
-- ============================================================
-- ============================================================
-- B1: Core positive case. Wrapper fires, picks insertion-order first
-- per group: a -> 10, b -> 20, c -> 40.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

-- Correctness: must return a->10, b->20, c->40.
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

-- EXPLAIN: Custom Scan rows=3, IndexScan rows=3 (skip-tids).
SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B2: Two $first on different fields. Both must come from the SAME
-- first row per group: a -> (y=10, _id=1), b -> (y=20, _id=2),
-- c -> (y=40, _id=4).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" }, "g": { "$first": "$_id" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" }, "g": { "$first": "$_id" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B3: $first of an expression argument. Wrapper must still fire
-- because the OID gate looks at the aggregate function id, not at
-- the argument shape.
-- Expected: a -> "a-", b -> "b-", c -> "c-".
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": { "$concat": ["$x", "-"] } } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": { "$concat": ["$x", "-"] } } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B4: $match on a non-indexed field then $group/$first. The y>=20
-- filter runs per heap tuple (Rows Removed by Filter > 0: the y=10
-- row in group "a" is filtered, leaving y in {30,60} so $first
-- becomes 30). The wrapper still fires on top of the IndexScan.
-- Expected: a->30, b->20, c->40.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$match": { "y": { "$gte": 20 } } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$match": { "y": { "$gte": 20 } } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B5: $skip / $sort / $limit AFTER $group/$first. Wrapper still
-- fires on the inner scan; downstream stages operate on grouped output.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } },
    { "$skip": 1 },
    { "$limit": 1 }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } },
    { "$skip": 1 },
    { "$limit": 1 }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B6: enable_hashagg ON, $first scenario. The planner must still pick
-- sorted GroupAggregate WITH the wrapper underneath (rather than
-- HashAgg), because HashAgg cannot benefit from per-key TID skipping
-- (its input order is irrelevant to it).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO on;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B7: Same shape as C11 ($sort on the GROUP KEY alone, then $group
-- with $first), but with enableSortPushToAccumulatorWithPrefix ON.
-- The rewrite sees groupKeysFormSortPrefix=true and hasSuffixSort=false,
-- so the Sort node is dropped and NOTHING is pushed into the
-- accumulator. $first stays as the plain (non-sort-aware) variant,
-- the walker accepts, and the wrapper MUST fire.
-- Correctness: a -> 10, b -> 20, c -> 40.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "x": 1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

-- EXPLAIN: Custom Scan rows=3, IndexScan rows=3 (skip-tids).
SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "x": 1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B8: Compound _id constructor ({ x: "$x", y: "$y" }) over the
-- composite index idx_xy, with enableGroupByCompoundIdIndexPushdown
-- ON. The aggregation rewriter decomposes the compound _id into
-- per-field GROUP BY expressions, the planner lines them up with the
-- per-column index orderbys, and the wrapper MUST fire. Each compound
-- group has exactly one document, so $first picks that document.
-- Correctness: 8 distinct (x, y) groups -> _ids 1, 3, 6, 2, 5, 8, 4, 7.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb_core.enableWriteDocumentsInRepath TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_xy", "pipeline": [
    { "$group": { "_id": { "x": "$x", "y": "$y" }, "f": { "$first": "$_id" } } },
    { "$sort": { "_id.x": 1, "_id.y": 1 } }
  ] }');

-- EXPLAIN: Custom Scan rows=8, IndexScan rows=8 (skip-tids), and the
-- Group Key shows two flattened bson_expression_get columns (one per
-- compound _id field) rather than a single opaque compound expression.
SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_xy", "pipeline": [
    { "$group": { "_id": { "x": "$x", "y": "$y" }, "f": { "$first": "$_id" } } },
    { "$sort": { "_id.x": 1, "_id.y": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B9: $lookup AFTER $group/$first -- wrapper fires on the inner
-- scan; lookup runs on the 3 grouped rows.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$lookup": { "from": "grp_first", "as": "m", "localField": "_id", "foreignField": "x" } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$lookup": { "from": "grp_first", "as": "m", "localField": "_id", "foreignField": "x" } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B10: $match + COMPOUND $group/$first on idx_xy. Predicate on
-- _id (not an idx_xy key) survives as residual Filter above the
-- IndexScan; pins Rows Removed by Filter > 0 so the wrapper's
-- key-skip can't precede the filter on the compound-key path.
-- Compound-key analog of B4. Expect 5 distinct (x,y) for _ids 4..8.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb_core.enableWriteDocumentsInRepath TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_xy", "pipeline": [
    { "$match": { "_id": { "$gt": 3 } } },
    { "$group": { "_id": { "x": "$x", "y": "$y" }, "f": { "$first": "$_id" } } },
    { "$sort": { "_id.x": 1, "_id.y": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_xy", "pipeline": [
    { "$match": { "_id": { "$gt": 3 } } },
    { "$group": { "_id": { "x": "$x", "y": "$y" }, "f": { "$first": "$_id" } } },
    { "$sort": { "_id.x": 1, "_id.y": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- B11: Partial-filter index used SAFELY -- $match {y>50}
-- subsumes the partial predicate, so distinct over x is sound.
-- Without the match the planner declines this index (which would
-- silently drop {c}).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first_part", "hint": "idx_x_partial", "pipeline": [
    { "$match": { "y": { "$gt": 50 } } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first_part", "hint": "idx_x_partial", "pipeline": [
    { "$match": { "y": { "$gt": 50 } } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- Group C — Negative cases: shapes where the wrapper MUST NOT
-- fire (walker guards, path-shape guards, current limitations).
-- Each case asserts the expected fallback plan shape and, where
-- applicable, that the correctness output is still right.
-- ============================================================
-- ============================================================
-- C1: $first MIXED with $sum. Walker rejects because $sum's Aggref
-- is not a $first-variant OID. Wrapper must NOT fire (inner rows=8).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" }, "s": { "$sum": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C2: Only non-$first accumulators. Walker rejects (no $first
-- present). Wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "s": { "$sum": "$y" }, "m": { "$max": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C3: $sort on a NON-group field followed by $group/$first. This
-- routes $first to the sort-aware BsonFirstAggregateFunctionOid,
-- which the walker EXPLICITLY rejects. Wrapper must NOT fire.
--
-- Loudness: the sort-aware result for $sort: { y: -1 } is
-- a -> 60, b -> 80, c -> 70 (max y per group). If the wrapper
-- incorrectly fired and picked insertion-order first, the result
-- would be a -> 10, b -> 20, c -> 40 — a visible diff in both
-- the correctness output and the EXPLAIN actual rows.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "y": -1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "y": -1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C4: $sort prefix matches the group key, suffix on another field.
-- With enableSortPushToAccumulatorWithPrefix ON, the rewrite drops the
-- prefix (group key already covered by idx_x) and pushes the suffix into
-- the accumulator as bsonfirstonsorted(... ORDER BY bson_orderby(...)).
-- The OID is in our allowlist, so the OID check passes; aggref->aggorder
-- is non-NIL, so the walker rejects on the aggorder guard. This case
-- exercises the second guard rather than the OID check.
--
-- Loudness: the sort-aware result for $sort: { x: 1, y: -1 } is
-- a -> 60, b -> 80, c -> 70. A regression where the walker missed
-- the aggorder guard would return a -> 10, b -> 20, c -> 40.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "x": 1, "y": -1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "x": 1, "y": -1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C5: Constant group key ($group: { _id: null, ... }). The planner
-- emits an empty group_pathkeys list, which the hook guards against.
-- Wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": null, "f": { "$first": "$y" } } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C6: Array-valued group key. Grouping by the full array expression is not
-- presorted by the index's element-wise ordering, so the aggregate input gets
-- an explicit Sort and the wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first_mk", "hint": "idx_tags", "pipeline": [
    { "$group": { "_id": "$tags", "f": { "$first": "$v" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C7: $skip BEFORE $group/$first changes input cardinality before
-- the group, so the wrapper would observe skipped TIDs incorrectly.
-- It must NOT fire here.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$skip": 2 },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$skip": 2 },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C8: $limit BEFORE $group/$first. Same reasoning as C7.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$limit": 4 },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$limit": 4 },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C9: $unwind BEFORE $group/$first. Unwind expands array values
-- into separate rows; per-TID skip would miss array elements.
-- Wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first_unwind", "hint": "idx_x", "pipeline": [
    { "$unwind": "$vals" },
    { "$group": { "_id": "$x", "f": { "$first": "$vals" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first_unwind", "hint": "idx_x", "pipeline": [
    { "$unwind": "$vals" },
    { "$group": { "_id": "$x", "f": { "$first": "$vals" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C10: Hint targets a non-group-key index (idx_y) while grouping
-- on $x with $first. The scan is not ordered by the group key, so
-- the wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_y", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C11: Leading $sort on the GROUP KEY before $group with $first.
-- AnalyzeSortGroupAccumulators does NOT drop this sort; it pushes the
-- sort spec into the accumulator, converting $first to the sort-aware
-- bsonfirst(...) variant. The walker rejects sort-aware bsonfirst.
-- Wrapper must NOT fire. Output is still correct (a->10, b->20, c->40)
-- but only because insertion order matches $sort:{x:1} order.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "x": 1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$sort": { "x": 1 } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C12: $project select-only still interposes bson_dollar_project();
-- group key is no longer a direct Var on the indexed column.
-- Wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$project": { "x": 1, "_id": 0 } },
    { "$group": { "_id": "$x", "f": { "$first": "$x" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$project": { "x": 1, "_id": 0 } },
    { "$group": { "_id": "$x", "f": { "$first": "$x" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C13: $project RENAMES the indexed field; group key isn't the
-- indexed Var. Wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$project": { "newx": "$x", "_id": 0 } },
    { "$group": { "_id": "$newx", "f": { "$first": "$newx" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$project": { "newx": "$x", "_id": 0 } },
    { "$group": { "_id": "$newx", "f": { "$first": "$newx" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C14: $project with a COMPUTED group key ($concat); not a direct
-- Var on the indexed column. Wrapper must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$project": { "xc": { "$concat": ["$x", "-suffix"] }, "_id": 0 } },
    { "$group": { "_id": "$xc", "f": { "$first": "$xc" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$project": { "xc": { "$concat": ["$x", "-suffix"] }, "_id": 0 } },
    { "$group": { "_id": "$xc", "f": { "$first": "$xc" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- C15: $lookup BEFORE $group/$first -- join can fan out base
-- rows, so TID skipping would silently drop joined rows. Wrapper
-- must NOT fire.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$lookup": { "from": "grp_first", "as": "m", "localField": "x", "foreignField": "x" } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$lookup": { "from": "grp_first", "as": "m", "localField": "x", "foreignField": "x" } },
    { "$group": { "_id": "$x", "f": { "$first": "$y" } } },
    { "$sort": { "_id": 1 } }
  ] }')
$Q$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================
-- Group D — Result equivalence: same pipeline with the GUC OFF
-- vs ON must produce byte-identical output.
-- ============================================================
-- ============================================================
-- D1: Result-equivalence pin. Same pipeline executed with the new
-- GUC OFF and ON in adjacent transactions must return byte-identical
-- documents. This guards against any regression that would otherwise
-- silently change the picked document while still parsing-correctly.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO off;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" }, "g": { "$first": "$_id" } } },
    { "$sort": { "_id": 1 } }
  ] }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctScanForGroupFirst TO on;

SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "grp_first", "hint": "idx_x", "pipeline": [
    { "$group": { "_id": "$x", "f": { "$first": "$y" }, "g": { "$first": "$_id" } } },
    { "$sort": { "_id": 1 } }
  ] }');
ROLLBACK;
