-- Tests for dynamic cursor behavior with aggregation pipelines, projections,
-- $lookup joins, and subquery pushdown for $match on computed fields.
-- Verifies cursor drain, explain plan shapes, and GUC-controlled behavior.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 90100;
SET documentdb.next_collection_index_id TO 90100;

SET documentdb.enablePrimaryKeyCursorScan TO on;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableSubqueryPushdownForMatch TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET enable_seqscan TO off;

-- ===========================================================================
-- Data setup: two collections for pipeline and join tests
-- ===========================================================================
SELECT documentdb_api.drop_collection('dcsub_pushdown_db', 'flights');
SELECT documentdb_api.drop_collection('dcsub_pushdown_db', 'airports');

-- flights: 20 docs with line items array for computed-field projection tests
SELECT COUNT(documentdb_api.insert_one('dcsub_pushdown_db', 'flights',
    FORMAT('{ "_id": %s, "routeId": %s, "phase": "%s", "legs": [
        { "code": "A", "dist": %s, "alt": %s },
        { "code": "B", "dist": %s, "alt": %s }
    ]}',
        i,
        (i % 5) + 1,
        CASE WHEN i % 3 = 0 THEN 'arrived' ELSE 'enroute' END,
        i, i * 10,
        i + 1, (i + 1) * 5
    )::documentdb_core.bson))
FROM generate_series(1, 20) AS i;

-- airports: small lookup target
SELECT documentdb_api.insert_one('dcsub_pushdown_db', 'airports', '{ "_id": 1, "code": "A", "city": "JFK" }');
SELECT documentdb_api.insert_one('dcsub_pushdown_db', 'airports', '{ "_id": 2, "code": "B", "city": "LAX" }');
SELECT documentdb_api.insert_one('dcsub_pushdown_db', 'airports', '{ "_id": 3, "code": "C", "city": "ORD" }');

-- Index on routeId for filtered queries
SELECT documentdb_api_internal.create_indexes_non_concurrently('dcsub_pushdown_db',
    '{"createIndexes": "flights", "indexes": [{"key": {"routeId": 1}, "name": "idx_routeId"}]}', true);

-- Index on phase for filtered queries
SELECT documentdb_api_internal.create_indexes_non_concurrently('dcsub_pushdown_db',
    '{"createIndexes": "flights", "indexes": [{"key": {"phase": 1}, "name": "idx_phase"}]}', true);

-- Index on code for lookup
SELECT documentdb_api_internal.create_indexes_non_concurrently('dcsub_pushdown_db',
    '{"createIndexes": "airports", "indexes": [{"key": {"code": 1}, "name": "idx_code"}]}', true);

ANALYZE;

-- ===========================================================================
-- Helper: drain all pages via aggregate_cursor_first_page + cursor_get_more
-- ===========================================================================
CREATE OR REPLACE FUNCTION dcsub_drain_agg(
    p_agg_spec text
) RETURNS TABLE(page_num int, batch_count bigint) AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_persist bool;
    v_batch_count bigint;
    v_page int := 1;
BEGIN
    SELECT fp.cursorPage, fp.continuation, fp.persistconnection
    INTO v_cursor_page, v_continuation, v_persist
    FROM aggregate_cursor_first_page(
        database => 'dcsub_pushdown_db',
        commandSpec => p_agg_spec::documentdb_core.bson,
        cursorId => 539
    ) fp;

    SELECT (bson_dollar_project(v_cursor_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }')
        ->> 'c')::bigint INTO v_batch_count;

    page_num := v_page; batch_count := v_batch_count;
    RETURN NEXT;

    WHILE v_continuation IS NOT NULL LOOP
        v_page := v_page + 1;
        SELECT gm.cursorPage, gm.continuation
        INTO v_cursor_page, v_continuation
        FROM cursor_get_more(
            database => 'dcsub_pushdown_db',
            getMoreSpec => '{ "getMore": { "$numberLong": "539" }, "collection": "flights", "batchSize": 5 }'::documentdb_core.bson,
            continuationSpec => v_continuation
        ) gm;

        SELECT (bson_dollar_project(v_cursor_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
            ->> 'c')::bigint INTO v_batch_count;

        page_num := v_page; batch_count := v_batch_count;
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- ===========================================================================
-- SECTION A: $project + $match on computed fields (subquery pushdown)
-- Pipeline: $match → $project (compute legCount, totalDist) → $match on computed
-- With enableSubqueryPushdownForMatch=on, the second $match should trigger a
-- subquery boundary so projection runs before filter evaluation.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test A1: Result correctness — $project computing array size + $match on it
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" },
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test A2: EXPLAIN — verify SubqueryScan appears in plan (subquery boundary)
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" },
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test A3: Same pipeline with GUC off — no SubqueryScan in plan
-- ---------------------------------------------------------------------------
SET documentdb.enableSubqueryPushdownForMatch TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" },
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": {} }');
$cmd$);

