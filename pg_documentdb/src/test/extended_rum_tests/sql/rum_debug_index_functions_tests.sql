-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 10100;
SET documentdb.next_collection_index_id TO 10100;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumdebugdb',
    '{ "createIndexes": "rum_debug_index", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }');

SELECT index_id AS index_id
FROM documentdb_api_catalog.collection_indexes ci
JOIN documentdb_api_catalog.collections c ON ci.collection_id = c.collection_id
WHERE c.database_name = 'rumdebugdb'
  AND c.collection_name = 'rum_debug_index'
  AND (ci.index_spec).index_name = 'a_1' \gset

SELECT FORMAT('documentdb_data.documents_rum_index_%s', :index_id) AS index_name \gset

-- a few distinct values, plus one value repeated enough to build a posting tree
SELECT COUNT(documentdb_api.insert_one(
    'rumdebugdb', 'rum_debug_index',
    bson_build_document('_id'::text, i, 'a'::text, CASE WHEN i <= 20 THEN i ELSE 0 END)))
FROM generate_series(1, 3000) i;

SELECT (pg_relation_size(:'index_name') / current_setting('block_size')::int) AS num_blocks \gset

-- meta page: the index variant matches the raw page variant
SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info_index(:'index_name'::regclass) =
       documentdb_api_internal.documentdb_rum_get_meta_page_info(get_raw_page(:'index_name', 0)) AS meta_matches;

SELECT (meta->>'entryPages')::int > 0 AS has_entry_pages
FROM documentdb_api_internal.documentdb_rum_get_meta_page_info_index(:'index_name'::regclass) meta;

-- page stats: the index variant matches the raw page variant on every page
SELECT bool_and(
           documentdb_api_internal.documentdb_rum_page_get_stats_index(:'index_name'::regclass, blkno) =
           documentdb_api_internal.documentdb_rum_page_get_stats(get_raw_page(:'index_name', blkno))) AS stats_match
FROM generate_series(1, :num_blocks - 1) blkno;

SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'index_name'::regclass, 1) ->> 'flagsStr' AS root_flags;

-- entries on the root entry page: the index variant matches the raw page variant
SELECT COUNT(*) > 0 AS has_entries
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'index_name'::regclass, 1);

SELECT array_agg(e ORDER BY e->>'offset') =
       (SELECT array_agg(r ORDER BY r->>'offset')
        FROM documentdb_api_internal.documentdb_rum_page_get_entries(
            get_raw_page(:'index_name', 1), :'index_name'::regclass) r) AS entries_match
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'index_name'::regclass, 1) e;

-- data items on a posting tree page: the index variant matches the raw page variant
SELECT MIN(blkno) AS data_blkno
FROM generate_series(1, :num_blocks - 1) blkno
WHERE ((documentdb_api_internal.documentdb_rum_page_get_stats_index(:'index_name'::regclass, blkno) ->> 'flags')::int & 1) = 1 \gset

SELECT COUNT(*) > 0 AS has_data_items
FROM documentdb_api_internal.documentdb_rum_page_get_data_items_index(:'index_name'::regclass, :data_blkno);

SELECT array_agg(d ORDER BY (d->>'offset')::int) =
       (SELECT array_agg(r ORDER BY (r->>'offset')::int)
        FROM documentdb_api_internal.documentdb_rum_page_get_data_items(
            get_raw_page(:'index_name', :data_blkno)) r) AS data_items_match
FROM documentdb_api_internal.documentdb_rum_page_get_data_items_index(:'index_name'::regclass, :data_blkno) d;

-- mismatched page types warn and return no items
SELECT COUNT(e) FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'index_name'::regclass, :data_blkno) e;
SELECT COUNT(d) FROM documentdb_api_internal.documentdb_rum_page_get_data_items_index(:'index_name'::regclass, 1) d;


-- multi-level entry tree: the root entry page is internal and its entries carry downlinks
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumdebugdb',
    '{ "createIndexes": "rum_debug_index_wide", "indexes": [ { "key": { "s": 1 }, "name": "s_1" } ] }');

SELECT index_id AS wide_index_id
FROM documentdb_api_catalog.collection_indexes ci
JOIN documentdb_api_catalog.collections c ON ci.collection_id = c.collection_id
WHERE c.database_name = 'rumdebugdb'
  AND c.collection_name = 'rum_debug_index_wide'
  AND (ci.index_spec).index_name = 's_1' \gset

SELECT FORMAT('documentdb_data.documents_rum_index_%s', :wide_index_id) AS wide_index_name \gset

SELECT COUNT(documentdb_api.insert_one(
    'rumdebugdb', 'rum_debug_index_wide',
    bson_build_document('_id'::text, i, 's'::text, lpad(i::text, 200, 'x'))))
FROM generate_series(1, 2000) i;

SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'wide_index_name'::regclass, 1) ->> 'flagsStr' AS wide_root_flags;

SELECT array_agg(e ORDER BY (e->>'offset')::int) =
       (SELECT array_agg(r ORDER BY (r->>'offset')::int)
        FROM documentdb_api_internal.documentdb_rum_page_get_entries(
            get_raw_page(:'wide_index_name', 1), :'wide_index_name'::regclass) r) AS wide_root_entries_match
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'wide_index_name'::regclass, 1) e;

SELECT COUNT(*) > 1 AS has_multiple_children,
       bool_and(e->>'entryType' = 'internal') AS all_internal,
       bool_and(e->'childBlock' IS NOT NULL AND jsonb_typeof(e->'childBlock') = 'number') AS all_have_child,
       bool_and((e->>'numPostings')::int = 0) AS no_postings,
       bool_and(e->'firstTids' = 'null'::jsonb) AS no_first_tids,
       COUNT(DISTINCT e->>'childBlock') = COUNT(*) AS distinct_children
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'wide_index_name'::regclass, 1) e;

-- every downlink points at an entry page (not a data page)
SELECT bool_and(
           ((documentdb_api_internal.documentdb_rum_page_get_stats_index(
                :'wide_index_name'::regclass, (e->>'childBlock')::int) ->> 'flags')::int & 1) = 0) AS children_are_entry_pages
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'wide_index_name'::regclass, 1) e;

-- NULL arguments return NULL / no rows rather than reading block 0
SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info_index(NULL) IS NULL AS meta_null_index;
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'index_name'::regclass, NULL) IS NULL AS stats_null_block;
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(NULL, 1) IS NULL AS stats_null_index;
SELECT COUNT(*) FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'index_name'::regclass, NULL);
SELECT COUNT(*) FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(NULL, 1);
SELECT COUNT(*) FROM documentdb_api_internal.documentdb_rum_page_get_data_items_index(:'index_name'::regclass, NULL);
SELECT COUNT(*) FROM documentdb_api_internal.documentdb_rum_page_get_data_items_index(NULL, :data_blkno);
