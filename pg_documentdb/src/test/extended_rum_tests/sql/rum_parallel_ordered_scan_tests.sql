SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 20100;
SET documentdb.next_collection_index_id TO 20100;

-- Test: Parallel ordered index scan correctness
-- Validates that parallel scans on ordered RUM indexes return correct results.
-- Covers a fix for offset reset when switching pages in parallel scan path
-- (MoveBuffersForOrderedScanParallel) which previously caused crashes.

SELECT documentdb_api.drop_collection('pord_db', 'ordered_scan');
SELECT documentdb_api.create_collection('pord_db', 'ordered_scan');

SELECT collection_id AS pord_col FROM documentdb_api_catalog.collections
    WHERE database_name = 'pord_db' AND collection_name = 'ordered_scan' \gset

-- Disable autovacuum for predictability, enable parallel workers
SELECT FORMAT('ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off, parallel_workers = 2)', :pord_col) \gexec

-- Insert enough documents to span multiple index pages.
-- Use date values spread across a range so $lte filters return partial results.
-- Years cycle 2015-2024 (i % 10), so each year has 500 docs.
SELECT COUNT(documentdb_api.insert_one('pord_db', 'ordered_scan',
    FORMAT('{ "_id": %s, "createdAt": { "$date": "%s-01-01T00:00:00Z" }, "val": %s }',
        i,
        2015 + (i % 10),
        i)::bson))
FROM generate_series(1, 5000) AS i;

-- Create an ordered composite term index on createdAt
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'pord_db',
    '{ "createIndexes": "ordered_scan", "indexes": [
        { "key": { "createdAt": 1 }, "name": "createdAt_1", "enableCompositeTerm": true }
    ] }', TRUE);

-- VACUUM FREEZE marks all heap pages all-visible, enabling Index Only Scan
SELECT FORMAT('VACUUM FREEZE documentdb_data.documents_%s', :pord_col) \gexec

SET documentdb.forceDisableSeqScan TO on;
SET enable_bitmapscan TO off;
SET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters TO on;

-- ============================================================
-- Baseline: Non-parallel counts via the API
-- ============================================================
SET documentdb.enableCompositeParallelIndexScan TO off;

-- Non-parallel baseline count with $lte filter (years 2015-2019 = 2500)
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$lte": { "$date": "2019-12-31T00:00:00Z" } } } }');

-- Non-parallel baseline full count (all 5000)
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$lte": { "$date": "2030-01-01T00:00:00Z" } } } }');

-- ============================================================
-- Parallel ordered scan: count queries (forward walk)
-- This is the scenario that previously caused SEGV due to
-- orderStack->off not being reset after CopyPageContents
-- in MoveBuffersForOrderedScanParallel.
-- ============================================================
SET parallel_tuple_cost TO 0;
SET parallel_setup_cost TO 0;
SET min_parallel_index_scan_size TO 0;
SET min_parallel_table_scan_size TO 0;
SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.forceParallelScanIfAvailable TO on;
SET documentdb.enableExtendedExplainPlans TO on;

-- Verify the plan uses Index Scan on the RUM index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$lte": { "$date": "2019-12-31T00:00:00Z" } } }, "sort": { "createdAt": 1 } }');

-- Parallel count with $lte — must match non-parallel baseline (2500)
-- Previously this would crash with SEGV due to orderStack->off not being
-- reset after CopyPageContents in MoveBuffersForOrderedScanParallel.
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$lte": { "$date": "2019-12-31T00:00:00Z" } } } }');

-- Parallel full count — must match non-parallel baseline (5000)
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$lte": { "$date": "2030-01-01T00:00:00Z" } } } }');

-- ============================================================
-- Parallel ordered scan: range filter ($gt + $lt)
-- ============================================================
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$gt": { "$date": "2017-01-01T00:00:00Z" }, "$lt": { "$date": "2020-01-01T00:00:00Z" } } } }');

-- ============================================================
-- Parallel ordered scan: backward walk with $gte/$gt
-- The $gte operator triggers a backward direction scan through
-- the RUM index, exercising the backward page walk in parallel.
-- ============================================================

-- Verify backward walk plan uses Index Scan on RUM index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$gte": { "$date": "2020-01-01T00:00:00Z" } } }, "sort": { "createdAt": -1 } }');

-- Backward walk count with $gte (years 2020-2024 = 2500 rows)
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$gte": { "$date": "2020-01-01T00:00:00Z" } } } }');

-- Backward walk count with $gt (exclusive, years 2021-2024 = 2000 rows)
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$gt": { "$date": "2020-01-01T00:00:00Z" } } } }');

-- Backward walk full count (all 5000 rows)
SELECT documentdb_api.count_query('pord_db', '{ "count": "ordered_scan", "query": { "createdAt": { "$gte": { "$date": "2010-01-01T00:00:00Z" } } } }');

