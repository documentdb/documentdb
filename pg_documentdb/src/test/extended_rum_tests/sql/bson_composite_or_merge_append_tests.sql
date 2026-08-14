-- Tests for the BitmapOr -> MergeAppend rewrite that removes a blocking Sort when
-- an $or of ordered per-branch composite-index scans shares the requested order as
-- a suffix. Gated by documentdb.enable_merge_sort_for_bitmap_or (default on).
--
-- A BitmapOr unions the per-branch TID bitmaps and therefore deduplicates rows; a
-- MergeAppend simply concatenates its children and does NOT deduplicate. When the
-- branches are provably disjoint (some scalar index column bound to a different
-- equality constant in both branches, so a document cannot match both) the plain
-- MergeAppend is sound on its own. When disjointness cannot be proven (identical
-- or overlapping branches, or a multi-key path that lets a single document match
-- more than one branch), the MergeAppend is wrapped in a heap-TID de-dup
-- CustomScan (DocumentDBApiTidDedup) that drops rows already emitted, so the
-- result still matches the deduplicating BitmapOr baseline.
--
-- This suite uses the order-capable extended_rum index AM, which is required for
-- the suffix order-by pushdown the rewrite depends on.
--
-- Assertion strategy:
--   * Correctness checks compare the row count with the feature OFF (BitmapOr,
--     deduplicated) against ON, so a regression that emits duplicates fails.
--   * "Feature ON" plan-shape checks run with enable_sort = off so the assertion
--     isolates "is a valid ordered MergeAppend path generated" from the cost
--     model's choice.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

SELECT documentdb_api.insert_one('msdb','__warmup','{ "_id": 1 }');
SELECT documentdb_api.drop_collection('msdb','__warmup');

SET documentdb.next_collection_id TO 39500;
SET documentdb.next_collection_index_id TO 39500;

SET documentdb.forceDisableSeqScan TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;

-- =====================================================================
-- Setup: composite index {a:1, b:1, c:1, d:1}.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','records');
SELECT documentdb_api.insert_one('msdb','records','{ "_id": 1, "a": 1, "b": 5, "c": 5, "d": 10 }');
SELECT documentdb_api.insert_one('msdb','records','{ "_id": 2, "a": 1, "b": 5, "c": 3, "d": 8 }');
SELECT documentdb_api.insert_one('msdb','records','{ "_id": 3, "a": 2, "b": 7, "c": 4, "d": 9 }');
SELECT documentdb_api.insert_one('msdb','records','{ "_id": 4, "a": 2, "b": 7, "c": 2, "d": 7 }');
SELECT documentdb_api.insert_one('msdb','records','{ "_id": 5, "a": 1, "b": 1, "c": 6, "d": 12 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "records", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1, "d": 1 }, "name": "abcd" } ] }', true);

-- =====================================================================
-- POSITIVE: disjoint branches ({a:1,b:5} vs {a:2,b:7}) sorted by c. The
-- branches are provably disjoint (a differs: 1 vs 2), so the rewrite is
-- sound. Expect a Merge Append and the c-ascending order 3,4,5.
-- =====================================================================
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "records", "filter": { "$or": [ { "a": 1, "b": 5 }, { "a": 2, "b": 7 } ] }, "sort": { "c": 1 } }');

SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS disjoint_has_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "records", "filter": { "$or": [ { "a": 1, "b": 5 }, { "a": 2, "b": 7 } ] }, "sort": { "c": 1 } }')
$cmd$) AS line;
SET enable_sort TO on;

-- Feature OFF for the same disjoint query keeps the deduplicating BitmapOr and
-- must return the identical rows/order (correctness is plan-independent).
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "records", "filter": { "$or": [ { "a": 1, "b": 5 }, { "a": 2, "b": 7 } ] }, "sort": { "c": 1 } }');
SET documentdb.enable_merge_sort_for_bitmap_or TO on;

-- =====================================================================
-- CORRECTNESS: overlapping branches must NOT emit duplicate rows. For every
-- case below the row count with the feature ON must equal the count with it
-- OFF (the BitmapOr baseline), proving the rewrite was rejected (or a sound
-- non-duplicating plan was chosen).
-- =====================================================================

