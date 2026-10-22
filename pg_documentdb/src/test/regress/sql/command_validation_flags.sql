-- Copyright (c) DocumentDB. All rights reserved.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core, documentdb_api_catalog, documentdb_api, public;
SET documentdb.next_collection_id TO 9820000;
SET documentdb.next_collection_index_id TO 9820000;
\set VERBOSITY sqlstate

-- All five switches are registered, default on, and can be overridden.
SELECT name, setting, boot_val
FROM pg_settings
WHERE name IN (
    'documentdb.enable_bson_type_argument_validation',
    'documentdb.enable_read_concern_validation',
    'documentdb.enable_session_argument_validation',
    'documentdb.enable_getmore_argument_validation',
    'documentdb.enable_server_status_command')
ORDER BY name;

SET documentdb.enable_read_concern_validation TO off;
SET documentdb.enable_session_argument_validation TO off;
SET documentdb.enable_getmore_argument_validation TO off;
SET documentdb.enable_server_status_command TO off;
SET documentdb.enable_bson_type_argument_validation TO off;

SELECT name, setting
FROM pg_settings
WHERE name IN (
    'documentdb.enable_bson_type_argument_validation',
    'documentdb.enable_read_concern_validation',
    'documentdb.enable_session_argument_validation',
    'documentdb.enable_getmore_argument_validation',
    'documentdb.enable_server_status_command')
ORDER BY name;

-- Disabled BSON validation restores the legacy error codes and keyword support.
SELECT documentdb_api.find_and_modify('validation_flags', '{"findAndModify":42}');
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('validation_flags', '{"listIndexes":42}');
CALL documentdb_api.drop_indexes('validation_flags', '{"dropIndexes":42,"index":"a_1"}');
SELECT documentdb_api.find_and_modify('validation_flags', '{"findAndModify":"items","remove":true,"let":null}');
SELECT documentdb_api.find_and_modify('validation_flags', '{"findAndModify":"items","remove":true,"hint":{"a":1}}');
SELECT bson_dollar_json_schema('{}', '{"$jsonSchema":{"title":"valid"}}');
SELECT bson_dollar_json_schema('{"a":4}', '{"$jsonSchema":{"properties":{"a":{"multipleOf":-2}}}}');
RESET documentdb.enable_bson_type_argument_validation;
RESET documentdb.enable_read_concern_validation;
RESET documentdb.enable_session_argument_validation;
RESET documentdb.enable_getmore_argument_validation;
RESET documentdb.enable_server_status_command;

SELECT name, setting
FROM pg_settings
WHERE name IN (
    'documentdb.enable_bson_type_argument_validation',
    'documentdb.enable_read_concern_validation',
    'documentdb.enable_session_argument_validation',
    'documentdb.enable_getmore_argument_validation',
    'documentdb.enable_server_status_command')
ORDER BY name;

-- Restoring the defaults reenables the strict backend behavior.
SELECT documentdb_api.find_and_modify('validation_flags', '{"findAndModify":42}');
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('validation_flags', '{"listIndexes":42}');
CALL documentdb_api.drop_indexes('validation_flags', '{"dropIndexes":42,"index":"a_1"}');
SELECT documentdb_api.find_and_modify('validation_flags', '{"findAndModify":"items","remove":true,"let":null}');
SELECT documentdb_api.find_and_modify('validation_flags', '{"findAndModify":"items","remove":true,"hint":{"a":1}}');
SELECT bson_dollar_json_schema('{}', '{"$jsonSchema":{"title":"valid"}}');
SELECT bson_dollar_json_schema('{"a":4}', '{"$jsonSchema":{"properties":{"a":{"multipleOf":-2}}}}');
\set VERBOSITY default