-- Results should still be correct with GUC off
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" },
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": {} }');

SET documentdb.enableSubqueryPushdownForMatch TO on;


-- ===========================================================================
-- SECTION B: Multiple chained streamable stages
-- $project → $project → $match: verifies that chained projections followed
-- by a $match on computed fields all work with subquery pushdown
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test B1: Two projections then match — result correctness
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "phase": "enroute" } },
        { "$project": {
            "_id": 1,
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$project": {
            "_id": 1,
            "totalDist": 1,
            "isLongHaul": { "$cond": [{ "$gte": ["$totalDist", 10] }, true, false] }
        }},
        { "$match": { "isLongHaul": true } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test B2: EXPLAIN for chained projections + match
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "phase": "enroute" } },
        { "$project": {
            "_id": 1,
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$project": {
            "_id": 1,
            "totalDist": 1,
            "isLongHaul": { "$cond": [{ "$gte": ["$totalDist", 10] }, true, false] }
        }},
        { "$match": { "isLongHaul": true } }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test B3: $addFields + $match on computed field
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": { "$lte": 3 } } },
        { "$addFields": {
            "legCount": { "$size": "$legs" },
            "firstCode": { "$arrayElemAt": ["$legs.code", 0] }
        }},
        { "$match": { "legCount": { "$gte": 1 }, "firstCode": "A" } },
        { "$project": { "_id": 1, "routeId": 1, "legCount": 1, "firstCode": 1 } }
    ], "cursor": {} }');


-- ===========================================================================
-- SECTION C: $lookup — subquery pushdown must NOT create subquery boundary
-- when joins are present. Verify correct results and explain plan.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test C1: $lookup + $match on computed field — correctness
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "_id": { "$lte": 3 } } },
        { "$project": { "_id": 1, "firstCode": { "$arrayElemAt": ["$legs.code", 0] } } },
        { "$lookup": { "from": "airports", "localField": "firstCode", "foreignField": "code", "as": "airport" } },
        { "$project": { "_id": 1, "firstCode": 1, "airportCity": { "$arrayElemAt": ["$airport.city", 0] } } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test C2: EXPLAIN for $lookup pipeline — verify no SubqueryScan wrapping
-- the $match + $project before the join. The join itself produces a Nested Loop.
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "_id": { "$lte": 3 } } },
        { "$project": { "_id": 1, "firstCode": { "$arrayElemAt": ["$legs.code", 0] } } },
        { "$lookup": { "from": "airports", "localField": "firstCode", "foreignField": "code", "as": "airport" } },
        { "$project": { "_id": 1, "firstCode": 1, "airportCity": { "$arrayElemAt": ["$airport.city", 0] } } }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test C3: $lookup with pipeline sub-pipeline + $match after — no subquery
-- pushdown because join is present
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "_id": { "$lte": 2 } } },
        { "$lookup": {
            "from": "airports",
            "pipeline": [{ "$match": { "code": "A" } }],
            "as": "matchedAirports"
        }},
        { "$project": {
            "_id": 1,
            "matchedCount": { "$size": "$matchedAirports" }
        }},
        { "$match": { "matchedCount": { "$gt": 0 } } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test C4: EXPLAIN for $lookup with sub-pipeline + $match
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "_id": { "$lte": 2 } } },
        { "$lookup": {
            "from": "airports",
            "pipeline": [{ "$match": { "code": "A" } }],
            "as": "matchedAirports"
        }},
        { "$project": {
            "_id": 1,
            "matchedCount": { "$size": "$matchedAirports" }
        }},
        { "$match": { "matchedCount": { "$gt": 0 } } }
    ], "cursor": {} }');
$cmd$);


