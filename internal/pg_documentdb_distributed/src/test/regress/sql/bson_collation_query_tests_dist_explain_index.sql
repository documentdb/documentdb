SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 95650000;
SET documentdb.next_collection_id TO 95650;
SET documentdb.next_collection_index_id TO 95650;

SET documentdb_api.forceUseIndexIfAvailable TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

-- Indexes are created AFTER each shard_collection call below so the collation-
-- aware index propagates to every shard. Mirrors bson_collation_query_index_tests_dist.sql.

-- ======================================================================
-- SECTION 1: $lookup on sharded collection (collation aware)
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','coll_lookup_d', '{"_id": "Cat", "a": { "b": "Cat" }}');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','coll_lookup_d', '{"_id": "dog", "a": { "b": "dog" }}');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','coll_lookup_d', '{"_id": "DOG", "a": { "b": "DOG" }}');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','coll_lookup_d', '{"_id": "cAT", "a": { "b": "cAT" }}');

SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'coll_lookup_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_lookup_d",
     "indexes": [{ "key": {"a.b": 1}, "name": "idx_ab_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_idx_dist_explain_db',
    '{ "aggregate": "coll_lookup_d", "pipeline": [ { "$lookup": { "from": "coll_lookup_d", "as": "matched_docs", "localField": "_id", "foreignField": "_id", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }')
$cmd$);
END;

-- ======================================================================
-- SECTION 2: Aggregation pipeline routing on sharded collection
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_agg_d', '{ "_id": "cat", "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_agg_d', '{ "_id": "cAt", "a": "cAt" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_agg_d', '{ "_id": "dog", "a": "dog" }');

SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'coll_agg_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_agg_d",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_idx_dist_explain_db', '{ "aggregate": "coll_agg_d", "pipeline": [ { "$match": { "_id": { "$eq": "CAT" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
END;

-- Numeric shard key value with collation: not collation-aware, single shard
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_idx_dist_explain_db', '{ "find": "coll_agg_d", "filter": { "_id": { "$eq": 2 } }, "sort": { "_id": 1 }, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
END;

-- ======================================================================
-- SECTION 3: Aggregation pipeline with collation on sharded single_field_d
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 7, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','single_field_d', '{"_id": 8, "a": null}', NULL);

SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'single_field_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_idx_dist_explain_db',
  '{ "createIndexes": "single_field_d",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_idx_dist_explain_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 4: Delete predicate plans on sharded coll_delete_d with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_delete_d', '{"_id": "dog", "a":"dog"}');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_delete_d', '{"_id": "DOG", "a":"DOG"}');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_delete_d', '{"_id": "cat", "a":"cat"}');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_delete_d', '{"_id": "CAT", "a":"CAT"}');

SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'coll_delete_d', '{ "a": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_delete_d",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

-- deleteMany predicate (collation-aware on the shard key field)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_delete_d')
  WHERE documentdb_api_internal.bson_query_match(document, '{"a": "CaT"}'::bson, '{}'::bson, 'en-u-ks-level1')
$cmd$);
END;

-- deleteOne predicate when no _id and no shard-key filter
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_delete_d')
  WHERE documentdb_api_internal.bson_query_match(document, '{"b": "CaT"}'::bson, '{}'::bson, 'en-u-ks-level1')
$cmd$);
END;

-- deleteOne predicate with collation-aware shard key value filter
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_delete_d')
  WHERE documentdb_api_internal.bson_query_match(document, '{"a": "CaT"}'::bson, '{}'::bson, 'en-u-ks-level1')
$cmd$);
END;

-- deleteOne predicate with both _id and shard key filter
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_delete_d')
  WHERE documentdb_api_internal.bson_query_match(document, '{"_id": "CaT", "a": "CaT"}'::bson, '{}'::bson, 'en-u-ks-level1')
$cmd$);
END;

-- ======================================================================
-- SECTION 5: Delete predicate plans on sharded single_field_d with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'single_field_d')
  WHERE documentdb_api_internal.bson_query_match(document, '{"a": "apple"}'::bson, '{}'::bson, 'en-u-ks-level1')
$cmd$);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'single_field_d')
  WHERE documentdb_api_internal.bson_query_match(document, '{"a": {"$gt": "cherry"}}'::bson, '{}'::bson, 'en-u-ks-level1')
$cmd$);
END;

-- ======================================================================
-- SECTION 6: bson_query_match on sharded collection — single shard key
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": "cat", "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": "dog", "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": 3, "a": "peacock" }');

SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_qm_d",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

-- Distributed: shard key value is collation-aware (fans out to all shards)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT" }', '{}', 'en-u-ks-level1')
$cmd$);
END;

-- Not distributed: shard key value is not collation-aware (single shard)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 3 }', '{}', 'en-u-ks-level1')
$cmd$);
END;

-- ======================================================================
-- SECTION 7: bson_query_match on sharded collection — compound shard key
-- ======================================================================

SELECT documentdb_api.drop_collection('coll_q_idx_dist_explain_db', 'coll_qm_d');

SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": "cAt", "a": "cAt" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": "doG", "a": "DOg" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": 3, "a": "doG" }');

SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'coll_qm_d', '{ "_id": "hashed", "a": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_q_idx_dist_explain_db',
  '{
    "createIndexes": "coll_qm_d",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);
END;

-- Distributed: shard key filter values are collation-aware
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT", "a": "CAT" }', '{}', 'en-u-ks-level1')
$cmd$);
END;

-- Mixed type filter: collation on string portion of compound shard key
-- still prevents pruning, so the query fans out to all shards.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('coll_q_idx_dist_explain_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 1, "a": "CAT" }', '{}', 'en-u-ks-level1')
$cmd$);
END;

-- Cleanup
RESET documentdb_api.forceUseIndexIfAvailable;
RESET documentdb.defaultUseCompositeOpClass;

-- ======================================================================
-- SECTION 12: $graphLookup on sharded collection (currently unsupported)
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','coll_graph_src_d', '{"_id": "alice", "pet" : "dog" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','coll_graph_dst_d', '{"_id": "DOG", "name" : "DOG" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db','coll_graph_dst_d', '{"_id": "dog", "name" : "dog" }');

SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'coll_graph_src_d', '{ "_id": "hashed" }', false);
SELECT documentdb_api.shard_collection('coll_q_idx_dist_explain_db', 'coll_graph_dst_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_graph_src_d",
     "indexes": [{ "key": {"pet": 1}, "name": "idx_pet_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_graph_dst_d",
     "indexes": [{ "key": {"name": 1}, "name": "idx_name_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_idx_dist_explain_db',
    '{ "aggregate": "coll_graph_src_d", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst_d", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
END;
