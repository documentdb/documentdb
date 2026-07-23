SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

-- Ensure database 'gbstream_db' exists so that the system.dbSentinel collection
-- does not consume a test collection id when running in standalone mode.
SELECT documentdb_api.insert_one('gbstream_db', 'setup_sentinel', '{ "_id": 0 }');
SELECT documentdb_api.drop_collection('gbstream_db', 'setup_sentinel');

SET documentdb.next_collection_id TO 79000;
SET documentdb.next_collection_index_id TO 79000;

-- 50 documents with 5 distinct values (0..4) for field "a".
SELECT COUNT(documentdb_api.insert_one('gbstream_db', 'gstream',
    FORMAT('{ "_id": %s, "a": %s, "b": %s }', i, i % 5, i)::documentdb_core.bson))
FROM generate_series(1, 50) i;

-- Ordered index on "a" so a grouping-only $group can be satisfied by an
-- ordered index (only) scan, which is the requirement for streaming.
SELECT documentdb_api_internal.create_indexes_non_concurrently('gbstream_db',
    '{ "createIndexes": "gstream", "indexes": [ { "key": { "a": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "a_1" } ] }',
    true);

ANALYZE;

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ===========================================================================
-- Plan shape: with the feature flag OFF the grouping-only $group must NOT be
-- wrapped by the dynamic cursor scan (the GroupAggregate sits directly on the
-- ordered index only scan).
-- ===========================================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enable_group_by_dynamic_streaming TO off;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('gbstream_db',
    '{ "aggregate": "gstream", "hint": "a_1", "pipeline": [ { "$group": { "_id": "$a" } } ], "cursor": { "batchSize": 2 } }')
$Q$);
ROLLBACK;

-- ===========================================================================
-- Plan shape: with the feature flag ON the grouping-only $group is served by
-- the dynamic cursor scan, producing
--   GroupAggregate -> Custom Scan (DocumentDBApiCursorScan) -> Index Only Scan.
-- ===========================================================================
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_hashagg TO off;
SET LOCAL documentdb.enable_group_by_dynamic_streaming TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($Q$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('gbstream_db',
    '{ "aggregate": "gstream", "hint": "a_1", "pipeline": [ { "$group": { "_id": "$a" } } ], "cursor": { "batchSize": 2 } }')
$Q$);
ROLLBACK;

-- ===========================================================================
-- Streaming a grouping-only $group with batchSize 1: each page must stream
-- exactly one group and report persistConnection=false. This is the tightest
-- exercise of the read-ahead continuation fix, since every page boundary falls
-- between two groups that the sorted GroupAggregate reads across.
-- ===========================================================================
CREATE OR REPLACE FUNCTION gstream_stream_pages(
    p_batch_size int
) RETURNS TABLE(page int, persist bool, ids text) AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_persist bool;
    v_page int := 0;
BEGIN
    SET LOCAL enable_seqscan TO off;
    SET LOCAL enable_bitmapscan TO off;
    SET LOCAL enable_hashagg TO off;
    SET LOCAL documentdb.enable_group_by_dynamic_streaming TO on;

    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
    INTO v_cursor_page, v_continuation, v_persist
    FROM aggregate_cursor_first_page(
        database => 'gbstream_db',
        commandSpec => FORMAT('{ "aggregate": "gstream", "hint": "a_1", "pipeline": [ { "$group": { "_id": "$a" } } ], "cursor": { "batchSize": %s } }', p_batch_size)::documentdb_core.bson,
        cursorId => 79600) fp;

    page := v_page;
    persist := v_persist;
    ids := bson_dollar_project(v_cursor_page, '{ "x": "$cursor.firstBatch._id" }') ->> 'x';
    RETURN NEXT;

    WHILE v_continuation IS NOT NULL LOOP
        v_page := v_page + 1;

        SELECT gm.cursorPage, gm.continuation
        INTO v_cursor_page, v_continuation
        FROM cursor_get_more(
            database => 'gbstream_db',
            getMoreSpec => FORMAT('{ "getMore": { "$numberLong": "79600" }, "collection": "gstream", "batchSize": %s }', p_batch_size)::documentdb_core.bson,
            continuationSpec => v_continuation) gm;

        page := v_page;
        persist := v_persist;
        ids := bson_dollar_project(v_cursor_page, '{ "x": "$cursor.nextBatch._id" }') ->> 'x';
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

SELECT page, persist, ids FROM gstream_stream_pages(1) ORDER BY page;

