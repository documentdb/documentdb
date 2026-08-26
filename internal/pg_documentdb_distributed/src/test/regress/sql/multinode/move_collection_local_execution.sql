SET citus.next_shard_id TO 120000;
SET documentdb.next_collection_id TO 12000;
SET documentdb.next_collection_index_id TO 12000;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

-- Regression test for move_collection failing with
-- "cannot execute command because a local execution has accessed a placement in
-- the transaction" when the collection's single shard resides on the node that
-- runs move_collection (the coordinator) and the command is invoked directly,
-- i.e. WITHOUT wrapping it in "SET citus.enable_local_execution TO OFF". The
-- command must disable local execution internally so the call succeeds.

-- Force new collection shards onto the coordinator (group 0).
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', false)
FROM pg_dist_node WHERE groupid <> 0 AND noderole = 'primary';
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', true)
FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';

SELECT documentdb_api.create_collection('move_le', 'coll');
SELECT documentdb_api.insert_one('move_le', 'coll', '{"_id": 1, "v": "a"}');
SELECT documentdb_api.insert_one('move_le', 'coll', '{"_id": 2, "v": "b"}');

-- Confirm the shard landed on the coordinator (group 0).
SELECT pp.groupid AS shard_group
FROM documentdb_api_catalog.collections c
JOIN pg_dist_shard ps ON ps.logicalrelid = ('documentdb_data.documents_' || c.collection_id)::regclass
JOIN pg_dist_placement pp ON pp.shardid = ps.shardid AND pp.shardstate = 1
WHERE c.database_name = 'move_le' AND c.collection_name = 'coll';

-- Re-enable the worker as a valid move target.
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', true)
FROM pg_dist_node WHERE groupid = 1 AND noderole = 'primary';

-- Direct call (no SET citus.enable_local_execution TO OFF wrapper). Without the
-- fix this fails; with the fix it returns { "ok" : 1 }.
SELECT documentdb_api_distributed.move_collection('{ "moveCollection": "move_le.coll", "toShard": "shard_1" }');

-- The shard is now on the worker (group 1) and the data is intact.
SELECT pp.groupid AS shard_group
FROM documentdb_api_catalog.collections c
JOIN pg_dist_shard ps ON ps.logicalrelid = ('documentdb_data.documents_' || c.collection_id)::regclass
JOIN pg_dist_placement pp ON pp.shardid = ps.shardid AND pp.shardstate = 1
WHERE c.database_name = 'move_le' AND c.collection_name = 'coll';

SELECT object_id, document FROM documentdb_api.collection('move_le', 'coll')
WHERE document @@ '{ "_id": { "$lte": 5 } }' ORDER BY object_id;

-- moveCollection is not permitted inside a transaction block: it must run as the
-- sole statement of its own transaction. Invoking it inside BEGIN/COMMIT must be
-- rejected with OperationNotSupportedInTransaction (263), for direct SQL callers
-- as well as the gateway.
BEGIN;
SELECT documentdb_api_distributed.move_collection('{ "moveCollection": "move_le.coll", "toShard": "shard_1" }');
ROLLBACK;

-- Cleanup.
SELECT documentdb_api.drop_collection('move_le', 'coll');

-- Restore default shard placement eligibility (coordinator holds no shards).
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', false)
FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';
