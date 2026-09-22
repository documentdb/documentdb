SET search_path TO documentdb_api,documentdb_core;
SET documentdb.next_collection_id TO 2900;
SET documentdb.next_collection_index_id TO 2900;

\set VERBOSITY TERSE

SET documentdb.enableRoleCrud TO ON;
SET documentdb.enableRolesAdminDBCheck TO ON;

CREATE ROLE "systemUsersRoleCreator" LOGIN CREATEROLE;
GRANT documentdb_admin_role TO "systemUsersRoleCreator";
GRANT documentdb_readonly_role TO "systemUsersRoleCreator";
GRANT SELECT ON documentdb_api_catalog.roles TO "systemUsersRoleCreator";

SET ROLE "systemUsersRoleCreator";
SELECT documentdb_api.create_role(
	'{"createRole":"systemUsersCreatorRole", "roles":[], "privileges":[], "$db":"admin"}') AS create_result \gset
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users" }');

RESET ROLE;
REVOKE documentdb_admin_role FROM "systemUsersRoleCreator";
SET ROLE "systemUsersRoleCreator";

-- system.roles must not report the created role either. The creator only holds
-- the membership PostgreSQL 16 and later records for the role running
-- CREATE ROLE, which carries ADMIN OPTION but confers neither INHERIT nor SET.
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles" }');
RESET ROLE;

SELECT documentdb_api.drop_role(
	'{"dropRole":"systemUsersCreatorRole", "$db":"admin"}') AS drop_result \gset
REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemUsersRoleCreator";
REVOKE documentdb_readonly_role FROM "systemUsersRoleCreator";
DROP ROLE "systemUsersRoleCreator";

SELECT documentdb_api.create_role('{"createRole":"systemUsersCustomRole", "roles":[], "privileges":[], "$db":"admin"}');

SELECT documentdb_api_internal.is_custom_role('systemUsersCustomRole')
	AS custom_role_is_catalog_backed,
	NOT documentdb_api_internal.is_custom_role('documentdb_readonly_role')
	AS built_in_role_is_not_catalog_backed;

SELECT has_table_privilege(
		   'documentdb_rbac_api_access_role',
		   'pg_catalog.pg_roles',
		   'SELECT') AS pg_roles_select_granted,
	   NOT has_column_privilege(
		   'documentdb_rbac_api_access_role',
		   'pg_catalog.pg_authid',
		   'oid',
		   'SELECT') AS pg_authid_select_not_granted;

GRANT "systemUsersCustomRole" TO CURRENT_USER;
GRANT documentdb_admin_role TO CURRENT_USER;
GRANT documentdb_readonly_role TO CURRENT_USER;

WITH system_users AS
(
	SELECT document
	FROM documentdb_api_catalog.bson_aggregation_find(
		'admin',
		'{ "find": "system.users" }')
)
SELECT bson_get_value_text(document, '_id') = 'admin.' || CURRENT_USER AS id_matches,
	   bson_get_value_text(document, 'user') = CURRENT_USER AS user_matches,
	   documentdb_api_catalog.bson_dollar_project(
		   document, '{ "_id": 0, "user": 0 }') AS document
FROM system_users;

REVOKE "systemUsersCustomRole" FROM CURRENT_USER;

SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users" }');

SELECT documentdb_api.create_user(
	'{"createUser":"systemUsersRootReader", "pwd":"Valid$123Pass", "roles":[{"role":"systemUsersCustomRole","db":"admin"}], "$db":"admin"}') AS create_result \gset
SELECT documentdb_api.create_user(
	'{"createUser":"systemUsersOtherReader", "pwd":"Valid$123Pass", "roles":[{"role":"systemUsersCustomRole","db":"admin"}], "$db":"admin"}') AS create_result \gset
SELECT documentdb_api.create_role(
	'{"createRole":"systemUsersNoLogin", "roles":[], "privileges":[], "$db":"admin"}') AS create_result \gset
CREATE ROLE "documentdb_api_hidden_user" LOGIN;
CREATE ROLE "documentdb_rbac_hidden_user" LOGIN;

CREATE ROLE "systemUsersAdminReader" LOGIN;
GRANT documentdb_admin_role TO "systemUsersAdminReader";
GRANT documentdb_readonly_role TO "systemUsersAdminReader";
SET ROLE "systemUsersAdminReader";
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users", "filter": { "user": "systemUsersOtherReader" } }');
RESET ROLE;
REVOKE documentdb_admin_role FROM "systemUsersAdminReader";
REVOKE documentdb_readonly_role FROM "systemUsersAdminReader";
DROP ROLE "systemUsersAdminReader";

GRANT "documentdb_root_role" TO "systemUsersRootReader";
GRANT "systemUsersCustomRole" TO
	"systemUsersNoLogin",
	"documentdb_api_hidden_user",
	"documentdb_rbac_hidden_user";
GRANT documentdb_readonly_role TO "systemUsersRootReader";

SET ROLE "systemUsersRootReader";
SET plan_cache_mode TO force_generic_plan;
PREPARE system_users_query AS
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users" }');
EXECUTE system_users_query;
RESET ROLE;

GRANT documentdb_readonly_role TO "systemUsersOtherReader";

REVOKE "documentdb_root_role" FROM "systemUsersRootReader";
SET ROLE "systemUsersRootReader";
EXECUTE system_users_query;
RESET ROLE;
DEALLOCATE system_users_query;
RESET plan_cache_mode;

SET ROLE "systemUsersOtherReader";
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users" }');
RESET ROLE;

SELECT documentdb_api.drop_user(
	'{"dropUser":"systemUsersRootReader", "$db":"admin"}') AS drop_result \gset
