SET search_path TO documentdb_api,documentdb_core;
SET documentdb.next_collection_id TO 2900;
SET documentdb.next_collection_index_id TO 2900;

\set VERBOSITY TERSE

SET documentdb.enableRoleCrud TO ON;
SET documentdb.enableRolesAdminDBCheck TO ON;

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
