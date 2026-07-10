SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 21100;
SET documentdb.next_collection_index_id TO 21100;

-- Enable the composite index planner, which is responsible for pushing equality
-- prefixes, ranges, and order-by clauses down into ordered composite index scans.
set documentdb.enableCompositeIndexPlanner to on;

-- Enable global index metadata tracking. With this on, the composite index records
-- per-path multi-key state in its opclass metadata. The intent is for the planner to
-- decide whether multiple bounds on a path may be merged based on whether that
-- *specific path* is multi-key, rather than on a single index-wide multi-key flag.
set documentdb.enableIndexMetadataGlobalTracking to on;

-- Respect the per-path multi-key bitmask when deciding order-by pushdown for the
-- ORDER BY cases below. This defaults to on; it is pinned explicitly so the order-by
-- plan shapes (Cases 2b, 5b) are deterministic regardless of the default.
set documentdb.enablePerPathMultiKeySortPushdown to on;

set documentdb.enableExtendedExplainPlans to on;
-- Suppress per-index cost details so explain output is stable across runs.
set documentdb.enableExplainScanIndexCosts to off;
-- Force index usage so the scan/bounds plan shape surfaces deterministically.
set enable_seqscan to off;
-- Disable bitmap scans so the planner picks the ordered index-scan path; a bitmap
-- scan cannot carry index ordering or composite bounds the same way.
set enable_bitmapscan to off;

-- ============================================================================
-- Per-path multi-key FILTER BOUND MERGING contract.
--
-- This suite validates how multiple range bounds on the SAME indexed path are
-- handled, depending on whether that path is multi-key. The signal is the
-- "indexBounds:" line in the extended explain output:
--   * A single merged bound per path renders as ONE bound set, e.g.
--       indexBounds: ["a": (1, 10), "b": (MinKey, MaxKey)]
--   * Multiple un-merged bounds on a path render as MULTIPLE comma-separated
--     bound sets, e.g.
--       indexBounds: ["a": (1, Infinity], ...], ["a": [-Infinity, 10), ...]
--
-- The documented contract for a composite index (a, b, c):
--   Rule 1: A single filter on a path -> one bound. Always valid.
--   Rule 2: Multiple filters on a path, the path is NOT multi-key -> both filters
--           are valid and their bounds MERGE into a single bound.
--   Rule 3: Multiple filters on a path, the path IS multi-key -> all bounds are
--           valid and BOTH bounds must be present (NOT merged), because distinct
--           array elements may independently satisfy each side of the range.
--   Rule 4: Multiple filters on a path, the index is multi-key on SOME OTHER path
--           but the filtered path itself is NOT multi-key -> both filters are valid
--           and their bounds MERGE into a single bound (same as Rule 2; the merge
--           decision is per-path, not index-wide).
--
-- ----------------------------------------------------------------------------
-- SUMMARY OF OBSERVED BEHAVIOR (see each case below for the evidence):
--
--   Case | Filtered path | Multi-key path(s) | Contract | Merged?
--   -----+---------------+-------------------+----------+--------------------
--    1   | a (eq)        | none              | 1: one   | yes (single bound)
--    2   | a (range)     | none              | 2: merge | yes  (UPHELD)
--    3   | a (range)     | a                 | 3: keep  | no   (UPHELD)
--    4   | b (range)     | a (b is scalar)   | 4: merge | yes  (UPHELD)
--    5   | a (range)     | b (a is scalar)   | 4: merge | yes  (UPHELD)
--    6   | b (range)     | b                 | 3: keep  | no   (UPHELD)
--    7   | a (range)     | a and b           | 3: keep  | no   (UPHELD)
--
-- All four rules hold. The merge decision is driven by PER-PATH multi-key state:
-- bounds on a filtered path merge into a single bound exactly when that specific
-- path is not multi-key (Rules 2 and 4), and are kept separate only when the
-- filtered path itself is multi-key (Rule 3). Cases 4 and 5 are the key per-path
-- cases: the index is multi-key on some other path, yet because the filtered path
-- is scalar its bounds still merge, distinguishing per-path tracking from an
-- index-wide multi-key flag (which would have blocked the merge).
--
-- The per-path merge is gated on documentdb.enablePerPathMultiKeySortPushdown; the
-- final scenario re-runs Cases 4/4b/5/5b with that flag OFF and confirms they revert
-- to the conservative two-bound (un-merged) behavior.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Fixture 1: a fully scalar collection on a composite (a, b, c) ordered index.
-- Exercises Rule 1 (single filter) and Rule 2 (range merges when no path is
-- multi-key).
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkf_db', '{ "createIndexes": "scalar_coll", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }');

