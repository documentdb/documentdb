SET search_path TO documentdb_api_catalog;
SET documentdb.next_collection_id TO 2000;
SET documentdb.next_collection_index_id TO 2000;

-- TEST authorization get_required_privileges function for FIND command
--   Test file to test the function:
--     documentdb_api_internal.get_required_privileges()
--   This test specifically validates privilege extraction for the 'find' MongoDB command

-- Test 1: Basic find command
SELECT documentdb_api_internal.get_required_privileges('{"find": "authorization_test", "$db": "db"}');

-- Test 2: Find command with filter
SELECT documentdb_api_internal.get_required_privileges('{"find": "authorization_test", "filter": {"name": "test"}, "$db": "db"}');

-- Test 3: Find command with projection and sort
SELECT documentdb_api_internal.get_required_privileges('{"find": "authorization_test", "filter": {"name": "test"}, "projection": {"name": 1}, "sort": {"name": 1}, "$db": "db"}');

-- Test 4: Find command on different collection
SELECT documentdb_api_internal.get_required_privileges('{"find": "other_collection", "$db": "db"}');

-- Test 5: Find command on different database
SELECT documentdb_api_internal.get_required_privileges('{"find": "test_collection", "$db": "other_db"}');

-- Test 6: Error case - missing $db field
SELECT documentdb_api_internal.get_required_privileges('{"find": "authorization_test"}');

-- Test 7: Error case - invalid find field type (not a string)
SELECT documentdb_api_internal.get_required_privileges('{"find": 123, "$db": "db"}');

-- Test 8: Error case - find field is a number
SELECT documentdb_api_internal.get_required_privileges('{"find": {"$numberInt": "5"}, "$db": "db"}');

-- Test 9: Find with special characters in collection name
SELECT documentdb_api_internal.get_required_privileges('{"find": "my.collection.name", "$db": "db"}');

-- Test 10: Find with empty collection name
SELECT documentdb_api_internal.get_required_privileges('{"find": "", "$db": "db"}');

-- Test 11: Find with very long collection name (near MAX_COLLECTION_NAME_LEN)
SELECT documentdb_api_internal.get_required_privileges(('{"find": "' || repeat('a', 250) || '", "$db": "db"}')::documentdb_core.bson);

-- Test 12: Find with very long database name (near MAX_DATABASE_NAME_LEN)
SELECT documentdb_api_internal.get_required_privileges(('{"find": "test_collection", "$db": "' || repeat('d', 60) || '"}')::documentdb_core.bson);

-- Test 13: Error case - NULL command
SELECT documentdb_api_internal.get_required_privileges(NULL);

-- Test 14: Error case - empty BSON document
SELECT documentdb_api_internal.get_required_privileges('{}');

-- Test 15: Error case - $db field is not a string
SELECT documentdb_api_internal.get_required_privileges('{"find": "test_collection", "$db": 123}');

-- Test 16: Error case - $db field is null
SELECT documentdb_api_internal.get_required_privileges('{"find": "test_collection", "$db": null}');
