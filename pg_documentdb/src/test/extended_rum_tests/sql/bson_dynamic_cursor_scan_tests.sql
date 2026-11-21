SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 9200;
SET documentdb.next_collection_index_id TO 9200;

-- Enable PK cursor scan (on by default) for dynamic streaming cursors
set documentdb.enableDynamicCursors TO on;

-- Insert 10 documents with _id in reverse insertion order so TID order differs from _id order
DO $$
DECLARE i int;
BEGIN
FOR i IN 1..10 LOOP
PERFORM documentdb_api.insert_one('dyncursordb', 'dyncursor_coll', FORMAT('{ "_id": %s, "sk": %s, "a": "%s" }', 10-i, mod(i, 3), repeat('Sample', 5))::documentdb_core.bson);
END LOOP;
END;
$$;

-- Prepare a drain query that recursively fetches all pages via find_cursor_first_page + cursor_get_more
PREPARE drain_find_query(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation FROM find_cursor_first_page(database => 'dyncursordb', commandSpec => $1, cursorId => 534)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation FROM cte, cursor_get_more(database => 'dyncursordb', getMoreSpec => $2, continuationSpec => cte.continuation) gm
            WHERE cte.continuation IS NOT NULL
    )
    SELECT * FROM cte);

-- Prepare a drain query returning only batch-length summaries
PREPARE drain_find_query_continuation(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation FROM find_cursor_first_page(database => 'dyncursordb', commandSpec => $1, cursorId => 534)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation FROM cte, cursor_get_more(database => 'dyncursordb', getMoreSpec => $2, continuationSpec => cte.continuation) gm
            WHERE cte.continuation IS NOT NULL
    )
    SELECT bson_dollar_project(cursorPage, '{"firstBatchLength": { "$size": { "$ifNull": ["$cursor.firstBatch", []]}}, "nextBatchLength": { "$size": { "$ifNull": ["$cursor.nextBatch", []]}}}'), continuation FROM cte);

-- ===========================================================================
-- Test 1: EXPLAIN first page - PK cursor scan wraps query under DocumentDBApiCursorScan
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "batchSize": 3 }');
$cmd$);

-- ===========================================================================
-- Test 2: EXPLAIN with _id range filter
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 3, "$lt": 8 }}, "batchSize": 1 }');
$cmd$);

-- ===========================================================================
-- Test 3: First page + getMore draining with batchSize=3
-- Verify correct _id ordering and batch sizes
-- ===========================================================================
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }') as cp, continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'dyncursordb', commandSpec => '{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "batchSize": 3 }', cursorId => 534);

SELECT cp FROM firstPageResponse;

-- Capture continuation for getMore
SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- getMore: fetch next batch of 3
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation FROM
    cursor_get_more(database => 'dyncursordb', getMoreSpec => '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 3 }', continuationSpec => :'r1_continuation');

-- ===========================================================================
-- Test 4: EXPLAIN the getMore - should show DocumentDBApiCursorScan with PK scan and continuation
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('dyncursordb',
    '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 3 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$);

-- ===========================================================================
-- Test 5: Full drain with batchSize=2 for first page, batchSize=1 for getMore
-- Verify all 10 rows returned in _id order
-- ===========================================================================
EXECUTE drain_find_query('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 1 }');

-- ===========================================================================
-- Test 6: Full drain with batchSize=2 - verify batch length per page
-- ===========================================================================
EXECUTE drain_find_query_continuation('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 2 }');

-- ===========================================================================
-- Test 7: Dynamic cursors with _id range filter - drain
-- ===========================================================================
EXECUTE drain_find_query('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 3, "$lt": 8 }}, "batchSize": 1 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 1 }');

-- ===========================================================================
-- Test 8: EXPLAIN for getMore with filter and continuation
-- ===========================================================================
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }') as cp, continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'dyncursordb', commandSpec => '{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 3, "$lt": 8 }}, "batchSize": 2 }', cursorId => 4294967294);

SELECT cp FROM firstPageResponse;

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('dyncursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "dyncursor_coll", "batchSize": 2 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$);

-- Drain remaining rows after the first page
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation FROM
    cursor_get_more(database => 'dyncursordb', getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "dyncursor_coll", "batchSize": 5 }', continuationSpec => :'r1_continuation');

-- ===========================================================================
-- Test 9: Dynamic cursors with non-_id field filter (sk=1)
-- ===========================================================================
EXECUTE drain_find_query('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "filter": { "sk": 1 }, "batchSize": 1 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 2 }');

-- ===========================================================================
-- Test 10: Verify PK cursor scan disabled shows different plan
-- When disabled, should not show DocumentDBApiCursorScan
-- ===========================================================================
SET documentdb.enablePrimaryKeyCursorScan TO off;

SET enable_indexscan TO off;
SET enable_bitmapscan TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "batchSize": 3 }');
$cmd$);

SET enable_indexscan TO on;
SET enable_bitmapscan TO on;

-- ===========================================================================
-- Test 11: Full drain with batchSize >= total rows - verify single-page drain
-- ===========================================================================
EXECUTE drain_find_query('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "batchSize": 20 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 20 }');

-- ===========================================================================
-- Test 12: EXPLAIN with enableCursorsOnAggregationQueryRewrite - verifies
-- the aggregation query rewrite path also uses DocumentDBApiCursorScan
-- ===========================================================================
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "batchSize": 3 }');
$cmd$);

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- Bitmap Index Scan tests with secondary RUM indexes
-- ===========================================================================

-- Create a secondary index on "sk" to enable bitmap heap scan plans
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_coll", "indexes": [ { "key": { "sk": 1 }, "name": "sk_1" } ] }',
    true
);

-- Create a secondary index on "a" for additional bitmap scan coverage
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_coll", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }',
    true
);

ANALYZE;

-- ===========================================================================
-- Test 13: EXPLAIN with secondary index filter - should show Bitmap Heap Scan
-- ===========================================================================
SET enable_indexscan TO off;
SET enable_seqscan TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_coll", "filter": { "sk": 1 }, "projection": { "_id": 1 }, "batchSize": 2 }');
$cmd$);

-- ===========================================================================
-- Test 13b: EXPLAIN with aggregation query rewrite + bitmap scan
-- Should show DocumentDBApiCursorScan wrapping Bitmap Heap Scan
-- ===========================================================================
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_coll", "filter": { "sk": 1 }, "projection": { "_id": 1 }, "batchSize": 2 }');
$cmd$);

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

SET enable_indexscan TO on;
SET enable_seqscan TO on;

-- ===========================================================================
-- Test 14: First page + getMore with bitmap heap scan on secondary index (sk=1)
-- sk=1 docs: _id 0, 3, 6, 9 (4 docs total)
-- ===========================================================================
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }') as cp, continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'dyncursordb', commandSpec => '{ "find": "dyncursor_coll", "filter": { "sk": 1 }, "projection": { "_id": 1 }, "batchSize": 2 }', cursorId => 534);

SELECT cp FROM firstPageResponse;

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- getMore: fetch remaining docs
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation IS NOT NULL as has_continuation FROM
    cursor_get_more(database => 'dyncursordb', getMoreSpec => '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 2 }', continuationSpec => :'r1_continuation');

