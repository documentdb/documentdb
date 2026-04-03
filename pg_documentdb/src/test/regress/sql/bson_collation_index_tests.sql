SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 2300;
SET documentdb.next_collection_index_id TO 2300;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET enable_seqscan TO OFF;

-- ======================================================================
-- SECTION 1: Setup — single-field and compound indexes with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 7, "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 8, "a": "Date"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 9, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','single_field', '{"_id": 10, "a": null}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "single_field",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_idx_db', '{"listIndexes": "single_field"}');

SELECT documentdb_api.insert_one('coll_idx_db','compound_field', '{"_id": 1, "a": "DOG", "b": 10}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','compound_field', '{"_id": 2, "a": "dog", "b": 20}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','compound_field', '{"_id": 3, "a": "Cat", "b": 30}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','compound_field', '{"_id": 4, "a": "cat", "b": 40}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','compound_field', '{"_id": 5, "a": "Bird", "b": 50}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','compound_field', '{"_id": 6, "a": "bird", "b": 60}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "compound_field",
    "indexes": [{
      "key": {"a": 1, "b": 1},
      "name": "idx_ab_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_idx_db', '{"listIndexes": "compound_field"}');


-- ======================================================================
-- SECTION 2: $eq — equality pushdown
-- ======================================================================

-- 2.1: $eq with matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.2: $eq with no collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 2.3: $eq with different locale — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 2.4: $eq with different strength — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 2.5: $eq with numericOrdering — index should NOT be used (different ICU string)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }')
$cmd$);

-- 2.6: $eq with numeric value (non-string) and matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.6b: $eq with numeric value and mismatched collation — index SHOULD be used (non-string type)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 2.7: $eq with null value and matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.8: $eq case-insensitive match at strength=1 — "APPLE" matches "apple" and "Apple"
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.9: $eq with empty string and matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 3: $gt, $gte — range operators
-- ======================================================================

-- 3.1: $gt with matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.2: $gte with matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.3: $gt with no collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 3.4: $gte with different locale — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 3.5: $gt with numeric value and matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.5b: $gt with numeric value and mismatched collation — index SHOULD be used (non-string type)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 3.6: $gt "BANANA" case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "BANANA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "BANANA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.7: $gte "CHERRY" case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "CHERRY" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "CHERRY" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 3b: $lt, $lte — range operators
-- ======================================================================

-- 3b.1: $lt with matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.2: $lte with matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.3: $lt with no collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 3b.4: $lte with different locale — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 3b.5: $lt with numeric value and matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.5b: $lt with numeric value and mismatched collation — index SHOULD be used (non-string type)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 3b.5c: $lte with numeric value and mismatched collation — index SHOULD be used (non-string type)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 3b.6: $lte case-insensitive at strength=1 — "banana" matches "banana" and "BANANA"
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.6b: $lte "Cherry" case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "Cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "Cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.7: $lt with null value and matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 4: Combinations — $and and compound index
-- ======================================================================

-- 4.1: $and with two $eq conditions — both should push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "Apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "Apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.2: $and with $eq + $gt — both can push down with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.3: $and with $eq + $gte — both can push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "cherry" } }, { "a": { "$gte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "cherry" } }, { "a": { "$gte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.4: $and with $gt + $lt range — both push down with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "apple" } }, { "a": { "$lt": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "apple" } }, { "a": { "$lt": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.5: $and with $gte + $lte range — both push down with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.6: Implicit $and — $gt + $lt both push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "apple", "$lt": "date" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "apple", "$lt": "date" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.7: Implicit $and with $gte + $lte — both push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana", "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana", "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.8: $and with $eq + $gt — no collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 } }')
$cmd$);

-- 4.9: Compound: $eq on "a" + $gt on "b" — matching collation — both push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.10: Compound: $eq on "a" + $gte on "b" — matching collation — both push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.11: Compound: $eq on "a" + $eq on "b" — matching collation — both push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.12: Compound: $gt on first key — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$gt": "bird" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$gt": "bird" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.13: Compound: $gte on first key — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.14: Compound: $eq on first key — no collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 4.15: Compound: $eq on first key — different locale — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 4.16: Compound: case-insensitive $eq on "a" + $gt on "b" — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "DOG" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "DOG" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.17: $and with $eq + $lt — both can push down with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.18: $and with $eq + $lte — both can push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$lte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$lte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.19: Compound: $lt on first key — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$lt": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$lt": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.20: Compound: $lte on first key — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.21: Compound: $eq on "a" + $lt on "b" — matching collation — both push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$lt": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$lt": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.22: Compound: $eq on "a" + $lte on "b" — matching collation — both push down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$lte": 40 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$lte": 40 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.23: $lte "banana" AND $gt "CHERRY" — case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lte": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lte": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.24: $eq "banana" AND $gt "CHERRY" — case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.25: Compound: $lte on "a" + $lt on "b" — range on both keys
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.26: $lt on "a" AND $lte on "a" — both string ranges at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lt": "date" } }, { "a": { "$lte": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lt": "date" } }, { "a": { "$lte": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.27: $gt "bAnAnA" AND $lte "chErRy" — mixed-case range at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "bAnAnA" } }, { "a": { "$lte": "chErRy" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "bAnAnA" } }, { "a": { "$lte": "chErRy" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 5: Multiple indexes with different collations
-- ======================================================================

SELECT documentdb_api.insert_one('coll_idx_db','multi_coll', '{"_id": 1, "a": "Alpha"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','multi_coll', '{"_id": 2, "a": "alpha"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','multi_coll', '{"_id": 3, "a": "Beta"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','multi_coll', '{"_id": 4, "a": "beta"}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "multi_coll",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "multi_coll",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s3",
      "collation": {"locale": "en", "strength": 3}
    }]
  }',
  TRUE
);

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_idx_db', '{"listIndexes": "multi_coll"}');

