-- Packed heap TID de-duplication keys. First a bitmap-level guard that adjacent
-- pages share Roaring containers, then end-to-end cross-page duplicate
-- suppression. The guard declares a test-only function in this file; it is not
-- part of the shipped SQL API.
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb.next_collection_id TO 25000000;
SET documentdb.next_collection_index_id TO 25000000;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.forceDisableSeqScan TO on;
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET enable_sort TO off;

\pset format unaligned

-- 50 pages x 10 TIDs. With packed keys they all fit in one container, at any
-- block size. A layout that reserves a 65536-key range per page, such as
-- block << 16 | offset, would use 50 containers.
CREATE OR REPLACE FUNCTION documentdb_test_helpers.tid_dedup_container_count(pages int, slots_per_page int)
RETURNS bigint
LANGUAGE C STRICT
AS '$libdir/pg_documentdb', 'test_tid_dedup_container_count';

SELECT documentdb_test_helpers.tid_dedup_container_count(50, 10) AS containers_for_50_pages;

SELECT documentdb_api.create_collection('packed_tid_db', 'cross_page_dedup');

DO $$
DECLARE
    batch_start int;
BEGIN
    FOR batch_start IN 1..8000 BY 1000 LOOP
        PERFORM documentdb_api.insert(
            'packed_tid_db',
            (SELECT jsonb_build_object(
                        'insert', 'cross_page_dedup',
                        'documents', jsonb_agg(jsonb_build_object(
                            '_id', i,
                            'a', ARRAY[1, 4],
                            'b', i,
                            'pad', (SELECT string_agg(md5(i::text || ':' || part::text), '')
                                    FROM generate_series(1, 32) AS part))))
                    ::text::documentdb_core.bson
             FROM generate_series(batch_start, batch_start + 999) AS i));
    END LOOP;
END
$$;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'packed_tid_db',
    '{ "createIndexes": "cross_page_dedup", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1", "enableOrderedIndex": 1 } ] }',
    true);

SELECT format('ANALYZE documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections
WHERE database_name = 'packed_tid_db'
  AND collection_name = 'cross_page_dedup' \gexec

SELECT pg_relation_size(format('documentdb_data.documents_%s', collection_id)::regclass) /
       current_setting('block_size')::int > 224 AS spans_tid_dedup_key_chunks
FROM documentdb_api_catalog.collections
WHERE database_name = 'packed_tid_db'
  AND collection_name = 'cross_page_dedup';

SELECT bool_or(line ~ 'DocumentDBApiTidDedup') AS has_tid_dedup,
       bool_or(line ~ 'Merge Append') AS has_merge_append,
       bool_or(line ~ 'Duplicate Rows Removed: 8000') AS removed_all_cross_child_duplicates
FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('packed_tid_db',
      '{ "find": "cross_page_dedup", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }')
$cmd$) AS line;

CREATE TEMP TABLE packed_tid_dedup_results AS
SELECT document
FROM bson_aggregation_find('packed_tid_db',
  '{ "find": "cross_page_dedup", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');

SELECT count(*) AS returned_rows,
       count(DISTINCT document->>'_id') AS distinct_rows
FROM packed_tid_dedup_results;
