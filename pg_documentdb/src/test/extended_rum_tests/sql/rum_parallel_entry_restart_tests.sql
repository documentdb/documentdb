SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 2400;
SET documentdb.next_collection_index_id TO 2400;

SELECT documentdb_api.create_collection('parallel_entry_restart_db', 'items');

SELECT collection_id AS collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'parallel_entry_restart_db'
  AND collection_name = 'items' \gset

SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off, parallel_workers = 1)',
    :collection_id) \gexec

SELECT COUNT(documentdb_api.insert_one(
    'parallel_entry_restart_db',
    'items',
    FORMAT('{ "_id": %s, "a": %s }', i, i)::bson))
FROM generate_series(1, 10000) AS i;

SELECT COUNT(documentdb_api.insert_one(
    'parallel_entry_restart_db',
    'items',
    FORMAT('{ "_id": %s, "a": "v%s" }', i + 10000, LPAD(i::text, 5, '0'))::bson))
FROM generate_series(1, 5000) AS i;

SET documentdb_rum.rum_default_page_fill_factor TO 10;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_entry_restart_db',
    '{ "createIndexes": "items", "indexes": [
        { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true }
    ] }',
    true);

RESET documentdb_rum.rum_default_page_fill_factor;

SELECT (
    documentdb_api_internal.documentdb_rum_get_meta_page_info(
        public.get_raw_page('documentdb_data.documents_rum_index_2402', 0))->>'entryPages'
    )::int > 100 AS has_many_entry_pages;

SELECT FORMAT(
    'VACUUM (FREEZE, ANALYZE) documentdb_data.documents_%s',
    :collection_id) \gexec

CREATE SCHEMA parallel_entry_restart_test;
SELECT documentdb_api.create_collection('parallel_entry_restart_db', 'saop_runtime');
SELECT documentdb_api.create_collection('parallel_entry_restart_db', 'saop_index');

SELECT collection_id AS saop_runtime_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'parallel_entry_restart_db'
  AND collection_name = 'saop_runtime' \gset

SELECT collection_id AS saop_index_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'parallel_entry_restart_db'
  AND collection_name = 'saop_index' \gset

-- Use the compound-key data distribution from the ordered SAOP scan tests.
SELECT COUNT(documentdb_api.insert_one(
    'parallel_entry_restart_db',
    'saop_runtime',
    bson_build_document('_id', i, 'a', i * 2, 'b', i)))
FROM generate_series(1, 1000) AS i;

SELECT COUNT(documentdb_api.insert_one(
    'parallel_entry_restart_db',
    'saop_runtime',
    bson_build_document('_id', i + 1000, 'a', (i * 2) - 1, 'b', i * 3)))
FROM generate_series(1, 1000) AS i;

SELECT COUNT(documentdb_api.insert_one(
    'parallel_entry_restart_db',
    'saop_runtime',
    bson_build_document('_id', i, 'a', i, 'b', 3001 - i)))
FROM generate_series(2001, 3000) AS i;

SELECT COUNT(documentdb_api.insert_one(
    'parallel_entry_restart_db',
    'saop_runtime',
    bson_build_document('_id', i, 'a', 7001 - i, 'b', i)))
FROM generate_series(3001, 4000) AS i;

SELECT COUNT(documentdb_api.insert_one(
    'parallel_entry_restart_db',
    'saop_runtime',
    '{ "_id": 4001, "a": 1000, "b": 2000 }'))
FROM generate_series(1, 1);

SELECT FORMAT(
    'INSERT INTO documentdb_data.documents_%s ' ||
    'SELECT %s, object_id, document FROM documentdb_data.documents_%s',
    :saop_index_collection_id,
    :saop_index_collection_id,
    :saop_runtime_collection_id) \gexec

SET documentdb_rum.rum_default_page_fill_factor TO 10;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_entry_restart_db',
    '{ "createIndexes": "saop_index", "indexes": [
        { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" }
    ] }',
    true);

