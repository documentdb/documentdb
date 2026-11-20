-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 3200;
SET documentdb.next_collection_index_id TO 3200;

-- ================================================================
-- Tests for deleteMany worker path via direct delete_worker calls.
-- Exercises the deleteMany serialization/deserialization on a single
-- node (non-distributed) to validate the worker function logic
-- independently of Citus distribution.
-- ================================================================

-- Setup: create collection and insert docs
SELECT 1 FROM documentdb_api.insert_one('dmw_oss', 'coll1', '{"_id":1, "a":1, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_oss', 'coll1', '{"_id":2, "a":2, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_oss', 'coll1', '{"_id":3, "a":3, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_oss', 'coll1', '{"_id":4, "a":4, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('dmw_oss', 'coll1', '{"_id":5, "a":5, "tag":"x"}');

SELECT collection_id AS dmw_coll_id FROM documentdb_api_catalog.collections
    WHERE database_name = 'dmw_oss' AND collection_name = 'coll1' \gset

-- ================================================================
-- 1. deleteMany via delete_worker: empty filter deletes all docs
--    Expect: d=5 (deleted)
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.delete_worker(
    p_collection_id => :dmw_coll_id,
    p_shard_key_value => :dmw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"deleteMany": {"query": {}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('dmw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 2. deleteMany via delete_worker: filter on tag=y (2 docs)
--    Expect: d=2
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.delete_worker(
    p_collection_id => :dmw_coll_id,
    p_shard_key_value => :dmw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"deleteMany": {"query": {"tag": "y"}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('dmw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 3. deleteMany via delete_worker: range filter a > 3 (2 docs)
--    Expect: d=2
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.delete_worker(
    p_collection_id => :dmw_coll_id,
    p_shard_key_value => :dmw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"deleteMany": {"query": {"a": {"$gt": 3}}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('dmw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 4. deleteMany via delete_worker: no matching docs
--    Expect: d=0
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.delete_worker(
    p_collection_id => :dmw_coll_id,
    p_shard_key_value => :dmw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"deleteMany": {"query": {"a": 999}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('dmw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 5. deleteMany via delete_worker: verify remaining docs after delete
--    Delete tag=x (3 docs) and confirm only tag=y docs remain.
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.delete_worker(
    p_collection_id => :dmw_coll_id,
    p_shard_key_value => :dmw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"deleteMany": {"query": {"tag": "x"}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('dmw_oss', 'coll1');
SELECT document FROM documentdb_api.collection('dmw_oss', 'coll1') ORDER BY document -> '_id';
ROLLBACK;

-- ================================================================
-- 6. End-to-end deleteMany through the public API with the worker
--    pushdown GUC enabled (single node: path falls back to the local
--    coordinator execution, result must be identical).
-- ================================================================
SET documentdb.enable_delete_many_worker_pushdown TO on;
SELECT documentdb_api.delete('dmw_oss', '{"delete":"coll1", "deletes":[{"q":{"tag":"x"}, "limit":0}]}');
SELECT document FROM documentdb_api.collection('dmw_oss', 'coll1') ORDER BY document -> '_id';
SET documentdb.enable_delete_many_worker_pushdown TO off;

-- Cleanup
SELECT documentdb_api.drop_collection('dmw_oss', 'coll1');
