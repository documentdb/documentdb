-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

-- Tests for deleteMany worker pushdown in a true multi-node environment.
-- Validates that delete_worker calls are correctly routed to remote
-- worker nodes and deleted counts are aggregated back on the coordinator.

SET citus.next_shard_id TO 198490000;
SET documentdb.next_collection_id TO 198490;
SET documentdb.next_collection_index_id TO 198490;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- Enable the worker pushdown path
SET documentdb.enable_delete_many_worker_pushdown TO ON;

-- ================================================================
-- Setup: create collection, insert docs, shard it
-- ================================================================
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'coll1', '{"_id":1, "a":1, "b":10, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'coll1', '{"_id":2, "a":2, "b":20, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'coll1', '{"_id":3, "a":3, "b":30, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'coll1', '{"_id":4, "a":4, "b":40, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'coll1', '{"_id":5, "a":5, "b":50, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'coll1', '{"_id":6, "a":6, "b":60, "tag":"z"}');

SELECT documentdb_api.shard_collection('dmw_mn', 'coll1', '{"a":"hashed"}', false);

-- ================================================================
-- 1. deleteMany via worker pushdown on remote nodes: delete all docs
--    Expect: n=6
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1');
ROLLBACK;

-- ================================================================
-- 2. deleteMany via worker pushdown: subset (tag=y, 2 docs)
--    Expect: n=2
-- ================================================================
\set VERBOSITY terse
BEGIN;
-- Open worker transactions before logging to omit transaction IDs and timestamps.
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1');
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"y"},"limit":0}]}');
SET LOCAL citus.log_remote_commands TO OFF;
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1') WHERE document @@ '{"tag":"y"}';
ROLLBACK;
\set VERBOSITY default

-- ================================================================
-- 3. deleteMany via worker pushdown: no matching docs
--    Expect: n=0
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"a":999},"limit":0}]}');
ROLLBACK;

-- ================================================================
-- 4. deleteMany via worker pushdown: with shard key eq filter
--    Should route to a single remote shard
-- ================================================================
\set VERBOSITY terse
BEGIN;
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1');
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"a":{"$eq":3}},"limit":0}]}');
SET LOCAL citus.log_remote_commands TO OFF;
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1') WHERE document @@ '{"a":3}';
ROLLBACK;
\set VERBOSITY default

-- ================================================================
-- 5. Verify GUC OFF falls back to coordinator path on remote nodes
--    Expect: n=3 (tag=x docs)
-- ================================================================
BEGIN;
SET LOCAL documentdb.enable_delete_many_worker_pushdown TO OFF;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1') WHERE document @@ '{"tag":"x"}';
ROLLBACK;

-- ================================================================
-- 6. GUC ON and OFF return identical deleted counts (parity)
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
ROLLBACK;
BEGIN;
SET LOCAL documentdb.enable_delete_many_worker_pushdown TO OFF;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
ROLLBACK;

-- ================================================================
-- 7. Range query fans out and deletes across remote shards
--    Expect: n=5 (a in [2,6])
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"a":{"$gte":2,"$lte":6}},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1');
ROLLBACK;

-- ================================================================
-- 8. Permanent delete and read-back to verify data integrity
-- ================================================================
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"z"},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1');
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1') WHERE document @@ '{"tag":"z"}';

-- ================================================================
-- 9. Non-default collation survives remote worker dispatch
--    Expect: n=2, with only beta remaining
-- ================================================================
-- Exclude coordinator placements so matching documents must cross a node boundary.
SELECT shouldhaveshards AS coordinator_had_shards FROM pg_dist_node
WHERE groupid = 0 AND noderole = 'primary' \gset
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', false)
FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'collation', '{"_id":1, "name":"alpha"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'collation', '{"_id":2, "name":"ALPHA"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_mn', 'collation', '{"_id":3, "name":"beta"}');
SELECT documentdb_api.shard_collection('dmw_mn', 'collation', '{"name":"hashed"}', false);
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', :'coordinator_had_shards'::boolean)
FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';

SELECT count(DISTINCT s.shardid) > 1 AS multiple_shards,
       bool_and(p.groupid <> 0) AS all_placements_remote
FROM documentdb_api_catalog.collections c
JOIN pg_dist_shard s ON s.logicalrelid = ('documentdb_data.documents_' || c.collection_id)::regclass
JOIN pg_dist_placement p ON p.shardid = s.shardid AND p.shardstate = 1
WHERE c.database_name = 'dmw_mn' AND c.collection_name = 'collation';

BEGIN;
SET LOCAL documentdb_core.enableCollation TO ON;
SET LOCAL plan_cache_mode TO force_generic_plan;
SET LOCAL client_min_messages TO WARNING;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"collation", "deletes":[{"q":{"name":"alpha"},"limit":0,"collation":{"locale":"en","strength":2}}]}');
SELECT document FROM documentdb_api.collection('dmw_mn', 'collation') ORDER BY object_id;
ROLLBACK;

-- Exercise cached routing and fanout with different filters and shard keys.
BEGIN;
SET LOCAL plan_cache_mode TO force_custom_plan;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"a":3},"limit":0}]}');
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"a":5},"limit":0}]}');
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"y"},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1');
ROLLBACK;

BEGIN;
SET LOCAL plan_cache_mode TO force_generic_plan;
SET LOCAL client_min_messages TO WARNING;
SET LOCAL documentdb_core.enableCollation TO ON;
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"a":3,"tag":"Y"},"limit":0,"collation":{"locale":"en","strength":2}}]}');
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"a":5},"limit":0}]}');
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
SELECT documentdb_api.delete('dmw_mn', '{"delete":"coll1", "deletes":[{"q":{"tag":"y"},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmw_mn', 'coll1');
ROLLBACK;

-- Cleanup
SELECT documentdb_api.drop_collection('dmw_mn', 'coll1');
SELECT documentdb_api.drop_collection('dmw_mn', 'collation');

RESET documentdb.enable_delete_many_worker_pushdown;
