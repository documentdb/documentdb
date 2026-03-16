-- Tests for drop_collection BSON signature: drop_collection(bson, uuid, bool)
-- This is the new signature used by the Gateway (RFC: Gateway-Extension Standardization)

SET search_path TO documentdb_api_catalog;
SET documentdb.next_collection_id TO 1700;
SET documentdb.next_collection_index_id TO 1700;

-- Setup: create a collection to drop
SELECT documentdb_api.create_collection('drop_bson_db','test_coll');

-- Test 1: drop existing collection via BSON
SELECT documentdb_api.drop_collection('{"drop": "test_coll", "$db": "drop_bson_db"}'::documentdb_core.bson);

-- Test 2: drop non-existent collection via BSON returns false
SELECT documentdb_api.drop_collection('{"drop": "no_such_coll", "$db": "drop_bson_db"}'::documentdb_core.bson);

-- Test 3: drop with NULL BSON returns false
SELECT documentdb_api.drop_collection(NULL::documentdb_core.bson);

-- Test 4: drop with missing $db field errors
SELECT documentdb_api.drop_collection('{"drop": "test_coll"}'::documentdb_core.bson);

-- Test 5: drop with missing drop field errors
SELECT documentdb_api.drop_collection('{"$db": "drop_bson_db"}'::documentdb_core.bson);

-- Test 6: BSON with extra fields (lsid, writeConcern) still works — these are ignored
SELECT documentdb_api.create_collection('drop_bson_db','test_extra_fields');
SELECT documentdb_api.drop_collection('{"drop": "test_extra_fields", "$db": "drop_bson_db", "lsid": {"id": "abc"}, "writeConcern": {"w": 1}}'::documentdb_core.bson);

-- Test 7: drop via BSON with UUID mismatch
SELECT documentdb_api.create_collection('drop_bson_db','test_uuid1');
SELECT documentdb_api.create_collection('drop_bson_db','test_uuid2');
SELECT collection_uuid::text AS wrong_uuid FROM documentdb_api_catalog.collections WHERE database_name = 'drop_bson_db' AND collection_name = 'test_uuid2' \gset
SELECT collection_uuid::text AS correct_uuid FROM documentdb_api_catalog.collections WHERE database_name = 'drop_bson_db' AND collection_name = 'test_uuid1' \gset

-- UUID mismatch should error
SELECT documentdb_api.drop_collection('{"drop": "test_uuid1", "$db": "drop_bson_db"}'::documentdb_core.bson, :'wrong_uuid'::uuid);

-- Correct UUID should succeed
SELECT documentdb_api.drop_collection('{"drop": "test_uuid1", "$db": "drop_bson_db"}'::documentdb_core.bson, :'correct_uuid'::uuid);

-- Test 8: drop collection that has data (insert then drop)
SELECT documentdb_api.create_collection('drop_bson_db','test_with_data');
SELECT documentdb_api.insert_one('drop_bson_db','test_with_data','{"_id":"1", "a":1}');
SELECT count(*) FROM documentdb_api.collection('drop_bson_db','test_with_data');
SELECT documentdb_api.drop_collection('{"drop": "test_with_data", "$db": "drop_bson_db"}'::documentdb_core.bson);
-- verify collection is gone
SELECT count(*) FROM documentdb_api.collection('drop_bson_db','test_with_data');

-- Test 9: recreate collection after BSON drop (same name reuse)
SELECT documentdb_api.create_collection('drop_bson_db','test_recreate');
SELECT documentdb_api.drop_collection('{"drop": "test_recreate", "$db": "drop_bson_db"}'::documentdb_core.bson);
SELECT documentdb_api.create_collection('drop_bson_db','test_recreate');
SELECT count(*) FROM documentdb_api.collection('drop_bson_db','test_recreate');
SELECT documentdb_api.drop_collection('{"drop": "test_recreate", "$db": "drop_bson_db"}'::documentdb_core.bson);

-- Test 10: drop in read-only transaction should error
SET default_transaction_read_only = on;
SELECT documentdb_api.drop_collection('{"drop": "no_matter", "$db": "drop_bson_db"}'::documentdb_core.bson);
SET default_transaction_read_only = off;

-- Cleanup
SELECT documentdb_api.drop_collection('drop_bson_db','test_uuid2');
SELECT documentdb_api.drop_database('drop_bson_db');
