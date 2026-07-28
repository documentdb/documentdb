SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 22000;
SET documentdb.next_collection_index_id TO 22000;

-- The high key optimization applies to ordered (sorted) scans over a composite
-- index. When the ordered scan crosses from one index leaf page to the next and
-- the high key of the newly reached page already satisfies the scan condition,
-- the per-item comparisons on that page can be skipped. The extended explain
-- output reports the number of such pages via the "highKeyEligiblePages" field.

set documentdb.defaultUseCompositeOpClass to on;

-- Single-field composite index. Insert enough rows so the ordered scan crosses
-- many index leaf pages.
SELECT documentdb_api.create_collection('highkeydb', 'single_key');
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'single_key', bson_build_document('_id', i, 'a', i, 'b', i))) FROM generate_series(1, 5000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('highkeydb',
    '{ "createIndexes": "single_key", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }'::bson, TRUE);
SELECT collection_id AS single_key_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'highkeydb' AND collection_name = 'single_key' \gset

-- Compound composite index over two fields.
SELECT documentdb_api.create_collection('highkeydb', 'compound_key');
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'compound_key', bson_build_document('_id', i, 'a', i, 'b', i * 2))) FROM generate_series(1, 5000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('highkeydb',
    '{ "createIndexes": "compound_key", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1", "enableCompositeTerm": true } ] }'::bson, TRUE);

-- Compound data with a non-monotonic suffix. Most page endpoints satisfy
-- b > 50, while every seventh tuple does not.
SELECT documentdb_api.create_collection('highkeydb', 'page_isolated_suffix');
SELECT COUNT(documentdb_api.insert_one(
    'highkeydb',
    'page_isolated_suffix',
    bson_build_document(
        '_id', i,
        'a', i,
        'b', CASE WHEN i % 7 = 0 THEN 0 ELSE 100 END)))
FROM generate_series(1, 5000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'highkeydb',
    '{ "createIndexes": "page_isolated_suffix", "indexes": [
        { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1", "enableCompositeTerm": true }
    ] }'::bson,
    TRUE);
SELECT collection_id AS page_isolated_suffix_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'highkeydb' AND collection_name = 'page_isolated_suffix' \gset

set documentdb.enableExtendedExplainPlans to on;
set documentdb.enableExplainScanIndexCosts to off;
set documentdb.forceDisableSeqScan to on;

-- Baseline: with the optimization disabled the ordered scan still crosses every
-- page, but the highKeyEligiblePages counter is never emitted.
set documentdb.enable_high_key_optimization to off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$gte": 1 } }, "sort": { "a": 1 } }'::bson) $cmd$);

set documentdb.enable_high_key_optimization to on;

-- Forward ordered scan over the full index: every page after the first has a
-- high key that still satisfies "a >= 1", so all crossed pages are eligible.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$gte": 1 } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Backward ordered scan over the full index yields the same eligible page count.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$lte": 5000 } }, "sort": { "a": -1 } }'::bson) $cmd$);

-- Selective forward scan (only the tail of the index matches): fewer eligible
-- pages, matching the smaller number of leaf pages crossed.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$gte": 4000 } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Forward scan that terminates partway through the index ("a <= 2500"): only the
-- pages whose high key still satisfies the bound are eligible.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$lte": 2500 } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Bounded range on both sides.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$gt": 1000, "$lt": 2000 } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Equality match resolves to a regular (non-ordered) scan, so the optimization
-- does not apply and no highKeyEligiblePages counter is emitted.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$eq": 100 } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- No matching rows: the ordered scan finds no eligible page and the counter is
-- omitted (only reported when greater than zero).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$gt": 99999 } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Compound composite index: ordered scan on the leading field also reports the
-- eligible page count.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "compound_key", "filter": { "a": { "$gte": 1 } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Sanity check that the optimization does not change query results.
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$gte": 4000 } }, "sort": { "a": 1 } }'::bson)) sub;
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "single_key", "filter": { "a": { "$lte": 2500 } }, "sort": { "a": 1 } }'::bson)) sub;

-- ============================================================================
-- Parallel scans do not depend on predecessor-page state. After processing the
-- first few tuples on an isolated page, both page bounds must satisfy the scan
-- before the remaining per-item comparisons can use the high key result.
-- ============================================================================
SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (parallel_workers = 2)',
    :single_key_collection_id) \gexec
SELECT FORMAT(
    'VACUUM (FREEZE, ANALYZE) documentdb_data.documents_%s',
    :single_key_collection_id) \gexec

set documentdb.enableCompositeParallelIndexScan to off;
set documentdb.forceParallelScanIfAvailable to off;
set max_parallel_workers_per_gather to 0;