SELECT documentdb_api.insert_one('mkf_db', 'scalar_coll', '{ "_id": 1, "a": 5, "b": 5, "c": 5 }');
SELECT documentdb_api.insert_one('mkf_db', 'scalar_coll', '{ "_id": 2, "a": 7, "b": 7, "c": 7 }');
SELECT documentdb_api.insert_one('mkf_db', 'scalar_coll', '{ "_id": 3, "a": 9, "b": 9, "c": 9 }');

-- Case 1 (Rule 1): a single equality filter on the leading path "a" yields a single
-- point bound on "a" and full ranges on the trailing paths. Always valid.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "scalar_coll", "filter": { "a": 5 }, "hint": "a_b_c_1" }') $cmd$);

-- Case 2 (Rule 2, UPHELD): a two-sided range on "a" with no multi-key path. The two
-- filters ($gt and $lt) MERGE into a single bound: indexBounds shows ["a": (1, 10), ...]
-- as ONE bound set.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "scalar_coll", "filter": { "a": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_c_1" }') $cmd$);

-- Case 2b (Rule 2 with ORDER BY): the same range with a sort on "a". The merged single
-- bound is preserved and the order by is pushed onto the scan.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "scalar_coll", "filter": { "a": { "$gt": 1, "$lt": 10 } }, "sort": { "a": 1 }, "hint": "a_b_c_1" }') $cmd$);

-- ----------------------------------------------------------------------------
-- Fixture 2: a composite (a, b) ordered index where the LEADING path "a" is
-- multi-key (an array value is inserted for "a") and "b" is scalar.
-- Exercises Rule 3 (range on multi-key "a" keeps both bounds) and Rule 4 (range on
-- scalar "b" should merge, but currently does not).
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkf_db', '{ "createIndexes": "a_multikey_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');

SELECT documentdb_api.insert_one('mkf_db', 'a_multikey_coll', '{ "_id": 1, "a": [ 5, 16 ], "b": 3 }');
SELECT documentdb_api.insert_one('mkf_db', 'a_multikey_coll', '{ "_id": 2, "a": 7, "b": 4 }');

-- Case 3 (Rule 3, UPHELD): "a" is multi-key (explain reports multiKeyPaths: a) and a
-- two-sided range is applied to "a". The bounds are NOT merged: indexBounds renders
-- TWO bound sets on "a" (the $gt side and the $lt side separately), because distinct
-- array elements may independently satisfy each side.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "a_multikey_coll", "filter": { "a": { "$gt": 1, "$lt": 20 } }, "hint": "a_b_1" }') $cmd$);

