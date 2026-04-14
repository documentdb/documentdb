SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 89000000;
SET documentdb.next_collection_id TO 89000;
SET documentdb.next_collection_index_id TO 89000;

SET documentdb_api.forceUseIndexIfAvailable to on;
SET documentdb.defaultUseCompositeOpClass TO on;


-- ======================================================================
-- SECTION 1: Setup — sharded single-field collection
-- ======================================================================

SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 7, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','single_field_d', '{"_id": 8, "a": null}', NULL);

SELECT documentdb_api.shard_collection('coll_idx_d_db', 'single_field_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_d_db',
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
COMMIT;

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_idx_d_db', '{"listIndexes": "single_field_d"}');


-- ======================================================================
-- SECTION 2: Correctness — results span shards correctly
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;


-- ======================================================================
-- SECTION 3: Aggregation pipeline with collation on sharded collection
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_idx_d_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_d_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
END;


-- ======================================================================
-- SECTION 4: Collation mismatch — index NOT used on sharded collection
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }');
END;


-- ======================================================================
-- SECTION 5: Delete on sharded collection with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_idx_d_db', '{ "delete": "single_field_d", "deletes": [{ "q": { "a": "apple" }, "limit": 0, "collation": { "locale": "en", "strength": 1 } }] }');
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "_id": { "$in": [1, 2] } }, "sort": { "_id": 1 } }');

SELECT documentdb_api.delete('coll_idx_d_db', '{ "delete": "single_field_d", "deletes": [{ "q": { "a": { "$gt": "cherry" } }, "limit": 0, "collation": { "locale": "en", "strength": 1 } }] }');
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": {}, "sort": { "_id": 1 } }');
END;


-- ======================================================================
-- SECTION 6: $ne on sharded collection with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;


-- ======================================================================
-- SECTION 7: $not $gt and $not $gte on sharded collection with collation
-- ======================================================================

-- $not $gt "BANANA" at strength-1 — returns docs ≤ banana plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $gte "Cherry" at strength-1 — returns docs < cherry plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gte": "Cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gte": "Cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $gt numeric with matching collation — non-string bypasses collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gt": 100 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;


-- ======================================================================
-- SECTION 8: $not $lt and $not $lte on sharded collection with collation
-- ======================================================================

-- $not $lt "CHERRY" at strength-1 — returns docs ≥ cherry plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $lte "banana" at strength-1 — returns docs > banana plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lte": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lte": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $lt numeric with matching collation — non-string bypasses collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": 100 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": 100 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;


-- ======================================================================
-- SECTION 9: Compound index on sharded collection with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_idx_d_db','compound_d', '{"_id": 1, "a": "dog", "b": 10}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','compound_d', '{"_id": 2, "a": "DOG", "b": 20}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','compound_d', '{"_id": 3, "a": "cat", "b": 30}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','compound_d', '{"_id": 4, "a": "Cat", "b": 40}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','compound_d', '{"_id": 5, "a": "bird", "b": 50}', NULL);
SELECT documentdb_api.insert_one('coll_idx_d_db','compound_d', '{"_id": 6, "a": "Bird", "b": 60}', NULL);

SELECT documentdb_api.shard_collection('coll_idx_d_db', 'compound_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_d_db',
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
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "compound_d", "filter": { "a": "dog", "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "compound_d", "filter": { "a": "dog", "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- Compound: $not $gt on "a" — matching collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "compound_d", "filter": { "a": { "$not": { "$gt": "cat" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "compound_d", "filter": { "a": { "$not": { "$gt": "cat" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- Compound: mismatched collation — index NOT used
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_d_db', '{ "find": "compound_d", "filter": { "a": "dog", "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
END;


-- ======================================================================
-- Cleanup
-- ======================================================================

RESET documentdb_api.forceUseIndexIfAvailable;
RESET documentdb.defaultUseCompositeOpClass;
