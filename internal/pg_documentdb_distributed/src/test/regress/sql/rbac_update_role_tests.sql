-- Tests for custom role operations with documentdb_api_update_role
-- This file verifies that users inheriting from documentdb_api_update_role can perform
-- update operations when granted UPDATE and SELECT permissions on specific collections.

SET documentdb.next_collection_id TO 1984100;
SET documentdb.next_collection_index_id TO 1984100;
\set VERBOSITY TERSE

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SHOW documentdb.enableRbacCompliantSchemas;
-- Save the original user for switching back
SELECT current_user AS original_user \gset

-- =============================================================================
-- Setup: Create test collections and update_test_users
-- =============================================================================

-- Create test collection (will get collection_id 1984101)
SELECT documentdb_api.create_collection('rbac_update_test_db', 'test_collection');

-- Create second test collection (will get collection_id 1984102) - user will NOT have access
SELECT documentdb_api.create_collection('rbac_update_test_db', 'restricted_collection');

-- Insert test data for update tests
SELECT documentdb_api.insert_one('rbac_update_test_db', 'test_collection', '{"_id": 1, "name": "doc1", "value": 100}');
SELECT documentdb_api.insert_one('rbac_update_test_db', 'restricted_collection', '{"_id": 1, "name": "restricted_doc"}');

-- Create update test users:
-- update_test_user_a: has UPDATE and SELECT
-- update_test_user_b: has UPDATE only
-- update_test_user_c: has UPDATE only
CREATE ROLE update_test_user_a WITH LOGIN PASSWORD 'TestPass123!';
CREATE ROLE update_test_user_b WITH LOGIN PASSWORD 'TestPass123!';
CREATE ROLE update_test_user_c WITH LOGIN PASSWORD 'TestPass123!';

-- Grant collection RBAC role to test users
GRANT documentdb_api_update_role TO update_test_user_a;
GRANT documentdb_api_update_role TO update_test_user_b;
GRANT documentdb_api_update_role TO update_test_user_c;

-- Grant table permissions on test_collection (collection_id = 1984101)
-- When next_collection_id is set to X, the first collection gets ID X+1
-- update_test_user_a: UPDATE and SELECT
GRANT UPDATE, SELECT ON TABLE documentdb_data.documents_1984101 TO update_test_user_a;
-- update_test_user_b: UPDATE only
GRANT UPDATE ON TABLE documentdb_data.documents_1984101 TO update_test_user_b;
-- update_test_user_c: UPDATE only
GRANT UPDATE ON TABLE documentdb_data.documents_1984101 TO update_test_user_c;

-- =============================================================================
-- Test: Update operation with UPDATE and SELECT permissions
-- A user with both UPDATE and SELECT can perform filtered updates.
-- =============================================================================

\c regression update_test_user_a
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Update with filter should work (has SELECT for WHERE clause)
SELECT documentdb_api_v2.update('rbac_update_test_db', '{"update": "test_collection", "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 999}}}]}', NULL, NULL);

-- =============================================================================
-- Test: Update operation with UPDATE only (no SELECT)
-- A user with only UPDATE cannot perform filtered updates because SELECT is
-- needed for the WHERE clause.
-- =============================================================================

\c regression update_test_user_b
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Update with filter should FAIL (no SELECT for WHERE clause)
SELECT documentdb_api_v2.update('rbac_update_test_db', '{"update": "test_collection", "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 888}}}]}', NULL, NULL);

-- =============================================================================
-- Test: Verify update_test_user_a cannot access restricted_collection
-- =============================================================================

\c regression update_test_user_a
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- update_test_user_a should NOT be able to update on restricted_collection (no UPDATE grant)
SELECT documentdb_api_v2.update('rbac_update_test_db', '{"update": "restricted_collection", "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 0}}}]}', NULL, NULL);

-- =============================================================================
-- Test: Verify update_test_user_a cannot perform other operations
-- =============================================================================

\c regression update_test_user_a
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- update_test_user_a should NOT be able to insert (no INSERT grant and no documentdb_api_insert_role role)
SELECT documentdb_api_v2.insert_one('rbac_update_test_db', 'test_collection', '{"_id": 101, "name": "should_fail"}', NULL);

-- update_test_user_a should NOT be able to delete (no DELETE grant and no documentdb_api_remove_role role)
SELECT documentdb_api_v2.delete('rbac_update_test_db', '{"delete": "test_collection", "deletes": [{"q": {"_id": 1}, "limit": 1}]}', NULL, NULL);

-- =============================================================================
-- Cleanup
-- =============================================================================
 
\c regression :original_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Drop test collections first (removes table privilege dependencies that block DROP ROLE)
SELECT documentdb_api.drop_collection('rbac_update_test_db', 'test_collection');
SELECT documentdb_api.drop_collection('rbac_update_test_db', 'restricted_collection');

-- Drop test roles (required due to 100 user limit)
DROP ROLE IF EXISTS update_test_user_a;
DROP ROLE IF EXISTS update_test_user_b;
DROP ROLE IF EXISTS update_test_user_c;
