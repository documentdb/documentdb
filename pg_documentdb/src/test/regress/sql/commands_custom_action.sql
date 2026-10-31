-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

SET documentdb.next_collection_id TO 9050100;
SET documentdb.next_collection_index_id TO 9050100;

SELECT documentdb_api.custom_action(NULL);
SELECT documentdb_api.custom_action('{}');
SELECT documentdb_api.custom_action('{"customAction": 1, "$db": "admin"}');
SELECT documentdb_api.custom_action('{"customAction": "unknown"}');
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": 1}');
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": "other"}');
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": "admin\u0000other"}');
SELECT documentdb_api.custom_action('{"customAction": "unknown\u0000action", "$db": "admin"}');
SELECT documentdb_api.custom_action('{"customAction": "unknown", "customAction": "other", "$db": "admin"}');
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": "admin", "$db": "other"}');
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": "admin"}');

CREATE ROLE custom_action_nonadmin;
GRANT USAGE ON SCHEMA documentdb_api TO custom_action_nonadmin;
SET ROLE custom_action_nonadmin;
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": "admin"}');
RESET ROLE;

-- Exercise the runtime check independently of the SQL execute privilege.
GRANT EXECUTE ON FUNCTION documentdb_api.custom_action(documentdb_core.bson) TO custom_action_nonadmin;
SET ROLE custom_action_nonadmin;
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": "admin"}');
RESET ROLE;
DROP OWNED BY custom_action_nonadmin;
DROP ROLE custom_action_nonadmin;

CREATE ROLE custom_action_admin IN ROLE documentdb_admin_role;
SET ROLE custom_action_admin;
SELECT documentdb_api.custom_action('{"customAction": "unknown", "$db": "admin"}');
RESET ROLE;
DROP ROLE custom_action_admin;
