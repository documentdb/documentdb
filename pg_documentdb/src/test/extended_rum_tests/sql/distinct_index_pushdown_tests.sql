SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal,public;

-- ============================================================
-- Setup: Create collection with varied data for distinct tests
-- ============================================================
SET documentdb.defaultUseCompositeOpClass TO on;

-- Ensure database 'db' exists so that the system.dbSentinel collection
-- does not consume a test collection ID when running in standalone mode.
SELECT documentdb_api.insert_one('db', 'setup_sentinel', '{ "_id": 0 }');
SELECT documentdb_api.drop_collection('db', 'setup_sentinel');

SET documentdb.next_collection_id TO 19900;
SET documentdb.next_collection_index_id TO 19900;

-- Create indexes before inserting data
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_push", "indexes": [ { "key": { "a": 1 }, "name": "idx_a" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_push", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "idx_a_b" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_push", "indexes": [ { "key": { "nested.field": 1 }, "name": "idx_nested" } ] }', true);

-- Insert non-array data (non-multikey) with duplicates for distinct to collapse
SELECT COUNT(documentdb_api.insert_one('db', 'dist_push', bson_build_document('_id', i, 'a', i % 10, 'b', chr(65 + (i % 5)), 'nested', bson_build_document('field', i % 7), 'extra', concat('data_', i)))) FROM generate_series(1, 200) AS i;

-- Analyze to ensure planner has accurate statistics for index selection
ANALYZE;

-- ============================================================
-- Test 1: EXPLAIN distinct on single indexed field - pushdown ON
-- With enableDistinctIndexPushdown ON, Sort node should be absent
-- and the composite index should provide ordering directly.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 2: EXPLAIN distinct on single indexed field - pushdown OFF
-- With enableDistinctIndexPushdown OFF, Sort should be present
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 3: EXPLAIN distinct on nested/dotted path - pushdown ON
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "nested.field" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 4: EXPLAIN distinct on leading key of compound index - pushdown ON
-- Index { a: 1, b: 1 } should support ordering on the leading key "a"
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 5: EXPLAIN distinct on non-leading key of compound index - pushdown ON
-- Index can't provide ordering on non-prefix key "b" alone;
-- Sort should still be present even with pushdown ON.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "b" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 6: EXPLAIN distinct on multikey field - pushdown should NOT apply
-- Multikey indexes cannot provide ordering for distinct
-- ============================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_push_mk", "indexes": [ { "key": { "arr": 1 }, "name": "idx_arr" } ] }', true);
SELECT documentdb_api.insert_one('db', 'dist_push_mk', '{ "arr": [1, 2, 3], "x": "a" }');
SELECT documentdb_api.insert_one('db', 'dist_push_mk', '{ "arr": [2, 3, 4], "x": "b" }');
SELECT documentdb_api.insert_one('db', 'dist_push_mk', '{ "arr": [3, 4, 5], "x": "c" }');
SELECT documentdb_api.insert_one('db', 'dist_push_mk', '{ "arr": 9, "x": "d" }');

ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push_mk", "key": "arr" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 7: Multikey transition - insert array into non-multikey collection
-- After inserting an array value into field "a", the index becomes multikey
-- and pushdown should NO LONGER eliminate Sort.
-- ============================================================
SELECT documentdb_api.insert_one('db', 'dist_push', '{ "_id": 999, "a": [100, 200, 300], "b": "Z" }');
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

-- After multikey insertion, Sort should reappear even with pushdown ON
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$);
ROLLBACK;

-- Remove the array doc and vacuum to clear multikey flag
SELECT documentdb_api.delete('db', '{ "delete": "dist_push", "deletes": [ { "q": { "_id": 999 }, "limit": 1 } ] }');
CALL documentdb_test_helpers.wait_for_vacuum_horizon();
VACUUM (FREEZE) documentdb_data.documents_19900;
ANALYZE documentdb_data.documents_19900;