RESET documentdb_rum.rum_default_page_fill_factor;

SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s ' ||
    'SET (autovacuum_enabled = off, parallel_workers = 2)',
    :saop_index_collection_id) \gexec

SELECT FORMAT(
    'VACUUM (FREEZE, ANALYZE) documentdb_data.documents_%s',
    :saop_runtime_collection_id) \gexec

SELECT FORMAT(
    'VACUUM (FREEZE, ANALYZE) documentdb_data.documents_%s',
    :saop_index_collection_id) \gexec

CREATE FUNCTION parallel_entry_restart_test.validate_parallel_results(
    test_name text,
    query_spec bson,
    force_ordered boolean,
    compare_order boolean,
    leader_participates boolean)
RETURNS TABLE(test_case text, result_count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    runtime_query_spec bson;
    index_query_spec bson;
    explain_query text;
    uses_parallel_index_scan boolean;
    uses_ordered_scan boolean;
    runtime_sequence text;
    parallel_sequence text;
    missing_count bigint;
    extra_count bigint;
BEGIN
    SELECT bson_dollar_add_fields(
        query_spec, '{ "find": "saop_runtime" }')
    INTO runtime_query_spec;
    SELECT bson_dollar_add_fields(
        query_spec, '{ "find": "saop_index" }')
    INTO index_query_spec;

    PERFORM set_config('documentdb.forceDisableSeqScan', 'off', false);
    PERFORM set_config('documentdb.enableCompositeParallelIndexScan', 'off', false);
    PERFORM set_config('documentdb.forceParallelScanIfAvailable', 'off', false);
    PERFORM set_config('documentdb_rum.forcerumorderedindexscan', 'off', false);
    PERFORM set_config('max_parallel_workers_per_gather', '0', false);

    CREATE TEMP TABLE parallel_runtime_results AS
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db', runtime_query_spec);
    ALTER TABLE parallel_runtime_results
        ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

    PERFORM set_config('documentdb.forceDisableSeqScan', 'on', false);
    PERFORM set_config('documentdb.enableCompositeParallelIndexScan', 'on', false);
    PERFORM set_config('documentdb.forceParallelScanIfAvailable', 'on', false);
    PERFORM set_config(
        'documentdb_rum.forcerumorderedindexscan',
        CASE WHEN force_ordered THEN 'on' ELSE 'off' END,
        false);
    PERFORM set_config('max_parallel_workers_per_gather', '2', false);
    PERFORM set_config(
        'parallel_leader_participation',
        CASE WHEN leader_participates THEN 'on' ELSE 'off' END,
        false);

    explain_query := FORMAT(
        'EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) ' ||
        'SELECT document FROM documentdb_api_catalog.bson_aggregation_find(%L, %L::bson)',
        'parallel_entry_restart_db',
        index_query_spec::text);

    SELECT
        BOOL_OR(explain_line LIKE '%Parallel Index Scan using a_1_b_1%'),
        BOOL_OR(explain_line LIKE '%scanType: ordered%')
    INTO uses_parallel_index_scan, uses_ordered_scan
    FROM documentdb_test_helpers.run_explain_and_trim(
        explain_query) AS explain_line;

    IF NOT uses_parallel_index_scan OR NOT uses_ordered_scan THEN
        RAISE EXCEPTION
            'Expected a parallel ordered index scan for %',
            test_name;
    END IF;

    CREATE TEMP TABLE parallel_index_results AS
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db', index_query_spec);
    ALTER TABLE parallel_index_results
        ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

    IF compare_order THEN
        IF EXISTS (
            (SELECT result_order, document FROM parallel_runtime_results
             EXCEPT
             SELECT result_order, document FROM parallel_index_results)
            UNION ALL
            (SELECT result_order, document FROM parallel_index_results
             EXCEPT
             SELECT result_order, document FROM parallel_runtime_results)
        ) THEN
            SELECT STRING_AGG(document::text, ' -> ' ORDER BY result_order)
            INTO runtime_sequence
            FROM parallel_runtime_results;
            SELECT STRING_AGG(document::text, ' -> ' ORDER BY result_order)
            INTO parallel_sequence
            FROM parallel_index_results;
            SELECT COUNT(*) INTO missing_count FROM (
                SELECT document FROM parallel_runtime_results
                EXCEPT ALL
                SELECT document FROM parallel_index_results
            ) missing;
            SELECT COUNT(*) INTO extra_count FROM (
                SELECT document FROM parallel_index_results
                EXCEPT ALL
                SELECT document FROM parallel_runtime_results
            ) extra;

            RAISE WARNING
                'ORDER_DIAGNOSTIC % missing % extra %. Runtime: %. Parallel: %',
                test_name, missing_count, extra_count,
                runtime_sequence, parallel_sequence;
        END IF;
    ELSE
        IF EXISTS (
            (SELECT document FROM parallel_runtime_results
             EXCEPT
             SELECT document FROM parallel_index_results)
            UNION ALL
            (SELECT document FROM parallel_index_results
             EXCEPT
             SELECT document FROM parallel_runtime_results)
        ) THEN
            RAISE EXCEPTION
                'Parallel results differ from runtime results for %',
                test_name;
        END IF;
    END IF;

    IF (SELECT COUNT(*) FROM parallel_runtime_results) !=
       (SELECT COUNT(*) FROM parallel_index_results) THEN
        RAISE EXCEPTION
            'Parallel result count differs from runtime result count for %',
            test_name;
    END IF;

    RETURN QUERY
    SELECT test_name, COUNT(*)::bigint
    FROM parallel_index_results;

    DROP TABLE parallel_runtime_results;
    DROP TABLE parallel_index_results;
END;
$$;

SET documentdb_rum.forcerumorderedindexscan TO on;
SET documentdb.forceDisableSeqScan TO on;
SET enable_bitmapscan TO off;
SET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters TO on;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
SET min_parallel_index_scan_size TO 0;
SET min_parallel_table_scan_size TO 0;
SET documentdb.enableExtendedExplainPlans TO on;

-- A disjoint $not predicate creates multiple ordered scan entries. Advancing
-- to the second entry must finish the page already owned by the worker.
SET documentdb.enableCompositeParallelIndexScan TO off;
SET documentdb.forceParallelScanIfAvailable TO off;
SET max_parallel_workers_per_gather TO 0;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db',
        '{ "find": "items", "filter": { "a": { "$not": { "$gt": 9000 } } } }')
