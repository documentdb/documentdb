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

-- 2.6: $eq with null value and matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.7: $eq case-insensitive match at strength=1 — "APPLE" matches "apple" and "Apple"
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.8: $eq with empty string and matching collation
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

-- 3.5: $gt "BANANA" case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "BANANA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$gt": "BANANA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.6: $gte "CHERRY" case-insensitive at strength=1
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

-- 3b.5: $lte case-insensitive at strength=1 — "banana" matches "banana" and "BANANA"
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.6: $lte "Cherry" case-insensitive at strength=1
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
-- SECTION 10: $ne — not-equal pushdown (complement of $eq)
-- ======================================================================

-- 10.1: $ne with matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.2: $ne case-insensitive — "APPLE" excludes both "apple" and "Apple" at strength=1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.3: $ne with no collation — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 10.4: $ne with different locale — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 10.5: $ne with null and matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.6: $ne "bAnAnA" mixed-case at strength=1 — excludes both "banana" and "BANANA"
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "bAnAnA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "bAnAnA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.7: $ne with empty string and matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.8: $ne combined with $gt — both push down with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gt": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gt": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.9: $ne combined with $lte — both push down with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.10: $ne on aggregation pipeline — matching collation — index SHOULD be used
SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$ne": "date" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_idx_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$ne": "date" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.11: Compound: $ne on "a" + $eq on "b" — matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "dog" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "dog" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.11b: Compound: $ne "DOG" (uppercase) — composite recheck uses collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.12: $ne with different strength — index should NOT be used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 10.13: $ne "DATE" case-insensitive — excludes both date and Date
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "DATE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.14: $ne "zebra" — value not in collection, returns all docs
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": "zebra" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.15: $ne "cherry" AND $gte "banana" AND $lte "date" — $ne within range
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gte": "banana" } }, { "a": { "$lte": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gte": "banana" } }, { "a": { "$lte": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.16: Multiple $ne — $ne "apple" AND $ne "banana"
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$ne": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$ne": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.17: Compound: $ne "DOG" AND $eq 20 — $ne excludes both dog variants, $eq 20 matches dog → empty
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.18: Compound: $ne "cat" AND $lt 50 — excludes Cat(30),cat(40), leaves Bird(50→no), bird(60→no), DOG(10),dog(20)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.19: $ne on multi_coll with strength=1 — picks idx_a_en_s1
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.20: $ne on multi_coll with strength=3 — case-sensitive, "ALPHA" not stored so nothing excluded
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 10.20b: $ne "alpha" at strength-3 — excludes only exact "alpha"(2), NOT "Alpha"(1); contrast with strength-1 (10.19)
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 10.21: $ne on insensitive_ops "HELLO" — case-insensitive excludes hello+HELLO
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": "HELLO" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": "HELLO" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.22: $ne boolean (true) on insensitive_ops
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.23: $ne + $eq on same field — $ne "banana" AND $eq "banana" — contradictory, empty result
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "banana" } }, { "a": { "$eq": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.24: $ne "APPLE" with strength=3 on multi_coll — "APPLE" not stored, nothing excluded
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 10.25: $ne $minKey with matching collation — boundary test
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 10b: Non-string type bypass with MISMATCHED collation
-- ======================================================================

-- 10b.1: $ne numeric with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.2: $eq numeric with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.3: $gt numeric with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": 1 } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": 1 } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 10b.4: $eq bool with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.5: $ne null with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 10b.6: $lt numeric with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.7: $gt bool with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": false } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": false } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.8: $lte bool with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.9: $eq regex value with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": { "$regularExpression": { "pattern": "^app", "options": "" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$eq": { "$regularExpression": { "pattern": "^app", "options": "" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.10: $gte numeric with mismatched collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.11: $eq array with mismatched collation — index NOT used because arrays can nest strings
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.12: $eq array with matching collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10b.13: $ne array with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.14: $gt array with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.15: $gte array with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.16: $lt array with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.17: $lte array with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.18: $eq document with mismatched collation — index NOT used because documents can nest strings
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.19: $eq document with matching collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10b.20: $ne document with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.21: $gt document with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.22: $gte document with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.23: $lt document with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.24: $lte document with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.25: $eq nested document with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.26: $eq nested document with matching collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10b.27: $eq array of documents with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.28: $eq array of documents with matching collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10b.29: $eq nested array with mismatched collation — index NOT used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.30: $eq nested array with matching collation — index used
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10b.31: $ne nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.32: $gt nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.33: $gte nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.34: $lt nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.35: $lte nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.36: $ne array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.37: $gt array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.38: $gte array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.39: $lt array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.40: $lte array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.41: $ne nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.42: $gt nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.43: $gte nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.44: $lt nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 10b.45: $lte nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);


-- ======================================================================
-- SECTION 11: Mixed collation-aware and non-collation-aware type bounds
-- in a single range query. The numeric bound bypasses collation checks
-- while the string bound requires matching collation.
-- ======================================================================

-- 11.1: $gte numeric + $lt string with matching collation — both use index
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.2: $gt string + $lte numeric with matching collation
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "banana" } }, { "a": { "$lte": 100 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "banana" } }, { "a": { "$lte": 100 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.3: $gte numeric + $lt string with MISMATCHED collation — numeric uses index, string does NOT
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 11.4: $ne string + $gte numeric with mismatched collation — numeric uses index, string $ne does NOT
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$gte": 10 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$gte": 10 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);


-- ======================================================================
-- SECTION 12: Other operators — collation index behavior
-- ======================================================================

-- 12.1: $exists — collation-insensitive, always uses index
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.2: $type — collation-insensitive, always uses index
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.3: $all — decomposes to $eq, uses collation index
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$all": ["apple", "APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$all": ["apple", "APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.4: $in — not yet supported, falls back to _id scan
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.5: $nin — not yet supported, falls back to _id scan
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.6: $regex — not collation-aware, falls back to _id scan
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.7: $or — not yet supported, falls back to _id scan
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
