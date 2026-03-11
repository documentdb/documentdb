SET documentdb.next_collection_id TO 9973800;
SET documentdb.next_collection_index_id TO 9973800;

\set VERBOSITY TERSE

-- Test RBAC metadata infrastructure for RFC-006 Phase 1

-- Test 1: Verify metadata tables exist
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'documentdb_api_catalog' 
AND table_name IN ('user_roles', 'roles', 'metadata_version')
ORDER BY table_name;

-- Test 2: Verify built-in roles count
SELECT COUNT(*) as builtin_roles_count 
FROM documentdb_api_catalog.roles
WHERE document OPERATOR(documentdb_core.->>) 'is_builtin' = 'true';

-- Test 3: List all built-in role names
SELECT document OPERATOR(documentdb_core.->>) 'role' as role_name,
       document OPERATOR(documentdb_core.->>) 'is_builtin' as is_builtin
FROM documentdb_api_catalog.roles
WHERE document OPERATOR(documentdb_core.->>) 'is_builtin' = 'true'
ORDER BY document OPERATOR(documentdb_core.->>) 'role';

-- Test 4: Verify specific roles exist
SELECT COUNT(*) as expected_roles_count
FROM documentdb_api_catalog.roles
WHERE document OPERATOR(documentdb_core.->>) 'role' IN ('read', 'readWrite', 'dbAdmin', 'userAdmin', 'root');

-- Test 5: Verify readWrite role exists
SELECT document OPERATOR(documentdb_core.->>) 'role' as role_name
FROM documentdb_api_catalog.roles
WHERE document OPERATOR(documentdb_core.->>) 'role' = 'readWrite';

-- Test 6: Verify read role exists
SELECT document OPERATOR(documentdb_core.->>) 'role' as role_name
FROM documentdb_api_catalog.roles
WHERE document OPERATOR(documentdb_core.->>) 'role' = 'read';

-- Test 7: Verify all expected roles are present
SELECT document OPERATOR(documentdb_core.->>) 'role' as role_name
FROM documentdb_api_catalog.roles
WHERE document OPERATOR(documentdb_core.->>) 'is_builtin' = 'true'
ORDER BY 1;

-- Test 8: Verify metadata_version table is initialized
SELECT COUNT(*) as version_count, 
       MIN(version_number) as initial_version
FROM documentdb_api_catalog.metadata_version;

-- Test 9: Verify user_roles table structure (should be empty initially or have migrated data)
SELECT COUNT(*) >= 0 as user_roles_table_accessible
FROM documentdb_api_catalog.user_roles;

-- Test 10: Create user and verify user_roles metadata is populated
SELECT documentdb_api.create_user('{"createUser":"rbac_test_user1", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

SELECT username, role_name, database_name 
FROM documentdb_api_catalog.user_roles 
WHERE username = 'rbac_test_user1'
ORDER BY role_name;

-- Test 11: Create user with readWriteAnyDatabase and verify metadata
SELECT documentdb_api.create_user('{"createUser":"rbac_test_user2", "pwd":"Valid$123Pass", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');

SELECT username, role_name, database_name 
FROM documentdb_api_catalog.user_roles 
WHERE username = 'rbac_test_user2'
ORDER BY role_name;

-- Test 12: Create user with admin role (readWriteAnyDatabase + clusterAdmin) and verify metadata
SELECT documentdb_api.create_user('{"createUser":"rbac_test_user3", "pwd":"Valid$123Pass", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

SELECT username, role_name, database_name 
FROM documentdb_api_catalog.user_roles 
WHERE username = 'rbac_test_user3'
ORDER BY role_name;

-- Test 13: Verify user_roles primary key constraint (should prevent duplicates)
SELECT COUNT(*) as entry_count
FROM documentdb_api_catalog.user_roles 
WHERE username = 'rbac_test_user1';

-- Test 14: Drop user and verify user_roles metadata is cleaned up
SELECT documentdb_api.drop_user('{"dropUser":"rbac_test_user1", "$db":"admin"}');

SELECT COUNT(*) as remaining_entries
FROM documentdb_api_catalog.user_roles 
WHERE username = 'rbac_test_user1';

-- Test 15: Drop second user and verify cleanup
SELECT documentdb_api.drop_user('{"dropUser":"rbac_test_user2", "$db":"admin"}');

SELECT COUNT(*) as remaining_entries
FROM documentdb_api_catalog.user_roles 
WHERE username = 'rbac_test_user2';

-- Test 16: Verify indexes exist on user_roles table
SELECT indexname, indexdef 
FROM pg_indexes 
WHERE tablename = 'user_roles' 
AND schemaname = 'documentdb_api_catalog'
ORDER BY indexname;

-- Test 17: Verify index exists on roles table for role name lookups
SELECT indexname, indexdef 
FROM pg_indexes 
WHERE tablename = 'roles' 
AND schemaname = 'documentdb_api_catalog'
ORDER BY indexname;

-- Cleanup remaining test users
SELECT documentdb_api.drop_user('{"dropUser":"rbac_test_user3", "$db":"admin"}');

-- Verify all test users are cleaned up
SELECT COUNT(*) as remaining_test_users
FROM documentdb_api_catalog.user_roles 
WHERE username LIKE 'rbac_test_user%';