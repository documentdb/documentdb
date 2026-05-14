SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal,public;

SET documentdb.next_collection_id TO 9300;
SET documentdb.next_collection_index_id TO 9300;

-- ================================================================
-- Note on what this test does NOT cover
-- ================================================================
-- This file validates plan shape (Section 2 EXPLAINs) and result correctness
-- (Section 1 / 3 SQL output) of the
-- documentdb.enableSortPushToAccumulatorWithPrefix optimization.
--
-- The runtime *win* of that optimization for the (sort{a,b}, group{a},
-- $first) shape on idx_a vs idx_a_b is NOT visible here, because the
-- per-group ORDER BY inside bsonfirstwithexpr is handled by the aggregate's
-- internal tuplesort, which PostgreSQL does not surface in EXPLAIN output
-- (no Sort node, no `Sort Method:` line, even with EXPLAIN ANALYZE).
--
-- For wall-clock measurement, see the companion microbenchmark:
--   test/microbenchmarks/sort_group_commonprefix_first.sql
--   test/microbenchmarks/sort_group_commonprefix_first_core.sql
--
-- ================================================================
-- Setup: create collection and insert test data
-- ================================================================
set documentdb.defaultUseCompositeOpClass to on;
-- 'c' is unique per row (i) so tests with sort{a,b,c} have no ties on
-- (a,b,c). This keeps the suffix push for tests 1.4-1.6 meaningful (c still
-- has many distinct values per (a,b) group) while making OFF/ON results
-- deterministic. Tests 1.1-1.3 (sort{a,b}, suffix=b) still see OFF/ON
-- divergence because b only takes two values; that is the expected behaviour
-- of $first on a tied prefix and is documented in the comment above.
SELECT COUNT(documentdb_api.insert_one('db', 'cpfx_test', bson_build_document(
    '_id', i,
    'a', chr(65 + (i % 3)),
    'b', chr(88 + (i % 2)),
    'c', i,
    'v', i * 10,
    'name', concat('name_', i)
))) FROM generate_series(1, 100) AS i;