CREATE TEMP TABLE serial_parallel_high_key_results AS
SELECT document
FROM bson_aggregation_find(
    'highkeydb',
    '{ "find": "single_key", "filter": { "a": { "$gte": 1 } }, "sort": { "a": 1 } }'::bson);
ALTER TABLE serial_parallel_high_key_results
    ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

set documentdb.enableCompositeParallelIndexScan to on;
set documentdb.forceParallelScanIfAvailable to on;
set documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set min_parallel_index_scan_size to 0;
set min_parallel_table_scan_size to 0;
set parallel_setup_cost to 0;
set parallel_tuple_cost to 0;
set max_parallel_workers_per_gather to 2;
set parallel_leader_participation to on;

SELECT
    BOOL_OR(explain_line LIKE '%Workers Planned:%')
        AS uses_parallel_index_scan,
    BOOL_OR(explain_line ~ 'highKeyEligiblePages: [1-9][0-9]* pages')
        AS uses_page_isolated_high_key
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find(
        'highkeydb',
        '{ "find": "single_key", "filter": { "a": { "$gte": 1 } }, "sort": { "a": 1 } }'::bson)
$cmd$) AS explain_line;

CREATE TEMP TABLE parallel_high_key_results AS
SELECT document
FROM bson_aggregation_find(
    'highkeydb',
    '{ "find": "single_key", "filter": { "a": { "$gte": 1 } }, "sort": { "a": 1 } }'::bson);
ALTER TABLE parallel_high_key_results
    ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

SELECT COUNT(*) FROM parallel_high_key_results;
SELECT COUNT(*) FROM (
    SELECT result_order, document FROM serial_parallel_high_key_results
    EXCEPT
    SELECT result_order, document FROM parallel_high_key_results
) missing_or_misordered_results;
SELECT COUNT(*) FROM (
    SELECT result_order, document FROM parallel_high_key_results
    EXCEPT
    SELECT result_order, document FROM serial_parallel_high_key_results
) extra_or_misordered_results;

-- Page endpoints cannot prove suffix bounds after a non-equality leading path.
-- Verify the page-isolated operation does not skip the b > 50 comparison.
SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (parallel_workers = 2)',
    :page_isolated_suffix_collection_id) \gexec
SELECT FORMAT(
    'VACUUM (FREEZE, ANALYZE) documentdb_data.documents_%s',
    :page_isolated_suffix_collection_id) \gexec

set documentdb.enableCompositeParallelIndexScan to off;
set documentdb.forceParallelScanIfAvailable to off;
set max_parallel_workers_per_gather to 0;

CREATE TEMP TABLE serial_page_isolated_suffix_results AS
SELECT document
FROM bson_aggregation_find(
    'highkeydb',
    '{ "find": "page_isolated_suffix",
       "filter": { "a": { "$gte": 1, "$lte": 5000 }, "b": { "$gt": 50 } },
       "sort": { "a": 1 } }'::bson);
ALTER TABLE serial_page_isolated_suffix_results
    ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

set documentdb.enableCompositeParallelIndexScan to on;
set documentdb.forceParallelScanIfAvailable to on;
set max_parallel_workers_per_gather to 2;

SELECT
    BOOL_OR(explain_line LIKE '%Workers Planned:%')
        AS uses_parallel_index_scan,
    BOOL_OR(explain_line ~ 'highKeyEligiblePages: [1-9][0-9]* pages')
        AS uses_page_isolated_high_key
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find(
        'highkeydb',
        '{ "find": "page_isolated_suffix",
           "filter": { "a": { "$gte": 1, "$lte": 5000 }, "b": { "$gt": 50 } },
           "sort": { "a": 1 } }'::bson)
$cmd$) AS explain_line;

CREATE TEMP TABLE parallel_page_isolated_suffix_results AS
SELECT document
FROM bson_aggregation_find(
    'highkeydb',
    '{ "find": "page_isolated_suffix",
       "filter": { "a": { "$gte": 1, "$lte": 5000 }, "b": { "$gt": 50 } },
       "sort": { "a": 1 } }'::bson);
ALTER TABLE parallel_page_isolated_suffix_results
    ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

SELECT COUNT(*) FROM parallel_page_isolated_suffix_results;
SELECT COUNT(*) FROM (
    SELECT result_order, document FROM serial_page_isolated_suffix_results
    EXCEPT
    SELECT result_order, document FROM parallel_page_isolated_suffix_results
) missing_or_misordered_results;
SELECT COUNT(*) FROM (
    SELECT result_order, document FROM parallel_page_isolated_suffix_results
    EXCEPT
    SELECT result_order, document FROM serial_page_isolated_suffix_results
) extra_or_misordered_results;

-- A scalar-array skip rewalk resets the inherited state. Verify that the
-- parallel reposition preserves the complete ordered result while later pages
-- remain free to establish new high key state from their own processed tuples.
set documentdb.max_non_ordered_term_scan_threshold to 1;

