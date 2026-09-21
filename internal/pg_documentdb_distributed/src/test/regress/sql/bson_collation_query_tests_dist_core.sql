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
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
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
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "coll_agg_d", "pipeline": [ { "$match": { "_id": { "$eq": "CAT" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
END;

-- Numeric _id with collation: not collation-aware, single shard.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_q_dist_db', '{ "find": "coll_agg_d", "filter": { "_id": { "$eq": 2 } }, "sort": { "_id": 1 }, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
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
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
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
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"a": "CaT" }, "limit": 0, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_delete_d');
ROLLBACK;

-- deleteOne errors when no _id and no shard-key filter.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"b": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
END;

-- deleteOne errors with collation-aware shard key value filter.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"a": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 3}}]}');
END;

-- deleteOne with both _id and shard key filter succeeds.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"_id": "CaT", "a": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_delete_d');
ROLLBACK;

-- ======================================================================
-- SECTION 5: Delete on sharded single_field_d with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
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
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT" }', '{}', 'en-u-ks-level1');
END;

-- Numeric shard-key value: not collation-aware → single shard.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 3 }', '{}', 'en-u-ks-level1');
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
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": "CAT", "a": "CAT" }', '{}', 'en-u-ks-level1');
END;

-- Mixed-type compound filter (numeric _id + string a): the collated
-- string portion still prevents pruning; query fans out.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_qm_d') WHERE documentdb_api_internal.bson_query_match(document, '{ "_id": 1, "a": "CAT" }', '{}', 'en-u-ks-level1');
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
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db',
    '{ "aggregate": "coll_graph_src_d", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst_d", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 1} }');
END;

-- ======================================================================
-- SECTION: collation-aware query and count on a string _id (sharded)
-- ======================================================================
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_id_d', '{ "_id": "cat", "n": 1 }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_id_d', '{ "_id": "Cat", "n": 2 }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_id_d', '{ "_id": "CAT", "n": 3 }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_id_d', '{ "_id": "dog", "n": 4 }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_id_d', '{ "_id": "Dog", "n": 5 }');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_id_d', '{ "_id": "hashed" }', false);

-- equality on a string _id under collation returns every case variant
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_q_dist_db',
    '{ "find": "coll_id_d", "filter": { "_id": "cat" }, "sort": { "n": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- range on a string _id under collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_q_dist_db',
    '{ "find": "coll_id_d", "filter": { "_id": { "$gte": "cat" } }, "sort": { "n": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- covered $count on a string _id under collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db',
    '{ "aggregate": "coll_id_d", "pipeline": [ { "$match": { "_id": "cat" } }, { "$count": "c" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
END;

-- count command on a string _id honors collation across shards
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_count('coll_q_dist_db',
    '{ "count": "coll_id_d", "query": { "_id": "cat" }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_count('coll_q_dist_db',
    '{ "count": "coll_id_d", "query": { "_id": { "$gte": "cat" } }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION: $max/$min/$maxN/$minN expression honors collation across shards
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_minmax_d', '{ "_id": 1, "vals": ["a", "A", "á", "b"] }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_minmax_d', '{ "_id": 2, "vals": ["10", "2", "1"] }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_minmax_d', '{ "_id": 3, "vals": ["apple", "Banana", "cherry", "APPLE"] }');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_minmax_d', '{ "_id": "hashed" }', false);

