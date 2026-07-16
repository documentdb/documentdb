SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 92000;
SET documentdb.next_collection_index_id TO 92000;

-- Dynamic cursors (with parallel plans allowed by default) drive the cursor-type
-- decision this test exercises.
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enable_dynamic_cursor_parallel_plans TO on;

-- Report whether the drained persisted cursor plan used a parallel scan in the
-- continuation document (test-only signal; avoids relying on EXPLAIN).
SET documentdb.reportParallelPlanInCursorContinuation TO on;

SELECT documentdb_api.create_collection('parallel_cursor_db', 'pcoll');

SELECT collection_id AS p_col FROM documentdb_api_catalog.collections WHERE database_name = 'parallel_cursor_db' AND collection_name = 'pcoll' \gset

-- Two workers, autovacuum off for predictable planning.
SELECT FORMAT('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off, parallel_workers = 2)', :p_col) \gexec

SELECT COUNT(documentdb_api.insert_one('parallel_cursor_db', 'pcoll', FORMAT('{ "_id": %s, "a": %s, "b": %s }', i, i, i % 5)::bson)) FROM generate_series(1, 2000) AS i;

-- Ordered index on "a" so order-by / group-by on "a" can stream.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_cursor_db',
    '{ "createIndexes": "pcoll", "indexes": [ { "key": { "a": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "a_1", "enableCompositeTerm": true } ] }', TRUE);

SELECT FORMAT('VACUUM FREEZE ANALYZE documentdb_data.documents_%s', :p_col) \gexec

-- Force parallel plans to be preferred wherever a partial path exists.
SET parallel_tuple_cost TO 0;
SET parallel_setup_cost TO 0;
SET min_parallel_table_scan_size TO 0;
SET min_parallel_index_scan_size TO 0;
SET parallel_leader_participation TO off;
SET documentdb.enableCompositeParallelIndexScan TO on;
SET documentdb.forceParallelScanIfAvailable TO on;
-- Disable seq scan so the planner prefers the (parallel) index/bitmap paths.
SET enable_seqscan TO off;

-- ===========================================================================
-- Streaming cases: even with parallel scans forced, a query that has a
-- streaming path available must pick the streaming dynamic cursor. The
-- continuation must be a streaming continuation ("qp": false) with no parallel
-- plan reported ("pp" absent).
-- ===========================================================================

-- Streaming case 1: plain filter (streams via the dynamic cursor scan).
SELECT bson_dollar_project(continuation, '{ "qp": 1, "pp": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'parallel_cursor_db',
    commandSpec => '{ "find": "pcoll", "filter": { "a": { "$gt": 10 } }, "projection": { "_id": 1 }, "batchSize": 3 }',
    cursorId => 92001);

-- Streaming case 2: order-by pushed down to the ordered index.
SELECT bson_dollar_project(continuation, '{ "qp": 1, "pp": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'parallel_cursor_db',
    commandSpec => '{ "find": "pcoll", "filter": { "a": { "$gt": 10 } }, "sort": { "a": 1 }, "projection": { "_id": 1 }, "batchSize": 3 }',
    cursorId => 92002);

-- Streaming case 3: group-by pushed down (sorted GroupAggregate over ordered index).
SELECT bson_dollar_project(continuation, '{ "qp": 1, "pp": 1 }') AS continuation_flags
FROM aggregate_cursor_first_page(
    database => 'parallel_cursor_db',
    commandSpec => '{ "aggregate": "pcoll", "pipeline": [ { "$sort": { "a": 1 } }, { "$group": { "_id": "$a", "c": { "$sum": 1 } } } ], "cursor": { "batchSize": 3 } }',
    cursorId => 92003);

-- ===========================================================================
-- Parallel case: a query with no streaming path (a blocking sort on an
-- unindexed field) falls back to a persisted cursor. With parallel scans
-- forced, that plan uses a parallel scan and the continuation reports it
-- ("qp": true, "pp": true).
-- ===========================================================================

SELECT bson_dollar_project(continuation, '{ "qp": 1, "pp": 1 }') AS continuation_flags
FROM aggregate_cursor_first_page(
    database => 'parallel_cursor_db',
    commandSpec => '{ "aggregate": "pcoll", "pipeline": [ { "$sort": { "b": 1, "_id": 1 } } ], "cursor": { "batchSize": 3 } }',
    cursorId => 92004);

