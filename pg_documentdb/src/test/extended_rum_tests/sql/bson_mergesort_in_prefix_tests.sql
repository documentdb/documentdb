-- Tests for merge-sort pushdown when an $in filter is an equality prefix of the
-- sort key on a composite index. The optimization issues one ordered index scan
-- per $in value (cartesian product across multiple $in prefix columns) and merges
-- them with a MergeAppend so the requested order is satisfied by the index instead
-- of a blocking Sort. Gated by documentdb.enable_merge_sort_for_in_prefix (default off).
--
-- This suite uses the order-capable extended_rum index AM, which is required for
-- the suffix order-by pushdown that the rewrite depends on.
--
-- Assertion strategy:
--   * Correctness checks compare result ordering and are independent of the plan
--     that is chosen.
--   * "Feature ON" plan-shape checks that lack a LIMIT run with enable_sort = off
--     so the assertion isolates "is a valid ordered MergeAppend path generated"
--     from the cost model's choice.
--   * Top-N (sort + limit) checks verify correctness under the default cost
--     model; the plan-shape check runs with enable_sort = off so it
--     deterministically shows the MergeAppend composing with a LIMIT.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

-- Create the per-database sentinel collection at the default id range before
-- pinning deterministic collection ids, so it does not consume the ids the
-- test collections expect.
SELECT documentdb_api.insert_one('msdb','__warmup','{ "_id": 1 }');
SELECT documentdb_api.drop_collection('msdb','__warmup');

SET documentdb.next_collection_id TO 2200;
SET documentdb.next_collection_index_id TO 2200;

-- =====================================================================
-- Setup: composite index {a:1, b:1}; b distinct within the {1,4} set
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 3, "a": 1, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 4, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 5, "a": 2, "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 6, "a": 1, "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 7, "a": 4, "b": 7 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 8, "a": 1, "b": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;

-- =====================================================================
-- Correctness: result order must be identical with the feature off and on.
-- Expected b ascending: 0,1,2,3,5,7,9  (a in {1,4})
-- =====================================================================
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

-- =====================================================================
-- Plan shape with feature OFF: expect a blocking Sort over a single $in scan.
-- (Rollout-default guard: must remain unchanged.)
-- =====================================================================
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Plan shape with feature ON (no LIMIT, enable_sort off to isolate the path):
-- expect Merge Append over per-value ordered scans and NO top Sort.
-- =====================================================================
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Recheck-filter suppression: each per-value child scan is already pinned to
-- one $in value by its point-equality Index Cond, so the original $in (@*=)
-- must NOT be re-attached as a redundant per-child recheck Filter. Assert the
-- plan is a Merge Append carrying no @*= recheck qual.
-- =====================================================================
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       NOT bool_or(line ~ '@\*=') AS no_recheck_filter
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$) AS line;
-- =====================================================================
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }')
$cmd$);

-- =====================================================================
-- Single-element $in: degenerates to a single ordered scan (no MergeAppend needed).
-- =====================================================================
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1] } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Duplicate $in values: result must not contain duplicate rows.
-- =====================================================================
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 1, 4] } }, "sort": { "b": 1 } }');

-- =====================================================================
-- Cross-representation numeric $in values: the same number spelled with
-- different BSON numeric types must collapse to a single child, otherwise
-- MergeAppend (which does not de-duplicate across children) would emit the
-- matching rows once per spelling. Covers both the integer case (1 / long /
-- double) and the non-integer double-vs-decimal128 case, which hash
-- differently but compare equal and produce the same index term.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 100, "a": 2.5, "b": 8 }');
-- Integer value spelled as int32 / int64 / double / decimal128: a=1 rows once each.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, { "$numberLong": "1" }, { "$numberDouble": "1.0" }, { "$numberDecimal": "1" }] } }, "sort": { "b": 1 } }');
-- Non-integer double and equal-valued decimal128: the a=2.5 row exactly once.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [2.5, { "$numberDecimal": "2.5" }] } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [2.5, { "$numberDecimal": "2.5" }] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Mixed BSON types in $in: values of differing types still match and order.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 9, "a": "x", "b": 4 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 10, "a": "x", "b": 6 }');
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, "x"] } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, "x"] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- String case sensitivity in $in: "x" and "X" remain distinct values.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 11, "a": "X", "b": 10 }');
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": ["x"] } }, "sort": { "b": 1 } }');
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": ["x", "X"] } }, "sort": { "b": 1 } }');

-- =====================================================================
-- Aggregate $match + $sort: must produce the same plan/result as find.
-- =====================================================================
SELECT document FROM bson_aggregation_pipeline('msdb',
  '{ "aggregate": "coll", "pipeline": [ { "$match": { "a": { "$in": [1, 4] } } }, { "$sort": { "b": 1 } } ], "cursor": {} }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('msdb',
      '{ "aggregate": "coll", "pipeline": [ { "$match": { "a": { "$in": [1, 4] } } }, { "$sort": { "b": 1 } } ], "cursor": {} }')
$cmd$);

-- =====================================================================
-- Multi-column $in (cartesian product). Index {a:1, c:1, b:1};
-- filter a:$in, c:$in, sort b => one ordered scan per (a,c) combination.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_mc');
SELECT documentdb_api.insert_one('msdb','coll_mc','{ "_id": 1, "a": 1, "c": 7, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_mc','{ "_id": 2, "a": 1, "c": 8, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_mc','{ "_id": 3, "a": 4, "c": 7, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_mc','{ "_id": 4, "a": 4, "c": 8, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_mc','{ "_id": 5, "a": 2, "c": 7, "b": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_mc", "indexes": [ { "key": { "a": 1, "c": 1, "b": 1 }, "name": "a_1_c_1_b_1" } ] }', true);
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mc", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_mc", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Interleaved constant-equality column. Index {a:1, x:1, b:1};
-- filter a:$in, x:5 (constant), sort b => ordered scan per a value with x=5 pinned.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_ic');
SELECT documentdb_api.insert_one('msdb','coll_ic','{ "_id": 1, "a": 1, "x": 5, "b": 8 }');
SELECT documentdb_api.insert_one('msdb','coll_ic','{ "_id": 2, "a": 4, "x": 5, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_ic','{ "_id": 3, "a": 1, "x": 9, "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_ic','{ "_id": 4, "a": 4, "x": 5, "b": 6 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_ic", "indexes": [ { "key": { "a": 1, "x": 1, "b": 1 }, "name": "a_1_x_1_b_1" } ] }', true);
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ic", "filter": { "a": { "$in": [1, 4] }, "x": 5 }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ic", "filter": { "a": { "$in": [1, 4] }, "x": 5 }, "sort": { "b": 1 } }')
$cmd$);

RESET enable_sort;

-- =====================================================================
-- Multi-column sort suffix (two-column suffix, same direction). Index
-- {a:1, b:1, c:1}; filter a:$in, sort {b:1, c:1} => each per-value ordered scan
-- yields the (b, c) order and the MergeAppend preserves it. The secondary key c
-- is what distinguishes this from a single-column suffix: within equal b the
-- rows must order by c ascending.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_ms');
SELECT documentdb_api.insert_one('msdb','coll_ms','{ "_id": 1, "a": 1, "b": 2, "c": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_ms','{ "_id": 2, "a": 1, "b": 2, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_ms','{ "_id": 3, "a": 4, "b": 1, "c": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_ms','{ "_id": 4, "a": 4, "b": 2, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_ms','{ "_id": 5, "a": 1, "b": 5, "c": 0 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_ms", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1" } ] }', true);

-- Correctness: feature off and on must agree. Expected (b asc, then c asc):
-- _id 3 (b1,c5), _id 4 (b2,c1), _id 2 (b2,c3), _id 1 (b2,c9), _id 5 (b5,c0).
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }');

-- Plan ON: expect a MergeAppend over per-value ordered scans (no top Sort).
SET enable_sort TO off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }')
$cmd$);

-- =====================================================================
-- Mixed-direction multi-column suffix. Index {a:1, b:1, c:1} (all ascending);
-- sort {b:1, c:-1}. The full (b asc, c desc) order is not streamable by a single
-- scan (a backward scan would reverse BOTH b and c together), but the leading key
-- b is, so the rewrite can produce a Merge Append ordered by the servable prefix
-- (b asc) with the suffix key c ordered above it by an Incremental Sort (PG16+)
-- or a plain Sort (PG15). Whether that path is cost-chosen is version dependent
-- (PG16+ prefers it via Incremental Sort; PG15 keeps the regular-scan + Sort), so
-- only correctness is asserted here; the prefix Merge Append plan shape is pinned
-- by the coll_ab_sort_bc / coll_tail_in cases below, which are stable on every
-- version. Correctness (b asc, then c desc): _id 3 (b1,c5), _id 1 (b2,c9),
-- _id 2 (b2,c3), _id 4 (b2,c1), _id 5 (b5,c0).
-- =====================================================================
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": -1 } }');