-- ===========================================================================
-- Test 15: EXPLAIN getMore with bitmap heap scan continuation
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('dyncursordb',
    '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 2 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$);

-- ===========================================================================
-- Test 16: Full drain with bitmap heap scan (sk=2, batchSize=1)
-- sk=2 docs: _id 2, 5, 8 (3 docs total)
-- ===========================================================================
EXECUTE drain_find_query('{ "find": "dyncursor_coll", "filter": { "sk": 2 }, "projection": { "_id": 1 }, "batchSize": 1 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 1 }');

-- ===========================================================================
-- Test 17: Full drain with bitmap heap scan (sk=0, batchSize=2)
-- sk=0 docs: _id 1, 4, 7 (3 docs total)
-- ===========================================================================
EXECUTE drain_find_query_continuation('{ "find": "dyncursor_coll", "filter": { "sk": 0 }, "projection": { "_id": 1 }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 2 }');

-- ===========================================================================
-- Test 18: Bitmap scan with combined secondary index filter + _id range
-- sk=1 AND _id > 2 AND _id < 8 => _id 3, 6
-- ===========================================================================
EXECUTE drain_find_query('{ "find": "dyncursor_coll", "filter": { "sk": 1, "_id": { "$gt": 2, "$lt": 8 } }, "projection": { "_id": 1 }, "batchSize": 1 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 1 }');

-- ===========================================================================
-- Test 19: Bitmap scan with string field index - drain using "a" index
-- All 10 docs have a = "SampleSampleSampleSampleSample", so all 10 returned
-- ===========================================================================
EXECUTE drain_find_query_continuation('{ "find": "dyncursor_coll", "filter": { "a": "SampleSampleSampleSampleSample" }, "projection": { "_id": 1 }, "batchSize": 3 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 3 }');

-- ===========================================================================
-- Test 20: Bitmap scan with large batchSize - all sk=1 docs in single page
-- ===========================================================================
EXECUTE drain_find_query('{ "find": "dyncursor_coll", "filter": { "sk": 1 }, "projection": { "_id": 1 }, "batchSize": 20 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 20 }');

-- ===========================================================================
-- Bitmap AND / OR tests with dynamic cursors
-- Need a larger dataset where two independent fields each have moderate
-- selectivity so the planner chooses BitmapAnd (conjunction) and BitmapOr.
-- ===========================================================================

-- Insert 2000 docs with padding to create many heap pages.
-- x = mod(i, 10): 10 values, each matches 200 docs (10%)
-- y = mod(i, 7):   7 values, each matches ~286 docs (14%)
-- Coprime moduli (10, 7) ensure independent distributions via CRT.
-- x=5 AND y=3: i ≡ 45 (mod 70) => 28 docs (1.4%) — much more selective.
DO $$
DECLARE i int;
BEGIN
FOR i IN 0..1999 LOOP
PERFORM documentdb_api.insert_one('dyncursordb', 'dyncursor_bm_coll', FORMAT('{ "_id": %s, "x": %s, "y": %s, "pad": "%s" }', i, mod(i, 10), mod(i, 7), repeat('P', 200))::documentdb_core.bson);
END LOOP;
END;
$$;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_bm_coll", "indexes": [ { "key": { "x": 1 }, "name": "x_1" } ] }',
    true
);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_bm_coll", "indexes": [ { "key": { "y": 1 }, "name": "y_1" } ] }',
    true
);

ANALYZE;

-- Prepare drain helpers for the new collection
PREPARE drain_bm_query(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation FROM find_cursor_first_page(database => 'dyncursordb', commandSpec => $1, cursorId => 535)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation FROM cte, cursor_get_more(database => 'dyncursordb', getMoreSpec => $2, continuationSpec => cte.continuation) gm
            WHERE cte.continuation IS NOT NULL
    )
    SELECT bson_dollar_project(cursorPage, '{"firstBatchLength": { "$size": { "$ifNull": ["$cursor.firstBatch", []]}}, "nextBatchLength": { "$size": { "$ifNull": ["$cursor.nextBatch", []]}}}'), continuation IS NOT NULL as has_more, bson_dollar_project(continuation, '{ "dc.type": 1 }') as scan_type FROM cte);

SET enable_indexscan TO off;
SET enable_seqscan TO off;

-- ===========================================================================
-- Test 21: EXPLAIN bitmap AND - conjunction on x and y indexes
-- x=5 (200 docs) AND y=3 (286 docs) => 28 docs via BitmapAnd
-- Should show BitmapAnd with two Bitmap Index Scans
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_bm_coll", "filter": { "x": 5, "y": 3 }, "projection": { "_id": 1 }, "batchSize": 2 }');
$cmd$);

-- ===========================================================================
-- Test 22: Full drain bitmap AND - x=5 AND y=3, batchSize=5
-- Expected: 28 docs (i ≡ 45 mod 70, i in 0..1999), 6 batches (5+5+5+5+5+3)
-- ===========================================================================
EXECUTE drain_bm_query('{ "find": "dyncursor_bm_coll", "filter": { "x": 5, "y": 3 }, "projection": { "_id": 1 }, "batchSize": 5 }', '{ "getMore": { "$numberLong": "535" }, "collection": "dyncursor_bm_coll", "batchSize": 5 }');

-- ===========================================================================
-- Test 23: EXPLAIN bitmap AND with different values
-- x=3 AND y=1 => should also produce BitmapAnd
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_bm_coll", "filter": { "x": 3, "y": 1 }, "projection": { "_id": 1 }, "batchSize": 2 }');
$cmd$);

-- ===========================================================================
-- Test 24: Full drain bitmap AND - x=3 AND y=1, batchSize=3
-- Expected: 28 docs (i ≡ 43 mod 70, i in 0..1999), 10 batches (3×9+1)
-- ===========================================================================
EXECUTE drain_bm_query('{ "find": "dyncursor_bm_coll", "filter": { "x": 3, "y": 1 }, "projection": { "_id": 1 }, "batchSize": 3 }', '{ "getMore": { "$numberLong": "535" }, "collection": "dyncursor_bm_coll", "batchSize": 3 }');

-- ===========================================================================
-- Test 25: EXPLAIN bitmap OR across different indexes
-- $or: [{x:5}, {y:3}] => BitmapOr with x_1 and y_1 index scans
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_bm_coll", "filter": { "$or": [{ "x": 5 }, { "y": 3 }] }, "projection": { "_id": 1 }, "batchSize": 3 }');
$cmd$);

-- ===========================================================================
-- Test 26: Full drain bitmap OR across different indexes
-- $or: [{x:5}, {y:3}] => union of x=5 (200) and y=3 (286) minus overlap (28)
-- Expected: 458 docs, 46 batches (10×45+8)
-- ===========================================================================
EXECUTE drain_bm_query('{ "find": "dyncursor_bm_coll", "filter": { "$or": [{ "x": 5 }, { "y": 3 }] }, "projection": { "_id": 1 }, "batchSize": 10 }', '{ "getMore": { "$numberLong": "535" }, "collection": "dyncursor_bm_coll", "batchSize": 10 }');

-- ===========================================================================
-- Test 27: Bitmap OR with first page + getMore - verify continuation
-- $or: [{x:0}, {y:0}] with batchSize=3
-- ===========================================================================
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }') as cp, continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'dyncursordb', commandSpec => '{ "find": "dyncursor_bm_coll", "filter": { "$or": [{ "x": 0 }, { "y": 0 }] }, "projection": { "_id": 1 }, "batchSize": 3 }', cursorId => 535);

SELECT cp FROM firstPageResponse;

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- EXPLAIN the getMore for bitmap OR continuation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('dyncursordb',
    '{ "getMore": { "$numberLong": "535" }, "collection": "dyncursor_bm_coll", "batchSize": 3 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$);

-- getMore: fetch next batch
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation IS NOT NULL as has_continuation FROM
    cursor_get_more(database => 'dyncursordb', getMoreSpec => '{ "getMore": { "$numberLong": "535" }, "collection": "dyncursor_bm_coll", "batchSize": 3 }', continuationSpec => :'r1_continuation');

-- ===========================================================================
-- Test 28: Bitmap AND with first page + getMore - verify continuation
-- x=5 AND y=3 (~29 docs) with batchSize=3
-- ===========================================================================
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }') as cp, continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'dyncursordb', commandSpec => '{ "find": "dyncursor_bm_coll", "filter": { "x": 5, "y": 3 }, "projection": { "_id": 1 }, "batchSize": 3 }', cursorId => 535);

