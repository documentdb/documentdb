-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

SET citus.next_shard_id TO 4590000;
SET documentdb.next_collection_id TO 45900;
SET documentdb.next_collection_index_id TO 45900;
SET documentdb_core.enableCollation TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
SET citus.enable_local_execution TO off;
SET citus.propagate_set_commands TO 'local';

-- delete command: remote worker inheritance.
SELECT documentdb_api.create_collection(
    'collation_write_mn', 'delete_remote');
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_mn'
  AND collection_name = 'delete_remote';
SELECT documentdb_api.insert(
    'collation_write_mn',
    '{
        "insert": "delete_remote",
        "documents": [
            { "_id": 1, "batch": "inherit", "value": "café" },
            { "_id": 2, "batch": "override", "value": "café" }
        ]
    }');

-- Place the unsharded collection remotely to verify the resolved default reaches the worker.
CALL documentdb_distributed_test_helpers.place_collection_on_node(
    'collation_write_mn', 'delete_remote', 1);

SELECT shard_key IS NULL AS is_unsharded
FROM documentdb_api_catalog.collections
WHERE database_name = 'collation_write_mn'
  AND collection_name = 'delete_remote';

-- Disabling collation preserves binary matching on a remote worker.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO off;
SELECT documentdb_api.delete(
    'collation_write_mn',
    '{ "delete": "delete_remote", "deletes": [
        { "q": { "batch": "inherit", "value": "CAFE" }, "limit": 0 }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_mn', 'delete_remote');
ROLLBACK;

-- The remote worker applies the inherited default and deletes the matching document.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete(
    'collation_write_mn',
    '{ "delete": "delete_remote", "deletes": [
        { "q": { "batch": "inherit", "value": "CAFE" }, "limit": 0 }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_mn', 'delete_remote')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "inherit" }';
ROLLBACK;

-- A remote unsharded mixed batch resolves the default without overriding simple.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete(
    'collation_write_mn',
    '{ "delete": "delete_remote", "ordered": false, "deletes": [
        { "q": { "batch": "inherit", "value": "CAFE" }, "limit": 0 },
        {
            "q": { "batch": "override", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "simple" }
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'delete_remote')
ORDER BY object_id;
ROLLBACK;

-- A remote unsharded BSON sequence resolves the default without overriding simple.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete(
    'collation_write_mn',
    '{ "delete": "delete_remote", "ordered": false }',
    '{ "": [
        { "q": { "batch": "inherit", "value": "CAFE" }, "limit": 0 },
        {
            "q": { "batch": "override", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "simple" }
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'delete_remote')
ORDER BY object_id;
ROLLBACK;

SELECT documentdb_api.drop_collection(
    'collation_write_mn', 'delete_remote');

-- update command: remote worker inheritance.
SELECT documentdb_api.create_collection(
    'collation_write_mn', 'update_remote');
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_mn'
  AND collection_name = 'update_remote';
SELECT documentdb_api.insert(
    'collation_write_mn',
    '{
        "insert": "update_remote",
        "documents": [
            { "_id": 1, "batch": "inherit", "value": "café" },
            { "_id": 2, "batch": "override", "value": "café" }
        ]
    }');

-- Place the unsharded collection remotely to verify the resolved default reaches the worker.
CALL documentdb_distributed_test_helpers.place_collection_on_node(
    'collation_write_mn', 'update_remote', 1);

SELECT shard_key IS NULL AS is_unsharded
FROM documentdb_api_catalog.collections
WHERE database_name = 'collation_write_mn'
  AND collection_name = 'update_remote';

-- Disabling collation preserves binary matching on a remote worker.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO off;
SELECT documentdb_api.update(
    'collation_write_mn',
    '{ "update": "update_remote", "updates": [
        {
            "q": { "batch": "inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'update_remote')
ORDER BY object_id;
ROLLBACK;

-- The remote worker applies the inherited default and updates the matching document.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update(
    'collation_write_mn',
    '{ "update": "update_remote", "updates": [
        {
            "q": { "batch": "inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'update_remote')
ORDER BY object_id;
ROLLBACK;

-- A remote unsharded mixed batch resolves the default without overriding simple.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update(
    'collation_write_mn',
    '{ "update": "update_remote", "ordered": false, "updates": [
        {
            "q": { "batch": "inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        },
        {
            "q": { "batch": "override", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "simple" }
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'update_remote')
ORDER BY object_id;
ROLLBACK;

-- A remote unsharded BSON sequence resolves the default without overriding simple.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update(
    'collation_write_mn',
    '{ "update": "update_remote", "ordered": false }',
    '{ "": [
        {
            "q": { "batch": "inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        },
        {
            "q": { "batch": "override", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "simple" }
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'update_remote')
ORDER BY object_id;
ROLLBACK;

-- findAndModify: the remote worker applies the inherited default; simple stays binary.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.find_and_modify('collation_write_mn',
    '{ "findAndModify": "update_remote", "query": { "batch": "inherit", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true }');
SELECT documentdb_api.find_and_modify('collation_write_mn',
    '{ "findAndModify": "update_remote", "query": { "batch": "override", "value": "CAFE" },
       "remove": true, "collation": { "locale": "simple" } }');
ROLLBACK;

-- findAndModify: disabling collation preserves binary matching on a remote worker.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO off;
SELECT documentdb_api.find_and_modify('collation_write_mn',
    '{ "findAndModify": "update_remote", "query": { "batch": "inherit", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true }');
ROLLBACK;

SELECT documentdb_api.drop_collection(
    'collation_write_mn', 'update_remote');

-- update_bulk: the non-transactional remote batch path resolves the default on the worker.
SELECT documentdb_api.create_collection(
    'collation_write_mn', 'update_bulk_remote');
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_mn'
  AND collection_name = 'update_bulk_remote';
SELECT documentdb_api.insert(
    'collation_write_mn',
    '{
        "insert": "update_bulk_remote",
        "documents": [
            { "_id": 1, "batch": "inherit", "value": "café" },
            { "_id": 2, "batch": "override", "value": "café" }
        ]
    }');

CALL documentdb_distributed_test_helpers.place_collection_on_node(
    'collation_write_mn', 'update_bulk_remote', 1);

-- The bulk procedure cannot run inside a transaction, so SET LOCAL is unavailable
-- and the worker setting is toggled explicitly below. Until then the worker leaves
-- collation disabled, so the bulk path stays on binary matching.
CALL documentdb_api.update_bulk(
    'collation_write_mn',
    '{ "update": "update_bulk_remote", "updates": [
        {
            "q": { "batch": "inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'update_bulk_remote')
ORDER BY object_id;

DO $$
DECLARE
    collation_nodes int;
    reloaded_nodes int;
BEGIN
    SELECT count(*) INTO collation_nodes
    FROM run_command_on_all_nodes(
        $cmd$ALTER SYSTEM SET documentdb_core.enableCollation = 'on'$cmd$)
    WHERE success;

    SELECT count(*) INTO reloaded_nodes
    FROM run_command_on_all_nodes($cmd$SELECT pg_reload_conf()$cmd$)
    WHERE success;

    IF collation_nodes <> 2 OR reloaded_nodes <> 2 THEN
        RAISE EXCEPTION 'failed to configure all nodes';
    END IF;
END
$$;

CALL documentdb_distributed_test_helpers.wait_for_command_result_on_all_nodes(
    $cmd$SHOW documentdb_core.enableCollation$cmd$, 'on');

-- A mixed bulk batch inherits the default and still honors an explicit simple override.
CALL documentdb_api.update_bulk(
    'collation_write_mn',
    '{ "update": "update_bulk_remote", "ordered": false, "updates": [
        {
            "q": { "batch": "inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        },
        {
            "q": { "batch": "override", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "simple" }
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_mn', 'update_bulk_remote')
ORDER BY object_id;

DO $$
DECLARE
    reset_collation_nodes int;
    reloaded_nodes int;
BEGIN
    SELECT count(*) INTO reset_collation_nodes
    FROM run_command_on_all_nodes(
        $cmd$ALTER SYSTEM RESET documentdb_core.enableCollation$cmd$)
    WHERE success;

    SELECT count(*) INTO reloaded_nodes
    FROM run_command_on_all_nodes($cmd$SELECT pg_reload_conf()$cmd$)
    WHERE success;

    IF reset_collation_nodes <> 2 OR reloaded_nodes <> 2 THEN
        RAISE EXCEPTION 'failed to restore all nodes';
    END IF;
END
$$;

CALL documentdb_distributed_test_helpers.wait_for_command_result_on_all_nodes(
    $cmd$SHOW documentdb_core.enableCollation$cmd$, 'off');

SELECT documentdb_api.drop_collection(
    'collation_write_mn', 'update_bulk_remote');

RESET citus.enable_local_execution;
RESET citus.propagate_set_commands;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb_core.enableCollation;
RESET search_path;
