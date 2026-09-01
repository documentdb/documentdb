-- ============================================================================
-- Dynamic Cursor Skip Tests
-- ============================================================================
--
-- Validates that a find with a positive skip uses a dynamic streaming cursor
-- (DocumentDBApiCursorScan) when enable_dynamic_cursor_with_skiplimit is on, and that
-- the skip is applied exactly once across getMore pages.
--
-- Unlike the streamed limit, no skip state is carried in the continuation. The
-- executor consumes OFFSET before its first row. A non-empty resume state clears
-- the offset; the empty state left by batchSize 0 preserves it. Per-page ids
-- detect an offset applied more than once.
--
-- enableExplainScanIndexCosts is turned off so the EXPLAIN output does not
-- include (non-deterministic) index cost estimates.
-- ============================================================================

SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 25870000;
SET documentdb.next_collection_index_id TO 25870000;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableExplainScanIndexCosts TO off;

-- Seed 20 documents.
DO $$
BEGIN
    FOR g IN 1..20 LOOP
        PERFORM documentdb_api.insert_one('skiptest', 'coll',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;

-- Drains a find across pages and reports the ids seen on each page, so a page
-- boundary that re-applies the offset is visible (a count-only check would not
-- catch it). Also reports whether the first page kept the connection, which
-- distinguishes a streaming cursor from the persistent fallback. Explicit
-- projections also include the returned documents.
CREATE OR REPLACE FUNCTION drain_skip_report(
    p_find_spec text,
    p_getmore_spec text,
    p_cursor_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_page bson;
    v_cont bson;
    v_persist bool;
    v_pages int := 1;
    v_ids text;
    v_all text := '';
    v_documents text;
    v_all_documents text := '';
    v_has_projection bool := p_find_spec::jsonb ? 'projection';
BEGIN
    SELECT cursorpage, continuation, persistconnection
    INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page('skiptest', p_find_spec::bson, p_cursor_id);

    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), ''),
           COALESCE(string_agg(
               regexp_replace(value::text,
                   '\{"\$numberInt": "(-?[0-9]+)"\}', '\1', 'g'),
               ',' ORDER BY ordinality), '')
    INTO v_ids, v_documents
    FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    v_all := '[' || v_ids || ']';
    v_all_documents := '[' || v_documents || ']';

    WHILE v_cont IS NOT NULL LOOP
        SELECT cursorpage, continuation INTO v_page, v_cont
        FROM cursor_get_more('skiptest', p_getmore_spec::bson, v_cont);

        SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), ''),
               COALESCE(string_agg(
                   regexp_replace(value::text,
                       '\{"\$numberInt": "(-?[0-9]+)"\}', '\1', 'g'),
                   ',' ORDER BY ordinality), '')
        INTO v_ids, v_documents
        FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
        v_all := v_all || ' [' || v_ids || ']';
        v_all_documents := v_all_documents || ' [' || v_documents || ']';
        v_pages := v_pages + 1;
    END LOOP;

    RETURN FORMAT('persist=%s pages=%s ids=%s%s', v_persist, v_pages, v_all,
        CASE WHEN v_has_projection THEN ' docs=' || v_all_documents ELSE '' END);
END;
$$;

------------------------------------------------------------
-- Streaming decision (EXPLAIN): a skip query uses the dynamic streaming cursor
-- (DocumentDBApiCursorScan) only when enable_dynamic_cursor_with_skiplimit is
-- on. A skip-only find isolates the skip decision from the limit one.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 3 }');

SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 3 }');

-- skip + limit still needs BOTH counts tracked: an untracked limit would
-- over-return on resume just as an untracked skip would over-skip. A single
-- flag authorizes the pair, so they stream as a unit and fall back as a unit.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 3, "limit": 6 }');

-- The single planner authorization is safe only because a streamed skip can
-- never coexist with an untracked limit > 1. Pin that invariant: a skip+limit
-- cursor that streams must carry its remaining limit in "lim".
CREATE TEMP TABLE skip_limit_authorization AS
SELECT continuation, persistconnection
FROM find_cursor_first_page(
    'skiptest',
    '{ "find": "coll", "skip": 3, "limit": 6, "batchSize": 2 }',
    9020);
SELECT persistconnection,
       bson_dollar_project(continuation, '{ "lim": 1 }') AS authorization_state
