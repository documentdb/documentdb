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

SELECT documentdb_api.drop_role(
	'{"dropRole":"systemUsersCreatorRole", "$db":"admin"}') AS drop_result \gset
REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemUsersRoleCreator";
REVOKE documentdb_admin_role FROM "systemUsersRoleCreator";
REVOKE documentdb_readonly_role FROM "systemUsersRoleCreator";
DROP ROLE "systemUsersRoleCreator";

SELECT documentdb_api.create_role('{"createRole":"systemUsersCustomRole", "roles":[], "privileges":[], "$db":"admin"}');

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

GRANT "documentdb_root_role" TO "systemUsersRootReader";
GRANT "systemUsersCustomRole" TO
	"systemUsersNoLogin",
	"documentdb_api_hidden_user",
	"documentdb_rbac_hidden_user";
GRANT documentdb_readonly_role TO "systemUsersRootReader";
GRANT SELECT ON documentdb_api_catalog.roles TO "systemUsersRootReader";

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
GRANT SELECT ON documentdb_api_catalog.roles TO "systemUsersOtherReader";

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

REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemUsersRootReader";
REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemUsersOtherReader";
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

-- TODO: Include this privilege in an OSS API-access baseline role.
GRANT SELECT ON documentdb_api_catalog.roles TO "systemUsersReader";

SET ROLE "systemUsersReader";

SELECT cursorpage::text =
	'{ "cursor" : { "id" : { "$numberLong" : "0" }, "ns" : "admin.system.users", "firstBatch" : [ { "_id" : "admin.systemUsersReader", "user" : "systemUsersReader", "db" : "admin", "roles" : [ { "db" : "admin", "role" : "systemUsersCustomRole" } ] } ] }, "ok" : { "$numberDouble" : "1.0" } }'
	AS page_matches
FROM documentdb_api.find_cursor_first_page(
	'admin',
	'{ "find": "system.users" }',
	0) \gset

\echo :page_matches

RESET ROLE;

REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemUsersReader";
SELECT documentdb_api.drop_user(
	'{"dropUser":"systemUsersReader", "$db":"admin"}') AS drop_result \gset
SELECT documentdb_api.drop_role('{"dropRole":"systemUsersCustomRole", "$db":"admin"}');

RESET documentdb.enableRoleCrud;
RESET documentdb.enableRolesAdminDBCheck;
