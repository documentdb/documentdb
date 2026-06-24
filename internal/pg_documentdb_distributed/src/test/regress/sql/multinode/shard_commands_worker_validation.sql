-- Tests that shard/reshard/unshard validation errors are properly surfaced
-- when commands are issued from a worker node (non-coordinator).
-- The worker parses the request on the failure path to give a user-friendly error.
--
-- Uses \c to connect directly to the worker, which exercises
-- the !IsMetadataCoordinator() code path in sharding.c.

SET citus.next_shard_id TO 4400000;
SET documentdb.next_collection_id TO 44000;
SET documentdb.next_collection_index_id TO 44000;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

-- Connect to the worker node directly
\c - - - 58081

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

-- ============================================================================
-- shard_collection validation errors from worker
-- ============================================================================

-- Missing shardCollection field
SELECT documentdb_api.shard_collection('{ }');

-- Invalid shard key value
SELECT documentdb_api.shard_collection('{ "shardCollection": "workerdb.coll1", "key": { "_id": 1 } }');

-- Invalid unique option with hashed key
SELECT documentdb_api.shard_collection('{ "shardCollection": "workerdb.coll1", "key": { "_id": "hashed" }, "unique": 1 }');

-- Negative numInitialChunks
SELECT documentdb_api.shard_collection('{ "shardCollection": "workerdb.coll1", "key": { "_id": "hashed" }, "numInitialChunks": -1 }');

-- Invalid namespace (empty collection)
SELECT documentdb_api.shard_collection('{ "shardCollection": "workerdb.", "key": { "_id": "hashed" } }');

-- Invalid namespace (empty db)
SELECT documentdb_api.shard_collection('{ "shardCollection": ".coll1", "key": { "_id": "hashed" } }');

-- ============================================================================
-- reshard_collection validation errors from worker
-- ============================================================================

-- Missing reshardCollection field
SELECT documentdb_api.reshard_collection('{ }');

-- Invalid shard key value
SELECT documentdb_api.reshard_collection('{ "reshardCollection": "workerdb.coll1", "key": { "_id": 1 } }');

-- Invalid unique option with hashed key
SELECT documentdb_api.reshard_collection('{ "reshardCollection": "workerdb.coll1", "key": { "_id": "hashed" }, "unique": 1 }');

-- Negative numInitialChunks
SELECT documentdb_api.reshard_collection('{ "reshardCollection": "workerdb.coll1", "key": { "_id": "hashed" }, "numInitialChunks": -1 }');

-- ============================================================================
-- unshard_collection validation errors from worker
-- ============================================================================

-- Missing unshardCollection field
SELECT documentdb_api.unshard_collection('{ }');

-- Unsupported toShard option
SELECT documentdb_api.unshard_collection('{ "unshardCollection": "workerdb.coll1", "toShard": "shard2" }');

-- Switch back to coordinator
\c - - - 58070

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;
