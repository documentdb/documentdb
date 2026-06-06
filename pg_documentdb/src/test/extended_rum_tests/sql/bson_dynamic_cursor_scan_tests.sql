SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 9200;
SET documentdb.next_collection_index_id TO 9200;

-- Enable PK cursor scan for dynamic streaming cursors
SET documentdb.enablePrimaryKeyCursorScan TO on;
SET documentdb.enableCursorPlanBeforeRestrictionPathUpdate TO off;
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
SET documentdb.enablePrimaryKeyCursorScan TO on;

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
SET documentdb.enableCursorPlanBeforeRestrictionPathUpdate TO off;
