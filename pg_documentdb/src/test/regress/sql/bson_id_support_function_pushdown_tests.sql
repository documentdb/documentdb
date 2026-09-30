SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 25860000;
SET documentdb.next_collection_index_id TO 25860000;

-- Enable the support function pushdown GUC
SET documentdb.enable_support_function_id_pushdown TO on;
SET enable_seqscan TO off;

------------------------------------------------------------
-- Setup: insert test data with various _id types
------------------------------------------------------------
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": 1, "a": 10, "b": "x" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": 2, "a": 20, "b": "y" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": 3, "a": 30, "b": "z" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": 4, "a": 40, "b": "w" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": 5, "a": 50, "b": "v" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": "abc", "a": 60, "b": "u" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": "def", "a": 70, "b": "t" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": "xyz", "a": 80, "b": "s" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": null, "a": 90, "b": "r" }');
SELECT documentdb_api.insert_one('id_push_db', 'test_coll', '{ "_id": true, "a": 100, "b": "q" }');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('id_push_db', 'test_coll', FORMAT('{ "_id": %s, "a": %s }', g, g)::bson) FROM generate_series(100, 200) g) i;

------------------------------------------------------------
-- Section 1: Btree _id_ index pushdown via bson_aggregation_find
------------------------------------------------------------

-- 1a: Point read $eq
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 3 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": "abc" } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": null } }');

-- 1b: Range queries $gt, $gte, $lt, $lte
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gt": 3, "$lt": 6 } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gte": 3, "$lt": 5 } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$lte": 2 } }, "sort": { "_id": 1 } }');

-- 1c: $in
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$in": [1, 3, 5] } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$in": ["abc", "xyz"] } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$in": [] } } }');

-- 1d: $regex on string _id
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$regex": "^ab" } } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$regex": "^d" } } }');

-- 1e: EXPLAIN plans for btree pushdown
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 3 } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gt": 3 } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gte": 3, "$lt": 5 } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$in": [1, 3, 5] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$regex": "^ab" } } }');

------------------------------------------------------------
-- Section 2: Bitmap scan fallback
------------------------------------------------------------
BEGIN;
SET LOCAL enable_indexscan TO off;

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 3 } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gt": 3, "$lt": 5 } } }');

-- Correctness under bitmap
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 3 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gt": 3, "$lt": 5 } } }');
COMMIT;

------------------------------------------------------------
-- Section 3: RUM composite index with _id column
------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "test_coll", "indexes": [{ "key": { "a": 1, "_id": 1 }, "name": "idx_a_id" }] }', true);

-- 3a: Compound filter using a + _id → should use RUM index
ANALYZE;
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": 10, "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gte": 10, "$lte": 30 }, "_id": { "$gt": 1 } }, "sort": { "_id": 1 } }');

-- 3b: EXPLAIN for compound filter
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": 10, "_id": 1 } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gte": 10 }, "_id": { "$gt": 2 } } }');

-- 3c: _id-only filter should fall back to btree _id_ (leading column not covered)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 3 } }');

------------------------------------------------------------
-- Section 4: RUM composite index with multiple columns + _id
------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "test_coll", "indexes": [{ "key": { "a": 1, "b": 1, "_id": 1 }, "name": "idx_a_b_id" }] }', true);

-- 4a: Compound filter a + b + _id
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": 10, "b": "x", "_id": 1 } }');

-- 4b: EXPLAIN
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": 10, "b": "x", "_id": 1 } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gte": 10 }, "b": "x", "_id": { "$gt": 0 } } }');

-- 4c: Partial columns — a + _id without b
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": 10, "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": 10, "_id": 1 } }');

------------------------------------------------------------
-- Section 6: Partial filter expressions on RUM with _id
------------------------------------------------------------

-- 6a: PFE on _id field
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "test_coll", "indexes": [{ "key": { "a": 1 }, "name": "idx_a_pfe_id", "partialFilterExpression": { "_id": { "$gt": 50 } } }] }', true);

