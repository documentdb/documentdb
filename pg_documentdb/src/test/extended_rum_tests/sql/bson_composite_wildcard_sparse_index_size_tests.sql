SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 1100;
SET documentdb.next_collection_index_id TO 1100;

set documentdb.defaultUseCompositeOpClass to on;

-- create composite wildcard index - should be sparse already
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'wildcard_db', '{ "createIndexes": "wildcard_coll", "indexes": [ { "name": "sparse_wildcard_index", "key": { "a.$**": 1 } } ] }', TRUE);

-- insert 5000 rows that don't match the index path
SELECT COUNT(documentdb_api.insert_one('wildcard_db', 'wildcard_coll', bson_build_document('_id'::text, i, 'b'::text, i))) FROM generate_series(1, 5000) i;

ANALYZE documentdb_data.documents_1101;

-- check index size - should be empty.
SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1102', 0));

-- read the root page: it should be a page that's a leaf with 0 entries.
SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1102', 1));
SELECT jsonb_set(documentdb_api_internal.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_1102', 1), 'documentdb_data.documents_rum_index_1102'::regclass), '{tupleTid}', 'null');

-- now insert into 'a'
SELECT documentdb_api.insert_one('wildcard_db', 'wildcard_coll', bson_build_document('_id'::text, 5001, 'a'::text, 5001));

ANALYZE documentdb_data.documents_1101;

-- read the root page: it should be a page that's a leaf with 1 entry.
SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1102', 1));
SELECT jsonb_set(jsonb_set(jsonb_set(documentdb_api_internal.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_1102', 1), 'documentdb_data.documents_rum_index_1102'::regclass), '{tupleTid}', 'null'), '{firstTids}', 'null'), '{data}', 'null');

TRUNCATE documentdb_data.documents_1101;

-- unset the guc to see the other behavior
set documentdb.enableCompositeWildcardSkipEmptyEntries to off;

-- insert 5000 rows that don't match the index path
SELECT COUNT(documentdb_api.insert_one('wildcard_db', 'wildcard_coll', bson_build_document('_id'::text, i, 'b'::text, i))) FROM generate_series(1, 5000) i;

ANALYZE documentdb_data.documents_1101;

-- read the root page: it should be a page that's a leaf with 1 entry.
SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1102', 1));
SELECT jsonb_set(jsonb_set(documentdb_api_internal.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_1102', 1), 'documentdb_data.documents_rum_index_1102'::regclass), '{tupleTid}', 'null'), '{data}', 'null');
