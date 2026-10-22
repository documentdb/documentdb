-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

SET citus.next_shard_id TO 259000000;
SET documentdb.next_collection_id TO 25900000;
SET documentdb.next_collection_index_id TO 25900000;
SET documentdb_core.enableCollation TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
SET citus.enable_local_execution TO off;

-- Inject defaults after sharding to isolate write routing from shard-command validation.
-- delete command: sharded routing under an inherited default.
SELECT documentdb_api.create_collection(
    'collation_write_dist', 'delete_sharded_numeric');
SELECT documentdb_api.shard_collection(
    'collation_write_dist', 'delete_sharded_numeric', '{ "sk": "hashed" }', false);
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_dist'
  AND collection_name = 'delete_sharded_numeric';
SELECT documentdb_api.insert(
    'collation_write_dist',
    '{
        "insert": "delete_sharded_numeric",
        "documents": [
            { "_id": 1, "sk": 1, "value": "café" },
            { "_id": 2, "sk": 2, "value": "café" }
        ]
    }');

-- Numeric shard-key routing remains targetable for inherited deleteMany and deleteOne.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete(
    'collation_write_dist',
    '{ "delete": "delete_sharded_numeric", "deletes": [
        { "q": { "sk": 1, "value": "CAFE" }, "limit": 0 }
    ] }');
SELECT documentdb_api.delete(
    'collation_write_dist',
    '{ "delete": "delete_sharded_numeric", "deletes": [
        { "q": { "sk": 2, "value": "CAFE" }, "limit": 1 }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_dist', 'delete_sharded_numeric');
ROLLBACK;

SELECT documentdb_api.create_collection(
    'collation_write_dist', 'delete_sharded_string');
SELECT documentdb_api.shard_collection(
    'collation_write_dist', 'delete_sharded_string', '{ "sk": "hashed" }', false);
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_dist'
  AND collection_name = 'delete_sharded_string';
SELECT documentdb_api.insert(
    'collation_write_dist',
    '{
        "insert": "delete_sharded_string",
        "documents": [
            { "_id": 1, "sk": "café" },
            { "_id": 2, "sk": "tea" }
        ]
    }');

-- A collation-sensitive shard key distributes deleteMany and uses _id for deleteOne.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete(
    'collation_write_dist',
    '{ "delete": "delete_sharded_string", "deletes": [
        { "q": { "sk": "CAFE" }, "limit": 0 }
    ] }');
SELECT documentdb_api.delete(
    'collation_write_dist',
    '{ "delete": "delete_sharded_string", "deletes": [
        { "q": { "_id": 2, "sk": "TEA" }, "limit": 1 }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_dist', 'delete_sharded_string');
ROLLBACK;

SELECT documentdb_api.drop_collection(
    'collation_write_dist', 'delete_sharded_numeric');
SELECT documentdb_api.drop_collection(
    'collation_write_dist', 'delete_sharded_string');

-- update command: sharded routing under an inherited default.
SELECT documentdb_api.create_collection(
    'collation_write_dist', 'update_sharded_numeric');
SELECT documentdb_api.shard_collection(
    'collation_write_dist', 'update_sharded_numeric', '{ "sk": "hashed" }', false);
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_dist'
  AND collection_name = 'update_sharded_numeric';
SELECT documentdb_api.insert(
    'collation_write_dist',
    '{
        "insert": "update_sharded_numeric",
        "documents": [
            { "_id": 1, "sk": 1, "value": "café" },
            { "_id": 2, "sk": 2, "value": "café" }
        ]
    }');

-- Numeric shard-key routing remains targetable for inherited multi and single updates.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update(
    'collation_write_dist',
    '{ "update": "update_sharded_numeric", "updates": [
        {
            "q": { "sk": 1, "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT documentdb_api.update(
    'collation_write_dist',
    '{ "update": "update_sharded_numeric", "updates": [
        { "q": { "sk": 2, "value": "CAFE" }, "u": { "$set": { "hit": true } } }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_dist', 'update_sharded_numeric')
ORDER BY object_id;
ROLLBACK;

SELECT documentdb_api.create_collection(
    'collation_write_dist', 'update_sharded_string');
SELECT documentdb_api.shard_collection(
    'collation_write_dist', 'update_sharded_string', '{ "sk": "hashed" }', false);
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_dist'
  AND collection_name = 'update_sharded_string';
SELECT documentdb_api.insert(
    'collation_write_dist',
    '{
        "insert": "update_sharded_string",
        "documents": [
            { "_id": 1, "sk": "café" },
            { "_id": 2, "sk": "tea" }
        ]
    }');

-- A collation-sensitive shard key distributes multi updates and uses _id for single updates.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update(
    'collation_write_dist',
    '{ "update": "update_sharded_string", "updates": [
        {
            "q": { "sk": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT documentdb_api.update(
    'collation_write_dist',
    '{ "update": "update_sharded_string", "updates": [
        { "q": { "_id": 2, "sk": "TEA" }, "u": { "$set": { "hit": true } } }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_dist', 'update_sharded_string')
ORDER BY object_id;
ROLLBACK;

-- findAndModify: numeric shard-key routing remains targetable under an inherited default.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.find_and_modify('collation_write_dist',
    '{ "findAndModify": "update_sharded_numeric", "query": { "sk": 1, "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true }');
SELECT documentdb_api.find_and_modify('collation_write_dist',
    '{ "findAndModify": "update_sharded_numeric", "query": { "sk": 2, "value": "CAFE" },
       "remove": true }');
ROLLBACK;

-- findAndModify: an inherited default on a string shard key cannot target one shard,
-- while explicit simple collation still routes with binary semantics.
SELECT documentdb_api.find_and_modify('collation_write_dist',
    '{ "findAndModify": "update_sharded_string", "query": { "sk": "café" },
       "update": { "$set": { "hit": true } }, "new": true }');
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.find_and_modify('collation_write_dist',
    '{ "findAndModify": "update_sharded_string", "query": { "sk": "café" },
       "update": { "$set": { "hit": true } }, "new": true,
       "collation": { "locale": "simple" } }');
ROLLBACK;

SELECT documentdb_api.drop_collection(
    'collation_write_dist', 'update_sharded_numeric');
SELECT documentdb_api.drop_collection(
    'collation_write_dist', 'update_sharded_string');

RESET citus.enable_local_execution;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb_core.enableCollation;
RESET search_path;
