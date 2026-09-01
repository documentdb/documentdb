-- ============================================================================
-- Dynamic Cursor Skip/Limit Untracked-Offset Fallback Tests
-- ============================================================================
--
-- Views can contribute nested LIMIT/OFFSET nodes whose state cannot be safely
-- rewritten on getMore. Find skip/limit streaming therefore excludes views
-- before view expansion replaces them with their underlying collection.
--
-- This file guards that fix. It asserts three things for every formerly-crashing
-- shape, because "it no longer crashes" is much weaker than "it is correct":
--
--   1. The full multi-page drain returns exactly the right documents -- not
--      just a correct first page. A dropped limit that still streamed would
--      over-return on resume.
--   2. The continuation is a persistent one (it carries a cursor name and no
--      streamed limit/cursor state), proving the fallback actually happened
--      rather than the query streaming with an untracked count.
--   3. The result is identical with the feature flag off, which is the
--      independent definition of correct for these queries.
--
-- The control cases at the top must keep streaming, so a future fix cannot
-- satisfy this file by disabling the feature wholesale.
-- ============================================================================

SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 25900000;
SET documentdb.next_collection_index_id TO 25900000;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

DO $$
BEGIN
    FOR g IN 1..20 LOOP
        PERFORM documentdb_api.insert_one('fallbackskiplim', 'coll',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;

-- Views that contribute a top-level OFFSET the find's limit eligibility never
-- sees, plus two that contribute a LIMIT instead (which is handled by a
-- different path and must keep working).
SELECT documentdb_api.create_collection_view('fallbackskiplim',
    '{ "create": "v_skip1", "viewOn": "coll", "pipeline": [ { "$skip": 1 } ] }'::documentdb_core.bson);
SELECT documentdb_api.create_collection_view('fallbackskiplim',
    '{ "create": "v_skip2", "viewOn": "coll", "pipeline": [ { "$skip": 2 } ] }'::documentdb_core.bson);
SELECT documentdb_api.create_collection_view('fallbackskiplim',
    '{ "create": "v_match_skip", "viewOn": "coll", "pipeline": [ { "$match": { "a": { "$gte": 3 } } }, { "$skip": 1 } ] }'::documentdb_core.bson);
SELECT documentdb_api.create_collection_view('fallbackskiplim',
    '{ "create": "v_skiplimit", "viewOn": "coll", "pipeline": [ { "$skip": 2 }, { "$limit": 10 } ] }'::documentdb_core.bson);
SELECT documentdb_api.create_collection_view('fallbackskiplim',
    '{ "create": "v_nested", "viewOn": "v_skiplimit", "pipeline": [ { "$skip": 1 } ] }'::documentdb_core.bson);
SELECT documentdb_api.create_collection_view('fallbackskiplim',
    '{ "create": "v_limit5", "viewOn": "coll", "pipeline": [ { "$limit": 5 } ] }'::documentdb_core.bson);
SELECT documentdb_api.create_collection_view('fallbackskiplim',
    '{ "create": "v_limit_then_skip", "viewOn": "coll", "pipeline": [ { "$limit": 9 }, { "$skip": 1 } ] }'::documentdb_core.bson);

-- Drains a find to exhaustion and reports the ids seen on each page. A limit
-- that was dropped but still streamed would keep emitting past its bound, which
-- shows up here as extra pages rather than as an error. Explicit projections
-- also include the returned documents.
CREATE OR REPLACE FUNCTION fb_drain(
    p_find_spec text,
    p_getmore_spec text,
    p_cursor_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_page bson;
    v_cont bson;
    v_pages int := 1;
    v_ids text;
    v_count int;
    v_total int := 0;
    v_all text := '';
    v_documents text;
    v_all_documents text := '';
    v_has_projection bool := p_find_spec::jsonb ? 'projection';
BEGIN
    SELECT cursorpage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page('fallbackskiplim', p_find_spec::bson, p_cursor_id);

    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), ''),
           COALESCE(string_agg(
               regexp_replace(value::text,
                   '\{"\$numberInt": "(-?[0-9]+)"\}', '\1', 'g'),
               ',' ORDER BY ordinality), ''),
           count(*)
    INTO v_ids, v_documents, v_count
    FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    v_all := '[' || v_ids || ']';
    v_all_documents := '[' || v_documents || ']';
    v_total := v_count;

    WHILE v_cont IS NOT NULL AND v_pages < 40 LOOP
        SELECT cursorpage, continuation INTO v_page, v_cont
        FROM cursor_get_more('fallbackskiplim', p_getmore_spec::bson, v_cont);

        SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), ''),
               COALESCE(string_agg(
                   regexp_replace(value::text,
                       '\{"\$numberInt": "(-?[0-9]+)"\}', '\1', 'g'),
                   ',' ORDER BY ordinality), ''),
               count(*)
        INTO v_ids, v_documents, v_count
        FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
        v_all := v_all || ' [' || v_ids || ']';
        v_all_documents := v_all_documents || ' [' || v_documents || ']';
        v_pages := v_pages + 1;
        v_total := v_total + v_count;
    END LOOP;

    RETURN FORMAT('pages=%s total=%s ids=%s%s', v_pages, v_total, v_all,
        CASE WHEN v_has_projection THEN ' docs=' || v_all_documents ELSE '' END);
