-- ============================================================================
-- Dynamic Cursor Limit Tests
-- ============================================================================
--
-- Validates that a find with a positive limit (> 1) uses a dynamic streaming
-- cursor (DocumentDBApiCursorScan) when enable_dynamic_cursor_with_skiplimit is on, and
-- that the limit is enforced correctly across getMore pages: the remaining count
-- is tracked as a top-level "lim" field in the continuation token, rewritten
-- into each page's LIMIT, and enforced by the executor LIMIT node. Streaming of
-- a limit > 1 is find-only; an aggregation $limit falls back to a persistent
-- cursor. EXPLAIN plans and per-page results are shown verbatim.
--
-- enableExplainScanIndexCosts is turned off so the EXPLAIN output does not
-- include (non-deterministic) index cost estimates.
-- ============================================================================

SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 26100;
SET documentdb.next_collection_index_id TO 26100;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableExplainScanIndexCosts TO off;

-- Seed 10 documents.
DO $$
BEGIN
    FOR g IN 1..10 LOOP
        PERFORM documentdb_api.insert_one('limtest', 'coll',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;

-- Drains a find across pages, asserting the ids, page count and continuation
-- state, and reports the ids seen on each page so a page boundary that emits the
-- wrong rows is visible in the output (a flat id list would not show it). Also
-- reports whether the first page kept the connection, which distinguishes a
-- streaming cursor from the persistent fallback. Explicit projections also
-- include the returned documents.
CREATE OR REPLACE FUNCTION validate_pk_sorted_limit(
    p_find_spec text,
    p_getmore_spec text,
    p_expected_ids int[],
    p_expected_pages int,
    p_disable_flag_after_first bool DEFAULT false,
    p_expected_page_counts int[] DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_ids int[] := '{}';
    v_batch_ids int[];
    v_pages int := 1;
    v_remaining bigint;
    v_cursor_type int;
    v_all text := '';
    v_documents text;
    v_batch_documents text;
    v_has_projection bool := p_find_spec::jsonb ? 'projection';
BEGIN
    SELECT cursorpage, continuation, persistconnection
    INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page('limtest', p_find_spec::bson, 541);

    IF v_persist THEN
        RAISE EXCEPTION 'Expected dynamic streaming cursor';
    END IF;

    SELECT array_agg((value->'_id'->>'$numberInt')::int ORDER BY ordinality),
           COALESCE(string_agg(
               regexp_replace(value::text,
                   '\{"\$numberInt": "(-?[0-9]+)"\}', '\1', 'g'),
               ',' ORDER BY ordinality), '')
    INTO v_batch_ids, v_batch_documents
    FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'firstBatch')
         WITH ORDINALITY;
    v_ids := v_ids || COALESCE(v_batch_ids, '{}');
    v_all := '[' || array_to_string(COALESCE(v_batch_ids, '{}'), ',') || ']';
    v_documents := '[' || v_batch_documents || ']';
    IF p_expected_page_counts IS NOT NULL AND
       cardinality(v_batch_ids) IS DISTINCT FROM p_expected_page_counts[1] THEN
        RAISE EXCEPTION 'Expected % rows on page 1, got %',
            p_expected_page_counts[1], cardinality(v_batch_ids);
    END IF;

    WHILE v_cont IS NOT NULL LOOP
        v_cursor_type :=
            (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int;
        v_remaining :=
            (bson_dollar_project(v_cont, '{ "lim": 1 }') ->> 'lim')::bigint;
        IF v_cursor_type IS DISTINCT FROM 2 OR
           v_remaining IS DISTINCT FROM
               (cardinality(p_expected_ids) - cardinality(v_ids))::bigint THEN
            RAISE EXCEPTION 'Unexpected continuation type %, remaining %',
                v_cursor_type, v_remaining;
        END IF;

        IF p_disable_flag_after_first AND v_pages = 1 THEN
            SET LOCAL documentdb.enable_dynamic_cursor_with_skiplimit TO off;
        END IF;

        SELECT cursorpage, continuation
        INTO v_page, v_cont
        FROM cursor_get_more('limtest', p_getmore_spec::bson, v_cont);

        SELECT array_agg((value->'_id'->>'$numberInt')::int ORDER BY ordinality),
               COALESCE(string_agg(
                   regexp_replace(value::text,
                       '\{"\$numberInt": "(-?[0-9]+)"\}', '\1', 'g'),
                   ',' ORDER BY ordinality), '')
        INTO v_batch_ids, v_batch_documents
        FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'nextBatch')
             WITH ORDINALITY;
        v_ids := v_ids || COALESCE(v_batch_ids, '{}');
        v_all := v_all || ' [' ||
                 array_to_string(COALESCE(v_batch_ids, '{}'), ',') || ']';
        v_documents := v_documents || ' [' || v_batch_documents || ']';
        v_pages := v_pages + 1;
        IF p_expected_page_counts IS NOT NULL AND
           cardinality(v_batch_ids) IS DISTINCT FROM p_expected_page_counts[v_pages] THEN
            RAISE EXCEPTION 'Expected % rows on page %, got %',
                p_expected_page_counts[v_pages], v_pages, cardinality(v_batch_ids);
        END IF;
    END LOOP;

    IF v_ids IS DISTINCT FROM p_expected_ids OR v_pages <> p_expected_pages OR
       (p_expected_page_counts IS NOT NULL AND
        cardinality(p_expected_page_counts) <> v_pages) THEN
        RAISE EXCEPTION 'Expected ids % in % pages, got % in % pages',
            p_expected_ids, p_expected_pages, v_ids, v_pages;
    END IF;

    RETURN FORMAT('persist=%s pages=%s ids=%s%s', v_persist, v_pages, v_all,
        CASE WHEN v_has_projection THEN ' docs=' || v_documents ELSE '' END);
END;
$$;

------------------------------------------------------------
-- Streaming decision (EXPLAIN): a limit > 1 query uses the dynamic streaming
-- cursor (DocumentDBApiCursorScan) only when enable_dynamic_cursor_with_skiplimit is on.
------------------------------------------------------------

-- find with limit 5, streaming enabled: Limit -> ... -> DocumentDBApiCursorScan.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "limit": 5 }');

