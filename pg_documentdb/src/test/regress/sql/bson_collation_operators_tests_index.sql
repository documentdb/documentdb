SET citus.next_shard_id TO 9400000;
SET documentdb.next_collection_id TO 9400;
SET documentdb.next_collection_index_id TO 9400;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET enable_seqscan TO OFF;

-- ======================================================================
-- Create collation-aware indexes used by the core body.
-- ======================================================================


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "single_field"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "compound_field"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "multi_coll"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "multi_coll"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "insensitive_ops"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "mixed_types"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "mixed_types"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "accent_coll"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "accent_coll"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "mixed_types"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "compound_field"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "three_key"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "multikey_coll"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "es_locale"}');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "de_locale"}');


-- ======================================================================
-- Run operator-strategy queries with indexes in place.
-- ======================================================================
\i sql/bson_collation_operators_tests_core.sql
