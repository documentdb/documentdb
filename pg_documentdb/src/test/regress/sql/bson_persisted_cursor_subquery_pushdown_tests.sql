-- Tests for subquery pushdown of $match on computed fields when the query uses
-- persisted cursors (i.e. dynamic cursors are disabled). Gated by the
-- enable_subquery_pushdown_for_match_on_persisted_cursors GUC. Verifies explain plan
-- shapes (subquery boundary) and result correctness.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 25860100;
SET documentdb.next_collection_index_id TO 25860100;

-- Persisted cursors: dynamic cursors are explicitly disabled for these tests.
SET documentdb.enableDynamicCursors TO off;

-- Rewrite the aggregation function inline so EXPLAIN exposes the underlying
-- query plan (and thus the Subquery Scan boundary) rather than an opaque
-- Function Scan on bson_aggregation_pipeline.
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enablePrimaryKeyCursorScan TO on;
SET enable_seqscan TO off;

-- ===========================================================================
-- Data setup
-- ===========================================================================
SELECT documentdb_api.drop_collection('pcsub_pushdown_db', 'flights');

SELECT COUNT(documentdb_api.insert_one('pcsub_pushdown_db', 'flights',
    FORMAT('{ "_id": %s, "routeId": %s, "carrier": "%s", "legs": [
        { "code": "A", "dist": %s },
        { "code": "B", "dist": %s }
    ]}',
        i,
        (i % 5) + 1,
        CASE WHEN i % 10 = 0 THEN 'ALPHA' ELSE 'alpha' END,
        i,
        i + 1
    )::documentdb_core.bson))
FROM generate_series(1, 20) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('pcsub_pushdown_db',
    '{"createIndexes": "flights", "indexes": [{"key": {"routeId": 1}, "name": "idx_routeId"}]}', true);

-- Refresh planner statistics scoped to this collection only (compact in
-- updateStats mode runs ANALYZE on the collection's backing table) so the plan
-- shapes below are stable without mutating shared statistics across tests.
SELECT documentdb_api.compact('{"compact": "flights", "$db": "pcsub_pushdown_db", "mode": "updateStats"}');

-- ===========================================================================
-- SECTION A: $project computing a field + $match on the computed field.
-- With enable_subquery_pushdown_for_match_on_persisted_cursors=on, the second $match
-- must trigger a subquery boundary (projection runs before the filter) even
-- though dynamic cursors are disabled.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test A1: Result correctness with the persisted pushdown GUC on
-- ---------------------------------------------------------------------------
SET documentdb.enable_subquery_pushdown_for_match_on_persisted_cursors TO on;

SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');

-- ---------------------------------------------------------------------------
-- Test A2: EXPLAIN — verify a Subquery Scan boundary appears in the plan.
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test A3: With the persisted pushdown GUC off, the pushdown must NOT happen
-- (persisted cursors remain gated). No Subquery Scan boundary should appear.
-- ---------------------------------------------------------------------------
SET documentdb.enable_subquery_pushdown_for_match_on_persisted_cursors TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');
$cmd$);

-- Results should still be correct with the GUC off.
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');

SET documentdb.enable_subquery_pushdown_for_match_on_persisted_cursors TO on;

-- ===========================================================================
-- SECTION B: Portal-backed persisted cursor variant.
-- With file-based cursors disabled, persistConnection must be true because
-- getMore must resume the portal on the same backend connection.
-- routeId:1 matches 4 documents, so batchSize:2 forces a first page + getMore.
-- ===========================================================================

SET documentdb.useFileBasedPersistedCursors TO off;

-- ---------------------------------------------------------------------------
-- Test B1: First page (batchSize 2) over the portal-backed persisted cursor.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE pcsub_portal_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
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
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_portal_first_page;

SELECT continuation AS pcsub_portal_cont FROM pcsub_portal_first_page \gset

-- ---------------------------------------------------------------------------
-- Test B2: getMore drains the remaining documents from the portal.
-- The full 4-document result set must be returned correctly across pages.
-- ---------------------------------------------------------------------------
SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "flights", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_portal_cont');

DROP TABLE pcsub_portal_first_page;

-- ===========================================================================
-- SECTION C: File-based persisted cursor variant.
-- This section drives the file-based drain path across multiple getMore pages.
-- ===========================================================================

SET documentdb.useFileBasedPersistedCursors TO on;