-- find with limit 5, streaming disabled: no DocumentDBApiCursorScan.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "limit": 5 }');

-- aggregation $limit 4: streaming of a limit > 1 is find-only, so an
-- aggregation $limit falls back to a persistent cursor (no DocumentDBApiCursorScan).
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('limtest', '{ "aggregate": "coll", "pipeline": [ { "$limit": 4 } ], "cursor": {} }');

-- aggregation $limit 4 followed by $match: also a persistent cursor (find-only
-- streaming), so no DocumentDBApiCursorScan below the Limit.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('limtest', '{ "aggregate": "coll", "pipeline": [ { "$limit": 4 }, { "$match": { "a": { "$gte": 1 } } } ], "cursor": {} }');

------------------------------------------------------------
-- Drain correctness: the limit is enforced across getMore pages. Each page's
-- batch count and document ids are shown, along with the stable remaining-limit
-- field from the continuation token and whether more remain.
-- (The projection template is repeated inline so results are shown verbatim.)
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- find limit 5 over batches of 2: ids [1,2], [3,4], [5]; closes after 5.
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 5, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_limit5_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_limit5_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_limit5_page3, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

-- The planner rewrite path restores the remaining limit before planning getMore.
CREATE TEMP TABLE limit_getmore_explain AS
SELECT continuation FROM find_cursor_first_page(
    database => 'limtest',
    commandSpec => '{ "find": "coll", "limit": 5, "batchSize": 2 }',
    cursorId => 540);
SELECT continuation AS explain_cont FROM limit_getmore_explain \gset
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
    SELECT document FROM bson_aggregation_getmore(
        'limtest',
        '{ "getMore": { "$numberLong": "540" }, "collection": "coll", "batchSize": 2 }',
        $cmd$ || quote_literal(:'explain_cont') || $cmd$::documentdb_core.bson);
$cmd$);
DROP TABLE limit_getmore_explain;

-- find limit 100 over batches of 4 on 10 docs: returns all 10 and closes.
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 100, "batchSize": 4 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_limit100_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 4 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_limit100_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 4 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_limit100_page3, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

-- find filter (a >= 2) with limit 3 over batches of 2: ids [2,3], [4]; closes after 3.
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "filter": { "a": { "$gte": 2 } }, "limit": 3, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_filter_limit3_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_filter_limit3_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

-- aggregation $limit 4 + $project over batches of 2: aggregation $limit falls
-- back to a persistent cursor (find-only streaming), which enforces the limit
-- natively. ids [1,2], [3,4]; closes after 4. No top-level "lim" is tracked.
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM aggregate_cursor_first_page('limtest', '{ "aggregate": "coll", "pipeline": [ { "$limit": 4 }, { "$project": { "a": 1 } } ], "cursor": { "batchSize": 2 } }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "docs": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }'::bson) AS agg_limit4_project_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "docs": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }'::bson) AS agg_limit4_project_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

