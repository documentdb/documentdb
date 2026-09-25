-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

SET documentdb.next_collection_id TO 13400;
SET documentdb.next_collection_index_id TO 13400;

-- Composite (ordered) index planner: pushes equality prefixes and order-by
-- clauses down into ordered composite index scans.
set documentdb.enableCompositeIndexPlanner to on;
-- Track per-path multi-key state in the composite index opclass metadata so the
-- planner can tell which individual index paths are multi-key.
set documentdb.enableIndexMetadataGlobalTracking to on;
-- Independent multi-key paths are exercised here; parallel-array rejection is
-- covered by dedicated tests.
set documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking to off;

set documentdb.enableExtendedExplainPlans to on;
-- Suppress per-index cost details so explain output is stable across runs.
set documentdb.enableExplainScanIndexCosts to off;
-- The distinct order-by pushdown is a prerequisite for everything below.
set documentdb.enableDistinctIndexPushdown to on;
-- The skip scan is the payoff of the pushdown, so keep it on to observe it.
set documentdb.enableDistinctCustomScan to on;
-- Force index usage and reject bitmap scans so the ordered index-scan shape (and
-- any order-by pushdown) surfaces deterministically. A bitmap scan cannot carry
-- the index ordering, so it would force a Sort/HashAggregate regardless.
set enable_seqscan to off;
set enable_bitmapscan to off;


-- ============================================================================
-- The reported customer shape: a five-column composite ordered index
-- (a, b, c, d, e) where only "c" is an array path (multi-key) and the distinct
-- column "e" is scalar. The query pins a, b, c and d with equality bounds and
-- asks for the distinct values of e.
--
-- 400 documents collapse to 20 distinct values of "e", so without the pushdown
-- the plan must read every matching row and de-duplicate above the scan.
-- ============================================================================
SELECT COUNT(documentdb_api.insert_one('dmk_db', 'recs',
    FORMAT('{ "_id": %s, "a": "A", "b": "B", "c": [ "shared", "u%s" ], "d": "D", "e": %s }',
        i, (i % 7), (i % 20)
    )::documentdb_core.bson))
FROM generate_series(1, 400) i;

-- A handful of documents match the "c" equality through TWO array elements, so
-- the streamed scan emits them more than once. The distinct must still collapse
-- them to a single value.
SELECT documentdb_api.insert_one('dmk_db', 'recs', '{ "_id": 901, "a": "A", "b": "B", "c": [ "u5", "u5" ], "d": "D", "e": 67 }');
SELECT documentdb_api.insert_one('dmk_db', 'recs', '{ "_id": 902, "a": "A", "b": "B", "c": [ "u5", "u5" ], "d": "D", "e": 77 }');


-- Create the ordered index on the composite key (a, b, c, d, e) to enable the distinct multi-key sort pushdown.
SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "recs", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1, "d": 1, "e": 1 }, "name": "idx_abcde", "enableOrderedIndex": 1 } ] }',
    true);

ANALYZE;

-- ============================================================================
-- Reading the plans:
--   * Order-by pushed  => the index scan carries an "Order By:" line and is
--     wrapped in Custom Scan (DocumentDBApiDistinctQueryScan); no Sort.
--   * Order-by blocked => no "Order By:" line, no custom scan wrapper, and a
--     Sort/HashAggregate performs the de-duplication above the scan.
-- ============================================================================

-- Flag OFF (default): a distinct over a multi-key index blocks the order-by
-- pushdown outright, regardless of which column is actually multi-key.
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SET LOCAL documentdb.enable_group_by_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "c": "u5", "d": "D" } }')
$cmd$);
ROLLBACK;

-- Flag ON: per-path metadata proves "c" is the only multi-key column and that
-- the distinct column "e" is scalar, and a/b/c/d are all pure point bounds, so
-- the order-by streams out of the ordered index scan and the skip scan applies.
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SET LOCAL documentdb.enable_group_by_multi_key_sort_pushdown TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "c": "u5", "d": "D" } }')
$cmd$);
ROLLBACK;

