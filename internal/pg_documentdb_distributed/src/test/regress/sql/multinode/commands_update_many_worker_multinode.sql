-- Tests for updateMany worker pushdown in a true multi-node environment.
-- Validates that update_worker calls are correctly routed to remote
-- worker nodes and results are aggregated back on the coordinator.

SET citus.next_shard_id TO 198480000;
SET documentdb.next_collection_id TO 198480;
SET documentdb.next_collection_index_id TO 198480;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- Enable the worker pushdown path
SET documentdb.enable_update_many_worker_pushdown TO ON;

-- ================================================================
-- Setup: create collection, insert docs, shard it
-- ================================================================
SELECT 1 FROM documentdb_api.insert_one('umw_mn', 'coll1', '{"_id":1, "a":1, "b":10, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umw_mn', 'coll1', '{"_id":2, "a":2, "b":20, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umw_mn', 'coll1', '{"_id":3, "a":3, "b":30, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('umw_mn', 'coll1', '{"_id":4, "a":4, "b":40, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('umw_mn', 'coll1', '{"_id":5, "a":5, "b":50, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umw_mn', 'coll1', '{"_id":6, "a":6, "b":60, "tag":"z"}');

SELECT documentdb_api.shard_collection('umw_mn', 'coll1', '{"a":"hashed"}', false);

-- ================================================================
-- 1. updateMany via worker pushdown on remote nodes: $set all docs
--    Expect: matched=6, modified=6
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{},"u":{"$set":{"c":1}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umw_mn', 'coll1') WHERE document @@ '{"c":1}';
ROLLBACK;

-- ================================================================
-- 2. updateMany via worker pushdown: $set subset (tag=y, 2 docs)
--    Expect: matched=2, modified=2
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{"tag":"y"},"u":{"$set":{"c":2}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umw_mn', 'coll1') WHERE document @@ '{"c":2}';
ROLLBACK;

-- ================================================================
-- 3. updateMany via worker pushdown: no matching docs
--    Expect: matched=0, modified=0
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{"a":999},"u":{"$set":{"c":3}},"multi":true}]}');
ROLLBACK;

-- ================================================================
-- 4. updateMany via worker pushdown: with shard key eq filter
--    Should route to a single remote shard
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{"a":{"$eq":3}},"u":{"$set":{"c":4}},"multi":true}]}');
SELECT document FROM documentdb_api.collection('umw_mn', 'coll1') WHERE document @@ '{"a":3}';
ROLLBACK;

-- ================================================================
-- 5. updateMany via worker pushdown: upsert with no match
--    Expect: matched=0, modified=0, upserted=1
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{"_id":888,"a":888},"u":{"$set":{"c":5}},"multi":true,"upsert":true}]}');
SELECT document FROM documentdb_api.collection('umw_mn', 'coll1') WHERE document @@ '{"_id":888}';
ROLLBACK;

-- ================================================================
-- 6. Verify GUC OFF falls back to CTE path on remote nodes
-- ================================================================
BEGIN;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO OFF;
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{},"u":{"$set":{"c":6}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umw_mn', 'coll1') WHERE document @@ '{"c":6}';
ROLLBACK;

-- ================================================================
-- 7. Permanent update and read-back to verify data integrity
-- ================================================================
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{},"u":{"$set":{"mn_verified":true}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umw_mn', 'coll1') WHERE document @@ '{"mn_verified":true}';

-- Cleanup
SELECT documentdb_api.drop_collection('umw_mn', 'coll1');

RESET documentdb.enable_update_many_worker_pushdown;