------------------------------------------------------------
-- Only a top-level LIMIT is streamed. These stress that a find keeps the limit
-- top-level so the getMore rewrite (which rewrites the top-level query->limitCount
-- to the remaining) stays correct. A runtime sort remains persistent, while an
-- index-provided sort can stream.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- find with a projection + limit 5 over batches of 2: the projection replaces the
-- target list without wrapping, so the limit stays top-level and streams; the
-- remaining "lim" is tracked (3, 1) and it closes after 5. ids [1,2], [3,4], [5].
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "projection": { "a": 1 }, "limit": 5, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "docs": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }'::bson) AS find_proj_limit5_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "docs": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }'::bson) AS find_proj_limit5_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "docs": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }'::bson) AS find_proj_limit5_page3, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

-- An unindexed sort needs a blocking Sort and therefore remains persistent.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "sort": { "a": -1 }, "limit": 5 }');

-- ... and drains correctly (sorted, no top-level "lim"): ids [10,9], [8,7], [6];
-- closes after 5.
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "sort": { "a": -1 }, "limit": 5, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_sort_limit5_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_sort_limit5_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS find_sort_limit5_page3, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

------------------------------------------------------------
-- Adversarial eligibility checks. Each query has a positive top-level find
-- limit, but another property makes dynamic limit streaming ineligible.
------------------------------------------------------------

-- An index-provided sort remains streamable.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "sort": { "_id": 1 }, "limit": 5 }');

SELECT validate_pk_sorted_limit(
    '{ "find": "coll", "sort": { "_id": 1 }, "limit": 5, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "541" }, "collection": "coll", "batchSize": 2 }',
    ARRAY[1,2,3,4,5], 3) AS pk_sort_asc_limit;

SELECT validate_pk_sorted_limit(
    '{ "find": "coll", "sort": { "_id": -1 }, "limit": 5, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "541" }, "collection": "coll", "batchSize": 2 }',
    ARRAY[10,9,8,7,6], 3) AS pk_sort_desc_limit;

-- Limit smaller than batch size closes on the first page.
SELECT validate_pk_sorted_limit(
    '{ "find": "coll", "sort": { "_id": 1 }, "limit": 3, "batchSize": 10 }',
    '{ "getMore": { "$numberLong": "541" }, "collection": "coll", "batchSize": 10 }',
    ARRAY[1,2,3], 1) AS pk_sort_limit_lt_batch;

-- An exact multiple of batch size closes without an extra empty page.
SELECT validate_pk_sorted_limit(
    '{ "find": "coll", "sort": { "_id": 1 }, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "541" }, "collection": "coll", "batchSize": 2 }',
    ARRAY[1,2,3,4], 2) AS pk_sort_limit_eq_batches;

-- Filter and projection preserve the ordered streaming limit.
SELECT validate_pk_sorted_limit(
    '{ "find": "coll", "filter": { "_id": { "$gte": 3 } }, "sort": { "_id": 1 }, "projection": { "_id": 1, "a": 1 }, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "541" }, "collection": "coll", "batchSize": 2 }',
    ARRAY[3,4,5], 2) AS pk_sort_filter_project_limit;

-- The continuation, not the live GUC, authorizes a sorted cursor after page 1.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
SELECT validate_pk_sorted_limit(
    '{ "find": "coll", "sort": { "_id": -1 }, "limit": 5, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "541" }, "collection": "coll", "batchSize": 2 }',
    ARRAY[10,9,8,7,6], 3, true) AS pk_sort_guc_toggle;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- Resuming a sorted streaming cursor must reconstruct the required ordering from
-- the continuation's recorded scan type, independently of the planner GUCs in
-- effect on the getMore. This pins the property that keeps the "Cannot resume
-- ... with the required ordering" guards in GeneratePathFromContinuation
-- unreachable: if a resume ever became sensitive to these settings it would
-- start failing in-flight cursors instead of silently changing plan shape.
-- The scan GUCs are disabled only for the getMore, after the first page has
-- already chosen a streaming index scan.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
SELECT cursorpage AS page, continuation AS cont, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "sort": { "_id": 1 }, "limit": 5, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id" }'::bson) AS resume_gucs_page1;
SET enable_indexscan TO off;
SET enable_indexonlyscan TO off;
SET enable_bitmapscan TO off;
SELECT cursorpage AS page, continuation AS cont FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }'::bson) AS resume_gucs_page2_scan_disabled;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;