FROM skip_limit_authorization;
DROP TABLE skip_limit_authorization;

SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 3, "limit": 6 }');

------------------------------------------------------------
-- Drain correctness. The offset must be applied exactly once, on the first
-- page. If a getMore re-applied it, skip:3 batchSize:2 would return
-- [4,5] [9,10] [14,15] instead of [4,5] [6,7] [8,9].
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9001" }, "collection": "coll", "batchSize": 2 }',
    9001) AS skip3_limit6_batch2;

-- A larger skip with an uneven final page.
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 8, "limit": 5, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9002" }, "collection": "coll", "batchSize": 3 }',
    9002) AS skip8_limit5_batch3;

-- Skip with no limit at all: the resumed pages carry no Limit node whatsoever
-- (both limitCount and limitOffset are NULL after the offset is cleared).
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 17, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9003" }, "collection": "coll", "batchSize": 2 }',
    9003) AS skip17_nolimit_batch2;

-- Skip with a filter still resumes at the right place.
SELECT drain_skip_report(
    '{ "find": "coll", "filter": { "a": { "$gte": 5 } }, "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9004" }, "collection": "coll", "batchSize": 2 }',
    9004) AS filter_skip2_limit4;

-- Sorted skip: an index-provided order must resume correctly across pages.
SELECT drain_skip_report(
    '{ "find": "coll", "sort": { "_id": -1 }, "skip": 3, "limit": 4, "projection": { "a": 1 }, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9005" }, "collection": "coll", "batchSize": 2 }',
    9005) AS sorted_desc_skip3_limit4_projection;

-- A skip past the end of the collection returns nothing and closes.
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 25, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9006" }, "collection": "coll", "batchSize": 2 }',
    9006) AS skip_past_end;

-- batchSize 0 leaves an empty state, preserving the offset for getMore.
SELECT persistconnection AS batch0_persistconnection
FROM find_cursor_first_page('skiptest', '{ "find": "coll", "skip": 3, "limit": 4, "batchSize": 0 }', 9008);

-- hasFetchedRows remains false until a page returns at least one row.
SELECT continuation AS fetched_state_cont
FROM find_cursor_first_page(
    'skiptest',
    '{ "find": "coll", "skip": 3, "limit": 4, "batchSize": 0 }',
    9026) \gset
SELECT bson_dollar_project(:'fetched_state_cont'::bson, '{ "_id": 0, "hasFetchedRows": 1 }')
    AS batch0_has_fetched_rows \gset
\echo batch0_has_fetched_rows=:batch0_has_fetched_rows
SELECT continuation AS fetched_state_cont
FROM cursor_get_more(
    'skiptest',
    '{ "getMore": { "$numberLong": "9026" }, "collection": "coll", "batchSize": 2 }',
    :'fetched_state_cont'::bson) \gset
SELECT bson_dollar_project(:'fetched_state_cont'::bson, '{ "_id": 0, "hasFetchedRows": 1 }')
    AS getmore_has_fetched_rows \gset
\echo getmore_has_fetched_rows=:getmore_has_fetched_rows

-- The first executor run applies the offset exactly once.
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 4, "batchSize": 0 }',
    '{ "getMore": { "$numberLong": "9009" }, "collection": "coll", "batchSize": 4 }',
    9009) AS batch0_drain;

-- Eligibility does not depend on batchSize being present on both pages.
-- Lower the default to force a resume.
SET documentdb.defaultCursorFirstPageBatchSize TO 2;
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 6 }',
    '{ "getMore": { "$numberLong": "9022" }, "collection": "coll", "batchSize": 2 }',
    9022) AS no_batchsize_skip6;
RESET documentdb.defaultCursorFirstPageBatchSize;

------------------------------------------------------------
-- Projection keeps LIMIT/OFFSET in the generated subquery. The planner
-- authorizes those counts without authorizing arbitrary nested queries.
------------------------------------------------------------
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 3, "limit": 6, "projection": { "a": 1 } }');
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 4, "projection": { "a": 1 }, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9007" }, "collection": "coll", "batchSize": 2 }',
    9007) AS projection_streamed;

-- An empty first page preserves the subquery offset for the first getMore.
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 4, "projection": { "a": 1 }, "batchSize": 0 }',
    '{ "getMore": { "$numberLong": "9024" }, "collection": "coll", "batchSize": 2 }',
    9024) AS projection_batchsize0;

