SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 9400;
SET documentdb.next_collection_index_id TO 9400;

-- Enable dynamic cursors with PK cursor scan (default on)
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;

-- Insert 1000 rows
SELECT COUNT(documentdb_api.insert_one('dyncursor_drain_db', 'drain_scans', FORMAT('{ "_id": %s, "a": %s, "b": %s, "c": "%s" }', i, i / 2, i, repeat('x', 200) || (i % 2 ))::documentdb_core.bson)) FROM generate_series(1, 1000) i;

-- Create a secondary index on "a" with ordered index support for index-only scan paths
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursor_drain_db',
    '{ "createIndexes": "drain_scans", "indexes": [ { "key": { "a": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "a_1" } ] }',
    true
);

ANALYZE;

-- ===========================================================================
-- EXPLAIN ANALYZE tests: verify plan shapes for index scan and index only scan
-- at representative batch sizes (5, 25, 50)
-- ===========================================================================

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ---------------------------------------------------------------------------
-- Index scan (projection includes _id): batchSize=5
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 5 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp;

-- ---------------------------------------------------------------------------
-- Index scan (projection includes _id): batchSize=25
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": 25 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": 25 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 25 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp;

-- ---------------------------------------------------------------------------
-- Index scan (projection includes _id): batchSize=50
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": 50 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": 50 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 50 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp;

-- ---------------------------------------------------------------------------
-- Index scan (projection includes _id): batchSize=5 with scans disabled
-- Disable seqscan, bitmapscan, indexscan before getMore to verify the
-- cursor still drains via the dynamic cursor continuation path
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE drain_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp \gset

SET enable_bitmapscan TO off;
SET enable_indexscan TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 5 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);

SET enable_bitmapscan TO on;
SET enable_indexscan TO on;
DROP TABLE drain_explain_resp;

-- ---------------------------------------------------------------------------
-- Index only scan (projection excludes _id): batchSize=5
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": 5 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": 5 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 5 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp;

-- ---------------------------------------------------------------------------
-- Index only scan (projection excludes _id): batchSize=25
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": 25 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": 25 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 25 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp;

-- ---------------------------------------------------------------------------
-- Index only scan (projection excludes _id): batchSize=50
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": 50 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": 50 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 50 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- Helper: drain a find query and return total row count across all batches
-- Uses recursive CTE to fetch all pages via find_cursor_first_page + cursor_get_more
-- Also validates that dc.type in the continuation matches the expected scan type
-- ===========================================================================
CREATE OR REPLACE FUNCTION drain_cursor_count(
    p_find_spec text,
    p_getmore_spec text,
    p_expected_cursor_type int,
    p_batch_size int,
    p_expected_count int
) RETURNS bigint AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_total_count bigint := 0;
    v_batch_count bigint;
    v_cursor_type int;
    v_round_trips int := 0;
    v_expected_round_trips int;
