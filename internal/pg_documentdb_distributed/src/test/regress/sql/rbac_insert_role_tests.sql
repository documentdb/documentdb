-- Tests for custom role operations with documentdb_api_insert_role
-- This file verifies that users inheriting from documentdb_api_insert_role can perform
-- insert operations when granted INSERT permissions on specific collections.

SET documentdb.next_collection_id TO 1984000;
SET documentdb.next_collection_index_id TO 1984000;
\set VERBOSITY TERSE

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SHOW documentdb.enableRbacCompliantSchemas;
-- Save the original user for switching back
SELECT current_user AS original_user \gset

-- =============================================================================
-- Setup: Create test collections and insert_test_user
-- =============================================================================

-- Create test collection (will get collection_id 1984001)
SELECT documentdb_api.create_collection('rbac_insert_test_db', 'test_collection');

-- Create second test collection (will get collection_id 1984002) - user will NOT have access
SELECT documentdb_api.create_collection('rbac_insert_test_db', 'restricted_collection');

-- Create insert test user
CREATE ROLE insert_test_user WITH LOGIN PASSWORD 'TestPass123!';

-- Grant collection RBAC role to test user
GRANT documentdb_api_insert_role TO insert_test_user;

-- Grant table permissions on test_collection (collection_id = 1984001)
-- When next_collection_id is set to X, the first collection gets ID X+1
-- insert_test_user: only INSERT
GRANT INSERT ON TABLE documentdb_data.documents_1984001 TO insert_test_user;

-- =============================================================================
-- Test: Insert operation with documentdb_api_insert_role role
-- =============================================================================

\c regression insert_test_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Insert should work
SELECT documentdb_api_v2.insert_one('rbac_insert_test_db', 'test_collection', '{"_id": 10, "name": "inserted_doc", "value": 1000}', NULL);

-- Insert with insert() function should work
SELECT documentdb_api_v2.insert('rbac_insert_test_db', '{"insert": "test_collection", "documents": [{"_id": 11, "name": "inserted_doc2"}]}', NULL, NULL);

-- =============================================================================
-- Test: Verify insert_test_user cannot access restricted_collection
-- =============================================================================

-- insert_test_user should NOT be able to insert on restricted_collection (no INSERT grant)
SELECT documentdb_api_v2.insert_one('rbac_insert_test_db', 'restricted_collection', '{"_id": 1, "name": "should_fail"}', NULL);

-- =============================================================================
-- Test: Verify insert_test_user cannot perform other operations
-- =============================================================================

-- insert_test_user should NOT be able to find (no SELECT grant and no documentdb_api_find_role role)
SELECT cursorpage FROM documentdb_api_v2.find_cursor_first_page('rbac_insert_test_db', '{"find": "test_collection", "filter": {}}', 0);

-- insert_test_user should NOT be able to update (no UPDATE grant and no documentdb_api_update_role role)
SELECT documentdb_api_v2.update('rbac_insert_test_db', '{"update": "test_collection", "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 0}}}]}', NULL, NULL);

-- insert_test_user should NOT be able to delete (no DELETE grant and no documentdb_api_remove_role role)
SELECT documentdb_api_v2.delete('rbac_insert_test_db', '{"delete": "test_collection", "deletes": [{"q": {"_id": 1}, "limit": 1}]}', NULL, NULL);

-- =============================================================================
-- Cleanup
-- =============================================================================
 
\c regression :original_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Drop test collections first (removes table privilege dependencies that block DROP ROLE)
SELECT documentdb_api.drop_collection('rbac_insert_test_db', 'test_collection');
SELECT documentdb_api.drop_collection('rbac_insert_test_db', 'restricted_collection');

-- Drop test role (required due to 100 user limit)
DROP ROLE IF EXISTS insert_test_user;