-- A non-zero skip enters the limit streaming path only when the skip is itself
-- tracked; the single flag authorizes both counts, so skip + limit streams.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "skip": 1, "limit": 5 }');

-- A projection moves both tracked counts into its generated subquery, where
-- they remain streamable as a unit.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "skip": 1, "limit": 5, "projection": { "a": 1 } }');

-- limit 1 is intentionally below the streaming eligibility threshold (> 1): a
-- single-row result is served by the single-batch cursor, which returns the row
-- and closes without a cursor at all, so no remaining limit is ever tracked for
-- it. Streaming authorization therefore stays exactly equivalent to "the
-- remaining limit is carried in the continuation".
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "limit": 1 }');
-- batchSize >= 1: single batch, exactly one document, cursor closed, no "lim".
SELECT cursorpage AS page, continuation IS NULL AS no_continuation FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 1, "batchSize": 1 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": "$cursor.firstBatch" }, "ids": "$cursor.firstBatch._id" }'::bson) AS limit1_batch1, :'no_continuation'::bool AS no_continuation;
SELECT cursorpage AS page, continuation IS NULL AS no_continuation FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 1, "batchSize": 5 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": "$cursor.firstBatch" }, "ids": "$cursor.firstBatch._id" }'::bson) AS limit1_batch5, :'no_continuation'::bool AS no_continuation;
-- batchSize 0 is the one limit 1 shape the single-batch cursor does not claim.
-- It must not be streamed (no "lim" is tracked), and it must still return
-- exactly one document across the two pages.
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 1, "batchSize": 0 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": "$cursor.firstBatch" } }'::bson) AS limit1_batch0_page1, :'stable_cont'::bson AS continuation_no_lim;
SELECT cursorpage AS page, continuation IS NULL AS no_continuation FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 5 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": "$cursor.nextBatch" }, "ids": "$cursor.nextBatch._id" }'::bson) AS limit1_batch0_page2, :'no_continuation'::bool AS no_continuation;

-- singleBatch owns cursor lifetime and must not create a dynamic continuation.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "limit": 5, "singleBatch": true }');
SELECT cursorpage AS page, continuation IS NULL AS no_continuation, cursorid = 0 AS closed FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 5, "singleBatch": true, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id" }'::bson) AS single_batch_limit, :'no_continuation'::bool AS no_continuation, :'closed'::bool AS closed;

-- An exact _id predicate uses the point-read path rather than a dynamic cursor.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "coll", "filter": { "_id": 5 }, "limit": 5 }');
SELECT cursorpage AS page, continuation IS NULL AS no_continuation, cursorid = 0 AS closed FROM find_cursor_first_page('limtest', '{ "find": "coll", "filter": { "_id": 5 }, "limit": 5, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id" }'::bson) AS point_read_limit, :'no_continuation'::bool AS no_continuation, :'closed'::bool AS closed;

-- Dynamic limit streaming is restricted to unsharded collections.
DO $$
BEGIN
    PERFORM documentdb_api.insert_one('limtest', 'sharded',
        '{ "_id": 1, "sk": 1 }'::documentdb_core.bson);
    PERFORM documentdb_api.shard_collection('limtest', 'sharded',
        '{ "sk": "hashed" }'::documentdb_core.bson, false);
END;
$$;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('limtest', '{ "find": "sharded", "limit": 5 }');

------------------------------------------------------------
-- Cursor lifetime is independent of the GUC: a cursor that started streaming
-- (GUC on) must keep resuming across getMore even if enable_dynamic_cursor_with_skiplimit
-- is turned OFF between pages -- the continuation ("lim") authorizes the resume,
-- not the live GUC. find limit 5 over batches of 2: ids [1,2], [3,4], [5]; the
-- remaining "lim" is still tracked (3, 1) and it closes after 5.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 5, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS guc_toggle_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
-- Turn the feature off mid-cursor; the in-flight cursor must still resume.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS guc_toggle_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS guc_toggle_page3, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

------------------------------------------------------------
-- Invalid remaining-limit state fails closed instead of running the original
-- unbounded page limit.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
SELECT continuation AS validation_cont FROM find_cursor_first_page(
    database => 'limtest',
    commandSpec => '{ "find": "coll", "limit": 5, "batchSize": 2 }',
    cursorId => 539) \gset