BEGIN
    -- First page
    SELECT cursorPage, continuation
    INTO v_cursor_page, v_continuation
    FROM find_cursor_first_page(
        database => 'dyncursor_drain_db',
        commandSpec => p_find_spec::documentdb_core.bson,
        cursorId => 536
    );
    v_round_trips := v_round_trips + 1;

    SELECT bson_dollar_project(v_cursor_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }')
        ->> 'c' INTO v_batch_count;
    v_total_count := v_total_count + COALESCE(v_batch_count, 0);

    -- Validate cursor type from first continuation
    IF v_continuation IS NOT NULL THEN
        SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO v_cursor_type;
        IF v_cursor_type IS DISTINCT FROM p_expected_cursor_type THEN
            RAISE EXCEPTION 'Expected cursor type %, got % on first page', p_expected_cursor_type, v_cursor_type;
        END IF;
    END IF;

    -- Iterate getMore until no continuation
    WHILE v_continuation IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation
        INTO v_cursor_page, v_continuation
        FROM cursor_get_more(
            database => 'dyncursor_drain_db',
            getMoreSpec => p_getmore_spec::documentdb_core.bson,
            continuationSpec => v_continuation
        ) gm;
        v_round_trips := v_round_trips + 1;

        SELECT bson_dollar_project(v_cursor_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
            ->> 'c' INTO v_batch_count;
        v_total_count := v_total_count + COALESCE(v_batch_count, 0);

        -- Validate cursor type on every continuation
        IF v_continuation IS NOT NULL THEN
            SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
                INTO v_cursor_type;
            IF v_cursor_type IS DISTINCT FROM p_expected_cursor_type THEN
                RAISE EXCEPTION 'Expected cursor type %, got % on getMore', p_expected_cursor_type, v_cursor_type;
            END IF;
        END IF;
    END LOOP;

    -- Assert minimum round trips
    v_expected_round_trips := GREATEST(CEIL(p_expected_count::float / p_batch_size), 1);
    IF v_round_trips < v_expected_round_trips THEN
        RAISE EXCEPTION 'Expected at least % round trips for batchSize=% and % rows, got %',
            v_expected_round_trips, p_batch_size, p_expected_count, v_round_trips;
    END IF;

    RETURN v_total_count;
END;
$$ LANGUAGE plpgsql;

-- ===========================================================================
-- Test 1: Secondary index scan - projection includes _id
-- Projection { "_id": 1, "a": 1 } triggers a secondary index scan (type 3)
-- Verify that for all batch sizes 1..1001, all 1000 rows are returned
-- ===========================================================================
DO $$
DECLARE
    v_bs int;
    v_count bigint;
BEGIN
    FOR v_bs IN 1..1001 LOOP
        SELECT drain_cursor_count(
            FORMAT('{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": %s }', v_bs),
            FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
            3,    -- expected cursor type: index scan
            v_bs, -- batch size
            1000  -- expected row count
        ) INTO v_count;

        IF v_count <> 1000 THEN
            RAISE EXCEPTION 'Secondary index scan: batchSize=% returned % rows instead of 1000', v_bs, v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Secondary index scan: all batch sizes 1..1001 returned 1000 rows';
END;
$$;

-- ===========================================================================
-- Test 2: Index only scan - projection excludes _id
-- Projection { "_id": 0, "a": 1 } triggers an index only scan (type 7)
-- Verify that for all batch sizes 1..1001, all 1000 rows are returned
-- ===========================================================================
DO $$
DECLARE
    v_bs int;
    v_count bigint;
BEGIN
    FOR v_bs IN 1..1001 LOOP
        SELECT drain_cursor_count(
            FORMAT('{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": %s }', v_bs),
            FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
            7,    -- expected cursor type: index only scan
            v_bs, -- batch size
            1000  -- expected row count
        ) INTO v_count;

        IF v_count <> 1000 THEN
            RAISE EXCEPTION 'Index only scan: batchSize=% returned % rows instead of 1000', v_bs, v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Index only scan: all batch sizes 1..1001 returned 1000 rows';
END;
$$;

-- Clean up helper function
DROP FUNCTION drain_cursor_count(text, text, int, int, int);

-- ===========================================================================
-- Helper: drain a find query, assert cursor type and round trips, return total row count
-- Uses dynamic SQL (EXECUTE) to avoid PL/pgSQL plan caching issues that
-- cause incorrect scan type selection across different projections.
-- ===========================================================================
CREATE OR REPLACE FUNCTION drain_cursor_checked(
    p_find_spec text,
    p_getmore_spec text,
    p_expected_cursor_type int,
    p_batch_size int,
    p_expected_count int,
    p_disable_scans bool DEFAULT false
) RETURNS bigint AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_total_count bigint := 0;
    v_batch_count bigint;
    v_cursor_type int;
    v_round_trips int := 0;
    v_expected_round_trips int;
BEGIN
    EXECUTE 'SELECT cursorPage, continuation FROM find_cursor_first_page(
        database => ''dyncursor_drain_db'',
        commandSpec => $1::documentdb_core.bson,
        cursorId => 536
    )' INTO v_cursor_page, v_continuation USING p_find_spec;
    v_round_trips := v_round_trips + 1;

    SELECT bson_dollar_project(v_cursor_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }')
        ->> 'c' INTO v_batch_count;
    v_total_count := v_total_count + COALESCE(v_batch_count, 0);

    IF v_continuation IS NOT NULL THEN
        SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO v_cursor_type;
        IF v_cursor_type IS DISTINCT FROM p_expected_cursor_type THEN
            IF p_expected_cursor_type = 3 AND v_cursor_type = 7 THEN
                RAISE NOTICE 'INVESTIGATE: expected IXS (3) but got IOS (7) on first page. find_spec: %', p_find_spec;
            END IF;
            RAISE EXCEPTION 'Expected cursor type %, got % on first page', p_expected_cursor_type, v_cursor_type;
        END IF;
    END IF;

    -- Disable scan types before getMore calls to verify cursors still drain
    IF p_disable_scans THEN
        SET LOCAL enable_bitmapscan TO off;
        SET LOCAL enable_indexscan TO off;
    END IF;

    WHILE v_continuation IS NOT NULL LOOP
        EXECUTE 'SELECT gm.cursorPage, gm.continuation FROM cursor_get_more(
            database => ''dyncursor_drain_db'',
            getMoreSpec => $1::documentdb_core.bson,
            continuationSpec => $2
        ) gm' INTO v_cursor_page, v_continuation USING p_getmore_spec, v_continuation;
        v_round_trips := v_round_trips + 1;

        SELECT bson_dollar_project(v_cursor_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
            ->> 'c' INTO v_batch_count;
        v_total_count := v_total_count + COALESCE(v_batch_count, 0);

        IF v_continuation IS NOT NULL THEN
            SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
                INTO v_cursor_type;
            IF v_cursor_type IS DISTINCT FROM p_expected_cursor_type THEN
                IF p_expected_cursor_type = 3 AND v_cursor_type = 7 THEN
                    RAISE NOTICE 'INVESTIGATE: expected IXS (3) but got IOS (7) on getMore. getmore_spec: %', p_getmore_spec;
                END IF;
                RAISE EXCEPTION 'Expected cursor type %, got % on getMore', p_expected_cursor_type, v_cursor_type;
            END IF;
        END IF;
    END LOOP;

    -- Restore scan types
    IF p_disable_scans THEN
        SET LOCAL enable_bitmapscan TO on;
        SET LOCAL enable_indexscan TO on;
    END IF;

    -- Assert minimum round trips
    v_expected_round_trips := GREATEST(CEIL(p_expected_count::float / p_batch_size), 1);
    IF v_round_trips < v_expected_round_trips THEN
        RAISE EXCEPTION 'Expected at least % round trips for batchSize=% and % rows, got %',
            v_expected_round_trips, p_batch_size, p_expected_count, v_round_trips;
    END IF;

    RETURN v_total_count;
END;
$$ LANGUAGE plpgsql;

-- ===========================================================================
-- Test 3: $exists on "a" with seqscan, bitmapscan, indexscan disabled
-- before getMore calls — verify cursors still drain correctly
-- ===========================================================================
DO $$
DECLARE
    v_bs int;
    v_count bigint;
    v_batch_sizes int[] := ARRAY[1, 29, 111, 347];
BEGIN
    FOREACH v_bs IN ARRAY v_batch_sizes LOOP
        -- IXS (projection includes _id, type 3)
        SELECT drain_cursor_checked(
            FORMAT('{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 1, "a": 1 }, "batchSize": %s }', v_bs),
            FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
            3, v_bs, 1000, true
        ) INTO v_count;
        IF v_count <> 1000 THEN
            RAISE EXCEPTION 'IXS scans disabled: batchSize=% returned % rows instead of 1000', v_bs, v_count;
        END IF;

        -- IOS (projection excludes _id, type 7)
        SELECT drain_cursor_checked(
            FORMAT('{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": %s }', v_bs),
            FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
            7, v_bs, 1000, true
        ) INTO v_count;
        IF v_count <> 1000 THEN
            RAISE EXCEPTION 'IOS scans disabled: batchSize=% returned % rows instead of 1000', v_bs, v_count;
        END IF;
    END LOOP;
    RAISE NOTICE '$exists on a with scans disabled: all batch sizes passed (1, 29, 111, 347)';
END;
$$;

-- ===========================================================================
-- Test 4: Query operators with dynamic cursors (IXS and IOS)
-- Data: 1000 rows with a = i/2 (integer division), so a ranges 0..500
-- For each operator combo, verify correct row count across batch sizes
-- using both index scan (projection includes _id) and index only scan
-- (projection excludes _id)
-- ===========================================================================
DO $$
DECLARE
    v_bs int;
    v_count bigint;
    v_batch_sizes int[] := ARRAY[1, 29, 111, 347];
    v_proj text;
    v_proj_label text;
    v_projections text[] := ARRAY[
        '{ "_id": 1, "a": 1 }',   -- IXS (index scan)
        '{ "_id": 0, "a": 1 }'    -- IOS (index only scan)
    ];
    v_proj_labels text[] := ARRAY['IXS', 'IOS'];
    -- Operator queries use IXS (3) when projection includes _id, IOS (7) when covered
    v_expected_types int[] := ARRAY[3, 7];
    v_test_label text;
    v_filter text;
    v_expected int;
    v_expected_type int;
    v_pi int;
BEGIN
    FOR v_pi IN 1..2 LOOP
        v_proj := v_projections[v_pi];
        v_proj_label := v_proj_labels[v_pi];
        v_expected_type := v_expected_types[v_pi];

        FOREACH v_bs IN ARRAY v_batch_sizes LOOP
            -- $gt: a > 400 → a in 401..500 → 199 rows
            v_test_label := v_proj_label || '/$gt';
            v_filter := '{ "a": { "$gt": 400 } }';
            v_expected := 199;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $gte: a >= 490 → a in 490..500 → 21 rows
            v_test_label := v_proj_label || '/$gte';
            v_filter := '{ "a": { "$gte": 490 } }';
            v_expected := 21;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $lt: a < 10 → a in 0..9 → 19 rows
            v_test_label := v_proj_label || '/$lt';
            v_filter := '{ "a": { "$lt": 10 } }';
            v_expected := 19;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $lte: a <= 5 → a in 0..5 → 11 rows
            v_test_label := v_proj_label || '/$lte';
            v_filter := '{ "a": { "$lte": 5 } }';
            v_expected := 11;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $gt + $lt: a > 100 AND a < 110 → a in 101..109 → 18 rows
            v_test_label := v_proj_label || '/$gt+$lt';
            v_filter := '{ "a": { "$gt": 100, "$lt": 110 } }';
            v_expected := 18;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $gte + $lte: a >= 200 AND a <= 210 → a in 200..210 → 22 rows
            v_test_label := v_proj_label || '/$gte+$lte';
            v_filter := '{ "a": { "$gte": 200, "$lte": 210 } }';
            v_expected := 22;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $in (small, 5 values below threshold): a in [1,5,10,50,100] → 10 rows
            v_test_label := v_proj_label || '/$in(small)';
            v_filter := '{ "a": { "$in": [1, 5, 10, 50, 100] } }';
            v_expected := 10;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $eq (exact match): a = 250 → 2 rows
            v_test_label := v_proj_label || '/$eq';
            v_filter := '{ "a": 250 }';
            v_expected := 2;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $ne: a != 250 → 1000 - 2 = 998 rows
            -- $ne cannot use index-only scan, always uses IXS (type 3)
            v_test_label := v_proj_label || '/$ne';
            v_filter := '{ "a": { "$ne": 250 } }';
            v_expected := 998;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                3,  -- $ne always uses IXS
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;
        END LOOP;
    END LOOP;
    RAISE NOTICE 'Query operators (IXS+IOS): all tests passed for batch sizes 1, 29, 111, 347';
END;
$$;

-- ===========================================================================
-- Test 5: $in with values exceeding MaxNonOrderedTermScanThreshold (IXS+IOS)
-- Lower threshold to 10 so that $in with 15+ values exceeds it
-- ===========================================================================
SET documentdb.max_non_ordered_term_scan_threshold TO 10;

DO $$
DECLARE
    v_bs int;
    v_count bigint;
    v_batch_sizes int[] := ARRAY[1, 29, 111, 347];
    v_proj text;
    v_proj_label text;
    v_projections text[] := ARRAY[
        '{ "_id": 1, "a": 1 }',   -- IXS (index scan)
        '{ "_id": 0, "a": 1 }'    -- IOS (index only scan)
    ];
    v_proj_labels text[] := ARRAY['IXS', 'IOS'];
    -- IXS (3) when projection includes _id, IOS (7) when covered
    v_expected_types int[] := ARRAY[3, 7];
    v_test_label text;
    v_filter text;
    v_expected int;
    v_expected_type int;
    v_pi int;
BEGIN
    FOR v_pi IN 1..2 LOOP
        v_proj := v_projections[v_pi];
        v_proj_label := v_proj_labels[v_pi];
        v_expected_type := v_expected_types[v_pi];

        FOREACH v_bs IN ARRAY v_batch_sizes LOOP
            -- $in with 15 values (exceeds threshold of 10)
            -- a in [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15] → 30 rows
            v_test_label := v_proj_label || '/$in(exceed_threshold_15)';
            v_filter := '{ "a": { "$in": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] } }';
            v_expected := 30;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $in with 20 values (well above threshold of 10)
            -- a in [10,20,...,200] → 40 rows
            v_test_label := v_proj_label || '/$in(exceed_threshold_20)';
            v_filter := '{ "a": { "$in": [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200] } }';
            v_expected := 40;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;

            -- $in combined with $gt on same field: a in [100,200,300,400,500] AND a > 350
            -- Intersection: a in {400, 500} → a=400 has 2 rows, a=500 has 1 row → 3 rows
            v_test_label := v_proj_label || '/$in+$gt';
            v_filter := '{ "$and": [{ "a": { "$in": [100, 200, 300, 400, 500] } }, { "a": { "$gt": 350 } }] }';
            v_expected := 3;
            SELECT drain_cursor_checked(
                FORMAT('{ "find": "drain_scans", "filter": %s, "projection": %s, "batchSize": %s }', v_filter, v_proj, v_bs),
                FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
                v_expected_type,
                v_bs,
                v_expected
            ) INTO v_count;
            IF v_count <> v_expected THEN
                RAISE EXCEPTION '%: batchSize=% returned % rows instead of %', v_test_label, v_bs, v_count, v_expected;
            END IF;
        END LOOP;
    END LOOP;
    RAISE NOTICE '$in exceed threshold (IXS+IOS): all tests passed for batch sizes 1, 29, 111, 347';
END;
$$;

-- Restore threshold
SET documentdb.max_non_ordered_term_scan_threshold TO 500;

-- ===========================================================================
-- Test 7: Drain with index on "c" using $exists filter
-- Create a secondary index on "c" and verify all rows are returned for
-- batch sizes 1..1000 with { "c": { "$exists": true } }
-- ===========================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dyncursor_drain_db',
    '{ "createIndexes": "drain_scans", "indexes": [ { "key": { "c": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "c_1" } ] }',
    true
);

