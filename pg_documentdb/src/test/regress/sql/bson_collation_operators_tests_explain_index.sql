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

-- 27.4: $in — not yet supported, falls back to _id scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 27.5: $nin — not yet supported, falls back to _id scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 27.6: $regex — not collation-aware, falls back to _id scan
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('coll_operators_index_explain_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 27.7: $or — not yet supported, falls back to _id scan
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
-- Cleanup
-- ======================================================================

RESET documentdb.enableExtendedExplainPlans;
RESET enable_seqscan;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb_core.enableCollation;