-- 5.1: $eq with strength=1 — should use idx_a_en_s1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 5.2: $eq with strength=3 — should use idx_a_en_s3
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 5.3: $eq with no collation — neither collated index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 5.4: $eq with strength=2 — neither index matches
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 5.5: strength=1 case-insensitive — "ALPHA" matches both Alpha and alpha
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 5.6: strength=3 case-sensitive — "alpha" only matches "alpha"
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);


-- ======================================================================
-- SECTION 6: Aggregation pipeline with collation
-- ======================================================================

-- 6.1: $match with $eq — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.2: $match with $eq — no collation — index should NOT be used
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {} }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {} }')
$cmd$);

-- 6.3: $match with $gt — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.4: $match then $project — matching collation — index SHOULD be used for $eq
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.5: $match with $lt — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lt": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lt": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.6: $match with $lte — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 7: Collation-insensitive operators — index SHOULD be used
-- regardless of whether query collation matches index collation.
-- ======================================================================

-- Setup: collection with mixed types for collation-insensitive operator tests
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 1, "a": "hello"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 2, "a": "HELLO"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 3, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 4, "a": 7}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 5, "a": 255}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 6, "a": null}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 7, "a": true}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 8, "a": [1, 2, 3]}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db','insensitive_ops', '{"_id": 9}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "insensitive_ops",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1_insensitive",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- 7.1: $exists: true — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.2: $exists: true — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 7.3: $exists: false — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": false } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": false } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.4: $type "string" — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.5: $type "number" — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "number" } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "number" } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 7.6: $type "null" — no collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "null" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "null" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 7.7: $size — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.8: $size — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 7.9: $mod — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.10: $mod — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 7.11: $bitsAllSet — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.12: $bitsAllSet — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 7.13: $bitsAllClear — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllClear": 8 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllClear": 8 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.14: $bitsAnySet — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnySet": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnySet": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.15: $bitsAnyClear — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnyClear": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnyClear": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.16: $exists + $eq combination — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$exists": true } }, { "a": { "$eq": "hello" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$exists": true } }, { "a": { "$eq": "hello" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.17: $type + $gt combination — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$type": "number" } }, { "a": { "$gt": 10 } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$type": "number" } }, { "a": { "$gt": 10 } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 8: $regex — not pushed down to collated index
-- ======================================================================

-- 8.1: $regex anchored prefix — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.2: $regex anchored prefix without collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 8.3: $regex anchored prefix with different collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 8.4: $regex unanchored — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "ana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "ana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.5: $regex with case-insensitive flag — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app", "$options": "i" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app", "$options": "i" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.6: $regex combined with $eq — $eq SHOULD use index, $regex becomes filter
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [{ "a": { "$eq": "apple" } }, { "a": { "$regex": "^app" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [{ "a": { "$eq": "apple" } }, { "a": { "$regex": "^app" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 9: MinKey/MaxKey boundary pushdown — collation does not affect
-- boundary values so these should always use the collated index.
-- ======================================================================

-- 9.1: $gte MinKey — matching collation — index SHOULD be used (same as $exists: true)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 9.2: $gte MinKey — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 9.3: $gt MinKey — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 9.4: $lt MaxKey — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 9.5: $lt MaxKey — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 9.6: $lte MaxKey — mismatched collation — index SHOULD still be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);


-- ======================================================================
-- SECTION 10: Unsupported operators — single test each to confirm NOT used
-- ======================================================================

-- 10.1: $ne with matching collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.2: $in with matching collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.3: $nin with matching collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.4: $regex — collation is ignored for regex operations
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.5: $all with matching collation — $all decomposes to $eq which IS pushed down
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$all": ["apple", "APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$all": ["apple", "APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.6: $exists with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.7: $type with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.8: $or with matching collation — index should NOT be used
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "$or": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "banana" } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "$or": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "banana" } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- Cleanup
-- ======================================================================

RESET documentdb.enableExtendedExplainPlans;
RESET enable_seqscan;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb_core.enableCollation;