-- The distinct flag must not enable group ordering, or be required for it.
BEGIN;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SET LOCAL documentdb.enable_group_by_multi_key_sort_pushdown TO off;
SELECT bool_or(line LIKE '%Order By:%') AS group_order_without_group_flag
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dmk_db', '{ "aggregate": "recs", "pipeline": [ { "$match": { "a": "A", "b": "B", "c": "u5", "d": "D" } }, { "$group": { "_id": "$e", "n": { "$sum": 1 } } } ], "hint": "idx_abcde", "cursor": {} }')
$cmd$) AS t(line);

SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SET LOCAL documentdb.enable_group_by_multi_key_sort_pushdown TO on;
SELECT bool_or(line LIKE '%Order By:%') AS group_order_with_group_flag
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dmk_db', '{ "aggregate": "recs", "pipeline": [ { "$match": { "a": "A", "b": "B", "c": "u5", "d": "D" } }, { "$group": { "_id": "$e", "n": { "$sum": 1 } } } ], "hint": "idx_abcde", "cursor": {} }')
$cmd$) AS t(line);
ROLLBACK;

-- Correctness: the distinct values are identical with the pushdown off and on.
-- The documents matching "c" through two array elements must contribute their
-- value exactly once.
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "c": "u5", "d": "D" } }');
ROLLBACK;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "c": "u5", "d": "D" } }');
ROLLBACK;

-- ============================================================================
-- Negative case: a non-equality (range) bound on the multi-key column "c".
-- A range on a multi-key column can match different array elements at different
-- points of the range, so the scanned range is no longer one contiguous run
-- ordered by "e" and the pushdown must be refused even with the flag on.
-- ============================================================================
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "c": { "$gte": "u5" }, "d": "D" } }')
$cmd$);
ROLLBACK;

-- ============================================================================
-- Negative case: the multi-key column "c" carries no bound at all. The query
-- pins a, b and d but leaves c unconstrained, so the scan would span every
-- array element of "c" and values of "e" would be interleaved across the
-- c-runs rather than forming one contiguous ordered run. The pushdown must not
-- appear. With no bound on "c" the composite index is not competitive either,
-- so the plan falls back to the _id_ scan; the assertion here is that no
-- ordered pushdown is produced and that the values stay correct.
-- ============================================================================
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "d": "D" } }')
$cmd$);
ROLLBACK;

-- Values for the unbounded-prefix case must match with the pushdown off and on.
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "d": "D" } }');
ROLLBACK;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "d": "D" } }');
ROLLBACK;

-- ============================================================================
-- Negative case: the distinct column is itself the multi-key column. One
-- document then yields several index tuples with different values for the
-- distinct path, so the streamed order (and the skip scan's assumption that
-- equal values are adjacent) would be unsound. Rejected even with the flag on.
-- ============================================================================
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "c", "query": { "a": "A", "b": "B" } }')
$cmd$);
ROLLBACK;

-- ============================================================================
-- Negative case: the per-path sort feature is disabled, even though the index
-- has per-path metadata.
-- ============================================================================
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SET LOCAL documentdb.enablePerPathMultiKeySortPushdown TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "c": "u5", "d": "D" } }')
$cmd$);
ROLLBACK;

-- ============================================================================
-- Multi-key transition: once an array lands in the distinct column "e" itself,
-- the per-path bitmask marks "e" multi-key and the pushdown must disappear.
-- ============================================================================
SELECT documentdb_api.insert_one('dmk_db', 'recs', '{ "_id": 999, "a": "A", "b": "B", "c": [ "shared" ], "d": "D", "e": [ 100, 200 ] }');
ANALYZE;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "recs", "key": "e", "query": { "a": "A", "b": "B", "c": "u5", "d": "D" } }')
$cmd$);
ROLLBACK;

SELECT documentdb_api.drop_collection('dmk_db', 'recs');

-- ============================================================================
-- A fully scalar index is unaffected by the new flag: the distinct order-by
-- pushdown never reached the multi-key gate, so the plan is the same either
-- way.
-- ============================================================================
SELECT COUNT(documentdb_api.insert_one('dmk_db', 'scalar_recs',
    FORMAT('{ "_id": %s, "a": "A", "e": %s }', i, (i % 20))::documentdb_core.bson))
