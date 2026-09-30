-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

-- Hiding an index when every shard of the collection lives on the coordinator
-- and the worker node holds no placement for it.
--
-- Hiding an index clears indisvalid on the underlying Postgres index. The per
-- node command used to be dispatched as a query over the shards of the
-- collection, so Citus routed it only to the nodes holding a shard placement,
-- plus a backfill on the coordinator. Every node also has the Citus shell
-- table documentdb_data.documents_<collection_id> and its index, created by
-- DDL propagation, regardless of where the placements live. A node holding no
-- placement therefore never ran the command and its shell table index kept
-- indisvalid = true, leaving the nodes disagreeing about the hidden state.
--
-- This test pins the invariant that every node in the cluster observes the
-- same hidden state, including a node that holds no placement for the
-- collection being modified.

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;
SET citus.next_shard_id TO 300040000;
SET documentdb.next_collection_id TO 30004000;
SET documentdb.next_collection_index_id TO 30004000;

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

SELECT count(*) AS worker_node_count
FROM pg_dist_node WHERE groupid <> 0 AND noderole = 'primary';

-- Create the collection and the index on the coordinator.
SELECT documentdb_api.create_collection('hide_np', 'coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently('hide_np',
    '{"createIndexes":"coll","indexes":[{"key":{"a":1},"name":"a_1"}]}', true);
SELECT documentdb_api.insert_one('hide_np', 'coll', '{"_id":1,"a":1}');

-- Placements can only be moved onto the coordinator when it is marked as a
-- node that should hold shards. Remember the current setting so the cluster is
-- left untouched for the tests that run after this one.
DO $setup$
DECLARE
    coordinator record;
BEGIN
    SELECT nodename, nodeport, shouldhaveshards INTO STRICT coordinator
    FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';

    PERFORM set_config('documentdb_test.coordinator_had_shards',
                       coordinator.shouldhaveshards::text, false);
    PERFORM citus_set_node_property(coordinator.nodename, coordinator.nodeport,
                                    'shouldhaveshards', true);
END;
$setup$;

-- Move every placement onto the coordinator, leaving the worker node with only
-- the shell table.
CALL documentdb_distributed_test_helpers.place_collection_on_node('hide_np', 'coll', 0);

-- Reports, per node, how many placements the node holds for the collection and
-- the state of the index on the shell table. The shard tables are deliberately
-- not reported: a shard that has been moved away can linger on the old node
-- until Citus runs deferred cleanup, which makes it nondeterministic.
CREATE FUNCTION documentdb_distributed_test_helpers.hidden_index_by_node(
    p_collection_name text)
RETURNS TABLE (node text, shard_placements bigint, shell_table_index text)
LANGUAGE plpgsql AS $function$
DECLARE
    v_collection_id bigint;
    v_index_id bigint;
    v_relid oid;
BEGIN
    SELECT collection_id INTO STRICT v_collection_id
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'hide_np' AND collection_name = p_collection_name;

    SELECT index_id INTO STRICT v_index_id
    FROM documentdb_api_catalog.collection_indexes
    WHERE collection_id = v_collection_id AND (index_spec).index_name = 'a_1';

    v_relid := format('documentdb_data.documents_%s', v_collection_id)::regclass;

    RETURN QUERY
    WITH per_node AS (
        SELECT n.nodeid, n.result AS shell_state
        FROM run_command_on_all_nodes(format($cmd$
            SELECT coalesce((SELECT CASE WHEN i.indisvalid THEN 'valid' ELSE 'hidden' END
                             FROM pg_catalog.pg_index i
                             JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
                             WHERE c.relnamespace = 'documentdb_data'::regnamespace
                               AND c.relname = 'documents_rum_index_%s'), 'absent')
        $cmd$, v_index_id)) n
    ),
    placements AS (
        SELECT d.groupid, count(p.placementid) AS placement_count
        FROM pg_dist_node d
        LEFT JOIN pg_dist_placement p
               ON p.groupid = d.groupid
              AND p.shardstate = 1
              AND p.shardid IN (SELECT shardid FROM pg_dist_shard WHERE logicalrelid = v_relid)
        WHERE d.noderole = 'primary'
        GROUP BY d.groupid
    )
    SELECT CASE WHEN d.groupid = 0 THEN 'coordinator' ELSE 'worker' || d.groupid END,
           pl.placement_count,
           pn.shell_state
    FROM pg_dist_node d
    JOIN per_node pn ON pn.nodeid = d.nodeid
    JOIN placements pl ON pl.groupid = d.groupid
    WHERE d.noderole = 'primary'
    ORDER BY d.groupid;