-- ===========================================================================
-- SECTION D: Cursor drain with subquery pushdown
-- Verify that cursors correctly drain all pages when subquery pushdown
-- introduces a SubqueryScan boundary in the plan.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test D1: Drain via aggregate cursor — $project + $match with batchSize=5
-- All 20 flights have legCount=2, so all should be returned
-- ---------------------------------------------------------------------------
SELECT * FROM dcsub_drain_agg(
    '{ "aggregate": "flights", "pipeline": [
        { "$project": {
            "_id": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": { "batchSize": 5 } }');

-- ---------------------------------------------------------------------------
-- Test D2: Drain with filter narrowing results — only routeId=1 (4 docs)
-- ---------------------------------------------------------------------------
SELECT * FROM dcsub_drain_agg(
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "legCount": { "$size": "$legs" },
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": { "batchSize": 2 } }');

-- ---------------------------------------------------------------------------
-- Test D3: Drain with chained projections + match
-- ---------------------------------------------------------------------------
SELECT * FROM dcsub_drain_agg(
    '{ "aggregate": "flights", "pipeline": [
        { "$project": {
            "_id": 1,
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$project": {
            "_id": 1,
            "totalDist": 1,
            "isLongHaul": { "$cond": [{ "$gte": ["$totalDist", 10] }, true, false] }
        }},
        { "$match": { "isLongHaul": true } }
    ], "cursor": { "batchSize": 3 } }');

-- ---------------------------------------------------------------------------
-- Test D4: Drain with GUC off — should still return correct results
-- ---------------------------------------------------------------------------
SET documentdb.enableSubqueryPushdownForMatch TO off;

SELECT * FROM dcsub_drain_agg(
    '{ "aggregate": "flights", "pipeline": [
        { "$project": {
            "_id": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": { "batchSize": 5 } }');

SET documentdb.enableSubqueryPushdownForMatch TO on;


-- ===========================================================================
-- SECTION E: EXPLAIN ANALYZE with cursor first page and getMore
-- Validates the plan shape changes between subquery pushdown on/off
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test E1: EXPLAIN ANALYZE for aggregate first page with subquery pushdown
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
        '{ "aggregate": "flights", "pipeline": [
            { "$match": { "routeId": 1 } },
            { "$project": {
                "_id": 1,
                "legCount": { "$size": "$legs" }
            }},
            { "$match": { "legCount": { "$gt": 0 } } }
        ], "cursor": { "batchSize": 5 } }');
$cmd$, true);

-- ---------------------------------------------------------------------------
-- Test E2: Same EXPLAIN ANALYZE with GUC off
-- ---------------------------------------------------------------------------
SET documentdb.enableSubqueryPushdownForMatch TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
        '{ "aggregate": "flights", "pipeline": [
            { "$match": { "routeId": 1 } },
            { "$project": {
                "_id": 1,
                "legCount": { "$size": "$legs" }
            }},
            { "$match": { "legCount": { "$gt": 0 } } }
        ], "cursor": { "batchSize": 5 } }');
$cmd$, true);

SET documentdb.enableSubqueryPushdownForMatch TO on;


-- ===========================================================================
-- SECTION F: $_internalInhibitOptimization — verify it prevents the
-- $match from being merged into the cursor stage
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test F1: With inhibit optimization — result correctness
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$_internalInhibitOptimization": {} },
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test F2: EXPLAIN with inhibit optimization — match stays as separate stage
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$_internalInhibitOptimization": {} },
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": {} }');
$cmd$);


-- ===========================================================================
-- SECTION G: $group + $match on grouped fields — subquery pushdown applies
-- after non-join stages that produce new fields
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test G1: $group by routeId + $match on count
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$group": {
            "_id": "$routeId",
            "flightCount": { "$sum": 1 },
            "totalLegs": { "$sum": { "$size": "$legs" } }
        }},
        { "$match": { "flightCount": { "$gte": 4 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test G2: EXPLAIN for $group + $match
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$group": {
            "_id": "$routeId",
            "flightCount": { "$sum": 1 },
            "totalLegs": { "$sum": { "$size": "$legs" } }
        }},
        { "$match": { "flightCount": { "$gte": 4 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');
$cmd$);


-- ===========================================================================
-- SECTION H: $unwind + $match — streamable stage chain
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test H1: $unwind items + $match on unwound field
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "_id": { "$lte": 3 } } },
        { "$unwind": "$legs" },
        { "$match": { "items.code": "A" } },
        { "$project": { "_id": 1, "code": "$legs.code", "dist": "$legs.dist" } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test H2: EXPLAIN for $unwind + $match
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "_id": { "$lte": 3 } } },
        { "$unwind": "$legs" },
        { "$match": { "items.code": "A" } },
        { "$project": { "_id": 1, "code": "$legs.code", "dist": "$legs.dist" } }
    ], "cursor": {} }');
