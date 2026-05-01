SET citus.next_shard_id TO 95300000;
SET documentdb.next_collection_id TO 95300;
SET documentdb.next_collection_index_id TO 95300;

SET documentdb_api.forceUseIndexIfAvailable TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET enable_seqscan TO OFF;

-- Create collation-aware indexes on collections used by the operators core body.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_dist_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_dist_db', '{"listIndexes": "single_field_d"}');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_dist_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_dist_db', '{"listIndexes": "compound_d"}');

\i sql/bson_collation_operators_tests_dist_core.sql