-- Create indexes for various scenarios
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "cpfx_test", "indexes": [ { "key": { "a": 1 }, "name": "idx_a" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "cpfx_test", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "idx_a_b" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "cpfx_test", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "idx_a_b_c" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "cpfx_test", "indexes": [ { "key": { "a.x": 1 }, "name": "idx_ax" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "cpfx_test", "indexes": [ { "key": { "a.x": 1, "b": 1 }, "name": "idx_ax_b" } ] }', true);

-- Separate collection used only by tests 1.12 / 2.12 to exercise dotted sort
-- suffix push ("b.y"). Kept apart from cpfx_test so the rest of the suite is
-- unaffected by these documents. Created after cpfx_test indexes so cpfx_test
-- keeps its original collection / index id sequence.
SELECT COUNT(documentdb_api.insert_one('db', 'cpfx_test_by', bson_build_document(
    '_id', i,
    'a', chr(65 + (i % 3)),
    'b', bson_build_document('y', i % 4),
    'c', i % 5,
    'name', concat('byname_', i)
))) FROM generate_series(0, 9) AS i;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableSortGroupStage TO on;
SET LOCAL documentdb.enableNewWithExprAccumulators TO on;
-- Required by tests that use enableGroupByCompoundIdIndexPushdown (1.5, 1.10,
-- 2.5, 2.10). Set once here since SET LOCAL persists for the transaction.
SET LOCAL documentdb_core.enableWriteDocumentsInRepath TO on;
ANALYZE documentdb_data.documents_9300;
-- The b.y collection is created right after cpfx_test so it gets the next
-- collection id; analyze it here so 1.12 / 2.12 plans are stable.
ANALYZE documentdb_data.documents_9301;

-- ================================================================
-- SECTION 1: SQL result tests (data correctness)
-- Each test pair: first with enableSortPushToAccumulatorWithPrefix OFF, then ON
-- ================================================================

-- ----------------------------------------------------------------
-- 1.1 Single-field group: sort{a,b}, group{a}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 1.2 Single-field group: sort{a,b}, group{a}, $first — hint idx_a
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

-- ----------------------------------------------------------------
-- 1.3 Single-field group: sort{a,b}, group{a}, $first — hint idx_a_b
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 1.4 Multi-field group: sort{a,b,c}, group{a,b}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 1.5 Multi-field group: sort{a,b,c}, group{a,b}, $first — hint idx_a_b
--     (enableGroupByCompoundIdIndexPushdown required)
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 1.6 Multi-field group: sort{a,b,c}, group{a,b}, $first — hint idx_a_b_c
--     (enableGroupByCompoundIdIndexPushdown required)
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b_c" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b_c" }');

-- ----------------------------------------------------------------
-- 1.7 Sort and group match exactly: sort{a}, group{a}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 1.8 Sort and group match exactly: sort{a}, group{a}, $first — hint idx_a
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

-- ----------------------------------------------------------------
-- 1.9 Sort and group match exactly: sort{a,b}, group{a,b}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 1.10 Sort and group match exactly: sort{a,b}, group{a,b}, $first — hint idx_a
--      (enableGroupByCompoundIdIndexPushdown required)
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

-- ----------------------------------------------------------------
-- 1.11 Sort and group match exactly: sort{a,b}, group{a,b}, $first — hint idx_a_b
--      (enableGroupByCompoundIdIndexPushdown required)
--      Sort matches group exactly so the bsonfirstwithexpr ORDER BY clause is
--      empty (no suffix to push). The plan still changes when ON: the compound
--      group key is split into per-field expressions and the Subquery wrapper
--      is removed (see 2.11). Results are unaffected.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 1.12 Dotted sort key, non-dotted group: sort{a, b.y}, group{a}, $first — hint _id_
--      Dots in sort keys are fine; only group key dots are rejected.
--      Optimization SHOULD apply (suffix key is "b.y").
--      Uses cpfx_test_by which has real nested b.y values so the result
--      actually depends on the suffix being pushed into the accumulator.
--      Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test_by", "pipeline": [
        { "$sort": { "a": 1, "b.y": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test_by", "pipeline": [
        { "$sort": { "a": 1, "b.y": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 1.13 Single-field group: sort{a,b}, group{a}, $first — forces HashAgg.
--      Enables hashagg and disables sort/group-agg paths so the planner
--      picks a HashAgg node instead of the GroupAggregate that the rest of
--      this suite exercises. Validates the optimization still produces
--      correct results when the group is computed via hashing (which loses
--      the input ordering, so $first on the suffix relies on the
--      accumulator-internal ORDER BY).
-- ----------------------------------------------------------------
SET LOCAL enable_hashagg TO on;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');
RESET enable_hashagg;
RESET enable_sort;
-- Restore the suite-wide settings cleared above.
SET LOCAL enable_hashagg TO off;

-- ----------------------------------------------------------------
-- 1.14 Multi-field group: sort{a,b,c}, group{a,b}, $first — forces HashAgg.
--      Same HashAgg-forcing knobs as 1.13, but with a compound _id. When the
--      optimization is ON, the planner rewrites the compound _id into
--      per-field group keys (see 2.5 / 2.11 ON for the bson_repath_and_build
--      shape); this test confirms that rewrite still produces correct results
--      under hashed aggregation. Requires enableGroupByCompoundIdIndexPushdown.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL enable_hashagg TO on;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');
RESET enable_hashagg;
RESET enable_sort;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
-- Restore the suite-wide settings cleared above.
SET LOCAL enable_hashagg TO off;

-- ----------------------------------------------------------------
-- 1.15 Single-field group: sort{a,b}, group{a}, $first — forces HashAgg
--      with hint idx_a_b. Unlike 1.13 (hint _id_), the index already
--      provides the (a,b) order so OFF can feed HashAgg directly from the
--      Index Scan with no intermediate Sort. ON forces GroupAggregate (the
--      bsonfirstwithexpr ORDER BY disqualifies HashAgg), which is the
--      pessimization scenario — OFF would have used a cheaper HashAgg-on-
--      indexed-scan plan.
-- ----------------------------------------------------------------
SET LOCAL enable_hashagg TO on;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');
RESET enable_hashagg;
RESET enable_sort;
-- Restore the suite-wide settings cleared above.
SET LOCAL enable_hashagg TO off;


-- ================================================================
-- SECTION 2: EXPLAIN tests (plan shape validation)
-- Each test pair: first with enableSortPushToAccumulatorWithPrefix OFF, then ON
-- ================================================================

-- ----------------------------------------------------------------
-- 2.1 Single-field group: sort{a,b}, group{a}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 2.2 Single-field group: sort{a,b}, group{a}, $first — hint idx_a
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

-- ----------------------------------------------------------------
-- 2.3 Single-field group: sort{a,b}, group{a}, $first — hint idx_a_b
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 2.4 Multi-field group: sort{a,b,c}, group{a,b}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 2.5 Multi-field group: sort{a,b,c}, group{a,b}, $first — hint idx_a_b
--     (enableGroupByCompoundIdIndexPushdown required)
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 2.6 Multi-field group: sort{a,b,c}, group{a,b}, $first — hint idx_a_b_c
--     (enableGroupByCompoundIdIndexPushdown required)
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b_c" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b_c" }');

-- ----------------------------------------------------------------
-- 2.7 Sort and group match exactly: sort{a}, group{a}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 2.8 Sort and group match exactly: sort{a}, group{a}, $first — hint idx_a
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

-- ----------------------------------------------------------------
-- 2.9 Sort and group match exactly: sort{a,b}, group{a,b}, $first — hint _id_
--     Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 2.10 Sort and group match exactly: sort{a,b}, group{a,b}, $first — hint idx_a
--      (enableGroupByCompoundIdIndexPushdown required)
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

-- ----------------------------------------------------------------
-- 2.11 Sort and group match exactly: sort{a,b}, group{a,b}, $first — hint idx_a_b
--      (enableGroupByCompoundIdIndexPushdown required)
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 2.12 Dotted sort key, non-dotted group: sort{a, b.y}, group{a}, $first — hint _id_
--      Optimization SHOULD apply (suffix key is "b.y").
--      Uses cpfx_test_by which has real nested b.y values.
--      Forces _id_ index so planner cannot pick a useful index.
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test_by", "pipeline": [
        { "$sort": { "a": 1, "b.y": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test_by", "pipeline": [
        { "$sort": { "a": 1, "b.y": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 2.13 Single-field group: sort{a,b}, group{a}, $first — forces HashAgg.
--      Same setup as 1.13: enable hashagg and disable sort to force the
--      planner to choose a HashAgg over the GroupAggregate path. Validates
--      that the optimization plan still wires the suffix sort through the
--      $first accumulator under hashed aggregation.
-- ----------------------------------------------------------------
SET LOCAL enable_hashagg TO on;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }')
$cmd$);

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }')
$cmd$);
RESET enable_hashagg;
RESET enable_sort;
-- Restore the suite-wide settings cleared above.
SET LOCAL enable_hashagg TO off;

-- ----------------------------------------------------------------
-- 2.14 Multi-field group: sort{a,b,c}, group{a,b}, $first — forces HashAgg.
--      Companion EXPLAIN for 1.14. Validates the plan shape under hashed
--      aggregation with a compound _id: OFF should keep the original
--      compound group-key + bsonfirst(sortspec[]) shape feeding HashAgg; ON
--      should split _id into per-field keys and use bsonfirstwithexpr with
--      the suffix ORDER BY (which forces GroupAggregate rather than
--      HashAgg — see 2.13 commentary).
-- ----------------------------------------------------------------
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL enable_hashagg TO on;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }')
$cmd$);

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }')
$cmd$);
RESET enable_hashagg;
RESET enable_sort;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
-- Restore the suite-wide settings cleared above.
SET LOCAL enable_hashagg TO off;

-- ----------------------------------------------------------------
-- 2.15 Single-field group: sort{a,b}, group{a}, $first — forces HashAgg
--      with hint idx_a_b. Companion EXPLAIN for 1.15. Expected shape:
--        OFF: HashAggregate -> Subquery Scan -> Index Scan using idx_a_b
--             (no Sort — the index already provides (a,b) order).
--        ON : GroupAggregate -> Index Scan using idx_a_b
--             (HashAgg disqualified by the per-aggregate ORDER BY on the
--             rewritten bsonfirstwithexpr; see 2.13 commentary).
--      This documents that the optimization is a pessimization here:
--      the OFF plan could have used HashAgg fed directly by the index.
-- ----------------------------------------------------------------
SET LOCAL enable_hashagg TO on;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');
RESET enable_hashagg;
RESET enable_sort;
-- Restore the suite-wide settings cleared above.
SET LOCAL enable_hashagg TO off;


-- ================================================================
-- SECTION 3: Negative tests — optimization must NOT apply
-- All run with enableSortPushToAccumulatorWithPrefix ON to confirm
-- the optimization correctly does nothing in these cases.
-- ================================================================
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET LOCAL documentdb.enableSortPushToAccumulatorWithPrefix TO on;

-- ----------------------------------------------------------------
-- 3.1 Group key is NOT a prefix of sort: sort{a,b}, group{b} — $first
--     Group on "b" but sort starts with "a", so no prefix match.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$b", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$b", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 3.2 Sort is a prefix of group (reversed): sort{a}, group{a,b} — $first
--     Sort has fewer keys than group, so there are no suffix keys to push.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a" }');

-- ----------------------------------------------------------------
-- 3.3 $natural sort — cannot be pushed to accumulator
--     $natural uses ctid ordering which aggorder cannot express.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "$natural": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "$natural": 1 } },
        { "$group": { "_id": "$a", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "_id_" }');

-- ----------------------------------------------------------------
-- 3.4 Dotted scalar group-by: sort{a.x, b}, group{"$a.x"}, $first
--     Group key "a.x" contains a dot — TryBuildSuffixSortSpec rejects it.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a.x": 1, "b": 1 } },
        { "$group": { "_id": "$a.x", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_ax" }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a.x": 1, "b": 1 } },
        { "$group": { "_id": "$a.x", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_ax" }');

-- ----------------------------------------------------------------
-- 3.5 Dotted compound group-by: sort{a.x, b, c}, group{ax: "$a.x", b: "$b"}, $first
--     One compound _id field path ("a.x") contains a dot — rejected.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a.x": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "ax": "$a.x", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_ax_b" }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a.x": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "ax": "$a.x", "b": "$b" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_ax_b" }');

-- ----------------------------------------------------------------
-- 3.6 Variable-reference group-by: sort{a, b}, group{"$$ROOT"}, $first
--     The _id is a variable reference (path[1] == '$'), not a field path,
--     so TryBuildSuffixSortSpec must reject it and the plan should fall
--     back to the standard $sort + $group shape (no suffix push, no
--     accumulator-internal ORDER BY).
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$$ROOT", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": "$$ROOT", "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

-- ----------------------------------------------------------------
-- 3.7 Variable-reference in compound group-by: sort{a, b},
--     group{ a: "$a", r: "$$ROOT" }, $first
--     Per-entry guard in the BSON_TYPE_DOCUMENT branch must reject the
--     "$$ROOT" entry (path[1] == '$'), so the whole compound _id is rejected
--     and the plan falls back to the standard $sort + $group shape.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "r": "$$ROOT" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "cpfx_test", "pipeline": [
        { "$sort": { "a": 1, "b": 1 } },
        { "$group": { "_id": { "a": "$a", "r": "$$ROOT" }, "firstVal": { "$first": "$name" } } }
    ], "cursor": {}, "hint": "idx_a_b" }');

ROLLBACK;

-- Cleanup
SELECT documentdb_api.drop_collection('db', 'cpfx_test');
SELECT documentdb_api.drop_collection('db', 'cpfx_test_by');