END;
$function$;

-- Baseline: the index is visible on every node, and only the coordinator holds
-- a placement.
SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll');

-- Hide the index from the coordinator.
SELECT documentdb_api.coll_mod('hide_np', 'coll',
    '{"collMod":"coll","index":{"name":"a_1","hidden":true}}');

-- Every node must report 'hidden', including worker1, which holds no
-- placement and only has the shell table.
SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll');

-- Restated as a single assertion over every node in the cluster.
SELECT bool_and(shell_table_index = 'hidden') AS all_nodes_agree_hidden
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll');

-- The nodes that hold a placement must agree as well.
SELECT bool_and(shell_table_index = 'hidden') AS nodes_with_command_agree_hidden
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll')
WHERE shard_placements > 0;

-- Reads still work: they are routed to the placement on the coordinator, whose
-- shard indexes were hidden.
SELECT document FROM bson_aggregation_find('hide_np',
    '{"find":"coll","filter":{"a":1}}');

-- Unhide and confirm the same set of nodes is updated in the other direction.
SELECT documentdb_api.coll_mod('hide_np', 'coll',
    '{"collMod":"coll","index":{"name":"a_1","hidden":false}}');

SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll');

SELECT bool_and(shell_table_index = 'valid') AS all_nodes_agree_valid
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll');

SELECT document FROM bson_aggregation_find('hide_np',
    '{"find":"coll","filter":{"a":1},"hint":"a_1"}');

-- Drop the collection that was pinned to the coordinator and hand the
-- coordinator back its original placement policy, so that the scenario below
-- runs against a coordinator that holds no shards of its own.
SELECT documentdb_api.drop_collection('hide_np', 'coll');

-- Restore the coordinator placement policy.
DO $cleanup$
DECLARE
    coordinator record;
BEGIN
    SELECT nodename, nodeport INTO STRICT coordinator
    FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';

    PERFORM citus_set_node_property(
        coordinator.nodename, coordinator.nodeport, 'shouldhaveshards',
        current_setting('documentdb_test.coordinator_had_shards')::boolean);
END;
$cleanup$;

-- Does the coordinator still hold shard placements of other distributed
-- tables? The scenario below reaches the coordinator through one of those
-- colocated tables, so it only behaves as described while this is true. The
-- exact count depends on which tests ran before this one, so only report
-- whether any placement exists.
SELECT count(p.placementid) > 0 AS coordinator_holds_other_placements
FROM pg_dist_node d
LEFT JOIN pg_dist_placement p ON p.groupid = d.groupid AND p.shardstate = 1
WHERE d.groupid = 0 AND d.noderole = 'primary';

---------------------------------------------------------------------
-- Inverse direction: the collection is placed on worker node 1 and the
-- collMod is issued on worker node 1 itself, rather than on the coordinator.
--
-- This is the case where the coordinator holds no placement for the collection
-- and cannot fall back to running the command locally either, because the
-- backfill is guarded by IsMetadataCoordinator() and the command originates on
-- a worker. The coordinator is still reached, because the per node dispatch
-- runs over a colocated table that does have placements on the coordinator.
-- Both nodes must therefore agree on the hidden state.
---------------------------------------------------------------------

