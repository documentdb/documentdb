SET documentdb.next_collection_id TO 1984100;
SET documentdb.next_collection_index_id TO 1984100;

SET documentdb.maxUserLimit TO 10;
\set VERBOSITY TERSE

SET documentdb.enableRoleCrud TO ON;
SET documentdb.enableUserCrud TO ON;
SET documentdb.enableRolesAdminDBCheck TO ON;
SET documentdb.enableUsersAdminDBCheck TO ON;

-- Set up the roles the grant commands operate on
SELECT documentdb_api.create_role('{"createRole":"grantTargetRole", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"grantSourceRole", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"grantRoleUser", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Membership checks distinguish an absent grant from an existing direct grant.
SELECT documentdb_api_internal.is_role_member_of_role(
    'grantRoleUser', 'grantTargetRole') AS has_target_role;
SELECT documentdb_api_internal.is_role_member_of_role(
    'grantRoleUser', 'documentdb_readonly_role') AS has_readonly_role;

SELECT user_name,
       documentdb_api_internal.is_reserved_user(user_name) AS is_reserved
FROM (VALUES
    ('documentdb_bg_worker_role'),
    ('documentdb_root_role'),
    ('documentdb_api_user'),
    ('documentdb_rbac_user'),
    ('documentdbXapi_user'),
    ('grantRoleUser')) AS users(user_name)
ORDER BY user_name;

SELECT documentdb_api_internal.is_reserved_user(NULL) IS NULL
    AS null_user_returns_null;

-- grantRolesToRole: grant a built-in role
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["readAnyDatabase"], "$db":"admin"}');

-- grantRolesToRole: grant a custom role using the {role, db} document form
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":[{"role":"grantSourceRole","db":"admin"}], "$db":"admin"}');

-- Re-granting a role that is already held is a no-op and must still succeed.
-- The redundant-grant NOTICE names the grantor, which is the operating system
-- account running the test, and its wording differs across server versions, so
-- it is suppressed here to keep the output stable.
SET client_min_messages TO WARNING;
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["readAnyDatabase"], "$db":"admin"}');
RESET client_min_messages;

-- Verify the inheritance edges
SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'grantTargetRole'
ORDER BY 1;

-- The stored role document is the source of truth for the role's inherited
-- roles, so it must list exactly the roles granted above.
SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name = 'grantTargetRole';

-- grantRolesToRole: the paired built-in roles must be granted together
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["readWriteAnyDatabase","clusterAdmin"], "$db":"admin"}');

-- The paired grant is reflected in both the membership catalog and the
-- stored role document.
SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'grantTargetRole'
ORDER BY 1;

SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name = 'grantTargetRole';

-- grantRolesToRole: error cases
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"missingRole", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"readAnyDatabase", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":[], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["notARole"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["clusterAdmin"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":1, "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":"readAnyDatabase", "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["readAnyDatabase"], "$db":"test"}');

-- root is not a grantable membership: it is rejected whether it is named alone
-- or in the {role, db} document form, and the reserved name is not accepted as
-- a grant target. This is the counterpart of the revoke side, and keeping root
-- ungrantable is what keeps it unrevocable.
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["root"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":[{"role":"root","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"root", "roles":["readAnyDatabase"], "$db":"admin"}');

-- grantRolesToUser: grant a custom role and a built-in role to a user
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":[{"role":"grantTargetRole","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":["readWriteAnyDatabase","clusterAdmin"], "$db":"admin"}');

-- Membership through grantTargetRole reaches its inherited custom role.
SELECT documentdb_api_internal.is_role_member_of_role(
    'grantRoleUser', 'grantTargetRole') AS has_target_role;
SELECT documentdb_api_internal.is_role_member_of_role(
    'grantRoleUser', 'grantSourceRole') AS has_transitive_source_role;

-- Unknown names use PostgreSQL's standard role lookup errors.
SELECT documentdb_api_internal.is_role_member_of_role(
    'missingRoleUser', 'grantTargetRole');
SELECT documentdb_api_internal.is_role_member_of_role(
    'grantRoleUser', 'missingTargetRole');

-- The function is strict.
SELECT documentdb_api_internal.is_role_member_of_role(
    NULL, 'grantTargetRole') IS NULL AS null_user_returns_null;
SELECT documentdb_api_internal.is_role_member_of_role(
    'grantRoleUser', NULL) IS NULL AS null_role_returns_null;

SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'grantRoleUser'
ORDER BY 1;

-- grantRolesToUser: error cases
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"missingUser", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":[], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":["notARole"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":["readAnyDatabase"], "$db":"test"}');

-- root is rejected on the user path as well, and the reserved root name is not
-- accepted as a user to grant to.
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":["root"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":[{"role":"root","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"root", "roles":["readAnyDatabase"], "$db":"admin"}');

-- No root membership was created by any of the attempts above.
SELECT COUNT(*) AS root_memberships_created
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname IN ('grantRoleUser', 'grantTargetRole')
  AND parent.rolname LIKE '%root%';

-- A role created while the admin-database check was disabled stores a document
-- that would not pass the command-time checks. Granting to it must still work:
-- the stored document is historical data, not a command being validated.
SET documentdb.enableRolesAdminDBCheck TO OFF;
SELECT documentdb_api.create_role('{"createRole":"grantLegacyNonAdminRole", "roles":[], "privileges":[], "$db":"nonAdminDatabase"}');
SELECT documentdb_api.create_role('{"createRole":"grantLegacyNoDbRole", "roles":[], "privileges":[]}');
SET documentdb.enableRolesAdminDBCheck TO ON;

SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantLegacyNonAdminRole", "roles":[{"role":"grantSourceRole","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantLegacyNoDbRole", "roles":[{"role":"grantSourceRole","db":"admin"}], "$db":"admin"}');

SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name IN ('grantLegacyNonAdminRole', 'grantLegacyNoDbRole')
ORDER BY role_name;

-- grantPrivilegesToRole is not implemented yet and is always rejected.
SELECT documentdb_api.grant_privileges_to_role('{"grantPrivilegesToRole":"grantTargetRole", "privileges":[{"resource":{"db":"grantdb","collection":"grantcoll"}, "actions":["find"]}], "$db":"admin"}');

-- The commands are rejected outright when role CRUD is disabled
SET documentdb.enableRoleCrud TO OFF;
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"grantTargetRole", "roles":["readAnyDatabase"], "$db":"admin"}');
RESET documentdb.enableRoleCrud;

SET documentdb.enableUserCrud TO OFF;
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"grantRoleUser", "roles":["readAnyDatabase"], "$db":"admin"}');
RESET documentdb.enableUserCrud;

-- Clean up
SET documentdb.enableRoleCrud TO ON;
SELECT documentdb_api.drop_user('{"dropUser":"grantRoleUser", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"grantTargetRole", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"grantSourceRole", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"grantLegacyNonAdminRole", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"grantLegacyNoDbRole", "$db":"admin"}');

RESET documentdb.enableRoleCrud;
RESET documentdb.enableUserCrud;
RESET documentdb.enableRolesAdminDBCheck;
RESET documentdb.enableUsersAdminDBCheck;
RESET documentdb.maxUserLimit;
