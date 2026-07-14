SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 43500;
SET documentdb.next_collection_index_id TO 43500;

-- ============================================================================
-- Runtime-recheck gating for the null-anchored operators on composite ordered
-- indexes: $eq null, $ne, $nin, and the range operators $gt / $gte / $lt / $lte
-- against null.
--
-- These operators generate a bound that spans the "undefined" index-term region
-- (missing fields AND empty arrays). Historically they always forced a heap
-- runtime recheck to filter empty-array false positives (an empty array must not
-- match $eq null / $gte null / $lte null). With per-path multi-key metadata
-- tracking (mkp=true) an empty array marks its path multi-key, so a path reported
-- as NON-multi-key is guaranteed array-free and the recheck can be skipped for
-- that path. On a multi-key path (or on a legacy mkp=false index) the recheck is
-- preserved.
--
-- The correctness of every result set below was cross-checked against a
-- sequential-scan ground truth (same query with index scans disabled); the two
-- always agree, i.e. the recheck-skip never changes the result -- it only removes
-- redundant heap work.
--
-- Observability: "Rows Removed by Index Recheck: N" appears on the inner Index
-- Scan only when the recheck runs AND removes at least one candidate. When the
-- recheck is skipped, the line is absent.
-- ============================================================================

set documentdb.enableCompositeIndexPlanner to on;
set documentdb.enableIndexMetadataGlobalTracking to on;
set documentdb.enablePerPathMultiKeySortPushdown to on;
set documentdb.enableExtendedExplainPlans to on;
set documentdb.enableExplainScanIndexCosts to off;
set enable_seqscan to off;
set enable_bitmapscan to off;

-- ----------------------------------------------------------------------------
-- Fixture A: nested composite index (a.b, a.c) exercising PER-PATH granularity.
-- The leaf path a.b holds arrays (including an empty array), making a.b
-- multi-key. The leaf path a.c holds only scalars / null / missing and there is
-- NO array on the shared ancestor "a", so a.c is NOT multi-key. Both paths live
-- in the SAME index, so the multi-key decision must be made per path.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "per_path", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'per_path', '{ "_id": 1, "a": { "b": null, "c": null } }');
SELECT documentdb_api.insert_one('nrg_db', 'per_path', '{ "_id": 2, "a": { "c": 5 } }');
SELECT documentdb_api.insert_one('nrg_db', 'per_path', '{ "_id": 3, "a": { "b": [ ], "c": 5 } }');
SELECT documentdb_api.insert_one('nrg_db', 'per_path', '{ "_id": 4, "a": { "b": [ 1, 2 ], "c": 5 } }');
SELECT documentdb_api.insert_one('nrg_db', 'per_path', '{ "_id": 5, "a": { "b": [ null, 3 ], "c": 5 } }');
SELECT documentdb_api.insert_one('nrg_db', 'per_path', '{ "_id": 6, "a": { "b": 5, "c": 5 } }');
SELECT documentdb_api.insert_one('nrg_db', 'per_path', '{ "_id": 7, "a": { "c": null } }');

-- a.c is NON-multi-key even though the index is multi-key via a.b: explain reports
-- "multiKeyPaths: a.b" (a.c absent). $eq null on a.c therefore SKIPS the recheck:
-- no "Rows Removed by Index Recheck" line. Result is still correct (null + missing
-- on a.c => _id 1, 7).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": null }, "hint": "ab_ac_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');

-- a.b IS multi-key (leaf arrays, incl. the empty array on _id 3): $eq null on a.b
-- PRESERVES the recheck. The empty array (_id 3) falls in the [MinKey, null] bound
-- but must not match null, so it is removed: "Rows Removed by Index Recheck: 1".
-- Result: null / missing / array-containing-null on a.b => _id 1, 2, 5, 7 (the
-- empty array _id 3 and the scalar/array-without-null are excluded).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": null }, "hint": "ab_ac_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');

-- The full operator family on the NON-multi-key path a.c (results verified against
-- a sequential scan). The recheck is skipped for all of these -- $eq/$gte/$lte/$gt/
-- $lt null, scalar $ne, AND the null-excluding negations $ne null / $nin [.., null].
-- On a non-multi-key path the term-level recheck (IsValidRecheckForIndexValue) is
-- exact: for $ne null it excludes an undefined (missing) / literal-null term
-- directly, since without arrays an undefined term can only be missing / literal
-- null (never an empty array). So no heap runtime recheck is needed on this path.
-- $ne 5 (scalar negation) => everything except a.c == 5 (_id 1, 7).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$ne": 5 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $nin [5, null] (excludes null) => a.c neither 5 nor null/missing (none here).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$nin": [ 5, null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $gte null / $lte null => null + missing on a.c (_id 1, 7).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$gte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$lte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $gt null / $lt null => empty (type-bracketed range excludes null and everything else).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$gt": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$lt": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $ne null (excludes null) => a.c present and not null (_id 2, 3, 4, 5, 6).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- Explicit recheck-SKIP guard for $ne null on the NON-multi-key path a.c: because
-- a.c is not multi-key, the term-level recheck excludes the missing / literal-null
-- terms exactly, so NO heap runtime recheck runs -- there is no "Rows Removed by
-- Index Recheck" line, and the result is still correct (a.c present and not null).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.c": { "$ne": null } }, "hint": "ab_ac_1" }') $cmd$);

