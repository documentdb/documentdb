-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

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
set enable_bitmapscan to off;

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

reset enable_bitmapscan;

-- An equality suffix is not monotonic after the timestamp range. Crossing a
-- page must not turn a nonmatching suffix into the end of the entire scan.
BEGIN;
SET LOCAL max_parallel_workers_per_gather TO 0;
SET LOCAL enable_bitmapscan TO off;

SELECT documentdb_api.create_collection('highkeydb', 'equality_range_suffix');
SELECT COUNT(documentdb_api.insert_one(
    'highkeydb',
    'equality_range_suffix',
    format(
        '{ "_id": %s, "store": { "$binary": { "base64": "AQIDBAUGBwgJCgsMDQ4PEA==", "subType": "03" } }, "timestamp": { "$date": { "$numberLong": "%s" } }, "type": %s, "kind": "%s" }',
        i, 1792123200000::bigint + i * 1000,
        CASE WHEN i % 3 = 0 THEN 10 ELSE 20 END,
        CASE WHEN i % 3 = 0 THEN 'SALE' ELSE 'void' END)::bson))
FROM generate_series(1, 900) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'highkeydb',
    '{ "createIndexes": "equality_range_suffix", "indexes": [
        { "key": { "store": 1, "timestamp": 1, "type": 1 },
          "name": "store_timestamp_type", "enableCompositeTerm": true }
    ] }'::bson,
    TRUE);

SET LOCAL documentdb.enable_high_key_optimization TO off;
CREATE TEMP TABLE high_key_range_suffix_off AS
SELECT document
FROM bson_aggregation_pipeline(
    'highkeydb',
    '{
        "aggregate": "equality_range_suffix",
        "pipeline": [
            { "$match": {
                "store": { "$binary": { "base64": "AQIDBAUGBwgJCgsMDQ4PEA==", "subType": "03" } },
                "timestamp": { "$gte": { "$date": "2026-10-16T04:00:00Z" } },
                "type": 10
            } },
            { "$group": { "_id": 1, "n": { "$sum": 1 } } }
        ],
        "cursor": {},
        "hint": "store_timestamp_type"
    }'::bson);

SET LOCAL documentdb.enable_high_key_optimization TO on;
CREATE TEMP TABLE high_key_range_suffix_on AS
SELECT document
FROM bson_aggregation_pipeline(
    'highkeydb',
    '{
        "aggregate": "equality_range_suffix",
        "pipeline": [
            { "$match": {
                "store": { "$binary": { "base64": "AQIDBAUGBwgJCgsMDQ4PEA==", "subType": "03" } },
                "timestamp": { "$gte": { "$date": "2026-10-16T04:00:00Z" } },
                "type": 10
            } },
            { "$group": { "_id": 1, "n": { "$sum": 1 } } }
        ],
        "cursor": {},
        "hint": "store_timestamp_type"
    }'::bson);

SELECT 'high_key_off' AS mode, document FROM high_key_range_suffix_off
UNION ALL
SELECT 'high_key_on' AS mode, document FROM high_key_range_suffix_on
ORDER BY mode;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_pipeline(
        'highkeydb',
        '{
            "aggregate": "equality_range_suffix",
            "pipeline": [
                { "$match": {
                    "store": { "$binary": { "base64": "AQIDBAUGBwgJCgsMDQ4PEA==", "subType": "03" } },
                    "timestamp": { "$gte": { "$date": "2026-10-16T04:00:00Z" } },
                    "type": 10
                } },
                { "$group": { "_id": 1, "n": { "$sum": 1 } } }
            ],
            "cursor": {},
            "hint": "store_timestamp_type"
        }'::bson)
$cmd$, p_ignore_group_key => true);

-- A backward scan must also continue past nonmatching suffix values.
SELECT '{
    "find": "equality_range_suffix",
    "filter": {
        "store": { "$binary": { "base64": "AQIDBAUGBwgJCgsMDQ4PEA==", "subType": "03" } },
        "timestamp": { "$gte": { "$date": "2026-10-16T04:00:00Z" } },
        "type": 20
    },
    "sort": { "timestamp": -1 },
    "hint": "store_timestamp_type"
}'::bson AS range_suffix_backward_command \gset
SET LOCAL documentdb.enable_high_key_optimization TO off;
CREATE TEMP TABLE high_key_range_suffix_backward_off AS
SELECT document FROM bson_aggregation_find('highkeydb', :'range_suffix_backward_command'::bson);
SET LOCAL documentdb.enable_high_key_optimization TO on;
CREATE TEMP TABLE high_key_range_suffix_backward_on AS
SELECT document FROM bson_aggregation_find('highkeydb', :'range_suffix_backward_command'::bson);
SELECT (SELECT count(*) FROM high_key_range_suffix_backward_off) AS backward_off,
       (SELECT count(*) FROM high_key_range_suffix_backward_on) AS backward_on;
SELECT bool_or(explain_line LIKE '%isBackwardScan: true%') AS uses_backward_scan,
       bool_or(explain_line ~ 'highKeyEligiblePages: [1-9][0-9]* pages') AS uses_high_key
FROM documentdb_test_helpers.run_explain_and_trim(format(
    'EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
     SELECT document FROM bson_aggregation_find(''highkeydb'', %L::bson)',
    :'range_suffix_backward_command')) explain_line;

-- Case-insensitive suffix equality must retain the same range-prefix state.
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'highkeydb',
    '{ "createIndexes": "equality_range_suffix", "indexes": [
        { "key": { "store": 1, "timestamp": 1, "kind": 1 },
          "name": "store_timestamp_kind", "enableCompositeTerm": true,
          "collation": { "locale": "en", "strength": 2 } }
    ] }'::bson,
    TRUE);
