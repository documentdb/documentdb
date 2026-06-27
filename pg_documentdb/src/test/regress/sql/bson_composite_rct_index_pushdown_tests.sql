-- Tests for TrimSecondaryVariableBounds with reduced correlated terms.
-- Verifies that only secondary paths sharing a common dotted prefix with
-- the first correlated path in the index are trimmed, and non-dotted paths
-- or paths under a different prefix are preserved.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 2400;
SET documentdb.next_collection_index_id TO 2400;

SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enableExtendedExplainPlans TO on;

-- =====================================================================
-- Test 1: Single correlated prefix group
-- Index: {a: 1, b.c: 1, b.d: 1}
-- b is array of docs → b.c, b.d are correlated under prefix "b"
-- Expected: b.d trimmed, a and b.c preserved
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "single_prefix", "indexes": [
    { "key": { "a": 1, "b.c": 1, "b.d": 1 }, "name": "idx_a_bc_bd" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'single_prefix',
  '{"_id": 1, "a": 10, "b": [{"c": 1, "d": 100}, {"c": 2, "d": 200}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'single_prefix',
  '{"_id": 2, "a": 10, "b": [{"c": 1, "d": 999}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'single_prefix',
  '{"_id": 3, "a": 20, "b": [{"c": 1, "d": 100}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'single_prefix',
  '{"_id": 4, "a": 10, "b": [{"c": 3, "d": 100}]}', NULL);

-- Filter on all three paths: a=10, b.c=1, b.d=100
-- a should have bounds [10,10], b.c should have bounds [1,1], b.d should be (MinKey, MaxKey)
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
      "filter": { "a": 10, "b.c": 1, "b.d": 100 }}')
$cmd$);

-- Verify correct results
SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
  "filter": { "a": 10, "b.c": 1, "b.d": 100 }}');

-- Filter on a + first correlated path only: no trimming needed
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
      "filter": { "a": 10, "b.c": 1 }}')
$cmd$);

-- Filter on a + second correlated path only: b.d should not be trimmed as it is the query filter leader for b.*
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
      "filter": { "a": 10, "b.d": 100 }}')
$cmd$);

-- =====================================================================
-- Test 2: Two correlated prefix groups
-- Index: {a: 1, b.c: 1, b.d: 1, f.g: 1, f.i: 1}
-- b is array of docs, f is also array of docs
-- Expected: b.d trimmed, f.i trimmed; a, b.c, f.g preserved
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "two_prefix", "indexes": [
    { "key": { "a": 1, "b.c": 1, "b.d": 1, "f.g": 1, "f.i": 1 }, "name": "idx_a_bc_bd_fg_fi" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'two_prefix',
  '{"_id": 1, "a": 10, "b": [{"c": 1, "d": 100}, {"c": 2, "d": 200}], "f": [{"g": "x", "i": "y"}, {"g": "p", "i": "q"}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'two_prefix',
  '{"_id": 2, "a": 10, "b": [{"c": 1, "d": 999}], "f": [{"g": "x", "i": "z"}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'two_prefix',
  '{"_id": 3, "a": 20, "b": [{"c": 1, "d": 100}], "f": [{"g": "x", "i": "y"}]}', NULL);

-- Filter on all 5 paths
-- a: [10,10], b.c: [1,1], b.d: trimmed, f.g: ["x","x"], f.i: trimmed
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "two_prefix",
      "filter": { "a": 10, "b.c": 1, "b.d": 100, "f.g": "x", "f.i": "y" }}')
$cmd$);

-- Verify correct results
SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "two_prefix",
  "filter": { "a": 10, "b.c": 1, "b.d": 100, "f.g": "x", "f.i": "y" }}');

-- Filter on one path per prefix group: a + b.c + f.g (all leaders, no trimming)
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "two_prefix",
      "filter": { "a": 10, "b.c": 1, "f.g": "x" }}')
$cmd$);