$cmd$);

CREATE TEMP TABLE serial_not_results AS
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'parallel_entry_restart_db',
    '{ "find": "items", "filter": { "a": { "$not": { "$gt": 9000 } } } }');

SELECT COUNT(*) FROM serial_not_results;

SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.forceParallelScanIfAvailable TO on;
SET max_parallel_workers_per_gather TO 1;

SELECT REGEXP_REPLACE(
    CASE
        WHEN explain_line ~ 'innerScanLoops: [0-9]+ loops'
             AND SUBSTRING(explain_line FROM 'innerScanLoops: ([0-9]+) loops')::int
                 BETWEEN 7000 AND 14100
        THEN REGEXP_REPLACE(
            explain_line,
            'innerScanLoops: [0-9]+ loops',
            'innerScanLoops: 7000-14100 loops')
        WHEN explain_line ~ 'parallelScanLoops: [0-9]+ loops'
             AND SUBSTRING(explain_line FROM 'parallelScanLoops: ([0-9]+) loops')::int
                 BETWEEN 7000 AND 14100
        THEN REGEXP_REPLACE(
            explain_line,
            'parallelScanLoops: [0-9]+ loops',
            'parallelScanLoops: 7000-14100 loops')
        ELSE explain_line
    END,
    'estimatedEntryCount: [0-9]+',
    'estimatedEntryCount: xxx',
    'g')
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
        EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
        SELECT document
        FROM documentdb_api_catalog.bson_aggregation_find(
            'parallel_entry_restart_db',
            '{ "find": "items", "filter": { "a": { "$not": { "$gt": 9000 } } } }')
    $cmd$) AS explain_line;

