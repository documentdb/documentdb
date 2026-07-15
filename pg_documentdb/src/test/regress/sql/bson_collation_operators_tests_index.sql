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


SELECT documentdb_api.drop_collection('coll_op_db', 'write_in_coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "write_in_coll"}');


SELECT documentdb_api.drop_collection('coll_op_db', 'nested_path_coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "nested_path_coll"}');


SELECT documentdb_api.drop_collection('coll_op_db', 'bson_types_coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
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
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "bson_types_coll"}');

-- $elemMatch collated indexes (sections 23–28 in core).
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{ "createIndexes": "elemmatch_coll",
     "indexes": [{ "key": {"items": 1}, "name": "idx_items_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{ "createIndexes": "elemmatch_obj",
     "indexes": [{ "key": {"a.name": 1}, "name": "idx_aname_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{ "createIndexes": "elemmatch_compound",
     "indexes": [{ "key": {"tags": 1, "category": 1}, "name": "idx_tags_cat_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{ "createIndexes": "elemmatch_desc",
     "indexes": [{ "key": {"v": -1}, "name": "idx_v_desc_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{ "createIndexes": "elemmatch_es",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_es_s1",
                   "collation": {"locale": "es", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{ "createIndexes": "elemmatch_de",
     "indexes": [{ "key": {"a": 1}, "name": "idx_a_de_s1",
                   "collation": {"locale": "de", "strength": 1} }] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{ "createIndexes": "elemmatch_nested",
     "indexes": [{ "key": {"matrix.vals": 1}, "name": "idx_matrix_vals_en_s1",
                   "collation": {"locale": "en", "strength": 1} }] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_op_db',
  '{
    "createIndexes": "ord_strategies",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_num",
      "collation": {"locale": "en", "numericOrdering": true}
    }]
  }',
  TRUE
);
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('coll_op_db', '{"listIndexes": "ord_strategies"}');

-- ======================================================================
-- Run operator-strategy queries with indexes in place.
-- ======================================================================
\i sql/bson_collation_operators_tests_core.sql