WITH raw_values AS (
    SELECT ARRAY[10] || ARRAY_AGG(i) AS a_values
    FROM generate_series(4001, 5000) AS i
)
SELECT bson_build_document(
    'find', 'single_key'::text,
    'filter', bson_build_document(
        'a', bson_build_document('$in', a_values)),
    'sort', bson_build_document('a', 1))::bson AS high_key_saop_query_spec
FROM raw_values \gset

set documentdb.enableCompositeParallelIndexScan to off;
set documentdb.forceParallelScanIfAvailable to off;
set max_parallel_workers_per_gather to 0;

CREATE TEMP TABLE serial_high_key_saop_results AS
SELECT document
FROM bson_aggregation_find(
    'highkeydb',
    :'high_key_saop_query_spec'::bson);
ALTER TABLE serial_high_key_saop_results
    ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

set documentdb.enableCompositeParallelIndexScan to on;
set documentdb.forceParallelScanIfAvailable to on;
set max_parallel_workers_per_gather to 2;

SELECT
    BOOL_OR(explain_line LIKE '%Workers Planned:%')
        AS uses_parallel_index_scan
FROM documentdb_test_helpers.run_explain_and_trim(
    FORMAT(
        'EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) ' ||
        'SELECT document FROM bson_aggregation_find(%L, %L::bson)',
        'highkeydb',
        :'high_key_saop_query_spec')) AS explain_line;

CREATE TEMP TABLE parallel_high_key_saop_results AS
SELECT document
FROM bson_aggregation_find(
    'highkeydb',
    :'high_key_saop_query_spec'::bson);
ALTER TABLE parallel_high_key_saop_results
    ADD COLUMN result_order bigint GENERATED ALWAYS AS IDENTITY;

SELECT COUNT(*) FROM parallel_high_key_saop_results;
SELECT COUNT(*) FROM (
    SELECT result_order, document FROM serial_high_key_saop_results
    EXCEPT
    SELECT result_order, document FROM parallel_high_key_saop_results
) missing_or_misordered_results;
SELECT COUNT(*) FROM (
    SELECT result_order, document FROM parallel_high_key_saop_results
    EXCEPT
    SELECT result_order, document FROM serial_high_key_saop_results
) extra_or_misordered_results;

reset documentdb.max_non_ordered_term_scan_threshold;
reset documentdb.enableCompositeParallelIndexScan;
reset documentdb.forceParallelScanIfAvailable;
reset documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters;
reset min_parallel_index_scan_size;
reset min_parallel_table_scan_size;
reset parallel_setup_cost;
reset parallel_tuple_cost;
reset max_parallel_workers_per_gather;
reset parallel_leader_participation;

-- ============================================================================
-- Index recheck predicates disable the high key optimization.
--
-- When a bound carries an index recheck function (predicates such as
-- $bitsAllClear, $bitsAllSet or $mod that cannot be fully satisfied from the
-- index term alone and must recheck the heap tuple), the high key of the next
-- page cannot be trusted to transitively satisfy the scan condition, so the
-- skip check is not applied and highKeyEligiblePages is never reported even
-- though the scan is still ordered.
-- ============================================================================

SELECT documentdb_api.create_collection('highkeydb', 'recheck_key');
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'recheck_key', bson_build_document('_id', i, 'n', i))) FROM generate_series(1, 5000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('highkeydb',
    '{ "createIndexes": "recheck_key", "indexes": [ { "key": { "n": 1 }, "name": "n_1", "enableCompositeTerm": true } ] }'::bson, TRUE);

-- Control: a plain range on the field is eligible for the optimization and
-- reports the eligible pages that the ordered scan crosses.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$gte": 1 } }, "sort": { "n": 1 } }'::bson) $cmd$);

-- $bitsAllClear adds an index recheck function on the same bound: the scan stays
-- ordered but highKeyEligiblePages is not reported.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$gte": 1, "$bitsAllClear": 1 } }, "sort": { "n": 1 } }'::bson) $cmd$);

-- $bitsAllSet is another recheck predicate: still no highKeyEligiblePages.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$gte": 1, "$bitsAllSet": 1 } }, "sort": { "n": 1 } }'::bson) $cmd$);

-- $mod is another recheck predicate: still no highKeyEligiblePages.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$gte": 1, "$mod": [ 2, 0 ] } }, "sort": { "n": 1 } }'::bson) $cmd$);

-- The recheck predicates still return the correct rows.
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$gte": 1, "$bitsAllClear": 1 } }, "sort": { "n": 1 } }'::bson)) sub;
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$gte": 1, "$bitsAllSet": 1 } }, "sort": { "n": 1 } }'::bson)) sub;
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$gte": 1, "$mod": [ 2, 0 ] } }, "sort": { "n": 1 } }'::bson)) sub;

-- The recheck predicate is still ignored for the optimization on a backward
-- ordered scan.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "recheck_key", "filter": { "n": { "$lte": 5000, "$bitsAllClear": 1 } }, "sort": { "n": -1 } }'::bson) $cmd$);

