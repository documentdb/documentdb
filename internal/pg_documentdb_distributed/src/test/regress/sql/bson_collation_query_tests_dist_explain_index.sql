SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 95800000;
SET documentdb.next_collection_id TO 95800;
SET documentdb.next_collection_index_id TO 95800;

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

-- Count command fans out and uses the matching collation index on each shard.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_count('coll_q_idx_dist_explain_db', '{ "count": "coll_agg_d", "query": { "a": "CAT" }, "collation": { "locale": "en", "strength": 1 } }')
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
-- SECTION 4: Predicate plans on sharded coll_delete_d with collation
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

-- Collation-aware shard-key predicate
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

-- Predicate without an _id or shard-key filter
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

-- Collation-aware shard-key value predicate
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

-- Predicate with both _id and shard-key filters
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
-- SECTION 5: Predicate plans on sharded single_field_d with collation
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

-- ======================================================================
-- SECTION: distinct with a collation-aware index across shards
-- ======================================================================
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_distinct_d', '{ "_id": 1, "a": "cafe" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_distinct_d', '{ "_id": 2, "a": "CAFE" }');
SELECT documentdb_api.insert_one('coll_q_idx_dist_explain_db', 'coll_distinct_d', '{ "_id": 3, "a": "tea" }');
SELECT documentdb_api.shard_collection(
  'coll_q_idx_dist_explain_db', 'coll_distinct_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_distinct_d", "indexes": [ { "key": { "a": 1 }, "name": "idx_a_en_s1", "collation": { "locale": "en", "strength": 1 } } ] }',
  TRUE);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_idx_dist_explain_db',
  '{ "distinct": "coll_distinct_d", "key": "a", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- An incompatible collation cannot borrow ordering from the strength-1 index.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.enable_distinct_exists_filter_pushdown TO on;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_idx_dist_explain_db',
  '{ "distinct": "coll_distinct_d", "key": "a", "collation": { "locale": "en", "strength": 2 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION: sorted update routing uses the matching compound index
-- ======================================================================
SELECT documentdb_api.insert_one(
  'coll_q_idx_dist_explain_db', 'coll_update_route_d',
  '{ "_id": "cat", "name": "cat", "bucket": 1, "rank": 10 }');
SELECT documentdb_api.insert_one(
  'coll_q_idx_dist_explain_db', 'coll_update_route_d',
  '{ "_id": "CAT", "name": "CAT", "bucket": 1, "rank": 1 }');
SELECT documentdb_api.shard_collection(
  'coll_q_idx_dist_explain_db', 'coll_update_route_d',
  '{ "name": "hashed" }', false);

SELECT pg_catalog.set_config(
  'documentdb.alternate_index_handler_name', 'extended_rum', false), extname
FROM pg_extension
WHERE extname = 'documentdb_extended_rum';

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_q_idx_dist_explain_db',
  '{ "createIndexes": "coll_update_route_d", "indexes": [
     { "key": { "name": 1 },
       "name": "idx_update_route_name_en_s1",
       "collation": { "locale": "en", "strength": 1 } },
     { "key": { "name": 1 },
       "name": "idx_update_route_name_binary" },
     { "key": { "_id": 1, "rank": 1 },
       "name": "idx_update_route_id_rank_en_s1",
       "collation": { "locale": "en", "strength": 1 } },
     { "key": { "_id": 1, "bucket": 1, "rank": -1 },
       "name": "idx_update_route_id_bucket_rank_en_s1",
       "collation": { "locale": "en", "strength": 1 } }
   ] }',
  TRUE);
END;

RESET documentdb.alternate_index_handler_name;

-- Generated update-many plans must fan out when a non-simple collation changes
-- the meaning of the shard-key equality.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "name": "CaT" }, "u": { "$set": { "selected": "many" } }, "multi": true, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);
END;

-- Generated single-update plans use the same global sorted lookup as runtime.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selected": "one" } }, "sort": { "rank": 1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);
END;

-- A non-string _id keeps the physical equality filter while allowing the
-- matching collated compound index to provide the requested ordering.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "selected": "numeric-id" } }, "sort": { "rank": 1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);
END;

-- Generated routing failures preserve the runtime SQLSTATE and message.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
DO $capture$
BEGIN
  EXECUTE $explain$
    EXPLAIN (COSTS OFF)
    SELECT document FROM bson_aggregation_update(
      'coll_q_idx_dist_explain_db',
      '{ "update": "coll_update_route_d", "updates": [ { "q": { "name": "CaT" }, "u": { "$set": { "selected": "one" } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
  $explain$;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'SQLSTATE: %, MESSAGE: %', SQLSTATE, SQLERRM;
END;
$capture$;
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
DO $capture$
BEGIN
  EXECUTE $explain$
    EXPLAIN (COSTS OFF)
    SELECT document FROM bson_aggregation_update(
      'coll_q_idx_dist_explain_db',
      '{ "update": "coll_update_route_d", "updates": [ { "q": { "rank": 10 }, "u": { "$set": { "selected": "upsert" } }, "multi": false, "upsert": true, "collation": { "locale": "simple" } } ] }')
  $explain$;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'SQLSTATE: %, MESSAGE: %', SQLSTATE, SQLERRM;
END;
$capture$;
END;

DO $capture$
BEGIN
  EXECUTE $explain$
    EXPLAIN (COSTS OFF)
    SELECT document FROM bson_aggregation_update(
      'coll_q_idx_dist_explain_db',
      '{ "update": "coll_update_route_d", "updates": [ { "q": { "rank": 10 }, "u": { "$set": { "selected": "one" } }, "multi": false } ] }')
  $explain$;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'SQLSTATE: %, MESSAGE: %', SQLSTATE, SQLERRM;
END;
$capture$;

-- Simple collation preserves one-shard pruning for generated updates.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "name": "cat" }, "u": { "$set": { "selected": "simple-one" } }, "multi": false, "collation": { "locale": "simple" } } ] }')
$cmd$);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "name": "cat" }, "u": { "$set": { "selected": "simple-many" } }, "multi": true, "collation": { "locale": "simple" } } ] }')
$cmd$);
END;

-- An exact _id lookup without a sort uses the physical index. The deterministic
-- tie-break sorts only the bounded set of candidate rows.
BEGIN;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "_id": "cat" }, "u": { "$set": { "selected": "binary-id" } }, "multi": false } ] }')
$cmd$);
END;

-- A collation-sensitive lookup without a sort uses the matching index prefix. The
-- deterministic tie-break sorts only the bounded set of candidate rows.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selected": "collated-id" } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);
END;

-- A simple-collation _id lookup keeps the physical index and applies the
-- requested sort globally.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "_id": "cat" }, "u": { "$set": { "selected": "simple-id" } }, "sort": { "rank": 1 }, "multi": false, "collation": { "locale": "simple" } } ] }')
$cmd$);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selected": "compound" } }, "sort": { "bucket": 1, "rank": -1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_idx_dist_explain_db',
  '{ "update": "coll_update_route_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selected": "descending" } }, "sort": { "rank": -1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);
END;
