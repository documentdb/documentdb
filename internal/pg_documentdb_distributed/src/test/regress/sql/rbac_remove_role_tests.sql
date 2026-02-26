-- Tests for custom role operations with documentdb_api_remove_role
-- This file verifies that users inheriting from documentdb_api_remove_role can perform
-- delete operations when granted DELETE, UPDATE, and SELECT permissions on specific collections.

SET documentdb.next_collection_id TO 1984200;
SET documentdb.next_collection_index_id TO 1984200;
\set VERBOSITY TERSE

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SHOW documentdb.enableRbacCompliantSchemas;
-- Save the original user for switching back
SELECT current_user AS original_user \gset

-- =============================================================================
-- Setup: Create test collections and remove_test_user
-- =============================================================================

-- Create test collection (will get collection_id 1984201)
SELECT documentdb_api.create_collection('rbac_remove_test_db', 'test_collection');

-- Create second test collection (will get collection_id 1984202) - user will NOT have access
SELECT documentdb_api.create_collection('rbac_remove_test_db', 'restricted_collection');

-- Insert test data for remove tests
SELECT documentdb_api.insert_one('rbac_remove_test_db', 'test_collection', '{"_id": 1, "name": "doc1", "value": 100}');
SELECT documentdb_api.insert_one('rbac_remove_test_db', 'restricted_collection', '{"_id": 1, "name": "restricted_doc"}');

-- Create remove test users:
-- remove_test_user_a: has DELETE, UPDATE, and SELECT
-- remove_test_user_b: has DELETE only
CREATE ROLE remove_test_user_a WITH LOGIN PASSWORD 'TestPass123!';
CREATE ROLE remove_test_user_b WITH LOGIN PASSWORD 'TestPass123!';

-- Grant collection RBAC role to test users
GRANT documentdb_api_remove_role TO remove_test_user_a;
GRANT documentdb_api_remove_role TO remove_test_user_b;

-- Grant table permissions on test_collection (collection_id = 1984201)
-- When next_collection_id is set to X, the first collection gets ID X+1
-- remove_test_user_a: DELETE, UPDATE, and SELECT
GRANT DELETE, UPDATE, SELECT ON TABLE documentdb_data.documents_1984201 TO remove_test_user_a;
-- remove_test_user_b: DELETE only
GRANT DELETE ON TABLE documentdb_data.documents_1984201 TO remove_test_user_b;

-- =============================================================================
-- Test: Remove operation with documentdb_api_remove_role role
-- =============================================================================

\c regression remove_test_user_a
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Delete should work
SELECT documentdb_api_v2.delete('rbac_remove_test_db', '{"delete": "test_collection", "deletes": [{"q": {"_id": 1}, "limit": 1}]}', NULL, NULL);

-- =============================================================================
-- Test: Verify remove_test_user_a cannot access restricted_collection
-- =============================================================================

-- remove_test_user_a should NOT be able to delete on restricted_collection (no DELETE grant)
SELECT documentdb_api_v2.delete('rbac_remove_test_db', '{"delete": "restricted_collection", "deletes": [{"q": {"_id": 1}, "limit": 1}]}', NULL, NULL);

-- =============================================================================
-- Test: Verify remove_test_user_a cannot perform other operations
-- =============================================================================

-- remove_test_user_a should NOT be able to insert (no INSERT grant and no documentdb_api_insert_role role)
SELECT documentdb_api_v2.insert_one('rbac_remove_test_db', 'test_collection', '{"_id": 102, "name": "should_fail"}', NULL);

-- remove_test_user_a should NOT be able to update (has UPDATE grant but no documentdb_api_update_role role)
SELECT documentdb_api_v2.update('rbac_remove_test_db', '{"update": "test_collection", "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 0}}}]}', NULL, NULL);

-- =============================================================================
-- Test: Verify remove_test_user_b (DELETE only) cannot delete with query filter
-- =============================================================================

\c regression remove_test_user_b
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- remove_test_user_b should NOT be able to delete with filter (has DELETE grant but no SELECT for WHERE clause)
SELECT documentdb_api_v2.delete('rbac_remove_test_db', '{"delete": "test_collection", "deletes": [{"q": {"_id": 1}, "limit": 1}]}', NULL, NULL);

-- =============================================================================
-- Cleanup
-- =============================================================================
 
\c regression :original_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Drop test collections first (removes table privilege dependencies that block DROP ROLE)
SELECT documentdb_api.drop_collection('rbac_remove_test_db', 'test_collection');
SELECT documentdb_api.drop_collection('rbac_remove_test_db', 'restricted_collection');

-- Drop test roles (required due to 100 user limit)
DROP ROLE IF EXISTS remove_test_user_a;
DROP ROLE IF EXISTS remove_test_user_b;