$cmd$);


-- ===========================================================================
-- SECTION I: Exhaustive row-correctness for $match → $project → $project → $match
-- Validates that every qualifying row is returned and no row is lost when the
-- bottom $match is pushed to an index and the top $match filters on computed
-- fields through two chained projections with subquery pushdown.
-- ===========================================================================

-- Use a separate collection with carefully constructed data so every row's
-- fate (included vs excluded) is deterministic and verifiable.
SELECT documentdb_api.drop_collection('dcsub_pushdown_db', 'aircraft');

-- 30 documents: _id 1..30
--   category: cycles through A, B, C  (i%3)
--   score: i * 10  (10, 20, ..., 300)
--   tags: array of length (i % 4) → 0, 1, 2, or 3 elements
-- This gives a mix of tagCount=0 (should be excluded by top $match) and
-- tagCount>0 (should be included), with varying scores for the ratio computation.
SELECT COUNT(documentdb_api.insert_one('dcsub_pushdown_db', 'aircraft',
    FORMAT('{ "_id": %s, "class": "%s", "range": %s, "features": [%s] }',
        i,
        CASE i % 3 WHEN 0 THEN 'A' WHEN 1 THEN 'B' ELSE 'C' END,
        i * 10,
        CASE i % 4
            WHEN 0 THEN ''
            WHEN 1 THEN '"t1"'
            WHEN 2 THEN '"t1", "t2"'
            ELSE '"t1", "t2", "t3"'
        END
    )::documentdb_core.bson))
FROM generate_series(1, 30) AS i;

-- Compound index on (category, score) — first $match can be pushed to index
SELECT documentdb_api_internal.create_indexes_non_concurrently('dcsub_pushdown_db',
    '{"createIndexes": "aircraft", "indexes": [{"key": {"class": 1, "range": 1}, "name": "idx_class_range"}]}', true);

ANALYZE;

-- ---------------------------------------------------------------------------
-- Test I1: Full pipeline $match → $project → $project → $match
-- First $match: category = "A" (i%3==0: docs 3,6,9,12,15,18,21,24,27,30 → 10 docs)
-- First $project: compute tagCount = $size(tags), normalizedScore = score/100
-- Second $project: compute hasData = (tagCount > 0 ? true : false)
-- Second $match: hasData = true AND normalizedScore >= 0.5
--
-- Expected: category="A" docs with tagCount>0 AND score>=50
-- Doc  3: i%4=3 → tags=3 items, score=30, normScore=0.3 → EXCLUDED (normScore < 0.5)
-- Doc  6: i%4=2 → tags=2 items, score=60, normScore=0.6 → INCLUDED
-- Doc  9: i%4=1 → tags=1 item,  score=90, normScore=0.9 → INCLUDED
-- Doc 12: i%4=0 → tags=0 items                          → EXCLUDED (hasData=false)
-- Doc 15: i%4=3 → tags=3 items, score=150, normScore=1.5 → INCLUDED
-- Doc 18: i%4=2 → tags=2 items, score=180, normScore=1.8 → INCLUDED
-- Doc 21: i%4=1 → tags=1 item,  score=210, normScore=2.1 → INCLUDED
-- Doc 24: i%4=0 → tags=0 items                          → EXCLUDED (hasData=false)
-- Doc 27: i%4=3 → tags=3 items, score=270, normScore=2.7 → INCLUDED
-- Doc 30: i%4=2 → tags=2 items, score=300, normScore=3.0 → INCLUDED
-- Total expected: 7 docs (ids 6, 9, 15, 18, 21, 27, 30)
-- ---------------------------------------------------------------------------

