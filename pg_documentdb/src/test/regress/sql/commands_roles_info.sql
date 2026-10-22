SET documentdb.next_collection_id TO 1983000;
SET documentdb.next_collection_index_id TO 1983000;

SET documentdb.maxUserLimit TO 10;
\set VERBOSITY TERSE

-- Enable role CRUD operations for testing
SET documentdb.enableRoleCrud TO ON;

-- Enable db admin requirement for testing
SET documentdb.enableRolesAdminDBCheck TO ON;

-- Create a custom role for testing rolesInfo with a custom role
SELECT documentdb_api.create_role('{"createRole":"test_custom_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- ********* Test rolesInfo with int value *********
-- Test rolesInfo with 1
SELECT documentdb_api.roles_info('{"rolesInfo":1, "$db":"admin"}');

-- Test rolesInfo with int value other than 1, which is not allowed
SELECT documentdb_api.roles_info('{"rolesInfo":0, "$db":"admin"}');

-- Test rolesInfo with showPrivileges
SELECT documentdb_api.roles_info('{"rolesInfo":1, "showPrivileges":true, "$db":"admin"}');

-- Test rolesInfo with invalid showPrivileges type
SELECT documentdb_api.roles_info('{"rolesInfo":1, "showPrivileges":1, "$db":"admin"}');

-- Test rolesInfo with showBuiltInRoles
SELECT documentdb_api.roles_info('{"rolesInfo":1, "showBuiltInRoles":true, "$db":"admin"}');

-- Test internal RBAC roles are hidden from rolesInfo.
SELECT documentdb_api.roles_info('{"rolesInfo":["documentdb_rbac_api_access_role", "documentdb_rbac_baseline_read_role", "documentdb_rbac_baseline_write_role", "documentdb_rbac_readwrite_anydb_role"], "$db":"admin"}');

-- Test rolesInfo with showBuiltInRoles and showPrivileges
SELECT documentdb_api.roles_info('{"rolesInfo":1, "showBuiltInRoles":true, "showPrivileges":true, "$db":"admin"}');

-- Test rolesInfo with invalid showBuiltInRoles type
SELECT documentdb_api.roles_info('{"rolesInfo":1, "showBuiltInRoles":1, "$db":"admin"}');

-- Test rolesInfo with unsupported field at root level
SELECT documentdb_api.roles_info('{"rolesInfo":1, "unsupportedField":"value", "$db":"admin"}');

-- Test rolesInfo with ignorable field at root level
SELECT documentdb_api.roles_info('{"rolesInfo":1, "lsid":"value", "$db":"admin"}');

-- Test rolesInfo with missing mandatory rolesInfo field
SELECT documentdb_api.roles_info('{"$db":"admin"}');

-- Test rolesInfo with null value
SELECT documentdb_api.roles_info('{"rolesInfo":null, "$db":"admin"}');

-- ********* Test rolesInfo with string value *********
-- Test rolesInfo with string value of built-in role
-- which also doesn't require showBuiltInRoles since it's only an addon flag for rolesInfo:1
SELECT documentdb_api.roles_info('{"rolesInfo":"clusterAdmin", "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"readWriteAnyDatabase", "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"root", "showPrivileges":true, "$db":"admin"}');
-- Unsupported built-in role names are omitted.
SELECT documentdb_api.roles_info('{"rolesInfo":"userAdminAnyDatabase", "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"dbAdminAnyDatabase", "$db":"admin"}');

-- Test rolesInfo with string value of custom role
SELECT documentdb_api.roles_info('{"rolesInfo":"test_custom_role", "showPrivileges":true, "$db":"admin"}');

-- Test rolesInfo with string value of not-exist role
SELECT documentdb_api.roles_info('{"rolesInfo":"not_exist_role", "$db":"admin"}');

-- Test rolesInfo with empty string value, which is the same as specifying a not-exist role
SELECT documentdb_api.roles_info('{"rolesInfo":"", "$db":"admin"}');

-- Test rolesInfo with a Postgres role with oid < FirstNormalObjectId, which is not allowed
SELECT documentdb_api.roles_info('{"rolesInfo":"pg_signal_backend", "$db":"admin"}');

-- Test a user role with oid >= FirstNormalObjectId. Create a user then try to fetch it
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"test_user", "$db":"admin"}');

