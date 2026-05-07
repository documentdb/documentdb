SET citus.next_shard_id TO 9500000;
SET documentdb.next_collection_id TO 9500;
SET documentdb.next_collection_index_id TO 9500;

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET enable_seqscan TO OFF;

-- ======================================================================
-- SECTION 1: Setup — single-field and compound indexes with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 7, "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 8, "a": "Date"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 9, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','single_field', '{"_id": 10, "a": null}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
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

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_operators_index_explain_db', '{"listIndexes": "single_field"}');

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','compound_field', '{"_id": 1, "a": "DOG", "b": 10}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','compound_field', '{"_id": 2, "a": "dog", "b": 20}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','compound_field', '{"_id": 3, "a": "Cat", "b": 30}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','compound_field', '{"_id": 4, "a": "cat", "b": 40}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','compound_field', '{"_id": 5, "a": "Bird", "b": 50}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','compound_field', '{"_id": 6, "a": "bird", "b": 60}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
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

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_operators_index_explain_db', '{"listIndexes": "compound_field"}');

-- ======================================================================
-- SECTION 2: $eq — equality pushdown
-- ======================================================================

-- 2.1: $eq with matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.2: $eq with no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 2.3: $eq with different locale — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 2.4: $eq with different strength — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 2.5: $eq with numericOrdering — index should NOT be used (different ICU string)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }')
$cmd$);

-- 2.6: $eq with null value and matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.7: $eq case-insensitive match at strength=1 — "APPLE" matches "apple" and "Apple"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.8: $eq with empty string and matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 3: $gt, $gte — range operators
-- ======================================================================

-- 3.1: $gt with matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.2: $gte with matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.3: $gt with no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 3.4: $gte with different locale — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 3.5: $gt "BANANA" case-insensitive at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gt": "BANANA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.6: $gte "CHERRY" case-insensitive at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gte": "CHERRY" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 3b: $lt, $lte — range operators
-- ======================================================================

-- 3b.1: $lt with matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.2: $lte with matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.3: $lt with no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 3b.4: $lte with different locale — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 3b.5: $lte case-insensitive at strength=1 — "banana" matches "banana" and "BANANA"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.6: $lte "Cherry" case-insensitive at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lte": "Cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3b.7: $lt with null value and matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lt": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 4: Combinations — $and and compound index
-- ======================================================================