FROM generate_series(1, 400) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "scalar_recs", "indexes": [ { "key": { "a": 1, "e": 1 }, "name": "idx_ae", "enableOrderedIndex": 1 } ] }',
    true);

ANALYZE;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "scalar_recs", "key": "e", "query": { "a": "A" } }')
$cmd$);
ROLLBACK;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "scalar_recs", "key": "e", "query": { "a": "A" } }')
$cmd$);
ROLLBACK;

SELECT documentdb_api.drop_collection('dmk_db', 'scalar_recs');

-- ============================================================================
-- Guard: an equality prefix that does not resolve to a single index term.
--
-- The prefix rule requires each column ahead of the sort column to be pinned to
-- one index term, otherwise the scan makes one ordered run per prefix term and
-- values of the sort column repeat across runs. Being an equality is not
-- sufficient for that: two value shapes are equalities that span several terms.
--
--   "a": null   is served by the range (MinKey, null] so that undefined terms
--               (a missing field or an empty array) also match, so it spans the
--               undefined term and the null term.
--   "a": [1,2]  is served by two alternative bounds, the array as a whole and
--               its first element.
--
-- In both cases the sort column "e" is only ordered within a run, so pushing
-- the order-by down would let the de-duplication above the scan miss values
-- that are not adjacent. The order-by must not be pushed down.
-- ============================================================================
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 1, "a": null, "e": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 2, "e": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 3, "a": null, "e": 2 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 4, "e": 2 }');
-- Makes "a" a multi-key path without matching either query below.
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 5, "a": [ 7, 8 ], "e": 9 }');
-- Matches "a": [1,2] both as the whole array and through its first element.
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 6, "a": [ 1, 2 ], "e": 3 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 7, "a": [ [ 1, 2 ], 9 ], "e": 3 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 8, "a": [ 1, 2 ], "e": 4 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_recs', '{ "_id": 9, "a": [ [ 1, 2 ], 9 ], "e": 4 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "point_recs", "indexes": [ { "key": { "a": 1, "e": 1 }, "name": "idx_point_ae", "enableOrderedIndex": 1 } ] }',
    true);

ANALYZE;

-- Plan shape: null equality on a multi-key prefix must not push the order-by down.
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_recs", "key": "e", "query": { "a": null } }')
$cmd$);
ROLLBACK;

-- Values: both arms must return exactly the two distinct values of "e".
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_recs", "key": "e", "query": { "a": null } }');
ROLLBACK;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_recs", "key": "e", "query": { "a": null } }');
ROLLBACK;

-- Plan shape: array equality on a multi-key prefix must not push the order-by down.
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_recs", "key": "e", "query": { "a": [ 1, 2 ] } }')
$cmd$);
ROLLBACK;

-- Values: both arms must return exactly the two distinct values of "e".
BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_recs", "key": "e", "query": { "a": [ 1, 2 ] } }');
ROLLBACK;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_recs", "key": "e", "query": { "a": [ 1, 2 ] } }');
ROLLBACK;

SELECT documentdb_api.drop_collection('dmk_db', 'point_recs');


-- ============================================================================
-- The same guard on a scalar (non multi-key) prefix. The multi-key relaxation
-- is not involved here at all: (MinKey, null] spans the undefined term and the
-- null term on any index, so the order-by must stay off the scan even with the
-- multi-key pushdown disabled.
-- ============================================================================
SELECT documentdb_api.insert_one('dmk_db', 'point_scalar_recs', '{ "_id": 1, "a": null, "e": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_scalar_recs', '{ "_id": 2, "e": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_scalar_recs', '{ "_id": 3, "a": null, "e": 2 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_scalar_recs', '{ "_id": 4, "e": 2 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "point_scalar_recs", "indexes": [ { "key": { "a": 1, "e": 1 }, "name": "idx_point_scalar_ae", "enableOrderedIndex": 1 } ] }',
    true);

ANALYZE;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_scalar_recs", "key": "e", "query": { "a": null } }')
$cmd$);
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "point_scalar_recs", "key": "e", "query": { "a": null } }');
ROLLBACK;

