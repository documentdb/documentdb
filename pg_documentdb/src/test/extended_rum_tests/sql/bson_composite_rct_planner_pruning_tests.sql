SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 29200;
SET documentdb.next_collection_index_id TO 29200;

SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

-- An MKP reduced-correlated index can prune unsafe plain dotted-path quals
-- during planning while preserving directly correlated quals from one
-- $elemMatch.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rct_prune_db',
    '{ "createIndexes": "items", "indexes": [
        {
          "key": {
            "items.id": 1,
            "items.city": 1,
            "items.role": 1,
            "profile.city": 1,
            "profile.age": 1
          },
          "name": "idx_items_profile",
          "enableOrderedIndex": 1
        }
    ]}',
    true);

SELECT documentdb_api.insert_one(
    'rct_prune_db', 'items',
    '{"_id":1,"items":[{"id":"A","city":"seattle","role":"customer","age":30}],"profile":{"city":"seattle","age":30}}');
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'items',
    '{"_id":2,"items":[{"id":"A","city":"portland","role":"lawyer","age":30},{"id":"B","city":"seattle","role":"customer","age":40}],"profile":{"city":"seattle","age":30}}');
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'items',
    '{"_id":3,"items":[{"id":"A","city":"seattle","role":"auditor","age":20}],"profile":{"city":"portland","age":20}}');

-- One $elemMatch owns the leading bound, so all of its same-prefix quals stay
-- on the index. The cross-element decoy (_id:2) is rejected by the index.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}}},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}}},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- Plain dotted-path predicates may match different elements. Keep the leading
-- id bound and evaluate city as a runtime filter so _id:2 remains visible.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items.id":"A","items.city":"seattle"},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"items.id":"A","items.city":"seattle"},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- Internal order-by range quals do not produce variable bounds and therefore
-- must not participate in correlated-prefix leader selection.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items.id":"A","items.city":"seattle"},"sort":{"items.role":1},"hint":"idx_items_profile"}')
$cmd$);

-- Planner-certified $elemMatch bounds must also survive the ordered-scan path.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}}},"sort":{"items.role":1},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}}},"sort":{"items.role":1},"hint":"idx_items_profile"}');

-- Independent $elemMatch groups may use different elements. They must not be
-- combined into one same-element bound group.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"$and":[{"items":{"$elemMatch":{"id":"A"}}},{"items":{"$elemMatch":{"city":"seattle"}}}]},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"$and":[{"items":{"$elemMatch":{"id":"A"}}},{"items":{"$elemMatch":{"city":"seattle"}}}]},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- A plain predicate under the same prefix remains independent from the
-- $elemMatch group and is pruned.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}},"items.role":"customer"},"hint":"idx_items_profile"}')
$cmd$);

-- A plain predicate and $elemMatch both constrain the lowest column. Keep both
-- id bounds, but trim the secondary city bound because the owners differ.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"$and":[{"items.id":"A"},{"items":{"$elemMatch":{"id":"B","city":"seattle"}}}]},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"$and":[{"items.id":"A"},{"items":{"$elemMatch":{"id":"B","city":"seattle"}}}]},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- The original heap filter still evaluates unindexed $elemMatch fields.
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle","age":30}}},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- A regex condition from the same $elemMatch remains an index qual. The heap
-- filter is still required for full $elemMatch semantics.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","role":{"$regex":"^CUSTOMER$","$options":"i"}}}},"hint":"idx_items_profile"}')
$cmd$);

-- Two multi-field $elemMatch groups both constrain the leader. The leader is
-- ambiguous, so neither group may extend into secondary bounds.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"$and":[{"items":{"$elemMatch":{"id":"A","role":"lawyer"}}},{"items":{"$elemMatch":{"id":"B","city":"seattle"}}}]},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"$and":[{"items":{"$elemMatch":{"id":"A","role":"lawyer"}}},{"items":{"$elemMatch":{"id":"B","city":"seattle"}}}]},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- $or branches use separate bitmap index scans, so each $elemMatch can retain
-- the safe correlated bounds within its own branch.
SET enable_bitmapscan TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"$or":[{"items":{"$elemMatch":{"id":"A","role":"lawyer"}}},{"items":{"$elemMatch":{"id":"A","city":"seattle"}}}]},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"$or":[{"items":{"$elemMatch":{"id":"A","role":"lawyer"}}},{"items":{"$elemMatch":{"id":"A","city":"seattle"}}}]},"sort":{"_id":1},"hint":"idx_items_profile"}');
SET enable_bitmapscan TO off;

-- Per-path metadata proves these dotted siblings are scalar, so both bounds
-- are safe to retain.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"profile.city":"seattle","profile.age":30},"hint":"idx_items_profile"}')
$cmd$);

-- A full-correlated index stores cross-element combinations, so planner
-- pruning is unnecessary. This legacy mode intentionally relies on full
-- cross-products, so opt it out of the metadata-backed parallel-array guard.
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO off;
SET documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rct_prune_db',
    '{"createIndexes":"full_terms","indexes":[{"key":{"items.id":1,"items.city":1},"name":"idx_full_terms","enableOrderedIndex":1}]}',
    true);
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'full_terms',
    '{"_id":1,"items":[{"id":"A","city":"portland"},{"id":"B","city":"seattle"}]}');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"full_terms","filter":{"items.id":"A","items.city":"seattle"},"hint":"idx_full_terms"}')