CREATE TEMP TABLE parallel_not_results AS
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'parallel_entry_restart_db',
    '{ "find": "items", "filter": { "a": { "$not": { "$gt": 9000 } } } }');

SELECT COUNT(*) FROM parallel_not_results;
SELECT COUNT(*) FROM (
    SELECT document FROM serial_not_results
    EXCEPT
    SELECT document FROM parallel_not_results
) missing_results;

-- Keep $in as multiple standard scan entries, then force the physical ordered
-- scan so advancing between entries exercises the same page-ownership path.
SET documentdb.enableCompositeParallelIndexScan TO off;
SET documentdb.forceParallelScanIfAvailable TO off;
SET max_parallel_workers_per_gather TO 0;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db',
        '{ "find": "items", "filter": { "a": { "$in": [10,20,100,1000,5000,9900] } } }')
$cmd$);

CREATE TEMP TABLE serial_standard_in_results AS
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'parallel_entry_restart_db',
    '{ "find": "items", "filter": { "a": { "$in": [10,20,100,1000,5000,9900] } } }');

SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.forceParallelScanIfAvailable TO on;
SET max_parallel_workers_per_gather TO 1;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db',
        '{ "find": "items", "filter": { "a": { "$in": [10,20,100,1000,5000,9900] } } }')
$cmd$);

CREATE TEMP TABLE parallel_standard_in_results AS
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'parallel_entry_restart_db',
    '{ "find": "items", "filter": { "a": { "$in": [10,20,100,1000,5000,9900] } } }');

SELECT COUNT(*) FROM serial_standard_in_results;
SELECT COUNT(*) FROM parallel_standard_in_results;
SELECT COUNT(*) FROM (
    SELECT document FROM serial_standard_in_results
    EXCEPT
    SELECT document FROM parallel_standard_in_results
) missing_results;

-- Scalar-array skip bounds reposition within an owned page and rewalk the
-- tree when the shared parallel scan frontier can safely skip whole pages.
RESET documentdb_rum.forcerumorderedindexscan;
SET documentdb.max_non_ordered_term_scan_threshold TO 1;

SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (parallel_workers = 2)',
    :collection_id) \gexec

SET documentdb.enableCompositeParallelIndexScan TO off;
SET documentdb.forceParallelScanIfAvailable TO off;
SET max_parallel_workers_per_gather TO 0;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db',
        '{ "find": "items", "filter": { "a": { "$in": [10,20,100,1000,5000,9900] } } }')
$cmd$);

SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.forceParallelScanIfAvailable TO on;
SET max_parallel_workers_per_gather TO 2;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db',
        '{ "find": "items", "filter": { "a": { "$in": [10,20,100,1000,5000,9900] } } }')
$cmd$);

-- Verify that both naturally ordered and force-ordered compound scans use the
-- parallel index path before comparing their complete result sets.
RESET documentdb_rum.forcerumorderedindexscan;
RESET documentdb.max_non_ordered_term_scan_threshold;
SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.forceParallelScanIfAvailable TO on;
SET max_parallel_workers_per_gather TO 2;
SET parallel_leader_participation TO on;

SELECT
    BOOL_OR(explain_line LIKE '%Parallel Index Scan using a_1_b_1%')
        AS uses_parallel_index_scan,
    BOOL_OR(explain_line LIKE '%scanType: ordered%')
        AS uses_ordered_scan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db',
        '{ "find": "saop_index",
           "filter": {
               "a": { "$in": [5,16,2005,3001] },
               "b": { "$in": [6,8,2005,2995,2996,4000] }
           },
           "sort": { "a": 1, "b": 1 } }')
