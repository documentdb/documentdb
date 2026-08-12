-- Empty and non-empty $in updateMany/deleteMany on a REMOTE UNSHARDED collection.
-- The collection is placed on a worker node so the modifying update executes
-- against a remote shard placement (the remote unsharded update path). Both the
-- empty and non-empty $in filters must route cleanly and return a clean result.
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;
SET citus.next_shard_id TO 4500000;
SET documentdb.next_collection_id TO 45000;
SET documentdb.next_collection_index_id TO 45000;

-- create an unsharded collection with a single row (a = 5)
SELECT documentdb_api.create_collection('remote_update_db', 'remote_updateme');
SELECT documentdb_api.insert_one('remote_update_db', 'remote_updateme', '{"a":5, "_id":50, "b":5, "c":"abc"}');

-- move the (unsharded) collection to a worker node to force the remote path
CALL documentdb_distributed_test_helpers.place_collection_on_node('remote_update_db', 'remote_updateme', 1);

-- verify the collection is unsharded (shard_key is NULL)
SELECT shard_key IS NULL AS is_unsharded FROM documentdb_api_catalog.collections WHERE database_name = 'remote_update_db' AND collection_name = 'remote_updateme';

-- updateMany, non-empty $in that matches: number
SELECT documentdb_api.update('remote_update_db', '{"update":"remote_updateme", "updates":[{"q":{"a":5, "b":{"$in":[5]}},"u":{"$set":{"u1":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: string
SELECT documentdb_api.update('remote_update_db', '{"update":"remote_updateme", "updates":[{"q":{"a":5, "c":{"$in":["abc"]}},"u":{"$set":{"u2":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: mixed types (number and string)
SELECT documentdb_api.update('remote_update_db', '{"update":"remote_updateme", "updates":[{"q":{"a":5, "b":{"$in":[5,"foo"]}},"u":{"$set":{"u3":1}},"multi":true}]}');
-- updateMany, empty $in matches nothing and must still route cleanly (no zero-shard error)
SELECT documentdb_api.update('remote_update_db', '{"update":"remote_updateme", "updates":[{"q":{"a":5, "c":{"$in":[]}},"u":{"$set":{"u4":1}},"multi":true}]}');
-- deleteMany, empty $in matches nothing and must still route cleanly
SELECT documentdb_api.delete('remote_update_db', '{"delete":"remote_updateme", "deletes":[{"q":{"a":5, "c":{"$in":[]}},"limit":0}]}');
-- deleteMany, non-empty $in removes the inserted row
SELECT documentdb_api.delete('remote_update_db', '{"delete":"remote_updateme", "deletes":[{"q":{"a":5, "c":{"$in":["abc"]}},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('remote_update_db', 'remote_updateme') WHERE document @@ '{"a":5}';

-- cleanup
SELECT documentdb_api.drop_collection('remote_update_db', 'remote_updateme');

-- ===========================================================================
-- Sharded collection variant, hash-sharded on {"a"} so its shards are spread
-- across workers. Both non-empty and empty $in filters alongside the shard key
-- must route to the shard and return a clean result. The empty $in with a shard
-- key filter is the routing regression this test covers.
-- ===========================================================================
SELECT documentdb_api.create_collection('remote_update_db', 'sharded_updateme');
SELECT documentdb_api.shard_collection('remote_update_db', 'sharded_updateme', '{"a":"hashed"}', false);
SELECT documentdb_api.insert_one('remote_update_db', 'sharded_updateme', '{"a":5, "_id":50, "b":5, "c":"abc"}');

-- updateMany, non-empty $in that matches: number
SELECT documentdb_api.update('remote_update_db', '{"update":"sharded_updateme", "updates":[{"q":{"a":5, "b":{"$in":[5]}},"u":{"$set":{"u1":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: string
SELECT documentdb_api.update('remote_update_db', '{"update":"sharded_updateme", "updates":[{"q":{"a":5, "c":{"$in":["abc"]}},"u":{"$set":{"u2":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: mixed types (number and string)
SELECT documentdb_api.update('remote_update_db', '{"update":"sharded_updateme", "updates":[{"q":{"a":5, "b":{"$in":[5,"foo"]}},"u":{"$set":{"u3":1}},"multi":true}]}');
-- updateMany, empty $in with the shard key filter (the routing regression case) must route cleanly
SELECT documentdb_api.update('remote_update_db', '{"update":"sharded_updateme", "updates":[{"q":{"a":5, "c":{"$in":[]}},"u":{"$set":{"u4":1}},"multi":true}]}');
-- deleteMany, empty $in with the shard key filter must still route cleanly
SELECT documentdb_api.delete('remote_update_db', '{"delete":"sharded_updateme", "deletes":[{"q":{"a":5, "c":{"$in":[]}},"limit":0}]}');
-- deleteMany, non-empty $in removes the inserted row
SELECT documentdb_api.delete('remote_update_db', '{"delete":"sharded_updateme", "deletes":[{"q":{"a":5, "c":{"$in":["abc"]}},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('remote_update_db', 'sharded_updateme') WHERE document @@ '{"a":5}';

-- cleanup
SELECT documentdb_api.drop_collection('remote_update_db', 'sharded_updateme');