-- =====================================================================
-- Test 3: Mixed - one prefix is array, other is plain document
-- Index: {a: 1, b.c: 1, b.d: 1, f.g: 1, f.i: 1}
-- b is array, f is a plain document (NOT array)
-- The index has hasCorrelatedTerms due to b.* paths.
-- f.g and f.i should still both be trimmed by prefix grouping logic,
-- even though f is not an array - the trim applies to the prefix group.
-- TODO: Track which paths are actually multi-key paths and reduced correlated term applies to, the rest shouldn't
-- be trimmed even if it is a nested path.
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "mixed_array_doc", "indexes": [
    { "key": { "a": 1, "b.c": 1, "b.d": 1, "f.g": 1, "f.i": 1 }, "name": "idx_mixed" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'mixed_array_doc',
  '{"_id": 1, "a": 10, "b": [{"c": 1, "d": 100}, {"c": 2, "d": 200}], "f": {"g": "x", "i": "y"}}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'mixed_array_doc',
  '{"_id": 2, "a": 10, "b": [{"c": 1, "d": 999}], "f": {"g": "x", "i": "z"}}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'mixed_array_doc',
  '{"_id": 3, "a": 20, "b": [{"c": 1, "d": 100}], "f": {"g": "p", "i": "q"}}', NULL);

-- Filter on all paths
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "mixed_array_doc",
      "filter": { "a": 10, "b.c": 1, "b.d": 100, "f.g": "x", "f.i": "y" }}')
$cmd$);

-- Verify correct results
SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "mixed_array_doc",
  "filter": { "a": 10, "b.c": 1, "b.d": 100, "f.g": "x", "f.i": "y" }}');

-- =====================================================================
-- Test 4: No shared prefix (different top-level parents)
-- Index: {a.b: 1, c.d: 1}
-- a and c are different prefixes - neither should be trimmed
-- even when both are arrays
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "diff_prefix", "indexes": [
    { "key": { "a.b": 1, "c.d": 1 }, "name": "idx_ab_cd" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'diff_prefix',
  '{"_id": 1, "a": [{"b": 1}, {"b": 2}], "c": [{"d": 10}, {"d": 20}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'diff_prefix',
  '{"_id": 2, "a": [{"b": 1}], "c": [{"d": 30}]}', NULL);

-- Both a.b and c.d should have their bounds preserved (different prefix groups)
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "diff_prefix",
      "filter": { "a.b": 1, "c.d": 10 }}')
$cmd$);

-- Verify correct results
SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "diff_prefix",
  "filter": { "a.b": 1, "c.d": 10 }}');

-- =====================================================================
-- Test 5: Non-dotted paths only (no trimming at all)
-- Index: {a: 1, b: 1, c: 1}
-- No dotted paths → no prefix groups → nothing to trim
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "no_dots", "indexes": [
    { "key": { "a": 1, "b": 1, "c": 1 }, "name": "idx_a_b_c" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'no_dots',
  '{"_id": 1, "a": 10, "b": [1, 2, 3], "c": 100}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'no_dots',
  '{"_id": 2, "a": 10, "b": [1, 4], "c": 200}', NULL);

-- All bounds should be preserved
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "no_dots",
      "filter": { "a": 10, "b": 1, "c": 100 }}')
$cmd$);

-- =====================================================================
-- Test 6: Large compound index with one correlated prefix group
-- Index: {x: 1, y: 1, r.p: 1, r.q: 1, r.s: 1, r.t: 1}
-- r is array → r.p is leader, r.q/s/t trimmed
-- x and y preserved
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "large_group", "indexes": [
    { "key": { "x": 1, "y": 1, "r.p": 1, "r.q": 1, "r.s": 1, "r.t": 1 }, "name": "idx_large_group" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'large_group',
  '{"_id": 1, "x": "alpha", "y": 100, "r": [{"p": "v1", "q": "w1", "s": 1, "t": 0}, {"p": "v2", "q": "w2", "s": 2, "t": 0}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'large_group',
  '{"_id": 2, "x": "alpha", "y": 100, "r": [{"p": "v1", "q": "w1", "s": 1, "t": 5}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'large_group',
  '{"_id": 3, "x": "beta", "y": 100, "r": [{"p": "v1", "q": "w1", "s": 1, "t": 0}]}', NULL);

-- Filter on all paths
-- x: [alpha, alpha], y: [100, 100], r.p: [v1, v1], r.q/s/t: trimmed
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "large_group",
      "filter": { "x": "alpha", "y": 100, "r.p": "v1", "r.q": "w1", "r.s": 1, "r.t": 0 }}')
$cmd$);

-- Verify correct results
SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "large_group",
  "filter": { "x": "alpha", "y": 100, "r.p": "v1", "r.q": "w1", "r.s": 1, "r.t": 0 }}');

