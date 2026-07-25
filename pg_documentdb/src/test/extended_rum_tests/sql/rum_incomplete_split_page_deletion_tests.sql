SET search_path TO documentdb_api_catalog, documentdb_core, public;

SET documentdb.next_collection_id TO 2300;
SET documentdb.next_collection_index_id TO 2300;

CREATE SCHEMA rum_incomplete_split_page_deletion_test;

CREATE FUNCTION rum_incomplete_split_page_deletion_test.set_incomplete_split(
    index_relid regclass,
    block_number integer,
    set_incomplete_split boolean)
RETURNS void
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core',
   'documentdb_rum_test_set_incomplete_split_on_page';

-- Entry-tree page deletion must preserve both halves of an incomplete split.
SELECT documentdb_api.create_collection(
    'rum_incomplete_split_deletion_db', 'entry_pages');

SELECT collection_id AS entry_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'rum_incomplete_split_deletion_db'
  AND collection_name = 'entry_pages' \gset

SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off)',
    :entry_collection_id) \gexec

SELECT COUNT(documentdb_api.insert_one(
    'rum_incomplete_split_deletion_db',
    'entry_pages',
    FORMAT('{ "_id": %s, "a": %s }', i, i)::bson))
FROM generate_series(1, 5000) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rum_incomplete_split_deletion_db',
    '{ "createIndexes": "entry_pages", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }',
    TRUE);

SELECT index_id AS entry_index_id,
       FORMAT('documentdb_data.documents_rum_index_%s', index_id) AS entry_index_name
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :entry_collection_id
  AND index_id != :entry_collection_id \gset

SELECT documentdb_api.delete(
    'rum_incomplete_split_deletion_db',
    '{ "delete": "entry_pages", "deletes": [ { "q": { "_id": { "$gte": 1000, "$lte": 4000 } }, "limit": 0 } ] }');

CALL documentdb_test_helpers.wait_for_vacuum_horizon();

SET documentdb_rum.prune_rum_empty_pages TO off;
SELECT FORMAT(
    'VACUUM (INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON, PARALLEL 0) documentdb_data.documents_%s',
    :entry_collection_id) \gexec
SELECT documentdb_api_internal.rum_prune_empty_entries_on_index(
    :'entry_index_name'::regclass);

WITH pages AS
(
    SELECT page_number,
           documentdb_api_internal.documentdb_rum_page_get_stats(
               public.get_raw_page(:'entry_index_name', page_number)) AS page_stats
    FROM generate_series(
        1,
        (pg_relation_size(:'entry_index_name'::regclass) /
         current_setting('block_size')::integer)::integer - 1) AS page_number
)
SELECT page_number AS entry_target_page,
       (page_stats->>'leftLink')::integer AS entry_left_page
FROM pages
WHERE page_stats->>'flagsStr' = 'LEAF'
  AND (page_stats->>'nEntries')::integer = 1
  AND page_stats->>'leftLink' IS NOT NULL
  AND page_stats->>'rightLink' IS NOT NULL
ORDER BY page_number
LIMIT 1 \gset

SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'entry_index_name'::regclass, :entry_target_page, true);

SET documentdb_rum.fix_incomplete_split TO off;
SET documentdb_rum.prune_rum_empty_pages TO on;
SELECT documentdb_api_internal.rum_prune_empty_entries_on_index(
    :'entry_index_name'::regclass);

SELECT page_stats->>'flagsStr' LIKE '%INCOMPLETE_SPLIT%'
       AND page_stats->>'flagsStr' NOT LIKE '%DELETED%'
       AND page_stats->>'flagsStr' NOT LIKE '%HALFDEAD%'
       AS preserved_incomplete_entry_page
FROM (
    SELECT documentdb_api_internal.documentdb_rum_page_get_stats(
        public.get_raw_page(:'entry_index_name', :entry_target_page)) AS page_stats
) AS page;

SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'entry_index_name'::regclass, :entry_target_page, false);
SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'entry_index_name'::regclass, :entry_left_page, true);

SELECT documentdb_api_internal.rum_prune_empty_entries_on_index(
    :'entry_index_name'::regclass);

SELECT target_stats->>'flagsStr' NOT LIKE '%DELETED%'
       AND target_stats->>'flagsStr' NOT LIKE '%HALFDEAD%'
       AND left_stats->>'flagsStr' LIKE '%INCOMPLETE_SPLIT%'
       AS preserved_entry_right_half
FROM (
    SELECT documentdb_api_internal.documentdb_rum_page_get_stats(
               public.get_raw_page(:'entry_index_name', :entry_target_page)) AS target_stats,
           documentdb_api_internal.documentdb_rum_page_get_stats(
               public.get_raw_page(:'entry_index_name', :entry_left_page)) AS left_stats
) AS pages;

SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'entry_index_name'::regclass, :entry_left_page, false);
RESET documentdb_rum.fix_incomplete_split;

-- Posting-tree page deletion must apply the same guards.
SELECT documentdb_api.create_collection(
    'rum_incomplete_split_deletion_db', 'posting_pages');

