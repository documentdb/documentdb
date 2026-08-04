SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal,public;

-- ============================================================================
-- Distinct custom scan (enableDistinctCustomScan) skip-scan over a compound
-- index whose trailing key carries a filter.
--
-- The distinct custom scan (DocumentDBApiDistinctQueryScan) emits one row per
-- distinct value of the distinct key. On a compound index it uses a skip-scan:
-- after emitting a row for the current leading-key value it asks the composite
-- opclass for a bound that jumps past every trailing-key value sharing that
-- leading value, landing the ordered scan directly on the next distinct
-- leading-key value instead of walking every matching (leading, trailing) pair.
--
-- For a distinct on "a":
--   * With an index on { a: 1 }, every "a" value is a single index entry with
--     many TIDs, so the per-entry TID skip already fetches one row per distinct
--     "a" value.
--   * With a filter on a trailing key (e.g. _id) the planner must instead use a
--     compound index { a: 1, _id: 1 } to push the _id bound into the index. Now
--     every (a, _id) pair is its OWN unique index entry (one TID each), so the
--     per-entry TID skip has nothing to collapse. The skip-scan bridges this by
--     re-seeking past the whole trailing-key range of the current "a" to the
--     next distinct "a".
--
-- documentdb.enableExtendedExplainPlans wraps the scan in a
-- DocumentDBApiExplainQueryScan node that reports "innerScanLoops", the number
-- of index entries the ordered scan actually walked. In both cases below
-- innerScanLoops stays proportional to the distinct-value count rather than the
-- matching-row count.
-- ============================================================================

SET documentdb.defaultUseCompositeOpClass TO on;

SET documentdb.next_collection_id TO 39900;
SET documentdb.next_collection_index_id TO 39900;

-- Index on the distinct key alone, and a compound index that also covers _id.
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dloop", "indexes": [ { "key": { "a": 1 }, "name": "idx_a" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dloop", "indexes": [ { "key": { "a": 1, "_id": 1 }, "name": "idx_a_id" } ] }', true);

-- 10 distinct "a" values (0..9), each with 1000 rows (_id 1..10000), so that a
-- large number of distinct _id values map to every single "a" value.
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dloop', bson_build_document('_id', i, 'a', i % 10))) FROM generate_series(1, 10000) AS i;
ANALYZE;

-- ============================================================================
-- Case 1: distinct on "a" with no trailing filter, using { a: 1 }.
-- The skip collapses the 1000 TIDs of each "a" value onto its single index
-- entry, so the inner Index Only Scan emits exactly one row per distinct "a"
-- value (actual rows=10) and the extended-explain wrapper reports
-- innerScanLoops=10. This is the efficient, intended behavior.
-- ============================================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

-- Correctness: distinct returns 0..9
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloop", "key": "a", "query": {}, "hint": { "a": 1 } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloop", "key": "a", "query": {}, "hint": { "a": 1 } }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 2: distinct on "a" with a trailing-key filter _id in (5, 5000), forcing
-- the compound index { a: 1, _id: 1 }.
-- Every (a, _id) pair is a unique index entry and a large number of _id values
-- match every "a", so the per-entry TID skip cannot collapse anything. The
-- skip-scan instead re-seeks past the whole matching _id range of the current
-- "a" to the next distinct "a", so the inner Index Scan emits one row per
-- distinct "a" value (actual rows=10) and innerScanLoops stays small (one seek
-- per distinct value plus the initial descent) instead of O(matching rows).
-- ============================================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

