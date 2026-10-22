-- Copyright (c) Microsoft Corporation.  All rights reserved.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 10200;
SET documentdb.next_collection_index_id TO 10200;

-- An INCOMPLETE_SPLIT flag that was set on a page whose split is already
-- complete must not cause split completion to insert a duplicate downlink.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rum_invalid_flag_db',
    '{ "createIndexes": "entries", "indexes": [ { "key": { "s": 1 }, "name": "s_1" } ] }');

SELECT FORMAT('documentdb_data.documents_rum_index_%s', index_id) AS entry_index_name
FROM documentdb_api_catalog.collection_indexes ci
JOIN documentdb_api_catalog.collections c ON ci.collection_id = c.collection_id
WHERE c.database_name = 'rum_invalid_flag_db'
  AND c.collection_name = 'entries'
  AND (ci.index_spec).index_name = 's_1' \gset

SELECT COUNT(documentdb_api.insert_one(
    'rum_invalid_flag_db', 'entries',
    bson_build_document('_id'::text, i, 's'::text, lpad(i::text, 200, 'x'))))
FROM generate_series(1, 400) i;

-- The tree has an internal root whose children are leaves.
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'entry_index_name'::regclass, 1) ->> 'flagsStr' AS root_flags;

SELECT MIN((e->>'childBlock')::int) FILTER (WHERE (e->>'offset')::int = 1) AS left_leaf,
       MIN((e->>'childBlock')::int) FILTER (WHERE (e->>'offset')::int = 2) AS second_leaf,
       MAX((e->>'childBlock')::int) FILTER (WHERE (e->>'offset')::int = (SELECT MAX((x->>'offset')::int)
            FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'entry_index_name'::regclass, 1) x)) AS right_leaf,
       COUNT(*) AS initial_children
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'entry_index_name'::regclass, 1) e \gset

SELECT (documentdb_api_internal.documentdb_rum_page_get_stats_index(:'entry_index_name'::regclass, :left_leaf) ->> 'rightLink')::int = :second_leaf AS left_leaf_links_to_second;
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'entry_index_name'::regclass, :right_leaf) ->> 'rightLink' IS NULL AS right_leaf_is_rightmost;

-- case 1: flag a non-rightmost leaf whose right sibling already has a downlink
SELECT documentdb_api_internal.documentdb_rum_test_set_incomplete_split_on_page(
    :'entry_index_name'::regclass, :left_leaf, true);
SELECT documentdb_api.insert_one('rum_invalid_flag_db', 'entries', '{ "_id": -1, "s": "0" }');

SELECT COUNT(*) = :initial_children AS no_new_children,
       COUNT(DISTINCT e->>'childBlock') = COUNT(*) AS distinct_children
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'entry_index_name'::regclass, 1) e;
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'entry_index_name'::regclass, :left_leaf) ->> 'flagsStr' AS left_leaf_flags;

-- case 2: flag the rightmost leaf of the level
SELECT documentdb_api_internal.documentdb_rum_test_set_incomplete_split_on_page(
    :'entry_index_name'::regclass, :right_leaf, true);
SELECT documentdb_api.insert_one('rum_invalid_flag_db', 'entries', '{ "_id": -2, "s": "zzz" }');

SELECT COUNT(*) = :initial_children AS no_new_children,
       COUNT(DISTINCT e->>'childBlock') = COUNT(*) AS distinct_children
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'entry_index_name'::regclass, 1) e;
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'entry_index_name'::regclass, :right_leaf) ->> 'flagsStr' AS right_leaf_flags;

-- case 3: flag the entry tree root
SELECT documentdb_api_internal.documentdb_rum_test_set_incomplete_split_on_page(
    :'entry_index_name'::regclass, 1, true);
SELECT documentdb_api.insert_one('rum_invalid_flag_db', 'entries', '{ "_id": -3, "s": "1" }');
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'entry_index_name'::regclass, 1) ->> 'flagsStr' AS root_flags;

SELECT COUNT(*) = :initial_children AS no_new_children,
       COUNT(DISTINCT e->>'childBlock') = COUNT(*) AS distinct_children
FROM documentdb_api_internal.documentdb_rum_page_get_entries_index(:'entry_index_name'::regclass, 1) e;

-- every inserted value is still reachable through the index
SET enable_seqscan TO off;
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('rum_invalid_flag_db',
    '{ "find": "entries", "filter": { "s": { "$in": [ "0", "1", "zzz" ] } }, "projection": { "_id": 1 }, "sort": { "_id": 1 } }');
RESET enable_seqscan;

-- case 4: flag the root of a posting tree
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rum_invalid_flag_db',
    '{ "createIndexes": "postings", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }');

SELECT FORMAT('documentdb_data.documents_rum_index_%s', index_id) AS posting_index_name
FROM documentdb_api_catalog.collection_indexes ci
JOIN documentdb_api_catalog.collections c ON ci.collection_id = c.collection_id
WHERE c.database_name = 'rum_invalid_flag_db'
  AND c.collection_name = 'postings'
  AND (ci.index_spec).index_name = 'a_1' \gset

SET documentdb_rum.data_page_posting_tree_size TO 3;
SELECT COUNT(documentdb_api.insert_one(
    'rum_invalid_flag_db', 'postings', bson_build_document('_id'::text, i, 'a'::text, 1)))
FROM generate_series(1, 10000) i;
RESET documentdb_rum.data_page_posting_tree_size;

WITH pages AS (
    SELECT blkno, documentdb_api_internal.documentdb_rum_page_get_stats_index(:'posting_index_name'::regclass, blkno) AS stats
    FROM generate_series(1, (pg_relation_size(:'posting_index_name'::regclass) / current_setting('block_size')::int)::int - 1) blkno)
SELECT MIN(blkno) FILTER (WHERE stats->>'leftLink' IS NULL AND stats->>'rightLink' IS NULL) AS posting_root,
       MIN(blkno) FILTER (WHERE stats->>'flagsStr' = 'LEAF|DATA' AND stats->>'leftLink' IS NOT NULL AND stats->>'rightLink' IS NULL) AS posting_right_leaf
FROM pages WHERE stats->>'flagsStr' LIKE '%DATA%' \gset

SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'posting_index_name'::regclass, :posting_root) ->> 'flagsStr' AS posting_root_flags;
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'posting_index_name'::regclass, :posting_right_leaf) ->> 'flagsStr' AS posting_right_leaf_flags;

SELECT documentdb_api_internal.documentdb_rum_test_set_incomplete_split_on_page(
    :'posting_index_name'::regclass, :posting_root, true);
SELECT documentdb_api.insert_one('rum_invalid_flag_db', 'postings', '{ "_id": 20000, "a": 1 }');
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'posting_index_name'::regclass, :posting_root) ->> 'flagsStr' AS posting_root_flags;

-- case 5: flag the rightmost leaf of the posting tree
SELECT documentdb_api_internal.documentdb_rum_test_set_incomplete_split_on_page(
    :'posting_index_name'::regclass, :posting_right_leaf, true);
SELECT documentdb_api.insert_one('rum_invalid_flag_db', 'postings', '{ "_id": 20001, "a": 1 }');
SELECT documentdb_api_internal.documentdb_rum_page_get_stats_index(:'posting_index_name'::regclass, :posting_right_leaf) ->> 'flagsStr' AS posting_right_leaf_flags;

SET enable_seqscan TO off;
SELECT document FROM documentdb_api_catalog.bson_aggregation_count('rum_invalid_flag_db',
    '{ "count": "postings", "query": { "a": 1 } }');
RESET enable_seqscan;