-- Overlap 1: two range branches sorted by the leading column a. A document with
-- a >= 2 satisfies both branches, so a MergeAppend would double-count it. No
-- equality column distinguishes the branches, so the rewrite must be rejected.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS overlap_ranges_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "records", "filter": { "$or": [ { "a": { "$gte": 1 }, "b": { "$lte": 7 } }, { "a": { "$gte": 2 }, "b": { "$lte": 5 } } ] }, "sort": { "a": 1 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS overlap_ranges_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "records", "filter": { "$or": [ { "a": { "$gte": 1 }, "b": { "$lte": 7 } }, { "a": { "$gte": 2 }, "b": { "$lte": 5 } } ] }, "sort": { "a": 1 } }')
) s;

SET enable_sort TO off;
SELECT NOT bool_or(line ~ 'Merge Append') AS overlap_ranges_no_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "records", "filter": { "$or": [ { "a": { "$gte": 1 }, "b": { "$lte": 7 } }, { "a": { "$gte": 2 }, "b": { "$lte": 5 } } ] }, "sort": { "a": 1 } }')
$cmd$) AS line;
SET enable_sort TO on;

-- Overlap 2: identical branches. Every matching document matches both, so a
-- MergeAppend would emit each row twice. Must be rejected.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS overlap_identical_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "records", "filter": { "$or": [ { "a": 1, "b": 5 }, { "a": 1, "b": 5 } ] }, "sort": { "c": 1 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS overlap_identical_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "records", "filter": { "$or": [ { "a": 1, "b": 5 }, { "a": 1, "b": 5 } ] }, "sort": { "c": 1 } }')
) s;

-- Overlap 3: the branches share their full equality prefix (a=1, b=1) and differ
-- only in a trailing $gt on d. A document with a=1,b=1,d large matches both. The
-- planner factors the shared prefix into a single ordered scan carrying the $or(d)
-- as a Filter, so there is no BitmapOr and no duplicates; assert the counts match.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS overlap_prefix_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "records", "filter": { "$or": [ { "a": 1, "b": 1, "d": { "$gt": 6 } }, { "a": 1, "b": 1, "d": { "$gt": 5 } } ] }, "sort": { "c": 1 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS overlap_prefix_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "records", "filter": { "$or": [ { "a": 1, "b": 1, "d": { "$gt": 6 } }, { "a": 1, "b": 1, "d": { "$gt": 5 } } ] }, "sort": { "c": 1 } }')
) s;

SELECT documentdb_api.drop_collection('msdb','records');

-- =====================================================================
-- Collation: the disjointness check compares equality constants under the
-- query/index collation. Under a case-insensitive collation "Alpha" and
-- "alpha" are equal, so branches bound to them overlap and the rewrite must
-- be rejected (a naive byte comparison would wrongly treat them as disjoint
-- and emit duplicates).
-- =====================================================================
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;

SELECT documentdb_api.create_collection('msdb','coll_ci');
SELECT documentdb_api.insert_one('msdb','coll_ci','{ "_id": 1, "cat": "Alpha", "score": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_ci','{ "_id": 2, "cat": "alpha", "score": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_ci','{ "_id": 3, "cat": "Beta",  "score": 4 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_ci", "indexes": [ { "key": { "cat": 1, "score": 1 }, "name": "cat_ci", "enableOrderedIndex": 1, "collation": { "locale": "en", "strength": 2 } } ] }', true);

-- "Alpha" vs "alpha" are collation-equal: overlapping branches, reject the rewrite.
-- Feature OFF vs ON must return the identical (deduplicated) row count.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS coll_overlap_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "coll_ci", "filter": { "$or": [ { "cat": "Alpha" }, { "cat": "alpha" } ] }, "sort": { "score": 1 }, "collation": { "locale": "en", "strength": 2 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS coll_overlap_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "coll_ci", "filter": { "$or": [ { "cat": "Alpha" }, { "cat": "alpha" } ] }, "sort": { "score": 1 }, "collation": { "locale": "en", "strength": 2 } }')
) s;