-- ============================================================
-- Test 8: Distinct correctness - pushdown ON vs OFF on indexed field "a"
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }');

-- ============================================================
-- Test 9: Distinct correctness on field "b" - pushdown ON vs OFF
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "b" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "b" }');

-- ============================================================
-- Test 10: Distinct correctness on nested path - pushdown ON vs OFF
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "nested.field" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "nested.field" }');

-- ============================================================
-- Test 11: Distinct with filter - pushdown ON vs OFF
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$gte": 5 } } }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$gte": 5 } } }');

-- ============================================================
-- Test 12: Distinct on multikey field - correctness with pushdown ON vs OFF
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push_mk", "key": "arr" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push_mk", "key": "arr" }');

-- ============================================================
-- Test 13: Distinct on non-indexed field - should work regardless of GUC
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "extra" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "extra" }');

-- ============================================================
-- Test 14: EXPLAIN distinct with filter on indexed field - pushdown ON
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$gte": 5 } } }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 15: EXPLAIN distinct with filter - pushdown OFF
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$gte": 5 } } }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 16: Distinct with filter on different field than distinct key
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "b": "A" } }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "b": "A" } }');

-- ============================================================
-- Tests 17-26: Distinct with truncated index terms
-- Index term truncation limit is ~2.7KB for single-path indexes.
-- Values larger than that are stored truncated in the index.
-- Distinct must return correct, full-fidelity values regardless.
-- With pushdown ON, the plan should show index ordering with recheck.
-- ============================================================

-- Create collection with large string values that exceed the truncation limit
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_trunc", "indexes": [ { "key": { "bigstr": 1 }, "name": "idx_bigstr" } ] }', true);

-- Insert strings of ~4000 chars each, differing only in the last few characters (beyond truncation point).
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 1, 'bigstr', concat(repeat('A', 4000), '_val1'), 'tag', 'str'::text));
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 2, 'bigstr', concat(repeat('A', 4000), '_val2'), 'tag', 'str'::text));
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 3, 'bigstr', concat(repeat('A', 4000), '_val3'), 'tag', 'str'::text));
-- Duplicate of val1 to verify deduplication still works
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 4, 'bigstr', concat(repeat('A', 4000), '_val1'), 'tag', 'str'::text));
-- A short string that is NOT truncated
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 5, 'bigstr', 'short_value'::text, 'tag', 'str'::text));

SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_trunc", "indexes": [ { "key": { "bigdoc": 1 }, "name": "idx_bigdoc" } ] }', true);

-- Insert documents with large nested subdocuments that differ after truncation point
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 10, 'bigdoc', bson_build_document('payload', repeat('X', 4000), 'key', 'doc1'::text), 'tag', 'doc'::text));
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 11, 'bigdoc', bson_build_document('payload', repeat('X', 4000), 'key', 'doc2'::text), 'tag', 'doc'::text));
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 12, 'bigdoc', bson_build_document('payload', repeat('X', 4000), 'key', 'doc1'::text), 'tag', 'doc'::text));
-- A small document that is NOT truncated
SELECT documentdb_api.insert_one('db', 'dist_trunc', bson_build_document('_id', 13, 'bigdoc', bson_build_document('key', 'small'::text), 'tag', 'doc'::text));

SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_trunc", "indexes": [ { "key": { "bigbin": 1 }, "name": "idx_bigbin" } ] }', true);