-- =====================================================================
-- Negative: missing intermediate prefix column. Index {a:1, b:1, c:1};
-- filter a:$in, sort {c:1} with no equality bound on b. The sort key c is not
-- an immediate suffix of the equality-bound prefix (b is unconstrained), so the
-- per-value ordered scans cannot stream rows in c order and the rewrite must be
-- abandoned in favor of a blocking Sort. Correctness must still hold; by c
-- ascending (0,1,3,5,9): _id 5, 4, 2, 3, 1.
-- =====================================================================
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "c": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "c": 1 } }')
$cmd$);

RESET enable_sort;

-- =====================================================================
-- Top-N correctness and plan shape
-- first 3 rows by b: 0,1,2 regardless of the plan chosen. The plan-shape check
-- runs with enable_sort = off so the assertion deterministically demonstrates
-- the MergeAppend path composing with a LIMIT (Limit over Merge Append). At this
-- small data scale the cost model may otherwise prefer a top-N heapsort over a
-- single scan, so the chosen winner is intentionally not hard-asserted here.
-- =====================================================================
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }');
SET enable_sort TO off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }')
$cmd$);
RESET enable_sort;

-- =====================================================================
-- Over-cap: with max_merge_sort_in_values below the $in cardinality, the optimization
-- must fall back to the existing (blocking Sort) plan. $in has 3 values, cap = 2.
-- =====================================================================
SET enable_sort TO off;
SET documentdb.max_merge_sort_in_values TO 2;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 2, 4] } }, "sort": { "b": 1 } }')
$cmd$);
RESET documentdb.max_merge_sort_in_values;
RESET enable_sort;

-- =====================================================================
-- Over-cap via the cartesian product rather than a single $in. coll_mc has
-- a:$in (2 values) and c:$in (2 values); with max_merge_sort_in_values = 3 neither
-- $in alone exceeds the cap, but their product (4) does. Processing the second
-- $in exhausts the remaining fan-out budget (3 / 2 = 1), so the rewrite is
-- abandoned in favor of the blocking Sort and no Merge Append is generated.
-- =====================================================================
SET enable_sort TO off;
SET documentdb.max_merge_sort_in_values TO 3;
SELECT NOT bool_or(line ~ 'Merge Append') AS no_merge_append_over_product_cap
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_mc", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "sort": { "b": 1 } }')
$cmd$) AS line;
RESET documentdb.max_merge_sort_in_values;
RESET enable_sort;

-- =====================================================================
-- Negatives and seq-scan-allowed correctness cases. These cannot (or should
-- not) be served by the composite index, so run with seq scan allowed.
-- =====================================================================
RESET documentdb.forceDisableSeqScan;

-- Empty $in: no rows.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [] } }, "sort": { "b": 1 } }');

SET enable_sort TO off;

-- =====================================================================
-- Negative: $in is on the sort field itself (not a prefix) => no MergeAppend.
-- =====================================================================
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "b": { "$in": [1, 4] } }, "sort": { "a": 1 } }')
$cmd$);

-- =====================================================================
-- Negative: range predicate on the prefix (not $in equality) => no MergeAppend.
-- =====================================================================
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$gt": 0 } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Negative: no composite index on the queried collection => no MergeAppend.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_noidx');
SELECT documentdb_api.insert_one('msdb','coll_noidx','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_noidx','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_noidx", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Array on the prefix field: a document whose prefix value is an array can
-- satisfy several $in branches at once. Exploding into per-value point scans
-- merged by a MergeAppend (which has no cross-child de-duplication) would emit
-- that document once per matching branch. The rewrite must therefore NOT fire
-- on a multi-key index: the result must match the feature-off result (the array
-- document appears exactly once) and the plan must fall back to a blocking Sort
-- rather than a MergeAppend.
-- =====================================================================
SET documentdb.forceDisableSeqScan TO on;

SELECT documentdb_api.create_collection('msdb','coll_arr');
SELECT documentdb_api.insert_one('msdb','coll_arr','{ "_id": 1, "a": [1, 4], "b": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_arr','{ "_id": 2, "a": 1, "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_arr','{ "_id": 3, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_arr','{ "_id": 4, "a": 1, "b": 8 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_arr", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);

-- Reference: feature OFF.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_arr", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

-- Feature ON: identical rows, the array document appears exactly once.
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_arr", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

-- Plan ON: multi-key index => no MergeAppend; falls back to a blocking Sort.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_arr", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);

RESET documentdb.forceDisableSeqScan;
RESET enable_sort;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Non-ascending index directions and combined predicates. Run with sequential
-- scans and explicit sorts disabled so the plan-shape assertions deterministically
-- show whether an ordered Merge Append path is generated.
-- =====================================================================
SET documentdb.forceDisableSeqScan TO on;
SET enable_sort TO off;

-- ---------------------------------------------------------------------
-- Descending index {a:-1, b:-1}. A request sorting {b:-1} matches the index
-- direction (each per-value scan streams b descending), so the rewrite applies.
-- Expected b descending: 9,5,2,1,0.
-- ---------------------------------------------------------------------
SELECT documentdb_api.create_collection('msdb','coll_desc');
SELECT documentdb_api.insert_one('msdb','coll_desc','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_desc','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_desc','{ "_id": 3, "a": 1, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_desc','{ "_id": 4, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_desc','{ "_id": 5, "a": 1, "b": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_desc", "indexes": [ { "key": { "a": -1, "b": -1 }, "name": "a_-1_b_-1" } ] }', true);

SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_desc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_desc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_desc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }')
$cmd$);

-- Opposite of the index direction (sort {b:1}) is satisfiable by a backward
-- per-value scan; the rewrite must still apply. Expected b ascending: 0,1,2,5,9.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_desc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_desc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);

-- ---------------------------------------------------------------------
-- Mixed-direction index {a:1, b:-1, c:1}. sort {b:-1} matches the b column's
-- direction (forward per-value scan streams b descending); the rewrite applies.
-- ---------------------------------------------------------------------
SELECT documentdb_api.create_collection('msdb','coll_mix');
SELECT documentdb_api.insert_one('msdb','coll_mix','{ "_id": 1, "a": 1, "b": 2, "c": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_mix','{ "_id": 2, "a": 4, "b": 0, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_mix','{ "_id": 3, "a": 1, "b": 9, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_mix','{ "_id": 4, "a": 4, "b": 5, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_mix','{ "_id": 5, "a": 1, "b": 1, "c": 3 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_mix", "indexes": [ { "key": { "a": 1, "b": -1, "c": 1 }, "name": "a_1_b_-1_c_1" } ] }', true);

SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mix", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mix", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_mix", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1 } }')
$cmd$);

-- sort {b:1} is the opposite of the index b direction, satisfiable via a
-- backward per-value scan; the rewrite must still apply.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mix", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mix", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_mix", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- Two-column suffix sort: remaining direction combinations on the all-ascending
-- index {a:1, b:1, c:1} (coll_ms). The sections above cover (b asc, c asc)
-- [full-coverage Merge Append] and (b asc, c desc) [prefix Merge Append + suffix
-- sort]; these add the two b-descending combinations to complete the matrix.
-- =====================================================================
-- (b desc, c desc): a uniform reversal of the index order, satisfiable by a
-- backward per-value scan; expect a Merge Append.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1, "c": -1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1, "c": -1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1, "c": -1 } }')
$cmd$);

-- (b desc, c asc): a mixed direction where the full order is not streamable, but
-- the leading key b is (via a backward per-value scan). As with (b asc, c desc),
-- whether the prefix Merge Append is cost-chosen is version dependent, so only
-- correctness is asserted here.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": -1, "c": 1 } }');

-- =====================================================================
-- Additional range predicate combined with the $in equality prefix.
-- =====================================================================
-- Range on the sort column itself. Index {a:1, b:1}; filter a:$in plus b>1,
-- sort {b:1}. Each per-value ordered scan also carries the b range as an index
-- bound; expect a Merge Append. Expected b ascending (b>1): 2,3,5,7,9.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] }, "b": { "$gt": 1 } }, "sort": { "b": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] }, "b": { "$gt": 1 } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] }, "b": { "$gt": 1 } }, "sort": { "b": 1 } }')
$cmd$);