SET enable_sort TO off;
SELECT NOT bool_or(line ~ 'Merge Append') AS coll_overlap_no_merge_append
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "coll_ci", "filter": { "$or": [ { "cat": "Alpha" }, { "cat": "alpha" } ] }, "sort": { "score": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$) AS line;
SET enable_sort TO on;

SELECT documentdb_api.drop_collection('msdb','coll_ci');

SET documentdb_core.enableCollation TO off;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO off;

-- =====================================================================
-- Order-by pushdown with an $elemMatch prefix and the sort key on the 3rd
-- index path. tags is an array (multi-key), so a document can appear under
-- multiple index entries; the ordered per-value fan-out is unsound and the
-- rewrite is not applied. Assert only that the result is correctly ordered
-- by rank (10,20,30) -- the plan keeps a Sort.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','tagged');
SELECT documentdb_api.insert_one('msdb','tagged','{ "_id": 1, "tags": [ { "k": "x", "v": 1 } ], "rank": 30 }');
SELECT documentdb_api.insert_one('msdb','tagged','{ "_id": 2, "tags": [ { "k": "x", "v": 1 } ], "rank": 10 }');
SELECT documentdb_api.insert_one('msdb','tagged','{ "_id": 3, "tags": [ { "k": "x", "v": 1 } ], "rank": 20 }');
SELECT documentdb_api.insert_one('msdb','tagged','{ "_id": 4, "tags": [ { "k": "y", "v": 2 } ], "rank": 5 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "tagged", "indexes": [ { "key": { "tags.k": 1, "tags.v": 1, "rank": 1 }, "name": "tags_rank", "enableOrderedIndex": 1 } ] }', true);

SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO on;

SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "tagged", "filter": { "tags": { "$elemMatch": { "k": "x", "v": 1 } } }, "sort": { "rank": 1 } }');

SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO off;
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO off;

SELECT documentdb_api.drop_collection('msdb','tagged');

-- =====================================================================
-- $or of two overlapping $elemMatch branches. An $elemMatch whose inner op
-- is an equality classifies to a DOLLAR_EQUAL index strategy, but the
-- physical index clause is a range operator whose constant is the elemMatch
-- spec document -- not the scalar equality value. The disjointness check must
-- therefore NOT capture it as an equality bound; otherwise two overlapping
-- elemMatch branches would be compared by their (differing) spec documents
-- and wrongly declared disjoint, dropping the deduplicating BitmapOr and
-- emitting duplicate rows. Feature OFF vs ON must return the identical count.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','em_or');
SELECT documentdb_api.insert_one('msdb','em_or','{ "_id": 1, "tags": [ { "k": "x", "v": 1 } ], "rank": 10 }');
SELECT documentdb_api.insert_one('msdb','em_or','{ "_id": 2, "tags": [ { "k": "x", "v": 1 }, { "k": "y", "v": 2 } ], "rank": 20 }');
SELECT documentdb_api.insert_one('msdb','em_or','{ "_id": 3, "tags": [ { "k": "y", "v": 2 } ], "rank": 30 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "em_or", "indexes": [ { "key": { "tags.k": 1, "tags.v": 1, "rank": 1 }, "name": "em_or_idx", "enableOrderedIndex": 1 } ] }', true);

SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS em_or_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "em_or", "filter": { "$or": [ { "tags": { "$elemMatch": { "k": "x", "v": 1 } } }, { "tags": { "$elemMatch": { "k": "y", "v": 2 } } } ] }, "sort": { "rank": 1 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS em_or_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "em_or", "filter": { "$or": [ { "tags": { "$elemMatch": { "k": "x", "v": 1 } } }, { "tags": { "$elemMatch": { "k": "y", "v": 2 } } } ] }, "sort": { "rank": 1 } }')
) s;

-- Soundness: whatever plan is chosen for the overlapping multi-key $or, a
-- MergeAppend (which does not de-duplicate) is only permissible when it is
-- wrapped in the heap-TID de-dup CustomScan. Assert the implication
-- "Merge Append => DocumentDBApiTidDedup" so an un-deduplicated MergeAppend
-- over overlapping array branches is caught even if the row count coincided.
SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS em_or_has_merge_append,
       (NOT bool_or(line ~ 'Merge Append'))
         OR bool_or(line ~ 'DocumentDBApiTidDedup') AS em_or_merge_is_deduped
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "em_or", "filter": { "$or": [ { "tags": { "$elemMatch": { "k": "x", "v": 1 } } }, { "tags": { "$elemMatch": { "k": "y", "v": 2 } } } ] }, "sort": { "rank": 1 } }')
$cmd$) AS line;
SET enable_sort TO on;