-- Insert binary values using base64-encoded data (~4KB each, differing at the end)
SELECT documentdb_api.insert_one('db', 'dist_trunc', format('{ "_id": 20, "bigbin": { "$binary": { "base64": "%sAQ==", "subType": "00" } }, "tag": "bin" }', repeat('QUFB', 1024))::bson);
SELECT documentdb_api.insert_one('db', 'dist_trunc', format('{ "_id": 21, "bigbin": { "$binary": { "base64": "%sAg==", "subType": "00" } }, "tag": "bin" }', repeat('QUFB', 1024))::bson);
SELECT documentdb_api.insert_one('db', 'dist_trunc', format('{ "_id": 22, "bigbin": { "$binary": { "base64": "%sAQ==", "subType": "00" } }, "tag": "bin" }', repeat('QUFB', 1024))::bson);
-- A small binary value that is NOT truncated
SELECT documentdb_api.insert_one('db', 'dist_trunc', '{ "_id": 23, "bigbin": { "$binary": { "base64": "AQID", "subType": "00" } }, "tag": "bin" }');

-- Analyze for truncated collection
ANALYZE;

-- ============================================================
-- Test 17: EXPLAIN distinct on truncated strings - pushdown ON
-- Should show index ordering with recheck for truncated terms
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 18: EXPLAIN distinct on truncated docs - pushdown ON
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigdoc" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 19: EXPLAIN distinct on truncated binary - pushdown ON
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigbin" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 20: Distinct on truncated strings - correctness validation
-- Must return 4 distinct values (3 long + 1 short), not collapse the long ones
-- Validate count and that suffixes (_val1, _val2, _val3, short_value) are present
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr" }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

-- Verify pushdown OFF gives same count
SET documentdb.enableDistinctIndexPushdown TO off;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr" }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

-- ============================================================
-- Test 21: Validate truncated string suffixes are preserved
-- Extract the last 5 chars of each value to confirm full fidelity
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr" }'))
SELECT bson_dollar_project(document, '{ "suffixes": { "$map": { "input": "$values", "as": "v", "in": { "$substrBytes": [ "$$v", 4000, 5 ] } } } }') FROM r1;

SET documentdb.enableDistinctIndexPushdown TO off;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr" }'))
SELECT bson_dollar_project(document, '{ "suffixes": { "$map": { "input": "$values", "as": "v", "in": { "$substrBytes": [ "$$v", 4000, 5 ] } } } }') FROM r1;

-- ============================================================
-- Test 22: Distinct on truncated documents - correctness validation
-- Must return 3 distinct docs (2 large + 1 small), dedup large doc1 duplicates
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigdoc" }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

SET documentdb.enableDistinctIndexPushdown TO off;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigdoc" }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

-- ============================================================
-- Test 23: Distinct on truncated binary - correctness validation
-- Must return 3 distinct binary values (2 large + 1 small)
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigbin" }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

SET documentdb.enableDistinctIndexPushdown TO off;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigbin" }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

-- ============================================================
-- Test 24: Mixed truncated and non-truncated in same index
-- Verify distinct correctly handles a mix of truncated and short values
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "tag" }');

SET documentdb.enableDistinctIndexPushdown TO off;
SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "tag" }');

-- ============================================================
-- Test 25: Distinct with filter on truncated field - correctness
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr", "query": { "tag": "str" } }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

SET documentdb.enableDistinctIndexPushdown TO off;
WITH r1 AS (SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr", "query": { "tag": "str" } }'))
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }') FROM r1;

-- ============================================================
-- Test 26: EXPLAIN distinct with filter on truncated field - pushdown ON
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_trunc", "key": "bigstr", "query": { "tag": "str" } }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Custom Scan (enableDistinctCustomScan) Tests
-- This mode wraps index scans to skip duplicate index entries,
-- scanning only one row per distinct value instead of all rows.
-- ============================================================

-- Setup: collection with 4000 rows but only 4 distinct values of "x"
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_cscan", "indexes": [ { "key": { "x": 1 }, "name": "idx_x" } ] }', true);
SELECT COUNT(documentdb_api.insert_one('db', 'dist_cscan', bson_build_document('_id', i, 'x', i % 4, 'pad', concat('padding_', i)))) FROM generate_series(1, 4000) AS i;
ANALYZE;