-- The first page tracks the remaining limit, and the final page retires it.
CREATE TEMP TABLE projection_limit_state AS
SELECT continuation, persistconnection
FROM find_cursor_first_page(
    'skiptest',
    '{ "find": "coll", "skip": 3, "limit": 4, "projection": { "a": 1 }, "batchSize": 2 }',
    9025);
SELECT persistconnection,
       bson_dollar_project(continuation, '{ "lim": 1 }') AS projection_limit_state
FROM projection_limit_state;
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "docs": "$cursor.nextBatch" }') AS projection_final_page,
       continuation IS NULL AS cursor_closed
FROM cursor_get_more(
    'skiptest',
    '{ "getMore": { "$numberLong": "9025" }, "collection": "coll", "batchSize": 2 }',
    (SELECT continuation FROM projection_limit_state));
DROP TABLE projection_limit_state;

-- Projection is evaluated after skip, so an invalid value in a skipped
-- document does not surface an error.
SELECT documentdb_api.insert_one('skiptest', 'projection_error', '{ "_id": 1, "a": [1, 2], "b": [10] }');
SELECT documentdb_api.insert_one('skiptest', 'projection_error', '{ "_id": 2, "a": [1, 2], "b": [20, 21] }');
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "docs": "$cursor.firstBatch" }')
    AS projection_skips_invalid_value
FROM find_cursor_first_page(
    'skiptest',
    '{ "find": "projection_error", "filter": { "a": 2 }, "sort": { "_id": 1 }, "skip": 1, "limit": 1, "projection": { "b.$": 1 }, "batchSize": 1 }',
    9026);
SELECT cursorpage
FROM find_cursor_first_page(
    'skiptest',
    '{ "find": "projection_error", "filter": { "a": 2 }, "sort": { "_id": 1 }, "limit": 1, "projection": { "b.$": 1 }, "batchSize": 1 }',
    9027);

-- GenerateGetMoreQuery keeps an unconsumed offset in the resumed plan.
CREATE TEMP TABLE skip_getmore_explain AS
SELECT continuation FROM find_cursor_first_page(
    database => 'skiptest',
    commandSpec => '{ "find": "coll", "skip": 3, "batchSize": 0 }',
    cursorId => 9023);
SELECT continuation AS explain_cont FROM skip_getmore_explain \gset
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
    SELECT document FROM bson_aggregation_getmore(
        'skiptest',
        '{ "getMore": { "$numberLong": "9023" }, "collection": "coll", "batchSize": 2 }',
        $cmd$ || quote_literal(:'explain_cont') || $cmd$::documentdb_core.bson);
$cmd$);
DROP TABLE skip_getmore_explain;

-- skip 0 is a no-op and must not enter the skip streaming path.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 0, "limit": 6 }');

-- singleBatch owns cursor lifetime and must not create a continuation.
SELECT cursorpage AS page, continuation IS NULL AS no_continuation FROM find_cursor_first_page('skiptest', '{ "find": "coll", "skip": 3, "limit": 4, "singleBatch": true, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id" }'::bson) AS single_batch_skip, :'no_continuation'::bool AS no_continuation;

-- Dynamic skip streaming is restricted to unsharded collections.
DO $$
BEGIN
    PERFORM documentdb_api.insert_one('skiptest', 'sharded',
        '{ "_id": 1, "sk": 1 }'::documentdb_core.bson);
    PERFORM documentdb_api.shard_collection('skiptest', 'sharded',
        '{ "sk": "hashed" }'::documentdb_core.bson, false);
END;
$$;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "sharded", "skip": 3, "limit": 4 }');

-- Aggregation skip/limit remains outside the find-only streaming path.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('skiptest', '{ "aggregate": "coll", "pipeline": [ { "$skip": 3 }, { "$limit": 4 }, { "$project": { "a": 1 } } ], "cursor": {} }');

------------------------------------------------------------
-- Cursor lifetime is independent of the GUC: a cursor that started streaming
-- must keep resuming across getMore even if enable_dynamic_cursor_with_skiplimit is
-- turned OFF between pages. The resume needs no authorization at all, because
-- the offset is cleared before planning.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
SELECT cursorpage AS page, continuation AS cont, persistconnection AS persist, cursorid AS cid
FROM find_cursor_first_page('skiptest', '{ "find": "coll", "skip": 3, "limit": 6, "projection": { "a": 1 }, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "docs": "$cursor.firstBatch" }'::bson) AS guc_toggle_page1, :'persist'::bool AS persist;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
SELECT cursorpage AS page, continuation AS cont FROM cursor_get_more('skiptest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "docs": "$cursor.nextBatch" }'::bson) AS guc_toggle_page2_guc_off;

