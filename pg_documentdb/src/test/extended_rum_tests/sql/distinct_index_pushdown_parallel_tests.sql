-- Characterizes how distinct index pushdown (documentdb.enableDistinctIndexPushdown)
-- interacts with parallel composite index scans on the extended RUM access method.
--
-- Documented state (see per-part comments and the expected output):
--   * Part 1 - Serial: distinct on an indexed field pushes down to an Index Only
--     Scan whose order-by is driven by the index (no Sort, no heap access).
--   * Part 2 - Parallel + pushdown: distinct still pushes down under parallelism.
--     A Gather Merge over a Parallel Index Only Scan on the field index keeps the
--     order-by pushdown and feeds Unique - so no Sort and no heap access, just
--     parallelized. This requires enableAddShardKeyOnlyOnPrimaryKeyFilters so the
--     scan is not pinned by a shard_key_value predicate (which otherwise makes the
--     parallel plan invalid). Both a forced (2a) and a cost-chosen (2b) parallel
--     plan work; parts 2c/2d repeat those cases with the distinct custom scan
--     (enableDistinctCustomScan) also enabled.
--   * Part 3 - Parallel without pushdown: with the distinct index pushdown off the
--     order-by is NOT pushed to the field index; the plan falls back to a parallel
--     Seq Scan feeding a Sort + Unique.
--
-- Plans use EXPLAIN without ANALYZE so the shape is stable across PostgreSQL
-- versions (per-worker actual row counts differ by version).
SET search_path TO documentdb_api_catalog, documentdb_core, public;
-- enableDistinctCustomScan is enabled by default starting in v117. Pin it off
-- here so Parts 1, 2a and 2b keep exercising the non-custom-scan distinct plan
-- shape; Parts 2c/2d toggle it on explicitly with SET LOCAL. Remove this pin
-- when the flag is retired.
SET documentdb.enableDistinctCustomScan TO off;
SET documentdb.next_collection_id TO 24800;
SET documentdb.next_collection_index_id TO 24800;

-- Composite op class so the single-path index supports index-only and parallel
-- composite scans.
SET documentdb.defaultUseCompositeOpClass TO on;

SELECT documentdb_api.drop_collection('dist_par', 'dp');
SELECT documentdb_api.create_collection('dist_par', 'dp');

SELECT collection_id AS p_col FROM documentdb_api_catalog.collections
    WHERE database_name = 'dist_par' AND collection_name = 'dp' \gset

-- Disable autovacuum and request 2 parallel workers for predictable plans.
SELECT FORMAT('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off, parallel_workers = 2)', :p_col) \gexec

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dist_par',
    '{ "createIndexes": "dp", "indexes": [ { "key": { "a": 1 }, "name": "idx_a", "enableCompositeTerm": true } ] }', TRUE);

-- 3000 rows over 10 distinct "a" values so distinct collapses heavily and the
-- table is large enough for the planner to consider a parallel scan.
SELECT COUNT(documentdb_api.insert_one('dist_par', 'dp',
    FORMAT('{ "_id": %s, "a": %s, "pad": "%s" }', i, (i % 10) + 1, repeat('x', 200))::bson))
    FROM generate_series(1, 3000) AS i;

-- Deterministic planner statistics.
SELECT FORMAT('VACUUM FREEZE ANALYZE documentdb_data.documents_%s', :p_col) \gexec

SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableDistinctIndexPushdown TO on;
-- Only add the shard_key_value predicate for primary-key (_id) filters, so the
-- distinct scan on "a" is not forced to carry a shard_key_value qualifier.
SET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters TO on;

-- ==========================================================================
-- Part 1: serial distinct pushdown -> Index Only Scan with Order By pushdown.
-- ==========================================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL max_parallel_workers_per_gather TO 0;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_par',
  '{ "distinct": "dp", "key": "a" }')
$cmd$);
ROLLBACK;

-- ==========================================================================
-- Part 2: parallel + distinct index pushdown. distinct pushes down under a
-- parallel plan: a Gather Merge over a Parallel Index Only Scan on idx_a keeps
-- the Order By pushdown and feeds Unique. Both a forced and a cost-chosen
-- parallel plan produce this shape.
-- ==========================================================================
-- Part 2a: forced parallel.
BEGIN;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL documentdb.enableCompositeParallelIndexScan TO on;
SET LOCAL documentdb.forceParallelScanIfAvailable TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_par',
  '{ "distinct": "dp", "key": "a" }');
ROLLBACK;

-- Part 2b: planner-choice parallel (no force) - same pushed-down parallel plan.
BEGIN;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL documentdb.enableCompositeParallelIndexScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_par',
  '{ "distinct": "dp", "key": "a" }');
ROLLBACK;

-- Part 2c: forced parallel with the distinct custom scan also enabled.
BEGIN;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL documentdb.enableCompositeParallelIndexScan TO on;
SET LOCAL documentdb.forceParallelScanIfAvailable TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_par',
  '{ "distinct": "dp", "key": "a" }');
ROLLBACK;

-- Part 2d: planner-choice parallel with the distinct custom scan also enabled.
BEGIN;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL documentdb.enableCompositeParallelIndexScan TO on;
SET LOCAL documentdb.enableDistinctCustomScan TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_par',
  '{ "distinct": "dp", "key": "a" }');
ROLLBACK;

-- ==========================================================================
-- Part 3: with distinct pushdown OFF the order-by is not pushed to idx_a - the
-- parallel plan falls back to a Seq Scan feeding a Sort + Unique.
-- ==========================================================================
BEGIN;
SET LOCAL parallel_tuple_cost TO 0;
SET LOCAL parallel_setup_cost TO 0;
SET LOCAL min_parallel_index_scan_size TO 0;
SET LOCAL min_parallel_table_scan_size TO 0;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL max_parallel_workers_per_gather TO 2;
SET LOCAL documentdb.enableCompositeParallelIndexScan TO on;
SET LOCAL documentdb.forceParallelScanIfAvailable TO on;
SET LOCAL documentdb.enableDistinctIndexPushdown TO off;
SET LOCAL documentdb.enableExtendedExplainPlans TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('dist_par',
  '{ "distinct": "dp", "key": "a" }')
$cmd$);
ROLLBACK;

-- Correctness: distinct "a" values are exactly {1..10} regardless of the plan.
SELECT document
FROM bson_aggregation_distinct('dist_par',
  '{ "distinct": "dp", "key": "a" }') \gset

SELECT array_agg((value ->> '$numberInt')::int
                 ORDER BY (value ->> '$numberInt')::int) AS values
FROM jsonb_array_elements((:'document'::jsonb) -> 'values') value;

SELECT documentdb_api.drop_collection('dist_par', 'dp');
