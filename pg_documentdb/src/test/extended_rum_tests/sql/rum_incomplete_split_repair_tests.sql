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

SET documentdb_rum.fix_incomplete_split TO off;
SET documentdb_rum.track_incomplete_split TO off;
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
SET documentdb_rum.track_incomplete_split TO on;
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

-- now enable tracking of the incomplete splits and repeat - the insert should go through (after finishing the incomplete split)
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
SET documentdb_rum.track_incomplete_split TO off;
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

-- now insert some more docs - we should get a lost path error
SET documentdb_rum.enable_inject_page_split_incomplete TO off;
SET documentdb.rumFailOnLostPath TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document('_id'::text, i, 'a'::text, i)))
FROM generate_series(2001, 3000) i;

-- repair the index using the rum repair functions
SET documentdb_rum.track_incomplete_split TO on;
SET documentdb_rum.fix_incomplete_split TO on;

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

-- this now works fine once dynamic repair is turned on:
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
SET documentdb_rum.track_incomplete_split TO off;
SELECT FORMAT('TRUNCATE documentdb_data.documents_%s', :collection_id) \gexec
SELECT COUNT(*) FROM documentdb_api.collection('rumdb', 'incomplete_split');

SET documentdb_rum.enable_inject_page_split_incomplete TO on;
SELECT COUNT(documentdb_api.insert_one(
    'rumdb', 'incomplete_split',
    bson_build_document(
        '_id'::text, i, 'a'::text, repeat('a', 1900) || i)))
FROM generate_series(1, 10000) i;

-- assert that documents got missed due to injecting incomplete split.
SELECT COUNT(*) < 10000
FROM documentdb_api.collection('rumdb', 'incomplete_split');

SET documentdb_rum.track_incomplete_split TO on;
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

RESET documentdb.rumFailOnLostPath;
RESET documentdb_rum.fix_incomplete_split;
RESET documentdb_rum.track_incomplete_split;

SELECT documentdb_api.drop_collection('rumdb', 'incomplete_split');
DROP SCHEMA rum_incomplete_split_repair_test CASCADE;