SELECT documentdb_api.drop_collection('dmk_db', 'point_scalar_recs');

-- A legacy index has no per-path metadata, even with both pushdown flags on.
SET documentdb.enableIndexMetadataGlobalTracking TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "legacy_recs", "indexes": [ { "key": { "a": 1, "e": 1 }, "name": "idx_legacy_ae", "enableOrderedIndex": 1 } ] }',
    true);
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SELECT documentdb_api.insert_one('dmk_db', 'legacy_recs', '{ "_id": 1, "a": [ "u5", "other" ], "e": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'legacy_recs', '{ "_id": 2, "a": [ "u5" ], "e": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'legacy_recs', '{ "_id": 3, "a": [ "u5", "another" ], "e": 2 }');
SELECT collection_id AS legacy_cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'dmk_db' AND collection_name = 'legacy_recs' \gset
ANALYZE documentdb_data.documents_:legacy_cid;
SELECT (pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking
    FROM pg_index idx
    JOIN pg_class cls ON cls.oid = idx.indexrelid
    WHERE idx.indrelid = ('documentdb_data.documents_' || :'legacy_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%'
    ORDER BY cls.relname;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SET LOCAL documentdb.enablePerPathMultiKeySortPushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "legacy_recs", "key": "e", "query": { "a": "u5" }, "hint": "idx_legacy_ae" }')
$cmd$);
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "legacy_recs", "key": "e", "query": { "a": "u5" }, "hint": "idx_legacy_ae" }');
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "legacy_recs", "key": "e", "query": { "a": "u5" }, "hint": "idx_legacy_ae" }');
ROLLBACK;
SELECT documentdb_api.drop_collection('dmk_db', 'legacy_recs');

-- Non-point equalities between sort keys also split the suffix into separate
-- ordered runs. The shared guard applies without the multikey distinct flag.
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 1, "a": 0, "b": null, "c": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 2, "a": 0, "c": 2 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 3, "a": 0, "b": null, "c": 3 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 4, "a": 0, "c": 4 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 5, "a": 0, "b": 1, "c": 4 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 6, "a": 0, "b": 1, "c": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 7, "a": 0, "c": 1 }');
SELECT documentdb_api.insert_one('dmk_db', 'point_gap_recs', '{ "_id": 8, "a": 0, "b": null, "c": 2 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "point_gap_recs", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "idx_gap_abc", "enableOrderedIndex": 1 } ] }',
    true);
SELECT collection_id AS gap_cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'dmk_db' AND collection_name = 'point_gap_recs' \gset
ANALYZE documentdb_data.documents_:gap_cid;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SET LOCAL enable_incremental_sort TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dmk_db', '{ "find": "point_gap_recs", "filter": { "b": null }, "sort": { "a": 1, "c": 1 }, "hint": "idx_gap_abc" }')
$cmd$);
WITH result AS (
    SELECT document FROM bson_aggregation_find('dmk_db', '{ "find": "point_gap_recs", "filter": { "b": null }, "sort": { "a": 1, "c": 1 }, "hint": "idx_gap_abc" }')
)
SELECT bson_dollar_project(document, '{ "_id": 0, "c": 1 }') FROM result;
SELECT document FROM bson_aggregation_pipeline('dmk_db',
    '{ "aggregate": "point_gap_recs", "pipeline": [
        { "$match": { "b": null } },
        { "$group": { "_id": { "a": "$a", "c": "$c" }, "n": { "$sum": 1 } } },
        { "$sort": { "_id.a": 1, "_id.c": 1 } }
    ], "hint": "idx_gap_abc", "cursor": {} }');

-- A genuine point equality in the same gap still permits both index sort keys.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dmk_db', '{ "find": "point_gap_recs", "filter": { "b": 1 }, "sort": { "a": 1, "c": 1 }, "hint": "idx_gap_abc" }')
$cmd$);
WITH result AS (
    SELECT document FROM bson_aggregation_find('dmk_db', '{ "find": "point_gap_recs", "filter": { "b": 1 }, "sort": { "a": 1, "c": 1 }, "hint": "idx_gap_abc" }')
)
SELECT bson_dollar_project(document, '{ "_id": 0, "c": 1 }') FROM result;
ROLLBACK;
SELECT documentdb_api.drop_collection('dmk_db', 'point_gap_recs');