-- Range on a trailing column that is neither the $in prefix nor the sort key.
-- Index {a:1, b:1, c:1}; filter a:$in plus c>=5, sort {b:1}. The c bound applies
-- as a per-child filter while order is still streamed on b; expect a Merge Append.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] }, "c": { "$gte": 5 } }, "sort": { "b": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] }, "c": { "$gte": 5 } }, "sort": { "b": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ms", "filter": { "a": { "$in": [1, 4] }, "c": { "$gte": 5 } }, "sort": { "b": 1 } }')
$cmd$);

-- =====================================================================
-- $hint interaction. A hint that selects the composite index must still allow
-- the rewrite; a hint that forces an unrelated index must fall back.
-- =====================================================================
-- Hint the composite index by name: the rewrite still applies (Merge Append).
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "hint": "a_1_b_1" }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "hint": "a_1_b_1" }')
$cmd$);

-- Hint the primary key: the composite path is unavailable, so the order cannot
-- be streamed and the plan falls back to a blocking Sort. Rows must still match.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "hint": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "hint": { "_id": 1 } }')
$cmd$);

RESET documentdb.forceDisableSeqScan;
RESET enable_sort;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Independent ground-truth correctness via a no-index runtime baseline. An
-- indexed collection (composite, order-capable) and a structurally identical
-- collection with no composite index are loaded with identical documents. For
-- each query the feature-on result bag must equal the runtime (sequential scan)
-- result bag. EXCEPT ALL is multiplicity-aware, so a spurious duplicate row is
-- caught, not just a missing or extra distinct row.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_rt_idx');
SELECT documentdb_api.create_collection('msdb','coll_rt_run');

SELECT documentdb_api.insert_one('msdb','coll_rt_idx','{ "_id": 1, "a": 1, "b": 2, "c": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_idx','{ "_id": 2, "a": 4, "b": 0, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_idx','{ "_id": 3, "a": 1, "b": 9, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_idx','{ "_id": 4, "a": 1, "b": 5, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_idx','{ "_id": 5, "a": 2, "b": 1, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_idx','{ "_id": 6, "a": 4, "b": 3, "c": 8 }');

SELECT documentdb_api.insert_one('msdb','coll_rt_run','{ "_id": 1, "a": 1, "b": 2, "c": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_run','{ "_id": 2, "a": 4, "b": 0, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_run','{ "_id": 3, "a": 1, "b": 9, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_run','{ "_id": 4, "a": 1, "b": 5, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_run','{ "_id": 5, "a": 2, "b": 1, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_run','{ "_id": 6, "a": 4, "b": 3, "c": 8 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_rt_idx", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1" } ] }', true);

-- Multikey variant: identical data plus an array-valued prefix document. The
-- array makes the index multikey, which disables the merge-sort rewrite (the
-- per-value scans could otherwise emit the same document once per matching $in
-- element). The runtime-equivalence guard confirms the fallback still emits the
-- array document exactly once and matches the sequential-scan ground truth.
SELECT documentdb_api.create_collection('msdb','coll_rt_mk_idx');
SELECT documentdb_api.create_collection('msdb','coll_rt_mk_run');

SELECT documentdb_api.insert_one('msdb','coll_rt_mk_idx','{ "_id": 1, "a": 1, "b": 2, "c": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_idx','{ "_id": 2, "a": 4, "b": 0, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_idx','{ "_id": 3, "a": 1, "b": 9, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_idx','{ "_id": 4, "a": [1, 4], "b": 5, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_idx','{ "_id": 5, "a": 2, "b": 1, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_idx','{ "_id": 6, "a": 4, "b": 3, "c": 8 }');

SELECT documentdb_api.insert_one('msdb','coll_rt_mk_run','{ "_id": 1, "a": 1, "b": 2, "c": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_run','{ "_id": 2, "a": 4, "b": 0, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_run','{ "_id": 3, "a": 1, "b": 9, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_run','{ "_id": 4, "a": [1, 4], "b": 5, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_run','{ "_id": 5, "a": 2, "b": 1, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_rt_mk_run','{ "_id": 6, "a": 4, "b": 3, "c": 8 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_rt_mk_idx", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1" } ] }', true);

-- Returns the indexed-collection row count when the two result bags are equal;
-- raises if either bag has rows the other lacks (multiplicity included). The
-- idx_spec side is planned under the merge-sort-forcing regime (the rewrite on,
-- seq scan and a plain Sort disabled) so the equivalence check actually
-- exercises the merge-sort path; the run_spec side is planned with the rewrite
-- off and a natural plan so it is the runtime $in-matcher ground truth. The
-- set_config calls use is_local so they revert at the end of this statement's
-- transaction and do not depend on, or leak into, the caller's GUC state.
CREATE SCHEMA mergesort_rt;
CREATE FUNCTION mergesort_rt.assert_equiv(idx_spec text, run_spec text)
RETURNS bigint
LANGUAGE plpgsql
AS $fn$
DECLARE
  idx_only bigint;
  run_only bigint;
  total bigint;
BEGIN
  -- Suppress the transient "table does not exist, skipping" NOTICE so the
  -- baseline does not depend on temp-table drop diagnostics. is_local=true
  -- scopes this to the current function-call transaction.
  PERFORM set_config('client_min_messages', 'warning', true);
  DROP TABLE IF EXISTS _ms_rt_idx;
  DROP TABLE IF EXISTS _ms_rt_run;
  PERFORM set_config('client_min_messages', 'notice', true);

  -- idx side: force the merge-sort path (rewrite on, seq scan and plain Sort off).
  PERFORM set_config('documentdb.enable_merge_sort_for_in_prefix', 'on', true);
  PERFORM set_config('documentdb.forceDisableSeqScan', 'on', true);
  PERFORM set_config('enable_sort', 'off', true);
  CREATE TEMP TABLE _ms_rt_idx AS SELECT document FROM bson_aggregation_find('msdb', idx_spec::bson);

  -- run side: ground truth via the runtime $in matcher (rewrite off, natural plan).
  PERFORM set_config('documentdb.enable_merge_sort_for_in_prefix', 'off', true);
  PERFORM set_config('documentdb.forceDisableSeqScan', 'off', true);
  PERFORM set_config('enable_sort', 'on', true);
  CREATE TEMP TABLE _ms_rt_run AS SELECT document FROM bson_aggregation_find('msdb', run_spec::bson);

  SELECT count(*) INTO idx_only FROM (
    SELECT document::text FROM _ms_rt_idx EXCEPT ALL SELECT document::text FROM _ms_rt_run
  ) a;
  SELECT count(*) INTO run_only FROM (
    SELECT document::text FROM _ms_rt_run EXCEPT ALL SELECT document::text FROM _ms_rt_idx
  ) b;
  IF idx_only <> 0 OR run_only <> 0 THEN
    RAISE EXCEPTION 'runtime-equivalence mismatch: indexed-only=% runtime-only=%', idx_only, run_only;
  END IF;
  SELECT count(*) INTO total FROM _ms_rt_idx;
  DROP TABLE _ms_rt_idx;
  DROP TABLE _ms_rt_run;
  RETURN total;
END;
$fn$;

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;
SET enable_sort TO off;

-- The indexed side here actually streams via the merge-sort path; confirm the
-- Merge Append is chosen so the equivalence check below validates the
-- optimization, not just a fallback.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_rt_idx", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);

-- The two-column suffix sort also streams via the merge-sort path; pin it too so
-- the equivalence check below validates the optimization, not a Sort fallback.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_rt_idx", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }')
$cmd$);

RESET documentdb.forceDisableSeqScan;
RESET enable_sort;