SELECT documentdb_api.drop_collection('msdb','em_or');

-- =====================================================================
-- Additional scalar coverage. Every non-disjoint case asserts
-- count(feature ON) = count(feature OFF, the deduplicating BitmapOr
-- baseline); a duplicate leak from an unsound MergeAppend fails the check
-- regardless of the plan the cost model picks. Collection {a,b,c,d}.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','or_scalar');
SELECT documentdb_api.insert_one('msdb','or_scalar','{ "_id": 1, "a": 1, "b": 2, "c": 30, "d": 1 }');
SELECT documentdb_api.insert_one('msdb','or_scalar','{ "_id": 2, "a": 1, "b": 2, "c": 10, "d": 2 }');
SELECT documentdb_api.insert_one('msdb','or_scalar','{ "_id": 3, "a": 1, "b": 3, "c": 20, "d": 3 }');
SELECT documentdb_api.insert_one('msdb','or_scalar','{ "_id": 4, "a": 3, "b": 4, "c": 15, "d": 4 }');
SELECT documentdb_api.insert_one('msdb','or_scalar','{ "_id": 5, "a": 3, "b": 4, "c": 25, "d": 5 }');
SELECT documentdb_api.insert_one('msdb','or_scalar','{ "_id": 6, "a": 1, "b": 3, "c": 5,  "d": 6 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "or_scalar", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "abc", "enableOrderedIndex": 1 } ] }', true);

-- Case A: three-way $or with an identical (overlapping) pair {a:1,b:2} plus a
-- disjoint branch {a:3,b:4}, sorted by the trailing key c. The identical pair
-- makes _id 1,2 reachable through two branches -- a plain MergeAppend would
-- double-count them.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS three_way_dup_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_scalar", "filter": { "$or": [ { "a": 1, "b": 2 }, { "a": 1, "b": 2 }, { "a": 3, "b": 4 } ] }, "sort": { "c": 1 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS three_way_dup_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_scalar", "filter": { "$or": [ { "a": 1, "b": 2 }, { "a": 1, "b": 2 }, { "a": 3, "b": 4 } ] }, "sort": { "c": 1 } }')
) s;

-- Case B: subset branches {a:1} and {a:1, c:{$gt:0}}. Every document of the
-- second branch also satisfies the first, so the branches fully overlap and a
-- MergeAppend without de-dup would repeat them.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS subset_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_scalar", "filter": { "$or": [ { "a": 1 }, { "a": 1, "c": { "$gt": 0 } } ] }, "sort": { "b": 1 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS subset_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_scalar", "filter": { "$or": [ { "a": 1 }, { "a": 1, "c": { "$gt": 0 } } ] }, "sort": { "b": 1 } }')
) s;

-- Case C: POSITIVE, provably disjoint on a trailing equality. {a:1,b:2} vs
-- {a:1,b:3} share the leading a but differ on the scalar b (2 vs 3), so no
-- document matches both. Sorted by c the rewrite is sound: expect a Merge
-- Append with NO de-dup scan (disjoint branches need no de-dup).
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "or_scalar", "filter": { "$or": [ { "a": 1, "b": 2 }, { "a": 1, "b": 3 } ] }, "sort": { "c": 1 } }');

SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS disjoint_b_has_merge_append,
       NOT bool_or(line ~ 'DocumentDBApiTidDedup') AS disjoint_b_no_dedup
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "or_scalar", "filter": { "$or": [ { "a": 1, "b": 2 }, { "a": 1, "b": 3 } ] }, "sort": { "c": 1 } }')
$cmd$) AS line;
SET enable_sort TO on;

SELECT documentdb_api.drop_collection('msdb','or_scalar');