$cmd$);
SELECT document FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"full_terms","filter":{"items.id":"A","items.city":"seattle"},"hint":"idx_full_terms"}');
RESET documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking;

-- Legacy indexes without planner-readable MKP metadata keep the execution-time
-- pruning fallback.
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rct_prune_db',
    '{"createIndexes":"legacy_terms","indexes":[{"key":{"items.id":1,"items.city":1},"name":"idx_legacy_terms","enableOrderedIndex":1}]}',
    true);
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'legacy_terms',
    '{"_id":1,"items":[{"id":"A","city":"portland"},{"id":"B","city":"seattle"}]}');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"legacy_terms","filter":{"items.id":"A","items.city":"seattle"},"hint":"idx_legacy_terms"}')
$cmd$);
SELECT document FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"legacy_terms","filter":{"items.id":"A","items.city":"seattle"},"hint":"idx_legacy_terms"}');

-- Flag-off plans carry no planner marker, so execution retains conservative
-- reduced-correlated trimming even on an MKP index.
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}}},"hint":"idx_items_profile"}')
$cmd$);
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO on;

SET documentdb.enableIndexMetadataGlobalTracking TO on;

-- Add cross-element and same-element documents after the pre-existing matrix
-- so these cases do not perturb its EXPLAIN cardinalities.
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'items',
    '{"_id":4,"items":[{"id":"C","city":"portland","role":"customer"},{"id":"Z","city":"seattle","role":"lawyer"}]}');
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'items',
    '{"_id":5,"items":[{"id":"C","city":"seattle","role":"auditor"}]}');

-- The lowest queried column need not be the first indexed column. With id
-- unbounded, city becomes the lowest queried items column and may retain role
-- from the same $elemMatch. The cross-element decoy (_id:4) must be rejected.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"city":"seattle","role":"customer"}}},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"city":"seattle","role":"customer"}}},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- Multiple range operations on the lowest queried column must all retain the
-- same planner marker as the secondary city bound.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"id":{"$gt":"B","$lt":"D"},"city":"seattle"}}},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"id":{"$gt":"B","$lt":"D"},"city":"seattle"}}},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- $in expansion inside $elemMatch must preserve the same-element city bound.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"items","filter":{"items":{"$elemMatch":{"id":{"$in":["C","Q"]},"city":"seattle"}}},"hint":"idx_items_profile"}')
$cmd$);
SELECT document
FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"id":{"$in":["C","Q"]},"city":"seattle"}}},"sort":{"_id":1},"hint":"idx_items_profile"}');

-- A generic plan built before the index has arrays carries no planner marker.
-- A later execution must retain the legacy trim if the index becomes reduced
-- correlated.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rct_prune_db',
    '{"createIndexes":"metadata_growth","indexes":[{"key":{"a.b":1,"a.c":1},"name":"idx_metadata_growth","enableOrderedIndex":1}]}',
    true);
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'metadata_growth',
    '{"_id":1,"a":{"b":0,"c":0}}');

SET plan_cache_mode TO force_generic_plan;
PREPARE cached_rct_query AS
SELECT document FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"metadata_growth","filter":{"a.b":1,"a.c":2},"hint":"idx_metadata_growth"}');
EXECUTE cached_rct_query;

-- This insert makes both paths multikey and starts emitting reduced-correlated
-- terms. Execution must trim a.c from the unmarked cached plan before scanning.
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'metadata_growth',
    '{"_id":2,"a":[{"b":1,"c":0},{"b":0,"c":2}]}');
EXECUTE cached_rct_query;
DEALLOCATE cached_rct_query;
RESET plan_cache_mode;

-- An outer $elemMatch does not correlate fields across a nested array. Keep
-- only one deep bound so predicates may match different nested elements.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rct_prune_db',
    '{"createIndexes":"nested_arrays","indexes":[{"key":{"a.b.c":1,"a.b.d":1},"name":"idx_nested_arrays","enableOrderedIndex":1}]}',
    true);
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'nested_arrays',
    '{"_id":1,"a":[{"b":[{"c":1,"d":0},{"c":0,"d":2}]}]}');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"nested_arrays","filter":{"a":{"$elemMatch":{"b.c":1,"b.d":2}}},"hint":"idx_nested_arrays"}')
$cmd$);
SELECT document FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"nested_arrays","filter":{"a":{"$elemMatch":{"b.c":1,"b.d":2}}},"hint":"idx_nested_arrays"}');

-- Moving $elemMatch to the physical correlation level makes both bounds safe.
SELECT documentdb_api.insert_one(
    'rct_prune_db', 'nested_arrays',
    '{"_id":2,"a":[{"b":[{"c":1,"d":2}]}]}');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rct_prune_db',
        '{"find":"nested_arrays","filter":{"a.b":{"$elemMatch":{"c":1,"d":2}}},"hint":"idx_nested_arrays"}')
$cmd$);
SELECT document FROM bson_aggregation_find(
    'rct_prune_db',
    '{"find":"nested_arrays","filter":{"a.b":{"$elemMatch":{"c":1,"d":2}}},"hint":"idx_nested_arrays"}');

SELECT documentdb_api.drop_collection('rct_prune_db', 'items');
SELECT documentdb_api.drop_collection('rct_prune_db', 'full_terms');
SELECT documentdb_api.drop_collection('rct_prune_db', 'legacy_terms');
SELECT documentdb_api.drop_collection('rct_prune_db', 'metadata_growth');
SELECT documentdb_api.drop_collection('rct_prune_db', 'nested_arrays');
