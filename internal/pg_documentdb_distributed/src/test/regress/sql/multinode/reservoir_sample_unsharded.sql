SET citus.next_shard_id TO 71000;
SET documentdb.next_collection_id TO 7100;
SET documentdb.next_collection_index_id TO 7100;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

-- Create unsharded collection and insert data
SELECT documentdb_api.create_collection('rsampledb', 'sample_node1');

SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 1, "category": "A", "value": 10}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 2, "category": "A", "value": 20}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 3, "category": "B", "value": 30}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 4, "category": "B", "value": 40}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 5, "category": "A", "value": 50}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 6, "category": "A", "value": 60}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 7, "category": "B", "value": 70}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 8, "category": "B", "value": 80}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 9, "category": "A", "value": 90}');
SELECT documentdb_api.insert_one('rsampledb', 'sample_node1', '{"_id": 10, "category": "A", "value": 100}');

-- Place collection on the worker node and force remote execution
SELECT documentdb_distributed_test_helpers.place_collection_on_node('rsampledb', 'sample_node1', 1);
SET citus.enable_local_execution TO off;

-- ============================================================
-- Multinode unsharded: reservoir sampling runs on the worker
-- ============================================================

-- $match + $sample: sample all 10 rows (deterministic output)
SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "sample_node1", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 10 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- $match narrowing + $sample: filter to 6 rows (category=A), sample all 6
SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "sample_node1", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 6 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- $sample size larger than collection: returns all 10 rows
SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "sample_node1", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 100 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- $match + $sample + $sort: verify ordering works
SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "sample_node1", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 10 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- ============================================================
-- natts = 0: when the outer query does not reference the document column,
-- the custom scan target list is NIL and the slot has 0 attributes.
-- This verifies ExecForceStoreHeapTuple handles natts=0 correctly.
-- ============================================================

-- $count stage produces a count without referencing document data
SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "sample_node1", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 10 } }, { "$count": "total" } ] }');

RESET citus.enable_local_execution;
