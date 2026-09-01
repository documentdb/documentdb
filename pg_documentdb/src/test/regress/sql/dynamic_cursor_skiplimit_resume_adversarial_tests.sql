-- ============================================================================
-- Dynamic Cursor Skip/Limit Resume Adversarial Tests
-- ============================================================================
--
-- Covers query-scoped authorization, continuation replay, page termination, and
-- streamable shapes. Each case checks returned documents for silent wrong answers.
--
-- enableExplainScanIndexCosts is off so EXPLAIN omits index cost estimates.
-- ============================================================================

SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 25940000;
SET documentdb.next_collection_index_id TO 25940000;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- Contiguous ids expose repeated offsets, dropped documents, and early stops.
DO $$
BEGIN
    FOR g IN 1..20 LOOP
        PERFORM documentdb_api.insert_one('resadv', 'coll',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
        PERFORM documentdb_api.insert_one('resadv', 'sh',
            FORMAT('{"_id": %s, "sk": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;

-- Report per-page ids and totals to expose boundary errors and early stops.
CREATE OR REPLACE FUNCTION res_drain(
    p_find_spec text,
    p_getmore_spec text,
    p_cursor_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_page bson; v_cont bson; v_persist bool;
    v_ids text; v_count int; v_pages int := 1; v_total int := 0; v_all text := '';
BEGIN
    SELECT cursorpage, continuation, persistconnection
    INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page('resadv', p_find_spec::bson, p_cursor_id);

    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), ''),
           count(*)
    INTO v_ids, v_count
    FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    v_all := '[' || v_ids || ']';
    v_total := v_count;

    -- Bound incorrect continuations that never retire.
    WHILE v_cont IS NOT NULL AND v_pages < 30 LOOP
        SELECT cursorpage, continuation INTO v_page, v_cont
        FROM cursor_get_more('resadv', p_getmore_spec::bson, v_cont);

        SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), ''),
               count(*)
        INTO v_ids, v_count
        FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
        v_all := v_all || ' [' || v_ids || ']';
        v_pages := v_pages + 1;
        v_total := v_total + v_count;
    END LOOP;

    RETURN FORMAT('persist=%s pages=%s total=%s ids=%s',
                  v_persist, v_pages, v_total, v_all);
END;
$$;

------------------------------------------------------------
-- 1. Planner authorization carried by the query.
--
-- Authorization must reach only the query for which it was computed.
------------------------------------------------------------

-- Interleave a skip-only cursor and a limit-only cursor to detect authorization
-- leaking between queries.
DO $$
DECLARE
    pa bson; ca bson; pb bson; cb bson;
    ids_a text := ''; ids_b text := ''; b text;