-- GUC ON: subquery pushdown active
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "A" } },
        { "$project": {
            "_id": 1,
            "range": 1,
            "tagCount": { "$size": "$features" },
            "normalizedScore": { "$divide": ["$range", 100] }
        }},
        { "$project": {
            "_id": 1,
            "range": 1,
            "tagCount": 1,
            "normalizedScore": 1,
            "hasData": { "$cond": [{ "$gt": ["$tagCount", 0] }, true, false] }
        }},
        { "$match": { "hasData": true, "normalizedScore": { "$gte": 0.5 } } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test I2: Same pipeline with GUC OFF — verify identical results
-- ---------------------------------------------------------------------------
SET documentdb.enableSubqueryPushdownForMatch TO off;

SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "A" } },
        { "$project": {
            "_id": 1,
            "range": 1,
            "tagCount": { "$size": "$features" },
            "normalizedScore": { "$divide": ["$range", 100] }
        }},
        { "$project": {
            "_id": 1,
            "range": 1,
            "tagCount": 1,
            "normalizedScore": 1,
            "hasData": { "$cond": [{ "$gt": ["$tagCount", 0] }, true, false] }
        }},
        { "$match": { "hasData": true, "normalizedScore": { "$gte": 0.5 } } }
    ], "cursor": {} }');

SET documentdb.enableSubqueryPushdownForMatch TO on;

-- ---------------------------------------------------------------------------
-- Test I3: EXPLAIN to confirm first $match uses index, subquery boundary exists
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "A" } },
        { "$project": {
            "_id": 1,
            "range": 1,
            "tagCount": { "$size": "$features" },
            "normalizedScore": { "$divide": ["$range", 100] }
        }},
        { "$project": {
            "_id": 1,
            "range": 1,
            "tagCount": 1,
            "normalizedScore": 1,
            "hasData": { "$cond": [{ "$gt": ["$tagCount", 0] }, true, false] }
        }},
        { "$match": { "hasData": true, "normalizedScore": { "$gte": 0.5 } } }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test I4: All categories, top $match keeps only tagCount > 0
-- No bottom index filter — ensures subquery pushdown works without index push.
-- i%4==0 docs have 0 tags: ids 4,8,12,16,20,24,28 (7 docs excluded)
-- normalizedScore >= 1.0 → score >= 100 → _id >= 10
-- So: _id 10..30 with tagCount > 0 = exclude 12,16,20,24,28 = 16 docs
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "aircraft", "pipeline": [
        { "$project": {
            "_id": 1,
            "tagCount": { "$size": "$features" },
            "normalizedScore": { "$divide": ["$range", 100] }
        }},
        { "$project": {
            "_id": 1,
            "tagCount": 1,
            "normalizedScore": 1,
            "hasData": { "$cond": [{ "$gt": ["$tagCount", 0] }, true, false] }
        }},
        { "$match": { "hasData": true, "normalizedScore": { "$gte": 1.0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test I5: Cursor drain for $match → $project → $project → $match
-- batchSize=2 to force multiple pages, verify total row count across all pages
-- ---------------------------------------------------------------------------
SELECT * FROM dcsub_drain_agg(
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "A" } },
        { "$project": {
            "_id": 1,
            "tagCount": { "$size": "$features" },
            "normalizedScore": { "$divide": ["$range", 100] }
        }},
        { "$project": {
            "_id": 1,
            "tagCount": 1,
            "normalizedScore": 1,
            "hasData": { "$cond": [{ "$gt": ["$tagCount", 0] }, true, false] }
        }},
        { "$match": { "hasData": true, "normalizedScore": { "$gte": 0.5 } } }
    ], "cursor": { "batchSize": 2 } }');

-- ---------------------------------------------------------------------------
-- Test I6: Cursor drain with GUC off — same pipeline, verify same total
-- ---------------------------------------------------------------------------
SET documentdb.enableSubqueryPushdownForMatch TO off;

SELECT * FROM dcsub_drain_agg(
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "A" } },
        { "$project": {
            "_id": 1,
            "tagCount": { "$size": "$features" },
            "normalizedScore": { "$divide": ["$range", 100] }
        }},
        { "$project": {
            "_id": 1,
            "tagCount": 1,
            "normalizedScore": 1,
            "hasData": { "$cond": [{ "$gt": ["$tagCount", 0] }, true, false] }
        }},
        { "$match": { "hasData": true, "normalizedScore": { "$gte": 0.5 } } }
    ], "cursor": { "batchSize": 2 } }');

SET documentdb.enableSubqueryPushdownForMatch TO on;