CREATE TEMP TABLE pcsub_file_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
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
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_file_first_page;

SELECT continuation AS pcsub_file_cont FROM pcsub_file_first_page \gset

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "flights", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_file_cont');

SET documentdb.useFileBasedPersistedCursors TO off;
DROP TABLE pcsub_file_first_page;

-- ===========================================================================
-- SECTION D: No-$sort streaming candidate must STAY on a streaming cursor.
-- Sections A-C append a trailing $sort, which forces a persistent cursor, so
-- the computed-field $match pushes the projection into a subquery. This section
-- drops the $sort, so nothing in the pipeline independently requires a
-- persistent cursor and it remains a streaming candidate. The persisted-cursor
-- pushdown must NOT fire here: the added SubqueryScan cannot be streamed over,
-- so pushing it down would force this streaming-eligible pipeline onto a
-- persistent cursor (a regression). This guards that the pushdown is skipped
-- and streaming is preserved: no Subquery Scan boundary in the plan,
-- persistConnection must be false (streaming cursors do not pin the backend),
-- and the two-page getMore must still return the full result set correctly (no
-- duplicated or skipped documents). routeId:1 matches 4 documents (_id 5, 10,
-- 15, 20), so batchSize:2 forces a first page + one getMore.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test D0: EXPLAIN — with the GUC on but no persistence-forcing stage, NO
-- Subquery Scan boundary should appear (the pushdown must be skipped).
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test D1: First page (batchSize 2). The cursor must remain streaming
-- (persistConnection false) rather than being downgraded to persistent.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE pcsub_nosort_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
    database => 'pcsub_pushdown_db',
    commandSpec => '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } }
    ], "cursor": { "batchSize": 2 } }',
    cursorId => 4294967294);

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_nosort_first_page;

SELECT continuation AS pcsub_nosort_cont FROM pcsub_nosort_first_page \gset

-- ---------------------------------------------------------------------------
-- Test D2: getMore drains the remaining documents from the streaming cursor.
-- The full 4-document result set must be returned correctly across pages.
-- ---------------------------------------------------------------------------
SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "flights", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_nosort_cont');
DROP TABLE pcsub_nosort_first_page;

-- ===========================================================================
-- SECTION E: A collation-sensitive match on a projected string retains the
-- command collation through the subquery boundary and persisted cursor pages.
-- routeId:1 matches four documents whose carrier values differ only by case.
-- ===========================================================================

SET documentdb_core.enableCollation TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "carrierName": "$carrier"
        }},
        { "$match": { "carrierName": "ALPHA" } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {},
       "collation": { "locale": "en", "strength": 1 } }');
$cmd$);

CREATE TEMP TABLE pcsub_collation_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
    database => 'pcsub_pushdown_db',
    commandSpec => '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "carrierName": "$carrier"
        }},
        { "$match": { "carrierName": "ALPHA" } },
        { "$sort": { "_id": 1 } }
    ], "cursor": { "batchSize": 2 },
       "collation": { "locale": "en", "strength": 1 } }',
    cursorId => 4294967294);

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_collation_first_page;

SELECT continuation AS pcsub_collation_cont FROM pcsub_collation_first_page \gset

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "flights", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_collation_cont');

DROP TABLE pcsub_collation_first_page;

RESET documentdb_core.enableCollation;

-- ===========================================================================
-- SECTION F: Cursor-kind gating for the persisted-cursor pushdown (GUC on,
-- dynamic cursors off throughout). Two pipelines that differ only in their
-- trailing stage decide whether the pushdown may fire:
--   F1: $match -> $project -> $match -> $project has no persistence-forcing
--       stage, so it stays a STREAMING cursor. The pushdown must be skipped so
--       the streaming plan is preserved (no Subquery Scan boundary,
--       persistConnection false). This is the regression guard: pushing the
--       projection into a subquery here would force streaming onto a
--       persistent cursor.
--   F2: $match -> $project -> $match -> $skip (non-zero) forces a PERSISTENT
--       cursor, so the pushdown fires: the projection is pushed into a subquery
--       (Subquery Scan boundary present) and persistConnection is true.
-- Together they show the gate keys off the fully resolved cursor kind, not just
-- the stages seen before the computed-field $match.
-- routeId:1 matches 4 documents (_id 5, 10, 15, 20).
-- ===========================================================================