SELECT cp FROM firstPageResponse;

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- EXPLAIN the getMore for bitmap AND continuation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('dyncursordb',
    '{ "getMore": { "$numberLong": "535" }, "collection": "dyncursor_bm_coll", "batchSize": 3 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$);

-- getMore: fetch remaining
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation IS NOT NULL as has_continuation FROM
    cursor_get_more(database => 'dyncursordb', getMoreSpec => '{ "getMore": { "$numberLong": "535" }, "collection": "dyncursor_bm_coll", "batchSize": 10 }', continuationSpec => :'r1_continuation');

SET enable_indexscan TO on;
SET enable_seqscan TO on;

-- ===========================================================================
-- Test: EXPLAIN ANALYZE FORMAT JSON with dynamic cursors and aggregation
-- rewrite enabled. Validates that the output is valid JSON.
-- ===========================================================================
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- Validate that EXPLAIN ANALYZE FORMAT JSON output is valid JSON by casting to jsonb.
-- We avoid printing the raw output since explain plans are not stable across PG versions.
DO $$
DECLARE
    v_plan text;
    v_json jsonb;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF, FORMAT JSON)
        SELECT document FROM bson_aggregation_find(''dyncursordb'',
            ''{ "find": "dyncursor_coll", "filter": {}, "projection": { "_id": 1 }, "batchSize": 3 }'')'
    INTO v_plan;

    v_json := v_plan::jsonb;
    RAISE NOTICE 'EXPLAIN FORMAT JSON is valid JSON: true';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'EXPLAIN FORMAT JSON is valid JSON: false - %', SQLERRM;
END $$;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- Test: Aggregate cursor - verify aggregate_cursor_first_page uses dynamic cursors
-- ===========================================================================
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- Aggregate with $match only (streamable pipeline)
CREATE TEMP TABLE agg_cursor_test AS
SELECT cursorPage, continuation FROM aggregate_cursor_first_page(
    database => 'dyncursordb',
    commandSpec => '{ "aggregate": "dyncursor_coll", "pipeline": [ { "$match": { "sk": 1 } } ], "cursor": { "batchSize": 2 } }',
    cursorId => 540);

SELECT bson_dollar_project(cursorPage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }')
    FROM agg_cursor_test;

-- Check cursor type: qd = dynamic, qc = streaming
SELECT bson_dollar_project(continuation, '{ "qd": 1, "qc": 1 }') AS agg_cursor_type FROM agg_cursor_test;

-- Compare with equivalent find (should also be dynamic)
CREATE TEMP TABLE find_cursor_test AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursordb',
    commandSpec => '{ "find": "dyncursor_coll", "filter": { "sk": 1 }, "batchSize": 2 }',
    cursorId => 541);

SELECT bson_dollar_project(continuation, '{ "qd": 1, "qc": 1 }') AS find_cursor_type FROM find_cursor_test;

DROP TABLE agg_cursor_test;
DROP TABLE find_cursor_test;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- Restore defaults
SET documentdb.enablePrimaryKeyCursorScan TO off;

-- ===========================================================================
-- Nested BitmapOr(BitmapAnd, BitmapAnd, BitmapIndexScan) tests
-- Regression test for segv crash when dynamic cursor continuation writing
-- encounters nested bitmap And/Or nodes (e.g. $or[ $and[...], $and[...], ... ]).
-- The old code assumed all children of BitmapOr/BitmapAnd were BitmapIndexScanState,
-- but nested $and/$or produces BitmapOr(BitmapAnd, BitmapAnd, BitmapIndexScan).
-- ===========================================================================

SET documentdb.enablePrimaryKeyCursorScan TO on;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO on;

-- Insert 2000 docs with 3 independent fields for separate indexes.
-- a = mod(i, 10): 10 values, each matches 200 docs
-- b = mod(i, 7):   7 values, each matches ~286 docs
-- c = mod(i, 13): 13 values, each matches ~154 docs
DO $$
DECLARE i int;
BEGIN
FOR i IN 0..1999 LOOP
PERFORM documentdb_api.insert_one('dyncursordb', 'dyncursor_nested_bm', FORMAT('{ "_id": %s, "a": %s, "b": %s, "c": %s, "pad": "%s" }', i, mod(i, 10), mod(i, 7), mod(i, 13), repeat('N', 200))::documentdb_core.bson);
END LOOP;
END;
$$;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_nested_bm", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }',
    true
);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_nested_bm", "indexes": [ { "key": { "b": 1 }, "name": "b_1" } ] }',
    true
);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_nested_bm", "indexes": [ { "key": { "c": 1 }, "name": "c_1" } ] }',
    true
);

ANALYZE;

-- Prepare drain helper for nested bitmap collection
PREPARE drain_nested_bm_query(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation FROM find_cursor_first_page(database => 'dyncursordb', commandSpec => $1, cursorId => 536)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation FROM cte, cursor_get_more(database => 'dyncursordb', getMoreSpec => $2, continuationSpec => cte.continuation) gm
            WHERE cte.continuation IS NOT NULL
    )
    SELECT bson_dollar_project(cursorPage, '{"firstBatchLength": { "$size": { "$ifNull": ["$cursor.firstBatch", []]}}, "nextBatchLength": { "$size": { "$ifNull": ["$cursor.nextBatch", []]}}}'), continuation IS NOT NULL as has_more, bson_dollar_project(continuation, '{ "dc.type": 1 }') as scan_type FROM cte);

SET enable_indexscan TO off;
SET enable_seqscan TO off;

-- ===========================================================================
-- Test 30: EXPLAIN nested bitmap - $or[ $and[a, b], $and[a, b], c ]
-- Should produce BitmapOr(BitmapAnd(a_1, b_1), BitmapAnd(a_1, b_1), BitmapIndexScan(c_1))
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_nested_bm", "filter": { "$or": [{ "$and": [{ "a": 1 }, { "b": 2 }] }, { "$and": [{ "a": 3 }, { "b": 4 }] }, { "c": 5 }] }, "projection": { "_id": 1 }, "batchSize": 3 }');
$cmd$);

-- ===========================================================================
-- Test 31: Full drain nested bitmap OR(AND, AND, IndexScan)
-- $or[ {a:1, b:2}, {a:3, b:4}, {c:5} ] with dynamic cursors and batchSize=5
-- This is the exact pattern that triggered the segv before the fix:
-- the continuation writer must recurse into nested BitmapAnd nodes inside
-- the BitmapOr, rather than assuming all children are BitmapIndexScanState.
-- ===========================================================================
EXECUTE drain_nested_bm_query('{ "find": "dyncursor_nested_bm", "filter": { "$or": [{ "$and": [{ "a": 1 }, { "b": 2 }] }, { "$and": [{ "a": 3 }, { "b": 4 }] }, { "c": 5 }] }, "projection": { "_id": 1 }, "batchSize": 5 }', '{ "getMore": { "$numberLong": "536" }, "collection": "dyncursor_nested_bm", "batchSize": 5 }');

-- ===========================================================================
-- Test 32: Drain nested bitmap with smaller batch to exercise more continuation writes
-- ===========================================================================
EXECUTE drain_nested_bm_query('{ "find": "dyncursor_nested_bm", "filter": { "$or": [{ "$and": [{ "a": 1 }, { "b": 2 }] }, { "$and": [{ "a": 3 }, { "b": 4 }] }, { "c": 5 }] }, "projection": { "_id": 1 }, "batchSize": 3 }', '{ "getMore": { "$numberLong": "536" }, "collection": "dyncursor_nested_bm", "batchSize": 3 }');

-- ===========================================================================
-- Test 33: Nested $or of $and with $or - triple nesting
-- $or[ $and[a:1, b:2], $or[{a:5}, {b:6}], c:9 ]
-- Produces BitmapOr(BitmapAnd, BitmapOr, BitmapIndexScan) - all 3 node types
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_nested_bm", "filter": { "$or": [{ "$and": [{ "a": 1 }, { "b": 2 }] }, { "$or": [{ "a": 5 }, { "b": 6 }] }, { "c": 9 }] }, "projection": { "_id": 1 }, "batchSize": 3 }');
$cmd$);

EXECUTE drain_nested_bm_query('{ "find": "dyncursor_nested_bm", "filter": { "$or": [{ "$and": [{ "a": 1 }, { "b": 2 }] }, { "$or": [{ "a": 5 }, { "b": 6 }] }, { "c": 9 }] }, "projection": { "_id": 1 }, "batchSize": 5 }', '{ "getMore": { "$numberLong": "536" }, "collection": "dyncursor_nested_bm", "batchSize": 5 }');

SET enable_indexscan TO on;
SET enable_seqscan TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO off;
SET documentdb.enablePrimaryKeyCursorScan TO off;
SET documentdb.enableDynamicCursors TO off;