-- Merge-sort path vs sequential-scan ground truth: basic prefix $in + suffix sort.
SELECT mergesort_rt.assert_equiv(
  '{ "find": "coll_rt_idx", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }',
  '{ "find": "coll_rt_run", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

-- Merge-sort path vs ground truth: two-column suffix sort.
SELECT mergesort_rt.assert_equiv(
  '{ "find": "coll_rt_idx", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }',
  '{ "find": "coll_rt_run", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }');

-- Multikey fallback vs ground truth: the array document must appear exactly once.
SELECT mergesort_rt.assert_equiv(
  '{ "find": "coll_rt_mk_idx", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }',
  '{ "find": "coll_rt_mk_run", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Collation guard: a non-simple (case-insensitive) collation must NOT be
-- rewritten into the merge-sort path. The per-value children use binary
-- point equality, so under such a collation they would drop documents that
-- compare equal but are not byte-identical (e.g. "A" when the $in lists "a").
-- The rewrite must be abandoned so the collation-correct path is used.
-- =====================================================================
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;

SELECT documentdb_api.create_collection('msdb','coll_collation');
SELECT documentdb_api.insert_one('msdb','coll_collation','{ "_id": 1, "a": "a", "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_collation','{ "_id": 2, "a": "A", "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_collation','{ "_id": 3, "a": "b", "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_collation','{ "_id": 4, "a": "B", "b": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_collation','{ "_id": 5, "a": "c", "b": 5 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_collation", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);

SET documentdb.enable_merge_sort_for_in_prefix TO on;

-- Plan shape: even with the feature on and the blocking Sort penalized (the
-- conditions under which a binary $in prefix does form a Merge Append), a
-- case-insensitive collation must fall back to a non-merge-sort plan.
SET enable_sort TO off;
SELECT NOT bool_or(line ~ 'Merge Append') AS no_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_collation", "filter": { "a": { "$in": ["a", "b"] } }, "sort": { "b": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$) AS line;
RESET enable_sort;

-- Correctness: the case-insensitive $in must match the case variants too
-- ("a" -> {"a","A"}, "b" -> {"b","B"}); only "c" is excluded. If the rewrite
-- were applied this would drop "A" and "B".
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_collation", "filter": { "a": { "$in": ["a", "b"] } }, "sort": { "b": 1 }, "collation": { "locale": "en", "strength": 2 } }');

RESET documentdb.enable_merge_sort_for_in_prefix;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;

-- =====================================================================
-- Regex/null guard: a $in entry that is a regex matches by pattern, and a
-- null entry matches both explicit null and a missing field via a range
-- bound that requires a runtime recheck. The per-value children use binary
-- point equality and suppress the original $in recheck, so expanding either
-- kind of entry would silently drop matches. The rewrite must be abandoned
-- so the bounds and recheck of the ordinary index scan are preserved.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_regex');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 1, "a": "xavier", "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 2, "a": "p", "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 3, "a": "xenon", "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 4, "a": "p", "b": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 5, "a": "alex", "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 6, "a": "zoo", "b": 6 }');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 7, "a": null, "b": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_regex','{ "_id": 8, "b": 8 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_regex", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);

SET documentdb.enable_merge_sort_for_in_prefix TO on;

-- Plan shape: a $in mixing a literal and a regex must not form a Merge Append
-- even with the blocking Sort penalized.
SET enable_sort TO off;
SELECT NOT bool_or(line ~ 'Merge Append') AS no_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_regex", "filter": { "a": { "$in": [ "p", { "$regularExpression": { "pattern": "^x", "options": "" } } ] } }, "sort": { "b": 1 } }')
$cmd$) AS line;

-- Plan shape: a $in mixing a literal and null must not form a Merge Append.
SELECT NOT bool_or(line ~ 'Merge Append') AS no_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_regex", "filter": { "a": { "$in": [ "p", null ] } }, "sort": { "b": 1 } }')
$cmd$) AS line;
RESET enable_sort;

-- Correctness: the regex must still match xavier/xenon and the literal "p";
-- if the rewrite fired with binary point equality the regex matches would be
-- dropped. Expected b ascending: 1 (xavier), 2 (p), 3 (xenon), 4 (p).
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_regex", "filter": { "a": { "$in": [ "p", { "$regularExpression": { "pattern": "^x", "options": "" } } ] } }, "sort": { "b": 1 } }');

-- Correctness: null must match explicit null (_id 7) and the missing field
-- (_id 8) as well as the literal "p". Expected b ascending: 2 (p), 4 (p),
-- 7 (null), 8 (missing).
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_regex", "filter": { "a": { "$in": [ "p", null ] } }, "sort": { "b": 1 } }');

RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Sort column leads the index. Index {b:1, a:1}; filter a:$in, sort {b:1}.
-- Here the $in is on the trailing key and the sort key b is the index prefix,
-- so a single ordered index scan already streams rows in b order while applying
-- the $in on a as an index condition (not a recheck). The requested order is
-- therefore already satisfied without a blocking Sort, so the merge-sort rewrite
-- must NOT fire: the candidate index path already carries pathkeys and is
-- skipped. Correctness must still hold.
-- Expected b ascending: _id 2 (b0), 1 (b2), 4 (b5), 3 (b9); _id 5 (a=2) excluded.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_ba');
SELECT documentdb_api.insert_one('msdb','coll_ba','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_ba','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_ba','{ "_id": 3, "a": 1, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_ba','{ "_id": 4, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_ba','{ "_id": 5, "a": 2, "b": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_ba", "indexes": [ { "key": { "b": 1, "a": 1 }, "name": "b_1_a_1" } ] }', true);

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;

SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ba", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

-- Plan shape: even with the blocking Sort penalized, the plan stays a single
-- ordered index scan on b_1_a_1 (no Merge Append, no Sort) -- the index serves
-- both the b order and the $in on a.
SET enable_sort TO off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ba", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$);
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- $in straddling the sort key. Index {a:1, b:1, c:1}; filter a:$in (prefix of
-- the sort key) and c:$in (a column *after* the sort suffix), sort {b:1}.
-- Only the prefix $in (a) needs exploding to make each child b-ordered; the
-- suffix $in (c) is carried into each child as an ordinary in-scan @*= index
-- condition rather than fanned out, so the child count is |a| (here 2), not
-- |a| * |c| (4). c values are scattered across the b range so the result also
-- exercises that order is produced by the b-ordered walk, not by c.
-- Expected b ascending: _id 4 (b0,c7), 2 (b2,c8), 6 (b4,c7), 1 (b5,c7),
-- 5 (b7,c8), 3 (b9,c8); _id 7 (c9) and _id 8 (a2) excluded.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_abc');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 1, "a": 1, "b": 5, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 2, "a": 1, "b": 2, "c": 8 }');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 3, "a": 4, "b": 9, "c": 8 }');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 4, "a": 4, "b": 0, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 5, "a": 1, "b": 7, "c": 8 }');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 6, "a": 4, "b": 4, "c": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 7, "a": 1, "b": 3, "c": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_abc','{ "_id": 8, "a": 2, "b": 1, "c": 7 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_abc", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1" } ] }', true);

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;

-- Correctness + order (with c scattered across the b range).
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_abc", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "sort": { "b": 1 } }');

-- Plan shape: a Merge Append over exactly 2 children (one per $in a value); the
-- suffix $in on c rides along as an @*= index condition (an exploded $in would
-- appear as @= point equality and produce 4 children).
SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       count(*) FILTER (WHERE line ~ 'Index Scan using a_1_b_1_c_1') AS child_scans,
       bool_or(line ~ '@\*=') AS suffix_in_carried_as_condition
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_abc", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "sort": { "b": 1 } }')
$cmd$) AS line;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Larger dataset with planner statistics and a competing {b} index. With
-- per-collection stats enabled and ANALYZE run, the planner has accurate costs,
-- and a separate non-ordered {b:1} index is present as an alternative for the
-- b:$gt filter. The $in-prefix rewrite still produces the ordered Merge Append
-- over the composite {a:1, b:1} index when the feature is on, avoiding the
-- blocking Sort the feature-off plan falls back to. The non-ordered {b} index
-- cannot serve the {b} sort, so the Merge Append is the chosen ordered path on
-- every PG version. Only b in {11..20} satisfies b > 5, so the matched, sorted
-- result is just 10 rows even though the collection is larger.
-- =====================================================================
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SELECT documentdb_api.create_collection('msdb','coll_stats_prune');
SELECT documentdb_api.coll_mod('msdb', 'coll_stats_prune',
  '{ "collMod": "coll_stats_prune", "enableStats": true }');

SELECT count(documentdb_api.insert_one('msdb', 'coll_stats_prune',
  bson_build_document('_id', i, 'a', (i % 3) + 1,
                      'b', CASE WHEN i > 19990 THEN 10 + i - 19990 ELSE 0 END)))
FROM generate_series(1, 20000) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_stats_prune", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1", "enableOrderedIndex": true } ] }', true);
SET documentdb.defaultUseCompositeOpClass TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_stats_prune", "indexes": [ { "key": { "b": 1 }, "name": "b_1_regular" } ] }', true);
SET documentdb.defaultUseCompositeOpClass TO on;

ANALYZE documentdb_data.documents_2216;

SET documentdb.enable_merge_sort_for_in_prefix TO on;

-- Plan shape: with the feature off the composite path is ordered by a blocking
-- Sort (no Merge Append); with the feature on the ordered Merge Append is
-- generated and chosen (the non-ordered {b} index cannot serve the {b} sort), so
-- the blocking Sort is avoided. This holds on every PG version.
SET enable_sort TO off;
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT NOT bool_or(line ~ 'Merge Append') AS no_merge_append_when_off
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_stats_prune", "filter": { "a": { "$in": [1, 2, 3] }, "b": { "$gt": 5 } }, "sort": { "b": 1 } }')
$cmd$) AS line;
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_stats_prune", "filter": { "a": { "$in": [1, 2, 3] }, "b": { "$gt": 5 } }, "sort": { "b": 1 } }')
$cmd$) AS line;
RESET enable_sort;

