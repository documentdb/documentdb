SET citus.next_shard_id TO 95210000;
SET documentdb.next_collection_id TO 95210;
SET documentdb.next_collection_index_id TO 95210;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb_api.forceUseIndexIfAvailable TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

-- ======================================================================
-- SECTION 1: Setup — sharded single-field collection
-- ======================================================================

SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 7, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','single_field_d', '{"_id": 8, "a": null}', NULL);

SELECT documentdb_api.shard_collection('coll_ops_idx_dist_explain_db', 'single_field_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_ops_idx_dist_explain_db',
  '{
    "createIndexes": "single_field_d",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);
END;

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_ops_idx_dist_explain_db', '{"listIndexes": "single_field_d"}');

-- ======================================================================
-- SECTION 2: Correctness — results span shards correctly
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 3: Aggregation pipeline with collation on sharded collection
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_ops_idx_dist_explain_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 4: Collation mismatch — index NOT used on sharded collection
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 5: $ne on sharded collection with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 6: $not $gt and $not $gte on sharded collection with collation
-- ======================================================================

-- $not $gt "BANANA" at strength-1 — returns docs ≤ banana plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- $not $gte "Cherry" at strength-1 — returns docs < cherry plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gte": "Cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 7: $not $lt and $not $lte on sharded collection with collation
-- ======================================================================

-- $not $lt "CHERRY" at strength-1 — returns docs ≥ cherry plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- $not $lte "banana" at strength-1 — returns docs > banana plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lte": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- $not $lt numeric with matching collation — non-string bypasses collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": 100 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 8: Compound index on sharded collection with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','compound_d', '{"_id": 1, "a": "dog", "b": 10}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','compound_d', '{"_id": 2, "a": "DOG", "b": 20}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','compound_d', '{"_id": 3, "a": "cat", "b": 30}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','compound_d', '{"_id": 4, "a": "Cat", "b": 40}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','compound_d', '{"_id": 5, "a": "bird", "b": 50}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','compound_d', '{"_id": 6, "a": "Bird", "b": 60}', NULL);

