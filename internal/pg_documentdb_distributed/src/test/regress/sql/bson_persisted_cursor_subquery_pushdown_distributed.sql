-- Distributed coverage for subquery pushdown of $match on computed fields when
-- the query is served by persisted cursors (dynamic cursors disabled), gated by
-- the enable_subquery_pushdown_for_match_on_persisted_cursors GUC.
--
-- The single-node test (bson_persisted_cursor_subquery_pushdown_tests) already
-- verifies the plan shape (the OFFSET-0 Subquery Scan boundary) and the
-- on/off gating on both persisted variants. This test complements it by
-- exercising the path on a *sharded* collection: the collection is hash-sharded
-- on _id so a $match on a non-shard-key field (routeId) fans out to all shards
-- and the coordinator merges and materializes the result.
--
-- SECTION A asserts result correctness across a multi-page getMore over the
-- file-based persisted cursor. SECTION B asserts, via EXPLAIN, that the
-- pushed-down subquery still forms under distribution (the projection becomes a
-- distributed subplan the coordinator reads back).
--
-- SECTION B dumps the (normalized) distributed plan via run_explain_and_trim:
-- shard ids, tuple/data sizes, node ports, OIDs and the system-time variable are
-- normalized by the trim helper and the harness output normalizer, so the plan
-- shape is stable across runs.
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 258601000;
SET documentdb.next_collection_id TO 25860100;
SET documentdb.next_collection_index_id TO 25860100;

-- Persisted cursors: dynamic cursors are explicitly disabled for these tests.
SET documentdb.enableDynamicCursors TO off;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enablePrimaryKeyCursorScan TO on;

-- ===========================================================================
-- Data setup: 20 documents, hash-sharded on _id so that a $match on routeId
-- (a non-shard-key field) is not pruned to a single shard. routeId:1 matches
-- 4 documents (_id 5, 10, 15, 20).
-- ===========================================================================
SELECT documentdb_api.drop_collection('pcsub_pushdown_db', 'flights');

SELECT COUNT(documentdb_api.insert_one('pcsub_pushdown_db', 'flights',
    FORMAT('{ "_id": %s, "routeId": %s, "legs": [
        { "code": "A", "dist": %s },
        { "code": "B", "dist": %s }
    ]}',
        i,
        (i % 5) + 1,
        i,
        i + 1
    )::documentdb_core.bson))
FROM generate_series(1, 20) AS i;

SELECT documentdb_api.shard_collection('pcsub_pushdown_db', 'flights', '{ "_id": "hashed" }', false);

-- Refresh planner statistics scoped to this collection only (compact in
-- updateStats mode runs ANALYZE on the collection's backing table) so the plan
-- shapes below are stable without mutating shared statistics across tests.
SELECT documentdb_api.compact('{"compact": "flights", "$db": "pcsub_pushdown_db", "mode": "updateStats"}');

-- ===========================================================================
-- SECTION A: File-based persisted cursor over the sharded collection.
-- $match {routeId:1} -> $project {legCount:$size:$legs} -> $match {legCount>0}
-- with a trailing $sort {_id:1} so the result order (hence page contents) is
-- deterministic across shards. batchSize:2 over 4 matches forces first page +
-- one getMore.
-- ===========================================================================
SET documentdb.enable_subquery_pushdown_for_match_on_persisted_cursors TO on;
SET documentdb.useFileBasedPersistedCursors TO on;

-- ---------------------------------------------------------------------------
-- Test A1: First page (batchSize 2) over the file-based persisted cursor.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE pcsub_dist_first_page AS
SELECT cursorPage, continuation FROM documentdb_api.aggregate_cursor_first_page(
    database => 'pcsub_pushdown_db',
    commandSpec => '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": { "batchSize": 2 } }',
    cursorId => 4294967294);

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM pcsub_dist_first_page;

SELECT continuation AS pcsub_dist_cont FROM pcsub_dist_first_page \gset

-- ---------------------------------------------------------------------------
-- Test A2: getMore drains the remaining documents from the file-based cursor.
-- The full 4-document result set must be returned correctly across pages.
-- ---------------------------------------------------------------------------
SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "flights", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_dist_cont');

SET documentdb.useFileBasedPersistedCursors TO off;
DROP TABLE pcsub_dist_first_page;

-- ===========================================================================
-- SECTION B: EXPLAIN — confirm the subquery pushdown still forms under
-- distribution. The computed-field $match forces a subquery boundary, so the
-- projection is materialized as a distributed subplan and the coordinator reads
-- the intermediate result back while the shards perform the routeId scan.
-- The distributed runtime details (shard ids, tuple/data sizes, node ports, the
-- system-time variable) are normalized by run_explain_and_trim + the harness
-- output normalizer, so the plan shape is stable across runs.
-- ===========================================================================
-- enableExtendedExplainPlans renders the BSON specs as readable JSON so the
-- system-time variable can be normalized in the expected output.
SET documentdb.enableExtendedExplainPlans TO on;

SET citus.propagate_set_commands TO 'local';
BEGIN;
SET LOCAL citus.max_adaptive_executor_pool_size TO 1;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL citus.explain_analyze_sort_method TO taskId;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim(
    $cmd$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('pcsub_pushdown_db', '{ "aggregate": "flights", "pipeline": [ { "$match": { "routeId": 1 } }, { "$project": { "_id": 1, "routeId": 1, "legCount": { "$size": "$legs" } } }, { "$match": { "legCount": { "$gt": 0 } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }')$cmd$,
    p_ignore_distributed_runtime_details => true,
    p_ignore_distributed_subplan_ids => true
);
ROLLBACK;

RESET documentdb.enableExtendedExplainPlans;

SELECT documentdb_api.drop_collection('pcsub_pushdown_db', 'flights');

RESET search_path;
