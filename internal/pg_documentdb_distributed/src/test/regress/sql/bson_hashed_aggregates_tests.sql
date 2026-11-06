-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core;

SET documentdb.next_collection_id TO 1430;
SET documentdb.next_collection_index_id TO 1430;
SET citus.next_shard_id TO 143000;

-- Insert test data for hashed aggregates
SELECT * FROM documentdb_api.insert_one('testdb', 'hash_aggTest', '{ "_id": 1, "key": 1, "value": "abc" }');
SELECT * FROM documentdb_api.insert_one('testdb', 'hash_aggTest', '{ "_id": 2, "key": 2, "value": "def" }');
SELECT * FROM documentdb_api.insert_one('testdb', 'hash_aggTest', '{ "_id": 3, "key": 1, "value": "ghi" }');

-- Enforce hashed aggregate plans
SET enable_hashagg = on;
SET enable_sort = off;
SET enable_incremental_sort = off;
SET documentdb.defaultcursorfirstpagebatchsize = 1;

-- TEST each aggregate, TODO add more

-- Drain both pages so no file slots remain occupied for later quota tests.
SELECT cursorPage, continuation, cursorId
FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$push": "$$ROOT" } } } ], "cursor" : {  } }')
\gset hash_push_
SELECT :'hash_push_cursorpage'::bson->'cursor.firstBatch';
SELECT cursorPage->'cursor.nextBatch' AS next_batch, continuation IS NULL AS fully_drained
FROM cursor_get_more('testdb',
    FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "hash_aggTest", "batchSize": 100 }', :'hash_push_cursorid')::bson,
    :'hash_push_continuation'::bson);

-- $addToSet under hash aggregation
SELECT cursorPage, continuation, cursorId
FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$addToSet": "$$ROOT" } } } ], "cursor" : {  } }')
\gset hash_set_
SELECT :'hash_set_cursorpage'::bson->'cursor.firstBatch';
SELECT cursorPage->'cursor.nextBatch' AS next_batch, continuation IS NULL AS fully_drained
FROM cursor_get_more('testdb',
    FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "hash_aggTest", "batchSize": 100 }', :'hash_set_cursorid')::bson,
    :'hash_set_continuation'::bson);

-- Check if we are really are doing hash aggregations
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT * FROM bson_aggregation_pipeline('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$push": "$$ROOT" } } } ], "cursor" : {  } }')
$cmd$, false, true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT * FROM bson_aggregation_pipeline('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$addToSet": "$$ROOT" } } } ], "cursor" : {  } }')
$cmd$, false, true);

RESET enable_hashagg;
RESET enable_sort;
RESET enable_incremental_sort;
RESET documentdb.defaultcursorfirstpagebatchsize;