-- A database-only group role is not a catalog-backed custom role.
CREATE ROLE test_sql_only_role;
SELECT documentdb_api.roles_info('{"rolesInfo":"test_sql_only_role", "$db":"admin"}');
SELECT documentdb_core.bson_to_json_string(
	documentdb_api.roles_info('{"rolesInfo":1, "$db":"admin"}'))::text LIKE '%test_sql_only_role%'
	AS lists_sql_only_role;
DROP ROLE test_sql_only_role;

-- ********* Test rolesInfo with role document *********
-- Test rolesInfo with basic role document
SELECT documentdb_api.roles_info('{"rolesInfo": {"role":"readAnyDatabase", "db":"admin"}, "$db":"admin"}');

-- Test rolesInfo with bson document with empty role or db
SELECT documentdb_api.roles_info('{"rolesInfo": {"role":"", "db":""}, "$db":"admin"}');

-- Test rolesInfo with bson document with miss db which is not allowed
SELECT documentdb_api.roles_info('{"rolesInfo": {"role":"readAnyDatabase"}, "$db":"admin"}');

-- Test rolesInfo with bson document with miss role which is not allowed
SELECT documentdb_api.roles_info('{"rolesInfo": {"db":"admin"}, "$db":"admin"}');

-- Test rolesInfo with bson document of invalid role field type
SELECT documentdb_api.roles_info('{"rolesInfo":{"role":1, "db":"admin"}, "$db":"admin"}');

-- Test rolesInfo with bson document of invalid role field type
SELECT documentdb_api.roles_info('{"rolesInfo":{"role":"readAnyDatabase", "db":1}, "$db":"admin"}');

-- Test rolesInfo with bson document with unknown field, which is not allowed
SELECT documentdb_api.roles_info('{"rolesInfo":{"role":"readAnyDatabase", "db":"admin", "unknownField":"value"}, "$db":"admin"}');

-- Test rolesInfo with non-admin database, should fail
SELECT documentdb_api.roles_info('{"rolesInfo":{"role":"readAnyDatabase", "db":"admin"}, "$db":"nonAdminDatabase"}');

-- Test rolesInfo with no database, should fail
SELECT documentdb_api.roles_info('{"rolesInfo":{"role":"readAnyDatabase", "db":"admin"}}');

-- ********* Test rolesInfo with array *********
-- Test rolesInfo with empty array
SELECT documentdb_api.roles_info('{"rolesInfo":[], "$db":"admin"}');

-- Test rolesInfo with array of role names, including empty string
SELECT documentdb_api.roles_info('{"rolesInfo":["readAnyDatabase", "test_custom_role", "not_exist_role", ""], "$db":"admin"}');

-- Test rolesInfo with array of mixed bson document and string
SELECT documentdb_api.roles_info('{"rolesInfo":[{"role":"readAnyDatabase", "db":"admin"}, "test_custom_role"], "$db":"admin"}');

-- Test rolesInfo for multiple built-in roles
SELECT documentdb_api.roles_info('{"rolesInfo":["readAnyDatabase", "clusterAdmin"], "showBuiltInRoles":true, "$db":"admin"}');

-- Test rolesInfo when feature is disabled
SET documentdb.enableRoleCrud TO OFF;
SELECT documentdb_api.roles_info('{"rolesInfo":1, "$db":"admin"}');
SET documentdb.enableRoleCrud TO ON;

-- Test rolesInfo with non-admin database when admin DB check is disabled, should succeed
SET documentdb.enableRolesAdminDBCheck TO OFF;
SELECT documentdb_api.roles_info('{"rolesInfo":1, "$db":"nonAdminDatabase"}');

-- Test rolesInfo with no database when admin DB check is disabled
SELECT documentdb_api.roles_info('{"rolesInfo":1}');
SET documentdb.enableRolesAdminDBCheck TO ON;

-- ********* Test rolesInfo reports inherited roles when the admin role has LOGIN *********

