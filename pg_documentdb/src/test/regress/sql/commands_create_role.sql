SET documentdb.next_collection_id TO 1982900;
SET documentdb.next_collection_index_id TO 1982900;

SET documentdb.maxUserLimit TO 10;
\set VERBOSITY TERSE

-- Test createRole command
-- Enable role CRUD operations for testing
SET documentdb.enableRoleCrud TO ON;

-- Enable db admin requirement for testing
SET documentdb.enableRolesAdminDBCheck TO ON;

-- Test creating a basic role that inherits from readAnyDatabase
SELECT documentdb_api.create_role('{"createRole":"customReadRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Verify the role was created
SELECT rolname FROM pg_roles WHERE rolname = 'customReadRole';

-- Test creating a role that inherits from readWriteAnyDatabase and clusterAdmin
-- (the pair is collapsed into a single grant of the admin role)
SELECT documentdb_api.create_role('{"createRole":"customAdminRole", "roles":["readWriteAnyDatabase", "clusterAdmin"], "privileges":[], "$db":"admin"}');

-- Verify customAdminRole inherits the admin role
SELECT r2.rolname AS granted_role
FROM pg_auth_members am
JOIN pg_roles r1 ON am.member = r1.oid
JOIN pg_roles r2 ON am.roleid = r2.oid
WHERE r1.rolname = 'customAdminRole';

-- Test creating a role that inherits from multiple roles (readAnyDatabase plus
-- the readWriteAnyDatabase + clusterAdmin admin pair)
SELECT documentdb_api.create_role('{"createRole":"multiInheritRole", "roles":["readAnyDatabase", "readWriteAnyDatabase", "clusterAdmin"], "privileges":[], "$db":"admin"}');

-- Test createRole with empty roles array and empty privileges array
SELECT documentdb_api.create_role('{"createRole":"emptyRolesRole", "roles":[], "privileges":[], "$db":"admin"}');

-- Test error cases

-- Test createRole with no roles array, should fail (roles is required)
SELECT documentdb_api.create_role('{"createRole":"noRolesRole", "privileges":[], "$db":"admin"}');

-- Test createRole with no privileges array, should fail (privileges is required)
SELECT documentdb_api.create_role('{"createRole":"noPrivilegesRole", "roles":[], "$db":"admin"}');

-- Test createRole with empty role name, should fail
SELECT documentdb_api.create_role('{"createRole":"", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Test createRole with invalid inherited role, should fail
SELECT documentdb_api.create_role('{"createRole":"invalidInheritRole", "roles":["nonexistent_role"], "privileges":[], "$db":"admin"}');

-- An inherited role name that exceeds the identifier limit is rejected rather
-- than skipped, so the role is not created inheriting less than was asked for.
SELECT documentdb_api.create_role('{"createRole":"longInheritRole", "roles":["1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'longInheritRole';

-- An empty inherited role name is rejected the same way.
SELECT documentdb_api.create_role('{"createRole":"emptyInheritRole", "roles":[""], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'emptyInheritRole';

-- Test createRole with invalid roles array type, should fail
SELECT documentdb_api.create_role('{"createRole":"invalidRolesType", "roles":"not_an_array", "privileges":[], "$db":"admin"}');

-- Test createRole with non-string role names in array, should fail
SELECT documentdb_api.create_role('{"createRole":"invalidRoleNames", "roles":[123, true], "privileges":[], "$db":"admin"}');

-- Test createRole with missing createRole field, should fail
SELECT documentdb_api.create_role('{"roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Test createRole with a built-in role, should fail
SELECT documentdb_api.create_role('{"createRole": "clusterAdmin", "roles":["readWriteAnyDatabase", "clusterAdmin"], "privileges":[],"$db":"admin"}');

-- Test createRole with unsupported field, should fail
SELECT documentdb_api.create_role('{"createRole":"unsupportedFieldRole", "roles":["readAnyDatabase"], "privileges":[], "unsupportedField":"value", "$db":"admin"}');

-- Test creating role with same name as existing role, should fail
SELECT documentdb_api.create_role('{"createRole":"customReadRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Test roles array with mixed valid and invalid roles, should fail
SELECT documentdb_api.create_role('{"createRole":"mixedRolesTest", "roles":["readAnyDatabase", "invalid_role"], "privileges":[], "$db":"admin"}');

-- Test invalid JSON in createRole, should fail
SELECT documentdb_api.create_role('{"createRole":"invalidJson", "roles":["readAnyDatabase"], "privileges":[]');

-- Test createRole with non-admin database, should fail
SELECT documentdb_api.create_role('{"createRole":"nonAdminDatabaseRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"nonAdminDatabase"}');

-- Test createRole with no database, should fail
SELECT documentdb_api.create_role('{"createRole":"noDatabaseRole", "roles":["readAnyDatabase"], "privileges":[]}');

-- Test createRole with just readWriteAnyDatabase role, should fail
-- (must be specified together with clusterAdmin)
SELECT documentdb_api.create_role('{"createRole":"readWriteOnlyRole", "roles":["readWriteAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Test createRole with just clusterAdmin role, should fail
-- (must be specified together with readWriteAnyDatabase)
SELECT documentdb_api.create_role('{"createRole":"clusterAdminOnlyRole", "roles":["clusterAdmin"], "$db":"admin", "privileges":[]}');

-- Test createRole with root role, should fail
SELECT documentdb_api.create_role('{"createRole":"rootRoleTest", "roles":["root"], "privileges":[], "$db":"admin"}');

-- Test createRole inheriting from a native built-in role that is not an
-- inheritable system role (e.g. dbAdmin), should fail as not supported
SELECT documentdb_api.create_role('{"createRole":"dbAdminInheritRole", "roles":["dbAdmin"], "privileges":[], "$db":"admin"}');

-- Test role functionality by creating users and assigning custom roles
-- Create a user first
SELECT documentdb_api.create_user('{"createUser":"testRoleUser", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Grant custom role to user (this demonstrates the role can be granted)
GRANT "customReadRole" TO "testRoleUser";

-- Verify the grant worked by checking pg_auth_members
SELECT r1.rolname as member_role, r2.rolname as granted_role 
FROM pg_auth_members am 
JOIN pg_roles r1 ON am.member = r1.oid 
JOIN pg_roles r2 ON am.roleid = r2.oid 
WHERE r1.rolname = 'testRoleUser' AND r2.rolname = 'customReadRole';

-- Test edge cases for role names
-- Test role name with maximum length (63 characters is PostgreSQL limit)
SELECT documentdb_api.create_role('{"createRole":"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk';

-- Test role name exceeding maximum length (64 characters) is rejected
SELECT documentdb_api.create_role('{"createRole":"1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = '1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij';
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name LIKE '1abcdefghijklmnopqrstuvwxyz%';

-- Test createRole when feature is disabled
SET documentdb.enableRoleCrud TO OFF;
SELECT documentdb_api.create_role('{"createRole":"disabledFeatureRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SET documentdb.enableRoleCrud TO ON;

-- Test createRole when admin DB check is disabled
SET documentdb.enableRolesAdminDBCheck TO OFF;
SELECT documentdb_api.create_role('{"createRole":"nonAdminDBNoCheckRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"nonAdminDatabase"}');
SELECT rolname FROM pg_roles WHERE rolname = 'nonAdminDBNoCheckRole';

-- Test createRole with no $db field
SELECT documentdb_api.create_role('{"createRole":"noDbFieldRole", "roles":["readAnyDatabase"], "privileges":[]}');
SELECT rolname FROM pg_roles WHERE rolname = 'noDbFieldRole';
SET documentdb.enableRolesAdminDBCheck TO ON;

-- Test special characters in role names
SELECT documentdb_api.create_role('{"createRole":"role_with_underscores", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"role-with-dashes", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"role123numbers", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname IN ('role_with_underscores', 'role-with-dashes', 'role123numbers') ORDER BY rolname;

-- Test case sensitivity in createRole
SELECT documentdb_api.create_role('{"createRole":"CaseSensitiveRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"casesensitiverole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname IN ('CaseSensitiveRole', 'casesensitiverole') ORDER BY rolname;

-- Test createRole with additional fields that should be ignored
SELECT documentdb_api.create_role('{"createRole":"ignoredFieldsRole", "roles":["readAnyDatabase"], "privileges":[], "lsid":"session123", "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'ignoredFieldsRole';

-- A well-formed privilege on a resource parses, but this build stores no
-- resource privileges, so the role is reported as unsupported and not created.
-- Test createRole with a privilege naming a resource (find action)
SELECT documentdb_api.create_role('{"createRole":"privRoleFind", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["find"]}], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'privRoleFind';

-- Test createRole with a privilege naming a resource (insert action)
SELECT documentdb_api.create_role('{"createRole":"privRoleInsert", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["insert"]}], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'privRoleInsert';

-- Test createRole with a privilege naming a resource (update action)
SELECT documentdb_api.create_role('{"createRole":"privRoleUpdate", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["update"]}], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'privRoleUpdate';

-- Test createRole with a privilege naming a resource (remove action)
SELECT documentdb_api.create_role('{"createRole":"privRoleRemove", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["remove"]}], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'privRoleRemove';

-- Test createRole with both roles and privileges
SELECT documentdb_api.create_role('{"createRole":"privRoleBoth", "roles":["readAnyDatabase"], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["find", "insert", "update", "remove"]}], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'privRoleBoth';

-- Test error cases for privileges

-- Test privileges with invalid type (not an array), should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleInvalidType", "roles":[], "privileges":"not_an_array", "$db":"admin"}');

-- Test privileges with non-document entry, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleNonDoc", "roles":[], "privileges":["string_entry"], "$db":"admin"}');

-- Test privileges with missing resource field, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleMissingResource", "roles":[], "privileges":[{"actions":["find"]}], "$db":"admin"}');

-- Test privileges with missing actions field, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleMissingActions", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"}}], "$db":"admin"}');

-- Test privileges with unsupported field in privilege, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleUnsupportedField", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["find"],"extraField":"value"}], "$db":"admin"}');

-- Test privileges with empty actions array, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleEmptyActions", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":[]}], "$db":"admin"}');

-- Test privileges with invalid action, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleInvalidAction", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["invalidAction"]}], "$db":"admin"}');

-- Test privileges with missing db in resource, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleMissingDb", "roles":[], "privileges":[{"resource":{"collection":"testcol"},"actions":["find"]}], "$db":"admin"}');

-- Test privileges with missing collection in resource, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleMissingCol", "roles":[], "privileges":[{"resource":{"db":"testdb"},"actions":["find"]}], "$db":"admin"}');

-- Test privileges with unsupported field in resource, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleUnsupportedResourceField", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol","cluster":true},"actions":["find"]}], "$db":"admin"}');

-- Test privileges with empty db in resource, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleEmptyDb", "roles":[], "privileges":[{"resource":{"db":"","collection":"testcol"},"actions":["find"]}], "$db":"admin"}');

-- Test privileges with empty collection in resource, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleEmptyCol", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":""},"actions":["find"]}], "$db":"admin"}');

-- Test privileges with non-string action, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleNonStringAction", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":[123]}], "$db":"admin"}');

-- Test privileges with non-string db, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleNonStringDb", "roles":[], "privileges":[{"resource":{"db":123,"collection":"testcol"},"actions":["find"]}], "$db":"admin"}');

-- Test privileges with non-string collection, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleNonStringCol", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":123},"actions":["find"]}], "$db":"admin"}');