BEGIN
    SELECT cursorpage, continuation INTO pa, ca FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "batchSize": 2 }'::bson, 8401);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality),'') INTO b
    FROM jsonb_array_elements((pa::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    ids_a := '[' || b || ']';

    SELECT cursorpage, continuation INTO pb, cb FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "limit": 6, "batchSize": 2 }'::bson, 8402);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality),'') INTO b
    FROM jsonb_array_elements((pb::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    ids_b := '[' || b || ']';

    FOR i IN 1..3 LOOP
        IF ca IS NOT NULL THEN
            SELECT cursorpage, continuation INTO pa, ca FROM cursor_get_more('resadv',
                '{ "getMore": { "$numberLong": "8401" }, "collection": "coll", "batchSize": 2 }'::bson, ca);
            SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality),'') INTO b
            FROM jsonb_array_elements((pa::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
            ids_a := ids_a || ' [' || b || ']';
        END IF;
        IF cb IS NOT NULL THEN
            SELECT cursorpage, continuation INTO pb, cb FROM cursor_get_more('resadv',
                '{ "getMore": { "$numberLong": "8402" }, "collection": "coll", "batchSize": 2 }'::bson, cb);
            SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality),'') INTO b
            FROM jsonb_array_elements((pb::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
            ids_b := ids_b || ' [' || b || ']';
        END IF;
    END LOOP;
    RAISE NOTICE 'interleaved skip cursor  = %', ids_a;
    RAISE NOTICE 'interleaved limit cursor = %', ids_b;
END;
$$;

-- A failed request must not retain authorization for later queries.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('resadv', '{ "find": "coll", "skip": 3 }');
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

DO $$
BEGIN
    PERFORM cursorpage FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "skip": 2, "limit": 5, "batchSize": 2, "hint": "no_such_index" }'::bson, 8403);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'hint error: %', SQLERRM;
END;
$$;

SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('resadv', '{ "find": "coll", "skip": 3 }');
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- Reject an injected remaining limit without retaining authorization.
DO $$
DECLARE p bson; c bson; c2 bson;
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "batchSize": 2 }'::bson, 8404);
    c2 := (c::text::jsonb || '{"lim": {"$numberLong": "2"}}'::jsonb)::text::bson;
    BEGIN
        PERFORM cursorpage FROM cursor_get_more('resadv',
            '{ "getMore": { "$numberLong": "8404" }, "collection": "coll", "batchSize": 5 }'::bson, c2);
        RAISE NOTICE 'injected remaining limit was accepted';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'injected remaining limit rejected [%]: %', SQLSTATE, SQLERRM;
    END;
END;
$$;

SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('resadv', '{ "find": "coll", "skip": 3 }');
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- Generic plans cannot read authorization from an unresolved tracker parameter.
-- Replaying one continuation compares generic and custom plans.
SELECT continuation AS gcont FROM find_cursor_first_page('resadv',
    '{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "limit": 6, "batchSize": 2 }'::bson, 8405) \gset

PREPARE resume_page(bson) AS
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS generic_plan_resume
FROM cursor_get_more('resadv',
    '{ "getMore": { "$numberLong": "8405" }, "collection": "coll", "batchSize": 2 }'::bson, $1);

EXECUTE resume_page(:'gcont'::bson);
SET plan_cache_mode TO force_generic_plan;
EXECUTE resume_page(:'gcont'::bson);
EXECUTE resume_page(:'gcont'::bson);
SET plan_cache_mode TO auto;
EXECUTE resume_page(:'gcont'::bson);
DEALLOCATE resume_page;

-- A parameterized first page must still stream.
PREPARE first_page(bson) AS
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.firstBatch._id" }') AS generic_plan_first_page,
       persistconnection
FROM find_cursor_first_page('resadv', $1, 8406);

EXECUTE first_page('{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "limit": 6, "batchSize": 2 }'::bson);
SET plan_cache_mode TO force_generic_plan;
EXECUTE first_page('{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "limit": 6, "batchSize": 2 }'::bson);
SET plan_cache_mode TO auto;
DEALLOCATE first_page;

------------------------------------------------------------
-- 2. Resume must be a pure function of the continuation.
------------------------------------------------------------

-- Replaying a continuation must return the same page.
DO $$
DECLARE p bson; c bson; ids1 text; ids2 text;
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 4, "batchSize": 3 }'::bson, 8501);
    SELECT cursorpage INTO p FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8501" }, "collection": "coll", "batchSize": 3 }'::bson, c);
    SELECT string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality) INTO ids1
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    SELECT cursorpage INTO p FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8501" }, "collection": "coll", "batchSize": 3 }'::bson, c);
    SELECT string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality) INTO ids2
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    RAISE NOTICE 'continuation replay: first=% second=%', ids1, ids2;
END;
$$;

-- A zero-batch getMore must not consume documents.
DO $$
DECLARE p bson; c bson; ids text;
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 5, "batchSize": 2 }'::bson, 8502);
    SELECT string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality) INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    RAISE NOTICE 'zero-batch page1 = %', ids;
    SELECT cursorpage, continuation INTO p, c FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8502" }, "collection": "coll", "batchSize": 0 }'::bson, c);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), '(empty)') INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    RAISE NOTICE 'zero-batch page = %, cursor still open = %', ids, (c IS NOT NULL);
    SELECT cursorpage, continuation INTO p, c FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8502" }, "collection": "coll", "batchSize": 3 }'::bson, c);
    SELECT string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality) INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    RAISE NOTICE 'resume after zero-batch = %', ids;
END;
$$;

-- An aborted subtransaction must not alter a prior continuation.
DO $$
DECLARE p bson; c bson; ids text;
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "batchSize": 2 }'::bson, 8503);
    BEGIN
        PERFORM cursor_get_more('resadv',
            '{ "getMore": { "$numberLong": "8503" }, "collection": "coll", "batchSize": 2 }'::bson, c);
        RAISE EXCEPTION 'forced subtransaction abort';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'subtransaction aborted after a getMore';
    END;
    SELECT cursorpage, continuation INTO p, c FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8503" }, "collection": "coll", "batchSize": 2 }'::bson, c);
    SELECT string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality) INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    RAISE NOTICE 'resume after aborted subtransaction = %', ids;
END;
$$;

