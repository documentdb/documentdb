SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_api_internal, documentdb_core, public;
SET documentdb.next_collection_id TO 1700;
SET documentdb.next_collection_index_id TO 1700;

set documentdb.enableExtendedExplainPlans to on;

-- Scenario 1.
-- validate that truncated entries get rechecked when we're not doing extended compare Partial
SELECT COUNT(documentdb_api.insert_one('rumget_db', 'rumget_coll',  FORMAT('{ "_id": %s, "a": "%s" }', i, repeat('a', 3500) || i)::bson)) FROM generate_series(1, 100) AS i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db', '{ "createIndexes": "rumget_coll", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', TRUE);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text)) $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }') $cmd$);

-- now try with the guc off
set documentdb.enablePartialMatchHasRecheck to off;
set documentdb_rum.forcerumorderedindexscan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text)) $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }') $cmd$);

reset documentdb.enablePartialMatchHasRecheck;
reset documentdb_rum.forcerumorderedindexscan;

-- Scenario 2.
-- Validate that queries work correctly with enableIndexPathKeySummarization turned off
SET documentdb.enableIndexPathKeySummarization TO off;

-- basic equality query should still return correct results
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_coll", "filter": { "a": "aaaa30" }, "hint": "a_1" }');

SELECT document FROM bson_aggregation_find('rumget_db',
    bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text));

-- regex query should also work
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }');

-- explain should still show index usage
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text)) $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }') $cmd$);

-- Scenario 3.
-- Validate multi-key TID deduplication with enableIndexPathKeySummarization off.
-- A document with an array field matches multiple index entries. When a query
-- has multiple conditions that match different array elements, the document
-- should be returned exactly once (TIDs must be deduplicated).
SELECT documentdb_api.insert_one('rumget_db', 'rumget_multikey',
    '{ "_id": 1, "a": [3, 5, 6] }');
SELECT documentdb_api.insert_one('rumget_db', 'rumget_multikey',
    '{ "_id": 2, "a": [10, 20] }');
SELECT documentdb_api.insert_one('rumget_db', 'rumget_multikey',
    '{ "_id": 3, "a": 7 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db',
    '{ "createIndexes": "rumget_multikey", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', TRUE);

-- $gt: 5 matches element 6, $lt: 4 matches element 3 => doc _id:1 matches, returned once
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } } }');

-- same query with hint to force index usage
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }');

-- verify explain shows index scan and correct row count (1 row, not duplicated)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }') $cmd$);

-- force ordered index scan and verify explain with multi-key deduplication
SET documentdb_rum.forcerumorderedindexscan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }') $cmd$);

SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }');

RESET documentdb_rum.forcerumorderedindexscan;

-- additional multi-key queries for coverage
-- $gte: 6 matches element 6, $lte: 5 matches elements 3 and 5 => doc _id:1
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gte": 6, "$lte": 5 } }, "hint": "a_1" }');

-- $gt: 9 matches 10 and 20, $lt: 15 matches 10 => doc _id:2 returned once
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 9, "$lt": 15 } }, "hint": "a_1" }');

RESET documentdb.enableIndexPathKeySummarization;