-- ===========================================================================
-- Simple index filter with planner statistics, no ANALYZE
-- Regression test for the scenario where on an unsharded collection, with
-- planner statistics enabled and no ANALYZE run, a simple filter like
-- { "a": "b" } with an index on "a" is executed via dynamic cursors.
-- The shard_key_value BitmapAnd optimization strips the shard_key child,
-- producing a single Bitmap Index Scan. This validates that the cursor
-- drain completes correctly even with planner statistics on a new collection.
-- ===========================================================================

SET documentdb.enablePrimaryKeyCursorScan TO on;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO on;

-- Insert a few docs - do NOT run ANALYZE
SELECT documentdb_api.insert_one('dyncursordb', 'dyncursor_shard_bm', '{ "a": "b", "pad": "x" }');
SELECT documentdb_api.insert_one('dyncursordb', 'dyncursor_shard_bm', '{ "a": "c", "pad": "y" }');
SELECT documentdb_api.insert_one('dyncursordb', 'dyncursor_shard_bm', '{ "a": "b", "pad": "z" }');

-- Disable autovacuum to prevent auto-analyze from adding planner stats
SELECT collection_id AS shard_bm_col FROM documentdb_api_catalog.collections
    WHERE database_name = 'dyncursordb' AND collection_name = 'dyncursor_shard_bm' \gset
SELECT FORMAT('ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off)', :shard_bm_col) \gexec

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursordb',
    '{ "createIndexes": "dyncursor_shard_bm", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }',
    true
);

-- Force bitmap scan path
SET enable_indexscan TO off;
SET enable_seqscan TO off;
SET seq_page_cost TO 9999999;

-- ===========================================================================
-- Test 34: Simple filter with bitmap scan, planner stats, no ANALYZE
-- ===========================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb', '{ "find": "dyncursor_shard_bm", "filter": { "a": "b" }, "batchSize": 2 }');
$cmd$);

-- ===========================================================================
-- Test 35: Drain cursor with simple filter, planner stats, no ANALYZE
-- ===========================================================================
PREPARE drain_shard_bm_query(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation FROM find_cursor_first_page(database => 'dyncursordb', commandSpec => $1, cursorId => 537)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation FROM cte, cursor_get_more(database => 'dyncursordb', getMoreSpec => $2, continuationSpec => cte.continuation) gm
            WHERE cte.continuation IS NOT NULL
    )
    SELECT bson_dollar_project(cursorPage, '{"firstBatchLength": { "$size": { "$ifNull": ["$cursor.firstBatch", []]}}, "nextBatchLength": { "$size": { "$ifNull": ["$cursor.nextBatch", []]}}}'), continuation IS NOT NULL as has_more, bson_dollar_project(continuation, '{ "dc.type": 1 }') as scan_type FROM cte);

EXECUTE drain_shard_bm_query('{ "find": "dyncursor_shard_bm", "filter": { "a": "b" }, "batchSize": 1 }', '{ "getMore": { "$numberLong": "537" }, "collection": "dyncursor_shard_bm", "batchSize": 1 }');

SET seq_page_cost TO DEFAULT;
SET enable_indexscan TO on;
SET enable_seqscan TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO off;
SET documentdb.enablePrimaryKeyCursorScan TO off;
SET documentdb.enableDynamicCursors TO off;

-- ===========================================================================
-- Test 36: Index hint on getMore across cursor configurations.
-- The bson_dollar_index_hint marker is a planner-only marker and must be
-- replaced by the planner. If it survives onto the streaming getMore
-- continuation scan it reaches execution and raises
-- "bson_dollar_index_hint function should be replaced by the planner".
-- ===========================================================================
SET documentdb.enableDynamicCursors TO off;
SET documentdb.enablePrimaryKeyCursorScan TO on;

-- EXPLAIN the getMore under primary key cursor scan. bson_dollar_index_hint
-- must not survive as a runtime Filter.
DROP TABLE IF EXISTS firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT continuation FROM
    find_cursor_first_page(database => 'dyncursordb', commandSpec => '{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "hint": { "$natural": 1 }, "batchSize": 3 }', cursorId => 534);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('dyncursordb',
    '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 3 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$);

-- Primary key cursor scan ON: the hint marker is trimmed from the primary-key
-- cursor scan, so the drain succeeds.
EXECUTE drain_find_query_continuation('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "hint": { "$natural": 1 }, "batchSize": 3 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 3 }');

-- Primary key cursor scan OFF: force the continuation onto a TID range scan; the
-- hint marker is trimmed and the drain succeeds.
SET documentdb.enablePrimaryKeyCursorScan TO off;
SET enable_indexscan TO off;
SET enable_bitmapscan TO off;

EXECUTE drain_find_query_continuation('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "hint": { "$natural": 1 }, "batchSize": 3 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 3 }');

SET enable_indexscan TO on;
SET enable_bitmapscan TO on;

-- Dynamic cursors ON: the dynamic cursor scan handles the hint marker; drain
-- succeeds.
SET documentdb.enablePrimaryKeyCursorScan TO on;
SET documentdb.enableDynamicCursors TO on;

EXECUTE drain_find_query_continuation('{ "find": "dyncursor_coll", "projection": { "_id": 1 }, "hint": { "$natural": 1 }, "batchSize": 3 }', '{ "getMore": { "$numberLong": "534" }, "collection": "dyncursor_coll", "batchSize": 3 }');

SET documentdb.enableDynamicCursors TO off;
SET documentdb.enablePrimaryKeyCursorScan TO off;

-- The dynamic cursor tracker is a planner marker, not a filtering predicate.
-- Its presence must not reduce the collection scan row estimate.
DO $$
DECLARE i int;
BEGIN
FOR i IN 1..300 LOOP
PERFORM documentdb_api.insert_one(
    'dyncursordb',
    'selectivity_coll',
    FORMAT('{ "_id": %s, "defs": [ { "key": %s } ] }', i, mod(i, 8))::documentdb_core.bson);
END LOOP;
END;
$$;

DO $$
DECLARE
    collection_id bigint;
BEGIN
    SELECT collections.collection_id
    INTO collection_id
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'dyncursordb' AND collection_name = 'selectivity_coll';

    EXECUTE FORMAT('ANALYZE documentdb_data.documents_%s', collection_id);
END;
$$;

DO $$
DECLARE
    explain_query text := $query$
        EXPLAIN (FORMAT JSON)
        SELECT document
        FROM bson_aggregation_pipeline(
            'dyncursordb',
            '{ "aggregate": "selectivity_coll", "pipeline": [
                { "$unwind": "$defs" },
                { "$group": { "_id": "$defs.key", "doc": { "$first": "$defs" } } }
            ], "cursor": {} }')
    $query$;
    explain_plan jsonb;
    relation_name text;
    rows_without_dynamic_cursor bigint;
    rows_with_dynamic_cursor bigint;
BEGIN
    SELECT FORMAT('documents_%s', collection_id)
    INTO relation_name
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'dyncursordb' AND collection_name = 'selectivity_coll';

    PERFORM set_config('documentdb.enableCursorsOnAggregationQueryRewrite', 'on', true);
    PERFORM set_config('documentdb.enableDynamicCursors', 'off', true);
    EXECUTE explain_query INTO explain_plan;

    WITH RECURSIVE plan_nodes(node) AS
    (
        SELECT explain_plan->0->'Plan'
        UNION ALL
        SELECT child
        FROM plan_nodes
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(plan_nodes.node->'Plans', '[]'::jsonb)) child
    )
    SELECT (node->>'Plan Rows')::bigint
    INTO rows_without_dynamic_cursor
    FROM plan_nodes
    WHERE node->>'Relation Name' = relation_name;

    PERFORM set_config('documentdb.enableDynamicCursors', 'on', true);
    EXECUTE explain_query INTO explain_plan;

    WITH RECURSIVE plan_nodes(node) AS
    (
        SELECT explain_plan->0->'Plan'
        UNION ALL
        SELECT child
        FROM plan_nodes
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(plan_nodes.node->'Plans', '[]'::jsonb)) child
    )
    SELECT (node->>'Plan Rows')::bigint
    INTO rows_with_dynamic_cursor
    FROM plan_nodes
    WHERE node->>'Relation Name' = relation_name;

    IF rows_without_dynamic_cursor IS NULL OR
       rows_with_dynamic_cursor IS DISTINCT FROM rows_without_dynamic_cursor THEN
        RAISE EXCEPTION
            'dynamic cursor changed scan estimate from % to %',
            rows_without_dynamic_cursor,
            rows_with_dynamic_cursor;
    END IF;

    RAISE NOTICE 'dynamic cursor preserves the collection scan estimate';
