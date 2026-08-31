SET citus.next_shard_id TO 8900000;
SET documentdb.next_collection_id TO 8900;
SET documentdb.next_collection_index_id TO 8900;

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 1, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 2, "a": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 3, "a": "DOG" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 4, "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 5, "a": "rabbit" }');

-- find with collation on equality predicate
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_simple", "filter": { "a": "CAT" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);

-- find with $expr equality on collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_simple", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);

-- find with $expr inequality on collation (different locale)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_simple", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 1 } }') $cmd$);

-- aggregation pipeline with $match and collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_runtime_explain_db', '{ "aggregate": "coll_simple", "pipeline": [ { "$match": { "a": "DOG" } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }') $cmd$);

-- covered $count under collation without an index -> sequential scan
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_runtime_explain_db', '{ "aggregate": "coll_simple", "pipeline": [ { "$match": { "a": "CAT" } }, { "$count": "n" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- count command without a matching collated index -> runtime filter
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_count('coll_q_runtime_explain_db', '{ "count": "coll_simple", "query": { "a": "CAT" }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- equality on a string _id under collation without an index -> sequential scan
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_id_simple', '{ "_id": "cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_id_simple', '{ "_id": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_id_simple', '{ "_id": "dog" }');
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_id_simple", "filter": { "_id": "cat" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- Distinct with collation performs semantic deduplication with complete
-- collated keys.
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_distinct', '{ "_id": 1, "a": "cafe", "n": { "a": "cafe" }, "arr": [ "cafe", "tea" ] }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_distinct', '{ "_id": 2, "a": "CAFE", "n": { "a": "CAFE" }, "arr": [ "CAFE" ] }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_distinct', '{ "_id": 3, "a": "tea", "n": { "a": "tea" }, "arr": [ "TEA" ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "a", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Dotted paths use the same three-argument unwind expression.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "n.a", "query": { "a": { "$in": [ "CAFE", "TEA" ] } }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Arrays retain ProjectSet, Sort, and Unique when no ordered index is present.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "arr", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Without a collation, distinct uses hash aggregation with binary comparison.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "a" }')
$cmd$);

SELECT documentdb_api.drop_collection('coll_q_runtime_explain_db', 'coll_distinct');