-- With the report GUC off, the parallel case must not add "pp" to the continuation.
SET documentdb.reportParallelPlanInCursorContinuation TO off;
SELECT bson_dollar_project(continuation, '{ "qp": 1, "pp": 1 }') AS continuation_flags
FROM aggregate_cursor_first_page(
    database => 'parallel_cursor_db',
    commandSpec => '{ "aggregate": "pcoll", "pipeline": [ { "$sort": { "b": 1, "_id": 1 } } ], "cursor": { "batchSize": 3 } }',
    cursorId => 92005);

-- ===========================================================================
-- EXPLAIN via the aggregation query rewrite path must mirror the same decision:
-- the rewritten plan uses the dynamic-cursor cursor options (including parallel)
-- so a streaming query stays a non-parallel dynamic cursor scan while a
-- non-streamable blocking sort is allowed to use a parallel scan.
-- ===========================================================================
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableDynamicCursorFastStartupScan TO on;

-- Streaming (order-by pushed to the ordered index): non-parallel dynamic cursor scan.
EXPLAIN (VERBOSE OFF, COSTS OFF) SELECT document FROM bson_aggregation_pipeline(
    'parallel_cursor_db',
    '{ "aggregate": "pcoll", "pipeline": [ { "$sort": { "a": 1 } } ], "cursor": { "batchSize": 3 } }');

-- Blocking sort on an unindexed field: parallel plan is used (Gather Merge on top).
EXPLAIN (VERBOSE OFF, COSTS OFF) SELECT document FROM bson_aggregation_pipeline(
    'parallel_cursor_db',
    '{ "aggregate": "pcoll", "pipeline": [ { "$sort": { "b": 1, "_id": 1 } } ], "cursor": { "batchSize": 3 } }');

-- Same blocking sort with parallel plans disabled: no parallel scan.
SET documentdb.enable_dynamic_cursor_parallel_plans TO off;
EXPLAIN (VERBOSE OFF, COSTS OFF) SELECT document FROM bson_aggregation_pipeline(
    'parallel_cursor_db',
    '{ "aggregate": "pcoll", "pipeline": [ { "$sort": { "b": 1, "_id": 1 } } ], "cursor": { "batchSize": 3 } }');
SET documentdb.enable_dynamic_cursor_parallel_plans TO on;

-- ===========================================================================
-- Text search ($text) with a textScore sort. The text-search custom scan
-- carries per-query runtime state that cannot be serialized to a parallel
-- worker, so the query must never build a parallel plan (Gather / Gather
-- Merge) over it -- even with parallel plans forced. Before the fix the
-- planner wrapped a parallel partial path in this non-parallelizable custom
-- scan, producing a Gather Merge costed with zero workers that crashed the
-- backend during planning.
-- ===========================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_cursor_db',
    '{ "createIndexes": "pcoll", "indexes": [ { "key": { "t": "text" }, "name": "t_text" } ] }', TRUE);

SELECT documentdb_api.insert_one('parallel_cursor_db', 'pcoll', FORMAT('{ "_id": %s, "t": "cat dog fish" }', 3000 + i)::bson) FROM generate_series(1, 5) AS i;

-- Must not use a parallel plan: no Gather / Gather Merge in the plan.
EXPLAIN (VERBOSE OFF, COSTS OFF) SELECT document FROM bson_aggregation_pipeline(
    'parallel_cursor_db',
    '{ "aggregate": "pcoll", "pipeline": [ { "$match": { "$text": { "$search": "cat" } } }, { "$project": { "score": { "$meta": "textScore" } } }, { "$sort": { "score": { "$meta": "textScore" } } } ], "cursor": { "batchSize": 3 } }');

-- Must not crash and must return the matching documents.
SELECT document FROM bson_aggregation_pipeline(
    'parallel_cursor_db',
    '{ "aggregate": "pcoll", "pipeline": [ { "$match": { "$text": { "$search": "cat" } } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ], "cursor": { "batchSize": 3 } }');

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

SELECT documentdb_api.drop_collection('parallel_cursor_db', 'pcoll');