-- =====================================================================
-- Multi-key array coverage. `vals` is an array, so a single document can hold
-- elements satisfying more than one $or branch and is reachable through each
-- branch. A plain MergeAppend would emit it once per branch, so the rewrite
-- is only sound when the MergeAppend is wrapped in the heap-TID de-dup scan.
-- Assert both count parity and the "Merge Append => de-dup" implication.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','or_mk');
SELECT documentdb_api.insert_one('msdb','or_mk','{ "_id": 1, "vals": [ 1, 2 ], "w": 20 }');
SELECT documentdb_api.insert_one('msdb','or_mk','{ "_id": 2, "vals": [ 1 ],    "w": 10 }');
SELECT documentdb_api.insert_one('msdb','or_mk','{ "_id": 3, "vals": [ 2 ],    "w": 30 }');
SELECT documentdb_api.insert_one('msdb','or_mk','{ "_id": 4, "vals": [ 3 ],    "w": 5  }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "or_mk", "indexes": [ { "key": { "vals": 1, "w": 1 }, "name": "vals_w", "enableOrderedIndex": 1 } ] }', true);

-- _id 1 has vals [1,2] and matches both {vals:1} and {vals:2}; the BitmapOr
-- baseline de-duplicates it to a single row.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS mk_or_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_mk", "filter": { "$or": [ { "vals": 1 }, { "vals": 2 } ] }, "sort": { "w": 1 } }')
) s;
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS mk_or_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_mk", "filter": { "$or": [ { "vals": 1 }, { "vals": 2 } ] }, "sort": { "w": 1 } }')
) s;

SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS mk_or_has_merge_append,
       (NOT bool_or(line ~ 'Merge Append'))
         OR bool_or(line ~ 'DocumentDBApiTidDedup') AS mk_or_merge_is_deduped
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "or_mk", "filter": { "$or": [ { "vals": 1 }, { "vals": 2 } ] }, "sort": { "w": 1 } }')
$cmd$) AS line;
SET enable_sort TO on;

SELECT documentdb_api.drop_collection('msdb','or_mk');

-- =====================================================================
-- De-dup stress: many documents each reachable through more than one $or
-- branch. `vals` is a multi-key array, so a document holding several matching
-- elements is emitted once per branch by a plain MergeAppend; the heap-TID
-- de-dup scan must collapse those back to one row so the count matches the
-- deduplicating BitmapOr baseline. Exercises both the plain projection (SELECT
-- document) and the column-pruning aggregation-above path (count(*)), which
-- forces a heap-fetching index scan so the surfaced ctid stays available.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','or_stress');
-- Each of the 90 documents carries every one of vals 1,2,3, so it matches all
-- three branches; a non-deduplicating plan would treble the row count.
SELECT COUNT(documentdb_api.insert_one('msdb','or_stress',
    FORMAT('{ "_id": %s, "vals": [ 1, 2, 3 ], "w": %s }', i, (i % 50))::documentdb_core.bson))
FROM generate_series(1, 90) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "or_stress", "indexes": [ { "key": { "vals": 1, "w": 1 }, "name": "vals_w", "enableOrderedIndex": 1 } ] }', true);

-- BitmapOr baseline (feature OFF): 90 distinct documents.
SET documentdb.enable_merge_sort_for_bitmap_or TO off;
SELECT count(*) AS stress_off FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_stress", "filter": { "$or": [ { "vals": 1 }, { "vals": 2 }, { "vals": 3 } ] }, "sort": { "w": 1 } }')
) s;

-- Feature ON, plain projection: the de-dup scan keeps the count at 90.
SET documentdb.enable_merge_sort_for_bitmap_or TO on;
SELECT count(*) AS stress_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_stress", "filter": { "$or": [ { "vals": 1 }, { "vals": 2 }, { "vals": 3 } ] }, "sort": { "w": 1 } }')
) s;

-- Feature ON, aggregation directly above (count(*) prunes the document column):
-- the branch scans must stay heap-fetching index scans so the de-dup ctid is
-- available; a regression here reintroduces the "variable not found in subplan
-- target list" planner error. Must equal the baseline (90).
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;
SELECT count(*) AS stress_agg_on FROM (
  SELECT document FROM bson_aggregation_find('msdb',
    '{ "find": "or_stress", "filter": { "$or": [ { "vals": 1 }, { "vals": 2 }, { "vals": 3 } ] }, "sort": { "w": 1 } }')
) s;
SET enable_seqscan TO on;
SET enable_bitmapscan TO on;

