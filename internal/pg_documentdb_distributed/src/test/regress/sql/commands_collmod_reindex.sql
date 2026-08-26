SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 198430000;
SET documentdb.next_collection_id TO 1984300;
SET documentdb.next_collection_index_id TO 1984300;

-- Delete all old create index requests from other tests
DELETE from documentdb_api_catalog.documentdb_index_queue;

SET documentdb.enableUniqueReindex TO true;

------------------------------------------------------------
-- Setup: Create collection with data and unique index
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_dist_db', 'reindex_unique_coll');
SELECT COUNT(documentdb_api.insert_one('reindex_dist_db', 'reindex_unique_coll', FORMAT('{"_id": %s, "a": %s, "b": %s}', i, i, i)::documentdb_core.bson)) FROM generate_series(1, 20) i;

-- Create an ordered unique index
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_dist_db',
  '{ "createIndexes": "reindex_unique_coll", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }', true);

-- Create a non-unique index for comparison
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_dist_db',
  '{ "createIndexes": "reindex_unique_coll", "indexes": [ { "key": { "b": 1 }, "name": "b_1" } ] }', true);

-- Verify indexes before reindex
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('reindex_dist_db', '{ "listIndexes": "reindex_unique_coll" }');

------------------------------------------------------------
-- Error: reindex of unique index with feature disabled
------------------------------------------------------------
-- Error: reindex must be true
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": false } }');

------------------------------------------------------------
-- Error: index not found
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "nonexistent_idx", "reindex": true } }');

------------------------------------------------------------
-- Error: reindex of unique index with feature disabled
------------------------------------------------------------
SET documentdb.enableUniqueReindex TO false;
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": true } }');
SET documentdb.enableUniqueReindex TO true;

------------------------------------------------------------
-- Error: reindex of unordered unique index is not supported
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_dist_db', 'reindex_unordered_coll');
SELECT documentdb_api.insert_one('reindex_dist_db', 'reindex_unordered_coll', '{"_id": 1, "a": 1}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_dist_db',
  '{ "createIndexes": "reindex_unordered_coll", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unordered", "unique": true } ] }', true);
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unordered_coll', '{ "collMod": "reindex_unordered_coll", "index": { "name": "a_1_unordered", "reindex": true } }');

------------------------------------------------------------
-- Reindex unique index on unsharded collection via collMod
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": true } }');

-- Verify the reindex request is in the queue
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;

-- Process the reindex queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the queue is empty
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;

-- Verify indexes still valid
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('reindex_dist_db', '{ "listIndexes": "reindex_unique_coll" }');

-- Verify uniqueness constraint still works
SELECT documentdb_api.insert_one('reindex_dist_db', 'reindex_unique_coll', '{"_id": 100, "a": 1}');

-- Verify data is intact
SELECT document FROM bson_aggregation_find('reindex_dist_db', '{ "find": "reindex_unique_coll", "filter": { "a": 5 } }');

------------------------------------------------------------
-- Shard the collection and test reindex on sharded unique index
------------------------------------------------------------
SELECT documentdb_api.shard_collection('{ "shardCollection": "reindex_dist_db.reindex_unique_coll", "key": { "_id": "hashed" }, "numInitialChunks": 3 }');

-- Reindex the unique index on the sharded collection
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;

-- Verify uniqueness still works after sharded reindex
SELECT documentdb_api.insert_one('reindex_dist_db', 'reindex_unique_coll', '{"_id": 101, "a": 2}');

-- Verify data is still accessible
SELECT document FROM bson_aggregation_find('reindex_dist_db', '{ "find": "reindex_unique_coll", "filter": { "a": 10 } }');

-- Verify indexes
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('reindex_dist_db', '{ "listIndexes": "reindex_unique_coll" }');

------------------------------------------------------------
-- Reindex the non-unique index on the sharded collection
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "b_1", "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;

------------------------------------------------------------
-- Reindex _id_ index on sharded collection via keyPattern
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "keyPattern": { "_id": 1 }, "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;

-- Verify data is still accessible after _id_ reindex
SELECT document FROM bson_aggregation_find('reindex_dist_db', '{ "find": "reindex_unique_coll", "filter": { "_id": 10 } }');

------------------------------------------------------------
-- Test: Reindex unique compound index on sharded collection
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_dist_db', 'reindex_compound_sharded');
SELECT COUNT(documentdb_api.insert_one('reindex_dist_db', 'reindex_compound_sharded', FORMAT('{"_id": %s, "x": %s, "y": %s}', i, i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_dist_db',
  '{ "createIndexes": "reindex_compound_sharded", "indexes": [ { "key": { "x": 1, "y": 1 }, "name": "xy_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }', true);

-- Shard the collection
SELECT documentdb_api.shard_collection('{ "shardCollection": "reindex_dist_db.reindex_compound_sharded", "key": { "_id": "hashed" }, "numInitialChunks": 3 }');

-- Reindex compound unique index via collMod
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_compound_sharded', '{ "collMod": "reindex_compound_sharded", "index": { "name": "xy_unique", "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;

-- Verify uniqueness still works on compound index after sharded reindex
SELECT documentdb_api.insert_one('reindex_dist_db', 'reindex_compound_sharded', '{"_id": 100, "x": 1, "y": 1}');

-- Verify indexes
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('reindex_dist_db', '{ "listIndexes": "reindex_compound_sharded" }');

------------------------------------------------------------
-- Test: skipIndexCleanupOnReindex leaves old index behind
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_dist_db', 'reindex_skip_cleanup');
SELECT COUNT(documentdb_api.insert_one('reindex_dist_db', 'reindex_skip_cleanup', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_dist_db',
  '{ "createIndexes": "reindex_skip_cleanup", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }', true);

-- Show table state before reindex
SELECT collection_id as skip_cleanup_collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'reindex_dist_db' AND collection_name = 'reindex_skip_cleanup' \gset
\d documentdb_data.documents_:skip_cleanup_collection_id

-- Set the GUC to skip cleanup of old index after reindex
SET documentdb.skipIndexCleanupOnReindex TO true;

-- Reindex the unique index
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_skip_cleanup', '{ "collMod": "reindex_skip_cleanup", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;

-- The old index (_ccold) should still be present on the table
\d documentdb_data.documents_:skip_cleanup_collection_id

RESET documentdb.skipIndexCleanupOnReindex;
