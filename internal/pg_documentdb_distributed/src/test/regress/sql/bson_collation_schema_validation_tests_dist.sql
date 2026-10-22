-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,pg_catalog;

SET citus.next_shard_id TO 271301000;
SET documentdb.next_collection_id TO 27130100;
SET documentdb.next_collection_index_id TO 27130100;
SET documentdb_core.enableCollation TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
SET citus.enable_local_execution TO off;

SELECT documentdb_api.create_collection_view(
    'collation_schema_validation_dist_db',
    '{"create":"validator_update","validator":{"$expr":{"$eq":["$value","cafe"]}},"validationAction":"error"}');
SELECT documentdb_api.shard_collection(
    'collation_schema_validation_dist_db', 'validator_update', '{ "_id": "hashed" }', false);
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"fr","strength":1}}'::documentdb_core.bson
WHERE database_name = 'collation_schema_validation_dist_db' AND collection_name = 'validator_update';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.insert(
    'collation_schema_validation_dist_db',
    '{"insert":"validator_update","documents":[{"_id":1,"value":"cafe"},{"_id":2,"value":"cafe"}]}');

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enable_collation_with_schema_validation TO off;
SELECT documentdb_api.update(
    'collation_schema_validation_dist_db',
    '{"update":"validator_update","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"value":"CAFÉ"}},"multi":true}]}');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enable_collation_with_schema_validation TO on;
SELECT documentdb_api.update(
    'collation_schema_validation_dist_db',
    '{"update":"validator_update","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"value":"CAFÉ"}},"multi":true,"collation":{"locale":"simple"}}]}');
SELECT documentdb_api.update(
    'collation_schema_validation_dist_db',
    '{"update":"validator_update","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"value":"different"}},"multi":true}]}');
SELECT document FROM bson_aggregation_find(
    'collation_schema_validation_dist_db',
    '{"find":"validator_update","sort":{"_id":1}}');
END;

RESET citus.enable_local_execution;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb_core.enableCollation;
RESET search_path;