END;
$$;

-- Check both cursor markers independently against the same physical scan.
-- Disabling the composite planner exposes the per-collection statistics gate.
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
    '{"createIndexes":"selectivity_coll","indexes":[{"key":{"defs.key":1},"name":"defs_key_1"}]}', true);

DO $$
DECLARE
    scenario record;
    collection_id bigint;
    relation_name text;
    base_query text;
    cursor_schema text;
    plan jsonb;
    base_rows bigint;
    base_cost numeric;
    base_startup numeric;
    state_rows bigint;
    state_cost numeric;
    projection_cost numeric;
    apply_support boolean;
BEGIN
    SELECT collections.collection_id INTO STRICT collection_id
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'dyncursordb' AND collection_name = 'selectivity_coll';
    relation_name := format('documentdb_data.documents_%s', collection_id);
    base_query := format('SELECT document FROM %s WHERE ctid >= ''(0,0)''::tid', relation_name);

    PERFORM set_config('enable_seqscan', 'off', true);
    PERFORM set_config('max_parallel_workers_per_gather', '0', true);

    FOR scenario IN SELECT * FROM (VALUES
        ('stats_off_flag_off', false, true, false, false),
        ('stats_off_flag_on', false, true, false, true),
        ('stats_on_flag_off', true, true, false, false),
        ('stats_on_flag_on', true, true, false, true),
        ('stats_globally_off', true, false, false, true),
        ('stats_disabled_again', false, true, false, true),
        ('composite_override', false, true, true, true),
        ('composite_flag_off', false, true, true, false)
    ) AS cases(name, collection_stats, global_stats, composite_planner, feature_enabled)
    LOOP
        PERFORM set_config('documentdb.enablePerCollectionPlannerStatistics', 'on', true);
        PERFORM documentdb_api.coll_mod('dyncursordb', 'selectivity_coll',
            jsonb_build_object('collMod', 'selectivity_coll',
                'enableStats', scenario.collection_stats)::text::documentdb_core.bson);
        EXECUTE format('ANALYZE %s', relation_name);
        IF scenario.collection_stats AND NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_statistic_ext
            WHERE stxrelid = relation_name::regclass) THEN
            RAISE EXCEPTION '%: collection statistics were not created', scenario.name;
        END IF;

        PERFORM set_config('documentdb.enablePerCollectionPlannerStatistics',
            scenario.global_stats::text, true);
        PERFORM set_config('documentdb.enableCompositeIndexPlanner',
            scenario.composite_planner::text, true);
        PERFORM set_config('documentdb.enable_index_scan_on_streaming_cursors',
            scenario.feature_enabled::text, true);
        apply_support := scenario.feature_enabled AND
            ((scenario.collection_stats AND scenario.global_stats) OR scenario.composite_planner);

        EXECUTE 'EXPLAIN (FORMAT JSON) ' || base_query INTO plan;
        base_rows := (plan->0->'Plan'->>'Plan Rows')::bigint;
        base_cost := (plan->0->'Plan'->>'Total Cost')::numeric;
        base_startup := (plan->0->'Plan'->>'Startup Cost')::numeric;

        FOREACH cursor_schema IN ARRAY ARRAY[
            'documentdb_api_internal', 'documentdb_api_internal_readonly']
        LOOP
            EXECUTE 'EXPLAIN (FORMAT JSON) ' || base_query || format(
                ' AND %I.cursor_state(document, ''{"getpage_batchCount":2}'')', cursor_schema)
            INTO plan;
            state_rows := (plan->0->'Plan'->>'Plan Rows')::bigint;
            state_cost := (plan->0->'Plan'->>'Total Cost')::numeric;
            IF (plan->0->'Plan'->>'Startup Cost')::numeric <> base_startup OR
                (apply_support AND (state_rows <> base_rows OR state_cost <> base_cost)) OR
                (NOT apply_support AND (state_rows >= base_rows OR state_cost <= base_cost)) THEN
                RAISE EXCEPTION '%/%: cursor_state estimate/cost %, % differs from baseline %, % (support %)',
                    scenario.name, cursor_schema, state_rows, state_cost, base_rows, base_cost, apply_support;
            END IF;

            EXECUTE format(
                'EXPLAIN (FORMAT JSON) SELECT %I.current_cursor_state(document)
                 FROM %s WHERE ctid >= ''(0,0)''::tid', cursor_schema, relation_name)
            INTO plan;
            projection_cost := (plan->0->'Plan'->>'Total Cost')::numeric;
            IF (plan->0->'Plan'->>'Plan Rows')::bigint <> base_rows OR
                (plan->0->'Plan'->>'Startup Cost')::numeric <> base_startup OR
                (apply_support AND projection_cost <> base_cost) OR
                (NOT apply_support AND projection_cost <= base_cost) THEN
                RAISE EXCEPTION '%/%: current_cursor_state cost % differs from baseline % (support %)',
                    scenario.name, cursor_schema, projection_cost, base_cost, apply_support;
            END IF;
            RAISE NOTICE '%/%: cursor marker estimates and costs honor the planner gates',
                scenario.name, cursor_schema;
        END LOOP;
    END LOOP;
END;
$$;

SELECT documentdb_api.drop_collection('dyncursordb', 'selectivity_coll');

-- Secondary streaming cursors must use ordered scans even for predicates that
-- otherwise select a fast scan. Repeated keys exercise getMore within a key.
SET documentdb.enableDynamicCursors TO off;
SET documentdb.enablePrimaryKeyCursorScan TO off;
SET documentdb.enable_index_scan_on_streaming_cursors TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO off;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

SELECT COUNT(documentdb_api.insert_one('dyncursordb', 'ordered_streaming_coll',
    FORMAT('{ "_id": %s, "a": %s, "b": %s, "s": "%s" }', i, mod(i, 3), mod(i, 4),
        CASE mod(i, 3) WHEN 0 THEN 'Alpha' WHEN 1 THEN 'alpha' ELSE 'Beta' END
    )::documentdb_core.bson))
FROM generate_series(9, 1, -1) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
    '{"createIndexes":"ordered_streaming_coll","indexes":[
        {"key":{"a":1},"name":"ordered_a","enableOrderedIndex":true},
        {"key":{"a":1,"b":1},"name":"ordered_ab_aa","enableOrderedIndex":true},
        {"key":{"a":1,"b":-1},"name":"ordered_ab_ad","enableOrderedIndex":true},
        {"key":{"s":1},"name":"ordered_s_ci","enableOrderedIndex":true,
         "collation":{"locale":"en","strength":2}}
    ]}', true);

PREPARE drain_ordered_streaming(bson) AS
    WITH RECURSIVE pages AS (
        SELECT cursorPage, continuation, 1 AS page
        FROM find_cursor_first_page('dyncursordb', $1, 534)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation, pages.page + 1
        FROM pages,
             cursor_get_more('dyncursordb',
                 '{"getMore":{"$numberLong":"534"},"collection":"ordered_streaming_coll","batchSize":2}',
                 pages.continuation) gm
        WHERE pages.continuation IS NOT NULL AND pages.page < 10
    )
    SELECT page,
           bson_dollar_project(cursorPage,
               '{"cursor.firstBatch":1,"cursor.nextBatch":1}') AS batch,
           continuation IS NOT NULL AS has_more,
           COALESCE((bson_to_json_string(continuation)::text::jsonb
               -> 'continuation' -> 0) ? 'six', false) AS secondary_continuation
    FROM pages
    ORDER BY page;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('dyncursordb',
    '{"find":"ordered_streaming_coll","filter":{"a":{"$in":[0,2]}},"projection":{"_id":1},"hint":"ordered_a","batchSize":2}');