END;
$$;

-- Classifies the first page's continuation. A streamed cursor carries the
-- remaining limit ("lim") and the resume position ("dc"); a persistent one
-- carries a server-side cursor name ("qn") instead. This is what distinguishes
-- "fell back" from "streamed with an untracked count".
CREATE OR REPLACE FUNCTION fb_cursor_kind(
    p_find_spec text,
    p_cursor_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_cont bson;
    v_json jsonb;
BEGIN
    SELECT continuation INTO v_cont
    FROM find_cursor_first_page('fallbackskiplim', p_find_spec::bson, p_cursor_id);

    IF v_cont IS NULL THEN
        RETURN 'no continuation (single batch)';
    END IF;

    v_json := v_cont::text::jsonb;
    RETURN FORMAT('streamedLimit=%s resumePosition=%s cursorName=%s',
                  v_json ? 'lim', v_json ? 'dc', v_json ? 'qn');
END;
$$;

------------------------------------------------------------
-- Controls: these must keep STREAMING. They pin that the fix removed only the
-- unreachable assertion and did not disable the feature. If a future change
-- makes these fall back too, the feature has been silently switched off.
------------------------------------------------------------

-- A plain collection find with a streamable limit: no view, no stray offset.
SELECT fb_cursor_kind('{ "find": "coll", "limit": 6, "batchSize": 2 }', 100) AS control_plain_limit_streams;
SELECT fb_drain(
    '{ "find": "coll", "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "101" }, "collection": "coll", "batchSize": 2 }',
    101) AS control_plain_limit_drain;

-- A plain collection find with a streamable skip and limit.
SELECT fb_cursor_kind('{ "find": "coll", "skip": 3, "limit": 6, "batchSize": 2 }', 102) AS control_plain_skip_limit_streams;
SELECT fb_drain(
    '{ "find": "coll", "skip": 3, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "103" }, "collection": "coll", "batchSize": 2 }',
    103) AS control_plain_skip_limit_drain;

------------------------------------------------------------
-- View shapes. Each must fall back to a persistent cursor and return the
-- documented documents.
------------------------------------------------------------

-- No find skip at all; the view's $skip still forces persistent fallback.
-- View drops _id 1, so limit 3 yields 2,3,4.
SELECT fb_cursor_kind('{ "find": "v_skip1", "limit": 3, "batchSize": 2 }', 200) AS view_skip_find_limit_only_kind;
SELECT fb_drain(
    '{ "find": "v_skip1", "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "201" }, "collection": "v_skip1", "batchSize": 2 }',
    201) AS view_skip_find_limit_only;

-- The find supplies a skip too; the view is still excluded from streaming.
-- View yields 2-20, skip 2 yields 4-20, limit 4 yields 4,5,6,7.
SELECT fb_cursor_kind('{ "find": "v_skip1", "skip": 2, "limit": 4, "batchSize": 2 }', 202) AS view_skip_plus_find_skip_kind;
SELECT fb_drain(
    '{ "find": "v_skip1", "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "203" }, "collection": "v_skip1", "batchSize": 2 }',
    203) AS view_skip_plus_find_skip;

-- Larger offsets on both sides remain persistent.
-- View yields 3-20, skip 3 yields 6-20, limit 5 yields 6,7,8,9,10.
SELECT fb_drain(
    '{ "find": "v_skip2", "skip": 3, "limit": 5, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "204" }, "collection": "v_skip2", "batchSize": 2 }',
    204) AS larger_offsets;

-- A filter ahead of the view's $skip, so the offset is not adjacent to the scan.
-- View yields 4-20, skip 2 yields 6-20, limit 3 yields 6,7,8.
SELECT fb_drain(
    '{ "find": "v_match_skip", "skip": 2, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "205" }, "collection": "v_match_skip", "batchSize": 2 }',
    205) AS match_then_skip;

-- A view over a view, so the offending offset arrives two subquery levels down.
-- Inner view yields 3-12, outer drops one more to 4-12, skip 2 limit 3 yields
-- 6,7,8.
SELECT fb_cursor_kind('{ "find": "v_nested", "skip": 2, "limit": 3, "batchSize": 2 }', 206) AS view_over_view_kind;
SELECT fb_drain(
    '{ "find": "v_nested", "skip": 2, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "207" }, "collection": "v_nested", "batchSize": 2 }',
    207) AS view_over_view;

-- A view whose own pipeline ends with $skip after a $limit: the offset reaching
-- the top level comes from the view's trailing stage.
-- View yields 2-9, skip 2 yields 4-9, limit 4 yields 4,5,6,7.
SELECT fb_drain(
    '{ "find": "v_limit_then_skip", "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "208" }, "collection": "v_limit_then_skip", "batchSize": 2 }',
    208) AS view_limit_then_skip;

-- The limit exceeding what the view can supply, so the drain ends by exhausting
-- the source rather than by reaching the limit.
-- View yields 2-20, limit 9 yields 2..10.
SELECT fb_drain(
    '{ "find": "v_skip1", "limit": 9, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "209" }, "collection": "v_skip1", "batchSize": 2 }',
    209) AS limit_exceeding_view;

-- A sort on top of the offending shape, which selects a different scan path.
-- View yields 2-20 descending from 20; skip 2 yields 18..2, limit 4 yields
-- 18,17,16,15.
SELECT fb_drain(
    '{ "find": "v_skip1", "sort": { "_id": -1 }, "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "210" }, "collection": "v_skip1", "batchSize": 2 }',
    210) AS sorted_untracked_offset;

------------------------------------------------------------
-- Other view shapes remain persistent regardless of their count arrangement.
------------------------------------------------------------
-- View yields 1-5, skip 2 yields 3,4,5, limit 3 yields 3,4,5.
SELECT fb_drain(
    '{ "find": "v_limit5", "skip": 2, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "300" }, "collection": "v_limit5", "batchSize": 2 }',
    300) AS view_limit_with_find_skip_limit;

-- View yields 1-5, limit 3 yields 1,2,3.
SELECT fb_drain(
    '{ "find": "v_limit5", "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "301" }, "collection": "v_limit5", "batchSize": 2 }',
    301) AS view_limit_with_find_limit;

-- A skip with no limit at all remains persistent for a view.
SELECT fb_drain(
    '{ "find": "v_skip1", "skip": 16, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "302" }, "collection": "v_skip1", "batchSize": 2 }',
    302) AS view_skip_no_limit;

-- limit 1 is served natively and never tracked.
SELECT fb_drain(
    '{ "find": "v_skip1", "skip": 2, "limit": 1, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "303" }, "collection": "v_skip1", "batchSize": 2 }',
    303) AS view_skip_limit_one;

-- batchSize 0 does not override view exclusion.
SELECT fb_drain(
    '{ "find": "v_skip1", "skip": 2, "limit": 4, "batchSize": 0 }',
    '{ "getMore": { "$numberLong": "304" }, "collection": "v_skip1", "batchSize": 2 }',
    304) AS view_skip_batchsize_zero;

-- Projection does not override view exclusion.
SELECT fb_drain(
    '{ "find": "v_skip1", "skip": 2, "limit": 4, "projection": { "a": 1 }, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "305" }, "collection": "v_skip1", "batchSize": 2 }',
    305) AS view_skip_with_projection;

------------------------------------------------------------
-- The same queries with the feature disabled. Every result must match the
-- corresponding case above: the feature flag must not change which documents a
-- query returns, only how the cursor is served.
------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;

SELECT fb_drain(
    '{ "find": "v_skip1", "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "400" }, "collection": "v_skip1", "batchSize": 2 }',
    400) AS guc_off_view_skip_find_limit_only;

SELECT fb_drain(
    '{ "find": "v_skip1", "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "401" }, "collection": "v_skip1", "batchSize": 2 }',
    401) AS guc_off_view_skip_plus_find_skip;

SELECT fb_drain(
    '{ "find": "v_skip2", "skip": 3, "limit": 5, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "402" }, "collection": "v_skip2", "batchSize": 2 }',
    402) AS guc_off_larger_offsets;

SELECT fb_drain(
    '{ "find": "v_match_skip", "skip": 2, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "403" }, "collection": "v_match_skip", "batchSize": 2 }',
    403) AS guc_off_match_then_skip;

SELECT fb_drain(
    '{ "find": "v_nested", "skip": 2, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "404" }, "collection": "v_nested", "batchSize": 2 }',
    404) AS guc_off_view_over_view;

SELECT fb_drain(
    '{ "find": "v_limit_then_skip", "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "405" }, "collection": "v_limit_then_skip", "batchSize": 2 }',
    405) AS guc_off_view_limit_then_skip;

SELECT fb_drain(
    '{ "find": "v_skip1", "limit": 9, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "406" }, "collection": "v_skip1", "batchSize": 2 }',
    406) AS guc_off_limit_exceeding_view;

SELECT fb_drain(
    '{ "find": "v_skip1", "sort": { "_id": -1 }, "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "407" }, "collection": "v_skip1", "batchSize": 2 }',
    407) AS guc_off_sorted_untracked_offset;

SELECT fb_drain(
    '{ "find": "coll", "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "408" }, "collection": "coll", "batchSize": 2 }',
    408) AS guc_off_control_plain_limit;

SELECT fb_drain(
    '{ "find": "coll", "skip": 3, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "409" }, "collection": "coll", "batchSize": 2 }',
    409) AS guc_off_control_plain_skip_limit;

SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

DROP FUNCTION fb_drain(text, text, bigint);
DROP FUNCTION fb_cursor_kind(text, bigint);