-- Correctness (ordering): the rewritten ordered path must stream rows in true (b
-- ascending) order. Feature off uses a blocking Sort (known-correct order);
-- feature on must return the same rows in the same order. Projected to {_id, b}.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_stats_prune", "filter": { "a": { "$in": [1, 2, 3] }, "b": { "$gt": 5 } }, "projection": { "_id": 1, "b": 1 }, "sort": { "b": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_stats_prune", "filter": { "a": { "$in": [1, 2, 3] }, "b": { "$gt": 5 } }, "projection": { "_id": 1, "b": 1 }, "sort": { "b": 1 } }');
RESET enable_sort;
RESET documentdb.enable_merge_sort_for_in_prefix;
RESET documentdb.enablePerCollectionPlannerStatistics;

-- =====================================================================
-- Sort suffix only partially covered by the index. Index {a:1, b:1}; filter
-- a:$in, sort {b:1, c:1}. The index can stream each per-value scan by b but not
-- c, so the rewrite advertises a Merge Append ordered by the servable prefix (b)
-- and PostgreSQL layers the remaining key c on top: an Incremental Sort (PG16+)
-- or a plain Sort (PG15) above the Merge Append, instead of a blocking full Sort
-- over an unordered scan.
-- Correctness (b asc, then c asc): _id 3 (b1,c5), _id 4 (b2,c1), _id 2 (b2,c3),
-- _id 1 (b2,c9), _id 5 (b5,c0).
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_ab_sort_bc');
SELECT documentdb_api.insert_one('msdb','coll_ab_sort_bc','{ "_id": 1, "a": 1, "b": 2, "c": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_ab_sort_bc','{ "_id": 2, "a": 1, "b": 2, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_ab_sort_bc','{ "_id": 3, "a": 4, "b": 1, "c": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_ab_sort_bc','{ "_id": 4, "a": 4, "b": 2, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_ab_sort_bc','{ "_id": 5, "a": 1, "b": 5, "c": 0 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_ab_sort_bc", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;

-- Correctness with the feature on: rows come back in (b asc, then c asc) order.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ab_sort_bc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }');

-- Plan shape: a Merge Append ordered by the servable prefix (b) is generated (it
-- was not before this optimization). Version-agnostic: the prefix Merge Append
-- forms on every supported PG version; whether the suffix sort above it is an
-- Incremental Sort (PG16+) or a plain Sort (PG15) is left to the cost model.
SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ab_sort_bc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }')
$cmd$) AS line;
RESET enable_sort;

-- Feature off: the prefix Merge Append must not be generated (the optimization is
-- opt-in), so the query falls back to a blocking Sort over the unordered scan.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SET enable_sort TO off;
SELECT NOT bool_or(line ~ 'Merge Append') AS no_merge_append_when_off
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ab_sort_bc", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1, "c": 1 } }')
$cmd$) AS line;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- $in on a column after the servable sort prefix. Index {a:1, b:1, c:1}; filter
-- a:$in, c:$in; sort {b:1, d:1} (d is not in the index). The servable sort prefix
-- is b, so c sits *after* it: c:$in is carried as an in-scan filter inside each
-- per-value child rather than fanned out into more children. Filtering never
-- reorders, so the b order the Merge Append relies on is preserved, and the sort
-- above it orders the (b, d) suffix. The fan-out therefore stays |a:$in| = 2
-- children (not |a:$in| * |c:$in| = 4).
-- Matched rows (a in {1,4} AND c in {7,8}); sort {b asc, d asc}:
--   b1: _id 3 (d5); b2: _id 4 (d1), _id 2 (d3), _id 1 (d9); b5: _id 5 (d0).
--   _id 6 (c9) and _id 7 (a2) are filtered out.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_tail_in');
SELECT documentdb_api.insert_one('msdb','coll_tail_in','{ "_id": 1, "a": 1, "b": 2, "c": 7, "d": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_tail_in','{ "_id": 2, "a": 1, "b": 2, "c": 8, "d": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_tail_in','{ "_id": 3, "a": 4, "b": 1, "c": 7, "d": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_tail_in','{ "_id": 4, "a": 4, "b": 2, "c": 8, "d": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_tail_in','{ "_id": 5, "a": 1, "b": 5, "c": 7, "d": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_tail_in','{ "_id": 6, "a": 1, "b": 2, "c": 9, "d": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_tail_in','{ "_id": 7, "a": 2, "b": 1, "c": 7, "d": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_tail_in", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;

-- Correctness: feature off (blocking Sort) and feature on return the same rows in
-- the same (b asc, d asc) order; c:$in filters _id 6, a:$in filters _id 7.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_tail_in", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "projection": { "_id": 1, "b": 1, "d": 1 }, "sort": { "b": 1, "d": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_tail_in", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "projection": { "_id": 1, "b": 1, "d": 1 }, "sort": { "b": 1, "d": 1 } }');

-- Plan shape: the Merge Append forms and there are exactly 2 ordered child index
-- scans (c:$in carried as a filter, not exploded into 4 children).
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       count(*) FILTER (WHERE line ~ 'Index Scan using') AS child_index_scans
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_tail_in", "filter": { "a": { "$in": [1, 4] }, "c": { "$in": [7, 8] } }, "sort": { "b": 1, "d": 1 } }')
$cmd$) AS line;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;


-- =====================================================================
-- REGRESSION: de-duplication of numerically-equal $in values that have
-- different binary encodings. Index {a:1, b:1}; filter a:$in with two
-- decimal128 cohorts of the SAME number -- NumberDecimal("1.5") and
-- NumberDecimal("1.50") -- so $in denotes the set {1.5}. The rewrite must
-- collapse the cohorts into ONE per-value child scan; otherwise each cohort
-- fans out into its own ordered child that scans the same index entries
-- (point @= is value-based), and the Merge Append emits every matched document
-- once per cohort. Each matched _id must appear EXACTLY ONCE.
-- Matched docs, b ascending: _id 2 (b1), _id 1 (b2).
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_dedup_numeric');
SELECT documentdb_api.insert_one('msdb','coll_dedup_numeric','{ "_id": 1, "a": 1.5, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_dedup_numeric','{ "_id": 2, "a": 1.5, "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_dedup_numeric','{ "_id": 3, "a": 9, "b": 3 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_dedup_numeric", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;

-- Ground truth (feature off): the runtime $in matcher de-duplicates the cohorts,
-- returning each matched _id once: _id 2 (b1), _id 1 (b2).
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_dedup_numeric", "filter": { "a": { "$in": [ { "$numberDecimal": "1.5" }, { "$numberDecimal": "1.50" } ] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');

-- Feature on: must return the SAME two rows. The de-dup defect instead fans the
-- two decimal cohorts into two child scans over the same entries, so each matched
-- _id comes back twice. rows_returned must be 2.
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_dedup_numeric", "filter": { "a": { "$in": [ { "$numberDecimal": "1.5" }, { "$numberDecimal": "1.50" } ] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');
SELECT count(*) AS rows_returned FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "coll_dedup_numeric", "filter": { "a": { "$in": [ { "$numberDecimal": "1.5" }, { "$numberDecimal": "1.50" } ] } }, "sort": { "b": 1 } }')
) matched;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- Out-of-double-range decimal128 cohorts must not raise while hashing for de-dup
-- (the normalized double conversion is the quiet variant) and must still collapse
-- to one child per value. Overflow (1e400 -> +Inf) and underflow (1e-400 -> 0)
-- both reach the same de-dup hash. Each matched _id must appear EXACTLY ONCE.
SELECT documentdb_api.insert_one('msdb','coll_dedup_numeric','{ "_id": 10, "a": { "$numberDecimal": "1e400" }, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_dedup_numeric','{ "_id": 11, "a": { "$numberDecimal": "1e400" }, "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_dedup_numeric','{ "_id": 12, "a": { "$numberDecimal": "1e-400" }, "b": 1 }');

SET documentdb.forceDisableSeqScan TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;

-- Overflow cohorts {1e400, 1.0e400} denote {1e400}: _id 11 (b1), _id 10 (b2), once each.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_dedup_numeric", "filter": { "a": { "$in": [ { "$numberDecimal": "1e400" }, { "$numberDecimal": "1.0e400" } ] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');
SELECT count(*) AS rows_returned FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "coll_dedup_numeric", "filter": { "a": { "$in": [ { "$numberDecimal": "1e400" }, { "$numberDecimal": "1.0e400" } ] } }, "sort": { "b": 1 } }')
) matched;

