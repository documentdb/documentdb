SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 95680000;
SET documentdb.next_collection_id TO 95680;
SET documentdb.next_collection_index_id TO 95680;

SELECT documentdb_api.insert_one('coll_q_runtime_dist_explain_db', 'coll_simple_d', '{ "_id": 1, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_dist_explain_db', 'coll_simple_d', '{ "_id": 2, "a": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_dist_explain_db', 'coll_simple_d', '{ "_id": 3, "a": "DOG" }');
SELECT documentdb_api.insert_one('coll_q_runtime_dist_explain_db', 'coll_simple_d', '{ "_id": 4, "a": "dog" }');

SELECT documentdb_api.shard_collection('coll_q_runtime_dist_explain_db', 'coll_simple_d', '{ "_id": "hashed" }', false);

-- find with collation on equality predicate
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_dist_explain_db', '{ "find": "coll_simple_d", "filter": { "a": "CAT" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- $expr equality with collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_dist_explain_db', '{ "find": "coll_simple_d", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- aggregation pipeline with $match and collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_runtime_dist_explain_db', '{ "aggregate": "coll_simple_d", "pipeline": [ { "$match": { "a": "DOG" } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;
