SET search_path TO documentdb_api_catalog, documentdb_core, public;

SET documentdb.next_collection_id TO 9500;
SET documentdb.next_collection_index_id TO 9500;

-- This test reproduces a bug in the RUM btree where a non-atomic
-- INCOMPLETE_SPLIT flag clear causes duplicate downlinks in internal pages.
--
-- The bug occurs when:
-- 1. A leaf page splits, getting INCOMPLETE_SPLIT flag
-- 2. The parent page also needs to split while inserting the child's downlink
-- 3. The parent split commits (with both downlinks embedded)
-- 4. An error occurs BEFORE the child's INCOMPLETE_SPLIT flag is cleared
-- 5. A subsequent fix for the child re-inserts the right sibling's downlink,
--    creating a duplicate in the parent

CREATE SCHEMA rum_incomplete_split_test;

-- Helper to generate a ~1KB high-entropy string from an integer seed.
-- Uses md5 hashes to defeat RLE compression in the RUM entry tree,
-- ensuring internal page keys remain large.
CREATE OR REPLACE FUNCTION rum_incomplete_split_test.gen_key(seed int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT concat(
        md5(seed::text || '01'), md5(seed::text || '02'), md5(seed::text || '03'), md5(seed::text || '04'),
        md5(seed::text || '05'), md5(seed::text || '06'), md5(seed::text || '07'), md5(seed::text || '08'),
        md5(seed::text || '09'), md5(seed::text || '10'), md5(seed::text || '11'), md5(seed::text || '12'),
        md5(seed::text || '13'), md5(seed::text || '14'), md5(seed::text || '15'), md5(seed::text || '16'),
        md5(seed::text || '17'), md5(seed::text || '18'), md5(seed::text || '19'), md5(seed::text || '20'),
        md5(seed::text || '21'), md5(seed::text || '22'), md5(seed::text || '23'), md5(seed::text || '24'),
        md5(seed::text || '25'), md5(seed::text || '26'), md5(seed::text || '27'), md5(seed::text || '28'),
        md5(seed::text || '29'), md5(seed::text || '30'), md5(seed::text || '31'), md5(seed::text || '32'))
$$;

CREATE OR REPLACE FUNCTION rum_incomplete_split_test.documentdb_rum_page_get_stats(page bytea)
RETURNS jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_page_get_stats';

CREATE OR REPLACE FUNCTION rum_incomplete_split_test.documentdb_rum_get_meta_page_info(page bytea)
RETURNS jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_get_meta_page_info';

CREATE OR REPLACE FUNCTION rum_incomplete_split_test.documentdb_rum_page_get_entries(page bytea, indexOid Oid)
RETURNS SETOF jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_page_get_entries';

-- Create a collection with a compound key index.
-- Using a long string prefix ("c") with a varying integer suffix ("a")
-- produces large entry keys that fill internal pages quickly,
-- making parent splits during rumFinishSplit predictable.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rum_isplit_db',
    '{ "createIndexes": "isplit_test", "indexes": [ { "key": { "c": 1, "a": 1 }, "name": "ca_1" } ] }');

SELECT collection_id AS isplit_col FROM documentdb_api_catalog.collections
    WHERE database_name = 'rum_isplit_db' AND collection_name = 'isplit_test' \gset

SELECT index_id AS isplit_idx FROM documentdb_api_catalog.collection_indexes
    WHERE collection_id = :isplit_col AND index_id != :isplit_col \gset

-- Phase 1: Build up the index with many documents
-- Using high-entropy string values prevents RLE compression in the
-- RUM entry tree, keeping internal page entry keys large (~1KB each)
-- and limiting internal page capacity to ~7 entries.
-- This makes parent splits during rumFinishSplit predictable.
SELECT COUNT(documentdb_api.insert_one('rum_isplit_db', 'isplit_test',
    bson_build_document('_id', i, 'a', rum_incomplete_split_test.gen_key(i),
                        'c', repeat('x', 1024))))
FROM generate_series(1, 50000) AS i;