$cmd$);
RESET documentdb.enableCursorsOnAggregationQueryRewrite;

EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"a":1},"projection":{"_id":1},"hint":"ordered_a","batchSize":2}');
EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"a":{"$in":[0,2]}},"projection":{"_id":1},"hint":"ordered_a","batchSize":2}');
EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"a":{"$in":[0,2]},"b":{"$in":[1,3]}},"projection":{"_id":1},"hint":"ordered_ab_aa","batchSize":2}');
EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"a":{"$in":[0,2]},"b":{"$in":[1,3]}},"projection":{"_id":1},"hint":"ordered_ab_ad","batchSize":2}');
EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"a":99},"projection":{"_id":1},"hint":"ordered_a","batchSize":2}');

-- Bitmap candidates must also become ordered scans when unwrapped.
SET enable_bitmapscan TO on;
SET enable_indexscan TO off;
EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"a":1},"projection":{"_id":1},"hint":"ordered_a","batchSize":2}');
RESET enable_indexscan;

-- Covered candidates are downgraded to ordinary ordered index scans.
SET documentdb.enableIndexOnlyScanForFindProject TO on;
EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"a":1},"projection":{"_id":0,"a":1},"hint":"ordered_a","batchSize":2}');

-- Case-insensitive matching must survive the ordered scan and its continuation.
EXECUTE drain_ordered_streaming(
    '{"find":"ordered_streaming_coll","filter":{"s":"ALPHA"},"projection":{"_id":1},"hint":"ordered_s_ci","collation":{"locale":"en","strength":2},"batchSize":2}');

-- A competing index may prune the original path, but must not kill its cursor.
SET documentdb.enableIndexOnlyScanForFindProject TO off;
SELECT COUNT(documentdb_api.insert_one('dyncursordb', 'ordered_replan_coll', document))
FROM documentdb_api.collection('dyncursordb', 'ordered_streaming_coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
    '{"createIndexes":"ordered_replan_coll","indexes":[
        {"key":{"a":1},"name":"ordered_a","enableOrderedIndex":true}
    ]}', true);
CREATE TEMP TABLE ordered_streaming_resume AS
SELECT cursorPage, continuation
FROM find_cursor_first_page('dyncursordb',
    '{"find":"ordered_replan_coll","filter":{"a":{"$gte":0}},"projection":{"_id":1},"batchSize":2}',
    534);
SELECT bson_dollar_project(cursorPage, '{"cursor.firstBatch":1}') AS first_page,
       (bson_to_json_string(continuation)::text::jsonb
           -> 'continuation' -> 0) ? 'six' AS secondary_continuation
FROM ordered_streaming_resume;
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
    '{"createIndexes":"ordered_replan_coll","indexes":[
        {"key":{"a":-1},"name":"ordered_a_desc","enableOrderedIndex":true}
    ]}', true);
WITH RECURSIVE pages AS (
    SELECT cursorPage, continuation, 1 AS page FROM ordered_streaming_resume
    UNION ALL
    SELECT gm.cursorPage, gm.continuation, pages.page + 1
    FROM pages,
         cursor_get_more('dyncursordb',
             '{"getMore":{"$numberLong":"534"},"collection":"ordered_replan_coll","batchSize":2}',
             pages.continuation) gm
    WHERE pages.continuation IS NOT NULL AND pages.page < 10
)
SELECT array_agg((doc -> '_id' ->> '$numberInt')::int
           ORDER BY (doc -> '_id' ->> '$numberInt')::int) AS ids,
       bool_or(continuation IS NULL) AS exhausted