SELECT documentdb_api.create_collection('hide_np', 'coll_worker');
SELECT documentdb_api_internal.create_indexes_non_concurrently('hide_np',
    '{"createIndexes":"coll_worker","indexes":[{"key":{"a":1},"name":"a_1"}]}', true);
SELECT documentdb_api.insert_one('hide_np', 'coll_worker', '{"_id":1,"a":1}');

CALL documentdb_distributed_test_helpers.place_collection_on_node('hide_np', 'coll_worker', 1);

-- Baseline: only worker1 holds a placement and the index is visible everywhere.
SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_worker');

-- Hide the index by running collMod on worker node 1 itself. The node name and
-- port are not printed because they vary between runs.
SELECT bool_and(success) AS ran_on_worker, min(result) AS worker_result
FROM run_command_on_workers($cmd$
    SELECT documentdb_api.coll_mod('hide_np', 'coll_worker',
        '{"collMod":"coll_worker","index":{"name":"a_1","hidden":true}}')::text
$cmd$);

-- Both nodes must report 'hidden'. A disagreement here means the node that
-- issued the command did not propagate the change to the coordinator.
SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_worker');

SELECT bool_and(shell_table_index = 'hidden') AS all_nodes_agree_hidden_from_worker
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_worker');

-- Unhide from the same worker node and confirm both nodes agree again.
SELECT bool_and(success) AS ran_on_worker, min(result) AS worker_result
FROM run_command_on_workers($cmd$
    SELECT documentdb_api.coll_mod('hide_np', 'coll_worker',
        '{"collMod":"coll_worker","index":{"name":"a_1","hidden":false}}')::text
$cmd$);

SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_worker');

SELECT bool_and(shell_table_index = 'valid') AS all_nodes_agree_valid_from_worker
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_worker');

SELECT documentdb_api.drop_collection('hide_np', 'coll_worker');


---------------------------------------------------------------------
-- The coordinator holds no placement of any table.
--
-- The scenario above still reached the coordinator, because the dispatch runs
-- over a colocated table and the coordinator happened to hold placements of
-- other collections. Once every non reference placement is moved off the
-- coordinator, there is no table to dispatch over, and the only remaining path
-- to the coordinator is the backfill, which is guarded by
-- IsMetadataCoordinator(). A collMod issued on a worker therefore has no way
-- to reach the coordinator at all.
--
-- KNOWN INCORRECT BEHAVIOR, ASSERTED BELOW AS IT EXISTS TODAY:
-- the coordinator keeps reporting 'valid' while worker1 reports 'hidden'.
-- This is the topology a drained coordinator has in a real deployment. When
-- the propagation is fixed, the coordinator row flips to 'hidden',
-- all_nodes_agree_hidden_drained becomes true, and this expected output has to
-- be regenerated.
---------------------------------------------------------------------

SELECT documentdb_api.create_collection('hide_np', 'coll_drained');
SELECT documentdb_api_internal.create_indexes_non_concurrently('hide_np',
    '{"createIndexes":"coll_drained","indexes":[{"key":{"a":1},"name":"a_1"}]}', true);
SELECT documentdb_api.insert_one('hide_np', 'coll_drained', '{"_id":1,"a":1}');

CALL documentdb_distributed_test_helpers.place_collection_on_node('hide_np', 'coll_drained', 1);

-- Remember which placements are moved so they can be put back afterwards, and
-- move every non reference placement off the coordinator. Reference tables are
-- present on every node and cannot be moved.
CREATE TEMP TABLE drained_shards AS
SELECT p.shardid
FROM pg_dist_placement p
JOIN pg_dist_shard s ON s.shardid = p.shardid
JOIN pg_dist_partition pt ON pt.logicalrelid = s.logicalrelid
JOIN pg_dist_colocation cl ON cl.colocationid = pt.colocationid
WHERE p.groupid = 0 AND p.shardstate = 1 AND cl.replicationfactor <> -1;

SET client_min_messages TO ERROR;
DO $drain$
DECLARE
    shard record;
    coordinator record;
    worker record;