BEGIN;
-- Filter within PFE range → should use idx_a_pfe_id
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gte": 100 }, "_id": { "$gt": 100 } } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gte": 100 }, "_id": { "$gt": 100 } }, "sort": { "_id": 1 } }');

-- Filter outside PFE range → should NOT use idx_a_pfe_id
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gte": 10 }, "_id": { "$lt": 5 } } }');

-- 6b: PFE on non-_id field, index includes _id
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "test_coll", "indexes": [{ "key": { "a": 1, "_id": 1 }, "name": "idx_a_id_pfe_a", "partialFilterExpression": { "a": { "$gt": 10 } } }] }', true);

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gt": 10 }, "_id": 3 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "a": { "$gt": 10 }, "_id": 3 } }');
COMMIT;

------------------------------------------------------------
-- Section 7: Collation-aware _id values
------------------------------------------------------------

-- String _id values with default collation → btree pushdown should work
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": "abc" } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": "abc" } }');

------------------------------------------------------------
-- Section 8: Edge cases
------------------------------------------------------------

-- 8a: _id: null
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": null } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": null } }');

-- 8b: $in with null
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$in": [null] } } }');

-- 8c: Compound _id + other field
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 1, "a": 10 } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 1, "a": 10 } }');

-- 8d: Multiple _id predicates (range)
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gt": 2, "$lt": 5 } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gt": 2, "$lt": 5 } } }');

-- 8e: No matching documents
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": 99999 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$in": [99998, 99999] } } }');

-- 8f: No matching documents (additional)
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "test_coll", "filter": { "_id": { "$gt": 99999 } } }');