-- Partial indexes remain outside multikey distinct pushdown's current scope.
SELECT COUNT(documentdb_api.insert_one('dmk_db', 'partial_recs',
    FORMAT('{ "_id": %s, "a": [ "selected", "other" ], "e": %s }',
        i, i % 3)::documentdb_core.bson))
FROM generate_series(1, 30) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "partial_recs", "indexes": [ { "key": { "a": 1, "e": 1 }, "name": "idx_partial_ae", "enableOrderedIndex": 1, "partialFilterExpression": { "a": "selected" } } ] }',
    true);
ANALYZE;

BEGIN;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT bool_or(line LIKE '%Order By:%') AS partial_distinct_order_pushed
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "partial_recs", "key": "e", "query": { "a": "selected" }, "hint": "idx_partial_ae" }')
$cmd$) AS t(line);
SELECT document FROM bson_aggregation_distinct('dmk_db',
    '{ "distinct": "partial_recs", "key": "e", "query": { "a": "selected" }, "hint": "idx_partial_ae" }');
ROLLBACK;
SELECT documentdb_api.drop_collection('dmk_db', 'partial_recs');

-- RCT bounds after a leading scalar target do not affect its ordering.
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api.insert_one('dmk_db', 'rct_recs',
    '{ "_id": 1, "k": "cafe", "accepted": false, "pairs": [ { "a": 1, "b": 1 } ] }');
SELECT documentdb_api.insert_one('dmk_db', 'rct_recs',
    '{ "_id": 2, "k": "cafe", "accepted": true, "pairs": [ { "a": 1, "b": 1 } ] }');
SELECT documentdb_api.insert_one('dmk_db', 'rct_recs',
    '{ "_id": 3, "k": "CAF\u00c9", "accepted": true, "pairs": [ { "a": 1, "b": 1 } ] }');
SELECT documentdb_api.insert_one('dmk_db', 'rct_recs',
    '{ "_id": 4, "k": "tea", "accepted": true, "pairs": [ { "a": 1, "b": 1 }, { "a": 2, "b": 2 } ] }');
SELECT documentdb_api.insert_one('dmk_db', 'rct_recs',
    '{ "_id": 5, "k": "TEA", "accepted": true, "pairs": [ { "a": 1, "b": 1 }, { "a": 1, "b": 1 } ] }');
SELECT documentdb_api.insert_one('dmk_db', 'rct_recs',
    '{ "_id": 6, "k": "not_selected", "accepted": true, "pairs": [ { "a": 1, "b": 2 }, { "a": 2, "b": 1 } ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('dmk_db',
    '{ "createIndexes": "rct_recs", "indexes": [
        { "key": { "k": 1, "pairs.a": 1, "pairs.b": 1 }, "name": "idx_rct_leading", "enableOrderedIndex": 1 },
        { "key": { "pairs.a": 1, "pairs.b": 1, "k": 1 }, "name": "idx_rct_trailing", "enableOrderedIndex": 1 },
        { "key": { "k": 1, "pairs.a": 1, "pairs.b": 1 }, "name": "idx_rct_leading_en", "enableOrderedIndex": 1, "collation": { "locale": "en", "strength": 1 } }
    ] }', true);
SELECT collection_id AS rct_cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'dmk_db' AND collection_name = 'rct_recs' \gset
ANALYZE documentdb_data.documents_:rct_cid;

BEGIN;
SET LOCAL documentdb.enable_composite_reduced_correlated_bounds_planning TO off;
SET LOCAL documentdb.enable_composite_secondary_path_order_pushdown TO on;
SET LOCAL documentdb.enable_group_by_multi_key_sort_pushdown TO off;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
WITH result AS (
    SELECT document FROM bson_aggregation_distinct('dmk_db',
        '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_leading" }')
)
SELECT bson_dollar_project(document,
    '{ "count": { "$size": "$values" }, "matches": { "$setEquals": [ "$values", [ "cafe", "CAF\u00c9", "tea", "TEA" ] ] } }')
