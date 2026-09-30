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

------------------------------------------------------------
-- Section 5: Partial RUM index implication from _id predicates
------------------------------------------------------------
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_unsharded', '{ "_id": 5, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_unsharded', '{ "_id": 10, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_unsharded', '{ "_id": 20, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_unsharded', '{ "_id": 30, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_unsharded', '{ "_id": 40, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_unsharded', '{ "_id": "abc", "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_unsharded', '{ "_id": "abd", "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_unsharded", "indexes": [
    { "key": { "p_eq": 1 }, "name": "idx_p_eq", "partialFilterExpression": { "_id": 20 } },
    { "key": { "p_in": 1 }, "name": "idx_p_in", "partialFilterExpression": { "_id": { "$in": [20, 30] } } },
    { "key": { "p_gt": 1 }, "name": "idx_p_gt", "partialFilterExpression": { "_id": { "$gt": 10 } } },
    { "key": { "p_gte": 1 }, "name": "idx_p_gte", "partialFilterExpression": { "_id": { "$gte": 10 } } },
    { "key": { "p_lt": 1 }, "name": "idx_p_lt", "partialFilterExpression": { "_id": { "$lt": 30 } } },
    { "key": { "p_lte": 1 }, "name": "idx_p_lte", "partialFilterExpression": { "_id": { "$lte": 30 } } },
    { "key": { "p_exists": 1 }, "name": "idx_p_exists", "partialFilterExpression": { "_id": { "$exists": true } } },
    { "key": { "c_eq": 1, "_id": 1 }, "name": "idx_c_eq_id", "partialFilterExpression": { "_id": 20 } },
    { "key": { "c_in": 1, "_id": 1 }, "name": "idx_c_in_id", "partialFilterExpression": { "_id": { "$in": [20, 30] } } },
    { "key": { "c_gt": 1, "_id": 1 }, "name": "idx_c_gt_id", "partialFilterExpression": { "_id": { "$gt": 10 } } },
    { "key": { "c_gte": 1, "_id": 1 }, "name": "idx_c_gte_id", "partialFilterExpression": { "_id": { "$gte": 10 } } },
    { "key": { "c_lt": 1, "_id": 1 }, "name": "idx_c_lt_id", "partialFilterExpression": { "_id": { "$lt": 30 } } },
    { "key": { "c_lte": 1, "_id": 1 }, "name": "idx_c_lte_id", "partialFilterExpression": { "_id": { "$lte": 30 } } },
    { "key": { "c_exists": 1, "_id": 1 }, "name": "idx_c_exists_id", "partialFilterExpression": { "_id": { "$exists": true } } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_unsharded');
ANALYZE;

BEGIN;
SET LOCAL documentdb.enable_support_function_id_pushdown TO on;
SET LOCAL enable_seqscan TO off;

-- The PFE implication GUC defaults on and can independently disable this optimization.
SHOW documentdb.enable_support_object_id_function_pfe_pushdown;
SET LOCAL documentdb.enable_support_object_id_function_pfe_pushdown TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SET LOCAL documentdb.enable_support_object_id_function_pfe_pushdown TO on;

-- 5a: Equality, $in, range, and boundary cases
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_in": 1, "_id": { "$in": [20] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_gt": 1, "_id": { "$gt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_gt": 1, "_id": { "$gte": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_gt": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_gte": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_lt": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_lt": 1, "_id": { "$lte": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_lt": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_lte": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";

-- 5b: $in subset case
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_gt": 1, "_id": { "$in": [20, 30] } } }') $explain$) AS "QUERY PLAN";

-- 5c: Lower-bound, equality, $in, and $regex predicates imply $exists: true
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_exists": 1, "_id": { "$exists": true } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_exists": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_exists": 1, "_id": { "$gt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_exists": 1, "_id": { "$gte": 20 } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_exists": 1, "_id": { "$in": [20, 30] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_exists": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";

-- 5d: String and numeric PFE boundaries for regex
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_single_string', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_single_string', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_single_string', '{ "_id": "", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_regex_single_string", "indexes": [{ "key": { "k": 1 }, "name": "idx_regex_single_string", "partialFilterExpression": { "_id": { "$gte": "" } } }] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_regex_single_string');

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_single_number', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_single_number', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_regex_single_number", "indexes": [{ "key": { "k": 1 }, "name": "idx_regex_single_number", "partialFilterExpression": { "_id": { "$gt": 10 } } }] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_regex_single_number');

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_comp_string', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_comp_string', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_comp_string', '{ "_id": "", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_regex_comp_string", "indexes": [{ "key": { "k": 1, "_id": 1 }, "name": "idx_regex_comp_string", "partialFilterExpression": { "_id": { "$gte": "" } } }] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_regex_comp_string');

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_comp_number', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_comp_number', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_regex_comp_number", "indexes": [{ "key": { "k": 1, "_id": 1 }, "name": "idx_regex_comp_number", "partialFilterExpression": { "_id": { "$gt": 10 } } }] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_regex_comp_number');

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_single_prefix', '{ "_id": "a", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_single_prefix', '{ "_id": "ab", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_regex_single_prefix", "indexes": [{ "key": { "k": 1 }, "name": "idx_regex_single_prefix", "partialFilterExpression": { "_id": { "$gte": "ab" } } }] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_regex_single_prefix');

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_comp_prefix', '{ "_id": "a", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_regex_comp_prefix', '{ "_id": "ab", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_regex_comp_prefix", "indexes": [{ "key": { "k": 1, "_id": 1 }, "name": "idx_regex_comp_prefix", "partialFilterExpression": { "_id": { "$gte": "ab" } } }] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_regex_comp_prefix');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": ".*" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^$" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "a|z" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^AB", "$options": "i" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_number", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": ".*" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "^$" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "a|z" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "^AB", "$options": "i" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_comp_number", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_prefix", "filter": { "k": 1, "_id": { "$regex": "^ab?" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_comp_prefix", "filter": { "k": 1, "_id": { "$regex": "^ab?" } } }') $explain$) AS "QUERY PLAN";

SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_gt": 1, "_id": { "$gt": 20 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "p_lt": 1, "_id": { "$lte": 20 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^ab" } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": ".*" } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^$" } }, "projection": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_regex_single_prefix", "filter": { "k": 1, "_id": { "$regex": "^ab?" } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');

-- 5e: Composite RUM keys containing _id cover every supported PFE form
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_in": 1, "_id": { "$in": [20] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_gt": 1, "_id": { "$gt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_gte": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_lt": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_lte": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_exists": 1, "_id": { "$exists": true } } }') $explain$) AS "QUERY PLAN";
SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_unsharded", "filter": { "c_in": 1, "_id": { "$in": [20, 30] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');

-- 5f: Isolated negative implication cases for both index shapes
SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_negative_eq', '{ "_id": 30, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_negative_eq", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_eq_single", "partialFilterExpression": { "_id": 20 } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_eq_comp", "partialFilterExpression": { "_id": 20 } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_negative_eq');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_eq", "filter": { "k_single": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_eq", "filter": { "k_comp": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_negative_in', '{ "_id": 40, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_negative_in", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_in_single", "partialFilterExpression": { "_id": { "$in": [20, 30] } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_in_comp", "partialFilterExpression": { "_id": { "$in": [20, 30] } } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_negative_in');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_in", "filter": { "k_single": 1, "_id": { "$in": [20, 40] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_in", "filter": { "k_comp": 1, "_id": { "$in": [20, 40] } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_negative_gt', '{ "_id": 10, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_negative_gt", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_gt_single", "partialFilterExpression": { "_id": { "$gt": 10 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_gt_comp", "partialFilterExpression": { "_id": { "$gt": 10 } } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_negative_gt');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gt", "filter": { "k_single": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gt", "filter": { "k_comp": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gt", "filter": { "k_single": 1, "_id": 10 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gt", "filter": { "k_comp": 1, "_id": 10 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gt", "filter": { "k_single": 1, "_id": { "$in": [10, 20] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gt", "filter": { "k_comp": 1, "_id": { "$in": [10, 20] } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_negative_gte', '{ "_id": 5, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_negative_gte", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_gte_single", "partialFilterExpression": { "_id": { "$gte": 10 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_gte_comp", "partialFilterExpression": { "_id": { "$gte": 10 } } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_negative_gte');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gte", "filter": { "k_single": 1, "_id": { "$gte": 5 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_gte", "filter": { "k_comp": 1, "_id": { "$gte": 5 } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_negative_lt', '{ "_id": 30, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_negative_lt", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_lt_single", "partialFilterExpression": { "_id": { "$lt": 30 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_lt_comp", "partialFilterExpression": { "_id": { "$lt": 30 } } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_negative_lt');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_lt", "filter": { "k_single": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_lt", "filter": { "k_comp": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_lt", "filter": { "k_single": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_lt", "filter": { "k_comp": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_negative_lte', '{ "_id": 40, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_negative_lte", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_lte_single", "partialFilterExpression": { "_id": { "$lte": 30 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_lte_comp", "partialFilterExpression": { "_id": { "$lte": 30 } } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_negative_lte');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_lte", "filter": { "k_single": 1, "_id": { "$lte": 40 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_lte", "filter": { "k_comp": 1, "_id": { "$lte": 40 } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_dist_db', 'pfe_negative_exists', '{ "_id": 20, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_dist_db',
  '{ "createIndexes": "pfe_negative_exists", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_exists_single", "partialFilterExpression": { "_id": { "$exists": true } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_exists_comp", "partialFilterExpression": { "_id": { "$exists": true } } }
  ] }', true);
SELECT documentdb_distributed_test_helpers.drop_primary_key('id_push_dist_db', 'pfe_negative_exists');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_exists", "filter": { "k_single": 1, "_id": { "$exists": false } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_exists", "filter": { "k_comp": 1, "_id": { "$exists": false } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_exists", "filter": { "k_single": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_exists", "filter": { "k_comp": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_exists", "filter": { "k_single": 1, "_id": { "$lte": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_dist_db', '{ "find": "pfe_negative_exists", "filter": { "k_comp": 1, "_id": { "$lte": 20 } } }') $explain$) AS "QUERY PLAN";
COMMIT;
