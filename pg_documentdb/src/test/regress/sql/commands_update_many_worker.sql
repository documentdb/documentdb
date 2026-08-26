SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 2300;
SET documentdb.next_collection_index_id TO 2300;

-- ================================================================
-- Tests for updateMany worker path via direct update_worker calls.
-- Exercises the updateMany serialization/deserialization on a single
-- node (non-distributed) to validate the worker function logic
-- independently of Citus distribution.
-- ================================================================

-- Setup: create collection and insert docs
SELECT 1 FROM documentdb_api.insert_one('umw_oss', 'coll1', '{"_id":1, "a":1, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umw_oss', 'coll1', '{"_id":2, "a":2, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umw_oss', 'coll1', '{"_id":3, "a":3, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('umw_oss', 'coll1', '{"_id":4, "a":4, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('umw_oss', 'coll1', '{"_id":5, "a":5, "tag":"x"}');

SELECT collection_id AS umw_coll_id FROM documentdb_api_catalog.collections
    WHERE database_name = 'umw_oss' AND collection_name = 'coll1' \gset

-- ================================================================
-- 1. updateMany via update_worker: $set on all docs
--    Expect: m=5 (matched), d=5 (modified)
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.update_worker(
    p_collection_id => :umw_coll_id,
    p_shard_key_value => :umw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"updateMany": {"query": {}, "update": {"$set": {"c": 1}}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('umw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 2. updateMany via update_worker: $set on subset (tag=y, 2 docs)
--    Expect: m=2, d=2
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.update_worker(
    p_collection_id => :umw_coll_id,
    p_shard_key_value => :umw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"updateMany": {"query": {"tag": "y"}, "update": {"$set": {"c": 2}}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('umw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 3. updateMany via update_worker: $inc on all docs
--    Expect: m=5, d=5
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.update_worker(
    p_collection_id => :umw_coll_id,
    p_shard_key_value => :umw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"updateMany": {"query": {}, "update": {"$inc": {"a": 10}}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('umw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 4. updateMany via update_worker: idempotent $set (no actual modification)
--    Expect: m=3, d=0 (tag=x already set on 3 docs)
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.update_worker(
    p_collection_id => :umw_coll_id,
    p_shard_key_value => :umw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"updateMany": {"query": {"tag": "x"}, "update": {"$set": {"tag": "x"}}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('umw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 5. updateMany via update_worker: no matching docs
--    Expect: m=0, d=0
-- ================================================================
BEGIN;
SELECT documentdb_api_internal.update_worker(
    p_collection_id => :umw_coll_id,
    p_shard_key_value => :umw_coll_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"updateMany": {"query": {"a": 999}, "update": {"$set": {"c": 5}}}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('umw_oss', 'coll1');
ROLLBACK;

-- ================================================================
-- 6. updateMany via update_worker: with arrayFilters
-- ================================================================
SELECT 1 FROM documentdb_api.insert_one('umw_oss', 'coll_af', '{"_id":1, "items":[{"name":"p1","qty":5},{"name":"p2","qty":15}]}');
SELECT 1 FROM documentdb_api.insert_one('umw_oss', 'coll_af', '{"_id":2, "items":[{"name":"p3","qty":25},{"name":"p4","qty":3}]}');

SELECT collection_id AS umw_af_id FROM documentdb_api_catalog.collections
    WHERE database_name = 'umw_oss' AND collection_name = 'coll_af' \gset

BEGIN;
SELECT documentdb_api_internal.update_worker(
    p_collection_id => :umw_af_id,
    p_shard_key_value => :umw_af_id,
    p_shard_oid => 0,
    p_update_internal_spec => '{"updateMany": {"query": {}, "update": {"$set": {"items.$[elem].status": "low"}}, "arrayFilters": [{"elem.qty": {"$lt": 10}}]}}'::bson,
    p_update_internal_docs => null::bsonsequence,
    p_transaction_id => null::text
) FROM documentdb_api.collection('umw_oss', 'coll_af');
-- Verify items with qty<10 have status=low
SELECT document FROM documentdb_api.collection('umw_oss', 'coll_af') ORDER BY document -> '_id';
ROLLBACK;

-- Cleanup
SELECT documentdb_api.drop_collection('umw_oss', 'coll1');
SELECT documentdb_api.drop_collection('umw_oss', 'coll_af');
