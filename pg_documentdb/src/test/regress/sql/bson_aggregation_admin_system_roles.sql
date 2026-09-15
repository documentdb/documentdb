SET search_path TO documentdb_api,documentdb_core;
SET documentdb.next_collection_id TO 2800;
SET documentdb.next_collection_index_id TO 2800;

\set VERBOSITY TERSE

SET documentdb.enableRoleCrud TO ON;
SET documentdb.enableRolesAdminDBCheck TO ON;

SELECT documentdb_api.create_role('{"createRole":"systemRolesParent", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"systemRolesChildOne", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"systemRolesChildTwo", "roles":["readWriteAnyDatabase", "clusterAdmin"], "privileges":[], "$db":"admin"}');

SET documentdb.enable_admin_database_queries TO OFF;
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "role": "systemRolesParent" } }');
SET documentdb.enable_admin_database_queries TO ON;

SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "role": { "$in": [ "systemRolesParent", "systemRolesChildOne", "systemRolesChildTwo" ] } }, "sort": { "role": 1 } }');

-- A filter must discriminate, not merely avoid an error. Pair each matching
-- filter with a non-matching one so an unconditionally empty or unconditionally
-- full result is visible.
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "role": "noSuchRole" } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "_id": "admin.systemRolesParent" } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "_id": "admin.noSuchRole" } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "db": "admin", "role": "systemRolesChildOne" } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "db": "notAdmin", "role": "systemRolesChildOne" } }');

-- Filter into the inherited roles array that $replaceRoot assembles.
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "roles.role": "readAnyDatabase" }, "sort": { "role": 1 } }');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "roles.role": "noSuchInheritedRole" } }');

-- A filter combined with a projection must still resolve against the
-- reshaped document.
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "role": "systemRolesChildTwo" }, "projection": { "_id": 0, "role": 1, "db": 1 } }');

GRANT USAGE ON SCHEMA documentdb_api_catalog TO "documentdb_root_role";
GRANT SELECT ON documentdb_api_catalog.roles TO "documentdb_root_role";

SET ROLE "documentdb_root_role";
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "role": { "$in": [ "systemRolesParent", "systemRolesChildOne", "systemRolesChildTwo" ] } }, "sort": { "role": 1 } }');
RESET ROLE;

REVOKE SELECT ON documentdb_api_catalog.roles FROM "documentdb_root_role";
REVOKE USAGE ON SCHEMA documentdb_api_catalog FROM "documentdb_root_role";

GRANT SELECT ON documentdb_api_catalog.roles TO "systemRolesChildOne";

SET ROLE "systemRolesChildOne";
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
	'admin',
	'{ "find": "system.roles", "filter": { "role": { "$in": [ "systemRolesParent", "systemRolesChildOne", "systemRolesChildTwo" ] } }, "sort": { "role": 1 } }');
RESET ROLE;

REVOKE SELECT ON documentdb_api_catalog.roles FROM "systemRolesChildOne";

SELECT cursorpage AS page, continuation AS cont, persistconnection AS persistent,
	cursorid AS cid
FROM documentdb_api.find_cursor_first_page(
	'admin',
	'{ "find": "system.roles", "filter": { "role": { "$in": [ "systemRolesParent", "systemRolesChildOne", "systemRolesChildTwo" ] } }, "batchSize": 1 }',
	4294967294) \gset

SELECT documentdb_api_catalog.bson_dollar_project(
	:'page'::bson,
	'{ "_id": 0, "batchCount": { "$size": "$cursor.firstBatch" } }'::bson) AS first_page,
	:'cont'::bson IS NOT NULL AS has_more,
	:'persistent'::bool AS persistent;

SELECT cursorpage AS page, continuation IS NULL AS exhausted
FROM documentdb_api.cursor_get_more(
	'admin',
	('{ "getMore": ' || :'cid' || ', "collection": "system.roles", "batchSize": 2 }')::bson,
	:'cont'::bson) \gset

SELECT documentdb_api_catalog.bson_dollar_project(
	:'page'::bson,
	'{ "_id": 0, "batchCount": { "$size": "$cursor.nextBatch" } }'::bson) AS next_page,
	:'exhausted'::bool AS exhausted;

SELECT documentdb_api.drop_role('{"dropRole":"systemRolesChildOne", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"systemRolesChildTwo", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"systemRolesParent", "$db":"admin"}');

RESET documentdb.enableRoleCrud;
RESET documentdb.enableRolesAdminDBCheck;
RESET documentdb.enable_admin_database_queries;
