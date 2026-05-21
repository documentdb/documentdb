-- Test schema validation with update multi:true (update all) in multinode environment
--
-- Schema validation is enforced for BOTH sharded and unsharded collections
-- in multinode environments via the update_worker function.

SET citus.next_shard_id TO 19000;
SET documentdb.next_collection_id TO 1900;
SET documentdb.next_collection_index_id TO 1900;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

-- Note: documentdb.enableSchemaValidation and documentdb.enableBypassDocumentValidation
-- are set in regression_opts.conf to ensure GUC values propagate to worker nodes

---------------------------------------------
-- Test 1: Sharded collection - multi update with schema validation
-- (Sharded collections enforce validation via CHECK constraint)
---------------------------------------------

-- Create collection with schema validator
SELECT documentdb_api.create_collection_view('sv_multinode', '{ "create": "col_sharded", "validator": {"$jsonSchema": {"bsonType": "object", "properties": {"value": {"bsonType": "int"}}}}, "validationLevel": "strict", "validationAction": "error"}');

-- Insert test data
SELECT documentdb_api.insert('sv_multinode', '{"insert":"col_sharded", "documents":[{"_id":"1", "value":10}, {"_id":"2", "value":20}, {"_id":"3", "value":30}]}');

-- Shard the collection by _id
SELECT documentdb_api.shard_collection('sv_multinode', 'col_sharded', '{ "_id": "hashed" }', false);

-- Multi update on sharded collection with valid values (should succeed)
SELECT documentdb_api.update('sv_multinode', '{"update":"col_sharded", "updates":[{"q":{},"u":{"$inc":{"value":1}}, "multi":true}]}');
SELECT shard_key_value, object_id, document FROM documentdb_api.collection('sv_multinode','col_sharded') ORDER BY object_id;

-- Multi update that violates schema on sharded collection (should fail with validation error)
SELECT documentdb_api.update('sv_multinode', '{"update":"col_sharded", "updates":[{"q":{},"u":{"$set":{"value":"invalid"}}, "multi":true}]}');

-- Verify no documents were modified
SELECT shard_key_value, object_id, document FROM documentdb_api.collection('sv_multinode','col_sharded') ORDER BY object_id;

-- Multi update with bypassDocumentValidation on sharded collection (should succeed)
SELECT documentdb_api.update('sv_multinode', '{"update":"col_sharded", "updates":[{"q":{},"u":{"$set":{"value":"bypassed"}}, "multi":true}], "bypassDocumentValidation": true}');
SELECT shard_key_value, object_id, document FROM documentdb_api.collection('sv_multinode','col_sharded') ORDER BY object_id;

---------------------------------------------
-- Test 2: Unsharded collection on WORKER node - multi update with schema validation
-- (Tests the remote worker path via update_worker)
---------------------------------------------

-- Create unsharded collection with schema validator
SELECT documentdb_api.create_collection_view('sv_multinode', '{ "create": "col_unsharded", "validator": {"$jsonSchema": {"bsonType": "object", "properties": {"value": {"bsonType": "int"}}}}, "validationLevel": "strict", "validationAction": "error"}');

-- Insert test data
SELECT documentdb_api.insert('sv_multinode', '{"insert":"col_unsharded", "documents":[{"_id":"1", "value":10}, {"_id":"2", "value":20}, {"_id":"3", "value":30}]}');

-- Move collection to worker node (node 1) to test remote execution path
SELECT documentdb_distributed_test_helpers.place_collection_on_node('sv_multinode', 'col_unsharded', 1);

-- Verify collection is unsharded (shard_key is NULL)
SELECT collection_id, shard_key IS NULL as is_unsharded FROM documentdb_api_catalog.collections WHERE collection_name = 'col_unsharded';

-- Multi update on unsharded collection with valid values (should succeed)
SELECT documentdb_api.update('sv_multinode', '{"update":"col_unsharded", "updates":[{"q":{},"u":{"$inc":{"value":1}}, "multi":true}]}');
SELECT shard_key_value, object_id, document FROM documentdb_api.collection('sv_multinode','col_unsharded') ORDER BY object_id;

-- Multi update that violates schema on unsharded collection (should fail with validation error)
SELECT documentdb_api.update('sv_multinode', '{"update":"col_unsharded", "updates":[{"q":{},"u":{"$set":{"value":"invalid"}}, "multi":true}]}');

-- Verify no documents were modified
SELECT shard_key_value, object_id, document FROM documentdb_api.collection('sv_multinode','col_unsharded') ORDER BY object_id;

---------------------------------------------
-- Cleanup
---------------------------------------------
SELECT documentdb_api.drop_collection('sv_multinode', 'col_sharded');
SELECT documentdb_api.drop_collection('sv_multinode', 'col_unsharded');
