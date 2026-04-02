SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 89000000;
SET documentdb.next_collection_id TO 89000;
SET documentdb.next_collection_index_id TO 89000;

SET documentdb_api.forceUseIndexIfAvailable to on;
SET documentdb.defaultUseCompositeOpClass TO on;


-- ======================================================================
-- SECTION 1: Setup — sharded single-field and compound collections
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
-- Cleanup
-- ======================================================================

RESET documentdb_api.forceUseIndexIfAvailable;
RESET documentdb.defaultUseCompositeOpClass;