-- Plan shape: a MergeAppend over the overlapping multi-key branches is only
-- sound when wrapped in the de-dup scan.
SET enable_sort TO off;
SELECT bool_or(line ~ 'Merge Append') AS stress_has_merge_append,
       (NOT bool_or(line ~ 'Merge Append'))
         OR bool_or(line ~ 'DocumentDBApiTidDedup') AS stress_merge_is_deduped
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "or_stress", "filter": { "$or": [ { "vals": 1 }, { "vals": 2 }, { "vals": 3 } ] }, "sort": { "w": 1 } }')
$cmd$) AS line;
SET enable_sort TO on;

SELECT documentdb_api.drop_collection('msdb','or_stress');

-- =====================================================================
-- Different-index branches use the blocking Sort while the feature flag is
-- off. When enabled, the ordered scans from both composite indexes can be
-- merged because they provide the same requested scheduledTime order.
-- =====================================================================
SELECT documentdb_api.create_collection('msdb','flights');
SELECT documentdb_api.insert_one('msdb','flights',
  '{ "_id": 1, "departureAirport": "SEA", "arrivalAirport": "PDX", "scheduledTime": 30 }');
SELECT documentdb_api.insert_one('msdb','flights',
  '{ "_id": 2, "departureAirport": "SFO", "arrivalAirport": "SEA", "scheduledTime": 40 }');
SELECT documentdb_api.insert_one('msdb','flights',
  '{ "_id": 3, "departureAirport": "SEA", "arrivalAirport": "LAX", "scheduledTime": 10 }');
SELECT documentdb_api.insert_one('msdb','flights',
  '{ "_id": 4, "departureAirport": "DEN", "arrivalAirport": "SEA", "scheduledTime": 20 }');
SELECT documentdb_api.insert_one('msdb','flights',
  '{ "_id": 5, "departureAirport": "SEA", "arrivalAirport": "SEA", "scheduledTime": 50 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "flights", "indexes": [
      { "key": { "departureAirport": 1, "scheduledTime": -1 }, "name": "departure_time", "enableOrderedIndex": 1 },
      { "key": { "arrivalAirport": 1, "scheduledTime": -1 }, "name": "arrival_time", "enableOrderedIndex": 1 }
  ] }', true);

SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "flights", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 }, "limit": 10 }');

SET enable_sort TO off;
SELECT line AS different_indexes_flag_off_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 }, "limit": 10 }')
$cmd$) AS line;

SET documentdb.enable_cross_index_bitmap_or_sort_merge TO on;

-- _id 5 matches both branches but must appear only once after TID de-dup.
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "flights", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 }, "limit": 10 }');

SELECT line AS different_indexes_flag_on_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 }, "limit": 10 }')
$cmd$) AS line;
SET documentdb.enable_cross_index_bitmap_or_sort_merge TO off;
SET enable_sort TO on;

SELECT documentdb_api.drop_collection('msdb','flights');

-- =====================================================================
-- Different-index rejection cases. The feature flag is enabled and Sort is
-- disabled to make a valid MergeAppend path preferable, but every case below
-- has at least one branch that cannot provide the complete requested order.
-- =====================================================================
SET documentdb.enable_cross_index_bitmap_or_sort_merge TO on;
SET enable_sort TO off;

-- One branch has the requested sort path and the other index does not contain
-- that path at all.
SELECT documentdb_api.create_collection('msdb','flights_missing_order');
SELECT documentdb_api.insert_one('msdb','flights_missing_order',
  '{ "_id": 1, "departureAirport": "SEA", "arrivalAirport": "PDX", "scheduledTime": 30, "gate": 4 }');
SELECT documentdb_api.insert_one('msdb','flights_missing_order',
  '{ "_id": 2, "departureAirport": "SFO", "arrivalAirport": "SEA", "scheduledTime": 40, "gate": 2 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "flights_missing_order", "indexes": [
      { "key": { "departureAirport": 1, "scheduledTime": -1 }, "name": "departure_time", "enableOrderedIndex": 1 },
      { "key": { "arrivalAirport": 1, "gate": 1 }, "name": "arrival_gate", "enableOrderedIndex": 1 }
  ] }', true);

