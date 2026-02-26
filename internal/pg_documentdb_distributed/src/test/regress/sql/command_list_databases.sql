SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 6350000;
SET documentdb.next_collection_id TO 6350;
SET documentdb.next_collection_index_id TO 6350;
SET documentdb_core.bsonUseEJson TO true;
SET client_min_messages TO WARNING;

-- Clean up any existing test databases
SELECT documentdb_api.drop_database('list_db_test1');
SELECT documentdb_api.drop_database('list_db_test2');
SELECT documentdb_api.drop_database('list_db_test3');

-- Test 1: No matching databases exist
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": {"$regex": "^list_db_test"}}, "nameOnly": true}');

-- Test 2: Create one database, verify it shows up
SELECT documentdb_api.create_collection('list_db_test1', 'col1');
SELECT documentdb_api.insert_one('list_db_test1', 'col1', '{"a": 1}', NULL);
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": "list_db_test1"}, "nameOnly": true}');

-- Test 3: Create more databases, verify with regex filter
SELECT documentdb_api.create_collection('list_db_test2', 'col1');
SELECT documentdb_api.insert_one('list_db_test2', 'col1', '{"x": 100}', NULL);
SELECT documentdb_api.create_collection('list_db_test3', 'large_col');
SELECT documentdb_api.insert_one('list_db_test3', 'large_col', '{"id": 1}', NULL);
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": "list_db_test2"}, "nameOnly": true}');
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": "list_db_test3"}, "nameOnly": true}');

-- Test 4: Drop a collection, database should still exist
SELECT documentdb_api.create_collection('list_db_test2', 'col2');
SELECT documentdb_api.drop_collection('list_db_test2', 'col2');
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": "list_db_test2"}, "nameOnly": true}');

-- Test 5: Drop entire database, verify it's gone
SELECT documentdb_api.drop_database('list_db_test3');
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": "list_db_test3"}, "nameOnly": true}');

-- Test 6: Exact filter match returns only that database
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": "list_db_test1"}, "nameOnly": true}');

-- Cleanup
SELECT documentdb_api.drop_database('list_db_test1');
SELECT documentdb_api.drop_database('list_db_test2');
SELECT documentdb_api.drop_database('list_db_test3');

-- Verify cleanup: no matching databases remain
SELECT documentdb_api.list_databases('{"listDatabases": 1, "filter": {"name": {"$regex": "^list_db_test"}}, "nameOnly": true}');

SET client_min_messages TO DEFAULT;