SELECT bson_dollar_add_fields(:'validation_cont'::bson, '{ "lim": "invalid" }'::bson) AS invalid_cont \gset
SELECT cursorpage FROM cursor_get_more(
    'limtest',
    '{ "getMore": { "$numberLong": "539" }, "collection": "coll", "batchSize": 2 }',
    :'invalid_cont'::bson);

SELECT bson_dollar_add_fields(:'validation_cont'::bson, '{ "lim": { "$numberLong": "0" } }'::bson) AS invalid_cont \gset
SELECT cursorpage FROM cursor_get_more(
    'limtest',
    '{ "getMore": { "$numberLong": "539" }, "collection": "coll", "batchSize": 2 }',
    :'invalid_cont'::bson);

SELECT bson_dollar_add_fields(:'validation_cont'::bson, '{ "lim": { "$numberLong": "6" } }'::bson) AS invalid_cont \gset
SELECT cursorpage FROM cursor_get_more(
    'limtest',
    '{ "getMore": { "$numberLong": "539" }, "collection": "coll", "batchSize": 2 }',
    :'invalid_cont'::bson);

SELECT bson_dollar_add_fields(:'validation_cont'::bson, '{ "qk": 2 }'::bson) AS invalid_cont \gset
SELECT cursorpage FROM cursor_get_more(
    'limtest',
    '{ "getMore": { "$numberLong": "539" }, "collection": "coll", "batchSize": 2 }',
    :'invalid_cont'::bson);

SELECT bson_dollar_add_fields(:'validation_cont'::bson, '{ "qd": { "$literal": { "find": "coll", "batchSize": 2 } } }'::bson) AS invalid_cont \gset
SELECT cursorpage FROM cursor_get_more(
    'limtest',
    '{ "getMore": { "$numberLong": "539" }, "collection": "coll", "batchSize": 2 }',
    :'invalid_cont'::bson);

------------------------------------------------------------
-- With streaming disabled, results are still correct (persistent cursor path).
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;

-- find limit 5 over batches of 2: same ids [1,2], [3,4], [5]; closes after 5.
SELECT cursorpage AS page, continuation AS cont, (continuation IS NOT NULL) AS more, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "coll", "limit": 5, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS guc_off_page1, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS guc_off_page2, :'more'::bool AS has_more;
SELECT cursorpage AS page, continuation AS cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "coll", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::bson) AS guc_off_page3, :'more'::bool AS has_more;

------------------------------------------------------------
-- Remote worker path: invoke the worker drain UDF (cursor_dynamic_drain_page)
-- directly, as the coordinator dispatches it to a Citus worker for a remote
-- unsharded collection. The worker streams the find limit > 1 query (a "dc"
-- dynamic streaming continuation, not a "qf" file cursor) and tracks the
-- remaining limit as a top-level "lim" field in its own continuation across
-- pages, closing at the limit. The UDF returns bson[]: [1] cursor page,
-- [2] { "ct": <type> } (0 = drained, 5 = has more), [3] the worker continuation
-- (SQL NULL when drained).
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- Resolve the collection's shard table for the direct UDF call.
SELECT format('documentdb_data.documents_%s', collection_id) AS shardtbl FROM documentdb_api_catalog.collections WHERE database_name = 'limtest' AND collection_name = 'coll' \gset

