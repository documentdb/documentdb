SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 2600;
SET documentdb.next_collection_index_id TO 2600;

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableExtendedIndexes TO on;

SELECT documentdb_api.create_collection('large_in_db', 'items');
SELECT documentdb_api.insert_one(
    'large_in_db', 'items', '{ "_id": 1, "a": 1, "b": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'large_in_db',
    '{ "createIndexes": "items", "indexes": [
        { "key": { "b": 1, "a": 1 }, "name": "b_1_a_1", "enableOrderedIndex": true },
        { "key": { "b": 1 }, "name": "b_1", "enableOrderedIndex": true },
        { "key": { "a": 1 }, "name": "a_1", "enableOrderedIndex": true }
    ] }',
    true);

SET documentdb.forceDisableSeqScan TO on;

WITH in_values AS
(
    SELECT string_agg(i::text, ',' ORDER BY i) AS values
    FROM generate_series(1, 50000) i
),
command_spec AS
(
    SELECT format(
        '{ "aggregate": "items", "pipeline": [
            { "$match": { "$and": [
                { "a": { "$in": [%1$s] } },
                { "b": { "$in": [%1$s] } }
            ] } }
        ], "cursor": { "batchSize": 1 } }',
        values)::documentdb_core.bson AS command_spec
    FROM in_values
)
SELECT first_page.cursorPage IS NOT NULL AS query_succeeded
FROM command_spec,
LATERAL aggregate_cursor_first_page(
    database => 'large_in_db',
    commandSpec => command_spec.command_spec,
    cursorId => 25001) first_page;

-- Reproduce an ordered index-scan query shape with dynamic cursors disabled. Most
-- score values are unique, while every hundredth document duplicates
-- the preceding value. Delete one document from each duplicate pair and retain
-- its index entry so the ordered scan also encounters dead items.
SET documentdb.enableDynamicCursors TO off;
SET documentdb.enableComparableTerms TO on;
SET documentdb.enable_high_key_optimization TO on;
SET documentdb_rum.enable_support_dead_index_items TO on;
SET documentdb.max_non_ordered_term_scan_threshold TO 1;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

SELECT documentdb_api.create_collection('large_in_db', 'records');
SELECT collection_id AS records_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'large_in_db' AND collection_name = 'records'
\gset

SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off)',
    :records_collection_id)
\gexec

SELECT COUNT(documentdb_api.insert_one(
    'large_in_db',
    'records',
    bson_build_document(
        '_id', i,
        'score', CASE WHEN i % 100 = 0 THEN i - 1 ELSE i END)))
FROM generate_series(1, 5000) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'large_in_db',
    '{ "createIndexes": "records",     "indexes": [
        {
            "key": { "score": 1 },
            "name": "score_1"
        }
    ] }',
    true);

WITH delete_ids AS
(
    SELECT string_agg(i::text, ',' ORDER BY i) AS ids
    FROM generate_series(100, 4000, 100) i
)
SELECT FORMAT(
    '{ "delete": "records", "deletes": [ { "q": { "_id": { "$in": [ %s ] } }, "limit": 0 } ] }',
    ids)::documentdb_core.bson AS delete_command
FROM delete_ids
\gset

SET documentdb.forceDisableSeqScan TO off;
SELECT documentdb_api.delete(
    'large_in_db',
    :'delete_command'::documentdb_core.bson);

CREATE TEMP TABLE individual_results(document documentdb_core.bson);
DO $$
DECLARE
    score_value int;
    query_spec documentdb_core.bson;
    individual_document documentdb_core.bson;
BEGIN
    FOR score_value IN 1..4000 LOOP
        query_spec := bson_build_document(
            'find', 'records'::text,
            'filter', bson_build_document('score', score_value),
            'hint', 'score_1'::text)::documentdb_core.bson;
        FOR individual_document IN EXECUTE
            'SELECT document FROM bson_aggregation_find($1, $2)'
            USING 'large_in_db', query_spec
        LOOP
            INSERT INTO individual_results VALUES (individual_document);
        END LOOP;
    END LOOP;
END;
$$;

SELECT FORMAT(
    'VACUUM (FREEZE ON, INDEX_CLEANUP OFF) documentdb_data.documents_%s',
    :records_collection_id)
\gexec
SET documentdb.forceDisableSeqScan TO on;

