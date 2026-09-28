-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

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

SELECT 1 FROM documentdb_api.insert_one(
    'umw_mn',
    'collation_effects',
    '{"_id":101,"a":101,"setValues":["Python"],"pullDirect":["Python","PYTHON","Java"],"pullAllValues":["Java","JAVA","Rust"],"minValue":"Go","maxValue":"Go","sortedValues":["10","2"],"items":[{"label":"Java","status":"old"},{"label":"Rust","status":"old"}],"pipelineValue":"Python"}');
SELECT 1 FROM documentdb_api.insert_one(
    'umw_mn',
    'collation_effects',
    '{"_id":102,"a":102,"setValues":["PYTHON"],"pullDirect":["PYTHON","Python","Rust"],"pullAllValues":["JAVA","Java","Go"],"minValue":"GO","maxValue":"GO","sortedValues":["20","4"],"items":[{"label":"JAVA","status":"old"},{"label":"Rust","status":"old"}],"pipelineValue":"PYTHON"}');
SELECT documentdb_api.shard_collection(
    'umw_mn', 'collation_effects', '{"a":"hashed"}', false);

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
-- 7. Collation-sensitive modifiers execute on remote workers
-- ================================================================
BEGIN;
SET LOCAL documentdb_core.enableCollation TO ON;
SELECT documentdb_api.update(
    'umw_mn',
    '{"update":"collation_effects","updates":[{"q":{},"u":{"$addToSet":{"setValues":"python"},"$pull":{"pullDirect":"python"},"$pullAll":{"pullAllValues":["java"]},"$min":{"minValue":"go"},"$max":{"maxValue":"go"},"$push":{"sortedValues":{"$each":["3"],"$sort":1}}},"multi":true,"collation":{"locale":"en","strength":2,"numericOrdering":true}}]}');
SELECT document
FROM documentdb_api.collection('umw_mn', 'collation_effects')
ORDER BY object_id;
ROLLBACK;

-- ================================================================
-- 8. Array filters preserve collation on remote workers
-- ================================================================
BEGIN;
SET LOCAL documentdb_core.enableCollation TO ON;
SELECT documentdb_api.update(
    'umw_mn',
    '{"update":"collation_effects","updates":[{"q":{},"u":{"$set":{"items.$[elem].status":"matched"}},"multi":true,"arrayFilters":[{"elem.label":"java"}],"collation":{"locale":"de","strength":2}}]}');
SELECT document
FROM documentdb_api.collection('umw_mn', 'collation_effects')
ORDER BY object_id;
ROLLBACK;

-- ================================================================
-- 9. Update pipelines preserve collation on remote workers
-- ================================================================
BEGIN;
SET LOCAL documentdb_core.enableCollation TO ON;
SELECT documentdb_api.update(
    'umw_mn',
    '{"update":"collation_effects","updates":[{"q":{},"u":[{"$set":{"pipelineEqual":{"$eq":["$pipelineValue","python"]}}}],"multi":true,"collation":{"locale":"fr","strength":2}}]}');
SELECT document
FROM documentdb_api.collection('umw_mn', 'collation_effects')
ORDER BY object_id;
ROLLBACK;

-- ================================================================
-- 10. Permanent update and read-back to verify data integrity
-- ================================================================
SELECT documentdb_api.update('umw_mn', '{"update":"coll1", "updates":[{"q":{},"u":{"$set":{"mn_verified":true}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umw_mn', 'coll1') WHERE document @@ '{"mn_verified":true}';

-- Cleanup
SELECT documentdb_api.drop_collection('umw_mn', 'coll1');
SELECT documentdb_api.drop_collection('umw_mn', 'collation_effects');

RESET documentdb.enable_update_many_worker_pushdown;