-- ============================================================================
-- $exists high key optimization only covers the portion of the index that
-- sorts strictly greater than NULL.
--
-- For an $exists predicate the high key of a crossed page can only be trusted
-- when both the low key and the high key of that page sort strictly greater
-- than NULL. Pages whose bounds sort at or below NULL (explicit null, MinKey or
-- a missing field) are never eligible.
-- ============================================================================

-- All values are real numbers (which sort above NULL), so an ordered $exists
-- scan behaves like a plain range: every crossed page is eligible.
SELECT documentdb_api.create_collection('highkeydb', 'exists_key');
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'exists_key', bson_build_document('_id', i, 'a', i))) FROM generate_series(1, 5000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('highkeydb',
    '{ "createIndexes": "exists_key", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }'::bson, TRUE);

-- Forward $exists ordered scan over an all-non-null collection: the eligible
-- pages match the full page crossing count.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "exists_key", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Backward $exists ordered scan yields the same eligible page count.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "exists_key", "filter": { "a": { "$exists": true } }, "sort": { "a": -1 } }'::bson) $cmd$);

-- Mixed collection: a leading block of documents store an explicit null or a
-- MinKey for "a" (sorting at or below NULL) and the remainder store real
-- values. Only the pages that lie entirely above NULL are eligible, so the
-- forward count is strictly smaller than the all-non-null collection above.
SELECT documentdb_api.create_collection('highkeydb', 'exists_mixed');
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'exists_mixed', ('{ "_id": ' || i || ', "a": null }')::bson)) FROM generate_series(1, 1000) i;
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'exists_mixed', ('{ "_id": ' || i || ', "a": { "$minKey": 1 } }')::bson)) FROM generate_series(1001, 2000) i;
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'exists_mixed', bson_build_document('_id', i, 'a', i))) FROM generate_series(2001, 5000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('highkeydb',
    '{ "createIndexes": "exists_mixed", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }'::bson, TRUE);

-- Forward: the null/MinKey pages at the head of the index are skipped, only the
-- trailing all-above-NULL pages are eligible.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "exists_mixed", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Backward: same subset is eligible; the null/MinKey tail (reached last) is not.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "exists_mixed", "filter": { "a": { "$exists": true } }, "sort": { "a": -1 } }'::bson) $cmd$);

-- $exists still returns every document (nulls and MinKeys included).
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "exists_mixed", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 } }'::bson)) sub;

-- ============================================================================
-- A collection whose leading indexed field is entirely at or below NULL never
-- sees the $exists high key optimization, even when the trailing fields span
-- many leaf pages.
--
-- The index is (a, b, c) with "a" fixed at MinKey (which sorts below NULL) for
-- every document while "b" and "c" take many distinct values so the ordered
-- scan crosses many leaf pages. Because the leading term is never above NULL,
-- no page is ever eligible and highKeyEligiblePages is omitted in either
-- direction.
-- ============================================================================

SELECT documentdb_api.create_collection('highkeydb', 'minkey_key');
SELECT COUNT(documentdb_api.insert_one('highkeydb', 'minkey_key', ('{ "_id": ' || i || ', "a": { "$minKey": 1 }, "b": ' || i || ', "c": ' || (i * 2) || ' }')::bson)) FROM generate_series(1, 5000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('highkeydb',
    '{ "createIndexes": "minkey_key", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_1_b_1_c_1", "enableCompositeTerm": true } ] }'::bson, TRUE);

-- Forward ordered scan: every leading term is MinKey (< NULL) so no page is
-- eligible although the scan crosses many pages of distinct b/c values.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "minkey_key", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 } }'::bson) $cmd$);

-- Backward ordered scan: same, no eligible pages.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "minkey_key", "filter": { "a": { "$exists": true } }, "sort": { "a": -1 } }'::bson) $cmd$);

-- All documents are still returned by $exists in both directions.
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "minkey_key", "filter": { "a": { "$exists": true } }, "sort": { "a": 1 } }'::bson)) sub;
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "minkey_key", "filter": { "a": { "$exists": true } }, "sort": { "a": -1 } }'::bson)) sub;

-- ============================================================================
-- Backward ordered scan over a compound composite index also reports the
-- eligible page count on the leading field (the forward case is covered above).
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('highkeydb', '{ "find": "compound_key", "filter": { "a": { "$lte": 5000 } }, "sort": { "a": -1 } }'::bson) $cmd$);
