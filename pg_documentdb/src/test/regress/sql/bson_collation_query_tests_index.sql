SET citus.next_shard_id TO 8500000;
SET documentdb.next_collection_id TO 8500;
SET documentdb.next_collection_index_id TO 8500;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET enable_seqscan TO OFF;

-- ======================================================================
-- Create collation-aware indexes (en, strength 1) on every runtime collection.
-- One index per collection on the field most exercised by the core body.
-- create_indexes_non_concurrently auto-creates the collection so subsequent
-- inserts in the core body populate the index as they happen.
-- ======================================================================

-- Section 1 coll_strings, Section 2 coll_multi_collation: equality / range / $or on `a`.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_strings",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_multi_collation",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 3 coll_order_tests0/1: sort by `b` under collation / numericOrdering.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_order_tests0",
     "indexes": [{ "key": {"b": 1}, "name": "idx_b_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_order_tests1",
     "indexes": [{ "key": {"b": 1}, "name": "idx_b_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 6 coll_agg_proj: $expr / equality on `a` under various locales.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_agg_proj",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 9 coll_lookup_src: $lookup join on `a.b`.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_lookup_src",
     "indexes": [{ "key": {"a.b": 1}, "name": "idx_ab_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 9 coll_graph_target: $graphLookup connectToField `name`.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_graph_target",
     "indexes": [{ "key": {"name": 1}, "name": "idx_name_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 11 coll_find_positional: equality on `a` for positional projection.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_find_positional",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 11 coll_in_empty: $in on `name`.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_in_empty",
     "indexes": [{ "key": {"name": 1}, "name": "idx_name_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 13 coll_delete and coll_delete_sort: delete predicates on `a`.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_delete",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_delete_sort",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 21 coll_ios: compound index with `_id` as the trailing key, so a
-- covered $count on the leading `country` field can use an index-only scan.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_ios",
     "indexes": [{ "key": {"country": 1, "_id": 1}, "name": "idx_country_id_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- Section 21 coll_id_ios: collation-aware ordered index keyed on `_id`.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_id_ios",
     "indexes": [{ "key": {"_id": 1}, "name": "idx_id_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

-- ======================================================================
-- Source the core body so all queries run against indexed collections.
-- ======================================================================
\i sql/bson_collation_query_tests_core.sql
