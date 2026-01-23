SET citus.next_shard_id TO 11000;
SET documentdb.next_collection_id TO 110;
SET documentdb.next_collection_index_id TO 110;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

SELECT documentdb_api.create_collection('testdb', 'test_collection_node_1');

SELECT documentdb_api.insert_one('testdb', 'test_collection_node_1', '{"_id": 1, "test": "value1"}');
SELECT documentdb_api.insert_one('testdb', 'test_collection_node_1', '{"_id": 2, "test": "value2"}');
SELECT documentdb_api.insert_one('testdb', 'test_collection_node_1', '{"_id": 3, "test": "value3"}');
SELECT documentdb_api.insert_one('testdb', 'test_collection_node_1', '{"_id": 4, "test": "value4"}');
SELECT documentdb_api.insert_one('testdb', 'test_collection_node_1', '{"_id": 5, "test": "value5"}');

-- Try to place it on a node that doesn't exist
SELECT documentdb_distributed_test_helpers.place_collection_on_node('testdb', 'test_collection_node_1', 10);

-- Place it on node 1
SELECT documentdb_distributed_test_helpers.place_collection_on_node('testdb', 'test_collection_node_1', 1);

SELECT object_id, document FROM documentdb_api.collection('testdb', 'test_collection_node_1') WHERE document @@ '{ "_id": { "$lte" : 5 }}' ORDER BY object_id;

EXPLAIN (VERBOSE ON, COSTS OFF, TIMING OFF) SELECT object_id, document FROM documentdb_api.collection('testdb', 'test_collection_node_1') WHERE document @@ '{ "_id": { "$lte" : 5 }}' ORDER BY object_id;