-- ============================================================
-- Test 27: EXPLAIN distinct with custom scan ON
-- The plan should show Custom Scan (DocumentDBApiDistinctQueryScan)
-- wrapping the Index Scan, and only ~4 rows returned (not 4000).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 28: EXPLAIN distinct with custom scan OFF (pushdown still ON)
-- Without custom scan, the plan should NOT show the
-- DocumentDBApiDistinctQueryScan wrapper node.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 29: EXPLAIN ANALYZE with custom scan ON - verify row counts
-- With 4000 rows and 4 distinct values, the custom scan should
-- produce only ~4 rows from the index (not 4000).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 30: EXPLAIN ANALYZE with custom scan OFF - verify row counts
-- Without custom scan, all 4000 rows should be scanned from index.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 31: Correctness - custom scan ON returns same results
-- Verify that the distinct values are identical with custom scan
-- ON and OFF.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

WITH r1 AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
)
SELECT bson_dollar_project(document, '{ "values": 1 }') FROM r1;
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO off;

WITH r1 AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
)
SELECT bson_dollar_project(document, '{ "values": 1 }') FROM r1;
ROLLBACK;

-- ============================================================
-- Test 32: Correctness after DELETE - custom scan ON
-- Delete all rows where x=2, then verify distinct returns {0,1,3}
-- ============================================================
SELECT documentdb_api.delete('db', '{ "delete": "dist_cscan", "deletes": [ { "q": { "x": 2 }, "limit": 0 } ] }');

-- VACUUM so the index is cleaned up and dead tuples are removed
VACUUM;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

WITH r1 AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
)
SELECT bson_dollar_project(document, '{ "values": 1 }') FROM r1;
ROLLBACK;

-- Also verify EXPLAIN ANALYZE shows only ~3 rows scanned
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 33: Correctness after UPDATE - custom scan ON
-- Update all rows where x=0 to x=5, then verify distinct returns {1,3,5}
-- ============================================================
SELECT documentdb_api.update('db', '{ "update": "dist_cscan", "updates": [ { "q": { "x": 0 }, "u": { "$set": { "x": 5 } }, "multi": true } ] }');
VACUUM;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

WITH r1 AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
)
SELECT bson_dollar_project(document, '{ "values": 1 }') FROM r1;
ROLLBACK;

-- ============================================================
-- Test 34: Custom scan with filter - only scan matching subset
-- After previous mutations: x values are {1, 3, 5}
-- Filter x >= 3 should return {3, 5}
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

WITH r1 AS (
  SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x", "query": { "x": { "$gte": 3 } } }')
)
SELECT bson_dollar_project(document, '{ "values": 1 }') FROM r1;
ROLLBACK;

-- ============================================================
-- Test 35: Custom scan with multikey (array) field
-- Arrays cause multikey which should prevent the custom scan
-- from being used (falls back to regular index scan).
-- ============================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_cscan_mk", "indexes": [ { "key": { "arr": 1 }, "name": "idx_arr" } ] }', true);
SELECT documentdb_api.insert_one('db', 'dist_cscan_mk', '{ "_id": 1, "arr": [1, 2] }');
SELECT documentdb_api.insert_one('db', 'dist_cscan_mk', '{ "_id": 2, "arr": [2, 3] }');
SELECT documentdb_api.insert_one('db', 'dist_cscan_mk', '{ "_id": 3, "arr": [3, 4] }');
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan_mk", "key": "arr" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 36: Custom scan with compound index - distinct on leading key
-- With compound index {x: 1, y: 1}, distinct on "x" should use
-- the custom scan on the leading key.
-- ============================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_cscan", "indexes": [ { "key": { "x": 1, "pad": 1 }, "name": "idx_x_pad" } ] }', true);

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_cscan", "key": "x" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Index Only Scan Tests for Distinct
-- Verify that distinct queries can use Index Only Scan when the
-- index supports ordered scans and the visibility map is up to date.
-- ============================================================

