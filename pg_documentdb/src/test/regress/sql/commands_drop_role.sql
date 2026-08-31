SET documentdb.next_collection_id TO 1983100;
SET documentdb.next_collection_index_id TO 1983100;

SET documentdb.maxUserLimit TO 10;
\set VERBOSITY TERSE

-- Enable role CRUD operations for testing
SET documentdb.enableRoleCrud TO ON;

-- Enable db admin requirement for testing
SET documentdb.enableRolesAdminDBCheck TO ON;

-- ********* Test dropRole command basic functionality *********
-- Test dropRole of a custom role
SELECT documentdb_api.create_role('{"createRole":"custom_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'custom_role';

-- Test dropRole of a referenced role which will still drop regardless
SELECT documentdb_api.create_role('{"createRole":"custom_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"userWithCustomRole", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
GRANT "custom_role" TO "userWithCustomRole";
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'custom_role';
SELECT documentdb_api.drop_user('{"dropUser":"userWithCustomRole", "$db":"admin"}');

-- Test dropRole with additional fields that should be ignored
SELECT documentdb_api.create_role('{"createRole":"custom_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "lsid":"test", "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'custom_role';

-- ********* Test dropRole error inputs *********
-- Creating this custom_role for all negative tests below which will be removed at the end of all error tests
SELECT documentdb_api.create_role('{"createRole":"custom_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'custom_role';

-- Test dropRole with missing dropRole field, should fail
SELECT documentdb_api.drop_role('{"$db":"admin"}');

-- Test dropRole with empty role name, should fail
SELECT documentdb_api.drop_role('{"dropRole":"", "$db":"admin"}');

-- Test dropRole with non-existent role, should fail
SELECT documentdb_api.drop_role('{"dropRole":"nonExistentRole", "$db":"admin"}');

-- An overlength name must not be truncated into an existing role
CREATE ROLE "1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij";
SELECT documentdb_api.drop_role('{"dropRole":"1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk", "$db":"admin"}');
SELECT rolname FROM pg_roles
WHERE rolname = '1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij';
DROP ROLE "1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij";

-- Test dropRole with invalid JSON, should fail
SELECT documentdb_api.drop_role('{"dropRole":"invalidJson"');

-- Test dropRole with non-string role name, should fail
SELECT documentdb_api.drop_role('{"dropRole":1, "$db":"admin"}');

-- Test dropRole with null role name, should fail
SELECT documentdb_api.drop_role('{"dropRole":null, "$db":"admin"}');

-- Test dropping built-in roles, should fail
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_admin_role", "$db":"admin"}');

-- Test dropRole with a non-admin database, should fail
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "lsid":"test", "$db":"nonAdminDatabase"}');

-- Test dropRole of a system role
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_bg_worker_role", "$db":"admin"}');

-- Test dropRole of non-existing role with built-in role prefix, which should fail with role not found
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_role", "$db":"admin"}');

-- Test dropRole with unsupported field, should fail
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "unsupportedField":"value", "$db":"admin"}');

-- Test dropRole with different casing which should fail with role not found
SELECT documentdb_api.drop_role('{"dropRole":"CUSTOM_ROLE", "$db":"admin"}');

-- Test dropRole with non-admin database, should fail
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "$db":"nonAdminDatabase"}');

-- Test dropRole with no database, should fail
SELECT documentdb_api.drop_role('{"dropRole":"custom_role"}');

-- Test dropRole when feature is disabled
SET documentdb.enableRoleCrud TO OFF;
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "$db":"admin"}');
SET documentdb.enableRoleCrud TO ON;

-- Test dropRole when admin DB check is disabled, should succeed
SET documentdb.enableRolesAdminDBCheck TO OFF;
SELECT documentdb_api.drop_role('{"dropRole":"custom_role", "$db":"nonAdminDatabase"}');
SELECT rolname FROM pg_roles WHERE rolname = 'custom_role';

-- Test dropRole with no database when admin DB check is disabled
SELECT documentdb_api.create_role('{"createRole":"custom_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"custom_role"}');
SELECT rolname FROM pg_roles WHERE rolname = 'custom_role';
SET documentdb.enableRolesAdminDBCheck TO ON;

-- Test dropRole with system login role names, should fail
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_bg_worker_role", "$db":"admin"}');

-- Test dropRole with native built-in role names, should fail
SELECT documentdb_api.drop_role('{"dropRole":"readAnyDatabase", "$db":"admin"}');

-- Test dropRole with additional native built-in role names, should all fail with a built-in role error
SELECT documentdb_api.drop_role('{"dropRole":"root", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"readWriteAnyDatabase", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"clusterAdmin", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"dbAdmin", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"userAdmin", "$db":"admin"}');

-- Test that reserved internal role names are blocked for dropRole
SET documentdb.blockedRolePrefixList TO '';
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_readonly_role", "$db":"admin"}');
RESET documentdb.blockedRolePrefixList;

-- Test dropRole with custom RBAC role names, should fail
SET documentdb.blockedRolePrefixList TO '';
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_api_find_role", "$db":"admin"}');
RESET documentdb.blockedRolePrefixList;

-- Test dropRole with custom blocked prefixes, should fail
SET documentdb.blockedRolePrefixList TO 'block,test';
SELECT documentdb_api.drop_role('{"dropRole":"block_role", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"test_role", "$db":"admin"}');
RESET documentdb.blockedRolePrefixList;

-- ********* Test drop_role removes catalog entry *********

-- Create a role with privileges, then drop it and verify catalog is cleaned
SELECT documentdb_api.create_role('{"createRole":"dropCatalogRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name = 'dropCatalogRole';

-- Drop the role
SELECT documentdb_api.drop_role('{"dropRole":"dropCatalogRole", "$db":"admin"}');

-- Verify catalog entry is removed
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name = 'dropCatalogRole';

-- Verify PG role is also gone
SELECT rolname FROM pg_roles WHERE rolname = 'dropCatalogRole';

-- ********* Test dropping one role does not affect another's catalog entry *********

SELECT documentdb_api.create_role('{"createRole":"keepCatalogRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"removeCatalogRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Drop only one
SELECT documentdb_api.drop_role('{"dropRole":"removeCatalogRole", "$db":"admin"}');

-- Verify the other role's catalog entry is untouched
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name = 'keepCatalogRole';
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name = 'removeCatalogRole';

-- Clean up
SELECT documentdb_api.drop_role('{"dropRole":"keepCatalogRole", "$db":"admin"}');

-- ********* Test drop_role for non-existent role gives proper error *********

SELECT documentdb_api.drop_role('{"dropRole":"neverExistedRole", "$db":"admin"}');

-- ********* Test drop_role rejects a login user (not a custom role) *********

-- A user created via create_user is a PG role but not a custom role, so
-- dropRole must not remove it.
SELECT documentdb_api.create_user('{"createUser":"notARoleUser", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"notARoleUser", "$db":"admin"}');
-- The user's PG role must still exist after the rejected dropRole
SELECT rolname FROM pg_roles WHERE rolname = 'notARoleUser';
SELECT documentdb_api.drop_user('{"dropUser":"notARoleUser", "$db":"admin"}');

-- Clean up and Reset settings
RESET documentdb.enableRoleCrud;
RESET documentdb.enableRolesAdminDBCheck;