FROM pages,
     jsonb_array_elements(COALESCE(
         bson_to_json_string(cursorPage)::text::jsonb #> '{cursor,firstBatch}',
         bson_to_json_string(cursorPage)::text::jsonb #> '{cursor,nextBatch}')) doc;
DROP TABLE ordered_streaming_resume;
SELECT documentdb_api.drop_collection('dyncursordb', 'ordered_replan_coll');

-- A TID continuation must not adopt a newly available secondary index order.
DO $$
DECLARE
    test_case record;
    collection_name text;
    command_spec bson;
    get_more_spec bson;
    cursor_page bson;
    cursor_continuation bson;
    holds_portal bool;
    ids int[];
    batch_ids int[];
    sorted_ids int[];
    distinct_ids bigint;
    pages int;
BEGIN
    FOR test_case IN
        SELECT * FROM (VALUES
            ('heap_index', false, false),
            ('heap_bitmap', false, true),
            ('multikey_index', true, false),
            ('multikey_bitmap', true, true)
        ) cases(label, multikey, bitmap_only)
    LOOP
        collection_name := 'mode_' || test_case.label;
        PERFORM set_config('documentdb.enablePrimaryKeyCursorScan', test_case.multikey::text, false);
        PERFORM set_config('enable_bitmapscan', test_case.bitmap_only::text, false);
        PERFORM set_config('enable_indexscan', (NOT test_case.bitmap_only)::text, false);
        PERFORM documentdb_api.insert_one('dyncursordb', collection_name,
            FORMAT('{"_id":%s,"a":%s,"b":%s}', i,
                CASE WHEN test_case.multikey THEN '[1,2]' ELSE i::text END, i)::bson)
        FROM generate_series(24, 1, -1) i;
        IF test_case.multikey THEN
            PERFORM documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
                jsonb_build_object('createIndexes', collection_name, 'indexes',
                    '[{"key":{"a":1},"name":"a","enableOrderedIndex":true}]'::jsonb)::text::bson, true);
        END IF;
        command_spec := jsonb_build_object('find', collection_name,
            'filter', CASE WHEN test_case.multikey THEN '{"a":1,"b":{"$gte":1}}'::jsonb
                ELSE '{"b":{"$gte":1}}'::jsonb END,
            'projection', '{"_id":1}'::jsonb, 'batchSize', 2)::text::bson;
        get_more_spec := FORMAT(
            '{"getMore":{"$numberLong":"534"},"collection":"%s","batchSize":2}',
            collection_name)::bson;
        SELECT fp.cursorPage, fp.continuation, fp.persistConnection
        INTO cursor_page, cursor_continuation, holds_portal
        FROM find_cursor_first_page('dyncursordb', command_spec, 534) fp;
        IF holds_portal OR cursor_continuation IS NULL THEN
            RAISE EXCEPTION '%: expected a streaming continuation', test_case.label;
        END IF;
        SELECT array_agg((doc -> '_id' ->> '$numberInt')::int)
        INTO batch_ids FROM jsonb_array_elements(
            cursor_page::text::jsonb #> '{cursor,firstBatch}') doc;
        IF batch_ids IS DISTINCT FROM ARRAY[24,23] THEN
            RAISE EXCEPTION '%: expected initial heap order, got %', test_case.label, batch_ids;
        END IF;
        PERFORM documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
            jsonb_build_object('createIndexes', collection_name, 'indexes',
                '[{"key":{"b":1},"name":"b","enableOrderedIndex":true}]'::jsonb)::text::bson, true);
        ids := '{}';
        pages := 0;
        LOOP
            pages := pages + 1;
            IF pages > 32 THEN
                RAISE EXCEPTION '%: cursor did not terminate', test_case.label;
            END IF;
            SELECT array_agg((doc -> '_id' ->> '$numberInt')::int)
            INTO batch_ids FROM jsonb_array_elements(COALESCE(
                cursor_page::text::jsonb #> '{cursor,firstBatch}',
                cursor_page::text::jsonb #> '{cursor,nextBatch}')) doc;
            ids := ids || COALESCE(batch_ids, '{}');
            EXIT WHEN cursor_continuation IS NULL;
            IF EXISTS (
                SELECT FROM jsonb_array_elements(
                    cursor_continuation::text::jsonb -> 'continuation') entry
                WHERE entry ? 'six'
            ) THEN
                RAISE EXCEPTION '%: TID continuation switched to secondary index order', test_case.label;
            END IF;
            SELECT gm.cursorPage, gm.continuation INTO cursor_page, cursor_continuation
            FROM cursor_get_more('dyncursordb', get_more_spec, cursor_continuation) gm;
        END LOOP;
        SELECT array_agg(id ORDER BY id), count(DISTINCT id)
        INTO sorted_ids, distinct_ids FROM unnest(ids) id;
        IF sorted_ids IS DISTINCT FROM ARRAY(SELECT generate_series(1,24)) OR
           cardinality(ids) <> distinct_ids THEN
            RAISE EXCEPTION '%: incomplete or duplicate results: %', test_case.label, sorted_ids;
        END IF;
        SELECT fp.continuation INTO cursor_continuation
        FROM find_cursor_first_page('dyncursordb', command_spec, 534) fp;
        IF NOT COALESCE((cursor_continuation::text::jsonb -> 'continuation' -> 0) ? 'six', false) THEN
            RAISE EXCEPTION '%: fresh cursor did not use the new secondary index', test_case.label;
        END IF;
        PERFORM documentdb_api.drop_collection('dyncursordb', collection_name);
        RAISE NOTICE '%: 24 unique documents, TID order preserved, fresh cursor uses new index', test_case.label;
    END LOOP;
END;
$$;
SET documentdb.enablePrimaryKeyCursorScan TO off;
SET enable_bitmapscan TO on;
RESET enable_indexscan;

-- Long inline terms can be page-owned rather than detoasted copies.
SELECT COUNT(documentdb_api.insert_one('dyncursordb', 'ordered_streaming_coll',
    FORMAT('{"_id":%s,"a":"%s"}', 100 + i, repeat('long-key-', 32))::bson))
FROM generate_series(1, 3) AS i;
EXECUTE drain_ordered_streaming(FORMAT(
    '{"find":"ordered_streaming_coll","filter":{"a":"%s"},"projection":{"_id":1},"hint":"ordered_a","batchSize":1}',
    repeat('long-key-', 32))::bson);

-- If the entire saved key disappears, resume at the next key, not at its TID.
-- Numeric collation orders item10 after item2, unlike binary comparison.
SET documentdb.enableComparableTerms TO off;
SELECT COUNT(documentdb_api.insert_one('dyncursordb', 'ordered_numeric_coll',
    FORMAT('{"_id":%s,"a":"item%s"}', i, i)::bson))
FROM (VALUES (2), (10), (20)) AS docs(i);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
    '{"createIndexes":"ordered_numeric_coll","indexes":[
        {"key":{"a":1},"name":"ordered_numeric_a","enableOrderedIndex":true,
         "collation":{"locale":"en","numericOrdering":true}}
    ]}', true);
CREATE TEMP TABLE ordered_collated_boundary AS
SELECT cursorPage, continuation
FROM find_cursor_first_page('dyncursordb',
    '{"find":"ordered_numeric_coll","filter":{"a":{"$in":["item2","item10","item20"]}},"projection":{"_id":1},"hint":"ordered_numeric_a","collation":{"locale":"en","numericOrdering":true},"batchSize":1}',
    534);
SELECT bson_dollar_project(cursorPage, '{"cursor.firstBatch":1}') AS first_page,
       (bson_to_json_string(continuation)::text::jsonb
           -> 'continuation' -> 0) ? 'six' AS secondary_continuation
FROM ordered_collated_boundary;
SELECT documentdb_api.delete('dyncursordb',
    '{"delete":"ordered_numeric_coll","deletes":[{"q":{"a":"item2"},"limit":0}],"collation":{"locale":"en","numericOrdering":true}}');
SELECT bson_dollar_project(cursorPage, '{"cursor.nextBatch":1}') AS remaining,
       continuation IS NULL AS exhausted
FROM cursor_get_more('dyncursordb',
    '{"getMore":{"$numberLong":"534"},"collection":"ordered_numeric_coll","batchSize":10}',
    (SELECT continuation FROM ordered_collated_boundary));
DROP TABLE ordered_collated_boundary;

-- Dynamic cursors save the next, unemitted key rather than the last emitted key.
SELECT COUNT(documentdb_api.insert_one('dyncursordb', 'ordered_numeric_coll',
    FORMAT('{"_id":%s,"a":"item%s"}', i, i)::bson))
FROM (VALUES (1), (2)) AS docs(i);
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableRumCursorDynamicIndexScans TO on;
CREATE TEMP TABLE dynamic_collated_boundary AS
SELECT cursorPage, continuation
FROM find_cursor_first_page('dyncursordb',
    '{"find":"ordered_numeric_coll","filter":{"a":{"$in":["item1","item2","item10","item20"]}},"projection":{"_id":1},"hint":"ordered_numeric_a","collation":{"locale":"en","numericOrdering":true},"batchSize":1}',
    534);
SELECT bson_dollar_project(cursorPage, '{"cursor.firstBatch":1}') AS first_page,
       continuation::text::jsonb #>> '{dc,type,$numberInt}' AS dynamic_scan_type
FROM dynamic_collated_boundary;
SELECT documentdb_api.delete('dyncursordb',
    '{"delete":"ordered_numeric_coll","deletes":[{"q":{"a":"item2"},"limit":0}],"collation":{"locale":"en","numericOrdering":true}}');
SELECT bson_dollar_project(cursorPage, '{"cursor.nextBatch":1}') AS remaining,
       continuation IS NULL AS exhausted
FROM cursor_get_more('dyncursordb',
    '{"getMore":{"$numberLong":"534"},"collection":"ordered_numeric_coll","batchSize":10}',
    (SELECT continuation FROM dynamic_collated_boundary));
DROP TABLE dynamic_collated_boundary;
SET documentdb.enableDynamicCursors TO off;
RESET documentdb.enableRumCursorDynamicIndexScans;
SELECT documentdb_api.drop_collection('dyncursordb', 'ordered_numeric_coll');
RESET documentdb.enableComparableTerms;

CREATE TEMP TABLE ordered_deleted_boundary AS
SELECT continuation
FROM find_cursor_first_page('dyncursordb',
    '{"find":"ordered_streaming_coll","filter":{"a":{"$in":[0,2]}},"projection":{"_id":1},"hint":"ordered_a","batchSize":3}',
    534);
SELECT documentdb_api.delete('dyncursordb',
    '{"delete":"ordered_streaming_coll","deletes":[{"q":{"a":0},"limit":0}]}');
SELECT bson_dollar_project(cursorPage, '{"cursor.nextBatch":1}') AS remaining,
       continuation IS NULL AS exhausted
FROM cursor_get_more('dyncursordb',
    '{"getMore":{"$numberLong":"534"},"collection":"ordered_streaming_coll","batchSize":10}',
    (SELECT continuation FROM ordered_deleted_boundary));
DROP TABLE ordered_deleted_boundary;

DEALLOCATE drain_ordered_streaming;
SELECT documentdb_api.drop_collection('dyncursordb', 'ordered_streaming_coll');
RESET documentdb.enable_index_scan_on_streaming_cursors;
RESET documentdb.enableIndexOnlyScanForFindProject;
RESET documentdb_core.enableCollation;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET enable_seqscan;
RESET enable_bitmapscan;

-- A descending dynamic cursor must resume below a deleted, unemitted key.
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableRumCursorDynamicIndexScans TO on;
SET documentdb.enable_index_scan_on_streaming_cursors TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
    '{"createIndexes":"descending_deleted_boundary","indexes":[{"key":{"item":1},"name":"item_idx"}]}', true);
SELECT documentdb_api.insert_one('dyncursordb', 'descending_deleted_boundary', '{"_id":1,"item":"A"}');
SELECT documentdb_api.insert_one('dyncursordb', 'descending_deleted_boundary', '{"_id":2,"item":"B"}');
SELECT documentdb_api.insert_one('dyncursordb', 'descending_deleted_boundary', '{"_id":3,"item":"C"}');
SELECT documentdb_api.insert_one('dyncursordb', 'descending_deleted_boundary', '{"_id":4,"item":"D"}');
SELECT documentdb_api.insert_one('dyncursordb', 'descending_deleted_boundary', '{"_id":5,"item":"E"}');

CREATE TEMP TABLE dynamic_descending_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM find_cursor_first_page('dyncursordb',
    '{"find":"descending_deleted_boundary","sort":{"item":-1},"hint":"item_idx","batchSize":1}',
    4242);
