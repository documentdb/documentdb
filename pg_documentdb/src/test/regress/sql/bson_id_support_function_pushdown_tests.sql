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