-- readWriteAnyDatabase and clusterAdmin are collapsed into a single grant of the
-- admin role. The admin role carrying LOGIN must not cause the roles it stands
-- for to be dropped from the response.
SELECT documentdb_api.create_role('{"createRole":"test_multi_inherit_role", "roles":["readAnyDatabase", "readWriteAnyDatabase", "clusterAdmin"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"test_multi_inherit_role", "$db":"admin"}');

ALTER ROLE documentdb_admin_role WITH LOGIN;
SELECT documentdb_api.roles_info('{"rolesInfo":"test_multi_inherit_role", "$db":"admin"}');
ALTER ROLE documentdb_admin_role WITH NOLOGIN;

DROP ROLE IF EXISTS "test_multi_inherit_role";
DELETE FROM documentdb_api_catalog.roles WHERE role_name = 'test_multi_inherit_role';

-- ********* Test rolesInfo ignores out-of-band grants *********

-- The stored catalog definition remains authoritative when database
-- memberships are changed outside role CRUD.
SELECT documentdb_api.create_role('{"createRole":"test_stray_parent_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
CREATE ROLE test_stray_login_role LOGIN;
GRANT test_stray_login_role TO "test_stray_parent_role";

SELECT documentdb_api.roles_info('{"rolesInfo":"test_stray_parent_role", "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":1, "$db":"admin"}') IS NOT NULL AS lists_all_roles;

REVOKE test_stray_login_role FROM "test_stray_parent_role";

-- Removing the grant does not change the reported metadata.
SELECT documentdb_api.roles_info('{"rolesInfo":"test_stray_parent_role", "$db":"admin"}');

-- Transitive out-of-band grants are also ignored.
SELECT documentdb_api.create_role('{"createRole":"test_stray_child_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
GRANT test_stray_login_role TO "test_stray_parent_role";
GRANT "test_stray_parent_role" TO "test_stray_child_role";
SELECT documentdb_api.roles_info('{"rolesInfo":"test_stray_child_role", "$db":"admin"}');

REVOKE "test_stray_parent_role" FROM "test_stray_child_role";
REVOKE test_stray_login_role FROM "test_stray_parent_role";
DROP ROLE IF EXISTS "test_stray_child_role";
DROP ROLE IF EXISTS test_stray_login_role;
DROP ROLE IF EXISTS "test_stray_parent_role";
DELETE FROM documentdb_api_catalog.roles WHERE role_name IN ('test_stray_parent_role', 'test_stray_child_role');

-- ********* Test rolesInfo custom-role visibility *********

SELECT documentdb_api.create_role('{"createRole":"test_hidden_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
CREATE ROLE test_roles_info_reader LOGIN;
GRANT documentdb_readonly_role TO test_roles_info_reader;
GRANT test_custom_role TO test_roles_info_reader;
SELECT documentdb_api.create_role('{"createRole":"test_transitive_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
GRANT test_transitive_role TO test_custom_role;

SET ROLE documentdb_root_role;
SELECT documentdb_api.roles_info('{"rolesInfo":"test_hidden_role", "$db":"admin"}');
RESET ROLE;

CREATE ROLE test_roles_info_admin LOGIN;
GRANT documentdb_admin_role TO test_roles_info_admin;
SET ROLE test_roles_info_admin;
-- Admin-role membership can list all catalog-backed custom roles.
SELECT pg_has_role(current_user, 'documentdb_root_role', 'MEMBER')
	AS is_root_role_member,
	pg_has_role(current_user, 'documentdb_admin_role', 'MEMBER')
	AS is_admin_role_member;
SELECT documentdb_api.roles_info('{"rolesInfo":"test_hidden_role", "$db":"admin"}');
-- Admin-role membership can also view any built-in role, even one it does not
-- otherwise hold, matching the view-all-roles behavior for custom roles.
SELECT documentdb_api.roles_info('{"rolesInfo":"root", "$db":"admin"}');
SELECT documentdb_core.bson_to_json_string(
	documentdb_api.roles_info('{"rolesInfo":1, "$db":"admin"}'))::text
		LIKE '%test_hidden_role%'
	AS admin_lists_all_custom_roles;
RESET ROLE;

SET ROLE test_roles_info_reader;
SELECT pg_has_role(current_user, 'documentdb_root_role', 'MEMBER')
	AS is_root_role_member,
	pg_has_role(current_user, 'test_custom_role', 'MEMBER')
	AS is_direct_role_member,
	pg_has_role(current_user, 'test_transitive_role', 'MEMBER')
	AS is_transitive_role_member,
	pg_has_role(current_user, 'test_hidden_role', 'MEMBER')
	AS is_hidden_role_member;
SELECT documentdb_api.roles_info('{"rolesInfo":["readAnyDatabase", "test_custom_role", "test_transitive_role"], "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"test_hidden_role", "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":["test_custom_role", "test_hidden_role"], "$db":"admin"}');
-- Built-in roles honor the same visibility rule: a held built-in role
-- (readAnyDatabase via documentdb_readonly_role) is returned, while unheld
-- built-in roles such as root and clusterAdmin are omitted rather than
-- exposing their definition and privileges.
SELECT documentdb_api.roles_info('{"rolesInfo":"readAnyDatabase", "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"root", "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":["readAnyDatabase", "root", "clusterAdmin"], "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":1, "$db":"admin"}');
RESET ROLE;

REVOKE test_transitive_role FROM test_custom_role;
REVOKE test_custom_role FROM test_roles_info_reader;
REVOKE documentdb_readonly_role FROM test_roles_info_reader;
DROP ROLE test_roles_info_reader;
REVOKE documentdb_admin_role FROM test_roles_info_admin;
DROP ROLE test_roles_info_admin;
SELECT documentdb_api.drop_role('{"dropRole":"test_transitive_role", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"test_hidden_role", "$db":"admin"}');

-- ********* Test rolesInfo built-in visibility for SET-only membership *********
-- A caller can hold a built-in role through membership (it can assume the role
-- via SET ROLE) without inheriting the role's privileges through USAGE. Built-in
-- role visibility must mirror the custom-role predicate and treat such a caller
-- as holding the role, so the definition stays viewable. The membership is
-- established through a NOINHERIT intermediary, which blocks privilege
-- inheritance while preserving the ability to assume the role. The reader draws
-- its ability to run rolesInfo from documentdb_readonly_role, so the built-in
-- role under test is readWriteAnyDatabase, whose backing role
-- documentdb_rbac_readwrite_anydb_role is provisioned by the extension.
CREATE ROLE test_roles_info_set_reader LOGIN;
GRANT documentdb_readonly_role TO test_roles_info_set_reader;
CREATE ROLE test_roles_info_set_only_parent NOINHERIT;
GRANT documentdb_rbac_readwrite_anydb_role TO test_roles_info_set_only_parent;
GRANT test_roles_info_set_only_parent TO test_roles_info_set_reader;
SET ROLE test_roles_info_set_reader;
-- The reader can assume readWriteAnyDatabase's backing role but does not hold its
-- privileges via USAGE.
SELECT pg_has_role(current_user, 'documentdb_rbac_readwrite_anydb_role', 'USAGE')
	AS holds_via_usage,
	pg_has_role(current_user, 'documentdb_rbac_readwrite_anydb_role', 'MEMBER')
	AS is_member;
SELECT documentdb_api.roles_info('{"rolesInfo":"readWriteAnyDatabase", "showPrivileges":true, "$db":"admin"}');
RESET ROLE;
REVOKE test_roles_info_set_only_parent FROM test_roles_info_set_reader;
REVOKE documentdb_rbac_readwrite_anydb_role FROM test_roles_info_set_only_parent;
DROP ROLE test_roles_info_set_only_parent;
REVOKE documentdb_readonly_role FROM test_roles_info_set_reader;
DROP ROLE test_roles_info_set_reader;

-- ********* Test rolesInfo built-in visibility ignores the legacy backing role *
-- rolesInfo visibility for readWriteAnyDatabase keys off the current backing
-- role documentdb_rbac_readwrite_anydb_role only. The legacy
-- documentdb_readwrite_role does not grant visibility, so a caller that holds
-- only the legacy role cannot view the readWriteAnyDatabase definition. User
-- reporting (connectionStatus and usersInfo) still recognizes the legacy role,
-- so that surface and rolesInfo intentionally differ for legacy-only holders.
-- The reader draws its ability to run rolesInfo from documentdb_readonly_role
-- and is not a member of the admin or root roles, so visibility is decided
-- solely by whether it holds the current backing role.
CREATE ROLE test_roles_info_legacy_reader LOGIN;
GRANT documentdb_readonly_role TO test_roles_info_legacy_reader;
GRANT documentdb_readwrite_role TO test_roles_info_legacy_reader;
SET ROLE test_roles_info_legacy_reader;
-- The reader holds only the legacy backing role, not the current one, and is not
-- an admin, so it cannot view the readWriteAnyDatabase definition.
SELECT pg_has_role(current_user, 'documentdb_readwrite_role', 'USAGE')
	AS holds_legacy_via_usage,
	pg_has_role(current_user, 'documentdb_rbac_readwrite_anydb_role', 'MEMBER')
	AS is_member_of_new_backing,
	pg_has_role(current_user, 'documentdb_admin_role', 'USAGE')
	AS holds_admin_via_usage;
SELECT documentdb_api.roles_info('{"rolesInfo":"readWriteAnyDatabase", "showPrivileges":true, "$db":"admin"}');
RESET ROLE;
REVOKE documentdb_readwrite_role FROM test_roles_info_legacy_reader;
REVOKE documentdb_readonly_role FROM test_roles_info_legacy_reader;
DROP ROLE test_roles_info_legacy_reader;

-- ***** Test rolesInfo view-all visibility for SET-only admin membership *****
-- Membership in the admin role grants the ability to view every role, even ones
-- the caller does not otherwise hold. That view-all predicate must mirror the
-- custom-role predicate and treat a caller that can assume the admin role via
-- SET ROLE (without inheriting its privileges through USAGE) as holding it. The
-- membership is established through a NOINHERIT intermediary, which blocks
-- privilege inheritance while preserving the ability to assume the role. The
-- reader draws its ability to run rolesInfo from documentdb_readonly_role, and
-- the roles under test are an unheld custom role and the unheld built-in root
-- role, neither of which the reader could see without the view-all path.
SELECT documentdb_api.create_role('{"createRole":"test_setadmin_hidden_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
CREATE ROLE test_roles_info_setadmin_reader LOGIN;
GRANT documentdb_readonly_role TO test_roles_info_setadmin_reader;
CREATE ROLE test_roles_info_setadmin_parent NOINHERIT;
GRANT documentdb_admin_role TO test_roles_info_setadmin_parent;
GRANT test_roles_info_setadmin_parent TO test_roles_info_setadmin_reader;
SET ROLE test_roles_info_setadmin_reader;
-- The reader can assume the admin role but does not hold its privileges via
-- USAGE, and is not a member of the custom role under test.
SELECT pg_has_role(current_user, 'documentdb_admin_role', 'USAGE')
	AS holds_admin_via_usage,
	pg_has_role(current_user, 'documentdb_admin_role', 'MEMBER')
	AS is_admin_member,
	pg_has_role(current_user, 'test_setadmin_hidden_role', 'MEMBER')
	AS is_hidden_role_member;
-- View-all lets the SET-only admin inspect roles it does not hold: the built-in
-- root role flows through the view-all predicate in RolesInfoCallerCanViewAllRoles,
-- and the unheld custom role through the equivalent system.roles view filter.
SELECT documentdb_api.roles_info('{"rolesInfo":"test_setadmin_hidden_role", "$db":"admin"}');
SELECT documentdb_api.roles_info('{"rolesInfo":"root", "showPrivileges":true, "$db":"admin"}');
RESET ROLE;
REVOKE test_roles_info_setadmin_parent FROM test_roles_info_setadmin_reader;
REVOKE documentdb_admin_role FROM test_roles_info_setadmin_parent;
DROP ROLE test_roles_info_setadmin_parent;
REVOKE documentdb_readonly_role FROM test_roles_info_setadmin_reader;
DROP ROLE test_roles_info_setadmin_reader;
SELECT documentdb_api.drop_role('{"dropRole":"test_setadmin_hidden_role", "$db":"admin"}');

-- Clean up test roles created for rolesInfo testing
DROP ROLE IF EXISTS "test_custom_role";
DELETE FROM documentdb_api_catalog.roles WHERE role_name IN ('test_custom_role');

-- Reset settings
RESET documentdb.enableRoleCrud;
RESET documentdb.enableRolesAdminDBCheck;