------------------------------------------------------------
-- With streaming disabled, results are still correct (persistent cursor path).
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 6, "projection": { "a": 1 }, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9010" }, "collection": "coll", "batchSize": 2 }',
    9010) AS guc_off_same_results;

------------------------------------------------------------
-- Top-level Limit-node authorization. PostgreSQL represents LIMIT and OFFSET
-- with the same plan node, so one planner flag authorizes that wrapper. The
-- cases below cover limit-only, skip-only, skip+limit:1, and neither tracked.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- A limit-only find authorizes its top-level Limit node. Must stream.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "limit": 6 }');
SELECT drain_skip_report(
    '{ "find": "coll", "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9011" }, "collection": "coll", "batchSize": 2 }',
    9011) AS limit_only_tracked_limit;

-- A skip-only find uses the same top-level Limit-node authorization. Must stream.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 14 }');
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 14, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9012" }, "collection": "coll", "batchSize": 2 }',
    9012) AS skip_only_tracked_skip;

-- (limit untracked, skip tracked) with both nodes present: limit 1 is below the
-- streaming threshold (> 1) so the limit is never tracked, while the offset is.
-- The limit node is served natively, so the plan still streams and returns _id 4.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 3, "limit": 1 }');
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 1, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9013" }, "collection": "coll", "batchSize": 2 }',
    9013) AS skip_with_limit1;

-- A projection moves the tracked counts into its generated subquery.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('skiptest', '{ "find": "coll", "skip": 3, "limit": 6, "projection": { "a": 1 } }');
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 6, "projection": { "a": 1 }, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9014" }, "collection": "coll", "batchSize": 2 }',
    9014) AS skip_limit_projection_tracked;

-- On getMore the remaining limit re-authorizes the Limit node after the offset
-- is cleared. The cursor must keep enforcing the limit without re-applying the
-- offset.
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 5, "limit": 7, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9015" }, "collection": "coll", "batchSize": 3 }',
    9015) AS getmore_limit_tracked_skip_not;

------------------------------------------------------------
-- Skip-eligibility gates that can leave a positive skip untracked with limit > 1.
--
-- A tracked limit must not coexist with an untracked offset.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- batchSize 0 streams; its empty resume state preserves the offset.
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 6, "batchSize": 0 }',
    '{ "getMore": { "$numberLong": "9016" }, "collection": "coll", "batchSize": 3 }',
    9016) AS gate_batchsize0;

-- Gate: unsharded collection.
DO $$
BEGIN
    FOR g IN 2..20 LOOP
        PERFORM documentdb_api.insert_one('skiptest', 'sharded',
            FORMAT('{"_id": %s, "sk": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;
SELECT drain_skip_report(
    '{ "find": "sharded", "sort": { "_id": 1 }, "skip": 3, "limit": 6, "projection": { "sk": 1 }, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9018" }, "collection": "sharded", "batchSize": 2 }',
    9018) AS gate_sharded;

-- Gate: collection exists. A missing collection has no offset to mistrack.
SELECT drain_skip_report(
    '{ "find": "missing_coll", "skip": 3, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9019" }, "collection": "missing_coll", "batchSize": 2 }',
    9019) AS gate_missing_collection;

-- Gate: skip is a positive number. Neither case produces an offset node at all
-- (HandleSkip returns early for 0), so the limit streams on its own.
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 0, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9020" }, "collection": "coll", "batchSize": 2 }',
    9020) AS gate_skip_zero;

-- Gate: the dynamic cursor param kind. An aggregation $skip is not the find
-- path, so neither count is tracked.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('skiptest', '{ "aggregate": "coll", "pipeline": [ { "$skip": 3 }, { "$limit": 6 } ], "cursor": { "batchSize": 2 } }');

-- Gate: the feature flag itself.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
SELECT drain_skip_report(
    '{ "find": "coll", "skip": 3, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9021" }, "collection": "coll", "batchSize": 2 }',
    9021) AS gate_guc_off;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

DROP FUNCTION drain_skip_report(text, text, bigint);
