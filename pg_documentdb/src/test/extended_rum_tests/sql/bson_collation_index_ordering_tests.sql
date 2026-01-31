SET documentdb.next_collection_id TO 8000;
SET documentdb.next_collection_index_id TO 8000;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO off;

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

CREATE SCHEMA collation_index_test_schema;

CREATE FUNCTION collation_index_test_schema.gin_bson_index_term_to_bson(bytea) 
RETURNS bson
LANGUAGE c
AS '$libdir/pg_documentdb', 'gin_bson_index_term_to_bson';

-- ===== Single-path indexes ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_collated",
    "indexes": [{
      "key": { "name": 1 },
      "name": "name_collated_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SELECT (index_spec).index_name,
       documentdb_core.bson_get_value_text((index_spec).index_options, 'collation') AS collation
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections 
                       WHERE database_name = 'coll_idx_db' AND collection_name = 'coll_collated')
ORDER BY index_id;

-- Check the index structure after insertions
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_collated', '{"_id": 1, "name": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_collated', '{"_id": 2, "name": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_collated', '{"_id": 3, "name": "APPLE"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_collated', '{"_id": 4, "name": "Banana"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_collated', '{"_id": 5, "name": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_collated', '{"_id": 6, "name": "cherry"}', NULL);

\d documentdb_data.documents_8001

-- Strength=1: 6 docs produce 4 index entries (Apple/apple/APPLE collapsed, Banana/banana collapsed)
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8002', 1), 
    'documentdb_data.documents_rum_index_8002'::regclass
) entry;

-- TODO: Query with matching collation should use the index
-- It will not use the index yet until we have supported index pushdown.
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "coll_collated", "filter": { "name": { "$eq": "apple" } }, "collation": { "locale": "en", "strength": 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('coll_idx_db', '{ "find": "coll_collated", "filter": { "name": { "$eq": "apple" } }, "collation": { "locale": "en", "strength": 1 } }');
ROLLBACK;


-- numericOrdering: true 
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_numeric_true",
    "indexes": [{
      "key": { "item": 1 },
      "name": "item_numorder_true_idx",
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_true', '{"_id": 1, "item": "item1"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_true', '{"_id": 2, "item": "item10"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_true', '{"_id": 3, "item": "item2"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_true', '{"_id": 4, "item": "item20"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_true', '{"_id": 5, "item": "item3"}', NULL);

\d documentdb_data.documents_8002

-- numericOrdering=true: sorted numerically as item1 < item2 < item3 < item10 < item20
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8004', 1), 
    'documentdb_data.documents_rum_index_8004'::regclass
) entry;

-- numericOrdering: false 
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_numeric_false",
    "indexes": [{
      "key": { "item": 1 },
      "name": "item_numorder_false_idx",
      "collation": { "locale": "en", "numericOrdering": false }
    }]
  }',
  TRUE
);

SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_false', '{"_id": 1, "item": "item1"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_false', '{"_id": 2, "item": "item10"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_false', '{"_id": 3, "item": "item2"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_false', '{"_id": 4, "item": "item20"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_numeric_false', '{"_id": 5, "item": "item3"}', NULL);

\d documentdb_data.documents_8003

-- numericOrdering=false: sorted lexically as item1 < item10 < item2 < item20 < item3
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8006', 1), 
    'documentdb_data.documents_rum_index_8006'::regclass
) entry;

-- ===== Single-path index with arrays and nested objects ======

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_nested",
    "indexes": [{
      "key": { "tags": 1 },
      "name": "tags_collated_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- Insert documents with arrays containing strings
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested', '{"_id": 1, "tags": ["Apple", "Banana"]}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested', '{"_id": 2, "tags": ["apple", "cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested', '{"_id": 3, "tags": ["APPLE", "BANANA", "zebra"]}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested', '{"_id": 4, "tags": "single_tag"}', NULL);
-- Nested object with string value at indexed path
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested', '{"_id": 5, "tags": {"nested": "value"}}', NULL);

\d documentdb_data.documents_8004

-- Strength=1 arrays: 10 entries - case variants (Apple/apple/APPLE) share one sort key
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8008', 1), 
    'documentdb_data.documents_rum_index_8008'::regclass
) entry;

-- ===== Single-path index with arrays/nested objects: strength=3 (case-sensitive) ======

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_nested_s3",
    "indexes": [{
      "key": { "tags": 1 },
      "name": "tags_collated_s3_idx",
      "collation": { "locale": "en", "strength": 3 }
    }]
  }',
  TRUE
);

-- Insert same documents as strength=1 test for comparison
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested_s3', '{"_id": 1, "tags": ["Apple", "Banana"]}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested_s3', '{"_id": 2, "tags": ["apple", "cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested_s3', '{"_id": 3, "tags": ["APPLE", "BANANA", "zebra"]}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested_s3', '{"_id": 4, "tags": "single_tag"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_nested_s3', '{"_id": 5, "tags": {"nested": "value"}}', NULL);

\d documentdb_data.documents_8005

-- Strength=3 arrays: 13 entries - case variants (apple, Apple, APPLE) each get separate sort keys
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8010', 1), 
    'documentdb_data.documents_rum_index_8010'::regclass
) entry;

-- ===== Wildcard index with collation ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_wildcard_coll",
    "indexes": [{
      "key": { "$**": 1 },
      "name": "wildcard_collated_idx",
      "collation": { "locale": "en", "strength": 2 }
    }]
  }',
  TRUE
);

SELECT (index_spec).index_name,
       documentdb_core.bson_get_value_text((index_spec).index_options, 'collation') AS collation
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections 
                       WHERE database_name = 'coll_idx_db' AND collection_name = 'coll_wildcard_coll')
ORDER BY index_id;

SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wildcard_coll', '{"_id": 1, "name": "Zebra", "city": "Austin"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wildcard_coll', '{"_id": 2, "name": "apple", "city": "Boston"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wildcard_coll', '{"_id": 3, "name": "Apple", "city": "Chicago"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wildcard_coll', '{"_id": 4, "name": "banana", "city": "Denver"}', NULL);

\d documentdb_data.documents_8006

-- Strength=2 wildcard: indexes all fields; name sorted as apple < banana < Zebra
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8012', 1), 
    'documentdb_data.documents_rum_index_8012'::regclass
) entry;

-- ===== Wildcard projection index ======

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_wp_coll",
    "indexes": [{
      "key": { "$**": 1 },
      "name": "wp_collated_idx",
      "wildcardProjection": { "title": 1 },
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SELECT (index_spec).index_name,
       documentdb_core.bson_get_value_text((index_spec).index_options, 'collation') AS collation
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections 
                       WHERE database_name = 'coll_idx_db' AND collection_name = 'coll_wp_coll')
ORDER BY index_id;

SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wp_coll', '{"_id": 1, "title": "Zebra", "other": "not_indexed"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wp_coll', '{"_id": 2, "title": "apple", "other": "not_indexed"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wp_coll', '{"_id": 3, "title": "APPLE", "other": "not_indexed"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_wp_coll', '{"_id": 4, "title": "banana", "other": "not_indexed"}', NULL);

\d documentdb_data.documents_8007

-- Strength=1 wildcard projection: only "title" field indexed; apple/APPLE collapsed
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8014', 1), 
    'documentdb_data.documents_rum_index_8014'::regclass
) entry;

-- ===== Truncated long strings with collation ======
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_truncated",
    "indexes": [{
      "key": { "longfield": 1 },
      "name": "longfield_collated_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- Insert documents with very long strings that will be truncated
-- Different prefixes to test ordering: "aaa..." vs "bbb..." vs "zzz..."
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated', 
  bson_build_document('_id'::text, 1, 'longfield'::text, ('aaa' || repeat('x', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated', 
  bson_build_document('_id'::text, 2, 'longfield'::text, ('AAA' || repeat('x', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated', 
  bson_build_document('_id'::text, 3, 'longfield'::text, ('bbb' || repeat('y', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated', 
  bson_build_document('_id'::text, 4, 'longfield'::text, ('BBB' || repeat('y', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated', 
  bson_build_document('_id'::text, 5, 'longfield'::text, ('zzz' || repeat('z', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated', 
  bson_build_document('_id'::text, 6, 'longfield'::text, ('ZZZ' || repeat('z', 3000))::text), NULL);

\d documentdb_data.documents_8008

-- Strength=1 truncated: 5 entries for 6 docs - aaa.../AAA... and bbb.../BBB... collapsed; $flags=1 indicates truncation
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8016', 1), 
    'documentdb_data.documents_rum_index_8016'::regclass
) entry;

-- ===== Truncated strings with strength=3 (case-sensitive) ======

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_truncated_s3",
    "indexes": [{
      "key": { "longfield": 1 },
      "name": "longfield_collated_s3_idx",
      "collation": { "locale": "en", "strength": 3 }
    }]
  }',
  TRUE
);

-- Same long strings with case-sensitive collation
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated_s3', 
  bson_build_document('_id'::text, 1, 'longfield'::text, ('aaa' || repeat('x', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated_s3', 
  bson_build_document('_id'::text, 2, 'longfield'::text, ('AAA' || repeat('x', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated_s3', 
  bson_build_document('_id'::text, 3, 'longfield'::text, ('bbb' || repeat('y', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated_s3', 
  bson_build_document('_id'::text, 4, 'longfield'::text, ('BBB' || repeat('y', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated_s3', 
  bson_build_document('_id'::text, 5, 'longfield'::text, ('zzz' || repeat('z', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_truncated_s3', 
  bson_build_document('_id'::text, 6, 'longfield'::text, ('ZZZ' || repeat('z', 3000))::text), NULL);

\d documentdb_data.documents_8009

-- Strength=3 truncated: 8 entries for 6 docs - aaa.../AAA..., bbb.../BBB..., zzz.../ZZZ... each distinct; $flags=1 indicates truncation
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8018', 1), 
    'documentdb_data.documents_rum_index_8018'::regclass
) entry;

-- ===== Mix of truncated and non-truncated strings ======

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_mixed_length",
    "indexes": [{
      "key": { "data": 1 },
      "name": "data_collated_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- Short strings (no truncation)
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_mixed_length', '{"_id": 1, "data": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_mixed_length', '{"_id": 2, "data": "apple"}', NULL);
-- Medium strings with same prefix as truncated ones
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_mixed_length', 
  bson_build_document('_id'::text, 3, 'data'::text, ('apple' || repeat('z', 50))::text), NULL);
-- Long truncated strings
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_mixed_length', 
  bson_build_document('_id'::text, 4, 'data'::text, ('apple' || repeat('z', 3000))::text), NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_mixed_length', 
  bson_build_document('_id'::text, 5, 'data'::text, ('APPLE' || repeat('z', 3000))::text), NULL);
-- Another short string that should sort after apple
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_mixed_length', '{"_id": 6, "data": "banana"}', NULL);

\d documentdb_data.documents_8010

-- Strength=1 mixed lengths: short "Apple"/"apple" collapsed; truncated entries have $flags=1
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8020', 1), 
    'documentdb_data.documents_rum_index_8020'::regclass
) entry;

-- ===== Documents inserted BEFORE index creation (index build) ======
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 1, "name": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 2, "name": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 3, "name": "APPLE"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 4, "name": "Banana"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 5, "name": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 6, "name": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 7, "name": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_test', '{"_id": 8, "name": "CHERRY"}', NULL);

-- Now create the collation-aware index on existing documents
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_build_test",
    "indexes": [{
      "key": { "name": 1 },
      "name": "name_build_collated_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

\d documentdb_data.documents_8011

-- Strength=1 index build: 8 docs produce 5 entries - Apple/apple/APPLE, Banana/banana, cherry/Cherry/CHERRY collapsed
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8022', 1), 
    'documentdb_data.documents_rum_index_8022'::regclass
) entry;

-- ===== Index build with strength=3 (case-sensitive) ======
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_s3', '{"_id": 1, "name": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_s3', '{"_id": 2, "name": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_s3', '{"_id": 3, "name": "APPLE"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_s3', '{"_id": 4, "name": "Banana"}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_build_s3', '{"_id": 5, "name": "banana"}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_build_s3",
    "indexes": [{
      "key": { "name": 1 },
      "name": "name_build_s3_idx",
      "collation": { "locale": "en", "strength": 3 }
    }]
  }',
  TRUE
);

\d documentdb_data.documents_8012

-- Strength=3 index build: 5 docs produce 7 entries - apple, Apple, APPLE, Banana, banana each distinct
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8024', 1), 
    'documentdb_data.documents_rum_index_8024'::regclass
) entry;

-- ===== Partial filter expression with wildcard on details.$** ======
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial', '{"_id": 1, "name": "Apple", "status": "Active", "details": {"items": ["apple", "banana", "cherry"], "info": {"city": "austin", "country": "usa"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial', '{"_id": 2, "name": "apple", "status": "INACTIVE", "details": {"items": ["APPLE", "BANANA", "CHERRY"], "info": {"city": "AUSTIN", "country": "USA"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial', '{"_id": 3, "name": "APPLE", "status": "ACTIVE", "details": {"items": ["Apple", "Banana", "Cherry"], "info": {"city": "Austin", "country": "Usa"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial', '{"_id": 4, "name": "Banana", "status": "active", "details": {"items": ["aPPLE", "bANANA", "cHERRY"], "info": {"city": "aUSTIN", "country": "uSA"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial', '{"_id": 5, "name": "banana", "status": "Inactive", "details": {"items": ["APPle", "BANana", "CHErry"], "info": {"city": "AUSTin", "country": "UsA"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial', '{"_id": 6, "name": "cherry", "status": "aCTIVE", "details": {"items": ["applE", "bananA", "cherrY"], "info": {"city": "austiN", "country": "usA"}}}', NULL);

-- Create single-path index on name and wildcard index on details.$**
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_partial",
    "indexes": [
      {
        "key": { "name": 1 },
        "name": "name_partial_s1_idx",
        "collation": { "locale": "en", "strength": 1 },
        "partialFilterExpression": { "status": "active" }
      },
      {
        "key": { "details.$**": 1 },
        "name": "details_wildcard_s1_idx",
        "collation": { "locale": "en", "strength": 1 },
        "partialFilterExpression": { "status": "active" }
      }
    ]
  }',
  TRUE
);

\d documentdb_data.documents_8013

-- Show index info
SELECT (index_spec).index_name,
       documentdb_core.bson_get_value_text((index_spec).index_options, 'collation') AS collation
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections 
                       WHERE database_name = 'coll_idx_db' AND collection_name = 'coll_partial')
ORDER BY index_id;

-- Strength=1 partial: only 4 entries (Apple, Banana, cherry) for docs where status="active" (case-insensitive match)
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8026', 1), 
    'documentdb_data.documents_rum_index_8026'::regclass
) entry;

-- Strength=1 wildcard partial: nested details.$** indexed for docs where status="active"
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8027', 1), 
    'documentdb_data.documents_rum_index_8027'::regclass
) entry;

-- ===== Partial filter expression with strength=3 (case-sensitive) ======
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial_s3', '{"_id": 1, "name": "Apple", "status": "Active", "details": {"items": ["apple", "banana", "cherry"], "info": {"city": "austin", "country": "usa"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial_s3', '{"_id": 2, "name": "apple", "status": "INACTIVE", "details": {"items": ["APPLE", "BANANA", "CHERRY"], "info": {"city": "AUSTIN", "country": "USA"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial_s3', '{"_id": 3, "name": "APPLE", "status": "ACTIVE", "details": {"items": ["Apple", "Banana", "Cherry"], "info": {"city": "Austin", "country": "Usa"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial_s3', '{"_id": 4, "name": "Banana", "status": "active", "details": {"items": ["aPPLE", "bANANA", "cHERRY"], "info": {"city": "aUSTIN", "country": "uSA"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial_s3', '{"_id": 5, "name": "banana", "status": "Inactive", "details": {"items": ["APPle", "BANana", "CHErry"], "info": {"city": "AUSTin", "country": "UsA"}}}', NULL);
SELECT documentdb_api.insert_one('coll_idx_db', 'coll_partial_s3', '{"_id": 6, "name": "cherry", "status": "aCTIVE", "details": {"items": ["applE", "bananA", "cherrY"], "info": {"city": "austiN", "country": "usA"}}}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_idx_db',
  '{
    "createIndexes": "coll_partial_s3",
    "indexes": [
      {
        "key": { "name": 1 },
        "name": "name_partial_s3_idx",
        "collation": { "locale": "en", "strength": 3 },
        "partialFilterExpression": { "status": "active" }
      },
      {
        "key": { "details.$**": 1 },
        "name": "details_wildcard_s3_idx",
        "collation": { "locale": "en", "strength": 3 },
        "partialFilterExpression": { "status": "active" }
      }
    ]
  }',
  TRUE
);

\d documentdb_data.documents_8014

-- Show index info
SELECT (index_spec).index_name,
       documentdb_core.bson_get_value_text((index_spec).index_options, 'collation') AS collation
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections 
                       WHERE database_name = 'coll_idx_db' AND collection_name = 'coll_partial_s3')
ORDER BY index_id;

-- Strength=3 partial: only 2 entries (Banana) - only doc with exact status="active" indexed
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8029', 1), 
    'documentdb_data.documents_rum_index_8029'::regclass
) entry;

-- Strength=3 wildcard partial: nested details.$** indexed only for doc with exact status="active"
SELECT entry->>'offset' AS offset,
       collation_index_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) AS index_term
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    public.get_raw_page('documentdb_data.documents_rum_index_8030', 1), 
    'documentdb_data.documents_rum_index_8030'::regclass
) entry;


DROP SCHEMA collation_index_test_schema CASCADE;

RESET documentdb.enableCollationWithIndexes;
RESET documentdb_core.enableCollation;