SELECT documentdb_api.drop_user(
	'{"dropUser":"systemUsersOtherReader", "$db":"admin"}') AS drop_result \gset
SELECT documentdb_api.drop_role(
	'{"dropRole":"systemUsersNoLogin", "$db":"admin"}') AS drop_result \gset
DROP ROLE "documentdb_api_hidden_user";
DROP ROLE "documentdb_rbac_hidden_user";

REVOKE documentdb_admin_role FROM CURRENT_USER;
REVOKE documentdb_readonly_role FROM CURRENT_USER;

SELECT documentdb_api.create_user(
	'{"createUser":"systemUsersReader", "pwd":"Valid$123Pass", "roles":[{"role":"systemUsersCustomRole","db":"admin"}], "$db":"admin"}') AS create_result \gset

-- TODO: Grant this through create_user after it supports custom and built-in role combinations.
GRANT documentdb_readonly_role TO "systemUsersReader";

SET ROLE "systemUsersReader";

SELECT cursorpage::text =
	'{ "cursor" : { "id" : { "$numberLong" : "0" }, "ns" : "admin.system.users", "firstBatch" : [ { "_id" : "admin.systemUsersReader", "user" : "systemUsersReader", "db" : "admin", "roles" : [ { "db" : "admin", "role" : "systemUsersCustomRole" } ] } ] }, "ok" : { "$numberDouble" : "1.0" } }'
	AS page_matches
FROM documentdb_api.find_cursor_first_page(
	'admin',
	'{ "find": "system.users" }',
	0) \gset

\echo :page_matches

-- A filter must be applied above the grouping stage that assembles each user
-- document. Applying it at the grouping level would leave the qual in a plan
-- node that cannot evaluate an aggregate.
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users", "filter": { "user": "systemUsersReader" } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users", "filter": { "user": "noSuchUser" } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users", "filter": { "_id": "admin.systemUsersReader" } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users", "filter": { "roles.role": "systemUsersCustomRole" } }');

RESET ROLE;

SELECT documentdb_api.drop_user(
	'{"dropUser":"systemUsersReader", "$db":"admin"}') AS drop_result \gset
SELECT documentdb_api.drop_role('{"dropRole":"systemUsersCustomRole", "$db":"admin"}');

-- A membership granted WITH ADMIN OPTION does confer the role, so both
-- system.users and system.roles must report it. Suppressing creator
-- memberships by testing ADMIN OPTION alone would wrongly hide this one,
-- which is why the filter tests whether the member holds the privileges of
-- the role instead.
SELECT documentdb_api.create_role(
	'{"createRole":"systemUsersAdminOptionRole", "roles":[], "privileges":[], "$db":"admin"}') AS create_result \gset

CREATE ROLE "systemUsersAdminOptionUser" LOGIN;
GRANT "systemUsersAdminOptionRole" TO "systemUsersAdminOptionUser" WITH ADMIN OPTION;
GRANT documentdb_readonly_role TO "systemUsersAdminOptionUser";
GRANT SELECT ON documentdb_api_catalog.roles TO "systemUsersAdminOptionUser";

SET ROLE "systemUsersAdminOptionUser";
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users" }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles" }');
RESET ROLE;

REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemUsersAdminOptionUser";
REVOKE documentdb_readonly_role FROM "systemUsersAdminOptionUser";
REVOKE "systemUsersAdminOptionRole" FROM "systemUsersAdminOptionUser";
DROP ROLE "systemUsersAdminOptionUser";
SELECT documentdb_api.drop_role(
	'{"dropRole":"systemUsersAdminOptionRole", "$db":"admin"}') AS drop_result \gset

-- A membership granted WITH INHERIT FALSE, SET TRUE also confers the role: the
-- member cannot use it implicitly but can assume it with SET ROLE. Testing only
-- for inherited privileges would wrongly hide it, so both system.users and
-- system.roles must report it. The automatic creator membership carries neither
-- option and so stays excluded.
--
-- Those grant options, and the automatic membership they exist to distinguish,
-- were both added in PostgreSQL 16. The grant is issued through dynamic SQL so
-- that earlier versions never parse the newer syntax, and falls back to a plain
-- grant there, which is the only membership shape those versions record. Both
-- branches must report the role, so the expected output is version independent.
SELECT documentdb_api.create_role(
	'{"createRole":"systemUsersSetOnlyRole", "roles":[], "privileges":[], "$db":"admin"}') AS create_result \gset

CREATE ROLE "systemUsersSetOnlyUser" LOGIN;
DO $$
BEGIN
	IF current_setting('server_version_num')::int >= 160000 THEN
		EXECUTE 'GRANT "systemUsersSetOnlyRole" TO "systemUsersSetOnlyUser"'
				' WITH INHERIT FALSE, SET TRUE';
	ELSE
		EXECUTE 'GRANT "systemUsersSetOnlyRole" TO "systemUsersSetOnlyUser"';
	END IF;
END
$$;
GRANT documentdb_readonly_role TO "systemUsersSetOnlyUser";
GRANT SELECT ON documentdb_api_catalog.roles TO "systemUsersSetOnlyUser";

SET ROLE "systemUsersSetOnlyUser";
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.users" }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles" }');
RESET ROLE;

REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemUsersSetOnlyUser";
REVOKE documentdb_readonly_role FROM "systemUsersSetOnlyUser";
REVOKE "systemUsersSetOnlyRole" FROM "systemUsersSetOnlyUser";
DROP ROLE "systemUsersSetOnlyUser";
SELECT documentdb_api.drop_role(
	'{"dropRole":"systemUsersSetOnlyRole", "$db":"admin"}') AS drop_result \gset

RESET documentdb.enableRoleCrud;
RESET documentdb.enableRolesAdminDBCheck;
