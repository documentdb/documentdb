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

------------------------------------------------------------
-- Test: reindex via create with planner statistics enabled moves the
-- statistics dependency to the rebuilt index so the old index can be dropped
-- concurrently. Covers both unsharded and sharded collections, and shows the
-- statistics objects on the distributed table and on its shards.
------------------------------------------------------------
SET citus.override_table_visibility TO off;
SET documentdb.enablePerCollectionPlannerStatistics TO on;

-- Statistics objects per level, and how many of them depend on an index
PREPARE reindex_stats_deps(bigint) AS
SELECT CASE WHEN c.relname = 'documents_' || $1 THEN 'table' ELSE 'shard' END AS level,
       COUNT(*) AS stats_objects,
       COUNT(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM pg_depend d JOIN pg_class i ON i.oid = d.refobjid AND i.relkind = 'i'
           WHERE d.classid = 'pg_statistic_ext'::regclass AND d.objid = st.oid
             AND d.refclassid = 'pg_class'::regclass)) AS depends_on_index
FROM pg_statistic_ext st JOIN pg_class c ON c.oid = st.stxrelid
WHERE c.relnamespace = 'documentdb_data'::regnamespace
  AND (c.relname = 'documents_' || $1 OR c.relname LIKE 'documents_' || $1 || '\_%')
GROUP BY 1 ORDER BY 1;

-- The index the distributed table's statistics object depends on
PREPARE reindex_stats_index(bigint) AS
SELECT st.stxname, d.refobjid::regclass AS depends_on_index, d.deptype
FROM pg_statistic_ext st
JOIN pg_depend d ON d.classid = 'pg_statistic_ext'::regclass AND d.objid = st.oid AND d.refclassid = 'pg_class'::regclass
JOIN pg_class i ON i.oid = d.refobjid AND i.relkind = 'i'
WHERE st.stxrelid = ('documentdb_data.documents_' || $1)::regclass ORDER BY 1;

-- Remaining _ccold indexes per level
PREPARE reindex_ccold_count(bigint) AS
SELECT CASE WHEN t.relname = 'documents_' || $1 THEN 'table' ELSE 'shard' END AS level, COUNT(*) AS ccold_indexes
FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid
WHERE t.relnamespace = 'documentdb_data'::regnamespace
  AND (t.relname = 'documents_' || $1 OR t.relname LIKE 'documents_' || $1 || '\_%')
  AND i.relname LIKE '%\_ccold%'
GROUP BY 1 ORDER BY 1;

-- Unsharded collection
SELECT documentdb_api.create_collection('reindex_dist_db', 'reindex_with_stats');
SELECT COUNT(documentdb_api.insert_one('reindex_dist_db', 'reindex_with_stats', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "enableStats": true }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_dist_db',
  '{ "createIndexes": "reindex_with_stats", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);
SELECT collection_id AS stats_coll_id FROM documentdb_api_catalog.collections WHERE database_name = 'reindex_dist_db' AND collection_name = 'reindex_with_stats' \gset
EXECUTE reindex_stats_deps(:stats_coll_id);
EXECUTE reindex_stats_index(:stats_coll_id);

SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "index": { "name": "a_1", "reindex": true, "updateOptions": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;
EXECUTE reindex_ccold_count(:stats_coll_id);
EXECUTE reindex_stats_deps(:stats_coll_id);
EXECUTE reindex_stats_index(:stats_coll_id);

-- A _ccold index left behind can be dropped concurrently by hand
SET documentdb.skipIndexCleanupOnReindex TO true;
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "index": { "name": "a_1", "reindex": true, "updateOptions": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
RESET documentdb.skipIndexCleanupOnReindex;
EXECUTE reindex_ccold_count(:stats_coll_id);
SELECT 'documentdb_data.documents_rum_index_' || index_id || '_ccold' AS ccold_index_name
FROM documentdb_api_catalog.collection_indexes WHERE collection_id = :stats_coll_id AND (index_spec).index_name = 'a_1' \gset
DROP INDEX CONCURRENTLY :ccold_index_name;
EXECUTE reindex_ccold_count(:stats_coll_id);
EXECUTE reindex_stats_deps(:stats_coll_id);
EXECUTE reindex_stats_index(:stats_coll_id);

-- Dropping the rebuilt index removes the statistics objects on the table and its shards
CALL documentdb_api.drop_indexes('reindex_dist_db', '{ "dropIndexes": "reindex_with_stats", "index": "a_1" }');
EXECUTE reindex_stats_deps(:stats_coll_id);

-- Sharded collection
SELECT documentdb_api.create_collection('reindex_dist_db', 'reindex_with_stats_sharded');
SELECT COUNT(documentdb_api.insert_one('reindex_dist_db', 'reindex_with_stats_sharded', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 20) i;
SELECT documentdb_api.shard_collection('reindex_dist_db', 'reindex_with_stats_sharded', '{ "_id": "hashed" }', false);
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_with_stats_sharded', '{ "collMod": "reindex_with_stats_sharded", "enableStats": true }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_dist_db',
  '{ "createIndexes": "reindex_with_stats_sharded", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);
SELECT collection_id AS sharded_stats_coll_id FROM documentdb_api_catalog.collections WHERE database_name = 'reindex_dist_db' AND collection_name = 'reindex_with_stats_sharded' \gset
EXECUTE reindex_stats_deps(:sharded_stats_coll_id);
EXECUTE reindex_stats_index(:sharded_stats_coll_id);

SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_with_stats_sharded', '{ "collMod": "reindex_with_stats_sharded", "index": { "name": "a_1", "reindex": true, "updateOptions": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984300 AND index_id <= 1984400 ORDER BY index_id;
EXECUTE reindex_ccold_count(:sharded_stats_coll_id);
EXECUTE reindex_stats_deps(:sharded_stats_coll_id);
EXECUTE reindex_stats_index(:sharded_stats_coll_id);

SET documentdb.skipIndexCleanupOnReindex TO true;
SELECT documentdb_api.coll_mod('reindex_dist_db', 'reindex_with_stats_sharded', '{ "collMod": "reindex_with_stats_sharded", "index": { "name": "a_1", "reindex": true, "updateOptions": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
RESET documentdb.skipIndexCleanupOnReindex;
EXECUTE reindex_ccold_count(:sharded_stats_coll_id);
SELECT 'documentdb_data.documents_rum_index_' || index_id || '_ccold' AS ccold_index_name
FROM documentdb_api_catalog.collection_indexes WHERE collection_id = :sharded_stats_coll_id AND (index_spec).index_name = 'a_1' \gset
DROP INDEX CONCURRENTLY :ccold_index_name;
EXECUTE reindex_ccold_count(:sharded_stats_coll_id);
EXECUTE reindex_stats_deps(:sharded_stats_coll_id);
EXECUTE reindex_stats_index(:sharded_stats_coll_id);

CALL documentdb_api.drop_indexes('reindex_dist_db', '{ "dropIndexes": "reindex_with_stats_sharded", "index": "a_1" }');
EXECUTE reindex_stats_deps(:sharded_stats_coll_id);

DEALLOCATE reindex_stats_deps;
DEALLOCATE reindex_stats_index;
DEALLOCATE reindex_ccold_count;
RESET documentdb.enablePerCollectionPlannerStatistics;
RESET citus.override_table_visibility;