-- Setup: collection for index-only scan with ordered index
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_ios", "indexes": [ { "key": { "status": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "idx_status_ordered" } ] }', true);

-- Disable autovacuum so VACUUM FREEZE controls visibility map
ALTER TABLE documentdb_data.documents_19905 SET (autovacuum_enabled = off);

-- Insert data with a few distinct status values
SELECT COUNT(documentdb_api.insert_one('db', 'dist_ios', bson_build_document('_id', i, 'status', CASE WHEN i % 5 = 0 THEN 'active' WHEN i % 5 = 1 THEN 'pending' WHEN i % 5 = 2 THEN 'closed' WHEN i % 5 = 3 THEN 'archived' ELSE 'draft' END, 'extra', concat('payload_', i)))) FROM generate_series(1, 500) AS i;

-- VACUUM FREEZE to mark all pages visible (enables index-only scan)
VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_19905;

-- ============================================================
-- Test 37: EXPLAIN ANALYZE distinct with index-only scan - pushdown ON
-- The plan should show "Index Only Scan" (not "Index Scan").
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_ios", "key": "status" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 38: EXPLAIN ANALYZE distinct with index-only scan - pushdown OFF
-- Should still use Index Only Scan but with Sort node present.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_ios", "key": "status" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 39: EXPLAIN ANALYZE distinct with index-only scan + custom scan
-- Custom scan wrapping an Index Only Scan should still use index-only.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_ios", "key": "status" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 40: Correctness - index-only scan distinct returns correct values
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

WITH r1 AS (
    SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_ios", "key": "status" }')
) SELECT bson_dollar_project(document, '{ "values": 1 }') FROM r1;
ROLLBACK;

-- ============================================================
-- Test 41: Distinct with filter on ordered index - index-only scan
-- Verify index-only scan is used even with a filter.
-- ============================================================

-- Create a compound ordered index for filter + distinct
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{ "createIndexes": "dist_ios", "indexes": [ { "key": { "status": 1, "extra": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "idx_status_extra_ordered" } ] }', true);
VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_19905;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_ios", "key": "status", "query": { "status": { "$gte": "closed" } } }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Extended Explain Tests for Distinct
-- Verify that enableExtendedExplainPlans provides additional
-- index metadata (indexName, indexBounds, scanType, etc.)
-- for distinct queries.
-- ============================================================

-- ============================================================
-- Test 42: Extended explain with distinct pushdown ON
-- Should show DocumentDBApiExplainQueryScan wrapper with
-- index metadata including indexBounds and scanType.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 43: Extended explain with distinct on compound index
-- Should show compound index metadata with multiple key bounds.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$gte": 5 } } }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 44: Extended explain with distinct custom scan ON
-- Should show DocumentDBApiExplainQueryScan wrapping the
-- DocumentDBApiDistinctQueryScan custom scan.
-- Uses dist_ios with an ordered index to get consistent results.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_ios", "key": "status" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 45: Extended explain with index-only scan
-- Should show index metadata with scanType for ordered index.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_ios", "key": "status" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 46: Extended explain with pushdown OFF
-- Without pushdown, distinct falls back to _id scan.
-- Extended explain should reflect the different scan strategy.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 47: Multikey index exists-true pushdown - pushdown ON
-- When the chosen index is multikey and a distinct is present, the
-- order-by cannot be pushed down (Sort remains). However, an
-- $exists: true filter on the distinct path is still pushed into the
-- index clauses so the scan is restricted to documents that contain
-- the field. Force the multikey composite index via a hint so the
-- pushed clause is visible in the Index Cond.
-- Expect: Index Scan using idx_arr with an Index Cond containing
-- @> '{ "arr" : { "$minKey" : 1 } }' and a Sort node still present.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push_mk", "key": "arr", "hint": "idx_arr" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 48: Multikey index exists-true pushdown - pushdown OFF
-- With pushdown OFF the order-by processing does not run, so no
-- $exists: true clause is pushed into the multikey index. Forcing the
-- multikey index via a hint should show a plain index scan (only the
-- orderByScan clause) with a Sort node, and no minKey exists clause.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push_mk", "key": "arr", "hint": "idx_arr" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Reinsert an array document into dist_push so that idx_a and idx_a_b
-- carry a live multikey term for the following tests, rather than only
-- the sticky metapage flag left behind by Test 7 (whose array doc was
-- deleted and vacuumed away). This keeps the multikey pushdown tests
-- below unambiguous: the index is genuinely multikey on "a" and the
-- extended-explain "isMultiKey" metadata reflects that.
-- ============================================================
SELECT documentdb_api.insert_one('db', 'dist_push', '{ "_id": 998, "a": [100, 200, 300], "b": "Z" }');
ANALYZE documentdb_data.documents_19900;

-- ============================================================
-- Test 49: Distinct with a hint forcing a specific index
-- The dist_push collection has both idx_a ({ a: 1 }) and idx_a_b
-- ({ a: 1, b: 1 }). A distinct on "a" could use either; a hint should
-- force the planner to use the named index.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

-- Hint the compound index idx_a_b explicitly.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "hint": "idx_a_b" }')
$cmd$);
ROLLBACK;