SELECT bson_dollar_project(cursorPage, '{"cursor.firstBatch._id":1}') AS first_page,
       continuation::text::jsonb #>> '{dc,type,$numberInt}' AS dynamic_scan_type
FROM dynamic_descending_first_page;

DO $$
DECLARE
    first_page jsonb;
    cursor_state jsonb;
    persistent boolean;
BEGIN
    SELECT cursorPage::text::jsonb, continuation::text::jsonb, persistConnection
    INTO STRICT first_page, cursor_state, persistent
    FROM dynamic_descending_first_page;
    IF first_page #>> '{cursor,firstBatch,0,_id,$numberInt}' IS DISTINCT FROM '5'
        OR jsonb_array_length(first_page #> '{cursor,firstBatch}') <> 1
        OR cursor_state #>> '{dc,type,$numberInt}' IS DISTINCT FROM '3'
        OR persistent IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'expected a secondary-index dynamic cursor returning only _id 5';
    END IF;
END;
$$;

SELECT documentdb_api.delete('dyncursordb',
    '{"delete":"descending_deleted_boundary","deletes":[{"q":{"_id":4},"limit":1}]}');

CREATE TEMP TABLE dynamic_descending_next_page AS
SELECT cursorPage, continuation
FROM cursor_get_more('dyncursordb',
    '{"getMore":{"$numberLong":"4242"},"collection":"descending_deleted_boundary","batchSize":10}',
    (SELECT continuation FROM dynamic_descending_first_page));
SELECT bson_dollar_project(cursorPage, '{"cursor.nextBatch._id":1}') AS remaining,
       continuation IS NULL AS exhausted
FROM dynamic_descending_next_page;

DO $$
DECLARE
    remaining_ids integer[];
BEGIN
    SELECT ARRAY(
        SELECT (document #>> '{_id,$numberInt}')::integer
        FROM jsonb_array_elements(page.cursorPage::text::jsonb #> '{cursor,nextBatch}')
            WITH ORDINALITY AS batch(document, position)
        ORDER BY position)
    INTO STRICT remaining_ids
    FROM dynamic_descending_next_page AS page;
    IF remaining_ids IS DISTINCT FROM ARRAY[3,2,1] THEN
        RAISE EXCEPTION 'descending dynamic cursor lost remaining rows after deleting saved key: expected {3,2,1}, got %',
            remaining_ids;
    END IF;
END;
$$;

DROP TABLE dynamic_descending_first_page, dynamic_descending_next_page;
SELECT documentdb_api.drop_collection('dyncursordb', 'descending_deleted_boundary');

-- Compare in traversal order, not the query's sort direction or the first index
-- column's direction. Equal-key TIDs still advance forward in a backward scan.
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
DO $$
DECLARE
    comparable_terms boolean;
    test_case record;
    collection_name text;
    first_page jsonb;
    next_page jsonb;
    cursor_state bson;
    persistent boolean;
    actual_ids integer[];
BEGIN
    FOR comparable_terms IN SELECT * FROM (VALUES (false), (true)) AS modes(enabled)
    LOOP
        PERFORM set_config('documentdb.enableComparableTerms', comparable_terms::text, true);
        FOR test_case IN
            SELECT * FROM (VALUES
                ('asc_asc', '{"item":1}'::jsonb, 1, NULL::jsonb, NULL::jsonb,
                 ARRAY['A','B','C','D','E'], 1, 2, ARRAY[3,4,5]),
                ('asc_desc', '{"item":1}', -1, NULL, NULL,
                 ARRAY['A','B','C','D','E'], 5, 4, ARRAY[3,2,1]),
                ('desc_asc', '{"item":-1}', 1, NULL, NULL,
                 ARRAY['A','B','C','D','E'], 1, 2, ARRAY[3,4,5]),
                ('desc_desc', '{"item":-1}', -1, NULL, NULL,
                 ARRAY['A','B','C','D','E'], 5, 4, ARRAY[3,2,1]),
                ('equal_key', '{"item":1}', -1, NULL, NULL,
                 ARRAY['A','B','B','B','C'], 5, 2, ARRAY[3,4,1]),
                ('compound_prefix', '{"prefix":1,"item":-1}', 1, '{"prefix":1}', NULL,
                 ARRAY['A','B','C','D','E'], 1, 2, ARRAY[3,4,5]),
                ('numeric_collation', '{"item":1}', -1, NULL, '{"locale":"en","numericOrdering":true}',
                 ARRAY['item1','item2','item10','item20'], 4, 3, ARRAY[2,1])
            ) AS cases(label, index_key, sort_direction, filter_spec, collation_spec,
                       items, first_id, deleted_id, remaining_ids)
        LOOP
            collection_name := 'deleted_boundary_' || test_case.label;
            PERFORM documentdb_api.insert_one('dyncursordb', collection_name,
                jsonb_build_object('_id', id, 'prefix', 1, 'item', item)::text::bson)
            FROM unnest(test_case.items) WITH ORDINALITY AS docs(item, id);
            PERFORM documentdb_api_internal.create_indexes_non_concurrently('dyncursordb',
                jsonb_build_object('createIndexes', collection_name, 'indexes',
                    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                        'key', test_case.index_key, 'name', 'resume_idx',
                        'collation', test_case.collation_spec))))::text::bson, true);

            SELECT cursorPage::text::jsonb, continuation, persistConnection
            INTO STRICT first_page, cursor_state, persistent
            FROM find_cursor_first_page('dyncursordb',
                jsonb_strip_nulls(jsonb_build_object('find', collection_name,
                    'filter', test_case.filter_spec,
                    'sort', jsonb_build_object('item', test_case.sort_direction),
                    'projection', jsonb_build_object('_id', 1),
                    'hint', 'resume_idx', 'collation', test_case.collation_spec,
                    'batchSize', 1))::text::bson, 4243);
            SELECT ARRAY(
                SELECT (document #>> '{_id,$numberInt}')::integer
                FROM jsonb_array_elements(first_page #> '{cursor,firstBatch}')
                    WITH ORDINALITY AS batch(document, position) ORDER BY position)
            INTO actual_ids;
            IF actual_ids IS DISTINCT FROM ARRAY[test_case.first_id]
                OR (cursor_state::text::jsonb #>> '{dc,type,$numberInt}')::integer
                    IS DISTINCT FROM 3
                OR persistent IS DISTINCT FROM false THEN
                RAISE EXCEPTION 'unexpected first page for %, comparable terms %: ids %, continuation %',
                    test_case.label, comparable_terms, actual_ids, cursor_state;
            END IF;

            PERFORM documentdb_api.delete('dyncursordb',
                jsonb_build_object('delete', collection_name, 'deletes',
                    jsonb_build_array(jsonb_build_object(
                        'q', jsonb_build_object('_id', test_case.deleted_id),
                        'limit', 1)))::text::bson);
            SELECT cursorPage::text::jsonb, continuation
            INTO STRICT next_page, cursor_state
            FROM cursor_get_more('dyncursordb',
                jsonb_build_object('getMore', jsonb_build_object('$numberLong', '4243'),
                    'collection', collection_name, 'batchSize', 10)::text::bson, cursor_state);
            SELECT ARRAY(
                SELECT (document #>> '{_id,$numberInt}')::integer
                FROM jsonb_array_elements(next_page #> '{cursor,nextBatch}')
                    WITH ORDINALITY AS batch(document, position) ORDER BY position)
            INTO actual_ids;
            IF actual_ids IS DISTINCT FROM test_case.remaining_ids OR cursor_state IS NOT NULL THEN
                RAISE EXCEPTION 'incorrect resume for %, comparable terms %: expected %, got %, continuation %',
                    test_case.label, comparable_terms, test_case.remaining_ids, actual_ids, cursor_state;
            END IF;
            PERFORM documentdb_api.drop_collection('dyncursordb', collection_name);
        END LOOP;
    END LOOP;
END;
$$;
RESET documentdb_core.enableCollation;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.enableDynamicCursors;
RESET documentdb.enableRumCursorDynamicIndexScans;
RESET documentdb.enable_index_scan_on_streaming_cursors;
