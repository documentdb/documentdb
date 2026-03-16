-- Tests for drop_database BSON signature: drop_database(bson)
-- This is the new signature used by the Gateway (RFC: Gateway-Extension Standardization)

SET search_path TO documentdb_api_catalog;
SET documentdb.next_collection_id TO 1200;
SET documentdb.next_collection_index_id TO 1200;

-- Setup: create a database with collections
SELECT documentdb_api.create_collection('drop_db_bson','coll1');
SELECT documentdb_api.insert_one('drop_db_bson','coll1','{"_id":"1", "a":1}');
SELECT documentdb_api.create_collection('drop_db_bson','coll2');

-- Test 1: drop database via BSON
SELECT documentdb_api.drop_database('{"dropDatabase": 1, "$db": "drop_db_bson"}'::documentdb_core.bson);
-- verify all collections gone
SELECT count(*) FROM documentdb_api_catalog.collections WHERE database_name = 'drop_db_bson';

-- Test 2: drop non-existent database via BSON
SELECT documentdb_api.drop_database('{"dropDatabase": 1, "$db": "no_such_db_bson"}'::documentdb_core.bson);

-- Test 3: drop with extra fields (lsid, writeConcern)
SELECT documentdb_api.create_collection('drop_db_bson2','coll1');
SELECT documentdb_api.drop_database('{"dropDatabase": 1, "$db": "drop_db_bson2", "lsid": {"id": "abc"}, "writeConcern": {"w": 1}}'::documentdb_core.bson);
SELECT count(*) FROM documentdb_api_catalog.collections WHERE database_name = 'drop_db_bson2';

-- Test 4: drop database with multiple collections
SELECT documentdb_api.create_collection('drop_db_bson3','coll_a');
SELECT documentdb_api.create_collection('drop_db_bson3','coll_b');
SELECT documentdb_api.create_collection('drop_db_bson3','coll_c');
SELECT documentdb_api.drop_database('{"dropDatabase": 1, "$db": "drop_db_bson3"}'::documentdb_core.bson);
SELECT count(*) FROM documentdb_api_catalog.collections WHERE database_name = 'drop_db_bson3';

-- Test 5: NULL BSON should error
SELECT documentdb_api.drop_database(NULL::documentdb_core.bson);