-- Underflow cohorts {1e-400, 1.0e-400} denote {1e-400}: _id 12 only, once.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_dedup_numeric", "filter": { "a": { "$in": [ { "$numberDecimal": "1e-400" }, { "$numberDecimal": "1.0e-400" } ] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');
SELECT count(*) AS rows_returned FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "coll_dedup_numeric", "filter": { "a": { "$in": [ { "$numberDecimal": "1e-400" }, { "$numberDecimal": "1.0e-400" } ] } }, "sort": { "b": 1 } }')
) matched;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Multi-$in-column cartesian explosion (both $in columns exploded, under cap).
-- Index {a:1, b:1, c:1}; filter a:$in[1,4] AND b:$in[5,6] (both equality-prefix
-- columns of the sort), sort {c:1}. Both $in columns are exploded into their
-- cartesian product, so the Merge Append has |a| * |b| = 4 ordered child scans
-- (not 2). The default cap (max_merge_sort_in_values = 200) is well above 4, so the
-- rewrite is applied (the over-cap rejection is covered separately by coll_mc).
-- Matched docs (a in {1,4} AND b in {5,6}); c ascending: _id 2 (c1), 4 (c2),
-- 1 (c3), 3 (c4). _id 5 (a2) and _id 6 (b7) are excluded.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_cartesian');
SELECT documentdb_api.insert_one('msdb','coll_cartesian','{ "_id": 1, "a": 1, "b": 5, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_cartesian','{ "_id": 2, "a": 4, "b": 6, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_cartesian','{ "_id": 3, "a": 1, "b": 6, "c": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_cartesian','{ "_id": 4, "a": 4, "b": 5, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_cartesian','{ "_id": 5, "a": 2, "b": 5, "c": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_cartesian','{ "_id": 6, "a": 1, "b": 7, "c": 0 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_cartesian", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;

-- Correctness: feature off and on agree (c ascending): _id 2,4,1,3.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_cartesian", "filter": { "a": { "$in": [1, 4] }, "b": { "$in": [5, 6] } }, "projection": { "_id": 1 }, "sort": { "c": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_cartesian", "filter": { "a": { "$in": [1, 4] }, "b": { "$in": [5, 6] } }, "projection": { "_id": 1 }, "sort": { "c": 1 } }');

-- Plan shape: a Merge Append over exactly 4 ordered child index scans (the
-- cartesian product of the two exploded $in columns).
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       count(*) FILTER (WHERE line ~ 'Index Scan using') AS child_index_scans
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_cartesian", "filter": { "a": { "$in": [1, 4] }, "b": { "$in": [5, 6] } }, "sort": { "c": 1 } }')
$cmd$) AS line;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Point-equality on an indexed intermediate prefix column. Index {a:1, b:1, c:1};
-- filter a:$in[1,4] AND b:5 (a plain $eq, not a $in or a range), sort {c:1}. The
-- $in on a is exploded; the equality on the indexed column b -- which sits
-- between a and the sort key c -- is what makes the [a,b] prefix fully
-- equality-bound so c is streamable. b rides into each child as an index
-- condition, so the Merge Append has |a| = 2 children. Matched docs (a in {1,4}
-- AND b = 5); c ascending: _id 4 (c1), 2 (c2), 1 (c3). _id 3 (b6) and _id 5 (a2)
-- are excluded.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_eq_prefix');
SELECT documentdb_api.insert_one('msdb','coll_eq_prefix','{ "_id": 1, "a": 1, "b": 5, "c": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_eq_prefix','{ "_id": 2, "a": 4, "b": 5, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_eq_prefix','{ "_id": 3, "a": 1, "b": 6, "c": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_eq_prefix','{ "_id": 4, "a": 4, "b": 5, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_eq_prefix','{ "_id": 5, "a": 2, "b": 5, "c": 9 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_eq_prefix", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_eq_prefix", "filter": { "a": { "$in": [1, 4] }, "b": 5 }, "projection": { "_id": 1 }, "sort": { "c": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_eq_prefix", "filter": { "a": { "$in": [1, 4] }, "b": 5 }, "projection": { "_id": 1 }, "sort": { "c": 1 } }');

-- Plan shape: Merge Append over exactly 2 children (one per $in a value); the b
-- equality rides along as an index condition rather than adding children.
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       count(*) FILTER (WHERE line ~ 'Index Scan using') AS child_index_scans
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_eq_prefix", "filter": { "a": { "$in": [1, 4] }, "b": 5 }, "sort": { "c": 1 } }')
$cmd$) AS line;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Non-finite $in values (NaN / +Infinity). Index {a:1, b:1}; the $in lists the
-- double and decimal128 cohorts of NaN and of +Infinity. These are non-finite,
-- so the de-dup normalizes them via the quiet double conversion: NaN-double and
-- NaN-decimal collapse to one child, as do +Inf-double and +Inf-decimal, giving
-- a fan-out of 2 (not 4) and each matched document exactly once. Matched docs
-- (a is NaN or +Inf); b ascending: _id 2 (b1), 4 (b2), 1 (b3), 3 (b5). _id 5
-- (a = 5) is excluded.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_nan');
SELECT documentdb_api.insert_one('msdb','coll_nan','{ "_id": 1, "a": { "$numberDouble": "NaN" }, "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_nan','{ "_id": 2, "a": { "$numberDouble": "NaN" }, "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_nan','{ "_id": 3, "a": { "$numberDouble": "Infinity" }, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_nan','{ "_id": 4, "a": { "$numberDouble": "Infinity" }, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_nan','{ "_id": 5, "a": 5, "b": 9 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_nan", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_nan", "filter": { "a": { "$in": [ { "$numberDouble": "NaN" }, { "$numberDecimal": "NaN" }, { "$numberDouble": "Infinity" }, { "$numberDecimal": "Infinity" } ] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_nan", "filter": { "a": { "$in": [ { "$numberDouble": "NaN" }, { "$numberDecimal": "NaN" }, { "$numberDouble": "Infinity" }, { "$numberDecimal": "Infinity" } ] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');
SELECT count(*) AS rows_returned FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "coll_nan", "filter": { "a": { "$in": [ { "$numberDouble": "NaN" }, { "$numberDecimal": "NaN" }, { "$numberDouble": "Infinity" }, { "$numberDecimal": "Infinity" } ] } }, "sort": { "b": 1 } }')
) matched;
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Competing cheaper index: the marked composite path must survive add_path.
-- The collection has BOTH a composite {a:1, b:1} index and a narrower {a:1}
-- index. For filter a:$in, sort {b:1}, the {a} index is the cheaper way to apply
-- the $in (it is unordered, and being a single-path composite opclass it is never
-- a merge-sort candidate), while the {a, b} index is the merge-sort candidate.
-- The cost-estimate marking pass advertises the prefix the candidate will produce
-- once rewritten as placeholder pathkeys; without that, the unordered {a, b} scan
-- is dominated on cost by the cheaper {a} scan and pruned by add_path before
-- ConsiderMergeSortForInPrefix can rewrite it -- so no Merge Append is generated.
-- This case is the one that exercises that placeholder-pathkeys advertisement:
-- it falls back to a blocking Sort over the {a} index if it is removed.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_competing_idx');
-- Enough rows that the wider {a, b} index is measurably costlier than {a}; the
-- count wrapper keeps the inserts to a single output row.
SELECT COUNT(*) FROM (
  SELECT documentdb_api.insert_one('msdb','coll_competing_idx',
    ('{ "_id": ' || g || ', "a": ' || (g % 4) || ', "b": ' || (g % 7) || ' }')::documentdb_core.bson)
  FROM generate_series(1, 300) g) inserted;
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_competing_idx", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_competing_idx", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);
ANALYZE;

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;

-- Plan shape: the {a, b} Merge Append is generated even though a cheaper {a}
-- index can serve the same $in filter -- the marked candidate survives add_path on
-- the strength of its advertised prefix pathkeys.
SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_competing_idx", "filter": { "a": { "$in": [1, 2] } }, "sort": { "b": 1 } }')
$cmd$) AS line;
RESET enable_sort;

RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- getMore / cursor continuation over a merge-sort Merge Append. With a small
-- batchSize the result is paged; the merge order must be preserved ACROSS pages,
-- not just within one. drain_ids fetches the first page then loops cursor_get_more
-- (threading the continuation) until the cursor id is 0, concatenating the
-- per-page _id lists. Draining coll_cartesian (the 4-child Merge Append, global c
-- order _id 2,4,1,3) with batchSize 2 must yield page 1 [2, 4] then page 2 [1, 3].
-- =====================================================================
CREATE SCHEMA mergesort_gm;
CREATE FUNCTION mergesort_gm.drain_ids(find_spec text, get_more_spec text)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
  doc documentdb_core.bson;
  cont documentdb_core.bson;
  pages text;
BEGIN
  SELECT cursorPage, continuation INTO doc, cont
  FROM documentdb_api.find_cursor_first_page('msdb', find_spec::documentdb_core.bson, 4294967200);
  pages := documentdb_core.bson_to_json_string(
    documentdb_api_catalog.bson_dollar_project(doc, '{ "page": "$cursor.firstBatch._id" }'::documentdb_core.bson));

  -- A zero cursor id signals exhaustion; otherwise fetch the next page and append
  -- its _ids. Order across pages must match the single-batch order.
  WHILE documentdb_api_catalog.bson_dollar_project(doc, '{ "id": "$cursor.id" }'::documentdb_core.bson)
		<> '{ "id" : { "$numberLong" : "0" } }'::documentdb_core.bson LOOP
    SELECT cursorPage, continuation INTO doc, cont
    FROM documentdb_api.cursor_get_more('msdb', get_more_spec::documentdb_core.bson, cont);
    pages := pages || ' | ' || documentdb_core.bson_to_json_string(
      documentdb_api_catalog.bson_dollar_project(doc, '{ "page": "$cursor.nextBatch._id" }'::documentdb_core.bson));
  END LOOP;
  RETURN pages;
END
$fn$;

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;
SET enable_sort TO off;
SELECT mergesort_gm.drain_ids(
  '{ "find": "coll_cartesian", "filter": { "a": { "$in": [1, 4] }, "b": { "$in": [5, 6] } }, "projection": { "_id": 1 }, "sort": { "c": 1 }, "batchSize": 2 }',
  '{ "collection": "coll_cartesian", "getMore": { "$numberLong": "4294967200" }, "batchSize": 2 }');
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- Dynamic streaming cursor + merge-sort: the same paged $in + sort query, now with
-- dynamic cursors enabled. The merge-sort marker is present in the pathlist when
-- UpdatePathsWithDynamicStreamingCursorPlans runs (before the rewrite strips it),
-- so the dynamic cursor must fall back to a persistent cursor and let the
-- MergeAppend supply the order. Draining must yield the same correct paged order
-- as the non-dynamic case above (page 1 [2, 4] then page 2 [1, 3]).
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;
SET enable_sort TO off;
SELECT mergesort_gm.drain_ids(
  '{ "find": "coll_cartesian", "filter": { "a": { "$in": [1, 4] }, "b": { "$in": [5, 6] } }, "projection": { "_id": 1 }, "sort": { "c": 1 }, "batchSize": 2 }',
  '{ "collection": "coll_cartesian", "getMore": { "$numberLong": "4294967200" }, "batchSize": 2 }');
RESET enable_sort;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enable_merge_sort_for_in_prefix;
RESET documentdb.enableDynamicCursors;

-- Fail-fast: the internal $in-prefix merge-sort marker is a planner-only signal
-- that must be stripped before execution. If it ever reaches runtime evaluation,
-- bson_dollar_range throws instead of silently treating it as a full scan (which
-- could return incorrect results).
SELECT documentdb_api_internal.bson_dollar_range('{}'::bson, '{ "mergeSort": { "mergeSortInPrefix": true } }'::bson);

-- =====================================================================
-- Index-only scan composition: when the composite index covers the projection
-- and index-only scans are enabled, each per-$in-value child scan is served as
-- an Index Only Scan, so the MergeAppend streams the requested order without a
-- blocking Sort and without touching the heap. A projection the index does not
-- cover (or index-only scans being disabled) falls back to regular, heap-
-- fetching ordered Index Scans. Correctness is unchanged either way.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_ios');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 1, "a": 1, "b": 2, "c": 100 }');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 2, "a": 4, "b": 0, "c": 100 }');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 3, "a": 1, "b": 9, "c": 100 }');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 4, "a": 4, "b": 5, "c": 100 }');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 5, "a": 2, "b": 1, "c": 100 }');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 6, "a": 1, "b": 3, "c": 100 }');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 7, "a": 4, "b": 7, "c": 100 }');
SELECT documentdb_api.insert_one('msdb','coll_ios','{ "_id": 8, "a": 1, "b": 1, "c": 100 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_ios", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "ios_a_1_b_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;
SET enable_indexonlyscan TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;

-- Correctness (covered projection {a,b}): result order identical feature off vs on.
-- Expected b ascending: 0,1,2,3,5,7,9 (a in {1,4}).
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }');
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }');

-- Plan (covered projection, enable_sort off to isolate the path): Merge Append
-- whose children are Index Only Scans, with no heap-fetching Index Scan.
SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       bool_or(line ~ 'Index Only Scan') AS children_index_only,
       NOT bool_or(line ~ 'Index Scan using') AS no_heap_index_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }')
$cmd$) AS line;

-- Plan (non-covered projection: c is not in the index): the children fall back
-- to regular ordered Index Scans; no Index Only Scan is generated.
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       NOT bool_or(line ~ 'Index Only Scan') AS no_index_only_scan,
       bool_or(line ~ 'Index Scan using') AS children_heap_index_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "sort": { "b": 1 } }')
$cmd$) AS line;

-- Plan (index-only scans disabled): the children fall back to regular ordered
-- Index Scans even though the projection is covered.
SET enable_indexonlyscan TO off;
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       NOT bool_or(line ~ 'Index Only Scan') AS no_index_only_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }')
$cmd$) AS line;
SET enable_indexonlyscan TO on;
RESET enable_sort;

-- Plan (single $in value, covered projection): the fast path emits one ordered
-- scan with no MergeAppend; it is still served as an Index Only Scan.
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ios", "filter": { "a": { "$in": [1] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }');
SELECT NOT bool_or(line ~ 'Merge Append') AS no_merge_append,
       bool_or(line ~ 'Index Only Scan') AS index_only_scan,
       NOT bool_or(line ~ 'Index Scan using') AS no_heap_index_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios", "filter": { "a": { "$in": [1] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }')
$cmd$) AS line;

-- Plan (covered projection but a filter on a field the index does not cover):
-- the c filter needs the heap, so the children fall back to regular ordered
-- Index Scans even though the projection itself is covered.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] }, "c": 100 }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }');
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       NOT bool_or(line ~ 'Index Only Scan') AS no_index_only_scan,
       bool_or(line ~ 'Index Scan using') AS children_heap_index_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] }, "c": 100 }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": 1 } }')
$cmd$) AS line;
RESET enable_sort;

-- Cartesian product ($in on a and b) with a covered projection on the (a,b,c)
-- index: each of the 2 x 2 per-value child scans is an Index Only Scan.
SELECT documentdb_api.create_collection('msdb','coll_ios_abc');
SELECT documentdb_api.insert_one('msdb','coll_ios_abc','{ "_id": 1, "a": 1, "b": 5, "c": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_ios_abc','{ "_id": 2, "a": 4, "b": 6, "c": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_ios_abc','{ "_id": 3, "a": 1, "b": 5, "c": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_ios_abc','{ "_id": 4, "a": 4, "b": 6, "c": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_ios_abc','{ "_id": 5, "a": 1, "b": 6, "c": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_ios_abc','{ "_id": 6, "a": 4, "b": 5, "c": 3 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_ios_abc", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "ios_a_1_b_1_c_1" } ] }', true);

-- Correctness (cartesian covered): c ascending 0,1,2,3,5,9.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ios_abc", "filter": { "a": { "$in": [1, 4] }, "b": { "$in": [5, 6] } }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "sort": { "c": 1 } }');

-- Plan (cartesian covered, enable_sort off): Merge Append over Index Only Scans.
SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       bool_or(line ~ 'Index Only Scan') AS children_index_only,
       NOT bool_or(line ~ 'Index Scan using') AS no_heap_index_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios_abc", "filter": { "a": { "$in": [1, 4] }, "b": { "$in": [5, 6] } }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "sort": { "c": 1 } }')
$cmd$) AS line;
RESET enable_sort;

-- Descending sort with a covered projection: the order-capable index cannot
-- serve a *descending* index-only ordered scan (it is costed as unusable), so
-- the children stay regular heap-fetching Index Scans while the MergeAppend is
-- still used (it is not silently dropped in favour of a blocking Sort). Result
-- order is correct regardless.
-- Expected b descending: 9,7,5,3,2,1,0 (a in {1,4}).
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": -1 } }');
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       NOT bool_or(line ~ 'Index Only Scan') AS no_index_only_scan,
       bool_or(line ~ 'Index Scan using') AS children_heap_index_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "_id": 0 }, "sort": { "b": -1 } }')
