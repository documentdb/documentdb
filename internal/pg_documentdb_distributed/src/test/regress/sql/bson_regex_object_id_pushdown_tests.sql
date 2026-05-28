SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 80000000;
SET documentdb.next_collection_id TO 8000;
SET documentdb.next_collection_index_id TO 8000;

-- Create collection and insert test data with string _id values for regex testing
SELECT documentdb_api.create_collection('regexDistDb', 'regex_id_dist');

SELECT COUNT(*) FROM (
    SELECT documentdb_api.insert_one('regexDistDb', 'regex_id_dist',
        FORMAT('{ "_id": "str_%s", "a": %s }', g, g)::bson)
    FROM generate_series(1, 20) g
) i;

-- Insert non-string _id values to verify type filtering
SELECT documentdb_api.insert_one('regexDistDb', 'regex_id_dist', '{ "_id": 100, "a": 100 }');
SELECT documentdb_api.insert_one('regexDistDb', 'regex_id_dist', '{ "_id": true, "a": 200 }');

-- Insert specific string _ids for pattern matching
SELECT documentdb_api.insert_one('regexDistDb', 'regex_id_dist', '{ "_id": "abc_one", "a": 21 }');
SELECT documentdb_api.insert_one('regexDistDb', 'regex_id_dist', '{ "_id": "abc_two", "a": 22 }');
SELECT documentdb_api.insert_one('regexDistDb', 'regex_id_dist', '{ "_id": "abd_three", "a": 23 }');
SELECT documentdb_api.insert_one('regexDistDb', 'regex_id_dist', '{ "_id": "xyz_four", "a": 24 }');

-- =============================================
-- Section 1: Result verification - anchored prefix regex on _id
-- =============================================

-- ^str_ should match all str_* _ids
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^str_" } }, "sort": { "_id": 1 } }');

-- ^abc should match abc_one, abc_two
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" } }, "sort": { "_id": 1 } }');

-- ^xyz should match xyz_four
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^xyz" } }, "sort": { "_id": 1 } }');

-- =============================================
-- Section 2: Result verification - non-anchored regex on _id
-- =============================================

-- non-anchored: "one" should match abc_one and str_1 (since "one" is not in "str_1", only abc_one)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "one" } }, "sort": { "_id": 1 } }');

-- non-anchored: "str" should match all str_* ids
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "str" } }, "sort": { "_id": 1 } }');

-- =============================================
-- Section 3: Result verification - regex via $regularExpression (regex type)
-- =============================================

-- Regex type (BSON regex) with anchored prefix
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } }, "sort": { "_id": 1 } }');

-- Regex type without anchor
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regularExpression": { "pattern": "four", "options": "" } } }, "sort": { "_id": 1 } }');

-- Regex type with case-insensitive option
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regularExpression": { "pattern": "^ABC", "options": "i" } } }, "sort": { "_id": 1 } }');

-- =============================================
-- Section 4: Combined regex on _id with other filters
-- =============================================

-- regex on _id combined with equality on another field
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" }, "a": 21 }, "sort": { "_id": 1 } }');

-- regex on _id combined with $gt on another field
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^str_1" }, "a": { "$gt": 15 } }, "sort": { "_id": 1 } }');

-- =============================================
-- Section 5: EXPLAIN plans via Citus remote execution
-- Force remote execution to verify the pushdown goes through Citus
-- =============================================

BEGIN;
SET LOCAL citus.enable_local_execution TO OFF;
SET LOCAL documentdb.useLocalExecutionShardQueries TO OFF;
SET LOCAL enable_seqscan TO OFF;

-- Anchored prefix: should show Custom Scan (Citus Adaptive) with btree pushdown
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);

-- Non-anchored regex: should show Custom Scan (Citus Adaptive) with btree pushdown
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "one" } } }')
$cmd$);

-- Regex type ($regularExpression) with anchored prefix
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } } }')
$cmd$);

-- Regex type with case-insensitive option
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regularExpression": { "pattern": "^ABC", "options": "i" } } } }')
$cmd$);

-- Combined _id regex with field filter
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" }, "a": 21 } }')
$cmd$);

COMMIT;

-- =============================================
-- Section 6: EXPLAIN ANALYZE via Citus remote execution
-- Verify actual execution through Citus with bson_regex_object_id_match pushdown
-- =============================================

BEGIN;
SET LOCAL citus.enable_local_execution TO OFF;
SET LOCAL documentdb.useLocalExecutionShardQueries TO OFF;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL enable_bitmapscan TO OFF;

-- Anchored prefix regex: verify Index Scan through Citus
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);

-- Non-anchored regex through Citus
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "one" } } }')
$cmd$);

-- Regex type ($regularExpression) through Citus
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } } }')
$cmd$);

-- Regex with case-insensitive through Citus
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regularExpression": { "pattern": "^ABC", "options": "i" } } } }')
$cmd$);

-- Combined regex + field filter through Citus
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^str_1" }, "a": { "$gt": 15 } } }')
$cmd$);

COMMIT;

-- =============================================
-- Section 7: Composite RUM index with _id regex through Citus
-- =============================================

SELECT documentdb_api_internal.create_indexes_non_concurrently('regexDistDb',
    '{ "createIndexes": "regex_id_dist", "indexes": [ { "key": { "a": 1, "_id": 1 }, "name": "idx_a_id" } ]}', true);

BEGIN;
SET LOCAL citus.enable_local_execution TO OFF;
SET LOCAL documentdb.useLocalExecutionShardQueries TO OFF;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL enable_bitmapscan TO OFF;

-- Combined _id regex + field filter should use composite RUM index through Citus
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" }, "a": { "$gt": 20 } } }')
$cmd$);

COMMIT;

-- =============================================
-- Section 8: Feature flag toggle through Citus
-- =============================================

BEGIN;
SET LOCAL citus.enable_local_execution TO OFF;
SET LOCAL documentdb.useLocalExecutionShardQueries TO OFF;
SET LOCAL enable_seqscan TO OFF;

-- With feature flag off, verify regex still works but no object_id pushdown
SET LOCAL documentdb.enableObjectIdFuncExprConversion TO off;
SET LOCAL documentdb.forceDisableSeqScan TO off;

SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" } }, "sort": { "_id": 1 } }');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexDistDb',
    '{ "find": "regex_id_dist", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);

COMMIT;