-- ---------------------------------------------------------------------------
-- Test I7: Edge case — top $match excludes ALL rows (tagCount > 100)
-- Verify 0 rows returned, no crash
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "A" } },
        { "$project": {
            "_id": 1,
            "tagCount": { "$size": "$features" }
        }},
        { "$project": {
            "_id": 1,
            "tagCount": 1,
            "hasMany": { "$cond": [{ "$gt": ["$tagCount", 100] }, true, false] }
        }},
        { "$match": { "hasMany": true } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test I8: Edge case — top $match includes ALL rows (tagCount >= 0)
-- All 10 category="A" docs should be returned
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "A" } },
        { "$project": {
            "_id": 1,
            "tagCount": { "$size": "$features" }
        }},
        { "$project": {
            "_id": 1,
            "tagCount": 1,
            "hasAny": { "$cond": [{ "$gte": ["$tagCount", 0] }, true, false] }
        }},
        { "$match": { "hasAny": true } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test I9: $or in top $match — compound filter on computed fields
-- Include docs where tagCount=0 OR normalizedScore >= 2.0
-- category="B" docs: 1,4,7,10,13,16,19,22,25,28
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "aircraft", "pipeline": [
        { "$match": { "class": "B" } },
        { "$project": {
            "_id": 1,
            "tagCount": { "$size": "$features" },
            "normalizedScore": { "$divide": ["$range", 100] }
        }},
        { "$project": {
            "_id": 1,
            "tagCount": 1,
            "normalizedScore": 1,
            "flag": { "$cond": [{ "$gt": ["$tagCount", 0] }, "has_tags", "no_tags"] }
        }},
        { "$match": {
            "$or": [
                { "flag": "no_tags" },
                { "normalizedScore": { "$gte": 2.0 } }
            ]
        }}
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test I10: EXPLAIN ANALYZE with $match → $project → $project → $match
-- Verify actual row counts in plan match expected
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
        '{ "aggregate": "aircraft", "pipeline": [
            { "$match": { "class": "A" } },
            { "$project": {
                "_id": 1,
                "tagCount": { "$size": "$features" },
                "normalizedScore": { "$divide": ["$range", 100] }
            }},
            { "$project": {
                "_id": 1,
                "tagCount": 1,
                "normalizedScore": 1,
                "hasData": { "$cond": [{ "$gt": ["$tagCount", 0] }, true, false] }
            }},
            { "$match": { "hasData": true, "normalizedScore": { "$gte": 0.5 } } }
        ], "cursor": {} }');
$cmd$, true);

-- Cleanup section I collection
SELECT documentdb_api.drop_collection('dcsub_pushdown_db', 'aircraft');


-- ===========================================================================
-- SECTION J: $match → $project → $match → $project → $match
-- Verifies that with multiple subquery boundaries from subquery pushdown,
-- the query still uses a secondary index scan, produces correct results,
-- and correctly drains all pages. Documents the cursor behavior (persistent
-- vs streaming) with nested subquery scan boundaries.
-- ===========================================================================

-- Helper: drain aggregate cursor and report cursor type info
CREATE OR REPLACE FUNCTION dcsub_drain_agg_cursortype(
    p_agg_spec text,
    p_collection text,
    p_batch_size int DEFAULT 3
) RETURNS TABLE(page_num int, batch_count bigint, cursor_type int, is_persistent bool) AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_persist bool;
    v_batch_count bigint;
    v_cursor_type int;
    v_page int := 1;
    v_getmore_spec text;
BEGIN
    v_getmore_spec := FORMAT('{ "getMore": { "$numberLong": "541" }, "collection": "%s", "batchSize": %s }',
        p_collection, p_batch_size);

    SELECT fp.cursorPage, fp.continuation, fp.persistconnection
    INTO v_cursor_page, v_continuation, v_persist
    FROM aggregate_cursor_first_page(
        database => 'dcsub_pushdown_db',
        commandSpec => p_agg_spec::documentdb_core.bson,
        cursorId => 541
    ) fp;

    SELECT (bson_dollar_project(v_cursor_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }')
        ->> 'c')::bigint INTO v_batch_count;

    IF v_continuation IS NOT NULL THEN
        SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO v_cursor_type;
    ELSE
        v_cursor_type := -1;
    END IF;

    page_num := v_page; batch_count := v_batch_count;
    cursor_type := COALESCE(v_cursor_type, -1); is_persistent := v_persist;
    RETURN NEXT;

    WHILE v_continuation IS NOT NULL LOOP
        v_page := v_page + 1;
        SELECT gm.cursorPage, gm.continuation
        INTO v_cursor_page, v_continuation
        FROM cursor_get_more(
            database => 'dcsub_pushdown_db',
            getMoreSpec => v_getmore_spec::documentdb_core.bson,
            continuationSpec => v_continuation
        ) gm;

        SELECT (bson_dollar_project(v_cursor_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
            ->> 'c')::bigint INTO v_batch_count;

        IF v_continuation IS NOT NULL THEN
            SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
                INTO v_cursor_type;
        ELSE
            v_cursor_type := -1;
        END IF;

        page_num := v_page; batch_count := v_batch_count;
        cursor_type := COALESCE(v_cursor_type, -1); is_persistent := v_persist;
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Test J1: EXPLAIN — $match → $project → $match → $project → $match
-- Verify plan uses secondary Index Scan with Subquery Scan boundaries
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": { "$lte": 4 } } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" },
            "totalCost": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": { "$multiply": ["$$it.dist", "$$it.alt"] } } } }
        }},
        { "$match": { "legCount": { "$gte": 1 } } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "totalCost": 1,
            "isExpensive": { "$cond": [{ "$gte": ["$totalCost", 100] }, true, false] }
        }},
        { "$match": { "isExpensive": true } }
    ], "cursor": { "batchSize": 3 } }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test J2: Result correctness for $match → $project → $match → $project → $match