------------------------------------------------------------
-- 3. Page-boundary termination other than a filled batch.
--
-- Each termination path must preserve whether the skip was consumed.
------------------------------------------------------------

-- Large documents make the response size cap end each page.
SELECT COUNT(documentdb_api.insert_one('resadv', 'big',
    FORMAT('{ "_id": %s, "p": "%s" }', i, repeat('x', 6000000))::bson))
FROM generate_series(1, 5) i;

SELECT res_drain('{ "find": "big", "sort": { "_id": 1 }, "skip": 2, "batchSize": 50 }',
    '{ "getMore": { "$numberLong": "8601" }, "collection": "big", "batchSize": 50 }',
    8601) AS size_capped_skip;

SELECT res_drain('{ "find": "big", "sort": { "_id": 1 }, "skip": 1, "limit": 3, "batchSize": 50 }',
    '{ "getMore": { "$numberLong": "8602" }, "collection": "big", "batchSize": 50 }',
    8602) AS size_capped_skip_limit;

-- A zero-batch page preserves the offset until the executor first runs.

-- Preserve the offset across two zero-batch pages.
DO $$
DECLARE p bson; c bson; ids text; allids text := '';
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 4, "batchSize": 0 }'::bson, 8701);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), '') INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    allids := '[' || ids || ']';
    SELECT cursorpage, continuation INTO p, c FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8701" }, "collection": "coll", "batchSize": 0 }'::bson, c);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), '') INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    allids := allids || ' [' || ids || ']';
    SELECT cursorpage, continuation INTO p, c FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8701" }, "collection": "coll", "batchSize": 3 }'::bson, c);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), '') INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    allids := allids || ' [' || ids || ']';
    RAISE NOTICE 'two zero-batch pages then a real one = %', allids;
END;
$$;

-- Replaying an unconsumed continuation must be idempotent.
DO $$
DECLARE p bson; c bson; ids1 text; ids2 text;
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 6, "batchSize": 0 }'::bson, 8702);
    SELECT cursorpage INTO p FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8702" }, "collection": "coll", "batchSize": 2 }'::bson, c);
    SELECT string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality) INTO ids1
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    SELECT cursorpage INTO p FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8702" }, "collection": "coll", "batchSize": 2 }'::bson, c);
    SELECT string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality) INTO ids2
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    RAISE NOTICE 'unconsumed continuation replay: first=% second=%', ids1, ids2;
END;
$$;

-- A zero-batch first page must not decrement the tracked limit.
SELECT bson_dollar_project(continuation, '{ "lim": 1 }') AS batch0_limit_untouched
FROM find_cursor_first_page('resadv',
    '{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "limit": 5, "batchSize": 0 }'::bson, 8703);

SELECT res_drain(
    '{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "limit": 5, "batchSize": 0 }',
    '{ "getMore": { "$numberLong": "8704" }, "collection": "coll", "batchSize": 2 }',
    8704) AS batch0_skip_limit_drain;

-- Resume authorization survives a flag change. Skip-only isolates this behavior
-- because a remaining limit independently authorizes its Limit node.
DO $$
DECLARE p bson; c bson; ids text;
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 15, "batchSize": 0 }'::bson, 8705);
    SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
    SELECT cursorpage, continuation INTO p, c FROM cursor_get_more('resadv',
        '{ "getMore": { "$numberLong": "8705" }, "collection": "coll", "batchSize": 3 }'::bson, c);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), '(empty)') INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
    SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
    RAISE NOTICE 'skip-only resume with the flag off = %', ids;
END;
$$;

------------------------------------------------------------
-- 4. Shapes that still stream, and shapes that must stop streaming.
------------------------------------------------------------

-- A multi-branch filter remains streamable after collapsing to one ordered scan.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('resadv',
    '{ "find": "coll", "filter": { "$or": [ { "_id": { "$lt": 5 } }, { "_id": { "$gt": 15 } } ] }, "sort": { "_id": 1 }, "skip": 2, "limit": 5 }');

SELECT res_drain(
    '{ "find": "coll", "filter": { "$or": [ { "_id": { "$lt": 5 } }, { "_id": { "$gt": 15 } } ] }, "sort": { "_id": 1 }, "skip": 2, "limit": 5, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "8701" }, "collection": "coll", "batchSize": 2 }',
    8701) AS or_branches_skip_limit;

SELECT res_drain(
    '{ "find": "coll", "filter": { "_id": { "$in": [2,4,6,8,10,12,14] } }, "sort": { "_id": 1 }, "skip": 2, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "8702" }, "collection": "coll", "batchSize": 2 }',
    8702) AS in_list_skip_limit;