-- Hint the single-field index idx_a explicitly.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "hint": "idx_a" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 50: Distinct on "a" with a filter on "b" over composite
-- index { a: 1, b: 1 }. The distinct key "a" is multikey and has no
-- bound of its own, so an $exists: true (@>= minKey) clause is pushed
-- on "a"; the query filter on "b" is pushed as a separate index clause.
-- Expect the Index Cond to contain a clause on "a" (orderByScan +
-- $minKey exists) AND a clause on "b" (the $gte filter).
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "b": { "$gte": "C" } }, "hint": "idx_a_b" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Test 51: Same query as Test 50 with extended explain plans ON.
-- The extended explain metadata should show the composite index
-- bounds for both "a" (with the $exists/$minKey lower bound) and "b".
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "b": { "$gte": "C" } }, "hint": "idx_a_b" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 52: Add a bound on the distinct key "a" (a > 5) alongside the
-- "b" filter. Because "a" now has its own (non-equality) bound, the
-- $exists: true (@>= minKey) clause should NO LONGER be pushed; the
-- Index Cond should contain the "a" > 5 bound and the "b" filter only.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "a": { "$gt": 5 }, "b": { "$gte": "C" } }, "hint": "idx_a_b" }')
$cmd$, p_ignore_heap_fetches => true);
ROLLBACK;

-- ============================================================
-- Test 53: Feature flag gate - enable_distinct_multikey_filter_pushdown
-- OFF. With the flag disabled, the $exists: true (@>= minKey) clause is
-- NOT pushed into the multikey index even though distinct pushdown is on
-- and the index is multikey. The order-by still cannot be pushed (Sort
-- remains) and only the orderByScan clause appears in the Index Cond.
-- ============================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableDistinctIndexPushdown TO on;
SET LOCAL documentdb.enable_distinct_multikey_filter_pushdown TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('db', '{ "distinct": "dist_push", "key": "a", "query": { "b": { "$gte": "C" } }, "hint": "idx_a_b" }')
$cmd$);
ROLLBACK;

-- ============================================================
-- Cleanup
-- ============================================================
-- SELECT documentdb_api.drop_collection('db', 'dist_push');
-- SELECT documentdb_api.drop_collection('db', 'dist_push_mk');
-- SELECT documentdb_api.drop_collection('db', 'dist_trunc');
-- SELECT documentdb_api.drop_collection('db', 'dist_cscan');
-- SELECT documentdb_api.drop_collection('db', 'dist_cscan_mk');
-- SELECT documentdb_api.drop_collection('db', 'dist_ios');
