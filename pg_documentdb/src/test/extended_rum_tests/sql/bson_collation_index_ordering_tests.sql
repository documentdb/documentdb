SET documentdb.next_collection_id TO 8100;
SET documentdb.next_collection_index_id TO 8100;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- ===== Section 0: Negative tests ======

-- ordered/composite index with collation should fail when
-- enableCollationWithNonUniqueOrderedIndexes is OFF
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_guc_off_fail",
    "indexes": [{
      "key": { "a": 1 },
      "name": "a_coll_guc_off_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;

-- unique ordered index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_unique_fail",
    "indexes": [{
      "key": { "a": 1, "b": 1 },
      "name": "a_b_unique_coll_idx",
      "unique": true,
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

-- non-ordered index with collation should fail
SET documentdb.defaultUseCompositeOpClass TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_non_ordered_fail",
    "indexes": [{
      "key": { "a": 1 },
      "name": "a_non_ordered_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SET documentdb.defaultUseCompositeOpClass TO on;

-- hashed index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_hashed_fail",
    "indexes": [{
      "key": { "a": "hashed" },
      "name": "a_hashed_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- 2d index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_2d_fail",
    "indexes": [{
      "key": { "loc": "2d" },
      "name": "loc_2d_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- text index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_text_fail",
    "indexes": [{
      "key": { "content": "text" },
      "name": "content_text_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- 2dsphere index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_2dsphere_fail",
    "indexes": [{
      "key": { "loc": "2dsphere" },
      "name": "loc_2dsphere_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

CREATE SCHEMA IF NOT EXISTS collation_ordered_test_schema;

CREATE FUNCTION collation_ordered_test_schema.gin_bson_index_term_to_bson(bytea) 
RETURNS bson
LANGUAGE c
AS '$libdir/pg_documentdb', 'gin_bson_index_term_to_bson';


-- ===== Section 1: Single-key ordered index with numericOrdering=true ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_numord_true",
    "indexes": [{
      "key": { "item": 1 },
      "name": "item_numord_true_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_true', '{"_id": 1, "item": "item1"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_true', '{"_id": 2, "item": "item10"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_true', '{"_id": 3, "item": "item2"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_true', '{"_id": 4, "item": "item20"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_true', '{"_id": 5, "item": "item3"}', NULL);

\d documentdb_data.documents_8101
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_numord_true"}');

-- numericOrdering=true: sorted numerically as item1 < item2 < item3 < item10 < item20
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8102', 1), 
    'documentdb_data.documents_rum_index_8102'::regclass
) entry;


-- ===== Section 2: Single-key ordered index with numericOrdering=false ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_numord_false",
    "indexes": [{
      "key": { "item": 1 },
      "name": "item_numord_false_idx",
      "collation": { "locale": "en", "numericOrdering": false }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_false', '{"_id": 1, "item": "item1"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_false', '{"_id": 2, "item": "item10"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_false', '{"_id": 3, "item": "item2"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_false', '{"_id": 4, "item": "item20"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_numord_false', '{"_id": 5, "item": "item3"}', NULL);

\d documentdb_data.documents_8102
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_numord_false"}');

-- numericOrdering=false: sorted lexically as item1 < item10 < item2 < item20 < item3
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8104', 1), 
    'documentdb_data.documents_rum_index_8104'::regclass
) entry;


-- ===== Section 3: Compound ordered index with numericOrdering=true ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_compound_numord_true",
    "indexes": [{
      "key": { "item": 1, "qty": 1 },
      "name": "item_qty_numord_true_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_true', '{"_id": 1, "item": "item1", "qty": 10}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_true', '{"_id": 2, "item": "item10", "qty": 20}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_true', '{"_id": 3, "item": "item2", "qty": 30}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_true', '{"_id": 4, "item": "item20", "qty": 40}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_true', '{"_id": 5, "item": "item3", "qty": 50}', NULL);

\d documentdb_data.documents_8103
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_compound_numord_true"}');

-- numericOrdering=true compound: item sorted numerically, qty is number so unaffected
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8106', 1), 
    'documentdb_data.documents_rum_index_8106'::regclass
) entry;


-- ===== Section 4: Compound ordered index with numericOrdering=false ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_compound_numord_false",
    "indexes": [{
      "key": { "item": 1, "qty": 1 },
      "name": "item_qty_numord_false_idx",
      "collation": { "locale": "en", "numericOrdering": false }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_false', '{"_id": 1, "item": "item1", "qty": 10}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_false', '{"_id": 2, "item": "item10", "qty": 20}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_false', '{"_id": 3, "item": "item2", "qty": 30}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_false', '{"_id": 4, "item": "item20", "qty": 40}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_numord_false', '{"_id": 5, "item": "item3", "qty": 50}', NULL);

\d documentdb_data.documents_8104
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_compound_numord_false"}');

-- numericOrdering=false compound: item sorted lexically
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8108', 1), 
    'documentdb_data.documents_rum_index_8108'::regclass
) entry;


-- ===== Section 5: Single-key ordered index with strength=1 ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_single_s1",
    "indexes": [{
      "key": { "name": 1 },
      "name": "name_s1_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_single_s1', '{"_id": 1, "name": "Apple"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_single_s1', '{"_id": 2, "name": "apple"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_single_s1', '{"_id": 3, "name": "APPLE"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_single_s1', '{"_id": 4, "name": "Banana"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_single_s1', '{"_id": 5, "name": "banana"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_single_s1', '{"_id": 6, "name": "cherry"}', NULL);

\d documentdb_data.documents_8105
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_single_s1"}');

-- Strength=1: Apple/apple/APPLE collapse to the same collation sort key
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8110', 1), 
    'documentdb_data.documents_rum_index_8110'::regclass
) entry;


-- ===== Section 6: Compound ordered index with strength=1 and numericOrdering=true ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_compound_s1_numord",
    "indexes": [{
      "key": { "name": 1, "age": 1 },
      "name": "name_age_s1_numord_idx",
      "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s1_numord', '{"_id": 1, "name": "Apple", "age": 30}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s1_numord', '{"_id": 2, "name": "apple", "age": 25}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s1_numord', '{"_id": 3, "name": "APPLE", "age": 35}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s1_numord', '{"_id": 4, "name": "Banana", "age": 20}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s1_numord', '{"_id": 5, "name": "banana", "age": 40}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s1_numord', '{"_id": 6, "name": "cherry", "age": 15}', NULL);

\d documentdb_data.documents_8106
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_compound_s1_numord"}');

-- Compound strength=1 + numericOrdering: case-insensitive name, numeric age
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8112', 1), 
    'documentdb_data.documents_rum_index_8112'::regclass
) entry;


-- ===== Section 7: Compound ordered index with strength=3 ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_compound_s3",
    "indexes": [{
      "key": { "name": 1, "age": 1 },
      "name": "name_age_s3_idx",
      "collation": { "locale": "en", "strength": 3 }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s3', '{"_id": 1, "name": "Apple", "age": 30}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s3', '{"_id": 2, "name": "apple", "age": 25}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s3', '{"_id": 3, "name": "APPLE", "age": 35}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s3', '{"_id": 4, "name": "Banana", "age": 20}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_s3', '{"_id": 5, "name": "banana", "age": 40}', NULL);

\d documentdb_data.documents_8107
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_compound_s3"}');

-- Compound strength=3: case variants produce distinct composite terms
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8114', 1), 
    'documentdb_data.documents_rum_index_8114'::regclass
) entry;


-- ===== Section 8: Arrays in single-key ordered index with numericOrdering=true ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_array_numord",
    "indexes": [{
      "key": { "codes": 1 },
      "name": "codes_numord_true_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_array_numord', '{"_id": 1, "codes": ["code1", "code10"]}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_array_numord', '{"_id": 2, "codes": ["code2", "code20"]}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_array_numord', '{"_id": 3, "codes": ["code3"]}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_array_numord', '{"_id": 4, "codes": "code100"}', NULL);

\d documentdb_data.documents_8108
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_array_numord"}');

-- Array with numericOrdering=true: code1 < code2 < code3 < code10 < code20 < code100
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8116', 1), 
    'documentdb_data.documents_rum_index_8116'::regclass
) entry;


-- ===== Section 9: Arrays in compound ordered index with numericOrdering=false ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_compound_array",
    "indexes": [{
      "key": { "codes": 1, "priority": 1 },
      "name": "codes_priority_numord_false_idx",
      "collation": { "locale": "en", "numericOrdering": false }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_array', '{"_id": 1, "codes": ["code1", "code10"], "priority": 1}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_array', '{"_id": 2, "codes": ["code2", "code20"], "priority": 2}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_compound_array', '{"_id": 3, "codes": "code3", "priority": 3}', NULL);

\d documentdb_data.documents_8109
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_compound_array"}');

-- Array compound numericOrdering=false: codes sorted lexically (code1 < code10 < code2 < code20 < code3)
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8118', 1), 
    'documentdb_data.documents_rum_index_8118'::regclass
) entry;


-- ===== Section 10: Index build — documents before index creation, numericOrdering=true ======
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_build_numord', '{"_id": 1, "item": "item1", "tag": "A"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_build_numord', '{"_id": 2, "item": "item10", "tag": "B"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_build_numord', '{"_id": 3, "item": "item2", "tag": "C"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_build_numord', '{"_id": 4, "item": "item20", "tag": "D"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_build_numord', '{"_id": 5, "item": "item3", "tag": "E"}', NULL);

-- Create the collated ordered index on existing documents
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_build_numord",
    "indexes": [{
      "key": { "item": 1, "tag": 1 },
      "name": "item_tag_build_numord_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

\d documentdb_data.documents_8110
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_build_numord"}');

-- Index build numericOrdering=true: item sorted numerically (item1 < item2 < item3 < item10 < item20)
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8120', 1), 
    'documentdb_data.documents_rum_index_8120'::regclass
) entry;


-- ===== Section 11: Missing fields and nulls with numericOrdering=true ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_missing",
    "indexes": [{
      "key": { "x": 1, "y": 1 },
      "name": "x_y_numord_true_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_missing', '{"_id": 1, "x": "item1", "y": "val1"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_missing', '{"_id": 2, "x": "item10"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_missing', '{"_id": 3, "y": "val2"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_missing', '{"_id": 4}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_missing', '{"_id": 5, "x": null, "y": "val3"}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_missing', '{"_id": 6, "x": 42, "y": "val4"}', NULL);

\d documentdb_data.documents_8111
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_missing"}');

-- Missing/null: collation only applies to string values; missing and null use standard ordering
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8122', 1), 
    'documentdb_data.documents_rum_index_8122'::regclass
) entry;


-- ===== Section 12: Multiple collations on same collection (numericOrdering true vs false) ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_multi_coll",
    "indexes": [{
      "key": { "item": 1, "value": 1 },
      "name": "item_val_numord_true_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_multi_coll",
    "indexes": [{
      "key": { "item": 1, "value": 1 },
      "name": "item_val_numord_false_idx",
      "collation": { "locale": "en", "numericOrdering": false }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_multi_coll', '{"_id": 1, "item": "item1", "value": 100}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_multi_coll', '{"_id": 2, "item": "item10", "value": 200}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_multi_coll', '{"_id": 3, "item": "item2", "value": 300}', NULL);

\d documentdb_data.documents_8112
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_multi_coll"}');

-- numericOrdering=true index: item1 < item2 < item10
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8124', 1), 
    'documentdb_data.documents_rum_index_8124'::regclass
) entry;

-- numericOrdering=false index: item1 < item10 < item2
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8125', 1), 
    'documentdb_data.documents_rum_index_8125'::regclass
) entry;


-- ===== Section 13: Three-key compound with numericOrdering=true ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_three_key",
    "indexes": [{
      "key": { "region": 1, "code": 1, "seq": 1 },
      "name": "region_code_seq_numord_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_three_key', '{"_id": 1, "region": "us-east-1", "code": "code1", "seq": 10}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_three_key', '{"_id": 2, "region": "us-east-10", "code": "code2", "seq": 20}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_three_key', '{"_id": 3, "region": "us-east-2", "code": "code10", "seq": 30}', NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_three_key', '{"_id": 4, "region": "us-west-1", "code": "code3", "seq": 40}', NULL);

\d documentdb_data.documents_8113
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_three_key"}');

-- Three-key numericOrdering=true: region sorted numerically (us-east-1 < us-east-2 < us-east-10 < us-west-1)
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8127', 1), 
    'documentdb_data.documents_rum_index_8127'::regclass
) entry;


-- ===== Section 14: Truncated long strings with numericOrdering=true ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_truncated",
    "indexes": [{
      "key": { "longfield": 1, "tag": 1 },
      "name": "longfield_tag_numord_true_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_truncated',
  bson_build_document('_id'::text, 1, 'longfield'::text, ('item1' || repeat('x', 3000))::text, 'tag'::text, 'A'::text), NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_truncated',
  bson_build_document('_id'::text, 2, 'longfield'::text, ('item10' || repeat('x', 3000))::text, 'tag'::text, 'B'::text), NULL);
SELECT documentdb_api.insert_one('ord_coll_ordered_db', 'ord_truncated',
  bson_build_document('_id'::text, 3, 'longfield'::text, ('item2' || repeat('y', 3000))::text, 'tag'::text, 'C'::text), NULL);

\d documentdb_data.documents_8114
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('ord_coll_ordered_db', '{"listIndexes": "ord_truncated"}');

-- Truncated with numericOrdering=true: item1... < item2... < item10... ; $flags=1 indicates truncation
SELECT entry->>'offset' AS offset,
       collation_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8129', 1), 
    'documentdb_data.documents_rum_index_8129'::regclass
) entry;


-- ===== Section 15: Query with matching collation (index pushdown not yet supported) ======
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('ord_coll_ordered_db', '{ "find": "ord_numord_true", "filter": { "item": { "$eq": "item1" } }, "collation": { "locale": "en", "numericOrdering": true } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('ord_coll_ordered_db', '{ "find": "ord_numord_true", "filter": { "item": { "$eq": "item1" } }, "collation": { "locale": "en", "numericOrdering": true } }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('ord_coll_ordered_db', '{ "find": "ord_compound_numord_true", "filter": { "item": { "$eq": "item1" } }, "collation": { "locale": "en", "numericOrdering": true } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('ord_coll_ordered_db', '{ "find": "ord_compound_numord_true", "filter": { "item": { "$eq": "item1" } }, "collation": { "locale": "en", "numericOrdering": true } }');
ROLLBACK;


DROP SCHEMA collation_ordered_test_schema CASCADE;

RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb_core.enableCollation;