-- The same operator family on the MULTI-KEY path a.b (recheck preserved, results
-- verified against a sequential scan).
-- $ne 5 => everything whose a.b is not exactly 5 (arrays match if any element != 5).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": { "$ne": 5 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $nin [5, null] => a.b has no element 5 and is not null/missing (_id 3, 4).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": { "$nin": [ 5, null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $gte null / $lte null => null + missing on a.b (_id 1, 2, 5, 7); empty array _id 3 excluded.
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": { "$gte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": { "$lte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $gt 0 / $lt 100 => numeric a.b (array elements count): _id 4, 5, 6.
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": { "$gt": 0 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": { "$lt": 100 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
-- $ne null => a.b present and not null (_id 3, 4, 6).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "per_path", "filter": { "a.b": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');

-- ----------------------------------------------------------------------------
-- Fixture B: nested composite index (a.b, a.c) exercising ANCESTOR arrays vs
-- LEAF arrays. An array on the shared ancestor "a" makes BOTH leaf paths
-- multi-key; an empty array on the ancestor produces an undefined term for the
-- leaf that is a genuine null match (not a false positive). This confirms the
-- recheck handling is correct for the ancestor-array shapes too.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "ancestor", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 1, "a": { "b": null, "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 2, "a": { "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 3, "x": 1 }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 4, "a": { "b": [ ], "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 5, "a": [ ] }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 6, "a": [ { "b": 1, "c": 1 }, { "b": 2, "c": 2 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 7, "a": [ { "c": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'ancestor', '{ "_id": 8, "a": { "b": 5, "c": 5 } }');

-- $eq null on a.b: the index is multi-key on a.b (ancestor / leaf arrays), so the
-- recheck runs. Matches literal null (_id 1), missing-b under a present (_id 2),
-- missing a (_id 3), and the array element without b (_id 7, a.b resolves to
-- missing). The two empty arrays are both rechecked out ("Rows Removed by Index
-- Recheck: 2"): the leaf empty array (_id 4, a.b == []) and the ancestor empty
-- array (_id 5, {a: []}) neither of which matches null. Result: _id 1, 2, 3, 7.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "ancestor", "filter": { "a.b": null }, "hint": "ab_ac_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "ancestor", "filter": { "a.b": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "ancestor", "filter": { "a.b": { "$gte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "ancestor", "filter": { "a.b": { "$lte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "ancestor", "filter": { "a.b": { "$ne": 5 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "ancestor", "filter": { "a.b": { "$nin": [ 5, null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');

-- ----------------------------------------------------------------------------
-- Fixture C: a fully NON-multi-key nested index (no arrays anywhere). Every
-- null-anchored operator skips the recheck on both paths; every result is still
-- correct.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "scalar", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'scalar', '{ "_id": 1, "a": { "b": null, "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'scalar', '{ "_id": 2, "a": { "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'scalar', '{ "_id": 3, "x": 1 }');
SELECT documentdb_api.insert_one('nrg_db', 'scalar', '{ "_id": 4, "a": { "b": 5, "c": 5 } }');
SELECT documentdb_api.insert_one('nrg_db', 'scalar', '{ "_id": 5, "a": { "b": 3, "c": 1 } }');

-- isMultiKey: false and no "Rows Removed" line for $eq null on a.b (recheck skipped).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.b": null }, "hint": "ab_ac_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.b": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.b": { "$gte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.b": { "$lte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.b": { "$gt": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.b": { "$lt": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.b": { "$ne": 5 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "scalar", "filter": { "a.c": { "$nin": [ 5, null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');

-- ----------------------------------------------------------------------------
-- Fixture D: legacy (mkp=false) index with an empty array present. The empty
-- array is NOT reflected in the multi-key state (isMultiKey: false), yet the gate
-- must fall back to the conservative behavior and KEEP the recheck so the empty
-- array is still excluded from $eq null / $gte null / $lte null. Dropping the
-- recheck here would wrongly return the empty-array document -- this is the case
-- the mkp restriction protects.
-- ----------------------------------------------------------------------------
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "legacy", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac_1", "enableOrderedIndex": 1 } ] }');
set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'legacy', '{ "_id": 1, "a": { "b": null, "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'legacy', '{ "_id": 2, "a": { "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'legacy', '{ "_id": 3, "a": { "b": [ ], "c": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'legacy', '{ "_id": 4, "a": { "b": 5, "c": 1 } }');

-- isMultiKey: false (empty array untracked) but "Rows Removed by Index Recheck: 1"
-- still appears -- the conservative gate keeps the recheck and excludes the empty
-- array (_id 3). Result: literal null + missing (_id 1, 2).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "legacy", "filter": { "a.b": null }, "hint": "ab_ac_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "legacy", "filter": { "a.b": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "legacy", "filter": { "a.b": { "$gte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "legacy", "filter": { "a.b": { "$lte": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac_1" }');

-- ----------------------------------------------------------------------------
-- Fixture E: count() parity for a leading-equality + trailing-null predicate on
-- a TOP-LEVEL composite key, across three index states -- no index (collection
-- scan), a single-field index on the equality prefix, and an mkp=true composite
-- index on the full key. The trailing field spans the four "absent-ish" shapes:
-- non-empty array, empty array, literal null, and missing. The predicate
-- { grp: 1, tag: null } must match ONLY the literal-null document, and the count
-- must be identical no matter which index (if any) serves the query. In
-- particular an empty array must NOT be counted as null -- on the mkp composite
-- index this relies on the runtime recheck (the tag path is multi-key) to drop
-- the empty-array candidate.
--
-- Data (same four documents in each collection):
--   { _id: 1, grp: 1, tag: [ 7 ] }  -- non-empty array
--   { _id: 2, grp: 1, tag: [ ] }    -- empty array (must not match tag: null)
--   { _id: 3, grp: 1, tag: null }   -- literal null (the only match for tag: null)
--   { _id: 4 }                      -- grp and tag both missing
-- Expected: count({grp:1}) = 3, count({grp:1,tag:null}) = 1, count({}) = 4.
-- ----------------------------------------------------------------------------

-- State 1: no index (collection scan) establishes the ground-truth counts.
SELECT documentdb_api.insert_one('nrg_db', 'cnt_noidx', '{ "_id": 1, "grp": 1, "tag": [ 7 ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_noidx', '{ "_id": 2, "grp": 1, "tag": [ ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_noidx', '{ "_id": 3, "grp": 1, "tag": null }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_noidx', '{ "_id": 4 }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_noidx", "query": { "grp": 1 } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_noidx", "query": { "grp": 1, "tag": null } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_noidx", "query": { } }');

-- State 2: a single-field index on the equality prefix. The trailing null is
-- rechecked on the heap, so the empty array is still excluded: counts unchanged.
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "cnt_single", "indexes": [ { "key": { "grp": 1 }, "name": "grp_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_single', '{ "_id": 1, "grp": 1, "tag": [ 7 ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_single', '{ "_id": 2, "grp": 1, "tag": [ ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_single', '{ "_id": 3, "grp": 1, "tag": null }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_single', '{ "_id": 4 }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_single", "query": { "grp": 1 } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_single", "query": { "grp": 1, "tag": null } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_single", "query": { } }');

-- State 3: an mkp=true composite index on the full key. Counts must still match;
-- the empty array is dropped by the runtime recheck on the multi-key tag path.
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "cnt_comp", "indexes": [ { "key": { "grp": 1, "tag": 1 }, "name": "grp_tag_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_comp', '{ "_id": 1, "grp": 1, "tag": [ 7 ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_comp', '{ "_id": 2, "grp": 1, "tag": [ ] }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_comp', '{ "_id": 3, "grp": 1, "tag": null }');
SELECT documentdb_api.insert_one('nrg_db', 'cnt_comp', '{ "_id": 4 }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_comp", "query": { "grp": 1 } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_comp", "query": { "grp": 1, "tag": null } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "cnt_comp", "query": { } }');

-- On the composite index the tag path is multi-key (non-empty array on _id 1,
-- empty array on _id 2), so { grp: 1, tag: null } keeps the recheck: the empty
-- array falls in the [MinKey, null] bound but is removed ("Rows Removed by Index
-- Recheck: 1"), leaving only the literal-null document.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "cnt_comp", "filter": { "grp": 1, "tag": null }, "hint": "grp_tag_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "cnt_comp", "filter": { "grp": 1, "tag": null }, "projection": { "_id": 1, "tag": 1 }, "sort": { "_id": 1 }, "hint": "grp_tag_1" }');

-- ----------------------------------------------------------------------------
-- Fixture F: combined $in + $ne (and the equivalent $in + $not:$in) on a SINGLE
-- multi-key array field. The two predicates apply to the DOCUMENT, not per array
-- element: { tags: { $in: [1], $ne: 3 } } means "the array contains an element in
-- [1]" AND "the array does not contain 3". Both documents contain 1, but the
-- second also contains 3, so only the first matches -- count is 1.
--
-- This is the classic multi-key negation trap: an index entry tags=1 satisfies
-- $in:[1], and 1 != 3 satisfies $ne:3 for that entry, so a per-entry evaluation
-- would wrongly return the { tags: [1, 3] } document. Correctness requires the
-- runtime recheck to inspect the whole array and drop it. On the mkp composite
-- index the tags path is multi-key, so the recheck is preserved.
--
-- Data (same two documents in each collection):
--   { _id: 1, tags: [ 1, 2 ], grp: 1 }  -- contains 1, no 3 -> matches
--   { _id: 2, tags: [ 1, 3 ], grp: 1 }  -- contains 1 AND 3 -> excluded
-- Expected count for both predicates: 1 (only _id 1), in every index state.
-- ----------------------------------------------------------------------------

-- State 1: no index (collection scan) establishes the ground-truth count.
SELECT documentdb_api.insert_one('nrg_db', 'neg_noidx', '{ "_id": 1, "tags": [ 1, 2 ], "grp": 1 }');
SELECT documentdb_api.insert_one('nrg_db', 'neg_noidx', '{ "_id": 2, "tags": [ 1, 3 ], "grp": 1 }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "neg_noidx", "query": { "tags": { "$in": [ 1 ], "$ne": 3 } } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "neg_noidx", "query": { "tags": { "$in": [ 1 ], "$not": { "$in": [ 3 ] } } } }');

-- State 2: a single-field index on the array. The result must be unchanged.
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "neg_single", "indexes": [ { "key": { "tags": 1 }, "name": "tags_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'neg_single', '{ "_id": 1, "tags": [ 1, 2 ], "grp": 1 }');
SELECT documentdb_api.insert_one('nrg_db', 'neg_single', '{ "_id": 2, "tags": [ 1, 3 ], "grp": 1 }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "neg_single", "query": { "tags": { "$in": [ 1 ], "$ne": 3 } } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "neg_single", "query": { "tags": { "$in": [ 1 ], "$not": { "$in": [ 3 ] } } } }');

-- State 3: an mkp=true composite index whose leading path is the array. The tags
-- path is multi-key, so { tags: { $in: [1], $ne: 3 } } keeps the recheck: the
-- { tags: [1, 3] } document falls inside the $in:[1] bound but is removed ("Rows
-- Removed by Index Recheck: 1"), leaving only the first document.
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "neg_comp", "indexes": [ { "key": { "tags": 1, "grp": 1 }, "name": "tags_grp_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'neg_comp', '{ "_id": 1, "tags": [ 1, 2 ], "grp": 1 }');
SELECT documentdb_api.insert_one('nrg_db', 'neg_comp', '{ "_id": 2, "tags": [ 1, 3 ], "grp": 1 }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "neg_comp", "query": { "tags": { "$in": [ 1 ], "$ne": 3 } } }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "neg_comp", "query": { "tags": { "$in": [ 1 ], "$not": { "$in": [ 3 ] } } } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_comp", "filter": { "tags": { "$in": [ 1 ], "$ne": 3 } }, "hint": "tags_grp_1" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_comp", "filter": { "tags": { "$in": [ 1 ], "$ne": 3 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "tags_grp_1" }');

-- ----------------------------------------------------------------------------
-- Fixture G: $exists / { path: null } / { path: $ne null } across a nesting
-- "staircase" of dotted paths, served by a single mkp=true composite index whose
-- columns are the four nesting depths. All documents are scalar (no arrays), so
-- every path is non-multi-key: the null / $ne-null predicates take the
-- recheck-skip path, and $exists is handled by its own term-level recheck
-- (independent of the multi-key gating). This validates the deep-nested
-- null-or-missing and existence semantics on a composite index.
--
-- Data (a nesting staircase; the deepest defined path grows by one per document):
--   { _id: 1 }                              -- no p
--   { _id: 2, p: 1 }                        -- p scalar
--   { _id: 3, p: { q: 1 } }                 -- p.q
--   { _id: 4, p: { q: { r: 1 } } }          -- p.q.r
--   { _id: 5, p: { q: { r: { s: null } } } }-- p.q.r.s == null
--
-- { path: null } matches "null OR missing", including a dead-end on a scalar or
-- missing ancestor, so it grows 1/2/3/5 with depth (all five at p.q.r.s, four
-- missing the path + one literal null). { path: $ne null } is the "present and
-- not null" complement (4/3/2/0). $exists true is 4/3/2/1 and $exists false is
-- its exact complement 1/2/3/4.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "stair", "indexes": [ { "key": { "p": 1, "p.q": 1, "p.q.r": 1, "p.q.r.s": 1 }, "name": "stair_idx", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'stair', '{ "_id": 1 }');
SELECT documentdb_api.insert_one('nrg_db', 'stair', '{ "_id": 2, "p": 1 }');
SELECT documentdb_api.insert_one('nrg_db', 'stair', '{ "_id": 3, "p": { "q": 1 } }');
SELECT documentdb_api.insert_one('nrg_db', 'stair', '{ "_id": 4, "p": { "q": { "r": 1 } } }');
SELECT documentdb_api.insert_one('nrg_db', 'stair', '{ "_id": 5, "p": { "q": { "r": { "s": null } } } }');

-- { path: null } staircase -> 1, 2, 3, 5.
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p": null }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q": null }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r": null }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r.s": null }, "hint": "stair_idx" }');

-- { path: $ne null } staircase (present and not null) -> 4, 3, 2, 0.
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p": { "$ne": null } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q": { "$ne": null } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r": { "$ne": null } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r.s": { "$ne": null } }, "hint": "stair_idx" }');

-- { path: $exists true } staircase -> 4, 3, 2, 1.
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p": { "$exists": true } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q": { "$exists": true } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r": { "$exists": true } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r.s": { "$exists": true } }, "hint": "stair_idx" }');

-- { path: $exists false } staircase (exact complement) -> 1, 2, 3, 4.
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p": { "$exists": false } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q": { "$exists": false } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r": { "$exists": false } }, "hint": "stair_idx" }');
SELECT documentdb_api.count_query('nrg_db', '{ "count": "stair", "query": { "p.q.r.s": { "$exists": false } }, "hint": "stair_idx" }');

-- The deep path p.q.r.s is non-multi-key (all scalars), so { p.q.r.s: null } takes
-- the recheck-skip path: isMultiKey is false and there is no "Rows Removed by Index
-- Recheck" line. It matches every document (literal null on _id 5, missing on the
-- rest).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "stair", "filter": { "p.q.r.s": null }, "hint": "stair_idx" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "stair", "filter": { "p.q.r.s": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "stair_idx" }');

-- ----------------------------------------------------------------------------
-- Fixture H: index / collection-scan CONSISTENCY across the negation, range,
-- $elemMatch, and null query shapes on a multi-key array field. This is the
-- differential-consistency invariant: a query must return the same set of
-- documents whether it is served by the composite index or by a collection scan.
-- It is the strongest guard for the recheck-gating logic, since the negations and
-- null predicates are exactly where a multi-key index can produce false positives
-- that the recheck must remove.
--
-- The document set deliberately spans the hard cases: multi-element arrays,
-- scalars, literal null, the empty array [], an array containing null, a missing
-- field, a nested document, an array of documents, and MinKey / MaxKey (bare and
-- inside arrays). For every query below the index-scan result set is compared to
-- the collection-scan result set (as an order-independent multiset); the harness
-- reports the number of mismatches, which must be 0.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "arr_cons", "indexes": [ { "key": { "elem": 1 }, "name": "elem_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":1, "elem":[7,8] }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":2, "elem":[9,10] }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":3, "elem":8 }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":4, "elem":9 }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":5, "elem":null }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":6, "elem":[] }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":7, "elem":[null] }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":8, "elem":[null,9] }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":9 }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":10, "elem":{ "k":5 } }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":11, "elem":[ { "k":7 } ] }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":12, "elem":{ "$minKey":1 } }');
SELECT documentdb_api.insert_one('nrg_db','arr_cons','{ "_id":13, "elem":[ { "$maxKey":1 }, 9 ] }');

CREATE TEMP TABLE arr_cons_q(label text, filter text);
INSERT INTO arr_cons_q VALUES
 ('eq null','{ "elem": null }'),('ne null','{ "elem": { "$ne": null } }'),
 ('nin [null]','{ "elem": { "$nin": [ null ] } }'),('nin [8,null]','{ "elem": { "$nin": [ 8, null ] } }'),
 ('nin [8,9]','{ "elem": { "$nin": [ 8, 9 ] } }'),
 ('gte null','{ "elem": { "$gte": null } }'),('lte null','{ "elem": { "$lte": null } }'),
 ('gt null','{ "elem": { "$gt": null } }'),('lt null','{ "elem": { "$lt": null } }'),
 ('not eq null','{ "elem": { "$not": { "$eq": null } } }'),
 ('not lt 9','{ "elem": { "$not": { "$lt": 9 } } }'),('not lte 9','{ "elem": { "$not": { "$lte": 9 } } }'),
 ('not gt 9','{ "elem": { "$not": { "$gt": 9 } } }'),('not gte 9','{ "elem": { "$not": { "$gte": 9 } } }'),
 ('not eq 9','{ "elem": { "$not": { "$eq": 9 } } }'),('ne 9','{ "elem": { "$ne": 9 } }'),
 ('em not eq 9','{ "elem": { "$elemMatch": { "$not": { "$eq": 9 } } } }'),
 ('em not gte 9','{ "elem": { "$elemMatch": { "$not": { "$gte": 9 } } } }'),
 ('em not lte 9','{ "elem": { "$elemMatch": { "$not": { "$lte": 9 } } } }'),
 ('gt minkey','{ "elem": { "$gt": { "$minKey": 1 } } }'),('lte maxkey','{ "elem": { "$lte": { "$maxKey": 1 } } }'),
 ('gt7 lt10','{ "elem": { "$gt": 7, "$lt": 10 } }'),
 ('not gt9 lt7','{ "elem": { "$not": { "$gt": 9, "$lt": 7 } } }'),
 ('not not lt9','{ "elem": { "$not": { "$not": { "$lt": 9 } } } }');

-- For each query, compare the index-scan result set with the collection-scan
-- result set. Report only the total mismatch count (which must be 0); any
-- individual mismatch prints its own NOTICE with the diverging sets.
DO $arr_cons$
DECLARE r RECORD; idxres text; seqres text; fs text; nmis int := 0;
BEGIN
  FOR r IN SELECT label, filter FROM arr_cons_q ORDER BY label LOOP
    fs := '{ "find": "arr_cons", "filter": ' || r.filter || ', "projection": { "_id": 0, "elem": 1 } }';
    SET enable_seqscan = off; SET enable_indexscan = on;
    EXECUTE 'SELECT array_agg(t.d::text ORDER BY t.d::text) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
      USING 'nrg_db', fs::documentdb_core.bson INTO idxres;
    SET enable_seqscan = on; SET enable_indexscan = off;
    EXECUTE 'SELECT array_agg(t.d::text ORDER BY t.d::text) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
      USING 'nrg_db', fs::documentdb_core.bson INTO seqres;
    IF idxres IS DISTINCT FROM seqres THEN
      nmis := nmis + 1;
      RAISE NOTICE 'MISMATCH [%]: idx=% seq=%', r.label, idxres, seqres;
    END IF;
  END LOOP;
  RAISE NOTICE 'index/collection-scan consistency mismatches: %', nmis;
END $arr_cons$;
RESET enable_seqscan;
RESET enable_indexscan;

-- ============================================================================
-- Fixture I: reduced-correlated-term (rct) null matching on a common-prefix
-- composite index (a.b, a.c). A composite index whose leaf paths share an
-- ancestor ("a") is built with reduced correlated terms: instead of the full
-- cross-product of per-leaf values, one correlated tuple is emitted per array
-- position (the "diagonal"), plus a marker term that tells the query side to
-- recheck off-diagonal combinations.
--
-- Regression guard: an array position whose indexed leaves are all absent -- an
-- empty sub-document {} or a scalar element that cannot descend into .b / .c --
-- must still emit its all-undefined diagonal tuple. Otherwise the document is
-- dropped from the index for a null / $exists:false predicate on the sub-path,
-- even though a collection scan (and the documented wire-protocol semantics)
-- match it. The document set and every expected result below were cross-checked
-- against the documented behavior and against a collection-scan ground truth.
--
-- Coverage is exercised twice: once with per-path multi-key tracking ON
-- (mkp=true) and once with it OFF (mkp=false), since the fix lives in the
-- reduced-correlated path and must hold independent of the mkp reloption.
--
-- Shared document set (deterministic _id): the hard array shapes for a.b / a.c.
--  1 {a:{b:5}}          plain sub-document, b present
--  2 {a:[{b:5}]}        array with sub-document, b present
--  3 {a:[{}]}           array with a single empty sub-document
--  4 {a:[{},{b:5}]}     empty sub-document + b present   (key rct case)
--  5 {a:[5,{b:5}]}      scalar element + b present       (key rct case)
--  6 {a:[5]}            scalar element only
--  7 {a:5}              scalar, path a.b/a.c not reachable
--  8 {a:[]}             empty array
--  9 {a:[{b:null}]}     explicit null b
-- 10 {a:[{b:5},{c:9}]}  b present in one element, sibling-only in another
-- 11 {a:{c:9}}          sub-document without b
-- 12 {a:[{c:9}]}        array sub-document without b
-- 13 {b:5}              no a at all
-- ============================================================================

-- mkp=on collection (index is rct=true, mkp=true).
set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'rct_on', doc) FROM (VALUES
 ('{ "_id": 1, "a": { "b": 5 } }'::documentdb_core.bson),
 ('{ "_id": 2, "a": [ { "b": 5 } ] }'),
 ('{ "_id": 3, "a": [ { } ] }'),
 ('{ "_id": 4, "a": [ { }, { "b": 5 } ] }'),
 ('{ "_id": 5, "a": [ 5, { "b": 5 } ] }'),
 ('{ "_id": 6, "a": [ 5 ] }'),
 ('{ "_id": 7, "a": 5 }'),
 ('{ "_id": 8, "a": [ ] }'),
 ('{ "_id": 9, "a": [ { "b": null } ] }'),
 ('{ "_id": 10, "a": [ { "b": 5 }, { "c": 9 } ] }'),
 ('{ "_id": 11, "a": { "c": 9 } }'),
 ('{ "_id": 12, "a": [ { "c": 9 } ] }'),
 ('{ "_id": 13, "b": 5 }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "rct_on", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac", "enableOrderedIndex": 1 } ] }', true);

-- mkp=off collection (index is rct=true, mkp=false).
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api.insert_one('nrg_db', 'rct_off', doc) FROM (VALUES
 ('{ "_id": 1, "a": { "b": 5 } }'::documentdb_core.bson),
 ('{ "_id": 2, "a": [ { "b": 5 } ] }'),
 ('{ "_id": 3, "a": [ { } ] }'),
 ('{ "_id": 4, "a": [ { }, { "b": 5 } ] }'),
 ('{ "_id": 5, "a": [ 5, { "b": 5 } ] }'),
 ('{ "_id": 6, "a": [ 5 ] }'),
 ('{ "_id": 7, "a": 5 }'),
 ('{ "_id": 8, "a": [ ] }'),
 ('{ "_id": 9, "a": [ { "b": null } ] }'),
 ('{ "_id": 10, "a": [ { "b": 5 }, { "c": 9 } ] }'),
 ('{ "_id": 11, "a": { "c": 9 } }'),
 ('{ "_id": 12, "a": [ { "c": 9 } ] }'),
 ('{ "_id": 13, "b": 5 }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "rct_off", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

-- Query set: the null / negation / existence shapes on the sub-paths, plus a
-- positive lookup that must ride the diagonal.
CREATE TEMP TABLE rct_q(label text, filter text);
INSERT INTO rct_q VALUES
 ('ab eq null','{ "a.b": null }'),
 ('ab in null','{ "a.b": { "$in": [ null ] } }'),
 ('ab ne null','{ "a.b": { "$ne": null } }'),
 ('ab nin null','{ "a.b": { "$nin": [ null ] } }'),
 ('ab exists false','{ "a.b": { "$exists": false } }'),
 ('ab exists true','{ "a.b": { "$exists": true } }'),
 ('ac eq null','{ "a.c": null }'),
 ('ac ne null','{ "a.c": { "$ne": null } }'),
 ('ac exists false','{ "a.c": { "$exists": false } }'),
 ('ab eq 5','{ "a.b": 5 }'),
 ('ab eq5 ac eq9','{ "a.b": 5, "a.c": 9 }');

-- Differential harness: for each collection (mkp on / off), assert the
-- index-scan result equals the collection-scan result for every query. The
-- mismatch count must be 0 -- this is what catches the dropped-diagonal
-- regression. (Index build happens above, outside this transaction.)
DO $rct$
DECLARE r RECORD; idxres text; seqres text; fs text; nmis int; coll text;
BEGIN
  FOREACH coll IN ARRAY ARRAY['rct_on','rct_off'] LOOP
    nmis := 0;
    FOR r IN SELECT label, filter FROM rct_q ORDER BY label LOOP
      fs := format('{ "find": "%s", "filter": %s, "projection": { "_id": 1 }, "hint": "ab_ac" }', coll, r.filter);
      SET enable_seqscan = off; SET enable_indexscan = on;
      EXECUTE 'SELECT array_agg((t.d->>''_id'')::int ORDER BY (t.d->>''_id'')::int) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
        USING 'nrg_db', fs::documentdb_core.bson INTO idxres;
      SET enable_seqscan = on; SET enable_indexscan = off;
      EXECUTE 'SELECT array_agg((t.d->>''_id'')::int ORDER BY (t.d->>''_id'')::int) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
        USING 'nrg_db', fs::documentdb_core.bson INTO seqres;
      IF idxres IS DISTINCT FROM seqres THEN
        nmis := nmis + 1;
        RAISE NOTICE 'MISMATCH [%][%]: idx=% seq=%', coll, r.label, idxres, seqres;
      END IF;
    END LOOP;
    RAISE NOTICE 'rct null-matching idx/seq mismatches [%]: %', coll, nmis;
  END LOOP;
  RESET enable_seqscan; RESET enable_indexscan;
END $rct$;

-- Explicit ground-truth result rows (index scan) for the null-anchored headline
-- predicates on the mkp=on collection, pinning the exact expected sets that
-- match the documented wire-protocol semantics:
--   a.b null / $in[null] -> 3,4,7,9,10,11,12,13   (empty sub-doc {} and scalar
--                                                   elements make a.b missing)
--   a.b $ne / $nin null  -> 1,2,5,6,8
-- (The empty sub-document _id 4 and the scalar-element docs are the positions
-- that the reduced-correlated diagonal previously dropped.)
set enable_seqscan to off;
set enable_indexscan to on;
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "rct_on", "filter": { "a.b": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "rct_on", "filter": { "a.b": { "$in": [ null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "rct_on", "filter": { "a.b": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "rct_on", "filter": { "a.b": { "$nin": [ null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ab_ac" }');
reset enable_seqscan;
reset enable_indexscan;

-- Unique common-prefix composite index (also rct): the all-undefined diagonal
-- position participates in the unique key exactly like the documented behavior,
-- so two documents whose indexed leaves are all-absent collide. Enforcement uses
-- the unique-shard-key path (independent of the diagonal fix); these cases pin
-- that behavior. doc2 of each pair reports a duplicate-key write error; the
-- distinct control pair inserts cleanly.
CREATE OR REPLACE FUNCTION pg_temp.dup_flag(res documentdb_core.bson) RETURNS text
  LANGUAGE sql AS $fn$ SELECT CASE WHEN res::text LIKE '%Duplicate key violation%' THEN 'DUP' ELSE 'OK' END $fn$;

SELECT documentdb_api.insert_one('nrg_db','uq_empty','{ "_id": 1, "a": [ { } ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db','{ "createIndexes": "uq_empty", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "u", "unique": true } ] }', true);
SELECT 'empty-doc x2' AS scenario, pg_temp.dup_flag(documentdb_api.insert_one('nrg_db','uq_empty','{ "_id": 2, "a": [ { } ] }')) AS result;

SELECT documentdb_api.insert_one('nrg_db','uq_scalar','{ "_id": 1, "a": [ 5 ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db','{ "createIndexes": "uq_scalar", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "u", "unique": true } ] }', true);
SELECT 'scalar vs scalar' AS scenario, pg_temp.dup_flag(documentdb_api.insert_one('nrg_db','uq_scalar','{ "_id": 2, "a": [ 6 ] }')) AS result;

SELECT documentdb_api.insert_one('nrg_db','uq_distinct','{ "_id": 1, "a": [ { "b": 1, "c": 10 } ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db','{ "createIndexes": "uq_distinct", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "u", "unique": true } ] }', true);
SELECT 'distinct (control)' AS scenario, pg_temp.dup_flag(documentdb_api.insert_one('nrg_db','uq_distinct','{ "_id": 2, "a": [ { "b": 2, "c": 20 } ] }')) AS result;

-- ============================================================================
-- Fixture J: composite path topologies for the reduced-correlated diagonal fix.
-- The diagonal-tuple recording is gated on "at least two composite paths
-- recursively match this array level" (numRecursiveMatches > 1), so the fix must
-- behave correctly across path shapes that engage the reduced correlated terms to
-- differing degrees:
--   * deep, fully-shared prefix  (a.b.c / a.b.d)      -> multi-level recursion
--   * no shared prefix           (a.b   / c.d)        -> reduced terms never apply
--   * partially-shared prefix    (a.b / a.c / x.y)    -> reduced on a.*, x.y apart
-- For every query the index-scan result must equal the collection-scan result
-- (mismatch count must be 0). This guards that broadening the diagonal candidate
-- to any sub-document position did not disturb non-reduced or partially-reduced
-- composite indexes.
-- ============================================================================

CREATE TEMP TABLE topo_docs(doc text);
INSERT INTO topo_docs VALUES
 ('{ "_id": 1,  "a": [ { "b": { "c": 1, "d": 2 } }, { "b": 5 } ] }'),
 ('{ "_id": 2,  "a": [ { "b": { "c": 1 } }, { "b": { } } ] }'),
 ('{ "_id": 3,  "a": [ { "b": { } }, { "b": { "d": 2 } } ] }'),
 ('{ "_id": 4,  "a": [ { "b": { "c": 1, "d": 2 } }, { } ] }'),
 ('{ "_id": 5,  "a": [ { "b": { "c": 1, "d": 2 } }, { "b": { "c": 3, "d": 4 } } ] }'),
 ('{ "_id": 6,  "a": [ { "b": 5 }, { "b": 6 } ] }'),
 ('{ "_id": 7,  "a": { "b": { "c": 1, "d": 2 } } }'),
 ('{ "_id": 8,  "a": [ { "b": { "c": null, "d": null } } ] }'),
 ('{ "_id": 9,  "a": { "b": 1 }, "c": { "d": 2 } }'),
 ('{ "_id": 10, "a": { "b": [ 1, 2 ] }, "c": { "d": 3 } }'),
 ('{ "_id": 11, "a": [ { "b": 1 }, { "b": 2 } ], "c": [ { "d": 3 }, { "d": 4 } ] }'),
 ('{ "_id": 12, "a": [ { "b": 1 }, { } ], "c": { "d": 3 } }'),
 ('{ "_id": 13, "a": [ { "b": 1, "c": 2 } ], "x": { "y": 9 } }'),
 ('{ "_id": 14, "a": [ { }, { } ], "x": { "y": 9 } }'),
 ('{ "_id": 15, "a": [ { "b": 1 } ], "x": [ { "y": 1 }, { "y": 2 } ] }');

set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'topo_deep', doc::documentdb_core.bson) FROM topo_docs;
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "topo_deep", "indexes": [ { "key": { "a.b.c": 1, "a.b.d": 1 }, "name": "ix", "enableOrderedIndex": 1 } ] }', true);
SELECT documentdb_api.insert_one('nrg_db', 'topo_nocp', doc::documentdb_core.bson) FROM topo_docs;
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "topo_nocp", "indexes": [ { "key": { "a.b": 1, "c.d": 1 }, "name": "ix", "enableOrderedIndex": 1 } ] }', true);
SELECT documentdb_api.insert_one('nrg_db', 'topo_part', doc::documentdb_core.bson) FROM topo_docs;
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "topo_part", "indexes": [ { "key": { "a.b": 1, "a.c": 1, "x.y": 1 }, "name": "ix", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

CREATE TEMP TABLE topo_q(coll text, filter text);
INSERT INTO topo_q VALUES
 ('topo_deep','{ "a.b.c": null }'),('topo_deep','{ "a.b.d": null }'),
 ('topo_deep','{ "a.b.c": { "$ne": null } }'),('topo_deep','{ "a.b.c": { "$exists": false } }'),
 ('topo_deep','{ "a.b.c": 1 }'),('topo_deep','{ "a.b.c": 1, "a.b.d": 2 }'),
 ('topo_deep','{ "a.b.c": { "$in": [ null ] } }'),('topo_deep','{ "a.b.d": { "$exists": true } }'),
 ('topo_nocp','{ "a.b": null }'),('topo_nocp','{ "c.d": null }'),('topo_nocp','{ "a.b": { "$ne": null } }'),
 ('topo_nocp','{ "a.b": 1 }'),('topo_nocp','{ "c.d": 3 }'),('topo_nocp','{ "a.b": { "$exists": false } }'),
 ('topo_part','{ "a.b": null }'),('topo_part','{ "a.c": null }'),('topo_part','{ "x.y": null }'),
 ('topo_part','{ "a.b": { "$ne": null } }'),('topo_part','{ "x.y": 9 }'),('topo_part','{ "a.b": 1, "a.c": 2 }'),
 ('topo_part','{ "a.b": { "$exists": false } }'),('topo_part','{ "x.y": { "$exists": false } }');

DO $topo$
DECLARE r RECORD; idxr text; seqr text; fs text; nmis int:=0;
BEGIN
  FOR r IN SELECT coll, filter FROM topo_q ORDER BY coll, filter LOOP
    fs := format('{ "find": "%s", "filter": %s, "projection": { "_id": 1 }, "hint": "ix" }', r.coll, r.filter);
    SET enable_seqscan = off; SET enable_indexscan = on; SET enable_bitmapscan = off;
    EXECUTE 'SELECT array_agg((t.d->>''_id'')::int ORDER BY (t.d->>''_id'')::int) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
      USING 'nrg_db', fs::documentdb_core.bson INTO idxr;
    SET enable_seqscan = on; SET enable_indexscan = off;
    EXECUTE 'SELECT array_agg((t.d->>''_id'')::int ORDER BY (t.d->>''_id'')::int) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
      USING 'nrg_db', fs::documentdb_core.bson INTO seqr;
    IF idxr IS DISTINCT FROM seqr THEN
      nmis := nmis + 1;
      RAISE NOTICE 'MISMATCH [%][%]: idx=% seq=%', r.coll, r.filter, idxr, seqr;
    END IF;
  END LOOP;
  RAISE NOTICE 'composite path-topology idx/seq mismatches: %', nmis;
  RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
END $topo$;


-- ============================================================================
-- Fixture K: $nin / $ne complementarity on multi-key arrays and a dotted path.
-- Exercises the $ne / $nin recheck handling on an ordered index over the classic
-- multi-key array shapes: nested arrays, an array-of-array value, arrays of
-- sub-documents, and a dotted-path array. (Field names and values are chosen
-- independently of any upstream fixture.)
--
-- Two guarantees are asserted, both served from the index:
--   1. Differential: index-scan count == collection-scan count for every query.
--   2. Complementarity: for any value v on any path, count({path: {$in:[v]}}) +
--      count({path: {$nin:[v]}}) == total document count. This is the strongest
--      invariant for the negation operators -- a false positive or false negative
--      in either $in or $nin breaks it.
-- ============================================================================

set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'neg_mkey', doc::documentdb_core.bson) FROM (VALUES
 ('{ "_id": 1, "m": [ 41, 42, 43 ] }'::documentdb_core.bson),
 ('{ "_id": 2, "m": [ 41, 42, 44 ] }'),
 ('{ "_id": 3, "m": [ 41, 48, 45 ] }'),
 ('{ "_id": 4, "m": [ 41, 48, 46 ] }'),
 ('{ "_id": 5, "m": [ 41, 49, 47 ] }'),
 ('{ "_id": 6, "m": [ 42, 42 ] }'),
 ('{ "_id": 7, "m": [ [ 42 ] ] }'),
 ('{ "_id": 8, "m": [ { "p": [ 50, 51 ] }, 51 ] }'),
 ('{ "_id": 9, "m": { "p": [ 60, 70 ] } }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "neg_mkey", "indexes": [ { "key": { "m": 1 }, "name": "m_1", "enableOrderedIndex": 1 }, { "key": { "m.p": 1 }, "name": "mp_1", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

-- Differential: $nin / $ne / $in / $all counts on the index must match the
-- collection scan.
CREATE TEMP TABLE neg_q(hint text, filter text);
INSERT INTO neg_q VALUES
 ('m_1','{ "m": { "$nin": [ 50 ] } }'),('m_1','{ "m": { "$ne": 41 } }'),
 ('m_1','{ "m": { "$nin": [ 41 ] } }'),('m_1','{ "m": { "$nin": [ 41, 42 ] } }'),
 ('m_1','{ "m": { "$nin": [ 42 ] } }'),('m_1','{ "m": { "$nin": [ 48 ] } }'),
 ('m_1','{ "m": { "$nin": [ 49 ] } }'),('m_1','{ "m": { "$nin": [ 42, 43 ] } }'),
 ('m_1','{ "m": { "$ne": 48, "$nin": [ 42, 43 ] } }'),('m_1','{ "m": { "$nin": [ 51 ] } }'),
 ('m_1','{ "m": { "$ne": null } }'),
 ('mp_1','{ "m.p": { "$nin": [ 50 ] } }'),('mp_1','{ "m.p": { "$nin": [ [ 50, 51 ] ] } }'),
 ('mp_1','{ "m.p": { "$all": [ 60 ] } }'),('mp_1','{ "m.p": { "$all": [ 60, 70 ] } }'),
 ('mp_1','{ "m.p": null }'),('mp_1','{ "m.p": { "$ne": null } }'),('mp_1','{ "m.p": { "$nin": [ null ] } }');

DO $neg$
DECLARE r RECORD; idxr text; seqr text; fs text; nmis int:=0;
BEGIN
  FOR r IN SELECT hint, filter FROM neg_q ORDER BY hint, filter LOOP
    fs := format('{ "find": "neg_mkey", "filter": %s, "hint": "%s" }', r.filter, r.hint);
    SET enable_seqscan=off; SET enable_indexscan=on; SET enable_bitmapscan=off;
    EXECUTE 'SELECT count(*) FROM (SELECT document AS d FROM bson_aggregation_find($1,$2)) t' USING 'nrg_db', fs::documentdb_core.bson INTO idxr;
    SET enable_seqscan=on; SET enable_indexscan=off;
    EXECUTE 'SELECT count(*) FROM (SELECT document AS d FROM bson_aggregation_find($1,$2)) t' USING 'nrg_db', fs::documentdb_core.bson INTO seqr;
    IF idxr IS DISTINCT FROM seqr THEN nmis := nmis + 1; RAISE NOTICE 'MISMATCH [%] %: idx=% seq=%', r.hint, r.filter, idxr, seqr; END IF;
  END LOOP;
  RAISE NOTICE 'negation $ne/$nin idx/seq mismatches: %', nmis;
  RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
END $neg$;

-- Complementarity: $in + $nin == total (9) for every value/path, served from the
-- index. A negation false-positive/negative would break the sum.
DO $comp$
DECLARE v text; p_hint text; p_path text; cin text; cnin text; nbad int:=0;
  total int;
BEGIN
  SET enable_seqscan=off; SET enable_indexscan=on; SET enable_bitmapscan=off;
  EXECUTE 'SELECT count(*) FROM (SELECT document FROM bson_aggregation_find($1, ''{ "find": "neg_mkey" }'')) t' USING 'nrg_db' INTO total;
  FOR p_hint, p_path IN VALUES ('m_1','m'), ('mp_1','m.p') LOOP
    FOREACH v IN ARRAY ARRAY['41','42','45','48','50','51','60','70','null'] LOOP
      EXECUTE format('SELECT count(*) FROM (SELECT document FROM bson_aggregation_find($1, ''{ "find": "neg_mkey", "filter": { "%s": { "$in": [ %s ] } }, "hint": "%s" }'')) t', p_path, v, p_hint) USING 'nrg_db' INTO cin;
      EXECUTE format('SELECT count(*) FROM (SELECT document FROM bson_aggregation_find($1, ''{ "find": "neg_mkey", "filter": { "%s": { "$nin": [ %s ] } }, "hint": "%s" }'')) t', p_path, v, p_hint) USING 'nrg_db' INTO cnin;
      IF (cin::int + cnin::int) <> total THEN
        nbad := nbad + 1;
        RAISE NOTICE 'COMPLEMENTARITY BROKEN [%=%]: in=% nin=% total=%', p_path, v, cin, cnin, total;
      END IF;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'negation $in+$nin complementarity violations: % (of % checks, total docs %)', nbad, 2 * 9, total;
  RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
END $comp$;

-- ============================================================================
-- Fixture L: negations over a multi-key index with exact-id expectations.
-- Two disjoint multi-key arrays where the excluded value lives inside one array,
-- so the index scan must recheck the array contents rather than trust a single
-- entry. Served from an ordered index (the recheck path under test). Field name
-- and values are chosen independently of any upstream fixture.
--   vec = [ 21, 22, 23 ] (_id 0)   vec = [ 30, 31 ] (_id 1)
--   { vec: { $ne: 23 } }        -> _id 1 only  (doc 0 contains 23)
--   { vec: { $not: { $gt: 26 } } } -> _id 0 only  (doc 1 has 30, 31 > 26)
-- ============================================================================

set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'neg_scan', doc::documentdb_core.bson) FROM (VALUES
 ('{ "_id": 0, "vec": [ 21, 22, 23 ] }'::documentdb_core.bson),
 ('{ "_id": 1, "vec": [ 30, 31 ] }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "neg_scan", "indexes": [ { "key": { "vec": 1 }, "name": "vec_1", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

set enable_seqscan to off;
set enable_indexscan to on;
-- $ne excludes the array that contains the value (index recheck must inspect the
-- full array, not a single matching entry).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_scan", "filter": { "vec": { "$ne": 23 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "vec_1" }');
-- $not over a range: excludes the array with any element in the range.
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_scan", "filter": { "vec": { "$not": { "$gt": 26 } } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "vec_1" }');
-- Companion negations pinned for completeness.
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_scan", "filter": { "vec": { "$nin": [ 23 ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "vec_1" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_scan", "filter": { "vec": { "$not": { "$lt": 26 } } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "vec_1" }');
reset enable_seqscan;
reset enable_indexscan;

-- ============================================================================
-- Fixture M: indexed null / $elemMatch of a missing sub-field, the canonical
-- distinction the reduced-correlated fix hinges on. An empty sub-document array
-- element makes the leaf sub-path null-equivalent (it descends into a document
-- that lacks the field), whereas a bare scalar array element does NOT (it cannot
-- descend). Both are served from a common-prefix composite index (which engages
-- reduced correlated terms) and an ordered single-path index. Field names and
-- values are chosen independently of any upstream fixture.
--   { g: [ { }, { h: 7 } ] }  -> g.h : null MATCHES   (empty sub-document)
--   { g: [ 9,   { h: 7 } ] }  -> g.h : null does NOT match (scalar element)
-- ============================================================================

set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'em_empty', '{ "_id": 0, "g": [ { }, { "h": 7 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'em_scalar', '{ "_id": 0, "g": [ 9, { "h": 7 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'em_empty_ord', '{ "_id": 0, "g": [ { }, { "h": 7 } ] }');
SELECT documentdb_api.insert_one('nrg_db', 'em_scalar_ord', '{ "_id": 0, "g": [ 9, { "h": 7 } ] }');
-- Common-prefix composite (reduced correlated terms engage on prefix g).
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "em_empty", "indexes": [ { "key": { "g.h": 1, "g.k": 1 }, "name": "ghk", "enableOrderedIndex": 1 } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "em_scalar", "indexes": [ { "key": { "g.h": 1, "g.k": 1 }, "name": "ghk", "enableOrderedIndex": 1 } ] }', true);
-- Ordered single-path index on the leaf.
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "em_empty_ord", "indexes": [ { "key": { "g.h": 1 }, "name": "gh", "enableOrderedIndex": 1 } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "em_scalar_ord", "indexes": [ { "key": { "g.h": 1 }, "name": "gh", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

set enable_seqscan to off;
set enable_indexscan to on;
-- Positive lookups (both scenarios): present sub-field is found.
SELECT 'empty comp  g.h:7' AS q, count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_empty", "filter": { "g.h": 7 }, "hint": "ghk" }')) t;
SELECT 'scalar comp g.h:7', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_scalar", "filter": { "g.h": 7 }, "hint": "ghk" }')) t;
SELECT 'empty comp  elemMatch h:7', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_empty", "filter": { "g": { "$elemMatch": { "h": 7 } } }, "hint": "ghk" }')) t;
-- Null / elemMatch-null: empty sub-document matches (1), scalar does not (0).
SELECT 'empty comp  g.h:null (exp 1)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_empty", "filter": { "g.h": null }, "hint": "ghk" }')) t;
SELECT 'scalar comp g.h:null (exp 0)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_scalar", "filter": { "g.h": null }, "hint": "ghk" }')) t;
SELECT 'empty comp  elemMatch h:null (exp 1)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_empty", "filter": { "g": { "$elemMatch": { "h": null } } }, "hint": "ghk" }')) t;
SELECT 'scalar comp elemMatch h:null (exp 0)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_scalar", "filter": { "g": { "$elemMatch": { "h": null } } }, "hint": "ghk" }')) t;
-- Ordered single-path index: same distinction.
SELECT 'empty ord   g.h:null (exp 1)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_empty_ord", "filter": { "g.h": null }, "hint": "gh" }')) t;
SELECT 'scalar ord  g.h:null (exp 0)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "em_scalar_ord", "filter": { "g.h": null }, "hint": "gh" }')) t;
reset enable_seqscan;
reset enable_indexscan;

-- ============================================================================
-- Fixture N: $not over array-only operators ($all, $size, $elemMatch) served
-- from an ordered index. These negations require the index scan to recheck the
-- whole array (a per-entry index match is not sufficient), complementing the
-- scalar negations covered above. Field names and values are chosen
-- independently of any upstream fixture.
--   w = [ "m", "n" ]               ($all / $size targets)
--   w = [ { q: "m" } ] (_id 0), w = [ { q: "n" } ] (_id 1)   ($elemMatch targets)
-- ============================================================================

set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'neg_arr', '{ "_id": 0, "w": [ "m", "n" ] }');
SELECT documentdb_api.insert_one('nrg_db', 'neg_em', doc::documentdb_core.bson) FROM (VALUES
 ('{ "_id": 0, "w": [ { "q": "m" } ] }'::documentdb_core.bson),
 ('{ "_id": 1, "w": [ { "q": "n" } ] }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "neg_arr", "indexes": [ { "key": { "w": 1 }, "name": "w_1", "enableOrderedIndex": 1 } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "neg_em", "indexes": [ { "key": { "w": 1 }, "name": "w_1", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

set enable_seqscan to off;
set enable_indexscan to on;
-- $not:{$all}: the array containing every listed value is excluded; missing one keeps it.
SELECT '$not $all[m,n] (exp 0)' AS q, count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_arr", "filter": { "w": { "$not": { "$all": [ "m", "n" ] } } }, "hint": "w_1" }')) t;
SELECT '$not $all[z] (exp 1)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_arr", "filter": { "w": { "$not": { "$all": [ "z" ] } } }, "hint": "w_1" }')) t;
-- $not:{$size}: exact-size negation.
SELECT '$not $size2 (exp 0)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_arr", "filter": { "w": { "$not": { "$size": 2 } } }, "hint": "w_1" }')) t;
SELECT '$not $size3 (exp 1)', count(*) FROM (SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "neg_arr", "filter": { "w": { "$not": { "$size": 3 } } }, "hint": "w_1" }')) t;
-- $not:{$elemMatch}: excludes the doc whose array has a matching element.
SELECT '$not elemMatch q:m (exp _id 1)' AS q, array_agg((t.d->>'_id')::int ORDER BY (t.d->>'_id')::int) AS ids
  FROM (SELECT document AS d FROM bson_aggregation_find('nrg_db', '{ "find": "neg_em", "filter": { "w": { "$not": { "$elemMatch": { "q": "m" } } } }, "hint": "w_1" }')) t;
SELECT '$not elemMatch q:z (exp _id 0,1)' AS q, array_agg((t.d->>'_id')::int ORDER BY (t.d->>'_id')::int) AS ids
  FROM (SELECT document AS d FROM bson_aggregation_find('nrg_db', '{ "find": "neg_em", "filter": { "w": { "$not": { "$elemMatch": { "q": "z" } } } }, "hint": "w_1" }')) t;
reset enable_seqscan;
reset enable_indexscan;

-- ============================================================================
-- Fixture O: $exists:false recheck gating on a composite leaf (a.b.c, a.b.d).
-- On a MULTI-KEY path a partial-existence array element (e.g. { b: null }) emits
-- a definite-undefined index term that is a false positive for $exists:false when
-- a SIBLING array element supplies the field. The per-term recheck cannot see
-- siblings, so the heap runtime recheck must be preserved: "Rows Removed by Index
-- Recheck" appears and the false positives are dropped. On a NON-multi-key path
-- there is exactly one term per document, so a definite-undefined term is exactly
-- "field absent" -- the recheck is SKIPPED (no recheck line, fast path preserved).
-- Results below verified against a collection scan. Field names/values chosen independently.
--   MULTI-KEY docs (arrays under "a"):
--     _id 1 { a: [ { b: null }, { b: { c: 5, d: 6 } } ] }
--     _id 2 { a: [ { b: null }, { b: [ { c: 5, d: 6 }, null ] } ] }
--     _id 3 { a: [ { b: [ { c: 5, d: 6 }, null ] } ] }
--   NON-multi-key docs (no arrays):
--     _id 1 { a: { b: null } }              _id 2 { a: { b: { c: 5, d: 6 } } }
--     _id 3 { a: { b: { c: null, d: 6 } } } _id 4 { a: { b: { d: 6 } } }
--     _id 5 { a: { x: 1 } }
-- ============================================================================

set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'exf_mk', doc::documentdb_core.bson) FROM (VALUES
 ('{ "_id": 1, "a": [ { "b": null }, { "b": { "c": 5, "d": 6 } } ] }'::documentdb_core.bson),
 ('{ "_id": 2, "a": [ { "b": null }, { "b": [ { "c": 5, "d": 6 }, null ] } ] }'),
 ('{ "_id": 3, "a": [ { "b": [ { "c": 5, "d": 6 }, null ] } ] }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "exf_mk", "indexes": [ { "key": { "a.b.c": 1, "a.b.d": 1 }, "name": "ix", "enableOrderedIndex": 1 } ] }', true);
SELECT documentdb_api.insert_one('nrg_db', 'exf_nomk', doc::documentdb_core.bson) FROM (VALUES
 ('{ "_id": 1, "a": { "b": null } }'::documentdb_core.bson),
 ('{ "_id": 2, "a": { "b": { "c": 5, "d": 6 } } }'),
 ('{ "_id": 3, "a": { "b": { "c": null, "d": 6 } } }'),
 ('{ "_id": 4, "a": { "b": { "d": 6 } } }'),
 ('{ "_id": 5, "a": { "x": 1 } }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "exf_nomk", "indexes": [ { "key": { "a.b.c": 1, "a.b.d": 1 }, "name": "ix", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

set enable_seqscan to off;
set enable_indexscan to on;
-- MULTI-KEY $exists:false PRESERVES the recheck: the { b: null } elements of _id 1
-- and 2 emit definite-undefined terms for a.b.c, but a sibling element supplies
-- a.b.c, so all three docs are removed by the heap recheck (result: none).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "exf_mk", "filter": { "a.b.c": { "$exists": false } }, "hint": "ix" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "exf_mk", "filter": { "a.b.c": { "$exists": false } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "exf_mk", "filter": { "a.b.d": { "$exists": false } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
-- $exists:true on the multi-key path is unaffected (docs found via a defined term).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "exf_mk", "filter": { "a.b.c": { "$exists": true } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');

-- NON-multi-key $exists:false SKIPS the recheck: one term per doc, so a
-- definite-undefined term is exactly "a.b.c absent" -- no "Rows Removed by Index
-- Recheck" line. Result: _id 1 (b:null), 4 (b has only d), 5 (no b).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "exf_nomk", "filter": { "a.b.c": { "$exists": false } }, "hint": "ix" }') $cmd$);
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "exf_nomk", "filter": { "a.b.c": { "$exists": false } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
-- $exists:true on the non-multi-key path => _id 2, 3 (a.b.c present).
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "exf_nomk", "filter": { "a.b.c": { "$exists": true } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
reset enable_seqscan;
reset enable_indexscan;

-- ============================================================================
-- Fixture P: null / $ne-null / $exists coverage on a composite (a.b.c, a.b.d)
-- index across the array-element shapes that distinguish a null match from a
-- non-match. Every query below is checked for index-scan vs collection-scan
-- CONSISTENCY (must be 0 mismatches) -- the core recheck-gating invariant -- and
-- its result set is pinned as a golden.
--
-- The document set encodes the key distinction for $eq null under implicit array
-- traversal: a scalar-null array element ([ null, ... ]) does NOT make a.b null,
-- but an empty sub-document element ([ {}, ... ]) DOES, because traversal descends
-- into a document that lacks the field (_id 1 vs _id 2). A { b: null } element
-- likewise makes the leaf null-equivalent (_id 5, 6, 7).
-- Field names / values are chosen independently of any upstream fixture.
-- ============================================================================

set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.insert_one('nrg_db', 'abcd_null', doc::documentdb_core.bson) FROM (VALUES
 ('{ "_id": 1,  "a": [ null, { "b": 5 } ] }'::documentdb_core.bson),
 ('{ "_id": 2,  "a": [ { }, { "b": 5 } ] }'),
 ('{ "_id": 3,  "a": [ { "b": { "e": null } } ] }'),
 ('{ "_id": 4,  "a": [ { "b": { "c": 3 } }, { "b": { } } ] }'),
 ('{ "_id": 5,  "a": [ { "b": { "c": 3 } }, { "b": null } ] }'),
 ('{ "_id": 6,  "a": [ { "b": null }, { "b": { "c": 5, "d": 6 } } ] }'),
 ('{ "_id": 7,  "a": [ { "b": null } ] }'),
 ('{ "_id": 8,  "a": [ null ] }'),
 ('{ "_id": 9,  "a": [ { "b": { "c": null, "d": 6 } } ] }'),
 ('{ "_id": 10, "a": [ { "b": [ { "c": 5, "d": 6 }, null ] } ] }')) v(doc);
SELECT documentdb_api_internal.create_indexes_non_concurrently('nrg_db', '{ "createIndexes": "abcd_null", "indexes": [ { "key": { "a.b.c": 1, "a.b.d": 1 }, "name": "ix", "enableOrderedIndex": 1 } ] }', true);
reset documentdb.enableIndexMetadataGlobalTracking;

-- Headline distinction, shown explicitly: a.b : null matches the empty-{} element
-- (_id 2) but NOT the scalar-null element (_id 1). Expected _id 2, 5, 6, 7, 10.
set enable_seqscan to off;
set enable_indexscan to on;
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
reset enable_seqscan;
reset enable_indexscan;

CREATE TEMP TABLE abcd_q(ord int, label text, filter text);
INSERT INTO abcd_q VALUES
 (1, 'a.b : null',           '{ "a.b": null }'),
 (2, 'a.b : $ne null',       '{ "a.b": { "$ne": null } }'),
 (3, 'a.b.c : $exists false','{ "a.b.c": { "$exists": false } }'),
 (4, 'a.b.c : $exists true', '{ "a.b.c": { "$exists": true } }'),
 -- Deep leaf below a null/missing intermediate inside an array. _id 6
 -- ([ { b: null }, { b: { c: 5, d: 6 } } ]) is the headline case: a null-first
 -- element makes a.b.c / a.b.d null even though a later element supplies a value.
 (5, 'a.b.c : null',         '{ "a.b.c": null }'),
 (6, 'a.b.c : $in null',     '{ "a.b.c": { "$in": [ null ] } }'),
 (7, 'a.b.c : $gte null',    '{ "a.b.c": { "$gte": null } }'),
 (8, 'a.b.c : $lte null',    '{ "a.b.c": { "$lte": null } }'),
 (9, 'a.b.c : $ne null',     '{ "a.b.c": { "$ne": null } }'),
 (10,'a.b.c : $nin null',    '{ "a.b.c": { "$nin": [ null ] } }'),
 (11,'a.b.d : null',         '{ "a.b.d": null }'),
 (12,'a.b.d : $in null',     '{ "a.b.d": { "$in": [ null ] } }'),
 (13,'a.b.d : $gte null',    '{ "a.b.d": { "$gte": null } }'),
 (14,'a.b.d : $lte null',    '{ "a.b.d": { "$lte": null } }'),
 (15,'a.b.d : $ne null',     '{ "a.b.d": { "$ne": null } }'),
 (16,'a.b.d : $nin null',    '{ "a.b.d": { "$nin": [ null ] } }');

DO $abcd$
DECLARE q RECORD; idxr int[]; seqr int[]; fs text; ncons int := 0;
BEGIN
  FOR q IN SELECT ord, label, filter FROM abcd_q ORDER BY ord LOOP
    fs := format('{ "find": "abcd_null", "filter": %s, "hint": "ix" }', q.filter);
    SET enable_seqscan = off; SET enable_indexscan = on; SET enable_bitmapscan = off;
    EXECUTE 'SELECT array_agg((t.d->>''_id'')::int ORDER BY (t.d->>''_id'')::int) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
      USING 'nrg_db', fs::documentdb_core.bson INTO idxr;
    SET enable_seqscan = on; SET enable_indexscan = off;
    EXECUTE 'SELECT array_agg((t.d->>''_id'')::int ORDER BY (t.d->>''_id'')::int) FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) t'
      USING 'nrg_db', format('{ "find": "abcd_null", "filter": %s }', q.filter)::documentdb_core.bson INTO seqr;
    idxr := COALESCE(idxr, '{}'); seqr := COALESCE(seqr, '{}');
    IF idxr IS DISTINCT FROM seqr THEN ncons := ncons + 1; END IF;
    RAISE NOTICE '% : idx=% : consistency=%',
      rpad(q.label, 24), idxr::text,
      CASE WHEN idxr IS DISTINCT FROM seqr THEN 'IDX!=SEQ' ELSE 'idx==seq' END;
  END LOOP;
  RAISE NOTICE 'index/collection-scan consistency mismatches: % (must be 0)', ncons;
  RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
END $abcd$;

-- Golden index-scan result sets for the deep-leaf null family (a.b.c / a.b.d).
-- The differential harness above already pinned index-scan == collection-scan for
-- every predicate; these rows pin the exact sets served from the index, which
-- match the documented wire-protocol semantics. _id 6 is the headline case: the
-- null-first array element makes a.b.c / a.b.d null, so it MUST match $eq null
-- (and be excluded from $ne null), even though a later element supplies a value.
--   a.b.c null / $in / $gte / $lte -> 1,2,3,4,5,6,7,9
--   a.b.c $ne / $nin null          -> 8,10
--   a.b.d null / $in / $gte / $lte -> 1,2,3,4,5,6,7
--   a.b.d $ne / $nin null          -> 8,9,10
set enable_seqscan to off;
set enable_indexscan to on;
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": { "$in": [ null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": { "$nin": [ null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.d": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.d": { "$in": [ null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.d": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.d": { "$nin": [ null ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
reset enable_seqscan;
reset enable_indexscan;

-- The enable_existential_null_array_match GUC (on by default) gates the fix.
-- With it off, the deep leaf reverts to the pre-fix last-position-wins behavior:
-- _id 6 is dropped from a.b.c : null (a later element supplies a.b.c) and instead
-- appears under a.b.c : $ne null. Index scan and collection scan still agree.
set documentdb.enable_existential_null_array_match to off;
set enable_seqscan to off;
set enable_indexscan to on;
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 }, "hint": "ix" }');
set enable_indexscan to off;
set enable_seqscan to on;
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": null }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('nrg_db', '{ "find": "abcd_null", "filter": { "a.b.c": { "$ne": null } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
reset enable_seqscan;
reset enable_indexscan;
reset documentdb.enable_existential_null_array_match;
