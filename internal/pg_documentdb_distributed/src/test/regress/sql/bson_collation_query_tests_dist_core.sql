SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- ======================================================================
-- SECTION 1: $lookup on sharded collection (collation aware)
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db','coll_lookup_d', '{"_id": "Cat", "a": { "b": "Cat" }}');
SELECT documentdb_api.insert_one('coll_q_dist_db','coll_lookup_d', '{"_id": "dog", "a": { "b": "dog" }}');
SELECT documentdb_api.insert_one('coll_q_dist_db','coll_lookup_d', '{"_id": "DOG", "a": { "b": "DOG" }}');
SELECT documentdb_api.insert_one('coll_q_dist_db','coll_lookup_d', '{"_id": "cAT", "a": { "b": "cAT" }}');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_lookup_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db',
    '{ "aggregate": "coll_lookup_d", "pipeline": [ { "$lookup": { "from": "coll_lookup_d", "as": "matched_docs", "localField": "_id", "foreignField": "_id", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
END;

-- _id join optimization GUC has no effect on sharded collections;
-- the join remains collation-aware.
BEGIN;
SET LOCAL documentdb.enableLookupIdJoinOptimizationOnCollation TO true;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db',
    '{ "aggregate": "coll_lookup_d", "pipeline": [ { "$lookup": { "from": "coll_lookup_d", "as": "matched_docs", "localField": "_id", "foreignField": "_id", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
END;

-- ======================================================================
-- SECTION 2: Aggregation pipeline routing on sharded collection
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_agg_d', '{ "_id": "cat", "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_agg_d', '{ "_id": "cAt", "a": "cAt" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_agg_d', '{ "_id": "dog", "a": "dog" }');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_agg_d', '{ "_id": "hashed" }', false);

-- String _id with collation: results returned, plan fans out to all shards.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "coll_agg_d", "pipeline": [ { "$match": { "_id": { "$eq": "CAT" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "coll_agg_d", "pipeline": [ { "$match": { "_id": { "$eq": "CAT" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }') $cmd$);
END;

-- Numeric _id with collation: not collation-aware, single shard.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_find('coll_q_dist_db', '{ "find": "coll_agg_d", "filter": { "_id": { "$eq": 2 } }, "sort": { "_id": 1 }, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_dist_db', '{ "find": "coll_agg_d", "filter": { "_id": { "$eq": 2 } }, "sort": { "_id": 1 }, "limit": 5, "collation": { "locale": "en", "strength" : 1} }') $cmd$);
END;

-- ======================================================================
-- SECTION 3: Aggregation pipeline with collation on sharded single_field_d
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 7, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_q_dist_db','single_field_d', '{"_id": 8, "a": null}', NULL);

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'single_field_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- ======================================================================
-- SECTION 4: Delete on sharded coll_delete_d with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_delete_d', '{"_id": "dog", "a":"dog"}');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_delete_d', '{"_id": "DOG", "a":"DOG"}');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_delete_d', '{"_id": "cat", "a":"cat"}');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_delete_d', '{"_id": "CAT", "a":"CAT"}');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_delete_d', '{ "a": "hashed" }', false);

-- deleteMany respects collation across shards.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"a": "CaT" }, "limit": 0, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_delete_d');
ROLLBACK;

-- deleteOne errors when no _id and no shard-key filter.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"b": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
END;

-- deleteOne errors with collation-aware shard key value filter.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"a": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 3}}]}');
END;

-- deleteOne with both _id and shard key filter succeeds.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"_id": "CaT", "a": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_delete_d');
ROLLBACK;

-- ======================================================================
-- SECTION 5: Delete on sharded single_field_d with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "single_field_d", "deletes": [{ "q": { "a": "apple" }, "limit": 0, "collation": { "locale": "en", "strength": 1 } }] }');
SELECT document FROM bson_aggregation_find('coll_q_dist_db', '{ "find": "single_field_d", "filter": { "_id": { "$in": [1, 2] } }, "sort": { "_id": 1 } }');

SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "single_field_d", "deletes": [{ "q": { "a": { "$gt": "cherry" } }, "limit": 0, "collation": { "locale": "en", "strength": 1 } }] }');
SELECT document FROM bson_aggregation_find('coll_q_dist_db', '{ "find": "single_field_d", "filter": {}, "sort": { "_id": 1 } }');
END;

-- ======================================================================
-- SECTION 6: bson_query_match on sharded collection — single shard key
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_qm_d', '{ "_id": "cat", "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_qm_d', '{ "_id": "dog", "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_qm_d', '{ "_id": 3, "a": "peacock" }');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_qm_d', '{ "_id": "hashed" }', false);

-- String shard-key value: collation-aware → fans out.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT" }', '{}', 'en-u-ks-level1');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT" }', '{}', 'en-u-ks-level1') $cmd$);
END;

-- Numeric shard-key value: not collation-aware → single shard.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 3 }', '{}', 'en-u-ks-level1');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 3 }', '{}', 'en-u-ks-level1') $cmd$);
END;

-- ======================================================================
-- SECTION 7: bson_query_match on sharded collection — compound shard key
-- ======================================================================

SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_qm_d');

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_qm_d', '{ "_id": "cAt", "a": "cAt" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_qm_d', '{ "_id": "doG", "a": "DOg" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_qm_d', '{ "_id": 3, "a": "doG" }');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_qm_d', '{ "_id": "hashed", "a": "hashed" }', false);

-- All-string compound filter: collation-aware on both keys → fans out.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT", "a": "CAT" }', '{}', 'en-u-ks-level1');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT", "a": "CAT" }', '{}', 'en-u-ks-level1') $cmd$);
END;

-- Mixed-type compound filter (numeric _id + string a): the collated
-- string portion still prevents pruning; query fans out.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 1, "a": "CAT" }', '{}', 'en-u-ks-level1');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 1, "a": "CAT" }', '{}', 'en-u-ks-level1') $cmd$);
END;

-- ======================================================================
-- SECTION 12: $graphLookup on sharded collection (currently unsupported)
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db','coll_graph_src_d', '{"_id": "alice", "pet" : "dog" }');
SELECT documentdb_api.insert_one('coll_q_dist_db','coll_graph_dst_d', '{"_id": "DOG", "name" : "DOG" }');
SELECT documentdb_api.insert_one('coll_q_dist_db','coll_graph_dst_d', '{"_id": "dog", "name" : "dog" }');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_graph_src_d', '{ "_id": "hashed" }', false);
SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_graph_dst_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db',
    '{ "aggregate": "coll_graph_src_d", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst_d", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 1} }');
END;

-- ======================================================================
-- CLEANUP
-- ======================================================================
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_agg_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_delete_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_graph_dst_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_graph_src_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_lookup_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_qm_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'single_field_d');