SET documentdb.useFileBasedPersistedCursors TO off;

-- ---------------------------------------------------------------------------
-- Test F1a: EXPLAIN — streaming pipeline, NO Subquery Scan boundary (pushdown
-- must be skipped).
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$project": { "_id": 1, "routeId": 1 } }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test F1b: First page (batchSize 2). The cursor must remain streaming
-- (persistConnection false), and the two-page getMore must return all four
-- documents.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE pcsub_stream_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
    database => 'pcsub_pushdown_db',
    commandSpec => '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$project": { "_id": 1, "routeId": 1 } }
    ], "cursor": { "batchSize": 2 } }',
    cursorId => 4294967290);

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_stream_first_page;

SELECT continuation AS pcsub_stream_cont FROM pcsub_stream_first_page \gset

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967290" }, "collection": "flights", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_stream_cont');

DROP TABLE pcsub_stream_first_page;

-- ---------------------------------------------------------------------------
-- Test F2a: EXPLAIN — a non-zero $skip forces a persistent cursor, so the
-- pushdown fires and a Subquery Scan boundary must appear.
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$skip": 1 }
    ], "cursor": {} }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test F2b: First page (batchSize 2). The cursor must be persistent
-- (persistConnection true). $skip:1 drops _id 5, so the drain returns
-- _id 10, 15, 20 across the first page and one getMore.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE pcsub_skip_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
    database => 'pcsub_pushdown_db',
    commandSpec => '{ "aggregate": "flights", "pipeline": [
        { "$match": { "routeId": 1 } },
        { "$project": {
            "_id": 1,
            "routeId": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$skip": 1 }
    ], "cursor": { "batchSize": 2 } }',
    cursorId => 4294967291);

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_skip_first_page;

SELECT continuation AS pcsub_skip_cont FROM pcsub_skip_first_page \gset

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967291" }, "collection": "flights", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_skip_cont');

DROP TABLE pcsub_skip_first_page;

-- ===========================================================================
-- SECTION G: Views resolve their underlying pipeline through a separate
-- stage-extraction pass on the same build context. The persistence look-ahead
-- raises requiresPersistentCursor monotonically, so a persistence-forcing stage
-- in one extraction pass must still enable the computed-field $match pushdown in
-- the other. These cases exercise that cross-extraction propagation, which
-- Sections A-F (single pipeline, single extraction) cannot reach.
-- routeId:1 matches 4 documents (_id 5, 10, 15, 20); legCount = 2 for every doc.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test G1: The forcing stage ($sort) and the computed-field $match both live
-- in the OUTER pipeline over a view whose definition only pre-filters. The view
-- adds a second extraction pass, but the pushdown must still fire (Subquery Scan
-- boundary present) and the cursor must be persistent.
-- ---------------------------------------------------------------------------
SELECT documentdb_api.create_collection_view('pcsub_pushdown_db',
    '{ "create": "flights_route1", "viewOn": "flights",
       "pipeline": [ { "$match": { "routeId": 1 } } ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights_route1", "pipeline": [
        { "$project": {
            "_id": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');
$cmd$);

CREATE TEMP TABLE pcsub_view_outer_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
    database => 'pcsub_pushdown_db',
    commandSpec => '{ "aggregate": "flights_route1", "pipeline": [
        { "$project": {
            "_id": 1,
            "legCount": { "$size": "$legs" }
        }},
        { "$match": { "legCount": { "$gt": 0 } } },
        { "$sort": { "_id": 1 } }
    ], "cursor": { "batchSize": 2 } }',
    cursorId => 4294967289);

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_view_outer_first_page;

SELECT continuation AS pcsub_view_outer_cont FROM pcsub_view_outer_first_page \gset

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967289" }, "collection": "flights_route1", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_view_outer_cont');

DROP TABLE pcsub_view_outer_first_page;

