-- Coverage for the group-first distinct scan under dynamic (streaming) cursors.
--
-- A pipeline of the shape
--     { "$match": { "a": { "$in": [ ... ] } } },
--     { "$sort":  { "a": 1, "b": 1, "c": 1 } },
--     { "$group": { "_id": "$a", "<field>": { "$first": "$$ROOT" } } }
-- can be served by a distinct custom scan over a composite index on
-- { a: 1, b: 1, c: 1 }: the scan skips directly to the first index entry of each
-- group key instead of reading every entry that matches the $in bounds.
--
-- With documentdb.enableDynamicCursors turned on the cursor custom scan is
-- planned as well. The expected shape is the distinct scan sitting above the
-- cursor scan, keeping the skip bound on the underlying index scan, so paging
-- does not give up the skip. The pagination section below drains the same
-- pipeline through aggregate_cursor_first_page / cursor_get_more and asserts
-- the cursor streams (it is not a persistent, fully materialized cursor) and
-- that every batch size returns each group key exactly once.

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

SET documentdb.next_collection_id TO 30010000;
SET documentdb.next_collection_index_id TO 30010000;

-- Composite op class is what lets the composite index expose the skip primitive
-- the distinct scan is built on.
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableDistinctScanForGroupFirst TO on;
SET documentdb.enable_distinct_scan_for_ordered_group_first TO on;
SET documentdb.enable_distinct_skip_scan_on_key TO on;

-- The aggregation query rewrite is what puts a cursor scan into the plan when
-- dynamic cursors are enabled, so it has to be on for the comparison below to
-- exercise the dynamic cursor path at all.
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- a -> 5 distinct group keys, b/c give the index a useful trailing order.
-- g -> 50 distinct group keys, used by the pagination section so that small
-- batch sizes actually force multiple round trips.
SELECT COUNT(documentdb_api.insert_one('dc_group_first_db', 'dc_group_first',
    bson_build_document('_id', i, 'a', i % 5, 'b', i % 7, 'c', i, 'g', i % 50)))
FROM generate_series(1, 500) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('dc_group_first_db',
    '{ "createIndexes": "dc_group_first", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_b_c" }, { "key": { "g": 1, "b": 1, "c": 1 }, "name": "g_b_c" } ] }',
    true);

ANALYZE;

SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

-- ===========================================================================
-- Baseline: dynamic cursors off. The plan is a GroupAggregate over
-- DocumentDBApiDistinctQueryScan, and the index condition carries the
-- fullScan/numGroupKeyPaths skip bound.
-- ===========================================================================
SET documentdb.enableDynamicCursors TO off;

EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_pipeline('dc_group_first_db',
    '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 2 } }');

-- ===========================================================================
-- Dynamic cursors on. DocumentDBApiDistinctQueryScan stays on top of
-- DocumentDBApiCursorScan and the skip bound is still present in the index
-- condition, so the scan keeps skipping to one entry per group key.
-- ===========================================================================
SET documentdb.enableDynamicCursors TO on;

EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_pipeline('dc_group_first_db',
    '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 2 } }');

-- ===========================================================================
-- Both settings return the same rows.
-- ===========================================================================
SET documentdb.enableDynamicCursors TO off;
SELECT document FROM bson_aggregation_pipeline('dc_group_first_db',
    '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } }, { "$sort": { "_id": 1 } } ], "cursor": { "batchSize": 2 } }');

SET documentdb.enableDynamicCursors TO on;
SELECT document FROM bson_aggregation_pipeline('dc_group_first_db',
    '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } }, { "$sort": { "_id": 1 } } ], "cursor": { "batchSize": 2 } }');

-- ===========================================================================
-- Same shape with a $replaceRoot tail, which is the common way this pipeline is
-- written. The distinct scan is kept with dynamic cursors here as well.
-- ===========================================================================
SET documentdb.enableDynamicCursors TO off;

EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_pipeline('dc_group_first_db',
    '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } }, { "$replaceRoot": { "newRoot": "$first" } } ], "cursor": { "batchSize": 2 } }');

SET documentdb.enableDynamicCursors TO on;

EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_pipeline('dc_group_first_db',
    '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } }, { "$replaceRoot": { "newRoot": "$first" } } ], "cursor": { "batchSize": 2 } }');

-- ===========================================================================
-- Draining the real cursor entry point under dynamic cursors returns the same
-- one-document-per-group-key result, confirming only the plan regressed.
-- ===========================================================================
SET documentdb.enableDynamicCursors TO on;

SELECT bson_dollar_project(cursorPage,
    '{ "n": { "$size": { "$ifNull": [ "$cursor.firstBatch", [] ] } } }') AS first_page_size
FROM aggregate_cursor_first_page(
    database => 'dc_group_first_db',
    commandSpec => '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 10 } }'::bson,
    cursorId => 30010001);