BEGIN
    SELECT nodename, nodeport INTO STRICT coordinator
    FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';
    SELECT nodename, nodeport INTO STRICT worker
    FROM pg_dist_node WHERE groupid = 1 AND noderole = 'primary';

    PERFORM citus_set_node_property(coordinator.nodename, coordinator.nodeport,
                                    'shouldhaveshards', false);

    FOR shard IN SELECT shardid FROM drained_shards LOOP
        PERFORM citus_move_shard_placement(
            shard.shardid, coordinator.nodename, coordinator.nodeport,
            worker.nodename, worker.nodeport, shard_transfer_mode => 'block_writes');
    END LOOP;
END;
$drain$;
RESET client_min_messages;

-- The coordinator now holds nothing that the per node dispatch can run over.
SELECT count(*) AS coordinator_non_reference_placements
FROM pg_dist_placement p
JOIN pg_dist_shard s ON s.shardid = p.shardid
JOIN pg_dist_partition pt ON pt.logicalrelid = s.logicalrelid
JOIN pg_dist_colocation cl ON cl.colocationid = pt.colocationid
WHERE p.groupid = 0 AND p.shardstate = 1 AND cl.replicationfactor <> -1;

-- A command issued on the coordinator must still update its shell index
-- through the local backfill when no documents_* relation can route to it.
SELECT documentdb_api.coll_mod('hide_np', 'coll_drained',
    '{"collMod":"coll_drained","index":{"name":"a_1","hidden":true}}');

SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_drained');

SELECT bool_and(shell_table_index = 'hidden') AS all_nodes_agree_hidden_from_drained_coordinator
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_drained');

SELECT documentdb_api.coll_mod('hide_np', 'coll_drained',
    '{"collMod":"coll_drained","index":{"name":"a_1","hidden":false}}');

SELECT bool_and(shell_table_index = 'valid') AS all_nodes_agree_valid_from_drained_coordinator
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_drained');

-- Hide the index by running collMod on worker node 1.
SELECT bool_and(success) AS ran_on_worker, min(result) AS worker_result
FROM run_command_on_workers($cmd$
    SELECT documentdb_api.coll_mod('hide_np', 'coll_drained',
        '{"collMod":"coll_drained","index":{"name":"a_1","hidden":true}}')::text
$cmd$);

-- TODO: Fix worker-originated propagation to a placement-free coordinator.
-- The coordinator remains valid while worker1 becomes hidden.
SELECT * FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_drained');

SELECT bool_and(shell_table_index = 'hidden') AS all_nodes_agree_hidden_drained
FROM documentdb_distributed_test_helpers.hidden_index_by_node('coll_drained');

-- Put the cluster back the way it was found.
SET client_min_messages TO ERROR;
DO $refill$
DECLARE
    shard record;
    coordinator record;
    worker record;
BEGIN
    SELECT nodename, nodeport INTO STRICT coordinator
    FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';
    SELECT nodename, nodeport INTO STRICT worker
    FROM pg_dist_node WHERE groupid = 1 AND noderole = 'primary';

    PERFORM citus_set_node_property(coordinator.nodename, coordinator.nodeport,
                                    'shouldhaveshards', true);

    FOR shard IN SELECT shardid FROM drained_shards LOOP
        PERFORM citus_move_shard_placement(
            shard.shardid, worker.nodename, worker.nodeport,
            coordinator.nodename, coordinator.nodeport,
            shard_transfer_mode => 'block_writes');
    END LOOP;

    PERFORM citus_set_node_property(
        coordinator.nodename, coordinator.nodeport, 'shouldhaveshards',
        current_setting('documentdb_test.coordinator_had_shards')::boolean);
END;
$refill$;
RESET client_min_messages;

DROP TABLE drained_shards;
SELECT documentdb_api.drop_collection('hide_np', 'coll_drained');

DROP FUNCTION documentdb_distributed_test_helpers.hidden_index_by_node(text);