-- routeId <= 4: docs where (i%5)+1 <= 4, i.e. i%5 in {0,1,2,3} → excludes ids 4,9,14,19
-- legCount >= 1: all docs have 2 items → all pass
-- isExpensive (totalCost >= 100): totalCost = i*(i*10) + (i+1)*((i+1)*5)
-- ---------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": { "$lte": 4 } } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" },
            "totalCost": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": { "$multiply": ["$$it.dist", "$$it.alt"] } } } }
        }},
        { "$match": { "legCount": { "$gte": 1 } } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "totalCost": 1,
            "isExpensive": { "$cond": [{ "$gte": ["$totalCost", 100] }, true, false] }
        }},
        { "$match": { "isExpensive": true } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test J3: Cursor drain — verify all pages drain correctly and report cursor type
-- With multiple subquery scan boundaries, cursor uses persistent mode.
-- ---------------------------------------------------------------------------
SELECT * FROM dcsub_drain_agg_cursortype(
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": { "$lte": 4 } } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" },
            "totalCost": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": { "$multiply": ["$$it.dist", "$$it.alt"] } } } }
        }},
        { "$match": { "legCount": { "$gte": 1 } } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "totalCost": 1,
            "isExpensive": { "$cond": [{ "$gte": ["$totalCost", 100] }, true, false] }
        }},
        { "$match": { "isExpensive": true } }
    ], "cursor": { "batchSize": 3 } }',
    'flights', 3);

-- ---------------------------------------------------------------------------
-- Test J4: EXPLAIN ANALYZE — confirm actual row counts with subquery pushdown
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
        '{ "aggregate": "flights", "pipeline": [
            { "$match": { "routeId": { "$lte": 4 } } },
            { "$project": {
                "_id": 1,
                "routeId": 1,
                "legCount": { "$size": "$legs" },
                "totalCost": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": { "$multiply": ["$$it.dist", "$$it.alt"] } } } }
            }},
            { "$match": { "legCount": { "$gte": 1 } } },
            { "$project": {
                "_id": 1,
                "routeId": 1,
                "totalCost": 1,
                "isExpensive": { "$cond": [{ "$gte": ["$totalCost", 100] }, true, false] }
            }},
            { "$match": { "isExpensive": true } }
        ], "cursor": { "batchSize": 3 } }');
$cmd$, true);

-- ---------------------------------------------------------------------------
-- Test J5: Second pipeline variant with status index
-- $match(status) → $project → $match → $project → $match
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "phase": "arrived" } },
        { "$project": {
            "_id": 1,
            "phase": 1,
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "totalDist": { "$gte": 5 } } },
        { "$project": {
            "_id": 1,
            "totalDist": 1,
            "label": { "$cond": [{ "$gte": ["$totalDist", 20] }, "large", "medium"] }
        }},
        { "$match": { "label": "large" } },
        { "$sort": { "_id": 1 } }
    ], "cursor": { "batchSize": 5 } }');
$cmd$);