SELECT line AS missing_order_path_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_missing_order", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 } }')
$cmd$) AS line;

SELECT line AS missing_order_path_reversed_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_missing_order", "filter": { "$or": [ { "arrivalAirport": "SEA" }, { "departureAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 } }')
$cmd$) AS line;

SELECT documentdb_api.drop_collection('msdb','flights_missing_order');

-- A BitmapOr spanning the collection's _id B-tree and an ordered RUM index
-- cannot be replaced by a MergeAppend. The RUM branch can provide the requested
-- scheduledTime order, while the B-tree branch cannot.
SET enable_sort TO on;
SET documentdb.enable_support_function_id_pushdown TO on;
SELECT documentdb_api.create_collection('msdb','flights_mixed_access_methods');
SELECT documentdb_api.insert_one('msdb','flights_mixed_access_methods',
  '{ "_id": 1, "arrivalAirport": "PDX", "scheduledTime": 30 }');
SELECT documentdb_api.insert_one('msdb','flights_mixed_access_methods',
  '{ "_id": 2, "arrivalAirport": "SEA", "scheduledTime": 40 }');
SELECT COUNT(documentdb_api.insert_one(
  'msdb', 'flights_mixed_access_methods',
  FORMAT('{ "_id": %s, "arrivalAirport": "SFO", "scheduledTime": %s }',
         flight_id, flight_id)::bson))
FROM generate_series(100, 199) AS flight_id;
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "flights_mixed_access_methods", "indexes": [
      { "key": { "arrivalAirport": 1, "scheduledTime": -1 }, "name": "arrival_time", "enableOrderedIndex": 1 }
  ] }', true);
ANALYZE;

SELECT line AS mixed_btree_rum_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document
    FROM documentdb_api.collection('msdb', 'flights_mixed_access_methods')
    WHERE bson_dollar_eq(document, object_id, '{ "_id": 1 }')
       OR document @= '{ "arrivalAirport": "SEA" }'
    ORDER BY bson_orderby(document, '{ "scheduledTime": -1 }') DESC
$cmd$) AS line;

SELECT line AS mixed_btree_rum_reversed_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document
    FROM documentdb_api.collection('msdb', 'flights_mixed_access_methods')
    WHERE document @= '{ "arrivalAirport": "SEA" }'
       OR bson_dollar_eq(document, object_id, '{ "_id": 1 }')
    ORDER BY bson_orderby(document, '{ "scheduledTime": -1 }') DESC
$cmd$) AS line;

SELECT documentdb_api.drop_collection('msdb','flights_mixed_access_methods');
RESET documentdb.enable_support_function_id_pushdown;
SET enable_sort TO off;

-- A non-ordered RUM branch cannot participate with an ordered RUM branch,
-- even when both indexes contain the requested sort path.
SELECT documentdb_api.create_collection('msdb','flights_non_ordered_branch');
SELECT documentdb_api.insert_one('msdb','flights_non_ordered_branch',
  '{ "_id": 1, "departureAirport": "SEA", "arrivalAirport": "PDX", "scheduledTime": 30 }');
SELECT documentdb_api.insert_one('msdb','flights_non_ordered_branch',
  '{ "_id": 2, "departureAirport": "SFO", "arrivalAirport": "SEA", "scheduledTime": 40 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "flights_non_ordered_branch", "indexes": [
      { "key": { "departureAirport": 1, "scheduledTime": -1 }, "name": "departure_time_ordered", "enableOrderedIndex": 1 },
      { "key": { "arrivalAirport": 1, "scheduledTime": -1 }, "name": "arrival_time_non_ordered", "enableOrderedIndex": false }
  ] }', true);

SELECT line AS ordered_non_ordered_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_non_ordered_branch", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 } }')
$cmd$) AS line;

SELECT line AS ordered_non_ordered_reversed_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_non_ordered_branch", "filter": { "$or": [ { "arrivalAirport": "SEA" }, { "departureAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 } }')
$cmd$) AS line;

SELECT documentdb_api.drop_collection('msdb','flights_non_ordered_branch');

