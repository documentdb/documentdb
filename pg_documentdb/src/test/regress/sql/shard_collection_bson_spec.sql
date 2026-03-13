SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core;
SET documentdb.next_collection_id TO 1983200;
SET documentdb.next_collection_index_id TO 1983200;

-- Test 1: Missing key field for shard_collection — not covered in distributed suite
SELECT documentdb_api.shard_collection('{"shardCollection": "shard_bson_db.test_coll"}'::documentdb_core.bson);

-- Test 2: Extra fields (lsid, writeConcern, $db) are silently ignored — RFC core requirement
-- This directly validates that the Gateway passing full BSON does not break the Extension parser
SELECT documentdb_api.insert_one('shard_bson_db', 'test_coll', '{"_id": "1", "a": 1}');
SELECT documentdb_api.shard_collection('{"shardCollection": "shard_bson_db.test_coll", "key": {"a": "hashed"}, "lsid": {"id": "abc-123"}, "writeConcern": {"w": 1}, "$db": "admin"}'::documentdb_core.bson);

-- Test 3: Missing key field for reshard_collection — not covered in distributed suite
SELECT documentdb_api.reshard_collection('{"reshardCollection": "shard_bson_db.test_coll"}'::documentdb_core.bson);

-- Cleanup
SELECT documentdb_api.drop_database('shard_bson_db');