-- ---------------------------------------------------------------------------
-- Test G2: The computed-field $match lives in the VIEW definition while the
-- only persistence-forcing stage ($sort) lives in the OUTER pipeline. The view
-- definition is extracted separately and on its own would stay streaming, so
-- the pushdown here depends entirely on the outer pipeline's look-ahead having
-- already raised requiresPersistentCursor. The Subquery Scan boundary must
-- still appear and the cursor must be persistent. This is the uniquely
-- cross-extraction case: Sections A-F keep the $match and the forcing stage in
-- the same extraction pass.
-- ---------------------------------------------------------------------------
SELECT documentdb_api.create_collection_view('pcsub_pushdown_db',
    '{ "create": "flights_route1_computed", "viewOn": "flights",
       "pipeline": [
           { "$match": { "routeId": 1 } },
           { "$project": {
               "_id": 1,
               "legCount": { "$size": "$legs" }
           }},
           { "$match": { "legCount": { "$gt": 0 } } }
       ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights_route1_computed", "pipeline": [
        { "$sort": { "_id": 1 } }
    ], "cursor": {} }');
$cmd$);

CREATE TEMP TABLE pcsub_view_def_first_page AS
SELECT cursorPage, continuation, persistConnection
FROM documentdb_api.aggregate_cursor_first_page(
    database => 'pcsub_pushdown_db',
    commandSpec => '{ "aggregate": "flights_route1_computed", "pipeline": [
        { "$sort": { "_id": 1 } }
    ], "cursor": { "batchSize": 2 } }',
    cursorId => 4294967288);

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson),
       persistConnection
FROM pcsub_view_def_first_page;

SELECT continuation AS pcsub_view_def_cont FROM pcsub_view_def_first_page \gset

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{ "ok": 1, "cursor.id": 1,
       "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } },
       "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson)
FROM documentdb_api.cursor_get_more(
    database => 'pcsub_pushdown_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967288" }, "collection": "flights_route1_computed", "batchSize": 2 }'::documentdb_core.bson,
    continuationSpec => :'pcsub_view_def_cont');

DROP TABLE pcsub_view_def_first_page;

-- ===========================================================================
-- SECTION H: $limit / $skip argument validation with the pushdown GUC on.
-- Regression guard: the persisted-cursor look-ahead walks the stages to decide
-- persistence before the stages are built. It must not pre-empt the
-- stage-specific validation error for $limit (5107201) / $skip (5107200) when
-- the argument is a numeric value that cannot be expressed as a 64-bit integer
-- (e.g. Decimal128 NaN or out of range). The look-ahead only runs when the GUC
-- is on, so the specific error must be raised identically whether the GUC is
-- on or off.
-- ===========================================================================

-- Baseline: with the GUC off the look-ahead is skipped and the stage handler
-- raises the specific error.
SET documentdb.enable_subquery_pushdown_for_match_on_persisted_cursors TO off;

-- $limit Decimal128 NaN -> 5107201
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$limit": { "$numberDecimal": "NaN" } }
    ], "cursor": {} }');

-- $limit Decimal128 out of 64-bit range -> 5107201
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$limit": { "$numberDecimal": "Infinity" } }
    ], "cursor": {} }');

-- $skip Decimal128 NaN -> 5107200
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$skip": { "$numberDecimal": "NaN" } }
    ], "cursor": {} }');

-- $skip Decimal128 out of 64-bit range -> 5107200
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$skip": { "$numberDecimal": "Infinity" } }
    ], "cursor": {} }');

-- With the GUC on the look-ahead runs first, yet the errors must be identical
-- to the baseline above (same code, same message, same stage).
SET documentdb.enable_subquery_pushdown_for_match_on_persisted_cursors TO on;

-- $limit Decimal128 NaN -> 5107201 (not a generic conversion error)
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$limit": { "$numberDecimal": "NaN" } }
    ], "cursor": {} }');

-- $limit Decimal128 out of 64-bit range -> 5107201
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$limit": { "$numberDecimal": "Infinity" } }
    ], "cursor": {} }');

-- $skip Decimal128 NaN -> 5107200
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$skip": { "$numberDecimal": "NaN" } }
    ], "cursor": {} }');

-- $skip Decimal128 out of 64-bit range -> 5107200
SELECT document FROM bson_aggregation_pipeline('pcsub_pushdown_db',
    '{ "aggregate": "flights", "pipeline": [
        { "$skip": { "$numberDecimal": "Infinity" } }
    ], "cursor": {} }');

SELECT documentdb_api.drop_collection('pcsub_pushdown_db', 'flights_route1');
SELECT documentdb_api.drop_collection('pcsub_pushdown_db', 'flights_route1_computed');

SELECT documentdb_api.drop_collection('pcsub_pushdown_db', 'flights');

RESET search_path;