-- One branch provides the full compound order while the other provides only
-- its leading scheduledTime key.
SELECT documentdb_api.create_collection('msdb','flights_partial_order');
SELECT documentdb_api.insert_one('msdb','flights_partial_order',
  '{ "_id": 1, "departureAirport": "SEA", "arrivalAirport": "PDX", "scheduledTime": 30, "flightCode": "B" }');
SELECT documentdb_api.insert_one('msdb','flights_partial_order',
  '{ "_id": 2, "departureAirport": "SFO", "arrivalAirport": "SEA", "scheduledTime": 40, "flightCode": "A" }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "flights_partial_order", "indexes": [
      { "key": { "departureAirport": 1, "scheduledTime": -1, "flightCode": 1 }, "name": "departure_time_code", "enableOrderedIndex": 1 },
      { "key": { "arrivalAirport": 1, "scheduledTime": -1 }, "name": "arrival_time", "enableOrderedIndex": 1 }
  ] }', true);

SELECT line AS partial_order_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_partial_order", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1, "flightCode": 1 } }')
$cmd$) AS line;

SELECT line AS partial_order_reversed_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_partial_order", "filter": { "$or": [ { "arrivalAirport": "SEA" }, { "departureAirport": "SEA" } ] }, "sort": { "scheduledTime": -1, "flightCode": 1 } }')
$cmd$) AS line;

SELECT documentdb_api.drop_collection('msdb','flights_partial_order');

-- Both indexes contain the compound sort paths, but one has an incompatible
-- direction for the second key and can provide only the first sort key.
SELECT documentdb_api.create_collection('msdb','flights_direction_mismatch');
SELECT documentdb_api.insert_one('msdb','flights_direction_mismatch',
  '{ "_id": 1, "departureAirport": "SEA", "arrivalAirport": "PDX", "scheduledTime": 30, "gate": 4 }');
SELECT documentdb_api.insert_one('msdb','flights_direction_mismatch',
  '{ "_id": 2, "departureAirport": "SFO", "arrivalAirport": "SEA", "scheduledTime": 40, "gate": 2 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "flights_direction_mismatch", "indexes": [
      { "key": { "departureAirport": 1, "scheduledTime": -1, "gate": 1 }, "name": "departure_time_gate", "enableOrderedIndex": 1 },
      { "key": { "arrivalAirport": 1, "scheduledTime": -1, "gate": -1 }, "name": "arrival_time_gate", "enableOrderedIndex": 1 }
  ] }', true);

SELECT line AS direction_mismatch_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_direction_mismatch", "filter": { "$or": [ { "departureAirport": "SEA" }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1, "gate": 1 } }')
$cmd$) AS line;

SELECT documentdb_api.drop_collection('msdb','flights_direction_mismatch');

-- A range bound on the leading index path does not fix that path to one value,
-- so the following scheduledTime path cannot provide a global order.
SELECT documentdb_api.create_collection('msdb','flights_range_prefix');
SELECT documentdb_api.insert_one('msdb','flights_range_prefix',
  '{ "_id": 1, "departureAirport": "SEA", "arrivalAirport": "PDX", "scheduledTime": 30 }');
SELECT documentdb_api.insert_one('msdb','flights_range_prefix',
  '{ "_id": 2, "departureAirport": "SFO", "arrivalAirport": "SEA", "scheduledTime": 40 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "flights_range_prefix", "indexes": [
      { "key": { "departureAirport": 1, "scheduledTime": -1 }, "name": "departure_time", "enableOrderedIndex": 1 },
      { "key": { "arrivalAirport": 1, "scheduledTime": -1 }, "name": "arrival_time", "enableOrderedIndex": 1 }
  ] }', true);

SELECT line AS range_prefix_plan
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('msdb',
      '{ "find": "flights_range_prefix", "filter": { "$or": [ { "departureAirport": { "$gte": "S" } }, { "arrivalAirport": "SEA" } ] }, "sort": { "scheduledTime": -1 } }')
$cmd$) AS line;

SELECT documentdb_api.drop_collection('msdb','flights_range_prefix');

SET enable_sort TO on;
SET documentdb.enable_cross_index_bitmap_or_sort_merge TO off;
