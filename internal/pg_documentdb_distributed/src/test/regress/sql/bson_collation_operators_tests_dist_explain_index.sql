SET citus.next_shard_id TO 95210000;
SET documentdb.next_collection_id TO 95210;
SET documentdb.next_collection_index_id TO 95210;

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb_api.forceUseIndexIfAvailable TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

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
-- Cleanup
-- ======================================================================

RESET documentdb_api.forceUseIndexIfAvailable;
RESET documentdb.defaultUseCompositeOpClass;