SELECT collection_id AS posting_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'rum_incomplete_split_deletion_db'
  AND collection_name = 'posting_pages' \gset

SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off)',
    :posting_collection_id) \gexec

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rum_incomplete_split_deletion_db',
    '{ "createIndexes": "posting_pages", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }',
    TRUE);

SELECT index_id AS posting_index_id,
       FORMAT('documentdb_data.documents_rum_index_%s', index_id) AS posting_index_name
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :posting_collection_id
ORDER BY index_id DESC
LIMIT 1 \gset

SET documentdb_rum.data_page_posting_tree_size TO 3;
SELECT COUNT(documentdb_api.insert_one(
    'rum_incomplete_split_deletion_db',
    'posting_pages',
    FORMAT('{ "_id": %s, "a": 1 }', i)::bson))
FROM generate_series(1, 10000) AS i;

SELECT documentdb_api.delete(
    'rum_incomplete_split_deletion_db',
    '{ "delete": "posting_pages", "deletes": [ { "q": { "_id": { "$gt": 1 } }, "limit": 0 } ] }');

CALL documentdb_test_helpers.wait_for_vacuum_horizon();

SET documentdb_rum.vacuum_skip_prune_posting_tree_pages TO on;
SELECT FORMAT(
    'VACUUM (INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON, PARALLEL 0) documentdb_data.documents_%s',
    :posting_collection_id) \gexec

WITH pages AS
(
    SELECT page_number,
           documentdb_api_internal.documentdb_rum_page_get_stats(
               public.get_raw_page(:'posting_index_name', page_number)) AS page_stats
    FROM generate_series(
        1,
        (pg_relation_size(:'posting_index_name'::regclass) /
         current_setting('block_size')::integer)::integer - 1) AS page_number
),
candidates AS
(
    SELECT page_number,
           (page_stats->>'leftLink')::integer AS left_page,
           row_number() OVER (ORDER BY page_number) AS candidate_number
    FROM pages
    WHERE page_stats->>'flagsStr' = 'LEAF|DATA'
      AND (page_stats->>'nEntries')::integer = 0
      AND page_stats->>'leftLink' IS NOT NULL
      AND page_stats->>'rightLink' IS NOT NULL
)
SELECT MAX(page_number) FILTER (WHERE candidate_number = 1)
           AS posting_incomplete_page,
       MAX(page_number) FILTER (WHERE candidate_number = 3)
           AS posting_right_half_page,
       MAX(left_page) FILTER (WHERE candidate_number = 3)
           AS posting_right_half_left_page
FROM candidates \gset

SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'posting_index_name'::regclass, :posting_incomplete_page, true);
SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'posting_index_name'::regclass, :posting_right_half_left_page, true);

SET documentdb_rum.fix_incomplete_split TO off;
SET documentdb_rum.vacuum_skip_prune_posting_tree_pages TO off;
SELECT documentdb_api.delete(
    'rum_incomplete_split_deletion_db',
    '{ "delete": "posting_pages", "deletes": [ { "q": { "_id": 1 }, "limit": 1 } ] }');
CALL documentdb_test_helpers.wait_for_vacuum_horizon();
SELECT FORMAT(
    'VACUUM (INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON, PARALLEL 0) documentdb_data.documents_%s',
    :posting_collection_id) \gexec

SELECT page_stats->>'flagsStr' LIKE '%INCOMPLETE_SPLIT%'
       AND page_stats->>'flagsStr' NOT LIKE '%DELETED%'
       AS preserved_incomplete_posting_page
FROM (
    SELECT documentdb_api_internal.documentdb_rum_page_get_stats(
        public.get_raw_page(:'posting_index_name', :posting_incomplete_page)) AS page_stats
) AS page;

SELECT target_stats->>'flagsStr' NOT LIKE '%DELETED%'
       AND left_stats->>'flagsStr' LIKE '%INCOMPLETE_SPLIT%'
       AS preserved_posting_right_half
FROM (
    SELECT documentdb_api_internal.documentdb_rum_page_get_stats(
               public.get_raw_page(:'posting_index_name', :posting_right_half_page)) AS target_stats,
           documentdb_api_internal.documentdb_rum_page_get_stats(
               public.get_raw_page(
                   :'posting_index_name', :posting_right_half_left_page)) AS left_stats
) AS pages;

SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'posting_index_name'::regclass, :posting_incomplete_page, false);
SELECT rum_incomplete_split_page_deletion_test.set_incomplete_split(
    :'posting_index_name'::regclass, :posting_right_half_left_page, false);
RESET documentdb_rum.fix_incomplete_split;

RESET documentdb_rum.data_page_posting_tree_size;
RESET documentdb_rum.prune_rum_empty_pages;
RESET documentdb_rum.vacuum_skip_prune_posting_tree_pages;

SELECT documentdb_api.drop_collection(
    'rum_incomplete_split_deletion_db', 'entry_pages');
SELECT documentdb_api.drop_collection(
    'rum_incomplete_split_deletion_db', 'posting_pages');
DROP SCHEMA rum_incomplete_split_page_deletion_test CASCADE;