ANALYZE;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ---------------------------------------------------------------------------
-- Index scan on "c" (projection includes _id): batchSize=1
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 1 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp_c AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 1 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp_c \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 1 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp_c;

-- ---------------------------------------------------------------------------
-- Index scan on "c" (projection includes _id): batchSize=5
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 5 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp_c AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 5 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp_c \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 5 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp_c;

-- ---------------------------------------------------------------------------
-- Index scan on "c" (projection includes _id): batchSize=25
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 25 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp_c AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 25 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp_c \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 25 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp_c;

-- ---------------------------------------------------------------------------
-- Index scan on "c" (projection includes _id): batchSize=100
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 100 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp_c AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 100 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp_c \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 100 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp_c;

-- ---------------------------------------------------------------------------
-- Index scan on "c" (projection includes _id): batchSize=500
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('dyncursor_drain_db',
        '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 500 }');
$cmd$, true);

CREATE TEMP TABLE drain_explain_resp_c AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'dyncursor_drain_db',
    commandSpec => '{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": 500 }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM drain_explain_resp_c \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('dyncursor_drain_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": 500 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE drain_explain_resp_c;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

DO $$
DECLARE
    v_bs int;
    v_count bigint;
BEGIN
    FOR v_bs IN 1..1000 LOOP
        SELECT drain_cursor_checked(
            FORMAT('{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": %s }', v_bs),
            FORMAT('{ "getMore": { "$numberLong": "536" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
            3,    -- expected cursor type: index scan (projection includes _id)
            v_bs,
            1000
        ) INTO v_count;

        IF v_count <> 1000 THEN
            RAISE EXCEPTION 'Index scan on c: batchSize=% returned % rows instead of 1000', v_bs, v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Index scan on c ($exists): all batch sizes 1..1000 returned 1000 rows';
END;
$$;

-- Clean up helper function
DROP FUNCTION drain_cursor_checked(text, text, int, int, int, bool);

-- ===========================================================================
-- Toggle enableIndexOnlyScanForFindProject between each page so the cursor
-- alternates between index only scan (type 7) and index scan (type 3).
-- Validates that the system correctly drains all rows despite mid-stream
-- scan type changes, and that each continuation reflects the expected type.
-- Uses dynamic SQL (EXECUTE) to avoid PL/pgSQL plan caching.
-- ===========================================================================
CREATE OR REPLACE FUNCTION drain_cursor_alternating(
    p_find_spec text,
    p_getmore_spec text,
    p_batch_size int,
    p_expected_count int
) RETURNS bigint AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_total_count bigint := 0;
    v_batch_count bigint;
    v_cursor_type int;
    v_ios_on bool := true;
    v_expected_type int;
    v_page_num int := 0;
    v_round_trips int := 0;
    v_expected_round_trips int;
BEGIN
    -- First page: enable_indexonlyscan ON → expect index only scan (type 7)
    SET LOCAL enable_indexonlyscan TO on;
    SET LOCAL plan_cache_mode TO force_custom_plan;

    EXECUTE 'SELECT cursorPage, continuation FROM find_cursor_first_page(
        database => ''dyncursor_drain_db'',
        commandSpec => $1::documentdb_core.bson,
        cursorId => 537
    )' INTO v_cursor_page, v_continuation USING p_find_spec;
    v_round_trips := v_round_trips + 1;

    SELECT bson_dollar_project(v_cursor_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }')
        ->> 'c' INTO v_batch_count;
    v_total_count := v_total_count + COALESCE(v_batch_count, 0);

    IF v_continuation IS NOT NULL THEN
        SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO v_cursor_type;
        IF v_cursor_type IS DISTINCT FROM 7 THEN
            RAISE EXCEPTION 'Page 0: expected cursor type 7 (IOS), got %', v_cursor_type;
        END IF;
    END IF;

    -- Iterate getMore, toggling GUC each page
    WHILE v_continuation IS NOT NULL LOOP
        v_page_num := v_page_num + 1;
        v_ios_on := NOT v_ios_on;

        IF v_ios_on THEN
            SET LOCAL enable_indexonlyscan TO on;
            v_expected_type := 7;
        ELSE
            SET LOCAL enable_indexonlyscan TO off;
            v_expected_type := 3;
        END IF;

        EXECUTE 'SELECT gm.cursorPage, gm.continuation FROM cursor_get_more(
            database => ''dyncursor_drain_db'',
            getMoreSpec => $1::documentdb_core.bson,
            continuationSpec => $2
        ) gm' INTO v_cursor_page, v_continuation USING p_getmore_spec, v_continuation;
        v_round_trips := v_round_trips + 1;

        SELECT bson_dollar_project(v_cursor_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
            ->> 'c' INTO v_batch_count;
        v_total_count := v_total_count + COALESCE(v_batch_count, 0);

        IF v_continuation IS NOT NULL THEN
            SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
                INTO v_cursor_type;
            IF v_cursor_type IS DISTINCT FROM v_expected_type THEN
                RAISE EXCEPTION 'Page %: expected cursor type %, got %', v_page_num, v_expected_type, v_cursor_type;
            END IF;
        END IF;
    END LOOP;

    -- Restore GUC
    SET LOCAL enable_indexonlyscan TO on;

    -- Assert minimum round trips
    v_expected_round_trips := GREATEST(CEIL(p_expected_count::float / p_batch_size), 1);
    IF v_round_trips < v_expected_round_trips THEN
        RAISE EXCEPTION 'Expected at least % round trips for batchSize=% and % rows, got %',
            v_expected_round_trips, p_batch_size, p_expected_count, v_round_trips;
    END IF;

    RETURN v_total_count;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    v_bs int;
    v_count bigint;
BEGIN
    FOR v_bs IN 1..1001 LOOP
        SELECT drain_cursor_alternating(
            FORMAT('{ "find": "drain_scans", "filter": { "a": { "$exists": true } }, "projection": { "_id": 0, "a": 1 }, "batchSize": %s }', v_bs),
            FORMAT('{ "getMore": { "$numberLong": "537" }, "collection": "drain_scans", "batchSize": %s }', v_bs),
            v_bs, -- batch size
            1000  -- expected row count
        ) INTO v_count;

        IF v_count <> 1000 THEN
            RAISE EXCEPTION 'Alternating scan: batchSize=% returned % rows instead of 1000', v_bs, v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Alternating scan: all batch sizes 1..1001 returned 1000 rows';
END;
$$;

-- Clean up helper functions
DROP FUNCTION drain_cursor_alternating(text, text, int, int);

-- ===========================================================================
-- Test 8: Validate continuation drains all remaining documents
-- For various batch sizes, fetch the first page on "c" index, verify the
-- first page has the expected count and continuation is non-null, then drain
-- all remaining docs via getMore and confirm exactly (1000 - batchSize) rows
-- are returned with no gaps or duplicates.
-- ===========================================================================
CREATE OR REPLACE FUNCTION validate_continuation_and_drain(
    p_batch_size int
) RETURNS void AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_first_batch_size bigint;
    v_remaining_count bigint := 0;
    v_batch_count bigint;
BEGIN
    -- Fetch first page using index on "c" with $exists filter
    EXECUTE 'SELECT cursorPage, continuation FROM find_cursor_first_page(
        database => ''dyncursor_drain_db'',
        commandSpec => $1::documentdb_core.bson,
        cursorId => 538
    )' INTO v_cursor_page, v_continuation
    USING FORMAT('{ "find": "drain_scans", "filter": { "c": { "$exists": true } }, "projection": { "_id": 1, "c": 1 }, "batchSize": %s }', p_batch_size);

    -- Verify firstBatch has the expected number of docs
    SELECT (bson_dollar_project(v_cursor_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }')
        ->> 'c')::bigint INTO v_first_batch_size;

    IF v_first_batch_size <> p_batch_size THEN
        RAISE EXCEPTION 'batchSize=%: firstBatch had % docs, expected %',
            p_batch_size, v_first_batch_size, p_batch_size;
    END IF;

    IF v_continuation IS NULL THEN
        RAISE EXCEPTION 'batchSize=%: continuation is NULL after first page', p_batch_size;
    END IF;

    -- Drain all remaining pages via getMore
    WHILE v_continuation IS NOT NULL LOOP
        EXECUTE 'SELECT gm.cursorPage, gm.continuation FROM cursor_get_more(
            database => ''dyncursor_drain_db'',
            getMoreSpec => $1::documentdb_core.bson,
            continuationSpec => $2
        ) gm' INTO v_cursor_page, v_continuation
        USING FORMAT('{ "getMore": { "$numberLong": "538" }, "collection": "drain_scans", "batchSize": %s }', p_batch_size),
              v_continuation;

        SELECT (bson_dollar_project(v_cursor_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
            ->> 'c')::bigint INTO v_batch_count;
        v_remaining_count := v_remaining_count + COALESCE(v_batch_count, 0);
    END LOOP;

    IF v_remaining_count <> (1000 - p_batch_size) THEN
        RAISE EXCEPTION 'batchSize=%: getMore returned % total rows, expected %',
            p_batch_size, v_remaining_count, 1000 - p_batch_size;
    END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    v_batch_sizes int[] := ARRAY[1, 2, 5, 10, 25, 50, 100, 250, 500, 999];
    v_bs int;
BEGIN
    FOREACH v_bs IN ARRAY v_batch_sizes LOOP
        PERFORM validate_continuation_and_drain(v_bs);
    END LOOP;
    RAISE NOTICE 'Continuation validation: all batch sizes passed (1, 2, 5, 10, 25, 50, 100, 250, 500, 999)';
END;
$$;

DROP FUNCTION validate_continuation_and_drain(int);

-- Restore defaults
SET documentdb.enablePrimaryKeyCursorScan TO off;