-- ===========================================================================
-- Pagination: the group-first distinct scan has to remain pageable. The
-- pipeline below groups on "g" (50 distinct group keys) over the { g, b, c }
-- index, so small batch sizes force real getMore round trips.
--
-- dcgf_drain reports:
--   total       - documents summed across every page
--   first_type  - dc.type from the first continuation (the cursor scan type;
--                 NULL when the whole result fits in the first page)
--   round_trips - first page plus one per getMore
--   persist     - persistConnection, which is false for a streaming cursor and
--                 true when the planner fell back to a materialized cursor
-- ===========================================================================
CREATE OR REPLACE FUNCTION dcgf_drain(p_agg text, p_batch_size int)
RETURNS TABLE(total bigint, first_type int, round_trips int, persist bool) AS $fn$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_batch bigint;
BEGIN
    total := 0;
    round_trips := 0;
    first_type := NULL;

    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
    INTO v_page, v_cont, persist
    FROM aggregate_cursor_first_page(
        database => 'dc_group_first_db', commandSpec => p_agg::documentdb_core.bson,
        cursorId => 30010002) fp;
    round_trips := round_trips + 1;

    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": [ "$cursor.firstBatch", [] ] } } }') ->> 'c')::bigint
        INTO v_batch;
    total := total + COALESCE(v_batch, 0);

    IF v_cont IS NOT NULL THEN
        SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO first_type;
    END IF;

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'dc_group_first_db',
            getMoreSpec => FORMAT('{ "getMore": { "$numberLong": "30010002" }, "collection": "dc_group_first", "batchSize": %s }', p_batch_size)::documentdb_core.bson,
            continuationSpec => v_cont) gm;
        round_trips := round_trips + 1;

        SELECT (bson_dollar_project(v_page,
            '{ "c": { "$size": { "$ifNull": [ "$cursor.nextBatch", [] ] } } }') ->> 'c')::bigint
            INTO v_batch;
        total := total + COALESCE(v_batch, 0);
    END LOOP;

    RETURN NEXT;
END;
$fn$ LANGUAGE plpgsql;

-- Same drain, but yields the group keys page by page so the paged result can be
-- compared against the single-page result.
CREATE OR REPLACE FUNCTION dcgf_drain_keys(p_agg text, p_batch_size int)
RETURNS SETOF documentdb_core.bson AS $fn$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
BEGIN
    SELECT fp.cursorPage, fp.continuation INTO v_page, v_cont
    FROM aggregate_cursor_first_page(
        database => 'dc_group_first_db', commandSpec => p_agg::documentdb_core.bson,
        cursorId => 30010003) fp;

    RETURN QUERY SELECT bson_dollar_project(u, '{ "_id": 0, "d": "$cursor.firstBatch._id" }')
        FROM bson_dollar_unwind(v_page, '$cursor.firstBatch') u;

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'dc_group_first_db',
            getMoreSpec => FORMAT('{ "getMore": { "$numberLong": "30010003" }, "collection": "dc_group_first", "batchSize": %s }', p_batch_size)::documentdb_core.bson,
            continuationSpec => v_cont) gm;

        RETURN QUERY SELECT bson_dollar_project(u, '{ "_id": 0, "d": "$cursor.nextBatch._id" }')
            FROM bson_dollar_unwind(v_page, '$cursor.nextBatch') u;
    END LOOP;
END;
$fn$ LANGUAGE plpgsql;

SET documentdb.enableDynamicCursors TO on;

-- The paged plan is still a distinct scan over the cursor scan on { g, b, c }.
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_pipeline('dc_group_first_db',
    '{ "aggregate": "dc_group_first", "hint": "g_b_c", "pipeline": [ { "$sort": { "g": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$g", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 1 } }');

-- batchSize 1: one group per page over a streaming (non-persistent) cursor.
-- total must be 50.
SELECT total, round_trips, persist FROM dcgf_drain(
    '{ "aggregate": "dc_group_first", "hint": "g_b_c", "pipeline": [ { "$sort": { "g": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$g", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 1 } }',
    1);

-- Every batch size must return all 50 group keys exactly once over a streaming
-- cursor, and the number of round trips must track the batch size.
SELECT bs AS batch_size, d.total, d.round_trips, d.persist
FROM unnest(ARRAY[1, 2, 3, 7, 25, 50, 51]) AS bs,
LATERAL dcgf_drain(
    FORMAT('{ "aggregate": "dc_group_first", "hint": "g_b_c", "pipeline": [ { "$sort": { "g": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$g", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": %s } }', bs),
    bs) d
ORDER BY bs;

-- Paging one group at a time must return every group key exactly once. The
-- distinct scan defers its skip until the next fetch, so the index scan stays
-- positioned on the tuple the continuation is captured for; skipping eagerly
-- moved the scan descriptor a group past that tuple and silently dropped groups
-- at every page boundary. dropped_group_keys must stay empty.
SELECT COUNT(*) AS paged_keys, COUNT(DISTINCT k) AS distinct_keys
FROM dcgf_drain_keys(
    '{ "aggregate": "dc_group_first", "hint": "g_b_c", "pipeline": [ { "$sort": { "g": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$g", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 1 } }',
    1) AS k;

SELECT COALESCE(array_agg((missing ->> 'd')::int ORDER BY (missing ->> 'd')::int), '{}') AS dropped_group_keys
FROM (
    SELECT k2 AS missing FROM dcgf_drain_keys(
        '{ "aggregate": "dc_group_first", "hint": "g_b_c", "pipeline": [ { "$sort": { "g": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$g", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 1000 } }', 1000) k2
    EXCEPT
    SELECT k1 FROM dcgf_drain_keys(
        '{ "aggregate": "dc_group_first", "hint": "g_b_c", "pipeline": [ { "$sort": { "g": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$g", "first": { "$first": "$$ROOT" } } } ], "cursor": { "batchSize": 1 } }', 1) k1
) m;

-- The $in + $replaceRoot variant pages the same way (3 group keys).
SELECT total, round_trips, persist FROM dcgf_drain(
    '{ "aggregate": "dc_group_first", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3 ] } } }, { "$sort": { "a": 1, "b": 1, "c": 1 } }, { "$group": { "_id": "$a", "first": { "$first": "$$ROOT" } } }, { "$replaceRoot": { "newRoot": "$first" } } ], "cursor": { "batchSize": 1 } }',
    1);

DROP FUNCTION dcgf_drain(text, int);
DROP FUNCTION dcgf_drain_keys(text, int);

RESET enable_seqscan;
RESET enable_bitmapscan;
