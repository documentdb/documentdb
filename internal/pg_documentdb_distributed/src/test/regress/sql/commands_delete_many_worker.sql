-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 198480000;
SET documentdb.next_collection_id TO 1984800;
SET documentdb.next_collection_index_id TO 1984800;

-- Enable the worker path GUC for the entire test
SET documentdb.enable_delete_many_worker_pushdown TO ON;

-- ================================================================
-- Tests for deleteMany worker pushdown (enable_delete_many_worker_pushdown)
-- Validates that sharded deleteMany uses the delete_worker path and
-- returns correct deleted counts.
-- ================================================================

-- Setup: create collection, insert docs, shard it
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":1, "a":1, "b":10, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":2, "a":2, "b":20, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":3, "a":3, "b":30, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":4, "a":4, "b":40, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":5, "a":5, "b":50, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":6, "a":6, "b":60, "tag":"z"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":7, "a":7, "b":70, "tag":"z"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":8, "a":8, "b":80, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":9, "a":9, "b":90, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcoll', '{"_id":10, "a":10, "b":100, "tag":"z"}');

SELECT documentdb_api.shard_collection('dmwdb', 'dmwcoll', '{"a":"hashed"}', false);

-- ================================================================
-- 1. Basic deleteMany all docs (GUC ON by default)
--    Expect: n=10
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll');
ROLLBACK;

-- ================================================================
-- 2. deleteMany on subset
--    Expect: n=3 (tag=y has 3 docs: _id 3,4,9)
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"tag":"y"},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll');
ROLLBACK;

-- ================================================================
-- 3. deleteMany with shard key eq filter
--    Should route to a single shard
-- ================================================================
BEGIN;
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"a":{"$eq":5}},"limit":0}]}');
RESET citus.log_remote_commands;
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll') WHERE document @@ '{"a":5}';
ROLLBACK;

-- ================================================================
-- 4. deleteMany without shard key filter
--    Should fan out to all shards via delete_worker
-- ================================================================
BEGIN;
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"tag":"z"},"limit":0}]}');
RESET citus.log_remote_commands;
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll') WHERE document @@ '{"tag":"z"}';
ROLLBACK;

-- ================================================================
-- 5. deleteMany with GUC OFF - should use the coordinator (CTE) path
-- ================================================================
BEGIN;
SET LOCAL documentdb.enable_delete_many_worker_pushdown TO OFF;
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
RESET citus.log_remote_commands;
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll') WHERE document @@ '{"tag":"x"}';
ROLLBACK;

-- ================================================================
-- 6. deleteMany no matching docs
--    Expect: n=0
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"a":999},"limit":0}]}');
ROLLBACK;

-- ================================================================
-- 7. deleteMany with range filter ($gte/$lte)
--    Expect: n=5 (a >= 3 AND a <= 7)
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"a":{"$gte":3,"$lte":7}},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll');
ROLLBACK;

-- ================================================================
-- 8. deleteMany toggle GUC on/off and compare results
--    Both paths must return identical deleted counts
-- ================================================================
BEGIN;
-- With GUC ON (worker path)
SET LOCAL documentdb.enable_delete_many_worker_pushdown TO ON;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
ROLLBACK;

BEGIN;
-- With GUC OFF (CTE path)
SET LOCAL documentdb.enable_delete_many_worker_pushdown TO OFF;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"tag":"x"},"limit":0}]}');
ROLLBACK;

-- ================================================================
-- 9. deleteMany with let variables via worker path
--    Verifies let variables are preserved through the worker path
--    serialization/deserialization (variableSpec on DeleteOneParams)
--    Expect: n=3 (tag=y has 3 docs: _id 3,4,9)
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"$expr":{"$eq":["$tag","$$targetTag"]}},"limit":0}], "let":{"targetTag":"y"}}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll');
ROLLBACK;

-- ================================================================
-- 10. Batch delete: multiple delete specs in one call
--     First spec: delete tag=x (4 docs), second spec: delete tag=y (3 docs)
-- ================================================================
BEGIN;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"tag":"x"},"limit":0},{"q":{"tag":"y"},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll');
ROLLBACK;

-- ================================================================
-- 11. deleteMany with non-default collation via worker path
--     Case-insensitive collation (strength 2) must match both
--     "alpha" and "ALPHA" through the worker serialization path.
--     Expect: n=2
-- ================================================================
SET documentdb_core.enableCollation TO ON;
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcollation', '{"_id":1, "name":"alpha"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcollation', '{"_id":2, "name":"ALPHA"}');
SELECT 1 FROM documentdb_api.insert_one('dmwdb', 'dmwcollation', '{"_id":3, "name":"beta"}');
SELECT documentdb_api.shard_collection('dmwdb', 'dmwcollation', '{"name":"hashed"}', false);

BEGIN;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcollation", "deletes":[{"q":{"name":"alpha"},"limit":0,"collation":{"locale":"en","strength":2}}]}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcollation');
ROLLBACK;

-- Parity: same collation delete with the worker path OFF deletes the same docs
BEGIN;
SET LOCAL documentdb.enable_delete_many_worker_pushdown TO OFF;
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcollation", "deletes":[{"q":{"name":"alpha"},"limit":0,"collation":{"locale":"en","strength":2}}]}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcollation');
ROLLBACK;

SELECT documentdb_api.drop_collection('dmwdb', 'dmwcollation');
RESET documentdb_core.enableCollation;

-- ================================================================
-- 12. Data integrity: permanent delete and read-back
-- ================================================================
SELECT documentdb_api.delete('dmwdb', '{"delete":"dmwcoll", "deletes":[{"q":{"tag":"z"},"limit":0}]}');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll');
SELECT count(*) FROM documentdb_api.collection('dmwdb', 'dmwcoll') WHERE document @@ '{"tag":"z"}';

-- Cleanup
SELECT documentdb_api.drop_collection('dmwdb', 'dmwcoll');

-- Reset the worker path GUC
RESET documentdb.enable_delete_many_worker_pushdown;
