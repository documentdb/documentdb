-- Tests for roles reference table in a multinode/distributed environment
-- This file verifies that the roles table is properly replicated as a
-- reference table across all nodes in the cluster.

SET citus.next_shard_id TO 19840000;
SET documentdb.next_collection_id TO 19840;
SET documentdb.next_collection_index_id TO 19840;

SET search_path TO documentdb_core,documentdb_api_catalog,documentdb_api_internal,public;

-- =============================================================================
-- Test: Verify roles table exists and is a reference table
-- =============================================================================

-- Check that roles table exists
SELECT COUNT(*) > 0 AS roles_exists 
FROM pg_class c 
JOIN pg_namespace n ON c.relnamespace = n.oid 
WHERE n.nspname = 'documentdb_api_catalog' AND c.relname = 'roles';

-- Verify roles is distributed as a reference table (has entry in pg_dist_partition)
SELECT COUNT(*) > 0 AS is_distributed
FROM pg_dist_partition 
WHERE logicalrelid = 'documentdb_api_catalog.roles'::regclass;

-- Verify the distribution method is 'n' (reference table / none)
SELECT partmethod = 'n' AS is_reference_table
FROM pg_dist_partition 
WHERE logicalrelid = 'documentdb_api_catalog.roles'::regclass;

-- =============================================================================
-- Test: Verify roles table is replicated to worker nodes
-- =============================================================================

-- Check that roles has shards on all nodes (reference tables have one shard per node)
SELECT COUNT(*) AS shard_count
FROM pg_dist_shard
WHERE logicalrelid = 'documentdb_api_catalog.roles'::regclass;

-- Verify the shard placements exist (reference tables have placements on all nodes)
SELECT COUNT(*) > 0 AS has_placements
FROM pg_dist_shard s
JOIN pg_dist_shard_placement p ON s.shardid = p.shardid
WHERE s.logicalrelid = 'documentdb_api_catalog.roles'::regclass;

-- =============================================================================
-- Test: Verify createRole/dropRole writes reach every node
--
-- The checks above only assert the table's topology. These assert that writes
-- issued through the API on the coordinator are actually visible in the shard
-- placement on the worker, which is what makes a custom role usable from any
-- node in the cluster.
-- =============================================================================

SET documentdb.enableRoleCrud TO ON;
SET documentdb.enableRolesAdminDBCheck TO ON;

SELECT documentdb_api.create_role('{"createRole":"mn_custom_role", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- The coordinator's logical table has the row.
SELECT role_name FROM documentdb_api_catalog.roles WHERE role_name = 'mn_custom_role';

-- Every worker placement has the row too. The shard id is resolved at runtime
-- and injected with format() so the workers read the placement relation
-- directly rather than going back through the logical table.
SELECT success, result
FROM run_command_on_workers(format(
    'SELECT count(*) FROM documentdb_api_catalog.roles_%s WHERE role_name = %L',
    (SELECT shardid FROM pg_dist_shard
     WHERE logicalrelid = 'documentdb_api_catalog.roles'::regclass),
    'mn_custom_role'));

-- The stored document, not just the key, is replicated. The catalog stores the
-- original createRole command, so the name is under "createRole".
SELECT success, result
FROM run_command_on_workers(format(
    'SELECT documentdb_core.bson_get_value_text(role_bson, %L) FROM documentdb_api_catalog.roles_%s WHERE role_name = %L',
    'createRole',
    (SELECT shardid FROM pg_dist_shard
     WHERE logicalrelid = 'documentdb_api_catalog.roles'::regclass),
    'mn_custom_role'));

-- rolesInfo reports the role from the coordinator.
SELECT documentdb_api.roles_info('{"rolesInfo":"mn_custom_role", "$db":"admin"}');

-- Deletes must propagate as well, otherwise a dropped role would linger on the
-- workers and keep satisfying lookups routed there.
SELECT documentdb_api.drop_role('{"dropRole":"mn_custom_role", "$db":"admin"}');

SELECT count(*) AS coordinator_rows FROM documentdb_api_catalog.roles WHERE role_name = 'mn_custom_role';

SELECT success, result
FROM run_command_on_workers(format(
    'SELECT count(*) FROM documentdb_api_catalog.roles_%s WHERE role_name = %L',
    (SELECT shardid FROM pg_dist_shard
     WHERE logicalrelid = 'documentdb_api_catalog.roles'::regclass),
    'mn_custom_role'));
