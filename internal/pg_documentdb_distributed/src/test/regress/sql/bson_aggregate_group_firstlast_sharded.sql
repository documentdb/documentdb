SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,pg_catalog;

SET citus.next_shard_id TO 19850000;
SET documentdb.next_collection_id TO 19850;
SET documentdb.next_collection_index_id TO 19850;

-- =============================================================================
-- Test 1: Sharded $first/$last with collation
-- Exercises combine function (send/recv) path across shards with collation.
-- =============================================================================

-- Setup and shard data
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 1, "g": "A", "name": "cherry" }');
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 2, "g": "A", "name": "BANANA" }');
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 3, "g": "A", "name": "Apple" }');
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 4, "g": "a", "name": "date" }');
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 5, "g": "a", "name": "FIG" }');
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 6, "g": "B", "name": "grape" }');
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 7, "g": "B", "name": "KIWI" }');

SELECT documentdb_api.shard_collection('db', 'fl_collation_test', '{ "_id": "hashed" }', false);

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNewGroupAccumulators TO on;

-- 1a. GUC ON: collation-sensitive $first/$last after sharding
SET documentdb.enableNewWithExprAccumulators TO on;

set citus.propagate_set_commands to 'local';
BEGIN;
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;

-- With collation (case-insensitive strength 1): "cherry" eq "CHERRY" → matched
-- TODO: Known bug - collation is not honored for value comparisons on worker nodes
-- in distributed execution. The $eq comparison inside $cond falls back to binary,
-- so "cherry" != "CHERRY" and all rows show "no-match" instead of "matched" for
-- the group containing _id=1. Update expected output once the fix is in.
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline (binary: "cherry" != "CHERRY")
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- Simple field reference with collation
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstName": { "$first": "$name" }, "lastName": { "$last": "$name" } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Constant _id group with collation-sensitive expression
-- TODO: Known bug - collation is not honored for value comparisons on worker nodes
-- in distributed execution. firstMatch should be "matched" since doc _id=1 has
-- name="cherry" which equals "CHERRY" at strength 1, but $eq uses binary
-- comparison on the worker. Update expected output once the fix is in.
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": null, "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

ROLLBACK;

-- 1b. GUC OFF: collation with old accumulators → error
SET documentdb.enableNewWithExprAccumulators TO off;
SET documentdb.enableCollationWithNewGroupAccumulators TO off;

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": "$name" }, "l": { "$last": "$name" } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

SET documentdb.enableCollationWithNewGroupAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
SET documentdb_core.enableCollation TO off;

-- =============================================================================
-- Test 2: Sharded $first/$last where every document in the group has a missing
-- field. With hashed _id sharding the docs land on different shards, so the
-- EOD (missing) value must survive the send/recv/combine path and come back
-- as null in the final result.
-- =============================================================================

SELECT documentdb_api.insert_one('db', 'fl_missing_test', '{ "_id": 1, "category": "electronics" }');
SELECT documentdb_api.insert_one('db', 'fl_missing_test', '{ "_id": 2, "category": "electronics" }');

SELECT documentdb_api.shard_collection('db', 'fl_missing_test', '{ "_id": "hashed" }', false);

-- 2a. GUC ON: $first and $last on missing nested field
SET documentdb.enableNewWithExprAccumulators TO on;

set citus.propagate_set_commands to 'local';
BEGIN;
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_missing_test", "pipeline": [{ "$group": { "_id": "$category", "firstResult": { "$first": "$profile.email" }, "lastResult": { "$last": "$profile.email" } } }], "cursor": {} }');
ROLLBACK;

-- 2b. GUC OFF: $first and $last on missing nested field
SET documentdb.enableNewWithExprAccumulators TO off;

set citus.propagate_set_commands to 'local';
BEGIN;
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_missing_test", "pipeline": [{ "$group": { "_id": "$category", "firstResult": { "$first": "$profile.email" }, "lastResult": { "$last": "$profile.email" } } }], "cursor": {} }');
ROLLBACK;

SELECT documentdb_api.drop_collection('db', 'fl_missing_test');

-- =============================================================================
-- Test 3: Sharded $setWindowFields for $first/$last
-- Covers data correctness and EXPLAIN for both sortBy and no-sortBy paths
-- with GUC on and off. Uses both $first and $last in every query.
-- =============================================================================

SELECT documentdb_api.insert_one('db', 'wfl_dist_test', '{ "_id": 1, "g": "A", "v": 10, "name": "alpha" }');
SELECT documentdb_api.insert_one('db', 'wfl_dist_test', '{ "_id": 2, "g": "B", "v": 20, "name": "beta" }');
SELECT documentdb_api.insert_one('db', 'wfl_dist_test', '{ "_id": 3, "g": "A", "v": 30, "name": "gamma" }');
SELECT documentdb_api.insert_one('db', 'wfl_dist_test', '{ "_id": 4, "g": "B", "v": 40, "name": "delta" }');

SELECT documentdb_api.shard_collection('db', 'wfl_dist_test', '{ "_id": "hashed" }', false);

-- 3a. GUC ON: $first/$last with sortBy - data correctness
SET documentdb.enableNewWithExprAccumulators TO on;

set citus.propagate_set_commands to 'local';
BEGIN;
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "sortBy": { "v": 1 }, "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- 3b. GUC ON: $first/$last without sortBy - data correctness
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

ROLLBACK;

-- 3c. GUC OFF: $first/$last with sortBy - data correctness
SET documentdb.enableNewWithExprAccumulators TO off;

set citus.propagate_set_commands to 'local';
BEGIN;
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "sortBy": { "v": 1 }, "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- 3d. GUC OFF: $first/$last without sortBy - data correctness
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

ROLLBACK;

-- 3e. GUC ON: EXPLAIN $first/$last with sortBy → bsonfirst / bsonlast (sorted path)
SET documentdb.enableNewWithExprAccumulators TO on;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "sortBy": { "v": 1 }, "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }], "cursor": {} }') $cmd$);

-- 3f. GUC ON: EXPLAIN $first/$last without sortBy → bsonfirstwithexpr / bsonlastwithexpr
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }], "cursor": {} }') $cmd$);

-- 3g. GUC OFF: EXPLAIN $first/$last with sortBy → bsonfirst / bsonlast (sorted path)
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "sortBy": { "v": 1 }, "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }], "cursor": {} }') $cmd$);

-- 3h. GUC OFF: EXPLAIN $first/$last without sortBy → bsonfirstonsorted / bsonlastonsorted
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "wfl_dist_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }], "cursor": {} }') $cmd$);

SELECT documentdb_api.drop_collection('db', 'wfl_dist_test');

SET documentdb.enableNewWithExprAccumulators TO off;
