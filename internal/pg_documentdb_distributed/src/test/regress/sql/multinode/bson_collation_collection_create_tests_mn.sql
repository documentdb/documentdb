-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core, documentdb_api, documentdb_api_catalog;
SET citus.next_shard_id TO 280400000;
SET documentdb.next_collection_id TO 28040000;
SET documentdb.next_collection_index_id TO 28040000;
SET documentdb_core.enableCollation TO on;
SET documentdb.enable_collation_with_create_collection TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.enable_collated_unique_indexes TO on;
SET documentdb.enable_composite_unique_optional_key TO on;
SET documentdb.alternate_index_handler_name TO 'extended_rum';
SET citus.enable_local_execution TO off;

-- Remote connections need the same collation capabilities as the coordinator.
DO $$
DECLARE
    parameter_name text;
    configured boolean;
BEGIN
    FOREACH parameter_name IN ARRAY ARRAY[
        'documentdb_core.enableCollation',
        'documentdb.enable_collation_with_create_collection',
        'documentdb.enableCollationWithNonUniqueOrderedIndexes',
        'documentdb.enable_collated_unique_indexes',
        'documentdb.enable_composite_unique_optional_key']
    LOOP
        SELECT bool_and(success) INTO configured FROM run_command_on_all_nodes(
            format('ALTER SYSTEM SET %s = on', parameter_name));
        IF configured IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'Failed to configure % on all nodes', parameter_name;
        END IF;
    END LOOP;
    SELECT bool_and(success) INTO configured
        FROM run_command_on_all_nodes('SELECT pg_reload_conf()');
    IF configured IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Failed to reload all nodes';
    END IF;
    FOREACH parameter_name IN ARRAY ARRAY[
        'documentdb_core.enableCollation',
        'documentdb.enable_collation_with_create_collection',
        'documentdb.enableCollationWithNonUniqueOrderedIndexes',
        'documentdb.enable_collated_unique_indexes',
        'documentdb.enable_composite_unique_optional_key']
    LOOP
        CALL documentdb_distributed_test_helpers.wait_for_command_result_on_all_nodes(
            format('SHOW %s', parameter_name), 'on');
    END LOOP;
END
$$;

-- Exclude coordinator storage so both placement modes exercise real worker backings.
CREATE TEMP TABLE collated_creation_coordinator_placement AS
    SELECT nodename, nodeport, shouldhaveshards FROM pg_dist_node WHERE groupid = 0;
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', false)
    FROM collated_creation_coordinator_placement;
SET documentdb.enableNativeColocation TO off;
SELECT documentdb_api.create_collection_view('collated_creation_mn_legacy',
    '{"create":"ids","collation":{"locale":"en","strength":2}}');
SET documentdb.enableNativeColocation TO on;
SELECT documentdb_api.create_collection_with_options('collated_creation_mn_native', 'ids',
    '{"collation":{"locale":"fr","strength":1}}');
CALL documentdb_distributed_test_helpers.place_collection_on_node(
    'collated_creation_mn_native', 'ids', 1);

SELECT database_name, p.partmethod,
    bool_and(n.groupid <> 0) AS placed_on_worker,
    (SELECT count(*) FROM documentdb_api_catalog.collection_indexes i
        WHERE i.collection_id = c.collection_id) AS logical_indexes
FROM documentdb_api_catalog.collections c
JOIN pg_dist_partition p ON p.logicalrelid =
    ('documentdb_data.documents_' || c.collection_id)::regclass
JOIN pg_dist_shard s ON s.logicalrelid = p.logicalrelid
    AND s.shardid = CASE WHEN p.partmethod = 'h' THEN
        get_shard_id_for_distribution_column(p.logicalrelid, c.collection_id)
        ELSE s.shardid END
JOIN pg_dist_shard_placement sp ON sp.shardid = s.shardid
JOIN pg_dist_node n ON n.nodename = sp.nodename AND n.nodeport = sp.nodeport
WHERE c.database_name IN ('collated_creation_mn_legacy','collated_creation_mn_native')
    AND c.collection_name = 'ids' AND sp.shardstate = 1 AND n.isactive
GROUP BY database_name, p.partmethod, c.collection_id
ORDER BY database_name;

-- Enforce collated uniqueness and resolve hinted matches through remote execution.
SELECT documentdb_api.insert_one('collated_creation_mn_legacy', 'ids', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation_mn_legacy', 'ids', '{"_id":"ALPHA"}');
SELECT documentdb_api.insert_one('collated_creation_mn_native', 'ids', '{"_id":"Cafe"}');
SELECT documentdb_api.insert_one('collated_creation_mn_native', 'ids', '{"_id":"CAF\u00c9"}');
SELECT document FROM bson_aggregation_find('collated_creation_mn_legacy',
    '{"find":"ids","filter":{"_id":"ALPHA"},"hint":"_id_"}');
SELECT document FROM bson_aggregation_find('collated_creation_mn_native',
    '{"find":"ids","filter":{"_id":"caf\u00e9"},"hint":"_id_"}');
SELECT documentdb_api.validate('collated_creation_mn_legacy', '{"validate":"ids"}');
SELECT documentdb_api.validate('collated_creation_mn_native', '{"validate":"ids"}');
-- Forward raw options even when creation-time collation is disabled on the worker.
SELECT bool_and(success) AS forwarded_success FROM run_command_on_workers($cmd$
    SET documentdb.enable_collation_with_create_collection TO off;
    SELECT documentdb_api.create_collection_with_options('collated_creation_mn_forwarded', 'ids',
        '{"collation":{"locale":"en","strength":2}}')
$cmd$);
SELECT count(*) AS forwarded_collections FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation_mn_forwarded' AND collection_name = 'ids';
SELECT documentdb_api.insert_one('collated_creation_mn_forwarded', 'ids', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation_mn_forwarded', 'ids', '{"_id":"ALPHA"}');
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page(
    'collated_creation_mn_forwarded', '{"listIndexes":"ids"}');

-- Restore node placement and configuration before other multinode tests run.
SELECT documentdb_api.drop_collection('collated_creation_mn_legacy', 'ids');
SELECT documentdb_api.drop_collection('collated_creation_mn_native', 'ids');
SELECT documentdb_api.drop_collection('collated_creation_mn_forwarded', 'ids');
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', shouldhaveshards)
    FROM collated_creation_coordinator_placement;
DROP TABLE collated_creation_coordinator_placement;
DO $$
DECLARE
    parameter_name text;
    configured boolean;
BEGIN
    FOREACH parameter_name IN ARRAY ARRAY[
        'documentdb_core.enableCollation',
        'documentdb.enable_collation_with_create_collection',
        'documentdb.enableCollationWithNonUniqueOrderedIndexes',
        'documentdb.enable_collated_unique_indexes',
        'documentdb.enable_composite_unique_optional_key']
    LOOP
        SELECT bool_and(success) INTO configured FROM run_command_on_all_nodes(
            format('ALTER SYSTEM RESET %s', parameter_name));
        IF configured IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'Failed to reset % on all nodes', parameter_name;
        END IF;
    END LOOP;
    SELECT bool_and(success) INTO configured
        FROM run_command_on_all_nodes('SELECT pg_reload_conf()');
    IF configured IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Failed to reload all nodes';
    END IF;
END
$$;
RESET documentdb.enableNativeColocation;
RESET citus.enable_local_execution;
RESET documentdb.alternate_index_handler_name;
RESET documentdb_core.enableCollation;
RESET documentdb.enable_collation_with_create_collection;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.enable_collated_unique_indexes;
RESET documentdb.enable_composite_unique_optional_key;