-- Phase 2: Inject split failures on internal pages only.
-- With injection on for internal-only splits and fix enabled (default),
-- an internal page split will:
--   1. Commit the split via GenericXLog (child INCOMPLETE_SPLIT cleared
--      atomically with the split in the fixed code path)
--   2. Fire an injected ERROR after GenericXLogFinish
-- The injected error is caught by insert_one internally.
-- With the fix, the child's INCOMPLETE_SPLIT is cleared in the same
-- GenericXLog record as the parent split, so rumFinishOldSplit will NOT
-- re-insert a downlink that already exists.
SET documentdb_rum.enable_inject_page_split_incomplete = on;
SET documentdb_rum.inject_split_entry_internal_only = on;

-- Insert enough docs to cause many internal page splits with injection
SELECT COUNT(documentdb_api.insert_one('rum_isplit_db', 'isplit_test',
    bson_build_document('_id', 60000 + i, 'a', rum_incomplete_split_test.gen_key(60000 + i),
                        'c', repeat('x', 1024))))
FROM generate_series(1, 10000) AS i;

RESET documentdb_rum.enable_inject_page_split_incomplete;
RESET documentdb_rum.inject_split_entry_internal_only;

-- Phase 3: Normal inserts to trigger rumFinishOldSplit on any remaining
-- INCOMPLETE_SPLIT pages left from the injected errors on parent pages.
SELECT COUNT(documentdb_api.insert_one('rum_isplit_db', 'isplit_test',
    bson_build_document('_id', 80000 + i, 'a', rum_incomplete_split_test.gen_key(80000 + i),
                        'c', repeat('x', 1024))))
FROM generate_series(1, 10000) AS i;

-- Phase 4: Verify no duplicate downlinks in internal pages.
-- With the atomic INCOMPLETE_SPLIT clear fix, the child's flag is cleared
-- in the same GenericXLog as the parent split, so rumFinishOldSplit does
-- not re-insert a downlink that already exists.
-- Suppress warnings from rum_page_get_entries on DATA pages
SET client_min_messages = error;

WITH internal_pages AS (
    SELECT i AS pageno FROM generate_series(1,
        (pg_relation_size(FORMAT('documentdb_data.documents_rum_index_%s', :isplit_idx)::regclass) / current_setting('block_size')::int)::int - 1) i
    WHERE (rum_incomplete_split_test.documentdb_rum_page_get_stats(
        public.get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :isplit_idx), i))
        ->>'flagsStr') NOT LIKE '%LEAF%'
    AND (rum_incomplete_split_test.documentdb_rum_page_get_stats(
        public.get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :isplit_idx), i))
        ->>'flagsStr') NOT LIKE '%DELETED%'
    AND (rum_incomplete_split_test.documentdb_rum_page_get_stats(
        public.get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :isplit_idx), i))
        ->>'flagsStr') NOT LIKE '%META%'
    AND (rum_incomplete_split_test.documentdb_rum_page_get_stats(
        public.get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :isplit_idx), i))
        ->>'flagsStr') NOT LIKE '%DATA%'
),
all_downlinks AS (
    SELECT ip.pageno,
           (regexp_match(e.entry->>'tupleTid', '^\((\d+),'))[1]::int AS downlink
    FROM internal_pages ip
    CROSS JOIN LATERAL rum_incomplete_split_test.documentdb_rum_page_get_entries(
        public.get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', :isplit_idx), ip.pageno),
        FORMAT('documentdb_data.documents_rum_index_%s', :isplit_idx)::regclass
    ) AS e(entry)
)
SELECT COUNT(*) > 0 AS has_duplicate_downlinks
FROM (
    SELECT downlink, count(*) as cnt
    FROM all_downlinks
    GROUP BY downlink
    HAVING count(*) > 1
) dups;

RESET client_min_messages;

-- Cleanup
SELECT documentdb_api.drop_collection('rum_isplit_db', 'isplit_test');
DROP SCHEMA rum_incomplete_split_test CASCADE;
