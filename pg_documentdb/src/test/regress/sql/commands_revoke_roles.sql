SET documentdb.next_collection_id TO 1984200;
SET documentdb.next_collection_index_id TO 1984200;

SET documentdb.maxUserLimit TO 10;
\set VERBOSITY TERSE

SET documentdb.enableRoleCrud TO ON;
SET documentdb.enableUserCrud TO ON;
SET documentdb.enableRolesAdminDBCheck TO ON;
SET documentdb.enableUsersAdminDBCheck TO ON;

-- Set up the roles and user the revoke commands operate on
SELECT documentdb_api.create_role('{"createRole":"revokeTargetRole", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"revokeSourceRole", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"revokeRoleUser", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"revokeTargetRole", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"revokeTargetRole", "roles":[{"role":"revokeSourceRole","db":"admin"}], "$db":"admin"}');

SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'revokeTargetRole'
ORDER BY 1;

-- The stored role document agrees with the membership catalog before any
-- revoke happens.
SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name = 'revokeTargetRole';

-- revokeRolesFromRole: revoke a custom role using the {role, db} document form
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":[{"role":"revokeSourceRole","db":"admin"}], "$db":"admin"}');

-- Only the custom role is gone: the built-in role must still be inherited.
SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name = 'revokeTargetRole';

-- revokeRolesFromRole: revoke a built-in role
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":["readAnyDatabase"], "$db":"admin"}');

-- Both memberships are gone
SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'revokeTargetRole'
ORDER BY 1;

-- The stored role document now has an empty 'roles' array.
SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name = 'revokeTargetRole';

-- The paired built-in roles are granted as one membership and revoked as one
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"revokeTargetRole", "roles":["readWriteAnyDatabase","clusterAdmin"], "$db":"admin"}');

-- Both paired roles are inherited after the grant.
SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name = 'revokeTargetRole';

SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":["readWriteAnyDatabase","clusterAdmin"], "$db":"admin"}');

SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'revokeTargetRole'
ORDER BY 1;

-- Revoking the pair removes both inherited roles together.
SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name = 'revokeTargetRole';

-- revokeRolesFromRole: error cases
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"missingRole", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"readAnyDatabase", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":[], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":["notARole"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":["clusterAdmin"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":1, "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":"readAnyDatabase", "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":["readAnyDatabase"], "$db":"test"}');

-- root is not a grantable membership, so it can never be revoked either. It is
-- rejected whether it is named alone or alongside a role that is revocable, and
-- the reserved name is not accepted as a revoke target.
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":["root"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":[{"role":"root","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"root", "roles":["readAnyDatabase"], "$db":"admin"}');

-- revokeRolesFromUser: take back a custom role and the paired built-in roles
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"revokeRoleUser", "roles":[{"role":"revokeTargetRole","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"revokeRoleUser", "roles":["readWriteAnyDatabase","clusterAdmin"], "$db":"admin"}');

-- Snapshot the granted state first so the effect of the revokes below is
-- observable rather than inferred.
SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'revokeRoleUser'
ORDER BY 1;

SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":[{"role":"revokeTargetRole","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":["readWriteAnyDatabase","clusterAdmin"], "$db":"admin"}');

SELECT parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'revokeRoleUser'
ORDER BY 1;

-- revokeRolesFromUser: error cases
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"missingUser", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":[], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":["notARole"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":["readAnyDatabase"], "$db":"test"}');

-- root is rejected on the user path as well, and the reserved root name is not
-- accepted as a user to revoke from.
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":["root"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":[{"role":"root","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"root", "roles":["readAnyDatabase"], "$db":"admin"}');

-- Revoking root leaves the user's existing memberships untouched.
SELECT parent.rolname AS granted_role_after_root_attempts
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname = 'revokeRoleUser'
ORDER BY 1;

-- The same applies on the revoke path: a role created while the admin-database
-- check was disabled must still be revokable once the check is enabled.
SET documentdb.enableRolesAdminDBCheck TO OFF;
SELECT documentdb_api.create_role('{"createRole":"revokeLegacyNonAdminRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"nonAdminDatabase"}');
SELECT documentdb_api.create_role('{"createRole":"revokeLegacyNoDbRole", "roles":["readAnyDatabase"], "privileges":[]}');
SET documentdb.enableRolesAdminDBCheck TO ON;

SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeLegacyNonAdminRole", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeLegacyNoDbRole", "roles":["readAnyDatabase"], "$db":"admin"}');

SELECT role_name, role_bson
FROM documentdb_api_catalog.roles
WHERE role_name IN ('revokeLegacyNonAdminRole', 'revokeLegacyNoDbRole')
ORDER BY role_name;

-- revokePrivilegesFromRole is not implemented yet and is always rejected.
SELECT documentdb_api.revoke_privileges_from_role('{"revokePrivilegesFromRole":"revokeTargetRole", "privileges":[{"resource":{"db":"revokedb","collection":"revokecoll"}, "actions":["find"]}], "$db":"admin"}');

-- The commands are rejected outright when role CRUD is disabled
SET documentdb.enableRoleCrud TO OFF;
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"revokeTargetRole", "roles":["readAnyDatabase"], "$db":"admin"}');
RESET documentdb.enableRoleCrud;

SET documentdb.enableUserCrud TO OFF;
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"revokeRoleUser", "roles":["readAnyDatabase"], "$db":"admin"}');
RESET documentdb.enableUserCrud;

-- Clean up
SET documentdb.enableRoleCrud TO ON;
SELECT documentdb_api.drop_user('{"dropUser":"revokeRoleUser", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"revokeTargetRole", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"revokeSourceRole", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"revokeLegacyNonAdminRole", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"revokeLegacyNoDbRole", "$db":"admin"}');

RESET documentdb.enableRoleCrud;
RESET documentdb.enableUserCrud;
RESET documentdb.enableRolesAdminDBCheck;
RESET documentdb.enableUsersAdminDBCheck;
RESET documentdb.maxUserLimit;