-- A reverse natural scan must resume with its direction intact.
SELECT res_drain(
    '{ "find": "coll", "sort": { "$natural": -1 }, "skip": 3, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "8703" }, "collection": "coll", "batchSize": 2 }',
    8703) AS natural_desc_skip_limit;

-- singleBatch closes without a continuation.
SELECT (cursorpage::text::jsonb)->'cursor'->'firstBatch' AS single_batch_ids,
       (continuation IS NULL) AS single_batch_closed
FROM find_cursor_first_page('resadv',
    '{ "find": "coll", "sort": { "_id": 1 }, "skip": 3, "limit": 4, "batchSize": 2, "singleBatch": true }'::bson, 8704);

-- Data exhaustion retires a limit larger than the remaining documents.
SELECT res_drain('{ "find": "coll", "sort": { "_id": 1 }, "skip": 15, "limit": 10, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "8705" }, "collection": "coll", "batchSize": 2 }',
    8705) AS limit_exceeds_remaining;

-- Ceiling values must not overflow when skip and limit are combined.
SELECT (cursorpage::text::jsonb)->'cursor'->'firstBatch' AS int64_ceiling_batch,
       (continuation IS NULL) AS int64_ceiling_closed
FROM find_cursor_first_page('resadv',
    '{ "find": "coll", "skip": 9223372036854775806, "limit": 9223372036854775807, "batchSize": 2 }'::bson, 8706);

------------------------------------------------------------
-- 5. A sharded collection, and DML across the resume boundary.
------------------------------------------------------------

-- Sharded collections use a persistent cursor and apply skip globally.
SELECT documentdb_api.shard_collection('resadv', 'sh', '{ "sk": "hashed" }'::bson, false);

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('resadv',
    '{ "find": "sh", "sort": { "_id": 1 }, "skip": 3, "limit": 6 }');

SELECT res_drain('{ "find": "sh", "sort": { "_id": 1 }, "skip": 3, "limit": 6, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "8801" }, "collection": "sh", "batchSize": 2 }',
    8801) AS sharded_skip_limit;

SELECT res_drain('{ "find": "sh", "sort": { "_id": 1 }, "skip": 5, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "8802" }, "collection": "sh", "batchSize": 3 }',
    8802) AS sharded_skip_only;

-- Shard-key equality applies skip to the filtered result.
SELECT res_drain('{ "find": "sh", "filter": { "sk": 7 }, "sort": { "_id": 1 }, "skip": 1, "limit": 3, "batchSize": 1 }',
    '{ "getMore": { "$numberLong": "8803" }, "collection": "sh", "batchSize": 1 }',
    8803) AS sharded_shardkey_eq_skip;

-- After inter-page DML, replanning must still satisfy the tracked limit.
DO $$
DECLARE p bson; c bson; ids text; allids text := '';
BEGIN
    SELECT cursorpage, continuation INTO p, c FROM find_cursor_first_page('resadv',
        '{ "find": "coll", "sort": { "_id": 1 }, "skip": 2, "limit": 6, "batchSize": 2 }'::bson, 8901);
    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality),'') INTO ids
    FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    allids := '[' || ids || ']';
    PERFORM documentdb_api.delete('resadv',
        '{ "delete": "coll", "deletes": [ { "q": { "_id": 6 }, "limit": 1 } ] }'::bson);
    PERFORM documentdb_api.update('resadv',
        '{ "update": "coll", "updates": [ { "q": { "_id": 7 }, "u": { "$set": { "a": 999 } } } ] }'::bson);
    WHILE c IS NOT NULL LOOP
        SELECT cursorpage, continuation INTO p, c FROM cursor_get_more('resadv',
            '{ "getMore": { "$numberLong": "8901" }, "collection": "coll", "batchSize": 2 }'::bson, c);
        SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality),'') INTO ids
        FROM jsonb_array_elements((p::text::jsonb)->'cursor'->'nextBatch') WITH ORDINALITY;
        allids := allids || ' [' || ids || ']';
    END LOOP;
    RAISE NOTICE 'delete+update across resume boundary = %', allids;
END;
$$;

------------------------------------------------------------
-- Cleanup
------------------------------------------------------------
SELECT documentdb_api.drop_collection('resadv', 'coll');
SELECT documentdb_api.drop_collection('resadv', 'sh');
SELECT documentdb_api.drop_collection('resadv', 'big');
DROP FUNCTION res_drain(text, text, bigint);
