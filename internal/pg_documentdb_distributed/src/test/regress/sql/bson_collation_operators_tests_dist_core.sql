SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- ======================================================================
-- SECTION 1: Setup — sharded single-field collection
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 7, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','single_field_d', '{"_id": 8, "a": null}', NULL);

SELECT documentdb_api.shard_collection('coll_op_dist_db', 'single_field_d', '{ "_id": "hashed" }', false);

-- ======================================================================
-- SECTION 2: Correctness — results span shards correctly
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION 3: Aggregation pipeline with collation on sharded collection
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_op_dist_db', '{ "aggregate": "single_field_d", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION 4: Collation mismatch — index NOT used on sharded collection
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }');
END;

-- ======================================================================
-- SECTION 5: Delete on sharded collection with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_op_dist_db', '{ "delete": "single_field_d", "deletes": [{ "q": { "a": "apple" }, "limit": 0, "collation": { "locale": "en", "strength": 1 } }] }');
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "_id": { "$in": [1, 2] } }, "sort": { "_id": 1 } }');

SELECT documentdb_api.delete('coll_op_dist_db', '{ "delete": "single_field_d", "deletes": [{ "q": { "a": { "$gt": "cherry" } }, "limit": 0, "collation": { "locale": "en", "strength": 1 } }] }');
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": {}, "sort": { "_id": 1 } }');
END;

-- ======================================================================
-- SECTION 6: $ne on sharded collection with collation
-- ======================================================================

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION 7: $not $gt and $not $gte on sharded collection with collation
-- ======================================================================

-- $not $gt "BANANA" at strength-1 — returns docs ≤ banana plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $gte "Cherry" at strength-1 — returns docs < cherry plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gte": "Cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $gt numeric with matching collation — non-string bypasses collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$gt": 100 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION 8: $not $lt and $not $lte on sharded collection with collation
-- ======================================================================

-- $not $lt "CHERRY" at strength-1 — returns docs ≥ cherry plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $lte "banana" at strength-1 — returns docs > banana plus non-strings
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lte": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $not $lt numeric with matching collation — non-string bypasses collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$not": { "$lt": 100 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION 9: Compound index on sharded collection with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_dist_db','compound_d', '{"_id": 1, "a": "dog", "b": 10}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','compound_d', '{"_id": 2, "a": "DOG", "b": 20}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','compound_d', '{"_id": 3, "a": "cat", "b": 30}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','compound_d', '{"_id": 4, "a": "Cat", "b": 40}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','compound_d', '{"_id": 5, "a": "bird", "b": 50}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','compound_d', '{"_id": 6, "a": "Bird", "b": 60}', NULL);

SELECT documentdb_api.shard_collection('coll_op_dist_db', 'compound_d', '{ "_id": "hashed" }', false);

-- Compound: $eq on "a" + $gt on "b" — matching collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "compound_d", "filter": { "a": "dog", "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- Compound: $not $gt on "a" — matching collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "compound_d", "filter": { "a": { "$not": { "$gt": "cat" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- ======================================================================
-- SECTION 10: $in/$nin on sharded collection with collation
-- ======================================================================

-- $in matching collation — case-insensitive across shards
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$in": ["apple", "CHERRY"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $nin matching collation — excludes case-equivalents
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- $in with no collation — exact-case match only
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$in": ["apple", "cherry"] } }, "sort": { "_id": 1 } }');
END;

-- $in with null — non-string element matches null doc
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": { "a": { "$in": [null, 42] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- delete with $nin + matching collation on sharded collection
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT documentdb_api.delete('coll_op_dist_db', '{ "delete": "single_field_d", "deletes": [{ "q": { "a": { "$nin": ["apple", "banana", "cherry"] } }, "limit": 0, "collation": { "locale": "en", "strength": 1 } }] }');
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "single_field_d", "filter": {}, "sort": { "_id": 1 } }');
END;

-- $in on compound — matching collation
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "compound_d", "filter": { "a": { "$in": ["dog", "cat"] }, "b": { "$gt": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

RESET documentdb_api.forceUseIndexIfAvailable;
RESET documentdb.defaultUseCompositeOpClass;

-- ======================================================================
-- SECTION 10: $elemMatch on sharded collection with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_dist_db','elemmatch_d', '{"_id": 1, "items": ["Apple", "banana", "Cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','elemmatch_d', '{"_id": 2, "items": ["apple", "BANANA", "cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','elemmatch_d', '{"_id": 3, "items": ["APPLE", "Apple", "apple"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','elemmatch_d', '{"_id": 4, "items": ["Dog", "elephant", "FOX"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','elemmatch_d', '{"_id": 5, "items": [42, "apple", null]}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','elemmatch_d', '{"_id": 6, "items": []}', NULL);
SELECT documentdb_api.insert_one('coll_op_dist_db','elemmatch_d', '{"_id": 7, "other": "value"}', NULL);

SELECT documentdb_api.shard_collection('coll_op_dist_db', 'elemmatch_d', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_dist_db',
  '{ "createIndexes": "elemmatch_d",
     "indexes": [{ "key": {"items": 1}, "name": "idx_items_en_s1_d",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
COMMIT;

-- 10.1: UPPERCASE needle vs case-mixed sharded data
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "elemmatch_d", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- 10.2: Numeric needle bypasses collation — only doc 5
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "elemmatch_d", "filter": { "items": { "$elemMatch": { "$eq": 42 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
END;

-- 10.3: mixed-case range across shards $gte "Banana" $lte "Dog"
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('coll_op_dist_db', '{ "aggregate": "elemmatch_d", "pipeline": [ { "$match": { "items": { "$elemMatch": { "$gte": "Banana", "$lte": "Dog" } } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
END;

-- 10.4: mismatched query collation (de vs en index) — runtime fallback
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_op_dist_db', '{ "find": "elemmatch_d", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
END;

-- ======================================================================
-- CLEANUP
-- ======================================================================
SELECT documentdb_api.drop_collection('coll_op_dist_db', 'compound_d');
SELECT documentdb_api.drop_collection('coll_op_dist_db', 'elemmatch_d');
SELECT documentdb_api.drop_collection('coll_op_dist_db', 'single_field_d');
