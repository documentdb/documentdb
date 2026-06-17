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

SET enable_bitmapscan TO off;
SET enable_seqscan TO off;

-- ============================================================
-- Baseline: Non-parallel count via the underlying table
-- Query the table directly with @<= to use the RUM ordered
-- scan path. VACUUM FREEZE enables Index Only Scan.
-- ============================================================
SET documentdb.enableCompositeParallelIndexScan TO off;

-- Non-parallel baseline count with $lte filter
SELECT FORMAT('SELECT count(*) FROM documentdb_data.documents_%s WHERE document @<= ''{ "createdAt": { "$date": "2019-12-31T00:00:00Z" } }''::documentdb_core.bson', :pord_col) \gexec

-- Non-parallel baseline full count
SELECT FORMAT('SELECT count(*) FROM documentdb_data.documents_%s WHERE document @<= ''{ "createdAt": { "$date": "2030-01-01T00:00:00Z" } }''::documentdb_core.bson', :pord_col) \gexec

-- ============================================================
-- Parallel ordered scan: count queries
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

-- Verify the plan uses Parallel Index Only Scan on the RUM index
SELECT documentdb_test_helpers.run_explain_and_trim(
    FORMAT('EXPLAIN (COSTS OFF) SELECT count(*) FROM documentdb_data.documents_%s WHERE document @<= ''{ "createdAt": { "$date": "2019-12-31T00:00:00Z" } }''::documentdb_core.bson', :'pord_col'));

-- Parallel count with $lte — must match non-parallel baseline (2500)
-- Previously this would crash with SEGV due to orderStack->off not being
-- reset after CopyPageContents in MoveBuffersForOrderedScanParallel.
SELECT FORMAT('SELECT count(*) FROM documentdb_data.documents_%s WHERE document @<= ''{ "createdAt": { "$date": "2019-12-31T00:00:00Z" } }''::documentdb_core.bson', :pord_col) \gexec

-- Parallel full count — must match non-parallel baseline (5000)
SELECT FORMAT('SELECT count(*) FROM documentdb_data.documents_%s WHERE document @<= ''{ "createdAt": { "$date": "2030-01-01T00:00:00Z" } }''::documentdb_core.bson', :pord_col) \gexec

-- ============================================================
-- Parallel ordered scan: range filter ($gt + $lt)
-- ============================================================
SELECT FORMAT('SELECT count(*) FROM documentdb_data.documents_%s WHERE document @> ''{ "createdAt": { "$date": "2017-01-01T00:00:00Z" } }''::documentdb_core.bson AND document @< ''{ "createdAt": { "$date": "2020-01-01T00:00:00Z" } }''::documentdb_core.bson', :pord_col) \gexec

-- Cleanup
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
RESET min_parallel_index_scan_size;
RESET min_parallel_table_scan_size;
RESET enable_seqscan;
RESET enable_bitmapscan;
RESET documentdb.enableCompositeParallelIndexScan;
RESET documentdb.forceParallelScanIfAvailable;

SELECT documentdb_api.drop_collection('pord_db', 'ordered_scan');