-- Case 4 (Rule 4, UPHELD): the filtered path is the SCALAR path "b" while only "a"
-- is multi-key. Because "b" is not multi-key, its two bounds MERGE into a single
-- bound: indexBounds renders ONE bound set ["a": (MinKey, MaxKey), "b": (1, 10)].
-- This is the key per-path case -- the merge happens even though the index is
-- multi-key (via "a"), because the merge decision consults the per-path state of the
-- filtered path "b", not an index-wide multi-key flag.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "a_multikey_coll", "filter": { "b": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_1" }') $cmd$);

-- Case 4b (Rule 4, UPHELD, with equality prefix): pin "a" to a single value and
-- range over the scalar "b". The two bounds on "b" MERGE into one bound
-- ["a": [7, 7], "b": (1, 10)], same per-path reason as Case 4.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "a_multikey_coll", "filter": { "a": 7, "b": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_1" }') $cmd$);

-- ----------------------------------------------------------------------------
-- Fixture 3: a composite (a, b) ordered index where the TRAILING path "b" is
-- multi-key and the leading path "a" is scalar.
-- Exercises Rule 4 (range on scalar "a" merges) and Rule 3 (range on multi-key "b"
-- keeps both bounds).
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkf_db', '{ "createIndexes": "b_multikey_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');

SELECT documentdb_api.insert_one('mkf_db', 'b_multikey_coll', '{ "_id": 1, "a": 5, "b": [ 3, 9 ] }');
SELECT documentdb_api.insert_one('mkf_db', 'b_multikey_coll', '{ "_id": 2, "a": 7, "b": 4 }');

-- Case 5 (Rule 4, UPHELD): the filtered path is the SCALAR leading path "a" while
-- only "b" is multi-key. The two bounds on "a" MERGE into a single bound:
-- indexBounds renders ONE bound set ["a": (1, 10), "b": (MinKey, MaxKey)], because
-- the filtered path "a" is itself scalar even though the index is multi-key via "b".
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "b_multikey_coll", "filter": { "a": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_1" }') $cmd$);

-- Case 5b (Rule 4, UPHELD, with ORDER BY): the same scalar-"a" range with a sort on
-- "a". As in Case 2b, the two bounds on the scalar path "a" merge into a single tight
-- range bound ["a": (1, 10), ...] and the order by is pushed onto the ordered scan.
-- The per-path merge applies even though the index is multi-key (via "b").
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "b_multikey_coll", "filter": { "a": { "$gt": 1, "$lt": 10 } }, "sort": { "a": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case 6 (Rule 3, UPHELD): the filtered path is the multi-key path "b". A two-sided
-- range on "b" keeps BOTH bounds (indexBounds renders two bound sets on "b").
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "b_multikey_coll", "filter": { "b": { "$gt": 1, "$lt": 20 } }, "hint": "a_b_1" }') $cmd$);

-- ----------------------------------------------------------------------------
-- Fixture 4: a composite (a, b) ordered index where BOTH paths are multi-key.
-- Exercises Rule 3 on the leading path "a".
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkf_db', '{ "createIndexes": "both_multikey_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');

SELECT documentdb_api.insert_one('mkf_db', 'both_multikey_coll', '{ "_id": 1, "a": [ 5, 16 ], "b": [ 3, 9 ] }');
SELECT documentdb_api.insert_one('mkf_db', 'both_multikey_coll', '{ "_id": 2, "a": 7, "b": 4 }');

-- Case 7 (Rule 3, UPHELD): "a" is multi-key and carries a two-sided range. The bounds
-- are NOT merged (two bound sets on "a"), matching the multi-key path rule.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "both_multikey_coll", "filter": { "a": { "$gt": 1, "$lt": 20 } }, "hint": "a_b_1" }') $cmd$);

-- Case 7b (Rule 1 on a multi-key index): an equality filter on each path yields single
-- point bounds even though both paths are multi-key. A single equality is always one
-- bound regardless of multi-key state.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "both_multikey_coll", "filter": { "a": 5, "b": 3 }, "hint": "a_b_1" }') $cmd$);

-- ============================================================================
-- Scenario: the per-path merge is gated on documentdb.enablePerPathMultiKeySortPushdown.
-- With the flag OFF, the merge logic can no longer trust the per-path multi-key
-- bitmask, so any multi-key index falls back to the conservative index-wide rule:
-- a filtered path's multiple bounds are NOT merged even when that path is itself
-- scalar. This reverts Cases 4, 4b, 5, 5b to two separate bound sets (the "diverged"
-- behavior), while the already-merged scalar-index Cases 2/2b are unaffected (they
-- have no multi-key path so the gate never engages).
-- ============================================================================
set documentdb.enablePerPathMultiKeySortPushdown to off;

-- Case 4-off (reverts): scalar path "b" range, index multi-key via "a". With the flag
-- off the bounds on "b" are NO LONGER merged -- indexBounds renders TWO bound sets on
-- "b", matching the conservative index-wide behavior.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "a_multikey_coll", "filter": { "b": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_1" }') $cmd$);

-- Case 4b-off (reverts): equality on "a" plus scalar "b" range; "b" bounds revert to
-- two separate bound sets.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "a_multikey_coll", "filter": { "a": 7, "b": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_1" }') $cmd$);

-- Case 5-off (reverts): scalar leading path "a" range, index multi-key via "b". The
-- bounds on "a" revert to two separate bound sets.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "b_multikey_coll", "filter": { "a": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_1" }') $cmd$);

-- Case 5b-off (reverts): the same scalar-"a" range with a sort on "a". With the flag
-- off the per-path order-by pushdown is also disabled, so a separate Sort node appears
-- above a regular index scan whose bounds on "a" are the two un-merged bound sets.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "b_multikey_coll", "filter": { "a": { "$gt": 1, "$lt": 10 } }, "sort": { "a": 1 }, "hint": "a_b_1" }') $cmd$);

-- Control: a fully scalar index (Case 2) still merges with the flag off, because it
-- has no multi-key path and the gate never engages.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "scalar_coll", "filter": { "a": { "$gt": 1, "$lt": 10 } }, "hint": "a_b_c_1" }') $cmd$);

set documentdb.enablePerPathMultiKeySortPushdown to on;
-- ============================================================================
-- Per-path multi-key RUNTIME RECHECK gating for $eq null and the range operators
-- against null ($gt / $gte / $lt / $lte), plus the scalar-value negations
-- $ne <scalar> / $nin <scalars>.
--
-- The [MinKey, null] bound generated for $eq null (and $gte / $lte null) also
-- matches undefined index terms -- missing fields AND empty arrays. A missing
-- field is a genuine match for these operators (null matches a missing path), but
-- an empty array must NOT match, so historically they always forced a heap
-- runtime recheck to filter the empty-array false positive.
--
-- With per-path multi-key metadata tracking (mkp=true) an empty array marks its
-- path multi-key, so a path reported as NON-multi-key is guaranteed to contain no
-- arrays at all. On such a path the bound is exact and the runtime recheck can be
-- skipped. The optimization is therefore gated on mkp: only a metadata-tracked
-- index may drop the recheck; a legacy (mkp=false) index conservatively keeps it,
-- because without tracking an empty array would not be reflected in the multi-key
-- state and would leak through.
--
-- The negations $ne / $nin also match undefined index terms (missing fields and
-- empty arrays). They register a term-level recheck that, on a NON-multi-key path,
-- is exact -- it excludes a missing / literal-null term directly (no arrays exist,
-- so an undefined term can only be missing / literal null) and excludes the
-- matching scalar term. So on a non-multi-key path the heap runtime recheck is
-- skipped for $ne / $nin as well, whether or not null is among the excluded values.
-- On a multi-key path the empty-array ambiguity remains, so the heap recheck is
-- preserved. The null-excluding negations ($ne null / $nin [.., null]) are covered
-- in bson_composite_index_null_recheck_gating_tests.
--
-- Observability: when the recheck runs and removes a false positive, explain
-- reports "Rows Removed by Index Recheck: N" on the inner Index Scan. When the
-- recheck is skipped, that line is absent.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Case R1 (mkp=true, non-multi-key path -> recheck SKIPPED). The path "a" holds
-- only scalars, missing fields, and literal null (no arrays), so it is not
-- multi-key. $eq null and the scalar negations $ne 5 / $nin [5] drop the recheck:
-- no "Rows Removed by Index Recheck" line, and the results are still correct.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkf_db', '{ "createIndexes": "null_scalar_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkf_db', 'null_scalar_coll', '{ "_id": 1, "a": null, "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_scalar_coll', '{ "_id": 2, "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_scalar_coll', '{ "_id": 3, "a": 5, "b": 1 }');

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": null }, "hint": "a_b_1" }') $cmd$);
-- $eq null matches literal null and missing (_id 1, 2), not the scalar (_id 3).
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');
-- $ne 5 matches everything except the scalar 5 (_id 1, 2).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": { "$ne": 5 } }, "hint": "a_b_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": { "$ne": 5 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');
-- $nin [5] behaves like $ne 5 here (_id 1, 2).
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": { "$nin": [ 5 ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');

-- ----------------------------------------------------------------------------
-- Case R2 (mkp=true, multi-key path -> recheck PRESERVED). An empty array on "a"
-- makes the path multi-key (isMultiKey: true). The empty array indexes as an
-- undefined term that falls inside the [MinKey, null] bound, so the recheck fires
-- and removes it: "Rows Removed by Index Recheck: 1". $eq null must NOT return the
-- empty-array document.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkf_db', '{ "createIndexes": "null_mk_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkf_db', 'null_mk_coll', '{ "_id": 1, "a": null, "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_mk_coll', '{ "_id": 2, "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_mk_coll', '{ "_id": 3, "a": [ ], "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_mk_coll', '{ "_id": 4, "a": 5, "b": 1 }');

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_mk_coll", "filter": { "a": null }, "hint": "a_b_1" }') $cmd$);
-- The empty array (_id 3) is excluded; only literal null and missing match (_id 1, 2).
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_mk_coll", "filter": { "a": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');

-- ----------------------------------------------------------------------------
-- Case R3 (mkp=false, empty array present -> recheck PRESERVED by the gate). The
-- index is built with metadata tracking OFF, so the empty array is NOT reflected
-- in the multi-key state and the path still reports isMultiKey: false. The gate
-- must therefore fall back to the conservative behavior and keep the recheck --
-- "Rows Removed by Index Recheck: 1" -- so the empty array is still excluded from
-- $eq null. This is the case the mkp restriction protects: dropping the recheck
-- here would wrongly return the empty-array document.
-- ----------------------------------------------------------------------------
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkf_db', '{ "createIndexes": "null_legacy_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('mkf_db', 'null_legacy_coll', '{ "_id": 1, "a": null, "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_legacy_coll', '{ "_id": 2, "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_legacy_coll', '{ "_id": 3, "a": [ ], "b": 1 }');
SELECT documentdb_api.insert_one('mkf_db', 'null_legacy_coll', '{ "_id": 4, "a": 5, "b": 1 }');

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_legacy_coll", "filter": { "a": null }, "hint": "a_b_1" }') $cmd$);
-- Despite isMultiKey: false, the recheck still runs and excludes the empty array
-- (_id 3): only literal null and missing match (_id 1, 2).
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_legacy_coll", "filter": { "a": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');

-- ----------------------------------------------------------------------------
-- Case R4: the same recheck gating applies to the null-anchored range operators
-- $gte / $lte (and $gt / $lt). $gte null and $lte null both generate a
-- [MinKey, null] bound that spans the undefined region (missing fields + empty
-- arrays), exactly like $eq null.
--
-- R4a (mkp=true, non-multi-key path -> recheck SKIPPED): $gte null and $lte null
-- on the scalar-only "null_scalar_coll" report isMultiKey: false with NO "Rows
-- Removed by Index Recheck" line, and still match literal null and missing
-- (_id 1, 2) but not the scalar (_id 3).
-- ----------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": { "$gte": null } }, "hint": "a_b_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": { "$gte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": { "$lte": null } }, "hint": "a_b_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_scalar_coll", "filter": { "a": { "$lte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');

-- ----------------------------------------------------------------------------
-- R4b (mkp=true, multi-key path -> recheck PRESERVED): $gte null and $lte null on
-- "null_mk_coll" (multi-key via the empty array on _id 3) report isMultiKey: true
-- and "Rows Removed by Index Recheck: 1", excluding the empty array. Only literal
-- null and missing match (_id 1, 2).
-- ----------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_mk_coll", "filter": { "a": { "$gte": null } }, "hint": "a_b_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_mk_coll", "filter": { "a": { "$gte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_mk_coll", "filter": { "a": { "$lte": null } }, "hint": "a_b_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('mkf_db', '{ "find": "null_mk_coll", "filter": { "a": { "$lte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "a_b_1" }');