-- 4.1: $and with two $eq conditions — both should push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "Apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.2: $and with $eq + $gt — both can push down with matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.3: $and with $eq + $gte — both can push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "cherry" } }, { "a": { "$gte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.4: $and with $gt + $lt range — both push down with matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "apple" } }, { "a": { "$lt": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.5: $and with $gte + $lte range — both push down with matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.6: Implicit $and — $gt + $lt both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gt": "apple", "$lt": "date" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.7: Implicit $and with $gte + $lte — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana", "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.8: $and with $eq + $gt — no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 } }')
$cmd$);

-- 4.9: Compound: $eq on "a" + $gt on "b" — matching collation — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.10: Compound: $eq on "a" + $gte on "b" — matching collation — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.11: Compound: $eq on "a" + $eq on "b" — matching collation — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.12: Compound: $gt on first key — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$gt": "bird" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.13: Compound: $gte on first key — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.14: Compound: $eq on first key — no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 4.15: Compound: $eq on first key — different locale — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 4.16: Compound: case-insensitive $eq on "a" + $gt on "b" — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "DOG" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.17: $and with $eq + $lt — both can push down with matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.18: $and with $eq + $lte — both can push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$lte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.19: Compound: $lt on first key — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$lt": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.20: Compound: $lte on first key — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.21: Compound: $eq on "a" + $lt on "b" — matching collation — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$lt": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.22: Compound: $eq on "a" + $lte on "b" — matching collation — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$lte": 40 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.23: $lte "banana" AND $gt "CHERRY" — case-insensitive at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lte": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.24: $eq "banana" AND $gt "CHERRY" — case-insensitive at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.25: Compound: $lte on "a" + $lt on "b" — range on both keys
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.26: $lt on "a" AND $lte on "a" — both string ranges at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lt": "date" } }, { "a": { "$lte": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.27: $gt "bAnAnA" AND $lte "chErRy" — mixed-case range at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "bAnAnA" } }, { "a": { "$lte": "chErRy" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 5: Multiple indexes with different collations
-- ======================================================================

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multi_coll', '{"_id": 1, "a": "Alpha"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multi_coll', '{"_id": 2, "a": "alpha"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multi_coll', '{"_id": 3, "a": "Beta"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multi_coll', '{"_id": 4, "a": "beta"}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
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
  'coll_operators_index_explain_db',
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

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_operators_index_explain_db', '{"listIndexes": "multi_coll"}');

-- 5.1: $eq with strength=1 — should use idx_a_en_s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 5.2: $eq with strength=3 — should use idx_a_en_s3
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 5.3: $eq with no collation — neither collated index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 5.4: $eq with strength=2 — neither index matches
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 5.5: strength=1 case-insensitive — "ALPHA" matches both Alpha and alpha
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 5.6: strength=3 case-sensitive — "alpha" only matches "alpha"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- ======================================================================
-- SECTION 6: Aggregation pipeline with collation
-- ======================================================================

-- 6.1: $match with $eq — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.2: $match with $eq — no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {} }')
$cmd$);

-- 6.3: $match with $gt — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.4: $match then $project — matching collation — index SHOULD be used for $eq
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.5: $match with $lt — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lt": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.6: $match with $lte — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 7: Collation-insensitive operators — index SHOULD be used
-- regardless of whether query collation matches index collation.
-- ======================================================================

-- Setup: collection with mixed types for collation-insensitive operator tests
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 1, "a": "hello"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 2, "a": "HELLO"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 3, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 4, "a": 7}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 5, "a": 255}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 6, "a": null}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 7, "a": true}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 8, "a": [1, 2, 3]}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 9}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','insensitive_ops', '{"_id": 10, "a": {"x": 1, "y": 2}}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
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
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.2: $exists: true — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 7.3: $exists: false — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": false } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.4: $type "string" — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.5: $type "number" — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "number" } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 7.6: $type "null" — no collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "null" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 7.7: $size — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.8: $size — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 7.9: $mod — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.10: $mod — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 7.11: $bitsAllSet — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.12: $bitsAllSet — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 7.13: $bitsAllClear — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllClear": 8 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.14: $bitsAnySet — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnySet": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.15: $bitsAnyClear — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnyClear": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.16: $exists + $eq combination — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$exists": true } }, { "a": { "$eq": "hello" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.17: $type + $gt combination — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$type": "number" } }, { "a": { "$gt": 10 } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 8: $regex — not pushed down to collated index
-- ======================================================================

-- 8.1: $regex anchored prefix — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.2: $regex anchored prefix without collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 8.3: $regex anchored prefix with different collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 8.4: $regex unanchored — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$regex": "ana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.5: $regex with case-insensitive flag — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app", "$options": "i" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.6: $regex combined with $eq — $eq SHOULD use index, $regex becomes filter
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [{ "a": { "$eq": "apple" } }, { "a": { "$regex": "^app" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 9: MinKey/MaxKey boundary pushdown — collation does not affect
-- boundary values so these should always use the collated index.
-- ======================================================================

-- 9.1: $gte MinKey — matching collation — index SHOULD be used (same as $exists: true)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 9.2: $gte MinKey — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 9.3: $gt MinKey — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$gt": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 9.4: $lt MaxKey — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 9.5: $lt MaxKey — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 9.6: $lte MaxKey — mismatched collation — index SHOULD still be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$lte": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- ======================================================================
-- SECTION 10: $ne — not-equal pushdown (complement of $eq)
-- ======================================================================

-- 10.1: $ne with matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.2: $ne case-insensitive — "APPLE" excludes both "apple" and "Apple" at strength=1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.3: $ne with no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 10.4: $ne with different locale — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 10.5: $ne with null and matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.6: $ne "bAnAnA" mixed-case at strength=1 — excludes both "banana" and "BANANA"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": "bAnAnA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.7: $ne with empty string and matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.8: $ne combined with $gt — both push down with matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gt": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.9: $ne combined with $lte — both push down with matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.10: $ne on aggregation pipeline — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$ne": "date" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.11: Compound: $ne on "a" + $eq on "b" — matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "dog" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.11b: Compound: $ne "DOG" (uppercase) — composite recheck uses collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.12: $ne with different strength — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 10.15: $ne "cherry" AND $gte "banana" AND $lte "date" — $ne within range
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gte": "banana" } }, { "a": { "$lte": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.16: Multiple $ne — $ne "apple" AND $ne "banana"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$ne": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.17: Compound: $ne "DOG" AND $eq 20 — $ne excludes both dog variants, $eq 20 matches dog → empty
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.18: Compound: $ne "cat" AND $lt 50 — excludes Cat(30),cat(40), leaves Bird(50→no), bird(60→no), DOG(10),dog(20)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.19: $ne on multi_coll with strength=1 — picks idx_a_en_s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.20: $ne on multi_coll with strength=3 — case-sensitive, "ALPHA" not stored so nothing excluded
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 10.21: $ne on insensitive_ops "HELLO" — case-insensitive excludes hello+HELLO
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": "HELLO" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.22: $ne boolean (true) on insensitive_ops
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.25: $ne $minKey with matching collation — boundary test
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 11: $not: { $gt } — negation of greater-than pushdown
-- ======================================================================

-- 11.1: $not $gt "BANANA" (uppercase) at strength-1 — includes both case variants (≤ banana)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.3: Mismatched collation (de vs en index) — falls back to _id_ scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 11.6: multi_coll index selection — strength-1 uses idx_a_en_s1; strength-3 uses idx_a_en_s3
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gt": "ALPHA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gt": "Alpha" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 11.7: Compound — $not $gt on "a" only, no filter on "b"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "CAT" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.9: Compound — $not $gt on "a" + $lte on "b" (range on both fields)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CAT" } } }, { "b": { "$lte": 30 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.10: Compound with mismatched collation — falls back to _id_
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "CAT" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 11.11: $not $gt + $not $lt (bounded range via two negations) — ≤ cherry AND ≥ banana
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$not": { "$lt": "BANANA" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.12: $not $gt "CHERRY" combined with $ne "APPLE" — both case-insensitive
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$ne": "APPLE" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.15: Multiple $not $gt — $not $gt "CHERRY" AND $not $gt "BANANA", tighter bound wins: ≤ banana
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$not": { "$gt": "BANANA" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.16: insensitive_ops $not $gt "HELLO" at strength-1 — mixed-type collection
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 11b: $not: { $gte } — negation of greater-than-or-equal pushdown
-- ======================================================================

-- 11b.1: $not $gte "BANANA" (uppercase) at strength-1 — excludes both case variants (< banana)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.3: Mismatched collation (de vs en index) — falls back to _id_ scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 11b.6: multi_coll index selection — strength-1 uses idx_a_en_s1; strength-3 uses idx_a_en_s3
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gte": "BETA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gte": "Beta" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 11b.7: Compound — $not $gte on "a" only, no filter on "b"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gte": "DOG" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.9: Compound — $not $gte on "a" + $gte on "b" (range on both fields)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "DOG" } } }, { "b": { "$gte": 30 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.10: Compound with mismatched collation — falls back to _id_
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gte": "DOG" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 11b.11: $not $gte + $not $lte (bounded range via two negations) — > apple AND < cherry
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "CHERRY" } } }, { "a": { "$not": { "$lte": "APPLE" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.12: $not $gte "APPLE" + $ne "BANANA" at strength-1 — both case-insensitive
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "APPLE" } } }, { "a": { "$ne": "BANANA" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.15: Multiple $not $gte — $not $gte "CHERRY" AND $not $gte "BANANA", tighter bound wins: < banana
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "CHERRY" } } }, { "a": { "$not": { "$gte": "BANANA" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.16: insensitive_ops $not $gte "HELLO" at strength-1 — mixed-type collection
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 12: $not: { $lt } — negation of less-than pushdown
-- ======================================================================

-- 12.1: $not $lt "CHERRY" (uppercase) at strength-1 — returns docs ≥ cherry plus non-strings
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.3: Mismatched collation (de vs en index) — falls back to _id_ scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 12.6: multi_coll index selection — strength-1 uses idx_a_en_s1; strength-3 uses idx_a_en_s3
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lt": "ALPHA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lt": "ALPHA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 12.7: Compound — $not $lt on "a" only, no filter on "b"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$lt": "CAT" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.9: Compound — $not $lt on "a" + $gt on "b" (range on both fields)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "BIRD" } } }, { "b": { "$gt": 20 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.10: Compound with mismatched collation — falls back to _id_
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "DOG" } } }, { "b": 10 } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 12.11: $not $lt + $not $gt (bounded range via two negations) — ≥ banana AND ≤ cherry
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "BANANA" } } }, { "a": { "$not": { "$gt": "CHERRY" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.12: $not $lt "CHERRY" combined with $ne "DATE" — both case-insensitive
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "CHERRY" } } }, { "a": { "$ne": "DATE" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.15: Multiple $not $lt — $not $lt "CHERRY" AND $not $lt "DATE", tighter bound wins: ≥ date
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "CHERRY" } } }, { "a": { "$not": { "$lt": "DATE" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.16: insensitive_ops $not $lt "HELLO" at strength-1 — mixed-type collection
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 12b: $not: { $lte } — negation of less-than-or-equal pushdown
-- ======================================================================

-- 12b.1: $not $lte "CHERRY" (uppercase) at strength-1 — returns docs > cherry plus non-strings
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.3: Mismatched collation (de vs en index) — falls back to _id_ scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 12b.6: multi_coll index selection — strength-1 uses idx_a_en_s1; strength-3 uses idx_a_en_s3
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lte": "ALPHA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lte": "ALPHA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 12b.7: Compound — $not $lte on "a" only, no filter on "b"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$lte": "BIRD" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.9: Compound — $not $lte on "a" + $lt on "b" (range on both fields)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BIRD" } } }, { "b": { "$lt": 50 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.10: Compound with mismatched collation — falls back to _id_
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "DOG" } } }, { "b": 10 } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 12b.11: $not $lte + $not $gte (bounded range via two negations) — > banana AND < cherry
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BANANA" } } }, { "a": { "$not": { "$gte": "CHERRY" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.12: $not $lte "BANANA" combined with $ne "DATE" — both case-insensitive
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BANANA" } } }, { "a": { "$ne": "DATE" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.15: Multiple $not $lte — $not $lte "BANANA" AND $not $lte "CHERRY", tighter bound wins: > cherry
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BANANA" } } }, { "a": { "$not": { "$lte": "CHERRY" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.16: insensitive_ops $not $lte "HELLO" at strength-1 — mixed-type collection
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 13: Non-string type bypass with MISMATCHED collation
-- ======================================================================