-- Results for J5
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "phase": "arrived" } },
        { "$project": {
            "_id": 1,
            "phase": 1,
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "totalDist": { "$gte": 5 } } },
        { "$project": {
            "_id": 1,
            "totalDist": 1,
            "label": { "$cond": [{ "$gte": ["$totalDist", 20] }, "large", "medium"] }
        }},
        { "$match": { "label": "large" } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test J6: Cursor drain for J5
-- ---------------------------------------------------------------------------
SELECT * FROM dcsub_drain_agg_cursortype(
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "phase": "arrived" } },
        { "$project": {
            "_id": 1,
            "phase": 1,
            "totalDist": { "$sum": { "$map": { "input": "$legs", "as": "it", "in": "$$it.dist" } } }
        }},
        { "$match": { "totalDist": { "$gte": 5 } } },
        { "$project": {
            "_id": 1,
            "totalDist": 1,
            "label": { "$cond": [{ "$gte": ["$totalDist", 20] }, "large", "medium"] }
        }},
        { "$match": { "label": "large" } },
        { "$sort": { "_id": 1 } }
    ], "cursor": { "batchSize": 2 } }',
    'flights', 2);

-- Cleanup J helper
DROP FUNCTION IF EXISTS dcsub_drain_agg_cursortype(text, text, int);


-- ===========================================================================
-- SECTION K: $project → $match → $group → $replaceRoot → $project pipeline
-- Tests a complex multi-stage pipeline with subquery pushdown and dynamic cursors.
-- ===========================================================================

-- Test K1: Correctness — project, match, group, replaceRoot, project
-- Compute legCount, filter by phase, group by routeId summing legCount,
-- replaceRoot to flatten, then project a label.
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$project": { "routeId": 1, "phase": 1, "legCount": { "$size": "$legs" } } },
        { "$match": { "phase": "enroute" } },
        { "$group": { "_id": "$routeId", "totalLegs": { "$sum": "$legCount" } } },
        { "$replaceRoot": { "newRoot": { "route": "$_id", "totalLegs": "$totalLegs" } } },
        { "$project": { "route": 1, "totalLegs": 1, "isHeavy": { "$gte": ["$totalLegs", 4] } } },
        { "$sort": { "route": 1 } }
    ], "cursor": {} }');

-- Test K2: EXPLAIN — verify plan shape with subquery pushdown
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$project": { "routeId": 1, "phase": 1, "legCount": { "$size": "$legs" } } },
        { "$match": { "phase": "enroute" } },
        { "$group": { "_id": "$routeId", "totalLegs": { "$sum": "$legCount" } } },
        { "$replaceRoot": { "newRoot": { "route": "$_id", "totalLegs": "$totalLegs" } } },
        { "$project": { "route": 1, "totalLegs": 1, "isHeavy": { "$gte": ["$totalLegs", 4] } } },
        { "$sort": { "route": 1 } }
    ], "cursor": {} }');

-- Test K3: With a trailing $match after $replaceRoot + $project
-- Ensures rows are not lost when match follows replaceRoot
SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$project": { "routeId": 1, "phase": 1, "legCount": { "$size": "$legs" } } },
        { "$match": { "phase": "enroute" } },
        { "$group": { "_id": "$routeId", "totalLegs": { "$sum": "$legCount" } } },
        { "$replaceRoot": { "newRoot": { "route": "$_id", "totalLegs": "$totalLegs" } } },
        { "$project": { "route": 1, "totalLegs": 1, "isHeavy": { "$gte": ["$totalLegs", 4] } } },
        { "$match": { "isHeavy": true } },
        { "$sort": { "route": 1 } }
    ], "cursor": {} }');

-- Test K4: EXPLAIN for the pipeline with trailing $match
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('dcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$project": { "routeId": 1, "phase": 1, "legCount": { "$size": "$legs" } } },
        { "$match": { "phase": "enroute" } },
        { "$group": { "_id": "$routeId", "totalLegs": { "$sum": "$legCount" } } },
        { "$replaceRoot": { "newRoot": { "route": "$_id", "totalLegs": "$totalLegs" } } },
        { "$project": { "route": 1, "totalLegs": 1, "isHeavy": { "$gte": ["$totalLegs", 4] } } },
        { "$match": { "isHeavy": true } },
        { "$sort": { "route": 1 } }
    ], "cursor": {} }');


-- ===========================================================================
-- Cleanup
-- ===========================================================================
DROP FUNCTION IF EXISTS dcsub_drain_agg(text);
SELECT documentdb_api.drop_collection('dcsub_pushdown_db', 'flights');
SELECT documentdb_api.drop_collection('dcsub_pushdown_db', 'airports');