-- Correctness: still the same 10 distinct values (0..9)
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloop", "key": "a", "query": { "_id": { "$gt": 5, "$lt": 5000 } }, "hint": { "a": 1, "_id": 1 } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloop", "key": "a", "query": { "_id": { "$gt": 5, "$lt": 5000 } }, "hint": { "a": 1, "_id": 1 } }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 3: the distinct key is NOT the leading index column.
-- Index { b: 1, a: 1, c: 1 }, distinct on "a", query { b: 1, c: { $gt: 5 } }.
-- Here "b" is an equality-constrained prefix, "a" is the order-by (distinct)
-- column at index position 1, and "c" is the trailing filtered suffix. The
-- skip-scan must keep BOTH the equality prefix "b" and the order-by column "a"
-- pinned and only jump past the trailing "c" range to reach the next distinct
-- "a" value. Skipping past "a" itself (as if it were the leading column) would
-- jump straight to the end of the b=1 range and drop every distinct "a" value
-- after the first, so this case guards the correctness of the suffix-only bound.
-- b=1 covers _id 1..5000, whose a = _id % 10 spans all of 0..9, so distinct
-- must return every value 0..9.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dloopbac", "indexes": [ { "key": { "b": 1, "a": 1, "c": 1 }, "name": "idx_b_a_c" } ] }', true);

-- b=1 for _id 1..5000 and b=2 for _id 5001..10000; a = _id % 10 (0..9); c = _id.
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dloopbac', bson_build_document('_id', i, 'b', CASE WHEN i <= 5000 THEN 1 ELSE 2 END, 'a', i % 10, 'c', i))) FROM generate_series(1, 10000) AS i;
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

-- Correctness: distinct returns all of 0..9 (not just the first "a" value).
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloopbac", "key": "a", "query": { "b": 1, "c": { "$gt": 5 } }, "hint": { "b": 1, "a": 1, "c": 1 } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloopbac", "key": "a", "query": { "b": 1, "c": { "$gt": 5 } }, "hint": { "b": 1, "a": 1, "c": 1 } }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 4: descending order-by column -> reverse (backward) ordered scan.
-- Index { a: -1, _id: 1 }, distinct on "a". The distinct scan walks "a" in
-- ascending order, which over a descending index is a backward ordered scan.
-- The skip-scan re-seek only advances for forward scans, so for a backward
-- scan the opclass returns no bound and the scan falls back to the per-TID
-- skip. This case is a regression guard: an earlier version pushed the suffix
-- to the wrong end of the group for backward scans, so the re-seek never
-- advanced and the query looped forever. It must simply return 0..9.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dloop", "indexes": [ { "key": { "a": -1, "_id": 1 }, "name": "idx_adesc_id" } ] }', true);
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

-- Correctness (and, crucially, termination): distinct returns 0..9.
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloop", "key": "a", "query": { "_id": { "$gt": 5 } }, "hint": { "a": -1, "_id": 1 } }');
ROLLBACK;

-- ============================================================================
-- Case 5: forward scan whose skipped suffix is a DESCENDING index path.
-- Index { b: 1, a: 1, c: -1 }, distinct on "a", query { b: 1, c: { $gt: 5 } }.
-- "a" is ascending (forward scan) but the trailing "c" is stored descending, so
-- the end of each group in scan order is the smallest "c" (MinKey for the
-- descending path). The skip-scan still engages and jumps only the "c" suffix.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dloopbac", "indexes": [ { "key": { "b": 1, "a": 1, "c": -1 }, "name": "idx_b_a_cdesc" } ] }', true);
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

-- Correctness: distinct returns all of 0..9.
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloopbac", "key": "a", "query": { "b": 1, "c": { "$gt": 5 } }, "hint": { "b": 1, "a": 1, "c": -1 } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloopbac", "key": "a", "query": { "b": 1, "c": { "$gt": 5 } }, "hint": { "b": 1, "a": 1, "c": -1 } }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 6: compound $group whose order-by columns are NON-CONTIGUOUS because an
-- equality-constrained column sits between them.
-- Index { a: 1, b: 1, c: 1, d: 1 }, equalities a=1 AND c=5, group by (b, d).
-- The index still provides (b, d) order because a and c are pinned by equality,
-- but the order-by columns are b (index path 1) and d (index path 3) with the
-- equality-pinned c (index path 2) between them. The skippable suffix is
-- everything strictly AFTER the LAST order-by column (d, the last index path),
-- which is empty - so the skip-scan must fall back to the per-TID skip and must
-- NOT push d to its extreme. A regression that resolved the keep-count from the
-- FIRST order-by column plus the order-by count (1 + 2 = 3) instead of the
-- last order-by position + 1 (3 + 1 = 4) would treat d as a skippable suffix
-- and prune distinct d values, returning only one d per b (3 groups) instead of
-- the full 9.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dgap", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1, "d": 1 }, "name": "idx_gap_abcd" } ] }', true);
-- a=1 and c=5 for all target rows; b in 1..3, d in 1..3, many rows each.
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap', bson_build_document('_id', i, 'a', 1, 'b', ((i / 3) % 3) + 1, 'c', 5, 'd', (i % 3) + 1))) FROM generate_series(1, 900) AS i;
-- Noise rows with a different c so the c=5 equality really selects a subset.
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap', bson_build_document('_id', 1000 + i, 'a', 1, 'b', ((i / 3) % 3) + 1, 'c', 9, 'd', (i % 3) + 1))) FROM generate_series(1, 90) AS i;
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableGroupByDistinctScan TO on;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb_core.enableWriteDocumentsInRepath TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