$cmd$) AS line;
RESET enable_sort;

-- Partial sort prefix with a covered projection on the (a,b,c) index. Sort
-- { b:1, c:-1 }: the index streams the servable prefix b ascending (an Index
-- Only Scan, since ascending order-by is index-only capable) and the descending
-- c suffix is layered above the Merge Append by an Incremental Sort (PG16+) or a
-- plain Sort (PG15). The children remain Index Only Scans because their servable
-- order (b ascending) is the index-only-capable direction.
-- Expected (b asc, then c desc): _id 3 (b5,c9), _id 6 (b5,c3), _id 1 (b5,c2),
-- _id 4 (b6,c5), _id 5 (b6,c1), _id 2 (b6,c0).
SET enable_sort TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_ios_abc", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "sort": { "b": 1, "c": -1 } }');
SELECT bool_or(line ~ 'Merge Append') AS has_merge_append,
       bool_or(line ~ 'Index Only Scan') AS children_index_only,
       NOT bool_or(line ~ 'Index Scan using') AS no_heap_index_scan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ios_abc", "filter": { "a": { "$in": [1, 4] } }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "sort": { "b": 1, "c": -1 } }')
$cmd$) AS line;
RESET enable_sort;

RESET enable_indexonlyscan;
RESET documentdb.enableIndexOnlyScanForFindProject;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Parallel scan interaction: the merge-sort marking guard skips any index
-- whose access method can produce parallel scans (amcanparallel). So when
-- composite parallel index scans are enabled and forced, a $in-prefix + sort
-- query must NOT produce a merge-sort Merge Append -- the planner uses an
-- ordinary parallel index scan with a Sort on top instead. This guards against
-- the placeholder-pathkeys marker ever leaking into a parallel path (which
-- would advertise an order the parallel scan does not actually provide).
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_par');
SELECT documentdb_api.insert_one('msdb','coll_par','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_par','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_par','{ "_id": 3, "a": 1, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_par','{ "_id": 4, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_par','{ "_id": 6, "a": 1, "b": 3 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_par", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "par_a_1_b_1" } ] }', true);

SELECT collection_id AS par_col FROM documentdb_api_catalog.collections
    WHERE database_name = 'msdb' AND collection_name = 'coll_par' \gset
SELECT FORMAT('ALTER TABLE documentdb_data.documents_%s SET (parallel_workers = 2)', :par_col) \gexec

SET documentdb.forceDisableSeqScan TO on;
SET enable_bitmapscan TO off;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
SET min_parallel_table_scan_size TO 0;
SET min_parallel_index_scan_size TO 0;
SET max_parallel_workers_per_gather TO 2;
SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.forceParallelScanIfAvailable TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO on;

-- The composite index is parallel-capable, so merge-sort marking is skipped: a
-- parallel Gather is used and NO Merge Append is generated. (Result-ordering
-- correctness for this shape is covered by the non-parallel cases above; under
-- forced parallelism the ordinary parallel index-scan path owns it.)
SELECT bool_or(line ~ 'Gather') AS has_gather,
       bool_or(line ~ 'Parallel') AS has_parallel,
       NOT bool_or(line ~ 'Merge Append') AS no_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, VERBOSE OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_par", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }')
$cmd$) AS line;

RESET documentdb.forceParallelScanIfAvailable;
RESET documentdb.enableCompositeParallelIndexScan;
RESET documentdb.enable_merge_sort_for_in_prefix;
RESET max_parallel_workers_per_gather;
RESET min_parallel_index_scan_size;
RESET min_parallel_table_scan_size;
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
RESET enable_bitmapscan;

-- =====================================================================
-- $sample interaction: a reservoir $sample stage wraps every base path with a
-- ReservoirSample custom scan. When a $sort precedes the $sample on a merge-sort
-- eligible shape, the rewrite replaces the plain scan with an ordered Merge
-- Append, which the reservoir sample then wraps -- so the per-$in-value ordering
-- is performed and then discarded by the random sample (a suboptimal, but
-- correct, plan). These tests assert the result is correct (the sample reads the
-- full matching set) and document the current plan shape.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','coll_sample');
SELECT documentdb_api.insert_one('msdb','coll_sample','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_sample','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_sample','{ "_id": 3, "a": 1, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_sample','{ "_id": 4, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_sample','{ "_id": 5, "a": 2, "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_sample','{ "_id": 6, "a": 1, "b": 3 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_sample", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "sample_a_1_b_1" } ] }', true);

SET documentdb.forceDisableSeqScan TO on;
SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO on;

-- Correctness: a bounded $sample returns exactly the requested size (the matching
-- set a in {1,4} has 5 docs, so a sample of 2 yields 2).
SELECT count(*) AS sample_count FROM (
  SELECT document FROM bson_aggregation_pipeline('msdb',
    '{ "aggregate": "coll_sample", "pipeline": [ { "$match": { "a": { "$in": [1, 4] } } }, { "$sort": { "b": 1 } }, { "$sample": { "size": 2 } } ] }')) s;

-- Correctness: sampling the whole matching set returns every matching row -- the
-- reservoir reads the full Merge Append output, so no rows are dropped or biased.
SELECT count(*) AS full_set_count FROM (
  SELECT document FROM bson_aggregation_pipeline('msdb',
    '{ "aggregate": "coll_sample", "pipeline": [ { "$match": { "a": { "$in": [1, 4] } } }, { "$sort": { "b": 1 } }, { "$sample": { "size": 5 } } ] }')) s;

-- Plan shape (documents the current interaction): the reservoir sample wraps a
-- merge-sort Merge Append. This assertion is expected to change if merge-sort is
-- later suppressed when a reservoir-sample expr is present.
SELECT bool_or(line ~ 'ReservoirSample') AS has_reservoir_sample,
       bool_or(line ~ 'Merge Append') AS wraps_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, VERBOSE OFF)
    SELECT document FROM bson_aggregation_pipeline('msdb',
      '{ "aggregate": "coll_sample", "pipeline": [ { "$match": { "a": { "$in": [1, 4] } } }, { "$sort": { "b": 1 } }, { "$sample": { "size": 2 } } ] }')
$cmd$) AS line;

RESET documentdb.enableDollarSampleReservoirScan;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- cleanup
SELECT documentdb_api.drop_collection('msdb','coll');
SELECT documentdb_api.drop_collection('msdb','coll_mc');
SELECT documentdb_api.drop_collection('msdb','coll_ic');
SELECT documentdb_api.drop_collection('msdb','coll_ms');
SELECT documentdb_api.drop_collection('msdb','coll_noidx');
SELECT documentdb_api.drop_collection('msdb','coll_arr');
SELECT documentdb_api.drop_collection('msdb','coll_desc');
SELECT documentdb_api.drop_collection('msdb','coll_mix');
SELECT documentdb_api.drop_collection('msdb','coll_rt_idx');
SELECT documentdb_api.drop_collection('msdb','coll_rt_run');
SELECT documentdb_api.drop_collection('msdb','coll_rt_mk_idx');
SELECT documentdb_api.drop_collection('msdb','coll_rt_mk_run');
SELECT documentdb_api.drop_collection('msdb','coll_collation');
SELECT documentdb_api.drop_collection('msdb','coll_regex');
SELECT documentdb_api.drop_collection('msdb','coll_ba');
SELECT documentdb_api.drop_collection('msdb','coll_abc');
SELECT documentdb_api.drop_collection('msdb','coll_stats_prune');
SELECT documentdb_api.drop_collection('msdb','coll_ab_sort_bc');
SELECT documentdb_api.drop_collection('msdb','coll_tail_in');
SELECT documentdb_api.drop_collection('msdb','coll_dedup_numeric');
SELECT documentdb_api.drop_collection('msdb','coll_cartesian');
SELECT documentdb_api.drop_collection('msdb','coll_eq_prefix');
SELECT documentdb_api.drop_collection('msdb','coll_nan');
SELECT documentdb_api.drop_collection('msdb','coll_competing_idx');
SELECT documentdb_api.drop_collection('msdb','coll_ios');
SELECT documentdb_api.drop_collection('msdb','coll_ios_abc');
SELECT documentdb_api.drop_collection('msdb','coll_par');
SELECT documentdb_api.drop_collection('msdb','coll_sample');
DROP SCHEMA mergesort_gm CASCADE;
DROP SCHEMA mergesort_rt CASCADE;