-- 25.1: $ne numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.2: $eq numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.3: $gt numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": 1 } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 25.4: $eq bool with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.5: $ne null with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 25.6: $lt numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.7: $gt bool with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": false } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.8: $lte bool with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.9: $eq regex value with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$eq": { "$regularExpression": { "pattern": "^app", "options": "" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.10: $gte numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.11: $eq array with mismatched collation — index NOT used because arrays can nest strings
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.12: $eq array with matching collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.13: $ne array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.14: $gt array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.15: $gte array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.16: $lt array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.17: $lte array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.18: $eq document with mismatched collation — index NOT used because documents can nest strings
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.19: $eq document with matching collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.20: $ne document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.21: $gt document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.22: $gte document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.23: $lt document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.24: $lte document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.25: $eq nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.26: $eq nested document with matching collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.27: $eq array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.28: $eq array of documents with matching collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.29: $eq nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.30: $eq nested array with matching collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.31: $ne nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.32: $gt nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.33: $gte nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.34: $lt nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.35: $lte nested document with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.36: $ne array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.37: $gt array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.38: $gte array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.39: $lt array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.40: $lte array of documents with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": [{ "key": "apple" }] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.41: $ne nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.42: $gt nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.43: $gte nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.44: $lt nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.45: $lte nested array with mismatched collation — index NOT used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.46: $not $gt numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": 100 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.47: $not $gt boolean with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": false } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 25.48: $not $gt array with mismatched collation — index NOT used (arrays can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": ["apple", "banana"] } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.49: $not $gt document with mismatched collation — index NOT used (documents can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": {"sub": "doc"} } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.50: $not $gte numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": 7 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.51: $not $gte boolean with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 25.52: $not $gte array with mismatched collation — index NOT used (arrays can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": ["apple", "banana"] } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.53: $not $gte document with mismatched collation — index NOT used (documents can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": {"sub": "doc"} } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.56: $not $gt boolean (true) on insensitive_ops — non-string filter bypasses collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.59: $not $gte boolean (true) on insensitive_ops — non-string filter bypasses collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.60: $not $lt numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": 7 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.61: $not $lt boolean with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 25.62: $not $lt array with mismatched collation — index NOT used (arrays can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": ["apple", "banana"] } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.63: $not $lt document with mismatched collation — index NOT used (documents can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": {"sub": "doc"} } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.64: $not $lte numeric with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": 42 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.65: $not $lte boolean with mismatched collation — index used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }')
$cmd$);

-- 25.66: $not $lte array with mismatched collation — index NOT used (arrays can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": ["apple", "banana"] } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.67: $not $lte document with mismatched collation — index NOT used (documents can nest strings)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": {"sub": "doc"} } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 25.70: $not $lt boolean on insensitive_ops — non-string bypasses collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 25.73: $not $lte boolean on insensitive_ops — non-string bypasses collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 14: Mixed collation-aware and non-collation-aware type bounds
-- in a single range query. The numeric bound bypasses collation checks
-- while the string bound requires matching collation.
-- ======================================================================

-- 26.1: $gte numeric + $lt string with matching collation — both use index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 26.2: $gt string + $lte numeric with matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "banana" } }, { "a": { "$lte": 100 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 26.3: $gte numeric + $lt string with MISMATCHED collation — numeric uses index, string does NOT
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 26.4: $ne string + $gte numeric with mismatched collation — numeric uses index, string $ne does NOT
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$gte": 10 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 26.5: $not $gt string + $gte numeric with matching collation — both use index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$gte": 10 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 26.6: $not $gt string + $lte numeric with MISMATCHED collation — numeric uses index, string does NOT
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "banana" } } }, { "a": { "$lte": 100 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 26.7: $not $gte string + $gt numeric with matching collation — both use index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "BANANA" } } }, { "a": { "$gt": 1 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 26.8: $not $gte string + $lt numeric with MISMATCHED collation — numeric uses index, string does NOT
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "cherry" } } }, { "a": { "$lt": 50 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- ======================================================================
-- SECTION 15: Other operators — collation index behavior
-- ======================================================================

-- 27.1: $exists — collation-insensitive, always uses index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 27.2: $type — collation-insensitive, always uses index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 27.3: $all — decomposes to $eq, uses collation index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$all": ["apple", "APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 27.4: $regex — not collation-aware, falls back to _id scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 27.5: $or — not yet supported, falls back to _id scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('coll_operators_index_explain_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "$or": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "banana" } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 16: Data variety & negative cases
-- ======================================================================
-- Test that collation-indexed $not, $ne, comparison operators correctly
-- handle non-string BSON types, null, missing fields, and duplicate
-- collation-equivalent values.

-- Collection with dense mixed-type data and collation-equivalent duplicates.
-- 20 docs: 14 strings (with case-variant triples), 2 numerics, 1 bool, 1 null, 2 missing
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 1,  "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 2,  "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 3,  "a": "APPLE"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 4,  "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 5,  "a": "Banana"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 6,  "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 7,  "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 8,  "a": "CHERRY"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 9,  "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 10, "a": "elderberry"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 11, "a": "fig"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 12, "a": "grape"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 13, "a": "honeydew"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 14, "a": "kiwi"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 15, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 16, "a": 7}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 17, "a": true}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 18, "a": null}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 19}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','mixed_types', '{"_id": 20}', NULL);

-- Strength-1 index (case-insensitive)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "mixed_types",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_mixed_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- Strength-3 index (case-sensitive)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "mixed_types",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_mixed_en_s3",
      "collation": {"locale": "en", "strength": 3}
    }]
  }',
  TRUE
);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$lt": "elderberry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$ne": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$ne": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- at strength-3.  1 string + 6 non-strings = 7.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "apple" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- ======================================================================
-- SECTION 17: Sort direction
-- ======================================================================
-- Verify descending and mixed-direction sorts work with collation indexes
-- and $not operators.