-- Correctness: all 9 distinct (b, d) combinations must be returned.
SELECT document FROM bson_aggregation_pipeline('dtk_db',
  '{ "aggregate": "dgap", "hint": "idx_gap_abcd", "pipeline": [
    { "$match": { "a": 1, "c": 5 } },
    { "$group": { "_id": { "b": "$b", "d": "$d" } } },
    { "$sort": { "_id.b": 1, "_id.d": 1 } }
  ] }');

-- Plan: the distinct scan engages but must walk one entry per (b, d) group.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_pipeline('dtk_db',
  '{ "aggregate": "dgap", "hint": "idx_gap_abcd", "pipeline": [
    { "$match": { "a": 1, "c": 5 } },
    { "$group": { "_id": { "b": "$b", "d": "$d" } } },
    { "$sort": { "_id.b": 1, "_id.d": 1 } }
  ] }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 7: interleaved equality gap AND a real trailing suffix to skip.
-- Index { a, b, c, d, e }, equalities a=1 AND c=5, group by (b, d), filter e>5.
-- Order-by columns b (path 1) and d (path 3) with the equality-pinned c
-- (path 2) between them; e (path 4) is a genuine trailing suffix after the last
-- order-by column. keepPathCount = lastOrderByPath(3) + 1 = 4, so only e is
-- skipped while c stays pinned. All 9 distinct (b, d) groups must be returned
-- and the skip-scan must engage (walking ~one entry per (b, d) group, not one
-- per matching row).
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dgap7", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1, "d": 1, "e": 1 }, "name": "idx7_abcde" } ] }', true);
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap7', bson_build_document('_id', i, 'a', 1, 'b', ((i / 300) % 3) + 1, 'c', 5, 'd', ((i / 100) % 3) + 1, 'e', (i % 10) + 1))) FROM generate_series(1, 900) AS i;
-- Noise with a different c so the c=5 equality really selects a subset.
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap7', bson_build_document('_id', 5000 + i, 'a', 1, 'b', ((i / 30) % 3) + 1, 'c', 9, 'd', (i % 3) + 1, 'e', (i % 10) + 1))) FROM generate_series(1, 90) AS i;
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableGroupByDistinctScan TO on;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb_core.enableWriteDocumentsInRepath TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT document FROM bson_aggregation_pipeline('dtk_db',
  '{ "aggregate": "dgap7", "hint": "idx7_abcde", "pipeline": [
    { "$match": { "a": 1, "c": 5, "e": { "$gt": 5 } } },
    { "$group": { "_id": { "b": "$b", "d": "$d" } } },
    { "$sort": { "_id.b": 1, "_id.d": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_pipeline('dtk_db',
  '{ "aggregate": "dgap7", "hint": "idx7_abcde", "pipeline": [
    { "$match": { "a": 1, "c": 5, "e": { "$gt": 5 } } },
    { "$group": { "_id": { "b": "$b", "d": "$d" } } },
    { "$sort": { "_id.b": 1, "_id.d": 1 } }
  ] }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 8: equality columns in the SKIPPABLE suffix after a single order-by.
-- Index { a, b, c, d }, equalities a=1 AND c=5, group by (b) alone. Order-by is
-- b (path 1); the suffix to skip is c (path 2, equality-pinned) and d (path 3).
-- keepPathCount = 1 + 1 = 2, so both c and d are pushed to their extreme to
-- jump to the next distinct b. Pushing an equality-pinned suffix column is safe
-- because the equality is re-applied by the scan's consistency check after the
-- re-seek. All 5 distinct b values must be returned.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dgap8", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1, "d": 1 }, "name": "idx8_abcd" } ] }', true);
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap8', bson_build_document('_id', i, 'a', 1, 'b', ((i / 30) % 5) + 1, 'c', 5, 'd', (i % 3) + 1))) FROM generate_series(1, 750) AS i;
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap8', bson_build_document('_id', 5000 + i, 'a', 1, 'b', ((i / 6) % 5) + 1, 'c', 9, 'd', (i % 3) + 1))) FROM generate_series(1, 90) AS i;
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableGroupByDistinctScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT document FROM bson_aggregation_pipeline('dtk_db',
  '{ "aggregate": "dgap8", "hint": "idx8_abcd", "pipeline": [
    { "$match": { "a": 1, "c": 5 } },
    { "$group": { "_id": "$b" } },
    { "$sort": { "_id": 1 } }
  ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_pipeline('dtk_db',
  '{ "aggregate": "dgap8", "hint": "idx8_abcd", "pipeline": [
    { "$match": { "a": 1, "c": 5 } },
    { "$group": { "_id": "$b" } },
    { "$sort": { "_id": 1 } }
  ] }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 9: multi-column equality prefix + interleaved equality, order-by reaches
-- the last index path. Index { a, b, c, d, e }, equalities a=1 AND b=2 AND d=7,
-- group by (c, e). Order-by columns c (path 2) and e (path 4); equality prefix
-- a (0), b (1); equality-pinned d (path 3) sits between the two order-by
-- columns. The last order-by column e is the final index path, so
-- keepPathCount = 4 + 1 = 5 = numIndexPaths and the skip-scan falls back to the
-- per-TID skip (nothing after e to skip). All 9 distinct (c, e) groups must be
-- returned. Guards against a regression that treated the interleaved d as a
-- skippable suffix.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dgap9", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1, "d": 1, "e": 1 }, "name": "idx9_abcde" } ] }', true);
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap9', bson_build_document('_id', i, 'a', 1, 'b', 2, 'c', ((i / 3) % 3) + 1, 'd', 7, 'e', (i % 3) + 1))) FROM generate_series(1, 900) AS i;
-- Noise with a different d so the d=7 equality really selects a subset.
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dgap9', bson_build_document('_id', 5000 + i, 'a', 1, 'b', 2, 'c', ((i / 3) % 3) + 1, 'd', 8, 'e', (i % 3) + 1))) FROM generate_series(1, 90) AS i;
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL enable_sort TO off;
SET LOCAL documentdb.enableGroupByDistinctScan TO on;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET LOCAL documentdb_core.enableWriteDocumentsInRepath TO on;

SELECT document FROM bson_aggregation_pipeline('dtk_db',
  '{ "aggregate": "dgap9", "hint": "idx9_abcde", "pipeline": [
    { "$match": { "a": 1, "b": 2, "d": 7 } },
    { "$group": { "_id": { "c": "$c", "e": "$e" } } },
    { "$sort": { "_id.c": 1, "_id.e": 1 } }
  ] }');
ROLLBACK;

-- ============================================================================
-- Case 10: single-key distinct whose skippable suffix contains an UNCONSTRAINED
-- gap column ahead of the filtered trailing column.
-- Index { a: 1, c: 1, b: 1 }, distinct on "a", filter { b: { $gt: 5 } }. The
-- distinct column "a" is the only order-by (index path 0); "c" (index path 1)
-- is neither the distinct key nor constrained by the query, and the filter "b"
-- lives at index path 2 AFTER that gap. keepPathCount = 0 + 1 = 1, so both the
-- unconstrained gap "c" and the filtered "b" are the skippable suffix: after
-- emitting a row for the current "a" the skip-scan pushes BOTH c and b to their
-- extreme and jumps straight to the next distinct "a". This is safe even though
-- "c" is unconstrained because we only need one row per distinct "a" and the
-- b>5 filter is re-applied by the scan's consistency check on the landed entry.
-- Because the gap column "c" (not "b") orders entries within each "a" group, the
-- b>5 rows are not contiguous at the group start, so after each skip the scan
-- walks a few residual entries until b>5 matches before skipping again. The
-- resulting innerScanLoops stays a small multiple of the distinct-"a" count (10)
-- and far below the number of matching (a, c, b) rows; distinct still returns
-- all of 0..9.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dloopacb", "indexes": [ { "key": { "a": 1, "c": 1, "b": 1 }, "name": "idx_a_c_b" } ] }', true);
-- a = i % 10 (0..9); b = (i / 10) % 10 varies across 0..9 within every "a"
-- residue class, so b>5 selects a subset that still covers all 10 "a" values;
-- c = i is unique so each (a, c, b) is its own index entry with a single TID.
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dloopacb', bson_build_document('_id', i, 'a', i % 10, 'c', i, 'b', (i / 10) % 10))) FROM generate_series(1, 10000) AS i;
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

-- Correctness: distinct returns all of 0..9.
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloopacb", "key": "a", "query": { "b": { "$gt": 5 } }, "hint": { "a": 1, "c": 1, "b": 1 } }');

-- Plan: skip-scan jumps the whole (c, b) suffix, so innerScanLoops stays a
-- small multiple of the distinct-"a" count rather than the matching-row count.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dloopacb", "key": "a", "query": { "b": { "$gt": 5 } }, "hint": { "a": 1, "c": 1, "b": 1 } }')
$cmd$, p_ignore_heap_fetches := true);
ROLLBACK;