-- =====================================================================
-- Test 7: Deeper dotted paths share same top-level prefix
-- Index: {a.b.c: 1, a.d.e: 1}
-- Both have prefix "a" → a.d.e trimmed, a.b.c preserved
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "deep_paths", "indexes": [
    { "key": { "a.b.c": 1, "a.d.e": 1 }, "name": "idx_abc_ade" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'deep_paths',
  '{"_id": 1, "a": [{"b": {"c": 1}, "d": {"e": 10}}, {"b": {"c": 2}, "d": {"e": 20}}]}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'deep_paths',
  '{"_id": 2, "a": [{"b": {"c": 1}, "d": {"e": 99}}]}', NULL);

-- a.b.c bounds preserved, a.d.e trimmed
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "deep_paths",
      "filter": { "a.b.c": 1, "a.d.e": 10 }}')
$cmd$);

-- Verify correct results
SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "deep_paths",
  "filter": { "a.b.c": 1, "a.d.e": 10 }}');

-- =====================================================================
-- Test 8: Non-array document (no multikey) should NOT trigger trimming
-- Index: {b.c: 1, b.d: 1} but b is always a plain document
-- The index will not have hasCorrelatedTerms → no trimming
-- =====================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trim_db', '{ "createIndexes": "no_array", "indexes": [
    { "key": { "b.c": 1, "b.d": 1 }, "name": "idx_bc_bd_noarray" }
  ]}', true);

SELECT documentdb_api.insert_one('trim_db', 'no_array',
  '{"_id": 1, "b": {"c": 1, "d": 100}}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'no_array',
  '{"_id": 2, "b": {"c": 1, "d": 200}}', NULL);
SELECT documentdb_api.insert_one('trim_db', 'no_array',
  '{"_id": 3, "b": {"c": 2, "d": 100}}', NULL);

-- Both b.c and b.d should be preserved since there are no arrays → no correlated terms
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "no_array",
      "filter": { "b.c": 1, "b.d": 100 }}')
$cmd$);

-- Verify correct results
SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "no_array",
  "filter": { "b.c": 1, "b.d": 100 }}');

-- =====================================================================
-- Test 9: $in on a correlated path — first path preserved, second trimmed
-- Index: {a: 1, b.c: 1, b.d: 1}
-- =====================================================================
SELECT documentdb_api.insert_one('trim_db', 'single_prefix',
  '{"_id": 5, "a": 10, "b": [{"c": 5, "d": 500}]}', NULL);

-- $in on the first correlated path (b.c) — bounds preserved
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
      "filter": { "a": 10, "b.c": { "$in": [1, 5] }, "b.d": 100 }}')
$cmd$);

-- $gt on the first correlated path
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
      "filter": { "a": 10, "b.c": { "$gt": 0 }, "b.d": 100 }}')
$cmd$);

-- =====================================================================
-- Test 10: Query order does not affect which path is kept
-- Index: {a: 1, b.c: 1, b.d: 1}
-- Even if query lists b.d before b.c, b.c (earlier in index) is leader
-- =====================================================================
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
      "filter": { "b.d": 100, "b.c": 1, "a": 10 }}')
$cmd$);

-- =====================================================================
-- Test 11: GUC off fallback — all secondary bounds trimmed
-- Same query as Test 1 but with prefix trim disabled.
-- Expected: only a preserved, b.c and b.d both trimmed (old behavior)
-- =====================================================================
SET documentdb.enableCompositeReducedCorrelatedPrefixTrim TO off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('trim_db', '{ "find": "single_prefix",
      "filter": { "a": 10, "b.c": 1, "b.d": 100 }}')
$cmd$);

SET documentdb.enableCompositeReducedCorrelatedPrefixTrim TO on;

-- =====================================================================
-- Cleanup
-- =====================================================================
SELECT documentdb_api.drop_collection('trim_db', 'single_prefix');
SELECT documentdb_api.drop_collection('trim_db', 'two_prefix');
SELECT documentdb_api.drop_collection('trim_db', 'mixed_array_doc');
SELECT documentdb_api.drop_collection('trim_db', 'diff_prefix');
SELECT documentdb_api.drop_collection('trim_db', 'no_dots');
SELECT documentdb_api.drop_collection('trim_db', 'large_group');
SELECT documentdb_api.drop_collection('trim_db', 'deep_paths');
SELECT documentdb_api.drop_collection('trim_db', 'no_array');