FROM result;

SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT bool_or(line LIKE '%hasCorrelatedTerms: true%') AS has_correlated_terms,
       bool_or(line LIKE '%DocumentDBApiDistinctQueryScan%actual rows=4 loops=1%') AS leading_distinct_skips
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_leading" }')
$cmd$, p_ignore_heap_fetches => true) AS t(line);
WITH result AS (
    SELECT document FROM bson_aggregation_distinct('dmk_db',
        '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_leading" }')
)
SELECT bson_dollar_project(document,
    '{ "count": { "$size": "$values" }, "matches": { "$setEquals": [ "$values", [ "cafe", "CAF\u00c9", "tea", "TEA" ] ] } }')
FROM result;

-- Existing leading-key group ordering does not require RCT prefix planning.
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
SET LOCAL documentdb.enable_group_by_multi_key_sort_pushdown TO on;
SET LOCAL enable_hashagg TO off;
SELECT bool_or(line LIKE '%Order By:%') AS leading_group_order_pushed
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dmk_db', '{ "aggregate": "rct_recs", "pipeline": [ { "$match": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true } }, { "$group": { "_id": "$k", "n": { "$sum": 1 } } } ], "hint": "idx_rct_leading", "cursor": {} }')
$cmd$) AS t(line);
SELECT document FROM bson_aggregation_pipeline('dmk_db',
    '{ "aggregate": "rct_recs", "pipeline": [ { "$match": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true } }, { "$group": { "_id": "$k", "n": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "hint": "idx_rct_leading", "cursor": {} }');

-- A trailing target still needs the correlated prefix bounds to be proven.
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO on;
SELECT bool_or(line LIKE '%Order By:%') AS unplanned_trailing_order_pushed
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_trailing" }')
$cmd$) AS t(line);
SET LOCAL documentdb.enable_composite_reduced_correlated_bounds_planning TO on;
SELECT bool_or(line LIKE '%DocumentDBApiDistinctQueryScan%actual rows=4 loops=1%') AS planned_trailing_distinct_skips
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_trailing" }')
$cmd$, p_ignore_heap_fetches => true) AS t(line);

-- The new leading-key path also preserves collation equivalence classes.
SET LOCAL documentdb.enable_composite_reduced_correlated_bounds_planning TO off;
SELECT bool_or(line LIKE '%hasCorrelatedTerms: true%') AS has_correlated_terms,
       bool_or(line LIKE '%DocumentDBApiDistinctQueryScan%actual rows=2 loops=1%') AS collated_leading_distinct_skips
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_distinct('dmk_db', '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_leading_en", "collation": { "locale": "en", "strength": 1 } }')
$cmd$, p_ignore_heap_fetches => true) AS t(line);
WITH result AS (
    SELECT document FROM bson_aggregation_distinct('dmk_db',
        '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_leading_en", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT documentdb_api_internal.bson_dollar_project_catalog(document,
    '{ "count": { "$size": "$values" }, "matches": { "$setEquals": [ "$values", [ "cafe", "tea" ] ] } }',
    '{}', 'en-u-ks-level1')
FROM result;
SET LOCAL documentdb.enable_distinct_multi_key_sort_pushdown TO off;
WITH result AS (
    SELECT document FROM bson_aggregation_distinct('dmk_db',
        '{ "distinct": "rct_recs", "key": "k", "query": { "pairs": { "$elemMatch": { "a": 1, "b": 1 } }, "accepted": true }, "hint": "idx_rct_leading_en", "collation": { "locale": "en", "strength": 1 } }')
)
SELECT documentdb_api_internal.bson_dollar_project_catalog(document,
    '{ "count": { "$size": "$values" }, "matches": { "$setEquals": [ "$values", [ "cafe", "tea" ] ] } }',
    '{}', 'en-u-ks-level1')
FROM result;
ROLLBACK;
SELECT documentdb_api.drop_collection('dmk_db', 'rct_recs');
RESET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath;
RESET documentdb_core.enableCollation;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