-- Test privileges with resource not a document, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleResourceNotDoc", "roles":[], "privileges":[{"resource":"not_a_document","actions":["find"]}], "$db":"admin"}');

-- Test privileges with actions not an array, should fail
SELECT documentdb_api.create_role('{"createRole":"privRoleActionsNotArray", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":"find"}], "$db":"admin"}');

-- Test createRole with system login role names, should fail
SELECT documentdb_api.create_role('{"createRole":"documentdb_bg_worker_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Test createRole with native built-in role names, should fail
SELECT documentdb_api.create_role('{"createRole":"readAnyDatabase", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Test that reserved role names are blocked for createRole
SET documentdb.blockedRolePrefixList TO '';
SELECT documentdb_api.create_role('{"createRole":"documentdb_readonly_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
RESET documentdb.blockedRolePrefixList;

-- Test createRole with custom RBAC role names, should fail
SET documentdb.blockedRolePrefixList TO '';
SELECT documentdb_api.create_role('{"createRole":"documentdb_api_find_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
RESET documentdb.blockedRolePrefixList;

-- Test createRole with blocked role names, should fail
SET documentdb.blockedRolePrefixList TO 'block,test';
SELECT documentdb_api.create_role('{"createRole":"block", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"test_block_user", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
RESET documentdb.blockedRolePrefixList;

-- ********* Test catalog table storage on create_role *********

-- Verify create_role stores BSON in documentdb_api_catalog.roles
SELECT documentdb_api.create_role('{"createRole":"catalogStoreRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name = 'catalogStoreRole';
SELECT role_bson IS NOT NULL AS has_bson FROM documentdb_api_catalog.roles WHERE role_name = 'catalogStoreRole';

-- Verify catalog constraints reject invalid role metadata
INSERT INTO documentdb_api_catalog.roles (role_name, role_bson)
VALUES (NULL, '{"createRole":"invalid"}'::documentdb_core.bson);
INSERT INTO documentdb_api_catalog.roles (role_name, role_bson)
VALUES ('nullRoleBson', NULL);

-- A role naming only resource privileges is rejected here, so no catalog row is
-- written for it
SELECT documentdb_api.create_role('{"createRole":"privOnlyCatalogRole", "roles":[], "privileges":[{"resource":{"db":"appdb","collection":"users"},"actions":["find","update"]}], "$db":"admin"}');
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name = 'privOnlyCatalogRole';

-- Verify duplicate role does not create a second catalog entry
SELECT documentdb_api.create_role('{"createRole":"catalogStoreRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT count(*) FROM documentdb_api_catalog.roles WHERE role_name = 'catalogStoreRole';

-- ********* Test role inheritance grants on create_role *********

-- Verify create_role grants inheritable system roles via pg_auth_members
SELECT documentdb_api.create_role('{"createRole":"noGrantTestRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT count(*) FROM pg_auth_members am JOIN pg_roles r ON am.member = r.oid WHERE r.rolname = 'noGrantTestRole';

-- ********* Test role name length validation *********

-- Role name at exactly 63 chars (NAMEDATALEN-1) should succeed
SELECT documentdb_api.create_role('{"createRole":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

-- Role name at 64 chars (NAMEDATALEN) should be rejected before the identifier
-- is truncated, so neither the role nor a catalog row is created
SELECT documentdb_api.create_role('{"createRole":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT rolname FROM pg_roles WHERE rolname = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name LIKE 'bbbb%';

-- A 64-char name must not be able to collide with an existing 63-char role by truncation
SELECT documentdb_api.create_role('{"createRole":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- ********* Test empty inherited role name validation *********

-- Empty string in roles array should fail
SELECT documentdb_api.create_role('{"createRole":"emptyInheritRole", "roles":[""], "privileges":[], "$db":"admin"}');

-- ********* Test inherited role name length validation *********

-- Inherited role name at 64 chars should fail as unsupported role
SELECT documentdb_api.create_role('{"createRole":"longInheritRole", "roles":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], "privileges":[], "$db":"admin"}');

-- ********* Test empty action name validation *********

-- Empty string in actions array should fail
SELECT documentdb_api.create_role('{"createRole":"emptyActionRole", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":[""]}], "$db":"admin"}');

-- ********* Test action name length validation *********

-- Action name at 64 chars should fail as unsupported action
SELECT documentdb_api.create_role('{"createRole":"longActionRole", "roles":[], "privileges":[{"resource":{"db":"testdb","collection":"testcol"},"actions":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}], "$db":"admin"}');

-- ********* Test a role naming neither a parent role nor a privilege *********

-- Empty roles AND empty privileges creates a role that grants nothing
SELECT documentdb_api.create_role('{"createRole":"emptyBothRole", "roles":[], "privileges":[], "$db":"admin"}');

-- Clean up privilege test roles
DROP ROLE IF EXISTS "privRoleFind";
DROP ROLE IF EXISTS "privRoleInsert";
DROP ROLE IF EXISTS "privRoleUpdate";
DROP ROLE IF EXISTS "privRoleRemove";
DROP ROLE IF EXISTS "privRoleBoth";

-- Clean up test roles
DROP ROLE IF EXISTS "customReadRole";
DROP ROLE IF EXISTS "longInheritRole";
DROP ROLE IF EXISTS "emptyInheritRole";
DROP ROLE IF EXISTS "customAdminRole";
DROP ROLE IF EXISTS "multiInheritRole";
DROP ROLE IF EXISTS "emptyRolesRole";
DROP ROLE IF EXISTS "emptyBothRole";
DROP ROLE IF EXISTS "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk";
DROP ROLE IF EXISTS "1abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij";
DROP ROLE IF EXISTS "role_with_underscores";
DROP ROLE IF EXISTS "role-with-dashes";
DROP ROLE IF EXISTS "role123numbers";
DROP ROLE IF EXISTS "CaseSensitiveRole";
DROP ROLE IF EXISTS "casesensitiverole";
DROP ROLE IF EXISTS "ignoredFieldsRole";
DROP ROLE IF EXISTS "nonAdminDBNoCheckRole";
DROP ROLE IF EXISTS "noDbFieldRole";
DROP ROLE IF EXISTS "catalogStoreRole";
DROP ROLE IF EXISTS "privOnlyCatalogRole";
DROP ROLE IF EXISTS "noGrantTestRole";
DROP ROLE IF EXISTS "maxPrivOkRole";
DROP ROLE IF EXISTS "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
-- Remove any roles catalog rows left behind by the raw DROP ROLE statements
-- above; a stale row would collide with the role_name primary key if a later
-- test in the same database reused one of these names.
DELETE FROM documentdb_api_catalog.roles r WHERE NOT EXISTS (SELECT 1 FROM pg_roles p WHERE p.rolname = r.role_name);

-- Clean up test users
SELECT documentdb_api.drop_user('{"dropUser":"testRoleUser", "$db":"admin"}');

-- Reset settings
RESET documentdb.enableRoleCrud;
RESET documentdb.blockedRolePrefixList;
RESET documentdb.enableRolesAdminDBCheck;