------------------------------------------------------------
-- Section 9: Partial RUM index implication from _id predicates
------------------------------------------------------------
SELECT documentdb_api.insert_one('id_push_db', 'pfe_coll', '{ "_id": 5, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_coll', '{ "_id": 10, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_coll', '{ "_id": 20, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_coll', '{ "_id": 30, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_coll', '{ "_id": 40, "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_coll', '{ "_id": "abc", "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_coll', '{ "_id": "abd", "p_eq": 1, "p_in": 1, "p_gt": 1, "p_gte": 1, "p_lt": 1, "p_lte": 1, "p_exists": 1, "p_string": 1, "c_eq": 1, "c_in": 1, "c_gt": 1, "c_gte": 1, "c_lt": 1, "c_lte": 1, "c_exists": 1, "c_string": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_coll", "indexes": [
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
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_coll');
ANALYZE;

-- The PFE implication GUC defaults on and can independently disable this optimization.
SHOW documentdb.enable_support_object_id_function_pfe_pushdown;
SET documentdb.enable_support_object_id_function_pfe_pushdown TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SET documentdb.enable_support_object_id_function_pfe_pushdown TO on;

-- 9a: Equality and $in PFEs
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_in": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_in": 1, "_id": { "$in": [20] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_in": 1, "_id": { "$in": [20, 30] } } }') $explain$) AS "QUERY PLAN";

-- 9b: Strict and inclusive lower bounds
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gt": 1, "_id": { "$gt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gt": 1, "_id": { "$gte": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gt": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gte": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gte": 1, "_id": { "$gt": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gte": 1, "_id": 10 } }') $explain$) AS "QUERY PLAN";

-- 9c: Strict and inclusive upper bounds
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_lt": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_lt": 1, "_id": { "$lte": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_lt": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_lte": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_lte": 1, "_id": { "$lt": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_lte": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";

-- 9d: $in must have every value inside the partial filter range
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gt": 1, "_id": { "$in": [20, 30] } } }') $explain$) AS "QUERY PLAN";

-- 9e: Lower-bound, equality, $in, and $regex predicates imply $exists: true
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_exists": 1, "_id": { "$exists": true } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_exists": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_exists": 1, "_id": { "$gt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_exists": 1, "_id": { "$gte": 20 } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_exists": 1, "_id": { "$in": [20, 30] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_exists": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";

-- 9f: A string boundary accepts regex queries, while a numeric boundary does not
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_single_string', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_single_string', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_single_string', '{ "_id": "", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_regex_single_string", "indexes": [{ "key": { "k": 1 }, "name": "idx_regex_single_string", "partialFilterExpression": { "_id": { "$gte": "" } } }] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_regex_single_string');

SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_single_number', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_single_number', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_regex_single_number", "indexes": [{ "key": { "k": 1 }, "name": "idx_regex_single_number", "partialFilterExpression": { "_id": { "$gt": 10 } } }] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_regex_single_number');

SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_comp_string', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_comp_string', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_comp_string', '{ "_id": "", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_regex_comp_string", "indexes": [{ "key": { "k": 1, "_id": 1 }, "name": "idx_regex_comp_string", "partialFilterExpression": { "_id": { "$gte": "" } } }] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_regex_comp_string');

SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_comp_number', '{ "_id": "abc", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_comp_number', '{ "_id": "abd", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_regex_comp_number", "indexes": [{ "key": { "k": 1, "_id": 1 }, "name": "idx_regex_comp_number", "partialFilterExpression": { "_id": { "$gt": 10 } } }] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_regex_comp_number');

SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_single_prefix', '{ "_id": "a", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_single_prefix', '{ "_id": "ab", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_regex_single_prefix", "indexes": [{ "key": { "k": 1 }, "name": "idx_regex_single_prefix", "partialFilterExpression": { "_id": { "$gte": "ab" } } }] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_regex_single_prefix');

SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_comp_prefix', '{ "_id": "a", "k": 1 }');
SELECT documentdb_api.insert_one('id_push_db', 'pfe_regex_comp_prefix', '{ "_id": "ab", "k": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_regex_comp_prefix", "indexes": [{ "key": { "k": 1, "_id": 1 }, "name": "idx_regex_comp_prefix", "partialFilterExpression": { "_id": { "$gte": "ab" } } }] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_regex_comp_prefix');

SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": ".*" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^$" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "a|z" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^AB", "$options": "i" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_number", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": ".*" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "^$" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "a|z" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_comp_string", "filter": { "k": 1, "_id": { "$regex": "^AB", "$options": "i" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_comp_number", "filter": { "k": 1, "_id": { "$regex": "^ab" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_prefix", "filter": { "k": 1, "_id": { "$regex": "^ab?" } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_comp_prefix", "filter": { "k": 1, "_id": { "$regex": "^ab?" } } }') $explain$) AS "QUERY PLAN";

-- Verify correct results through the partial indexes
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_gt": 1, "_id": { "$gt": 20 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "p_lt": 1, "_id": { "$lte": 20 } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^ab" } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": ".*" } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_string", "filter": { "k": 1, "_id": { "$regex": "^$" } }, "projection": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_regex_single_prefix", "filter": { "k": 1, "_id": { "$regex": "^ab?" } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');

-- 9g: Composite RUM keys containing _id cover every supported PFE form
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_eq": 1, "_id": 20 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_in": 1, "_id": { "$in": [20] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_gt": 1, "_id": { "$gt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_gte": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_lt": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_lte": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_exists": 1, "_id": { "$exists": true } } }') $explain$) AS "QUERY PLAN";
SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_coll", "filter": { "c_in": 1, "_id": { "$in": [20, 30] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');

-- 9h: Isolated negative implication cases for both index shapes
SELECT documentdb_api.insert_one('id_push_db', 'pfe_negative_eq', '{ "_id": 30, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_negative_eq", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_eq_single", "partialFilterExpression": { "_id": 20 } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_eq_comp", "partialFilterExpression": { "_id": 20 } }
  ] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_negative_eq');
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_eq", "filter": { "k_single": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_eq", "filter": { "k_comp": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_db', 'pfe_negative_in', '{ "_id": 40, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_negative_in", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_in_single", "partialFilterExpression": { "_id": { "$in": [20, 30] } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_in_comp", "partialFilterExpression": { "_id": { "$in": [20, 30] } } }
  ] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_negative_in');
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_in", "filter": { "k_single": 1, "_id": { "$in": [20, 40] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_in", "filter": { "k_comp": 1, "_id": { "$in": [20, 40] } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_db', 'pfe_negative_gt', '{ "_id": 10, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_negative_gt", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_gt_single", "partialFilterExpression": { "_id": { "$gt": 10 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_gt_comp", "partialFilterExpression": { "_id": { "$gt": 10 } } }
  ] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_negative_gt');
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gt", "filter": { "k_single": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gt", "filter": { "k_comp": 1, "_id": { "$gte": 10 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gt", "filter": { "k_single": 1, "_id": 10 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gt", "filter": { "k_comp": 1, "_id": 10 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gt", "filter": { "k_single": 1, "_id": { "$in": [10, 20] } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gt", "filter": { "k_comp": 1, "_id": { "$in": [10, 20] } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_db', 'pfe_negative_gte', '{ "_id": 5, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_negative_gte", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_gte_single", "partialFilterExpression": { "_id": { "$gte": 10 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_gte_comp", "partialFilterExpression": { "_id": { "$gte": 10 } } }
  ] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_negative_gte');
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gte", "filter": { "k_single": 1, "_id": { "$gte": 5 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_gte", "filter": { "k_comp": 1, "_id": { "$gte": 5 } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_db', 'pfe_negative_lt', '{ "_id": 30, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_negative_lt", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_lt_single", "partialFilterExpression": { "_id": { "$lt": 30 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_lt_comp", "partialFilterExpression": { "_id": { "$lt": 30 } } }
  ] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_negative_lt');
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_lt", "filter": { "k_single": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_lt", "filter": { "k_comp": 1, "_id": { "$lte": 30 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_lt", "filter": { "k_single": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_lt", "filter": { "k_comp": 1, "_id": 30 } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_db', 'pfe_negative_lte', '{ "_id": 40, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_negative_lte", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_lte_single", "partialFilterExpression": { "_id": { "$lte": 30 } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_lte_comp", "partialFilterExpression": { "_id": { "$lte": 30 } } }
  ] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_negative_lte');
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_lte", "filter": { "k_single": 1, "_id": { "$lte": 40 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_lte", "filter": { "k_comp": 1, "_id": { "$lte": 40 } } }') $explain$) AS "QUERY PLAN";

SELECT documentdb_api.insert_one('id_push_db', 'pfe_negative_exists', '{ "_id": 20, "k_single": 1, "k_comp": 1 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('id_push_db',
  '{ "createIndexes": "pfe_negative_exists", "indexes": [
    { "key": { "k_single": 1 }, "name": "idx_negative_exists_single", "partialFilterExpression": { "_id": { "$exists": true } } },
    { "key": { "k_comp": 1, "_id": 1 }, "name": "idx_negative_exists_comp", "partialFilterExpression": { "_id": { "$exists": true } } }
  ] }', true);
SELECT documentdb_test_helpers.drop_primary_key('id_push_db', 'pfe_negative_exists');
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_exists", "filter": { "k_single": 1, "_id": { "$exists": false } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_exists", "filter": { "k_comp": 1, "_id": { "$exists": false } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_exists", "filter": { "k_single": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_exists", "filter": { "k_comp": 1, "_id": { "$lt": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_exists", "filter": { "k_single": 1, "_id": { "$lte": 20 } } }') $explain$) AS "QUERY PLAN";
SELECT documentdb_test_helpers.run_explain_and_trim($explain$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('id_push_db', '{ "find": "pfe_negative_exists", "filter": { "k_comp": 1, "_id": { "$lte": 20 } } }') $explain$) AS "QUERY PLAN";
