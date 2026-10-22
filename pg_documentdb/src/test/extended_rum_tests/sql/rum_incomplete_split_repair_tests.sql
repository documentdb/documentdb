-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 2700;
SET documentdb.next_collection_index_id TO 2700;

CREATE SCHEMA rum_incomplete_split_repair_test;

CREATE FUNCTION rum_incomplete_split_repair_test.index_term_to_bson(bytea)
RETURNS bson
LANGUAGE c
AS '$libdir/pg_documentdb', 'gin_bson_index_term_to_bson';

-- Simulate legacy interrupted splits without restoring the retired insertion path.
CREATE FUNCTION rum_incomplete_split_repair_test.clear_incomplete_split_flags(index_rel regclass)
RETURNS boolean
LANGUAGE SQL
AS $$
    SELECT COUNT(documentdb_api_internal.documentdb_rum_test_set_incomplete_split_on_page(
        index_rel, b, FALSE)) > 0
    FROM generate_series(1, (pg_relation_size(index_rel) / current_setting('block_size')::int)::int - 1) b
    WHERE documentdb_api_internal.documentdb_rum_page_get_stats_index(index_rel, b)->>'flagsStr'
        LIKE '%INCOMPLETE_SPLIT%';
$$;

SET documentdb_rum.fix_incomplete_split TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumdb',
    '{ "createIndexes": "incomplete_split", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": false } ] }');

SELECT collection_id AS collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'rumdb'
  AND collection_name = 'incomplete_split' \gset

SELECT index_id AS index_id
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :collection_id
  AND (index_spec).index_name = 'a_1' \gset

SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(1, 1000) i;

-- the root page has all the children (the tree consistent)
SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);

-- insert second batch of documents
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(2001, 3000) i;

SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);
SELECT entry->> 'offset',
       rum_incomplete_split_repair_test.index_term_to_bson(
           (entry->>'firstEntry')::bytea)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass) entry;

SELECT COUNT(*)
FROM documentdb_api.collection('rumdb', 'incomplete_split')
WHERE document @@ '{ "a": { "$exists": true } }';

CALL documentdb_api.drop_indexes(
    'rumdb',
    '{ "dropIndexes": "incomplete_split", "index": "a_1" }');
SELECT FORMAT('TRUNCATE documentdb_data.documents_%s', :collection_id) \gexec
SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumdb',
    '{ "createIndexes": "incomplete_split", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": false } ] }',
    TRUE);

SELECT index_id AS index_id
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :collection_id
  AND (index_spec).index_name = 'a_1' \gset

-- insert documents that cause splits and leave the tree in a dangling state
SET documentdb_rum.enable_inject_page_split_incomplete TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(1, 1000) i;

-- assert that not all documents got inserted
SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');

-- the root page doesn't have all the children (the tree is inconsistent)
SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);

-- now don't throw on incomplete split, but insert some more - we should get lost path here.
SET documentdb_rum.enable_inject_page_split_incomplete TO off;
SET documentdb.rumFailOnLostPath TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(2001, 3000) i;

-- the root page doesn't have all the children (the tree is inconsistent)
SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);
SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');

-- Repeat the injection and enable inline repair so inserts finish the splits.
CALL documentdb_api.drop_indexes(
    'rumdb',
    '{ "dropIndexes": "incomplete_split", "index": "a_1" }');
SELECT FORMAT('TRUNCATE documentdb_data.documents_%s', :collection_id) \gexec

SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumdb',
    '{ "createIndexes": "incomplete_split", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": false } ] }',
    TRUE);

SELECT index_id AS index_id
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :collection_id
  AND (index_spec).index_name = 'a_1' \gset

SET documentdb_rum.enable_inject_page_split_incomplete TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(1, 1000) i;

-- the root page doesn't have all the children (the tree is inconsistent)
SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);
SELECT entry->> 'offset',
       rum_incomplete_split_repair_test.index_term_to_bson(
           (entry->>'firstEntry')::bytea)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass) entry;