SELECT '{
    "aggregate": "equality_range_suffix",
    "pipeline": [
        { "$match": {
            "store": { "$binary": { "base64": "AQIDBAUGBwgJCgsMDQ4PEA==", "subType": "03" } },
            "timestamp": { "$gte": { "$date": "2026-10-16T04:00:00Z" } },
            "kind": "sale"
        } },
        { "$group": { "_id": 1, "n": { "$sum": 1 } } }
    ],
    "cursor": {},
    "hint": "store_timestamp_kind",
    "collation": { "locale": "en", "strength": 2 }
}'::bson AS range_suffix_collated_command \gset
SET LOCAL documentdb.enable_high_key_optimization TO off;
CREATE TEMP TABLE high_key_range_suffix_collated_off AS
SELECT document FROM bson_aggregation_pipeline('highkeydb', :'range_suffix_collated_command'::bson);
SET LOCAL documentdb.enable_high_key_optimization TO on;
CREATE TEMP TABLE high_key_range_suffix_collated_on AS
SELECT document FROM bson_aggregation_pipeline('highkeydb', :'range_suffix_collated_command'::bson);
SELECT 'collated_off' AS mode, document FROM high_key_range_suffix_collated_off
UNION ALL
SELECT 'collated_on' AS mode, document FROM high_key_range_suffix_collated_on
ORDER BY mode;
SELECT bool_or(explain_line ~ 'highKeyEligiblePages: [1-9][0-9]* pages') AS uses_high_key
FROM documentdb_test_helpers.run_explain_and_trim(format(
    'EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
     SELECT document FROM bson_aggregation_pipeline(''highkeydb'', %L::bson)',
    :'range_suffix_collated_command')) explain_line;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM (
            SELECT document FROM high_key_range_suffix_off
            UNION ALL
            SELECT document FROM high_key_range_suffix_on
            UNION ALL
            SELECT document FROM high_key_range_suffix_collated_off
            UNION ALL
            SELECT document FROM high_key_range_suffix_collated_on
        ) results
        WHERE document != '{ "_id": 1, "n": 300 }'::bson)
       OR (SELECT count(*) FROM high_key_range_suffix_off) != 1
       OR (SELECT count(*) FROM high_key_range_suffix_on) != 1
       OR (SELECT count(*) FROM high_key_range_suffix_collated_off) != 1
       OR (SELECT count(*) FROM high_key_range_suffix_collated_on) != 1 THEN
        RAISE EXCEPTION 'High-key on and off must both count all 300 matching documents';
    END IF;

    IF (SELECT count(*) FROM high_key_range_suffix_backward_off) != 600
       OR (SELECT count(*) FROM high_key_range_suffix_backward_on) != 600
       OR EXISTS (
           (SELECT document FROM high_key_range_suffix_backward_off
            EXCEPT ALL SELECT document FROM high_key_range_suffix_backward_on)
           UNION ALL
           (SELECT document FROM high_key_range_suffix_backward_on
            EXCEPT ALL SELECT document FROM high_key_range_suffix_backward_off)
       ) THEN
        RAISE EXCEPTION 'Backward high-key on and off must return the same 600 documents';
    END IF;
END;
$$;
ROLLBACK;

-- An $exists recheck on a path must not make later non-monotonic rechecks on
-- the same path (such as $mod) eligible for high-key page skipping.
SET max_parallel_workers_per_gather TO 0;
SET enable_bitmapscan TO off;

SELECT documentdb_api.create_collection('highkeydb', 'exists_mod_recheck');
SELECT COUNT(documentdb_api.insert_one(
    'highkeydb',
    'exists_mod_recheck',
    bson_build_document(
        '_id', i, 'p', (i - 1) / 2000, 'a', (i - 1) % 2000, 'b', (i * 37) % 11)))
FROM generate_series(1, 6000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'highkeydb',
    '{ "createIndexes": "exists_mod_recheck", "indexes": [
        { "key": { "p": 1, "a": -1, "b": 1 }, "name": "p_a_b", "enableCompositeTerm": true }
    ] }'::bson,
    TRUE);
SELECT format('VACUUM (FREEZE, ANALYZE) documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections
WHERE database_name = 'highkeydb' AND collection_name = 'exists_mod_recheck'
\gexec

SELECT '{
    "aggregate": "exists_mod_recheck",
    "pipeline": [
        { "$match": { "p": 1, "a": { "$exists": true, "$mod": [ 2, 0 ] } } },
        { "$group": { "_id": 1, "n": { "$sum": 1 } } }
    ],
    "cursor": {},
    "hint": "p_a_b"
}' AS exists_mod_command \gset

SET documentdb.enable_high_key_optimization TO off;
SELECT document
FROM bson_aggregation_pipeline('highkeydb', :'exists_mod_command'::bson);

SET documentdb.enable_high_key_optimization TO on;
SELECT document
FROM bson_aggregation_pipeline('highkeydb', :'exists_mod_command'::bson);
SELECT documentdb_test_helpers.run_explain_and_trim(format(
    'EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
     SELECT document FROM bson_aggregation_pipeline(''highkeydb'', %L::bson)',
    :'exists_mod_command'),
    p_ignore_heap_fetches => true, p_ignore_group_key => true);
RESET documentdb.enable_high_key_optimization;
RESET max_parallel_workers_per_gather;
RESET enable_bitmapscan;
SELECT documentdb_api.drop_collection('highkeydb', 'exists_mod_recheck');
