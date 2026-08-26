SET citus.next_shard_id TO 95240000;
SET documentdb.next_collection_id TO 95240;
SET documentdb.next_collection_index_id TO 95240;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SELECT documentdb_api.insert_one('coll_ops_runtime_dist_explain_db','single_field_d', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_runtime_dist_explain_db','single_field_d', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_runtime_dist_explain_db','single_field_d', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_runtime_dist_explain_db','single_field_d', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_runtime_dist_explain_db','single_field_d', '{"_id": 5, "a": "cherry"}', NULL);

SELECT documentdb_api.shard_collection('coll_ops_runtime_dist_explain_db', 'single_field_d', '{ "_id": "hashed" }', false);

-- $eq with collation across shards
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_runtime_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- $gt with collation across shards
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_runtime_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- aggregation pipeline with $match and collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_ops_runtime_dist_explain_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$match": { "a": { "$eq": "cherry" } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- collated ORDER BY on a non-_id field without a collation-aware index —
-- per-shard Seq Scan and a coordinator-side merge sort
-- (Sort over remote_scan."?sort?"). The per-shard sort key is the 3-arg
-- bson_orderby_index(document, sortspec, '<icu-collation>') expression
-- introduced by this PR (visible with VERBOSE; here we assert the plan
-- shape, consistent with the rest of the file).
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_runtime_dist_explain_db', '{ "find": "single_field_d", "filter": {}, "sort": { "a": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;