-- worker first page: ids [1,2], ct 5 (has more), streaming (dc), remaining lim 3.
SELECT r[1] AS batch, r[2] AS meta, r[3] AS wc FROM documentdb_api_internal.cursor_dynamic_drain_page('limtest', '{ "find": "coll", "limit": 5, "batchSize": 2 }'::bson, :'shardtbl'::regclass, '{}'::bson, 1, '{ "p_use_file_based_cursor": true, "p_batch_size": 2, "p_namespace": "limtest.coll" }'::bson) AS r \gset
SELECT bson_dollar_project(:'batch'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id" }'::bson) AS worker_page1, :'meta'::bson AS ct, bson_dollar_project(:'wc'::bson, '{ "_id": 0, "streaming_dc": { "$cond": [ "$dc", true, false ] }, "file_qf": { "$cond": [ "$qf", true, false ] }, "remaining_lim": "$lim" }'::bson) AS wc_info;

-- worker getMore page 2: ids [3,4], ct 5, remaining lim 1.
SELECT r[1] AS batch, r[2] AS meta, r[3] AS wc FROM documentdb_api_internal.cursor_dynamic_drain_page('limtest', '{ "find": "coll", "limit": 5, "batchSize": 2 }'::bson, :'shardtbl'::regclass, :'wc'::bson, 1, '{ "p_use_file_based_cursor": true, "p_batch_size": 2, "p_namespace": "limtest.coll" }'::bson) AS r \gset
SELECT bson_dollar_project(:'batch'::bson, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }'::bson) AS worker_page2, :'meta'::bson AS ct, bson_dollar_project(:'wc'::bson, '{ "_id": 0, "remaining_lim": "$lim" }'::bson) AS wc_info;

-- worker getMore page 3: ids [5], ct 0 (drained), no worker continuation.
SELECT r[1] AS batch, r[2] AS meta, (r[3] IS NULL) AS drained FROM documentdb_api_internal.cursor_dynamic_drain_page('limtest', '{ "find": "coll", "limit": 5, "batchSize": 2 }'::bson, :'shardtbl'::regclass, :'wc'::bson, 1, '{ "p_use_file_based_cursor": true, "p_batch_size": 2, "p_namespace": "limtest.coll" }'::bson) AS r \gset
SELECT bson_dollar_project(:'batch'::bson, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }'::bson) AS worker_page3, :'meta'::bson AS ct, :'drained'::bool AS drained;

------------------------------------------------------------
-- Large-limit stress: the previous held-portal path had to materialize the
-- entire 100,001-row result before returning. Dynamic streaming must return
-- only each requested batch, without a persistent connection, while keeping
-- the remaining limit above the 32-bit range across getMore.
------------------------------------------------------------
DO $$
BEGIN
    PERFORM documentdb_api.insert_one('limtest', 'stress',
        '{ "_id": 0, "a": 0 }'::documentdb_core.bson);
END;
$$;
SELECT format('documentdb_data.documents_%s', collection_id) AS stresstable, collection_id AS stressid FROM documentdb_api_catalog.collections WHERE database_name = 'limtest' AND collection_name = 'stress' \gset
WITH docs AS (
    SELECT bson_build_document('_id', g, 'a', g) AS document
    FROM generate_series(1, 100000) g
)
INSERT INTO :stresstable (shard_key_value, object_id, document)
SELECT :stressid, bson_get_value(document, '_id'), document FROM docs;
ANALYZE :stresstable;

SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more, persistconnection AS persistent, cursorid AS cid FROM find_cursor_first_page('limtest', '{ "find": "stress", "limit": 3000000000, "batchSize": 2 }') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": "$cursor.firstBatch" }, "ids": "$cursor.firstBatch._id" }'::bson) AS find_limit3b_page1, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more, :'persistent'::bool AS persist_connection;
SELECT cursorpage AS page, continuation AS cont, COALESCE(bson_dollar_project(continuation, '{ "lim": 1 }'::bson), '{}'::bson) AS stable_cont, (continuation IS NOT NULL) AS more FROM cursor_get_more('limtest', ('{ "getMore": ' || :'cid' || ', "collection": "stress", "batchSize": 2 }')::bson, :'cont'::bson) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "batchCount": { "$size": "$cursor.nextBatch" }, "ids": "$cursor.nextBatch._id" }'::bson) AS find_limit3b_page2, :'stable_cont'::bson AS continuation, :'more'::bool AS has_more;

------------------------------------------------------------
-- Response-size termination does not consume the fetched-but-unemitted row.
-- Two approximately 6 MB documents fit in page 1; the third resumes on page 2.
------------------------------------------------------------
SELECT COUNT(documentdb_api.insert_one(
    'limtest', 'size_limit',
    FORMAT('{ "_id": %s, "payload": "%s" }', i, repeat('x', 6000000))::bson))
FROM generate_series(1, 3) i;

SELECT validate_pk_sorted_limit(
    '{ "find": "size_limit", "sort": { "_id": 1 }, "limit": 3, "batchSize": 10 }',
    '{ "getMore": { "$numberLong": "541" }, "collection": "size_limit", "batchSize": 10 }',
    ARRAY[1,2,3], 2, false, ARRAY[2,1]) AS pk_sort_response_size_limit;

------------------------------------------------------------
-- Cleanup
------------------------------------------------------------
SELECT documentdb_api.drop_collection('limtest', 'coll');
SELECT documentdb_api.drop_collection('limtest', 'sharded');
SELECT documentdb_api.drop_collection('limtest', 'stress');
SELECT documentdb_api.drop_collection('limtest', 'size_limit');

DROP FUNCTION validate_pk_sorted_limit(text, text, int[], int, bool, int[]);