-- assert that not all documents got inserted
SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');

-- this no longer fails
SET documentdb_rum.fix_incomplete_split TO on;
SET documentdb_rum.enable_inject_page_split_incomplete TO off;
SET documentdb.rumFailOnLostPath TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(2001, 3000) i;

-- not all the children are here.
SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);
SELECT entry->> 'offset',
       rum_incomplete_split_repair_test.index_term_to_bson(
           (entry->>'firstEntry')::bytea)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass) entry;

-- count is correct
SELECT COUNT(*)
FROM documentdb_api.collection('rumdb', 'incomplete_split')
WHERE document @@ '{ "a": { "$exists": true } }';

-- now repeat this exercise again but use the repair function to fix it.
SET documentdb_rum.fix_incomplete_split TO off;
CALL documentdb_api.drop_indexes(
    'rumdb',
    '{ "dropIndexes": "incomplete_split", "index": "a_1" }');
SELECT FORMAT('TRUNCATE documentdb_data.documents_%s', :collection_id) \gexec

SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumdb',
    '{ "createIndexes": "incomplete_split", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": false } ] }',
    TRUE);

SELECT index_id AS index_id
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :collection_id
  AND (index_spec).index_name = 'a_1' \gset

SET documentdb_rum.enable_inject_page_split_incomplete TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(1, 1000) i;

SELECT rum_incomplete_split_repair_test.clear_incomplete_split_flags(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);

-- the root page doesn't have all the children (the tree is inconsistent)
SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);
SELECT entry->> 'offset',
       rum_incomplete_split_repair_test.index_term_to_bson(
           (entry->>'firstEntry')::bytea)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass) entry;

-- assert that not all documents got inserted
SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');

-- now insert some more docs - we should get a lost path error
SET documentdb_rum.enable_inject_page_split_incomplete TO off;
SET documentdb.rumFailOnLostPath TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(2001, 3000) i;

-- repair the index using the rum repair functions
-- Keep inline repair disabled until the repair function has marked the legacy splits.

-- run in dry run mode - reports but doesn't fix.
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    FALSE, TRUE);
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(2001, 3000) i;

-- now run in real mode
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    FALSE, FALSE);

-- Inserts finish the marked splits once inline repair is enabled.
SET documentdb_rum.fix_incomplete_split TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(2001, 3000) i;

-- not all the children are here.
SELECT COUNT(*)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);
SELECT entry->> 'offset',
       rum_incomplete_split_repair_test.index_term_to_bson(
           (entry->>'firstEntry')::bytea)
FROM documentdb_api_internal.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass) entry;

-- count is correct
SELECT COUNT(*)
FROM documentdb_api.collection('rumdb', 'incomplete_split')
WHERE document @@ '{ "a": { "$exists": true } }';

-- now repeat with larger index keys to see if there's multiple levels.
SET documentdb_rum.fix_incomplete_split TO off;
SELECT FORMAT('TRUNCATE documentdb_data.documents_%s', :collection_id) \gexec
SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');

SET documentdb_rum.enable_inject_page_split_incomplete TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i, 'a'::text, repeat('a', 1900) || i)))
FROM generate_series(1, 10000) i;

SELECT rum_incomplete_split_repair_test.clear_incomplete_split_flags(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);

-- assert that documents got missed due to injecting incomplete split.
SELECT COUNT(*) < 10000
FROM documentdb_api.collection('rumdb', 'incomplete_split');

SET documentdb_rum.fix_incomplete_split TO on;
SET documentdb_rum.enable_inject_page_split_incomplete TO off;

-- run in dry run mode - reports but doesn't fix.
SET client_min_messages TO WARNING;
-- now fix the pages
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    FALSE, TRUE);
-- rerunning in dryrunmode should only report that it's in incomplete split page
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    FALSE, FALSE);
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    FALSE, TRUE);
RESET client_min_messages;

-- insert a bunch of docs (still fails with lost path)
SET documentdb.rumFailOnLostPath TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i + 10000, 'a'::text, repeat('a', 1900) || i)))
FROM generate_series(1, 10000) i;

