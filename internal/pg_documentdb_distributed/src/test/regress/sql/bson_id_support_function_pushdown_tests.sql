SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 258600000;
SET documentdb.next_collection_id TO 25860000;
SET documentdb.next_collection_index_id TO 25860000;
SET citus.propagate_set_commands TO 'local';

-- Enable the support function pushdown GUC
-- Note: use SET LOCAL inside BEGIN blocks for distributed tests
-- so the GUC propagates to Citus workers via propagate_set_commands.

------------------------------------------------------------
-- Setup: Unsharded collection
------------------------------------------------------------
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', '{ "_id": 1, "a": 10, "b": "x" }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', '{ "_id": 2, "a": 20, "b": "y" }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', '{ "_id": 3, "a": 30, "b": "z" }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', '{ "_id": 4, "a": 40, "b": "w" }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', '{ "_id": 5, "a": 50, "b": "v" }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', '{ "_id": "abc", "a": 60, "b": "u" }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', '{ "_id": "def", "a": 70, "b": "t" }');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('id_push_dist_db', 'test_unsharded', FORMAT('{ "_id": %s, "a": %s }', g, g)::bson) FROM generate_series(100, 200) g) i;

------------------------------------------------------------
-- Section 1: Btree pushdown on unsharded collection
------------------------------------------------------------
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_unsharded", "filter": { "_id": 3 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_unsharded", "filter": { "_id": { "$gt": 3, "$lt": 5 } } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_unsharded", "filter": { "_id": { "$in": [1, 3, 5] } }, "sort": { "_id": 1 } }');

BEGIN;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_unsharded", "filter": { "_id": 3 } }');
COMMIT;

BEGIN;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_unsharded", "filter": { "_id": { "$gt": 3 } } }');
COMMIT;

BEGIN;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_unsharded", "filter": { "_id": { "$in": [1, 3] } } }');
COMMIT;

------------------------------------------------------------
-- Section 2: Sharded collection — shard key is _id
------------------------------------------------------------
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_id', '{ "_id": 1, "a": 10 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_id', '{ "_id": 2, "a": 20 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_id', '{ "_id": 3, "a": 30 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_id', '{ "_id": 4, "a": 40 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_id', '{ "_id": 5, "a": 50 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_id', '{ "_id": "abc", "a": 60 }');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_id', FORMAT('{ "_id": %s, "a": %s }', g, g)::bson) FROM generate_series(100, 150) g) i;

SELECT documentdb_api.shard_collection('id_push_dist_db', 'test_sharded_by_id', '{ "_id": "hashed" }', false);

-- 2a: Point read with shard key = _id
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_id", "filter": { "_id": 3 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_id", "filter": { "_id": "abc" } }');

-- 2b: Range queries
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_id", "filter": { "_id": { "$gt": 3, "$lt": 5 } } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_id", "filter": { "_id": { "$in": [1, 3, 5] } }, "sort": { "_id": 1 } }');

-- 2c: EXPLAIN
BEGIN;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_id", "filter": { "_id": 3 } }');
COMMIT;

BEGIN;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_id", "filter": { "_id": { "$gt": 3 } } }');
COMMIT;

------------------------------------------------------------
-- Section 3: Sharded collection — shard key is different field
------------------------------------------------------------
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_a', '{ "_id": 1, "a": 10 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_a', '{ "_id": 2, "a": 20 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_a', '{ "_id": 3, "a": 30 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_a', '{ "_id": 4, "a": 40 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_a', '{ "_id": 5, "a": 50 }');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('id_push_dist_db', 'test_sharded_by_a', FORMAT('{ "_id": %s, "a": %s }', g, g)::bson) FROM generate_series(100, 150) g) i;

SELECT documentdb_api.shard_collection('id_push_dist_db', 'test_sharded_by_a', '{ "a": "hashed" }', false);

-- 3a: _id filter without shard key → scatter-gather
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_a", "filter": { "_id": 3 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_a", "filter": { "_id": { "$gt": 3, "$lt": 5 } } }');

-- 3b: _id + shard key filter → targeted + btree pushdown
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_a", "filter": { "_id": 3, "a": 30 } }');
BEGIN;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_a", "filter": { "_id": 3, "a": 30 } }');
COMMIT;

-- 3c: Range on _id with shard key
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_a", "filter": { "_id": { "$gte": 1, "$lte": 3 }, "a": { "$gte": 10, "$lte": 30 } }, "sort": { "_id": 1 } }');

------------------------------------------------------------
-- Section 4: RUM index with _id on sharded collection
------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "test_sharded_by_a", "indexes": [{ "key": { "a": 1, "_id": 1 }, "name": "idx_a_id_sharded" }] }', true);

ANALYZE;

-- 4a: Compound filter on sharded collection
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_a", "filter": { "a": 30, "_id": 3 } }');

-- 4b: EXPLAIN
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "test_sharded_by_a", "filter": { "a": 30, "_id": 3 } }');
COMMIT;
