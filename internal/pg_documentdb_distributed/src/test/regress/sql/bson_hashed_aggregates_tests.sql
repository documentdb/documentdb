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

SELECT cursorPage->'cursor.firstBatch' FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$push": "$$ROOT" } } } ], "cursor" : {  } }');

-- fails without enableAddToSetAggregationRewrite set to 'on'
SELECT cursorPage->'cursor.firstBatch' FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$addToSet": "$$ROOT" } } } ], "cursor" : {  } }');

-- Check if we are really are doing hash aggregations
EXPLAIN (COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT * FROM bson_aggregation_pipeline('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$push": "$$ROOT" } } } ], "cursor" : {  } }');
EXPLAIN (COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT * FROM bson_aggregation_pipeline('testdb', '{ "aggregate": "hash_aggTest", "pipeline": [ { "$group": { "_id": "$key", "items": { "$addToSet": "$$ROOT" } } } ], "cursor" : {  } }');

RESET enable_hashagg;
RESET enable_sort;
RESET enable_incremental_sort;
RESET documentdb.defaultcursorfirstpagebatchsize;