SELECT documentdb_api.shard_collection('coll_ops_idx_dist_explain_db', 'compound_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_ops_idx_dist_explain_db',
  '{
    "createIndexes": "compound_d",
    "indexes": [{
      "key": {"a": 1, "b": 1},
      "name": "idx_ab_en_s1_d",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);
END;

-- Compound: $eq on "a" + $gt on "b" — matching collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "compound_d", "filter": { "a": "dog", "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- Compound: $not $gt on "a" — matching collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "compound_d", "filter": { "a": { "$not": { "$gt": "cat" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- Compound: matching collation — index used end-to-end
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "compound_d", "filter": { "a": "dog", "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;



-- ======================================================================
-- SECTION 10: $in/$nin — sharded collation index pushdown
-- ======================================================================

-- $in with matching collation — results span shards correctly

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$in": ["apple", "CHERRY"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $nin with matching collation — results span shards correctly

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "single_field_d", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $in on compound — matching collation

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "compound_d", "filter": { "a": { "$in": ["dog", "cat"] }, "b": { "$gt": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION 9: $elemMatch on sharded collection with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','elemmatch_d', '{"_id": 1, "items": ["Apple", "banana", "Cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','elemmatch_d', '{"_id": 2, "items": ["apple", "BANANA", "cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','elemmatch_d', '{"_id": 3, "items": ["APPLE", "Apple", "apple"]}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','elemmatch_d', '{"_id": 4, "items": ["Dog", "elephant", "FOX"]}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','elemmatch_d', '{"_id": 5, "items": [42, "apple", null]}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','elemmatch_d', '{"_id": 6, "items": []}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','elemmatch_d', '{"_id": 7, "other": "value"}', NULL);

SELECT documentdb_api.shard_collection('coll_ops_idx_dist_explain_db', 'elemmatch_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_ops_idx_dist_explain_db',
  '{ "createIndexes": "elemmatch_d",
     "indexes": [{ "key": {"items": 1}, "name": "idx_items_en_s1_d",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
END;

-- 9.1: UPPERCASE needle vs case-mixed sharded data — index used per shard
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "elemmatch_d", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- 9.2: numeric needle bypasses collation — index still used across shards
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "elemmatch_d", "filter": { "items": { "$elemMatch": { "$eq": 42 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- 9.3: mixed-case range across shards — both bounds collation-aware
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_ops_idx_dist_explain_db', '{ "aggregate": "elemmatch_d", "pipeline": [ { "$match": { "items": { "$elemMatch": { "$gte": "Banana", "$lte": "Dog" } } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
END;

-- 9.4: mismatched query collation — index pushdown declined; runtime fallback
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "elemmatch_d", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);
END;

-- ======================================================================
-- SECTION 11: Sharded collated index — predicate pushdown + ORDER BY shapes
-- ======================================================================

SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 1, "a": "item20"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 2, "a": "item3"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 3, "a": "item11"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 4, "a": "item1"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 5, "a": "item100"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 6, "a": "item2"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 7, "a": "item40"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_pure_d', '{"_id": 8, "a": "item12"}', NULL);
SELECT documentdb_api.shard_collection('coll_ops_idx_dist_explain_db', 'ord_pure_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_ops_idx_dist_explain_db',
  '{ "createIndexes": "ord_pure_d",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_num_ord_pure",
                   "collation": {"locale": "en", "numericOrdering": true} }] }', TRUE);
END;

SELECT collection_id AS ord_pure_d_id FROM documentdb_api_catalog.collections WHERE collection_name = 'ord_pure_d' AND database_name = 'coll_ops_idx_dist_explain_db' \gset
ANALYZE documentdb_data.documents_:ord_pure_d_id;

SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_compound_d', '{"_id": 1, "a": "item1", "b": "sub20"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_compound_d', '{"_id": 2, "a": "item2", "b": "sub3"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_compound_d', '{"_id": 3, "a": "item2", "b": "sub11"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_compound_d', '{"_id": 4, "a": "item10", "b": "sub10"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_compound_d', '{"_id": 5, "a": "item10", "b": "sub2"}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_compound_d', '{"_id": 6, "a": "item3", "b": "sub2"}', NULL);
SELECT documentdb_api.shard_collection('coll_ops_idx_dist_explain_db', 'ord_compound_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_ops_idx_dist_explain_db',
  '{ "createIndexes": "ord_compound_d",
     "indexes": [{ "key": {"a": 1, "b": 1}, "name": "idx_ab_en_num_ord_compound",
                   "collation": {"locale": "en", "numericOrdering": true} }] }', TRUE);
END;

SELECT collection_id AS ord_compound_d_id FROM documentdb_api_catalog.collections WHERE collection_name = 'ord_compound_d' AND database_name = 'coll_ops_idx_dist_explain_db' \gset
ANALYZE documentdb_data.documents_:ord_compound_d_id;

SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_id_d', '{"_id": "item1", "a": 1}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_id_d', '{"_id": "item10", "a": 2}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_id_d', '{"_id": "item2", "a": 3}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_id_d', '{"_id": "item20", "a": 4}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_id_d', '{"_id": "item3", "a": 5}', NULL);
SELECT documentdb_api.insert_one('coll_ops_idx_dist_explain_db','ord_id_d', '{"_id": "item30", "a": 6}', NULL);
SELECT documentdb_api.shard_collection('coll_ops_idx_dist_explain_db', 'ord_id_d', '{ "_id": "hashed" }', false);

-- 11a: ASC sort, no LIMIT — coordinator does a plain Sort (per-shard index
--      ordering is not preserved across shards in a hash-distributed table)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_pure_d", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 }, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11b: ASC sort + LIMIT — per-shard Index Scan with Order By: |<> pushdown
--      (sort is index-driven on each shard); coordinator Sort over per-shard top-N
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_pure_d", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 }, "limit": 4, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11c: DESC sort + LIMIT — per-shard Index Scan with Order By: |<> pushdown (DESC);
--      coordinator Sort DESC over per-shard top-N
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_pure_d", "filter": { "a": { "$exists": true } }, "sort": { "a": -1 }, "limit": 4, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11d: bounded filter + ASC sort + LIMIT — per-shard Index Scan with bounded Index Cond
--      AND Order By: |<> pushdown; coordinator Sort over per-shard top-N
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_pure_d", "filter": { "a": { "$gte": "item10" } }, "sort": { "a": 1 }, "limit": 4, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11e: compound — equality on leading key + sort on second key + LIMIT — per-shard
--      compound Index Scan with eq Index Cond AND Order By: |<> pushdown on secondary
--      key; coordinator Sort over per-shard top-N
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_compound_d", "filter": { "a": "item10" }, "sort": { "b": 1 }, "limit": 4, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11f: locale mismatch (query fr vs index en) — existence scan still uses the index;
--      MinKey Index Cond carries the query's fr numericOrdering collation; coordinator Sort (re-sort)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_pure_d", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 }, "collation": { "locale": "fr", "numericOrdering": true } }')
$cmd$);
END;

-- 11g: numericOrdering mismatch (query default vs index numericOrdering true) — existence scan still uses the index;
--      MinKey Index Cond carries the query's non-numeric collation; coordinator Sort (re-sort)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_pure_d", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 }, "collation": { "locale": "en" } }')
$cmd$);
END;

-- 11h: _id ASC sort with collation — _id_ PK rejected under collation; falls back to per-shard Seq Scan
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_id_d", "filter": {}, "sort": { "_id": 1 }, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11i: _id DESC sort with collation — _id_ PK rejected under collation; falls back to per-shard Seq Scan
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_id_d", "filter": {}, "sort": { "_id": -1 }, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11j: _id eq filter + _id collated sort — PK rejected for both filter and sort under collation;
--      per-shard Seq Scan + Filter (point seek not available); coordinator Sort (re-sort)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_id_d", "filter": { "_id": "item2" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "numericOrdering": true } }')
$cmd$);
END;

-- 11k: uncollated query against the collated index — existence scan still uses the index
--      with no collation in the MinKey Index Cond; coordinator Sort (re-sort)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_ops_idx_dist_explain_db', '{ "find": "ord_pure_d", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 } }')
$cmd$);
END;

-- ======================================================================
-- Cleanup
-- ======================================================================

RESET documentdb_api.forceUseIndexIfAvailable;
RESET documentdb.defaultUseCompositeOpClass;