-- ============================================================
-- Parallel ordered scan: forward walk with sort ascending
-- bson_aggregation_find with sort exercises the parallel index
-- scan with full tuple retrieval in the forward direction.
-- ============================================================

-- Verify forward walk plan uses Index Scan on RUM index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$lte": { "$date": "2030-01-01T00:00:00Z" } } }, "sort": { "createdAt": 1 } }');

-- Forward sort: count all documents with createdAt ASC
WITH r1 AS (SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$lte": { "$date": "2030-01-01T00:00:00Z" } } }, "sort": { "createdAt": 1 } }'))
SELECT COUNT(*) FROM r1;

-- ============================================================
-- Parallel ordered scan: backward walk with sort descending
-- bson_aggregation_find with sort descending exercises the
-- parallel index scan with backward page walk.
-- ============================================================

-- Verify backward walk plan uses Index Scan on RUM index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$gte": { "$date": "2015-01-01T00:00:00Z" } } }, "sort": { "createdAt": -1 } }');

-- Backward sort: count all documents with createdAt DESC
WITH r1 AS (SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$gte": { "$date": "2015-01-01T00:00:00Z" } } }, "sort": { "createdAt": -1 } }'))
SELECT COUNT(*) FROM r1;

-- ============================================================
-- Parallel ordered scan: forward walk with filter + sort
-- Narrower filter to exercise partial scan with sort
-- ============================================================

-- Forward sort with range filter: createdAt between 2017 and 2020
WITH r1 AS (SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$gte": { "$date": "2017-01-01T00:00:00Z" }, "$lt": { "$date": "2020-01-01T00:00:00Z" } } }, "sort": { "createdAt": 1 } }'))
SELECT COUNT(*) FROM r1;

-- Backward sort with range filter: createdAt between 2017 and 2020
WITH r1 AS (SELECT document FROM bson_aggregation_find('pord_db',
    '{ "find": "ordered_scan", "filter": { "createdAt": { "$gte": { "$date": "2017-01-01T00:00:00Z" }, "$lt": { "$date": "2020-01-01T00:00:00Z" } } }, "sort": { "createdAt": -1 } }'))
SELECT COUNT(*) FROM r1;

-- ============================================================
-- Parallel ordered scan: distinct query
-- Exercises parallel index scan with distinct pushdown on the
-- createdAt field (10 distinct year values: 2015-2024).
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;

-- Verify distinct plan uses parallel scan on RUM index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt" }');

-- Distinct values: should return 10 distinct dates (one per year 2015-2024)
SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt" }');

-- Distinct with filter: only years 2017-2019 (3 distinct values)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt", "query": { "createdAt": { "$gte": { "$date": "2017-01-01T00:00:00Z" }, "$lt": { "$date": "2020-01-01T00:00:00Z" } } } }');

SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt", "query": { "createdAt": { "$gte": { "$date": "2017-01-01T00:00:00Z" }, "$lt": { "$date": "2020-01-01T00:00:00Z" } } } }');

RESET documentdb.enableDistinctIndexPushdown;

-- ============================================================
-- Parallel ordered scan: custom distinct scan
-- With enableDistinctCustomScan, the planner wraps the index scan
-- in a DocumentDBApiDistinctQueryScan node that skips duplicate
-- index entries, scanning only one row per distinct value.
-- ============================================================
SET documentdb.enableDistinctIndexPushdown TO on;
SET documentdb.enableDistinctCustomScan TO on;

-- Ensure stats are up to date for deterministic plans
SELECT FORMAT('ANALYZE documentdb_data.documents_%s', :pord_col) \gexec

-- Verify custom distinct plan with parallel scan
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt" }');

-- Custom distinct: should return 10 distinct dates (one per year 2015-2024)
SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt" }');

-- Custom distinct with filter: only years 2017-2019 (3 distinct values)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt", "query": { "createdAt": { "$gte": { "$date": "2017-01-01T00:00:00Z" }, "$lt": { "$date": "2020-01-01T00:00:00Z" } } } }');

SELECT document FROM bson_aggregation_distinct('pord_db',
    '{ "distinct": "ordered_scan", "key": "createdAt", "query": { "createdAt": { "$gte": { "$date": "2017-01-01T00:00:00Z" }, "$lt": { "$date": "2020-01-01T00:00:00Z" } } } }');

RESET documentdb.enableDistinctIndexPushdown;
RESET documentdb.enableDistinctCustomScan;

-- Cleanup
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
RESET min_parallel_index_scan_size;
RESET min_parallel_table_scan_size;
RESET documentdb.forceDisableSeqScan;
RESET enable_bitmapscan;
RESET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters;
RESET documentdb.enableCompositeParallelIndexScan;
RESET documentdb.forceParallelScanIfAvailable;

SELECT documentdb_api.drop_collection('pord_db', 'ordered_scan');
