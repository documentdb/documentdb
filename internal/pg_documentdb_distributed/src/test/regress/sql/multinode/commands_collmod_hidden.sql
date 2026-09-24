-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;
SET citus.next_shard_id TO 300020000;
SET documentdb.next_collection_id TO 30002000;
SET documentdb.next_collection_index_id TO 30002000;

-- Recreate the worker entry point so its OID differs from the coordinator's.
SELECT bool_and(success) AS recreated_worker_function
FROM run_command_on_workers($cmd$
DO $do$
DECLARE
    function_oid oid := 'documentdb_api_distributed.update_postgres_index_worker(documentdb_core.bson)'::regprocedure;
    function_definition text := pg_get_functiondef(function_oid);
    extension_name text;
BEGIN
    PERFORM set_config('citus.enable_ddl_propagation', 'off', true);
    SELECT extname INTO STRICT extension_name
    FROM pg_depend JOIN pg_extension ON refobjid = pg_extension.oid
    WHERE classid = 'pg_proc'::regclass AND objid = function_oid
      AND refclassid = 'pg_extension'::regclass AND deptype = 'e';
    EXECUTE format('ALTER EXTENSION %I DROP FUNCTION documentdb_api_distributed.update_postgres_index_worker(documentdb_core.bson)', extension_name);
    DROP FUNCTION documentdb_api_distributed.update_postgres_index_worker(documentdb_core.bson);
    EXECUTE function_definition;
    EXECUTE format('ALTER EXTENSION %I ADD FUNCTION documentdb_api_distributed.update_postgres_index_worker(documentdb_core.bson)', extension_name);
END;
$do$;
$cmd$);

SELECT bool_and(success AND result::oid <>
    'documentdb_api_distributed.update_postgres_index_worker(documentdb_core.bson)'::regprocedure::oid) AS worker_oids_differ
FROM run_command_on_workers($cmd$
    SELECT 'documentdb_api_distributed.update_postgres_index_worker(documentdb_core.bson)'::regprocedure::oid
$cmd$);

SELECT documentdb_api.create_collection('hide_mn', 'coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently('hide_mn',
    '{"createIndexes":"coll","indexes":[{"key":{"a":1},"name":"a_1"}]}', true);
CALL documentdb_distributed_test_helpers.place_collection_on_node('hide_mn', 'coll', 1);

-- Check both logical and shard indexes, including the coordinator with no shards.
CREATE FUNCTION documentdb_distributed_test_helpers.hidden_index_state(expected_valid boolean)
RETURNS boolean LANGUAGE SQL AS $$
    SELECT bool_and(success AND result = 't')
    FROM run_command_on_all_nodes(format($cmd$
        SELECT count(*) > 0 AND bool_and(i.indisvalid = %L::boolean AND i.indisready)
        FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
        WHERE c.relnamespace = 'documentdb_data'::regnamespace AND c.relname ~ %L
    $cmd$, expected_valid, '^documents_rum_index_' || (
        SELECT index_id FROM documentdb_api_catalog.collection_indexes
        WHERE collection_id = 30002001 AND (index_spec).index_name = 'a_1'
    ) || '(_[0-9]+)?$'));
$$;

SELECT documentdb_distributed_test_helpers.hidden_index_state(true);

-- An empty remote collection must still execute the per-node command.
SELECT documentdb_api.coll_mod('hide_mn', 'coll',
    '{"collMod":"coll","index":{"name":"a_1","hidden":true}}');
SELECT documentdb_distributed_test_helpers.hidden_index_state(false);
SELECT documentdb_api.insert_one('hide_mn', 'coll', '{"_id":1,"a":1}');
SELECT documentdb_api.coll_mod('hide_mn', 'coll',
    '{"collMod":"coll","index":{"name":"a_1","hidden":false}}');
SELECT documentdb_distributed_test_helpers.hidden_index_state(true);
SELECT document FROM bson_aggregation_find('hide_mn',
    '{"find":"coll","filter":{"a":1},"hint":"a_1"}');

SELECT documentdb_api.shard_collection(
    '{"shardCollection":"hide_mn.coll","key":{"_id":"hashed"},"numInitialChunks":4}');

SELECT documentdb_api.coll_mod('hide_mn', 'coll',
    '{"collMod":"coll","index":{"name":"a_1","hidden":true}}');
SELECT documentdb_distributed_test_helpers.hidden_index_state(false);
SELECT documentdb_api.insert_one('hide_mn', 'coll', '{"_id":2,"a":2}');
SELECT documentdb_api.coll_mod('hide_mn', 'coll',
    '{"collMod":"coll","index":{"name":"a_1","hidden":false}}');
SELECT documentdb_distributed_test_helpers.hidden_index_state(true);
SELECT document FROM bson_aggregation_find('hide_mn',
    '{"find":"coll","filter":{"a":2},"hint":"a_1"}');

-- The per-node catalog updates must roll back with the command.
BEGIN;
SELECT documentdb_api.coll_mod('hide_mn', 'coll',
    '{"collMod":"coll","index":{"name":"a_1","hidden":true}}');
ROLLBACK;
SELECT documentdb_distributed_test_helpers.hidden_index_state(true);

SELECT documentdb_api.drop_collection('hide_mn', 'coll');
DROP FUNCTION documentdb_distributed_test_helpers.hidden_index_state(boolean);