-- ============================================================================
-- Case 11: PARALLEL scan must NOT apply the skip-scan optimization.
-- Same layout as Case 10 (distinct on "a", filter b>5, index { a: 1, c: 1, b: 1 })
-- but forced to run as a parallel ordered index scan. The skip-scan re-seek does
-- not coordinate with parallel workers, so
-- documentdb_rum_skip_tids_on_current_entry gates the optimization on
-- scan->parallel_scan == NULL and falls back to the per-TID skip whenever the
-- scan is parallel. This case validates that the parallel path still returns
-- every distinct "a" value (0..9). Correctness - not the loop count - is the
-- observable guarantee here, because per-worker loop counts are split across
-- workers and are not deterministic, so this case does not pin innerScanLoops.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('dtk_db', '{ "createIndexes": "dlooppar", "indexes": [ { "key": { "a": 1, "c": 1, "b": 1 }, "name": "idxpar_a_c_b" } ] }', true);
SELECT COUNT(documentdb_api.insert_one('dtk_db', 'dlooppar', bson_build_document('_id', i, 'a', i % 10, 'c', i, 'b', (i / 10) % 10))) FROM generate_series(1, 10000) AS i;

-- Give the heap table parallel workers and freeze it for an Index Only Scan.
SELECT collection_id AS par_col FROM documentdb_api_catalog.collections
    WHERE database_name = 'dtk_db' AND collection_name = 'dlooppar' \gset
SELECT FORMAT('ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off, parallel_workers = 2)', :par_col) \gexec
SELECT FORMAT('VACUUM (FREEZE, ANALYZE) documentdb_data.documents_%s', :par_col) \gexec

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableCompositeParallelIndexScan TO on;
SET LOCAL documentdb.forceParallelScanIfAvailable TO on;

-- Plan: a parallel Gather over the DistinctQueryScan confirms the parallel path.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dlooppar", "key": "a", "query": { "b": { "$gt": 5 } }, "hint": { "a": 1, "c": 1, "b": 1 } }');

-- Correctness under parallelism: distinct still returns all of 0..9.
SELECT document FROM bson_aggregation_distinct('dtk_db', '{ "distinct": "dlooppar", "key": "a", "query": { "b": { "$gt": 5 } }, "hint": { "a": 1, "c": 1, "b": 1 } }');
ROLLBACK;