DROP FUNCTION gstream_stream_pages(int);

-- ===========================================================================
-- Correctness across pagination: drain a grouping-only $group cursor and
-- validate that every batch size returns exactly the full set of distinct
-- groups. A sorted GroupAggregate reads one row into the following group
-- before it can emit the current group, so the continuation must resume from
-- the boundary of the last emitted group; otherwise a group that straddles a
-- page boundary would be dropped.
-- ===========================================================================
CREATE OR REPLACE FUNCTION gstream_drain_group(
    p_batch_size int,
    p_streaming bool
) RETURNS text AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_persist bool;
    v_ids text := '';
    v_batch text;
BEGIN
    EXECUTE FORMAT('SET LOCAL documentdb.enable_group_by_dynamic_streaming TO %s',
                   CASE WHEN p_streaming THEN 'on' ELSE 'off' END);

    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
    INTO v_cursor_page, v_continuation, v_persist
    FROM aggregate_cursor_first_page(
        database => 'gbstream_db',
        commandSpec => FORMAT('{ "aggregate": "gstream", "hint": "a_1", "pipeline": [ { "$group": { "_id": "$a" } } ], "cursor": { "batchSize": %s } }', p_batch_size)::documentdb_core.bson,
        cursorId => 79500) fp;

    IF p_streaming AND v_persist THEN
        RAISE EXCEPTION 'batchSize=%: expected streaming (persistConnection=false)', p_batch_size;
    END IF;
    IF (NOT p_streaming) AND (NOT v_persist) THEN
        RAISE EXCEPTION 'batchSize=%: expected persisted cursor (persistConnection=true)', p_batch_size;
    END IF;

    v_batch := bson_dollar_project(v_cursor_page, '{ "x": "$cursor.firstBatch._id" }') ->> 'x';
    IF v_batch IS NOT NULL AND v_batch <> '[ ]' THEN
        v_ids := v_batch;
    END IF;

    WHILE v_continuation IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation
        INTO v_cursor_page, v_continuation
        FROM cursor_get_more(
            database => 'gbstream_db',
            getMoreSpec => FORMAT('{ "getMore": { "$numberLong": "79500" }, "collection": "gstream", "batchSize": %s }', p_batch_size)::documentdb_core.bson,
            continuationSpec => v_continuation) gm;

        v_batch := bson_dollar_project(v_cursor_page, '{ "x": "$cursor.nextBatch._id" }') ->> 'x';
        IF v_batch IS NOT NULL AND v_batch <> '[ ]' THEN
            v_ids := v_ids || ' | ' || v_batch;
        END IF;
    END LOOP;

    RETURN v_ids;
END;
$$ LANGUAGE plpgsql;

-- For every batch size, streaming and persisted must return the same grouped
-- pages; the union across pages must be the complete distinct set {0..4}.
DO $$
DECLARE
    v_bs int;
    v_stream text;
    v_persist text;
    v_expected_count bigint;
    v_stream_count bigint;
BEGIN
    SET LOCAL enable_seqscan TO off;
    SET LOCAL enable_bitmapscan TO off;
    SET LOCAL enable_hashagg TO off;

    FOR v_bs IN 1..7 LOOP
        v_stream := gstream_drain_group(v_bs, true);
        v_persist := gstream_drain_group(v_bs, false);

        IF v_stream IS DISTINCT FROM v_persist THEN
            RAISE EXCEPTION 'batchSize=%: streaming pages "%" differ from persisted pages "%"',
                v_bs, v_stream, v_persist;
        END IF;

        -- Count of distinct groups streamed (comma separated ids across pages).
        SELECT COUNT(*) INTO v_stream_count
        FROM regexp_matches(v_stream, '[0-9]+', 'g');

        IF v_stream_count <> 5 THEN
            RAISE EXCEPTION 'batchSize=%: expected 5 groups, streamed % ("%")',
                v_bs, v_stream_count, v_stream;
        END IF;
    END LOOP;

    RAISE NOTICE 'Group-by dynamic streaming: batch sizes 1..7 stream all 5 groups and match the persisted cursor';
END;
$$;

DROP FUNCTION gstream_drain_group(int, bool);