$cmd$) AS explain_line;

SET documentdb_rum.forcerumorderedindexscan TO on;

SELECT
    BOOL_OR(explain_line LIKE '%Parallel Index Scan using a_1_b_1%')
        AS uses_parallel_index_scan,
    BOOL_OR(explain_line LIKE '%scanType: ordered%')
        AS uses_ordered_scan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document
    FROM documentdb_api_catalog.bson_aggregation_find(
        'parallel_entry_restart_db',
        '{ "find": "saop_index",
           "filter": {
               "a": { "$in": [10,20,100,200,500,1000] },
               "b": { "$in": [5,10,50,100,500] }
           } }')
$cmd$) AS explain_line;

-- Naturally ordered scans. Compare ordinal positions when the query requests
-- an index-compatible sort.
SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'regular_in_both_ascending',
    '{ "filter": {
           "a": { "$in": [5,16,2005,3001] },
           "b": { "$in": [6,8,2005,2995,2996,4000] }
       },
       "sort": { "a": 1, "b": 1 } }',
    false, true, true);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'regular_in_with_range',
    '{ "filter": {
           "a": { "$in": [10,100,500,2500] },
           "b": { "$gte": 5, "$lte": 500 }
       },
       "sort": { "a": 1 } }',
    false, true, false);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'regular_overlapping_values',
    '{ "filter": {
           "a": { "$in": [998,999,1000,1001,1002] },
           "b": { "$gte": 1, "$lte": 3000 }
       },
       "sort": { "a": 1, "b": 1 } }',
    false, true, true);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'regular_sparse_large_in',
    '{ "filter": {
           "a": { "$in": [1,50,100,200,500,1000,1500,2000,2500,3000,3500,4000] },
           "b": { "$gt": 0, "$lt": 2000 }
       },
       "sort": { "a": 1 } }',
    false, true, true);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'regular_empty',
    '{ "filter": {
           "a": { "$in": [5000,6000,7000] },
           "b": { "$in": [1,2,3] }
       },
       "sort": { "a": 1 } }',
    false, true, true);

-- Force-ordered scans without a requested sort. Compare complete result sets
-- while allowing parallel workers to return them in any order.
SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'forced_in_both',
    '{ "filter": {
           "a": { "$in": [10,20,100,200,500,1000] },
           "b": { "$in": [5,10,50,100,500] }
       } }',
    true, false, true);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'forced_not_range',
    '{ "filter": {
           "a": { "$in": [10,100,500,2000] },
           "b": { "$not": { "$gt": 100 } }
       } }',
    true, false, false);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'forced_nin',
    '{ "filter": {
           "a": { "$in": [10,20,30,40,50] },
           "b": { "$nin": [5,10,15] }
       } }',
    true, false, true);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'forced_and_range',
    '{ "filter": {
           "$and": [
               { "a": { "$in": [10,100,500,1000,2000] } },
               { "a": { "$gte": 100 } },
               { "b": { "$lt": 600 } }
           ]
       } }',
    true, false, false);

SELECT * FROM parallel_entry_restart_test.validate_parallel_results(
    'forced_contradictory',
    '{ "filter": {
           "a": { "$in": [5,16,2005,3001], "$gt": 5000 },
           "b": { "$in": [6,8] }
       } }',
    true, false, true);

RESET documentdb.max_non_ordered_term_scan_threshold;
RESET documentdb.forceDisableSeqScan;
RESET enable_bitmapscan;
RESET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_index_scan_size;
RESET min_parallel_table_scan_size;
RESET documentdb.enableExtendedExplainPlans;
RESET documentdb.enableCompositeParallelIndexScan;
RESET documentdb.forceParallelScanIfAvailable;
RESET max_parallel_workers_per_gather;
RESET parallel_leader_participation;

DROP SCHEMA parallel_entry_restart_test CASCADE;
SELECT documentdb_api.drop_database('parallel_entry_restart_db');
SELECT 1 AS done;