WITH lookup_values AS
(
    SELECT array_agg(score_value ORDER BY sort_key, occurrence) AS score_values
    FROM
    (
        SELECT i AS score_value, (i * 7919) % 4001 AS sort_key, 0 AS occurrence
        FROM generate_series(1, 4000) i
        UNION ALL
        SELECT i AS score_value, (i * 7919) % 4001 AS sort_key, 1 AS occurrence
        FROM generate_series(50, 4000, 50) i
    ) query_values
)
SELECT bson_build_document(
    'find', 'records'::text,
    'filter', bson_build_document(
        'score', bson_build_document('$in', score_values)),
    'hint', 'score_1'::text,
    'batchSize', 127)::documentdb_core.bson AS records_query
FROM lookup_values
\gset

PREPARE drain_find_query(bson, bson) AS
(
    WITH RECURSIVE cursor_pages(page_number, cursor_page, continuation) AS
    (
        SELECT 1, cursorPage, continuation
        FROM find_cursor_first_page(
            database => 'large_in_db',
            commandSpec => $1,
            cursorId => 534)
        UNION ALL
        SELECT cursor_pages.page_number + 1, get_more.cursorPage, get_more.continuation
        FROM cursor_pages,
        cursor_get_more(
            database => 'large_in_db',
            getMoreSpec => $2,
            continuationSpec => cursor_pages.continuation) get_more
        WHERE cursor_pages.continuation IS NOT NULL
    ),
    cursor_batches AS
    (
        SELECT
            page_number,
            COALESCE(
                (cursor_page::text::jsonb)->'cursor'->'firstBatch',
                (cursor_page::text::jsonb)->'cursor'->'nextBatch',
                '[]'::jsonb) AS batch
        FROM cursor_pages
    ),
    cursor_documents AS
    (
        SELECT value::text::bson AS document
        FROM cursor_batches,
        LATERAL jsonb_array_elements(batch)
    )
    SELECT
        (SELECT COUNT(*) FROM cursor_batches) AS page_count,
        (SELECT MIN(jsonb_array_length(batch)) FROM cursor_batches) AS min_batch_size,
        (SELECT MAX(jsonb_array_length(batch)) FROM cursor_batches) AS max_batch_size,
        (SELECT COUNT(*) FROM cursor_documents) AS cursor_result_count,
        (SELECT COUNT(*) FROM
            (
                SELECT document FROM individual_results
                EXCEPT ALL
                SELECT document FROM cursor_documents
            ) missing) AS missing_from_cursor,
        (SELECT COUNT(*) FROM
            (
                SELECT document FROM cursor_documents
                EXCEPT ALL
                SELECT document FROM individual_results
            ) extra) AS extra_in_cursor
);

EXECUTE drain_find_query(
    :'records_query'::documentdb_core.bson,
    '{ "getMore": { "$numberLong": "534" }, "collection": "records", "batchSize": 127 }'::documentdb_core.bson);

CREATE TEMP TABLE bulk_results AS
SELECT document
FROM bson_aggregation_find(
    'large_in_db',
    :'records_query'::documentdb_core.bson);

SELECT
    BOOL_OR(explain_line LIKE '%scanType: ordered%') AS uses_ordered_scan,
    BOOL_OR(explain_line LIKE '%innerScanLoops:%') AS uses_multiple_scan_ranges
FROM documentdb_test_helpers.run_explain_and_trim(
    FORMAT(
        'EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) '
        'SELECT document FROM bson_aggregation_find(%L, %L::documentdb_core.bson)',
        'large_in_db',
        :'records_query')) explain_line;

SELECT COUNT(*) AS bulk_result_count FROM bulk_results;
SELECT COUNT(*) AS individual_result_count FROM individual_results;
SELECT COUNT(*) AS missing_from_bulk
FROM
(
    SELECT document FROM individual_results
    EXCEPT ALL
    SELECT document FROM bulk_results
) missing;
SELECT COUNT(*) AS extra_in_bulk
FROM
(
    SELECT document FROM bulk_results
    EXCEPT ALL
    SELECT document FROM individual_results
) extra;

DEALLOCATE drain_find_query;

RESET documentdb.enableExtendedExplainPlans;
RESET documentdb.max_non_ordered_term_scan_threshold;
RESET documentdb_rum.enable_support_dead_index_items;
RESET documentdb.enable_high_key_optimization;
RESET documentdb.enableComparableTerms;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.forceDisableSeqScan;
RESET documentdb.enableExtendedIndexes;
RESET documentdb.enableCursorsOnAggregationQueryRewrite;
RESET documentdb.enableDynamicCursors;

SELECT documentdb_api.drop_collection('large_in_db', 'items');
SELECT documentdb_api.drop_collection('large_in_db', 'records');