-- Same result set as 28.1 (14 docs) but in reverse _id order.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "cherry" } } }, "sort": { "_id": -1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "cat" } } }, "sort": { "a": 1, "b": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Same result set as 29.3 but in reverse order.

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "dog" } }, "b": { "$not": { "$lt": 30 } } }, "sort": { "a": 1, "b": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 18: Collation-specific edge cases
-- ======================================================================
-- Accented characters and overlapping negations on the same field.

-- Collection with accented and non-accented variants
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 1, "a": "cafe"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 2, "a": "café"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 3, "a": "caff"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 4, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 5, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 6, "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 7, "a": "elderberry"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 8, "a": "Café"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','accent_coll', '{"_id": 9, "a": "CAFE"}', NULL);

-- Strength-1 (case + accent insensitive — but ICU treats accent as primary)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "accent_coll",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_accent_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- Strength-2 (accent sensitive, case insensitive)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "accent_coll",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_accent_en_s2",
      "collation": {"locale": "en", "strength": 2}
    }]
  }',
  TRUE
);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "accent_coll", "filter": { "a": { "$ne": "cafe" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "accent_coll", "filter": { "a": { "$ne": "cafe" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "accent_coll", "filter": { "a": { "$not": { "$gt": "cafe" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "accent_coll", "filter": { "a": { "$not": { "$gt": "café" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "accent_coll", "filter": { "$and": [ { "a": { "$not": { "$gt": "café" } } }, { "a": { "$not": { "$lt": "banana" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "$and": [ { "a": { "$not": { "$gt": "cherry" } } }, { "a": { "$not": { "$lt": "banana" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "$and": [ { "a": { "$not": { "$gt": "cherry" } } }, { "a": { "$not": { "$lt": "banana" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- ======================================================================
-- SECTION 19: Descending and mixed-direction indexes
-- ======================================================================
-- Test indexes with descending key direction ({a: -1}) and mixed
-- {a: 1, b: -1} indexes with $not operators.

-- Descending single-field index on mixed_types
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "mixed_types",
    "indexes": [{
      "key": { "a": -1 },
      "name": "idx_mixed_desc_s1",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- Mixed-direction compound on compound_field: {a: 1, b: -1}
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "compound_field",
    "indexes": [{
      "key": { "a": 1, "b": -1 },
      "name": "idx_compound_mixed_s1",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Excludes only fruits (apple/Apple/APPLE, plus banana, cherry > "cherry"); numeric/null docs survive.

-- a: $not $gt "cherry", b: $not $lt "green" at S1
-- Uses the compound_field collection.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "cherry" } }, "b": { "$not": { "$lt": "green" } } }, "sort": { "a": 1, "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 20: Three-key composite index
-- ======================================================================
-- Tests $not operators on a three-key composite index {a:1, b:1, c:1}
-- with collation. Covers equality prefix + trailing negation, negation
-- on middle key, and all three keys with negation.

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 1,  "a": "apple",  "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 2,  "a": "apple",  "b": "red",    "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 3,  "a": "apple",  "b": "green",  "c": "z"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 4,  "a": "banana", "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 5,  "a": "banana", "b": "yellow", "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 6,  "a": "cherry", "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 7,  "a": "cherry", "b": "green",  "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 8,  "a": "Cherry", "b": "Red",    "c": "Z"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 9,  "a": "date",   "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 10, "a": "date",   "b": "green",  "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 11, "a": null,     "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','three_key', '{"_id": 12, "a": "cherry", "b": null,     "c": "x"}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "three_key",
    "indexes": [{
      "key": { "a": 1, "b": 1, "c": 1 },
      "name": "idx_three_key_s1",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "three_key", "filter": { "a": "cherry", "b": "red", "c": { "$not": { "$gt": "x" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "three_key", "filter": { "a": { "$not": { "$gt": "cherry" } }, "b": { "$not": { "$gt": "red" } }, "c": { "$not": { "$gt": "x" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 21: Multi-key (array field) with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 1, "tags": ["ABC", "def"]}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 2, "tags": ["abc", "DEF"]}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 3, "tags": ["ghi", "JKL"]}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 4, "tags": "abc"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 5, "tags": "ABC"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 6, "tags": ["abc", "ghi"]}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 7, "tags": null}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','multikey_coll', '{"_id": 8}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "multikey_coll",
    "indexes": [{
      "key": {"tags": 1},
      "name": "idx_tags_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- 33.1: $eq "abc" at s1 — matches scalars and array elements case-insensitively
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multikey_coll", "filter": { "tags": "abc" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 33.2: $ne "abc" at s1 — excludes docs where ANY element = "abc"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multikey_coll", "filter": { "tags": { "$ne": "abc" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 33.4: $not $gt "def" at s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multikey_coll", "filter": { "tags": { "$not": { "$gt": "def" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- SECTION 22: Locale-specific collation tests — es (ñ) and de (ß)
-- ======================================================================

-- ===== 34A: Spanish (es) locale — ñ sorts after n =====

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','es_locale', '{"_id": 1, "a": "napa"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','es_locale', '{"_id": 2, "a": "ñapa"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','es_locale', '{"_id": 3, "a": "nylon"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','es_locale', '{"_id": 4, "a": "Ñapa"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','es_locale', '{"_id": 5, "a": "opal"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','es_locale', '{"_id": 6, "a": "mango"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','es_locale', '{"_id": 7, "a": "nacho"}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "es_locale",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_es_s1",
      "collation": {"locale": "es", "strength": 1}
    }]
  }',
  TRUE
);

-- 34A.1: $eq "ñapa" at es/s1 — matches ñapa and Ñapa (case-insensitive)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "es_locale", "filter": { "a": { "$eq": "ñapa" } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }')
$cmd$);

-- 34A.3: $gt "nylon" at es/s1 — ñ comes after all n-words
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "es_locale", "filter": { "a": { "$gt": "nylon" } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }')
$cmd$);

-- 34A.5: $ne "ñapa" at es/s1 — excludes ñapa(2) and Ñapa(4)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "es_locale", "filter": { "a": { "$ne": "ñapa" } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }')
$cmd$);

-- 34A.6: mismatched locale (en vs es index) — should NOT use index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "es_locale", "filter": { "a": { "$eq": "ñapa" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ===== 34B: German (de) locale — ß equivalence with ss =====

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 1, "a": "straße"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 2, "a": "strasse"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 3, "a": "Straße"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 4, "a": "STRASSE"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 5, "a": "string"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 6, "a": "strudel"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 7, "a": "apfel"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','de_locale', '{"_id": 8, "a": "zucker"}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "de_locale",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_de_s1",
      "collation": {"locale": "de", "strength": 1}
    }]
  }',
  TRUE
);

-- 34B.1: $eq "straße" at de/s1 — ß == ss at strength-1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "de_locale", "filter": { "a": { "$eq": "straße" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 34B.3: $ne "straße" at de/s1 — excludes all straße/strasse variants
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "de_locale", "filter": { "a": { "$ne": "straße" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 34B.4: $gt "strasse" at de/s1 — straße is NOT > strasse since ß==ss
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "de_locale", "filter": { "a": { "$gt": "strasse" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 34B.6: mismatched locale (en vs de index) — should NOT use index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "de_locale", "filter": { "a": { "$eq": "straße" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);



-- ======================================================================
-- Section 35: $in — collation index pushdown (comprehensive)
-- ======================================================================

-- 35.1: $in with no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "banana"] } }, "sort": { "_id": 1 } }')
$cmd$);

-- 35.2: $in with different locale — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 35.3: $in with different strength — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 35.4: $in with numericOrdering — index should NOT be used (different ICU string)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }')
$cmd$);

-- 35.5: $in case-insensitive — "APPLE" matches apple(1), Apple(2); "BANANA" matches BANANA(3), banana(4)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["APPLE", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.9: $in with null — index SHOULD be used (null is non-collation-aware)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": [null] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.10: $in with empty string
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": [""] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.11: $in single element — equivalent to $eq
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.12: $in null + string — both match
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": [null, "apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.14: $in with number + string — mixed types
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": [42, "apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.15: multi-element $in non-string with mismatched collation — index NOT used
--        (the $in array is itself a collation-aware BSON type, so the planner
--         rejects the index regardless of element types)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": [42, null] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 35.16: $in string with mismatched collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 35.17: $in mixed string+number with mismatched collation — index should NOT be used (string present)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": [42, "apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 35.18: $in on compound index — matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$in": ["dog", "cat"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.19: $in on compound first key + $gt on second — matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$in": ["dog", "cat"] }, "b": { "$gt": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.20: $in UPPERCASE on compound — "DOG" matches dog/DOG, "BIRD" matches Bird/bird
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$in": ["DOG", "BIRD"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.21: $in on compound — no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$in": ["dog", "cat"] } }, "sort": { "_id": 1 } }')
$cmd$);

-- 35.22: $in on multi_coll strength=1 — uses idx_a_en_s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$in": ["alpha", "beta"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.23: $in on multi_coll strength=3 — case-sensitive, "alpha" only matches alpha(2)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$in": ["alpha"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 35.26: $in combined with $gt — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$in": ["cherry", "date"] } }, { "a": { "$gt": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.27: $in combined with $ne — $ne narrows $in results
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$in": ["apple", "banana", "cherry"] } }, { "a": { "$ne": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.28: $in combined with $exists
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$in": ["apple", "date"] } }, { "a": { "$exists": true } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.32: $in on multikey — "abc" matches array elements case-insensitively at s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multikey_coll", "filter": { "tags": { "$in": ["abc"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.34: $in multiple values on multikey
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multikey_coll", "filter": { "tags": { "$in": ["abc", "ghi"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.37: $in on insensitive_ops — "HELLO" matches hello + HELLO at s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$in": ["HELLO"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.38: $in on insensitive_ops — mixed types ["hello", 42, true]
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$in": ["hello", 42, true] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.39: multi-element $in numeric-only with mismatched collation — index NOT used
--        (multi-element $in goes through array path → collation must match)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$in": [42, 7] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 35.40: single-element $in [true] with mismatched collation — index IS used
--        (planner decomposes single-element $in to $eq, then non-string element
--         bypasses the collation check)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$in": [true] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 35.41: $in document value with mismatched collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$in": [{"sub": "doc"}] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 35.42: $in array value with mismatched collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$in": [["apple", "banana"]] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 35.43: $in on es_locale — "ñapa" matches ñapa(2) and Ñapa(4) at s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "es_locale", "filter": { "a": { "$in": ["ñapa"] } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }')
$cmd$);

-- 35.45: $in on es_locale — mismatched locale (en vs es) — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "es_locale", "filter": { "a": { "$in": ["ñapa"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 35.46: $in on de_locale — "straße" at de/s1 — ß==ss at strength-1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "de_locale", "filter": { "a": { "$in": ["straße"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 35.49: Large $in with many values
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "banana", "cherry", "date", "elderberry", "fig", "grape", "honeydew", "kiwi", "lemon"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- Section 36: $nin — collation index pushdown (comprehensive)
-- ======================================================================

-- 36.1: $nin with no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 } }')
$cmd$);

-- 36.2: $nin with different locale — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 36.3: $nin with different strength — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);

-- 36.4: $nin "APPLE" at s1 — excludes apple(1) and Apple(2)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.6: $nin all string values — returns only non-string types (42, null) and any missing-field docs (none in this fixture)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana", "cherry", "date"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.9: $nin with null — excludes both null(10) AND any missing-field docs (none in this fixture, all 10 have field "a")
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": [null] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.12: $nin null + string — excludes both null and apple matches
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": [null, "apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.13: $nin number + string — excludes both
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": [42, "apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.14: single-element $nin [42] with mismatched collation — index IS used
--        (single-element $nin decomposes to $ne, non-string element bypasses
--         the collation check)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": [42] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 36.15: $nin string with mismatched collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 36.16: $nin on compound index — matching collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$nin": ["dog"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.17: $nin on compound first key + $gt second key
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "a": { "$nin": ["dog"] }, "b": { "$gt": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.19: $nin on multi_coll strength=1 — "ALPHA" excludes Alpha(1) and alpha(2)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$nin": ["ALPHA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.20: $nin on multi_coll strength=3 — "alpha" only excludes alpha(2)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multi_coll", "filter": { "a": { "$nin": ["alpha"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 36.22: $nin combined with $gt — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$nin": ["date"] } }, { "a": { "$gt": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.24: $nin combined with $lte — both push down
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$nin": ["apple"] } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.25: $nin combined with $not $gt
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$nin": ["apple"] } }, { "a": { "$not": { "$gt": "cherry" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.27: $nin on multikey — excludes docs where ANY element matches "abc" at s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multikey_coll", "filter": { "tags": { "$nin": ["abc"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.29: $nin multiple values on multikey
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "multikey_coll", "filter": { "tags": { "$nin": ["abc", "ghi"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.31: $nin on insensitive_ops — "HELLO" excludes hello(1), HELLO(2) at s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$nin": ["HELLO"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 36.33: $nin document value with mismatched collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "insensitive_ops", "filter": { "a": { "$nin": [{"sub": "doc"}] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 36.34: $nin on es_locale — "ñapa" excludes ñapa(2), Ñapa(4) at s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "es_locale", "filter": { "a": { "$nin": ["ñapa"] } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }')
$cmd$);

-- 36.35: $nin on de_locale — "straße" excludes all straße/strasse variants at de/s1
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "de_locale", "filter": { "a": { "$nin": ["straße"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 36.36: Large $nin
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana", "cherry", "date", "elderberry", "fig", "grape"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- Section 37: $in/$nin — feature flag disabled
-- ======================================================================

SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO off;

-- 37.1: $in with matching collation but flag OFF — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 37.2: $nin with matching collation but flag OFF — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;


-- ======================================================================
-- Section 38: $in/$nin — data distribution on mixed_types (20 docs)
-- ======================================================================
-- Verifies correct counts across collation-equivalent triples, non-strings,
-- null, and missing-field documents.

-- 38.1: $in "cherry" at s1 — matches cherry(6), Cherry(7), CHERRY(8) = 3 docs
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$in": ["cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 38.2: Same $in "cherry" at s3 — only lowercase "cherry"(6) matches = 1 doc
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$in": ["cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);

-- 38.3: $nin "cherry" at s1 — excludes cherry×3 = 17 docs returned
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "mixed_types", "filter": { "a": { "$nin": ["cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- Section 39: $in/$nin — accent collection (café vs cafe)
-- ======================================================================

-- 39.1: $in "cafe" at en/s1 — strength=1 ignores BOTH case AND diacritics, matches cafe(1), café(2), Café(8), CAFE(9) = 4 docs
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "accent_coll", "filter": { "a": { "$in": ["cafe"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 39.4: $nin "cafe" at en/s1 — excludes all 4 cafe-equivalents (cafe, café, Café, CAFE), returns 5 docs
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "accent_coll", "filter": { "a": { "$nin": ["cafe"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- Section 40: $in/$nin — three-key composite index
-- ======================================================================

-- 40.1: $in on first key with equality on rest
-- a: $in ["cherry", "banana"], b = "red", c = "x"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "three_key", "filter": { "a": { "$in": ["cherry", "banana"] }, "b": "red", "c": "x" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 40.2: $nin on first key with equality on rest
-- a: $nin ["cherry"], b = "red", c = "x" → apple(1), banana(4), date(9), null(11)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "three_key", "filter": { "a": { "$nin": ["cherry"] }, "b": "red", "c": "x" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- Section 41: $in/$nin — write-path coverage (delete with collation)
-- ======================================================================
-- Uses a dedicated collection so prior sections' state stays untouched.
-- update.collation and findAndModify.collation are NOT supported by the
-- backend today, so only delete is exercised here. The find+EXPLAIN before
-- each delete proves the same filter the delete executor evaluates can use
-- the collation index.

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 1, "a": "apple", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 2, "a": "Apple", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 3, "a": "BANANA", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 4, "a": "banana", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 5, "a": "cherry", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 6, "a": "Cherry", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 7, "a": "date",   "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 8, "a": "Date",   "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id": 9, "a": 42,       "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','write_in_coll', '{"_id":10, "a": null,     "v": 1}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "write_in_coll",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- 41.1: delete_one with $nin + matching collation (en s1) — removes one non-fruit doc (id 9 or 10)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "write_in_coll", "filter": { "a": { "$nin": ["apple", "banana", "cherry", "date"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
-- 41.2: delete_many with $in (matching collation) — removes BOTH date variants (ids 7,8)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "write_in_coll", "filter": { "a": { "$in": ["DATE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
-- 41.3: delete_many with $in + mismatched collation (de/s2 vs idx en/s1) — index NOT used; at de/s2 case is still ignored, so deletes BOTH cherry and Cherry
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "write_in_coll", "filter": { "a": { "$in": ["cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);
-- 41.4: delete with $in all-non-string + mismatched collation — index path still valid (non-string bypass)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "write_in_coll", "filter": { "a": { "$in": [42, null] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);
-- ======================================================================
-- Section 42: $in/$nin nested under $or / $and / $nor
-- ======================================================================
-- Boolean composition is where index-selection logic typically misbehaves.
-- These tests cover both legs of $or/$nor matching and $and combinations.

-- 42.1: $or [ $in, $eq ] — apple/Apple via collated $in OR cherry via $eq
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$or": [ { "a": { "$in": ["APPLE"] } }, { "a": { "$eq": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 42.2: $or [ $in, $in ] — both legs use the collation index ideally
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$or": [ { "a": { "$in": ["APPLE"] } }, { "a": { "$in": ["DATE"] } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 42.3: $and with $in + $ne — apple variants minus exact "apple"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$in": ["APPLE"] } }, { "a": { "$ne": "apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 42.5: $nor with $in — docs NOT in the collated set
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "$nor": [ { "a": { "$in": ["APPLE", "BANANA"] } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 42.8: $or with $in on one field + $eq on another (compound_field)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "compound_field", "filter": { "$or": [ { "a": { "$in": ["DOG"] } }, { "b": 30 } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- ======================================================================
-- Section 43: $in/$nin — large arrays (planner threshold behavior)
-- ======================================================================
-- Planners often switch strategies once $in array size crosses a threshold
-- (e.g., 32, 64, 100, 200). Verify both correctness and that the index
-- pushdown decision still holds at scale.

-- 43.1: $in with 200 elements (one of which matches) — case-insensitive
-- The list contains "FOO_NN" placeholders plus "BANANA"; only BANANA matches.
SELECT count(*) FROM (
    SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', $$
        { "find": "single_field",
          "filter": { "a": { "$in":
              ["FOO_0","FOO_1","FOO_2","FOO_3","FOO_4","FOO_5","FOO_6","FOO_7","FOO_8","FOO_9",
               "FOO_10","FOO_11","FOO_12","FOO_13","FOO_14","FOO_15","FOO_16","FOO_17","FOO_18","FOO_19",
               "FOO_20","FOO_21","FOO_22","FOO_23","FOO_24","FOO_25","FOO_26","FOO_27","FOO_28","FOO_29",
               "FOO_30","FOO_31","FOO_32","FOO_33","FOO_34","FOO_35","FOO_36","FOO_37","FOO_38","FOO_39",
               "FOO_40","FOO_41","FOO_42","FOO_43","FOO_44","FOO_45","FOO_46","FOO_47","FOO_48","FOO_49",
               "FOO_50","FOO_51","FOO_52","FOO_53","FOO_54","FOO_55","FOO_56","FOO_57","FOO_58","FOO_59",
               "FOO_60","FOO_61","FOO_62","FOO_63","FOO_64","FOO_65","FOO_66","FOO_67","FOO_68","FOO_69",
               "FOO_70","FOO_71","FOO_72","FOO_73","FOO_74","FOO_75","FOO_76","FOO_77","FOO_78","FOO_79",
               "FOO_80","FOO_81","FOO_82","FOO_83","FOO_84","FOO_85","FOO_86","FOO_87","FOO_88","FOO_89",
               "FOO_90","FOO_91","FOO_92","FOO_93","FOO_94","FOO_95","FOO_96","FOO_97","FOO_98","FOO_99",
               "FOO_100","FOO_101","FOO_102","FOO_103","FOO_104","FOO_105","FOO_106","FOO_107","FOO_108","FOO_109",
               "FOO_110","FOO_111","FOO_112","FOO_113","FOO_114","FOO_115","FOO_116","FOO_117","FOO_118","FOO_119",
               "FOO_120","FOO_121","FOO_122","FOO_123","FOO_124","FOO_125","FOO_126","FOO_127","FOO_128","FOO_129",
               "FOO_130","FOO_131","FOO_132","FOO_133","FOO_134","FOO_135","FOO_136","FOO_137","FOO_138","FOO_139",
               "FOO_140","FOO_141","FOO_142","FOO_143","FOO_144","FOO_145","FOO_146","FOO_147","FOO_148","FOO_149",
               "FOO_150","FOO_151","FOO_152","FOO_153","FOO_154","FOO_155","FOO_156","FOO_157","FOO_158","FOO_159",
               "FOO_160","FOO_161","FOO_162","FOO_163","FOO_164","FOO_165","FOO_166","FOO_167","FOO_168","FOO_169",
               "FOO_170","FOO_171","FOO_172","FOO_173","FOO_174","FOO_175","FOO_176","FOO_177","FOO_178","FOO_179",
               "FOO_180","FOO_181","FOO_182","FOO_183","FOO_184","FOO_185","FOO_186","FOO_187","FOO_188","FOO_189",
               "FOO_190","FOO_191","FOO_192","FOO_193","FOO_194","FOO_195","FOO_196","FOO_197","FOO_198","BANANA"]
          } },
          "sort": { "_id": 1 },
          "collation": { "locale": "en", "strength": 1 }
        }
    $$)
) t;

-- 43.2: Same large $in with no collation — only exact "BANANA" matches → 1
SELECT count(*) FROM (
    SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', $$
        { "find": "single_field",
          "filter": { "a": { "$in":
              ["FOO_0","FOO_1","FOO_2","FOO_3","FOO_4","FOO_5","FOO_6","FOO_7","FOO_8","FOO_9",
               "FOO_10","FOO_11","FOO_12","FOO_13","FOO_14","FOO_15","FOO_16","FOO_17","FOO_18","FOO_19",
               "FOO_20","FOO_21","FOO_22","FOO_23","FOO_24","FOO_25","FOO_26","FOO_27","FOO_28","FOO_29",
               "FOO_30","FOO_31","FOO_32","FOO_33","FOO_34","FOO_35","FOO_36","FOO_37","FOO_38","FOO_39",
               "FOO_40","FOO_41","FOO_42","FOO_43","FOO_44","FOO_45","FOO_46","FOO_47","FOO_48","FOO_49",
               "FOO_50","FOO_51","FOO_52","FOO_53","FOO_54","FOO_55","FOO_56","FOO_57","FOO_58","FOO_59",
               "FOO_60","FOO_61","FOO_62","FOO_63","FOO_64","FOO_65","FOO_66","FOO_67","FOO_68","FOO_69",
               "FOO_70","FOO_71","FOO_72","FOO_73","FOO_74","FOO_75","FOO_76","FOO_77","FOO_78","FOO_79",
               "FOO_80","FOO_81","FOO_82","FOO_83","FOO_84","FOO_85","FOO_86","FOO_87","FOO_88","FOO_89",
               "FOO_90","FOO_91","FOO_92","FOO_93","FOO_94","FOO_95","FOO_96","FOO_97","FOO_98","FOO_99",
               "FOO_100","FOO_101","FOO_102","FOO_103","FOO_104","FOO_105","FOO_106","FOO_107","FOO_108","FOO_109",
               "FOO_110","FOO_111","FOO_112","FOO_113","FOO_114","FOO_115","FOO_116","FOO_117","FOO_118","FOO_119",
               "FOO_120","FOO_121","FOO_122","FOO_123","FOO_124","FOO_125","FOO_126","FOO_127","FOO_128","FOO_129",
               "FOO_130","FOO_131","FOO_132","FOO_133","FOO_134","FOO_135","FOO_136","FOO_137","FOO_138","FOO_139",
               "FOO_140","FOO_141","FOO_142","FOO_143","FOO_144","FOO_145","FOO_146","FOO_147","FOO_148","FOO_149",
               "FOO_150","FOO_151","FOO_152","FOO_153","FOO_154","FOO_155","FOO_156","FOO_157","FOO_158","FOO_159",
               "FOO_160","FOO_161","FOO_162","FOO_163","FOO_164","FOO_165","FOO_166","FOO_167","FOO_168","FOO_169",
               "FOO_170","FOO_171","FOO_172","FOO_173","FOO_174","FOO_175","FOO_176","FOO_177","FOO_178","FOO_179",
               "FOO_180","FOO_181","FOO_182","FOO_183","FOO_184","FOO_185","FOO_186","FOO_187","FOO_188","FOO_189",
               "FOO_190","FOO_191","FOO_192","FOO_193","FOO_194","FOO_195","FOO_196","FOO_197","FOO_198","BANANA"]
          } },
          "sort": { "_id": 1 }
        }
    $$)
) t;

-- 43.3: Large $nin (200 fruit-name placeholders + actual fruits to exclude)
-- $nin should still produce the complement; with collation, all four
-- apple/banana variants are excluded, leaving 6 (cherry/Cherry/date/Date/42/null).
SELECT count(*) FROM (
    SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', $$
        { "find": "single_field",
          "filter": { "a": { "$nin":
              ["NOPE_0","NOPE_1","NOPE_2","NOPE_3","NOPE_4","NOPE_5","NOPE_6","NOPE_7","NOPE_8","NOPE_9",
               "NOPE_10","NOPE_11","NOPE_12","NOPE_13","NOPE_14","NOPE_15","NOPE_16","NOPE_17","NOPE_18","NOPE_19",
               "NOPE_20","NOPE_21","NOPE_22","NOPE_23","NOPE_24","NOPE_25","NOPE_26","NOPE_27","NOPE_28","NOPE_29",
               "NOPE_30","NOPE_31","NOPE_32","NOPE_33","NOPE_34","NOPE_35","NOPE_36","NOPE_37","NOPE_38","NOPE_39",
               "NOPE_40","NOPE_41","NOPE_42","NOPE_43","NOPE_44","NOPE_45","NOPE_46","NOPE_47","NOPE_48","NOPE_49",
               "NOPE_50","NOPE_51","NOPE_52","NOPE_53","NOPE_54","NOPE_55","NOPE_56","NOPE_57","NOPE_58","NOPE_59",
               "NOPE_60","NOPE_61","NOPE_62","NOPE_63","NOPE_64","NOPE_65","NOPE_66","NOPE_67","NOPE_68","NOPE_69",
               "NOPE_70","NOPE_71","NOPE_72","NOPE_73","NOPE_74","NOPE_75","NOPE_76","NOPE_77","NOPE_78","NOPE_79",
               "NOPE_80","NOPE_81","NOPE_82","NOPE_83","NOPE_84","NOPE_85","NOPE_86","NOPE_87","NOPE_88","NOPE_89",
               "NOPE_90","NOPE_91","NOPE_92","NOPE_93","NOPE_94","NOPE_95","NOPE_96","NOPE_97","NOPE_98","NOPE_99",
               "NOPE_100","NOPE_101","NOPE_102","NOPE_103","NOPE_104","NOPE_105","NOPE_106","NOPE_107","NOPE_108","NOPE_109",
               "NOPE_110","NOPE_111","NOPE_112","NOPE_113","NOPE_114","NOPE_115","NOPE_116","NOPE_117","NOPE_118","NOPE_119",
               "NOPE_120","NOPE_121","NOPE_122","NOPE_123","NOPE_124","NOPE_125","NOPE_126","NOPE_127","NOPE_128","NOPE_129",
               "NOPE_130","NOPE_131","NOPE_132","NOPE_133","NOPE_134","NOPE_135","NOPE_136","NOPE_137","NOPE_138","NOPE_139",
               "NOPE_140","NOPE_141","NOPE_142","NOPE_143","NOPE_144","NOPE_145","NOPE_146","NOPE_147","NOPE_148","NOPE_149",
               "NOPE_150","NOPE_151","NOPE_152","NOPE_153","NOPE_154","NOPE_155","NOPE_156","NOPE_157","NOPE_158","NOPE_159",
               "NOPE_160","NOPE_161","NOPE_162","NOPE_163","NOPE_164","NOPE_165","NOPE_166","NOPE_167","NOPE_168","NOPE_169",
               "NOPE_170","NOPE_171","NOPE_172","NOPE_173","NOPE_174","NOPE_175","NOPE_176","NOPE_177","NOPE_178","NOPE_179",
               "NOPE_180","NOPE_181","NOPE_182","NOPE_183","NOPE_184","NOPE_185","NOPE_186","NOPE_187","NOPE_188","NOPE_189",
               "NOPE_190","NOPE_191","NOPE_192","NOPE_193","NOPE_194","NOPE_195","NOPE_196","NOPE_197","APPLE","BANANA"]
          } },
          "sort": { "_id": 1 },
          "collation": { "locale": "en", "strength": 1 }
        }
    $$)
) t;

-- 43.4: Large $in with EXPLAIN — verify planner doesn't blow up and pushdown decision is unchanged at scale
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db',
        '{ "find": "single_field", "filter": { "a": { "$in": ["x0","x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","x18","x19","x20","x21","x22","x23","x24","x25","x26","x27","x28","x29","x30","x31","x32","x33","x34","x35","x36","x37","x38","x39","x40","x41","x42","x43","x44","x45","x46","x47","x48","x49","x50","x51","x52","x53","x54","x55","x56","x57","x58","x59","x60","x61","x62","x63","BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- Section 44: $in/$nin — degenerate arrays
-- ======================================================================
-- $in:[null] and $nin:[null] are already covered in §35.9 / §36.x.
-- Cover the remaining MongoDB-special degenerates: empty arrays.

-- 44.1: $in: [] — matches NOTHING (universally true for any collation)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": [] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 44.2: $nin: [] — matches EVERYTHING (all 10 docs)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": [] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 44.4: $nin: [] without collation — must still match everything
SELECT count(*) FROM (SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": [] } } }')) t;

-- ======================================================================
-- Section 45: $in/$nin — index hint
-- ======================================================================
-- Hints can be by name (string) or by key spec (document). Verify the
-- collation index is selected when hinted explicitly, even when the
-- planner might otherwise prefer _id_.

-- 45.1: hint by name → collation index for $in (matching collation)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["APPLE", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 }, "hint": "idx_a_en_s1" }')
$cmd$);

-- 45.2: hint by key spec → collation index for $in
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["APPLE", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 }, "hint": { "a": 1 } }')
$cmd$);

-- 45.3: hint with $nin
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["APPLE", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 }, "hint": "idx_a_en_s1" }')
$cmd$);

-- 45.4: hint collation index but query collation MISMATCHES — planner must reject the hint or fall back safely
-- (Behavior probe: documents whatever the planner does today.)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 }, "hint": "idx_a_en_s1" }')
$cmd$);

-- 45.5: hint $natural — force collection scan even when collation index would otherwise apply
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 }, "hint": { "$natural": 1 } }')
$cmd$);


-- ======================================================================
-- Section 46: $in/$nin — nested field path with collation index
-- ======================================================================
-- A collection with a nested field "a.b" and a collation index on the
-- nested path. Verify $in/$nin pushdown decisions are the same as for
-- top-level fields.

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 1, "a": {"b": "apple"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 2, "a": {"b": "Apple"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 3, "a": {"b": "BANANA"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 4, "a": {"b": "banana"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 5, "a": {"b": "cherry"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 6, "a": {"b": "Cherry"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 7, "a": {"b": null}}',    NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 8, "a": {}}',             NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','nested_path_coll', '{"_id": 9}',                       NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "nested_path_coll",
    "indexes": [{
      "key": {"a.b": 1},
      "name": "idx_ab_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- 46.1: $in on nested path — case-insensitive at strength=1 → ids 1,2,3,4 (apple+banana variants)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "nested_path_coll", "filter": { "a.b": { "$in": ["APPLE", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 46.3: $in on nested path — mismatched collation — exact-case binary match
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "nested_path_coll", "filter": { "a.b": { "$in": ["apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 46.6: hint nested-path collation index for $in
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "nested_path_coll", "filter": { "a.b": { "$in": ["CHERRY"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 }, "hint": "idx_ab_en_s1" }')
$cmd$);


-- ======================================================================
-- Section 47: $in/$nin — BSON type variety in array (non-string bypass)
-- ======================================================================
-- Beyond int/bool/null (already covered), exercise Date, ObjectId,
-- Decimal128, Binary. Each travels a distinct comparator code path; the
-- collation index should still be usable when the array contains only
-- non-string values, regardless of query collation.

SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 3, "a": {"$date": "2024-01-15T00:00:00Z"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 4, "a": {"$date": "2025-06-20T12:00:00Z"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 5, "a": {"$oid": "507f1f77bcf86cd799439011"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 6, "a": {"$oid": "507f1f77bcf86cd799439022"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 7, "a": {"$numberDecimal": "3.14"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 8, "a": {"$numberDecimal": "9.99"}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id": 9, "a": {"$binary": {"base64": "AAEC", "subType": "00"}}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id":10, "a": {"$binary": {"base64": "AwQF", "subType": "00"}}}', NULL);
SELECT documentdb_api.insert_one('coll_operators_index_explain_db','bson_types_coll', '{"_id":11, "a": null}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_operators_index_explain_db',
  '{
    "createIndexes": "bson_types_coll",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- 47.1: single-element $in [Date] mismatched collation — index IS used (decomposed to $eq)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "bson_types_coll", "filter": { "a": { "$in": [ {"$date": "2024-01-15T00:00:00Z"} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 47.5: multi-element $in (Date + ObjectId + Decimal + Binary) mismatched — index NOT used
--       (array forces collation check regardless of element types)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "bson_types_coll", "filter": { "a": { "$in": [ {"$date": "2024-01-15T00:00:00Z"}, {"$oid": "507f1f77bcf86cd799439022"}, {"$numberDecimal": "9.99"}, {"$binary": {"base64": "AwQF", "subType": "00"}} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- ======================================================================
-- Cleanup
-- ======================================================================

RESET documentdb.enableExtendedExplainPlans;
RESET enable_seqscan;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb_core.enableCollation;