-- Strength 1 (case- and accent-insensitive): values that compare equal under the
-- collation follow the documented operator-specific tie order even though
-- rows fan out across shards ($sort on _id makes the cross-shard order stable).
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL citus.enable_local_execution TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "coll_minmax_d", "pipeline": [ { "$project": { "mx": { "$max": "$vals" }, "mn": { "$min": "$vals" }, "mxn": { "$maxN": { "input": "$vals", "n": 2 } }, "mnn": { "$minN": { "input": "$vals", "n": 2 } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 }, "cursor": {} }');
END;

-- numericOrdering on a single-shard route (numeric _id equality): "1" < "2" < "10".
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL citus.enable_local_execution TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "coll_minmax_d", "pipeline": [ { "$match": { "_id": 2 } }, { "$project": { "mx": { "$max": "$vals" }, "mn": { "$min": "$vals" }, "mxn": { "$maxN": { "input": "$vals", "n": 2 } }, "mnn": { "$minN": { "input": "$vals", "n": 2 } } } } ], "collation": { "locale": "en", "numericOrdering": true }, "cursor": {} }');
END;

-- Without a command collation the same pipeline falls back to binary comparison.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL citus.enable_local_execution TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_q_dist_db', '{ "aggregate": "coll_minmax_d", "pipeline": [ { "$project": { "mx": { "$max": "$vals" }, "mn": { "$min": "$vals" }, "mxn": { "$maxN": { "input": "$vals", "n": 2 } }, "mnn": { "$minN": { "input": "$vals", "n": 2 } } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }');
END;

-- ======================================================================
-- SECTION: distinct with collation across shards
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_distinct_d', '{ "_id": 1, "a": "cafe", "nested": { "a": "cafe" }, "arr": [ "cafe", "tea" ], "group": "one" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_distinct_d', '{ "_id": 2, "a": "CAFE", "nested": { "a": "CAFE" }, "arr": [ "CAFE" ], "group": "ONE" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_distinct_d', '{ "_id": 3, "a": "tea", "nested": { "a": "tea" }, "arr": [ "TEA", "coffee" ], "group": "two" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_distinct_d', '{ "_id": 4, "a": "TEA", "nested": { "a": "TEA" }, "arr": [ "tea" ], "group": "TWO" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_distinct_visible_d', '{ "_id": 1, "a": "cafe" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_distinct_visible_d', '{ "_id": 2, "a": "caf\u00e9" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_distinct_visible_d', '{ "_id": 3, "a": "th\u00e9" }');

SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_distinct_d', '{ "_id": "hashed" }', false);
SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_distinct_visible_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL citus.enable_local_execution TO off;

-- Scalar values in separate equivalence classes have a stable full response.
SELECT document FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_visible_d", "key": "a", "collation": { "locale": "fr", "strength": 2 } }');

-- Collated equivalence classes are combined after gathering rows from all shards.
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_d", "key": "a", "collation": { "locale": "en", "strength": 1 } }');

-- Strength 2 still folds case for these unaccented values.
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_d", "key": "a", "collation": { "locale": "en", "strength": 2 } }');

-- The command collation applies to both the query predicate and distinct values.
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_d", "key": "a", "query": { "group": "ONE" }, "collation": { "locale": "en", "strength": 1 } }');

-- Dotted and array paths are deduplicated again after gathering shard results.
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_d", "key": "nested.a", "collation": { "locale": "en", "strength": 1 } }');
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_d", "key": "arr", "collation": { "locale": "en", "strength": 1 } }');

-- Collated range filtering runs before global distinct deduplication.
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_d", "key": "group", "query": { "a": { "$gte": "cafe", "$lt": "tea" } }, "collation": { "locale": "en", "strength": 1 } }');

-- Binary comparison keeps case variants separate.
SELECT document AS uncollated_distinct_document
FROM documentdb_api.distinct_query(
  'coll_q_dist_db',
  '{ "distinct": "coll_distinct_d", "key": "a" }') \gset

SELECT jsonb_array_length(actual_values) = 4
       AND actual_values @> '["CAFE", "TEA", "cafe", "tea"]'::jsonb
       AND actual_values <@ '["CAFE", "TEA", "cafe", "tea"]'::jsonb AS values_match
FROM (
  SELECT (:'uncollated_distinct_document'::jsonb) -> 'values' AS actual_values
) response;
END;

-- deleteOne without a shard-key filter uses the _id filter to find the shard.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_q_dist_db', '{ "delete": "coll_delete_d", "deletes": [ { "q": {"_id": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
ROLLBACK;

-- ======================================================================
-- SECTION: update document selection with collation on sharded collections
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_select_d', '{ "_id": "cat", "name": "cat", "bucket": 1, "rank": 10 }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_select_d', '{ "_id": "CAT", "name": "CAT", "bucket": 1, "rank": 1 }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_select_d', '{ "_id": "dog", "name": "dog", "bucket": 2, "rank": 5 }');
SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_update_select_d', '{ "name": "hashed" }', false);

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_worker_one_d', '{ "_id": 1, "shard": 1, "name": "cat" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_worker_one_d', '{ "_id": 2, "shard": 2, "name": "dog" }');
SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_update_worker_one_d', '{ "shard": "hashed" }', false);

SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_unsharded_d', '{ "_id": 1, "name": "cat" }');
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_unsharded_d', '{ "_id": 2, "name": "CAT" }');

-- The non-transactional unsharded batch path serializes the client-shaped
-- collation document and reparses it on the worker.
SET documentdb_core.enableCollation TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
CALL documentdb_api.update_bulk(
    'coll_q_dist_db',
    '{ "update": "coll_update_unsharded_d", "updates": [ { "q": { "name": "CaT" }, "u": { "$set": { "selected": true } }, "multi": true, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_unsharded_d') ORDER BY object_id;

-- Semantic collation errors from the worker are indexed write errors, and an
-- unordered batch preserves valid writes before and after them.
CALL documentdb_api.update_bulk(
    'coll_q_dist_db',
    '{ "update": "coll_update_unsharded_d", "ordered": false, "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "beforeError": true } }, "multi": false }, { "q": { "_id": 1 }, "u": { "$set": { "invalidLocale": true } }, "multi": false, "collation": { "locale": "invalid_locale_xyz" } }, { "q": { "_id": 2 }, "u": { "$set": { "afterError": true } }, "multi": false } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_unsharded_d') ORDER BY object_id;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb_core.enableCollation;

-- A collation-sensitive shard-key equality must fan out rather than prune to
-- the shard selected by the query literal's binary hash.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO off;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "name": "CaT" }, "u": { "$set": { "selected": "coordinator" } }, "multi": true, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d') ORDER BY object_id;
ROLLBACK;

-- The update-many worker path preserves the collation and has the same fanout.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "name": "CaT" }, "u": { "$set": { "selected": "worker" } }, "multi": true, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d') ORDER BY object_id;
ROLLBACK;

-- The update-many worker path pushes down the parsed collation string, which
-- the coordinator produces inside the per-update error boundary. An invalid
-- collation therefore stays an indexed write error here as well, instead of
-- failing the whole command before any update runs.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "ordered": false, "updates": [ { "q": { "name": "CaT" }, "u": { "$set": { "workerBeforeError": true } }, "multi": true, "collation": { "locale": "en", "strength": 1 } }, { "q": { "name": "CaT" }, "u": { "$set": { "workerInvalidLocale": true } }, "multi": true, "collation": { "locale": "invalid_locale_xyz" } }, { "q": { "name": "cat" }, "u": { "$set": { "workerAfterError": true } }, "multi": true } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d') ORDER BY object_id;
ROLLBACK;

-- The global _id lookup applies the requested sort before choosing a shard.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selectedWithoutSort": true } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_one_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "selectedWithoutSort": true }';
ROLLBACK;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selectedBySort": "ascending" } }, "sort": { "rank": 1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "CAT", "selectedBySort": "ascending" }';
ROLLBACK;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selectedBySort": "descending" } }, "sort": { "rank": -1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "cat", "selectedBySort": "descending" }';
ROLLBACK;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selectedBySort": "compound" } }, "sort": { "bucket": 1, "rank": -1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "cat", "selectedBySort": "compound" }';
ROLLBACK;

-- Global string ordering must use the operation collation, not binary ordering.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "cat" }, "u": { "$set": { "sortName": "apple" } }, "multi": false }, { "q": { "_id": "CAT" }, "u": { "$set": { "sortName": "Zebra" } }, "multi": false } ] }');
SELECT document FROM bson_aggregation_find('coll_q_dist_db', '{ "find": "coll_update_select_d", "filter": { "_id": { "$in": [ "cat", "CAT" ] } }, "sort": { "sortName": 1 }, "limit": 1 }');

SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selectedByStringSort": "ascending" } }, "sort": { "sortName": 1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "cat", "selectedByStringSort": "ascending" }';

SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT" }, "u": { "$set": { "selectedByStringSort": "descending" } }, "sort": { "sortName": -1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "CAT", "selectedByStringSort": "descending" }';
ROLLBACK;

-- Additional predicates and command variables participate in global
-- candidate selection before the shard is chosen.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT", "rank": { "$gte": 5 } }, "u": { "$set": { "selectedBySort": "filtered" } }, "sort": { "rank": 1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "cat", "selectedBySort": "filtered" }';
ROLLBACK;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "CaT", "$expr": { "$eq": [ "$rank", "$$targetRank" ] } }, "u": { "$set": { "selectedBySort": "variable" } }, "sort": { "rank": 1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ], "let": { "targetRank": 10 } }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "cat", "selectedBySort": "variable" }';
ROLLBACK;

-- A single-document update cannot route only by a collation-sensitive shard key.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "name": "CaT" }, "u": { "$set": { "selected": "one" } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
ROLLBACK;

-- A numeric shard-key equality routes to one worker, which must preserve the
-- collation while selecting the matching document there.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_worker_one_d", "updates": [ { "q": { "shard": 1, "name": "CAT" }, "u": { "$set": { "selected": true } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_worker_one_d') ORDER BY object_id;
ROLLBACK;

-- A non-string _id uses exact routing even when the operation also supplies
-- a collation and sort.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_worker_one_d", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "selectedById": true } }, "sort": { "name": -1 }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_worker_one_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": 1, "selectedById": true }';
ROLLBACK;

-- Simple collation is binary and preserves exact shard-key routing for
-- single-document updates and upserts.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "name": "cat" }, "u": { "$set": { "selected": "simple" } }, "multi": false, "collation": { "locale": "simple" } } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d') ORDER BY object_id;
ROLLBACK;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "cat" }, "u": { "$set": { "selected": "simple-id-sort" } }, "sort": { "rank": 1 }, "multi": false, "collation": { "locale": "simple" } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "cat", "selected": "simple-id-sort" }';
ROLLBACK;

-- Exact _id values can repeat on different shards, so candidate selection
-- must apply the requested sort before choosing a shard.
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_duplicate_id_d', '{ "_id": "duplicate", "name": 1, "rank": 10 }');
SELECT documentdb_api.shard_collection('coll_q_dist_db', 'coll_update_duplicate_id_d', '{ "name": "hashed" }', false);
SELECT documentdb_api.insert_one('coll_q_dist_db', 'coll_update_duplicate_id_d', '{ "_id": "duplicate", "name": 2, "rank": 1 }');

BEGIN;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_duplicate_id_d", "updates": [ { "q": { "_id": "duplicate" }, "u": { "$set": { "selectedByExactIdSort": "ascending" } }, "sort": { "rank": 1 }, "multi": false } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_duplicate_id_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "duplicate", "name": 2, "selectedByExactIdSort": "ascending" }';
ROLLBACK;

BEGIN;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_duplicate_id_d", "updates": [ { "q": { "_id": "duplicate" }, "u": { "$set": { "selectedByExactIdSort": "descending" } }, "sort": { "rank": -1 }, "multi": false } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_duplicate_id_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "duplicate", "name": 1, "selectedByExactIdSort": "descending" }';
ROLLBACK;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_duplicate_id_d", "updates": [ { "q": { "_id": "duplicate" }, "u": { "$set": { "selectedByExactIdSort": "simple-descending" } }, "sort": { "rank": -1 }, "multi": false, "collation": { "locale": "simple" } } ] }');
SELECT COUNT(*) = 1 AS selected_expected_document
FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_duplicate_id_d')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": "duplicate", "name": 1, "selectedByExactIdSort": "simple-descending" }';
ROLLBACK;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_api.update('coll_q_dist_db', '{ "update": "coll_update_select_d", "updates": [ { "q": { "_id": "simple-upsert", "name": "fox" }, "u": { "$set": { "selected": "simple-upsert" } }, "multi": false, "upsert": true, "collation": { "locale": "simple" } } ] }');
SELECT document FROM documentdb_api.collection('coll_q_dist_db', 'coll_update_select_d') ORDER BY object_id;
ROLLBACK;

-- ======================================================================
-- CLEANUP
-- ======================================================================
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_agg_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_minmax_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_delete_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_distinct_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_distinct_visible_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_graph_dst_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_graph_src_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_lookup_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_id_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_qm_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_update_select_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_update_duplicate_id_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_update_unsharded_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'coll_update_worker_one_d');
SELECT documentdb_api.drop_collection('coll_q_dist_db', 'single_field_d');