-- rerun with fixing data pages
SET client_min_messages TO WARNING;
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    TRUE, FALSE);
RESET client_min_messages;

-- inserts finally work
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i + 10000, 'a'::text, repeat('a', 1900) || i)))
FROM generate_series(1, 10000) i;

-- no inconsistencies in dryrun mode - expect no failures
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    TRUE, TRUE);

-- now build a tree with more than 2 levels and leave an incomplete split under a
-- non-leftmost internal page. The repair must walk every page at each level to find it.
RESET documentdb.rumFailOnLostPath;
SET documentdb_rum.fix_incomplete_split TO off;
CALL documentdb_api.drop_indexes(
    'rumdb',
    '{ "dropIndexes": "incomplete_split", "index": "a_1" }');
SELECT FORMAT('TRUNCATE documentdb_data.documents_%s', :collection_id) \gexec

SET documentdb.indexTermLimitOverride TO 2000;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumdb',
    '{ "createIndexes": "incomplete_split", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": false } ] }',
    TRUE);

SELECT index_id AS index_id
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :collection_id
  AND (index_spec).index_name = 'a_1' \gset

-- large incompressible keys so that the entry tree has multiple internal levels
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i, 'a'::text,
        'b' || lpad(i::text, 6, '0') ||
        (SELECT string_agg(md5(i::text || '_' || j::text), '') FROM generate_series(1, 30) j))))
FROM generate_series(1, 2000) i;

-- the root has internal pages as children (more than one internal page below the root)
SELECT pg_relation_size(FORMAT('documentdb_data.documents_rum_index_%s', :index_id)) / 8192 AS index_blocks \gset
SELECT COUNT(*) > 2 AS has_multiple_internal_pages
FROM generate_series(1, :index_blocks - 1) b
WHERE documentdb_api_internal.documentdb_rum_page_get_stats(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :index_id), b::int))->>'flagsStr' NOT LIKE '%LEAF%';

-- leave an incomplete split at the right end of the key space (under the rightmost internal page)
SET documentdb_rum.enable_inject_page_split_incomplete TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i, 'a'::text,
        'c' || lpad(i::text, 6, '0') ||
        (SELECT string_agg(md5(i::text || '_' || j::text), '') FROM generate_series(1, 30) j))))
FROM generate_series(3001, 3010) i;
SET documentdb_rum.enable_inject_page_split_incomplete TO off;

SELECT rum_incomplete_split_repair_test.clear_incomplete_split_flags(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass);

-- inserts fail with lost path
SET documentdb.rumFailOnLostPath TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i, 'a'::text,
        'c' || lpad(i::text, 6, '0') ||
        (SELECT string_agg(md5(i::text || '_' || j::text), '') FROM generate_series(1, 30) j))))
FROM generate_series(3011, 3100) i;

SET documentdb_rum.fix_incomplete_split TO on;
SET client_min_messages TO WARNING;

-- dry run reports the inconsistency without data pages tracking
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    FALSE, TRUE);

-- repair it
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    FALSE, FALSE);
RESET client_min_messages;

-- inserts now succeed after a single repair
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i, 'a'::text,
        'c' || lpad(i::text, 6, '0') ||
        (SELECT string_agg(md5(i::text || '_' || j::text), '') FROM generate_series(1, 30) j))))
FROM generate_series(3011, 3100) i;

-- no inconsistencies left
SELECT documentdb_api_internal.rum_repair_incomplete_split_on_index(
    FORMAT('documentdb_data.documents_rum_index_%s', :index_id)::regclass,
    TRUE, TRUE);
RESET documentdb.indexTermLimitOverride;

RESET documentdb.rumFailOnLostPath;
RESET documentdb_rum.fix_incomplete_split;

SELECT documentdb_api.drop_collection('rumdb', 'incomplete_split');
DROP SCHEMA rum_incomplete_split_repair_test CASCADE;