-- ===========================================================================
-- Stages layered on top of a fully pushable $group (a trailing $project or a
-- post-group $match) are planned with a SubqueryScan wrapping the sorted
-- GroupAggregate. Streaming descends through that SubqueryScan, so the
-- read-ahead continuation must be detected through the wrapper rather than only
-- at the top-level plan node. Drain such pipelines across batch sizes and assert
-- the streamed pages match the persisted cursor exactly (no straddling group is
-- dropped) regardless of whether streaming or a persisted cursor is chosen.
-- ===========================================================================
CREATE OR REPLACE FUNCTION gstream_drain_pipeline(
    p_pipeline text,
    p_batch_size int,
    p_streaming bool,
    OUT o_ids text,
    OUT o_persist bool
) AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_batch text;
BEGIN
    EXECUTE FORMAT('SET LOCAL documentdb.enable_group_by_dynamic_streaming TO %s',
                   CASE WHEN p_streaming THEN 'on' ELSE 'off' END);

    o_ids := '';

    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
    INTO v_cursor_page, v_continuation, o_persist
    FROM aggregate_cursor_first_page(
        database => 'gbstream_db',
        commandSpec => FORMAT('{ "aggregate": "gstream", "hint": "a_1", "pipeline": %s, "cursor": { "batchSize": %s } }', p_pipeline, p_batch_size)::documentdb_core.bson,
        cursorId => 79700) fp;

    v_batch := bson_dollar_project(v_cursor_page, '{ "x": "$cursor.firstBatch._id" }') ->> 'x';
    IF v_batch IS NOT NULL AND v_batch <> '[ ]' THEN
        o_ids := v_batch;
    END IF;

    WHILE v_continuation IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation
        INTO v_cursor_page, v_continuation
        FROM cursor_get_more(
            database => 'gbstream_db',
            getMoreSpec => FORMAT('{ "getMore": { "$numberLong": "79700" }, "collection": "gstream", "batchSize": %s }', p_batch_size)::documentdb_core.bson,
            continuationSpec => v_continuation) gm;

        v_batch := bson_dollar_project(v_cursor_page, '{ "x": "$cursor.nextBatch._id" }') ->> 'x';
        IF v_batch IS NOT NULL AND v_batch <> '[ ]' THEN
            o_ids := o_ids || ' | ' || v_batch;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    v_bs int;
    v_pipeline text;
    v_stream_ids text;
    v_stream_persist bool;
    v_persist_ids text;
    v_persist_persist bool;
    v_streamed_any bool := false;
    v_pipelines text[] := ARRAY[
        '[ { "$group": { "_id": "$a" } }, { "$project": { "g": "$_id" } } ]',
        '[ { "$group": { "_id": "$a" } }, { "$match": { "_id": { "$gte": 0 } } } ]',
        '[ { "$match": { "a": { "$gte": 0 } } }, { "$group": { "_id": "$a" } }, { "$project": { "g": "$_id" } }, { "$match": { "g": { "$gte": 0 } } } ]'
    ];
BEGIN
    SET LOCAL enable_seqscan TO off;
    SET LOCAL enable_bitmapscan TO off;
    SET LOCAL enable_hashagg TO off;

    FOREACH v_pipeline IN ARRAY v_pipelines LOOP
        FOR v_bs IN 1..7 LOOP
            SELECT o_ids, o_persist INTO v_stream_ids, v_stream_persist
            FROM gstream_drain_pipeline(v_pipeline, v_bs, true);
            SELECT o_ids, o_persist INTO v_persist_ids, v_persist_persist
            FROM gstream_drain_pipeline(v_pipeline, v_bs, false);

            IF v_stream_ids IS DISTINCT FROM v_persist_ids THEN
                RAISE EXCEPTION 'pipeline % batchSize=%: streaming pages "%" differ from persisted pages "%"',
                    v_pipeline, v_bs, v_stream_ids, v_persist_ids;
            END IF;

            IF NOT v_stream_persist THEN
                v_streamed_any := true;
            END IF;
        END LOOP;
    END LOOP;

    -- Guard against the test silently becoming vacuous: these pipelines are
    -- expected to stream (SubqueryScan over a sorted GroupAggregate over the
    -- cursor scan), which is what exercises the read-ahead continuation path.
    IF NOT v_streamed_any THEN
        RAISE EXCEPTION 'expected at least one $group pipeline with a trailing stage to stream, but all used a persisted cursor';
    END IF;

    RAISE NOTICE 'Group-by dynamic streaming: $group with trailing $project/$match stages matches the persisted cursor across batch sizes';
END;
$$;

DROP FUNCTION gstream_drain_pipeline(text, int, bool);
