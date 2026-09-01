-- ============================================================================
-- Dynamic Cursor Skip/Limit Adversarial Tests
-- ============================================================================
--
-- Attacks the dynamic streaming skip/limit path with inputs chosen to break the
-- invariant it depends on: a streamed count is either tracked exactly or not
-- streamed at all. Each section targets a distinct way that invariant can be
-- subverted, and every case asserts the documents returned -- not just a count
-- or a plan shape -- because the failure modes here are silent wrong answers
-- rather than errors.
--
-- The four attack surfaces:
--
--   1. Numeric boundaries. The eligibility predicates and the streaming
--      predicates read the same user value through different width
--      conversions, so a value can be classified inconsistently.
--   2. The continuation. It is client-supplied on every getMore, so the
--      remaining-limit state must be validated rather than trusted.
--   3. Concurrent DDL/DML between pages. A streamed cursor re-plans on every
--      getMore, so the object it resumes against can change underneath it.
--   4. Nested limit/offset nodes. Only a top-level count can be rewritten on
--      resume, so a subquery-level one must never be streamed.
--
-- enableExplainScanIndexCosts is off so EXPLAIN omits index cost estimates.
-- ============================================================================

SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 25890000;
SET documentdb.next_collection_index_id TO 25890000;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- Seed 20 documents with contiguous ids so a page boundary that re-applies an
-- offset, or a limit that stops early, is visible in the id sequence itself.
DO $$
BEGIN
    FOR g IN 1..20 LOOP
        PERFORM documentdb_api.insert_one('advskiplim', 'coll',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;

-- Drains a find across pages, reporting the ids seen per page plus the total.
-- The per-page ids are what make an over-skip or an over-return detectable; the
-- total is what makes a silent early stop detectable.
CREATE OR REPLACE FUNCTION adv_drain(
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
    v_count int;
    v_total int := 0;
    v_all text := '';
BEGIN
    SELECT cursorpage, continuation, persistconnection
    INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page('advskiplim', p_find_spec::bson, p_cursor_id);

    SELECT COALESCE(string_agg(value->'_id'->>'$numberInt', ',' ORDER BY ordinality), ''),
           count(*)
    INTO v_ids, v_count
    FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'firstBatch') WITH ORDINALITY;
    v_all := '[' || v_ids || ']';
    v_total := v_count;

    -- Bounded so a continuation that never retires fails as a wrong answer
    -- rather than hanging the suite.
    WHILE v_cont IS NOT NULL AND v_pages < 40 LOOP
        SELECT cursorpage, continuation INTO v_page, v_cont
        FROM cursor_get_more('advskiplim', p_getmore_spec::bson, v_cont);

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

-- Returns only the shape of a drain (no ids), for cases whose interest is the
-- number of documents returned rather than which ones.
CREATE OR REPLACE FUNCTION adv_drain_shape(
    p_find_spec text,
    p_getmore_spec text,
    p_cursor_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_page bson;
    v_cont bson;
    v_persist bool;
    v_pages int := 1;
    v_count int;
    v_total int := 0;
BEGIN
    SELECT cursorpage, continuation, persistconnection
    INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page('advskiplim', p_find_spec::bson, p_cursor_id);

    SELECT count(*) INTO v_count
    FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'firstBatch');
    v_total := v_count;

    WHILE v_cont IS NOT NULL AND v_pages < 40 LOOP
        SELECT cursorpage, continuation INTO v_page, v_cont
        FROM cursor_get_more('advskiplim', p_getmore_spec::bson, v_cont);
        SELECT count(*) INTO v_count
        FROM jsonb_array_elements((v_page::text::jsonb)->'cursor'->'nextBatch');
        v_pages := v_pages + 1;
        v_total := v_total + v_count;
    END LOOP;

    RETURN FORMAT('persist=%s pages=%s total=%s', v_persist, v_pages, v_total);
END;
$$;

------------------------------------------------------------
-- 1. Numeric boundary attacks on the eligibility predicates.
--
-- The persistence decision (RequiresPersistentCursorLimit /
-- RequiresPersistentCursorSkip), the streaming decision in ApplyFindSpec, and
-- the stages that actually apply the count (HandleLimit / HandleSkip) all read
-- the same user value, so they must all read it at the same width. They now
-- all read 64 bits. Narrowing any one of them to 32 bits would classify a value
-- by its low bits, and these cases are chosen so that such a narrowing changes
-- the documents returned rather than merely the plan.
--
-- The collection holds 20 documents and every limit below is far larger than
-- that, so the correct answer for all of them is identical: 20 documents in 7
-- pages of 3. Any row reporting a smaller total is silently losing documents.
------------------------------------------------------------

-- Values chosen around the 32-bit wrap point. The low 32 bits of 2^32 + 1,
-- 2*2^32 + 1 and 3*2^32 + 1 are all exactly 1, which is the value that marks a
-- single-row result and turns the cursor into a single-batch one; narrowing
-- would therefore return only the first batch and close the cursor without a
-- continuation. The low 32 bits of 2^32 are 0, the value that marks "no limit
-- at all". 2^32 - 1 and 2^32 + 2 narrow to values that carry no special
-- meaning. All seven must drain the full 20 documents.
SELECT v AS limit_value,
       adv_drain_shape(
           FORMAT('{ "find": "coll", "limit": { "$numberLong": "%s" }, "batchSize": 3 }', v),
           FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "coll", "batchSize": 3 }', 9600),
           9600) AS result
FROM (VALUES ('4294967295'),
             ('4294967296'),
             ('4294967297'),
             ('4294967298'),
             ('8589934593'),
             ('12884901889'),
             ('9223372036854775807')) t(v);

-- The same numeric value delivered as a double instead of an int64 takes the
-- other branch of the width conversion, so the document set returned depends on
-- the BSON type used to express the limit rather than on its value.
SELECT adv_drain_shape(
    '{ "find": "coll", "limit": { "$numberLong": "4294967297" }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9601" }, "collection": "coll", "batchSize": 3 }',
    9601) AS limit_as_int64;
-- The same numeric value delivered as a double rather than an int64 reaches the
-- predicates through a different conversion branch. The documents returned must
-- depend on the value, not on the BSON type used to express it.
SELECT adv_drain_shape(
    '{ "find": "coll", "limit": { "$numberLong": "4294967297" }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9601" }, "collection": "coll", "batchSize": 3 }',
    9601) AS limit_as_int64;
SELECT adv_drain_shape(
    '{ "find": "coll", "limit": { "$numberDouble": "4294967297.0" }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9602" }, "collection": "coll", "batchSize": 3 }',
    9602) AS limit_as_double;

-- The decimal128 branch is the third conversion path, and the one that reports
-- an out-of-range conversion as an error rather than wrapping. A limit that fits
-- in 64 bits must not be rejected here just because it does not fit in 32.
SELECT adv_drain_shape(
    '{ "find": "coll", "limit": { "$numberDecimal": "4294967297" }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9606" }, "collection": "coll", "batchSize": 3 }',
    9606) AS limit_as_decimal128;

-- A negative limit whose magnitude also wraps. The find spec replaces a negative
-- limit with its absolute value before the predicates run, so this must behave
-- as the corresponding positive limit does rather than as its narrowed form.
SELECT adv_drain_shape(
    '{ "find": "coll", "limit": { "$numberLong": "-4294967295" }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9607" }, "collection": "coll", "batchSize": 3 }',
    9607) AS limit_negative_low_bits_one;

-- The same narrowing applied to a skip expressed as a double rather than an
-- int64. Both name an offset past the end of a 20 document collection, so both
-- must return nothing.
SELECT adv_drain_shape(
    '{ "find": "coll", "skip": { "$numberDouble": "4294967296.0" }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9608" }, "collection": "coll", "batchSize": 3 }',
    9608) AS skip_as_double;

-- A limit that narrows to 1 must produce the same plan as one that does not.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('advskiplim', '{ "find": "coll", "limit": { "$numberLong": "4294967297" } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('advskiplim', '{ "find": "coll", "limit": { "$numberLong": "4294967298" } }');

-- Skips at the same boundary. The low 32 bits of 2^32 and 2*2^32 are 0, the
-- value that marks "no skip at all", so a narrowing here would return documents
-- from the start of the collection. All of these skip past the end of a 20
-- document collection, so the correct answer for every one is zero documents.
SELECT v AS skip_value,
       adv_drain_shape(
           FORMAT('{ "find": "coll", "skip": { "$numberLong": "%s" }, "batchSize": 3 }', v),
           FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "coll", "batchSize": 3 }', 9603),
           9603) AS result
FROM (VALUES ('4294967296'),
             ('4294967299'),
             ('8589934592'),
             ('9223372036854775806')) t(v);

-- A skip that truncates to 0 combined with a streamable limit: the pair must
-- agree, because a limit may only stream while the offset is tracked too.
SELECT adv_drain(
    '{ "find": "coll", "skip": { "$numberLong": "4294967296" }, "limit": 6, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9604" }, "collection": "coll", "batchSize": 3 }',
    9604) AS huge_skip_with_limit;

-- An int64 limit at the maximum, with a real skip, must still apply the skip
-- exactly once and return the remaining 15 documents.
SELECT adv_drain(
    '{ "find": "coll", "skip": 5, "limit": { "$numberLong": "9223372036854775807" }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "9605" }, "collection": "coll", "batchSize": 3 }',
    9605) AS skip5_limit_int64max;

------------------------------------------------------------
-- 2. Continuation tampering.
--
-- The continuation is handed back by the client on every getMore, so the
-- remaining limit in "lim" is untrusted input. If it were taken at face value a
-- client could resume with a larger remaining count than the query ever
-- authorized and read past its own limit. Each case below must be rejected, and
-- must be rejected with an error rather than by returning documents.
--
-- The continuation is mutated through its extended-JSON form so these cases
-- stay independent of the collection id and of the resume position encoded in
-- the cursor state.
------------------------------------------------------------
SELECT continuation AS cont
FROM find_cursor_first_page('advskiplim', '{ "find": "coll", "limit": 10, "batchSize": 3 }', 9700) \gset

-- Control: the untouched continuation resumes normally and returns ids 4-6.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS control_untampered
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson, :'cont'::bson);

-- hasFetchedRows must remain a boolean when supplied by a continuation.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_has_fetched_rows_type
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{hasFetchedRows}', '"true"'::jsonb)::text::bson);

-- Remaining limit inflated far beyond the limit the query was created with.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_lim_too_large
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{lim}', '{"$numberLong":"999"}'::jsonb)::text::bson);

-- Remaining limit inflated to the int64 maximum.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_lim_int64max
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{lim}', '{"$numberLong":"9223372036854775807"}'::jsonb)::text::bson);

-- Negative remaining limit: must not reach the parse tree as a negative LIMIT.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_lim_negative
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{lim}', '{"$numberLong":"-5"}'::jsonb)::text::bson);

-- Zero remaining limit: an exhausted cursor is never serialized, so a zero here
-- can only be forged.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_lim_zero
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{lim}', '{"$numberLong":"0"}'::jsonb)::text::bson);

-- Right value, wrong BSON width. The remaining limit is stored as an int64, and
-- accepting a narrower type here would reintroduce the width mismatch that
-- section 1 attacks.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_lim_int32
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{lim}', '{"$numberInt":"7"}'::jsonb)::text::bson);

-- Non-numeric remaining limit.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_lim_string
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{lim}', '"7"'::jsonb)::text::bson);

-- Remaining limit retained while the query it belongs to is swapped for one
-- with no limit at all, so there is no original count to validate against.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_query_without_limit
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{qd}',
                               '{"find":"coll","batchSize":{"$numberInt":"3"}}'::jsonb)::text::bson);

-- Remaining limit retained while the query is swapped for a limit 1, which is
-- served natively and never carries a tracked remaining count.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_query_limit_one
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{qd}',
                               '{"find":"coll","limit":{"$numberInt":"1"},"batchSize":{"$numberInt":"3"}}'::jsonb)::text::bson);

-- Remaining limit retained while the query is swapped for an aggregate. The
-- continuation still declares a find, so the swapped spec is rejected while
-- being parsed rather than being resumed under the find's tracked limit.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_query_aggregate
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{qd}',
                               '{"aggregate":"coll","pipeline":[{"$limit":{"$numberInt":"10"}}],"cursor":{}}'::jsonb)::text::bson);

-- Remaining limit retained while the cursor state that anchors the resume
-- position is removed.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_missing_cursor_state
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     ((:'cont'::bson::text::jsonb) - 'dc')::text::bson);

-- A limited cursor whose remaining count is stripped: the query still carries
-- its original limit, but nothing tracks how much of it was already consumed.
-- Resuming must not fall through to re-applying the full original limit.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_missing_lim
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     ((:'cont'::bson::text::jsonb) - 'lim')::text::bson);

-- Planner authorization is generated internally from QueryData. A forged copy
-- inside dc is ignored, so the cursor resumes like the untampered control.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_planner_authorization
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{dc,allowOffsetLimitNode}', 'true'::jsonb)::text::bson);

-- A skip reinstated on the resumed query. The offset is spent on the first
-- page, so a continuation that carries one back must not skip a second time.
SELECT continuation AS skipcont
FROM find_cursor_first_page('advskiplim', '{ "find": "coll", "skip": 4, "limit": 10, "batchSize": 3 }', 9701) \gset
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_skip_reinstated
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9701" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'skipcont'::bson::text::jsonb, '{qd}',
                               '{"find":"coll","skip":{"$numberInt":"4"},"limit":{"$numberInt":"10"},"batchSize":{"$numberInt":"3"}}'::jsonb)::text::bson);

-- The remaining limit reset to the original limit: a well-formed forgery that
-- claims no rows have been consumed yet. It passes the "not greater than the
-- original" check, so nothing but the resume position bounds how many documents
-- this cursor can be walked through. Pinned to make the permissiveness visible.
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_lim_reset_to_original
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{lim}', '{"$numberLong":"10"}'::jsonb)::text::bson);

-- The query swapped for a find on a different collection while the remaining
-- limit is kept. The limit was authorized against the original namespace, so
-- resuming another one under it must not be allowed to read further than that
-- namespace's own query would have. The other collection is seeded with a
-- disjoint id range so the returned ids identify which collection was actually
-- read: ids in the 100s mean the resume followed the swapped spec rather than
-- the collection the cursor state was captured against.
DO $$
BEGIN
    FOR g IN 101..120 LOOP
        PERFORM documentdb_api.insert_one('advskiplim', 'othercoll',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS tampered_query_other_collection
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9700" }, "collection": "coll", "batchSize": 3 }'::bson,
                     jsonb_set(:'cont'::bson::text::jsonb, '{qd}',
                               '{"find":"othercoll","limit":{"$numberInt":"10"},"batchSize":{"$numberInt":"3"}}'::jsonb)::text::bson);

------------------------------------------------------------
-- 3. Concurrent DDL and DML between pages.
--
-- A streamed cursor re-plans against the live catalog on every getMore, unlike
-- a persistent cursor which drains a snapshot taken on the first page. Widening
-- the streaming path to cover skip and limit therefore moves these queries onto
-- a resume that can observe concurrent changes.
------------------------------------------------------------

-- Deleting the document the continuation is anchored on must resume at the next
-- surviving document rather than restarting or skipping a page.
SELECT continuation AS delcont
FROM find_cursor_first_page('advskiplim', '{ "find": "coll", "skip": 2, "limit": 8, "batchSize": 3 }', 9800) \gset
SELECT documentdb_api.delete('advskiplim', '{ "delete": "coll", "deletes": [ { "q": { "_id": 6 }, "limit": 0 } ] }');
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS resume_after_anchor_deleted
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9800" }, "collection": "coll", "batchSize": 3 }'::bson, :'delcont'::bson);
SELECT documentdb_api.insert_one('advskiplim', 'coll', '{ "_id": 6, "a": 6 }'::documentdb_core.bson);

-- A concurrent insert positioned *inside* the range the cursor has yet to
-- visit. _id 5.5 sorts between the anchor (5) and the next document (6), so it
-- is reachable from the resumed scan rather than being filtered out by the
-- resume position the way a low _id would be. A streamed cursor re-plans and so
-- observes it; the point of the case is that the page still starts at the
-- anchor and is not shifted by a re-applied offset, which would return 8,9,10.
SELECT continuation AS inscont
FROM find_cursor_first_page('advskiplim', '{ "find": "coll", "skip": 2, "limit": 8, "batchSize": 3 }', 9801) \gset
SELECT documentdb_api.insert_one('advskiplim', 'coll', '{ "_id": 5.5, "a": 5.5 }'::documentdb_core.bson);
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS resume_after_insert_inside_window
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9801" }, "collection": "coll", "batchSize": 3 }'::bson, :'inscont'::bson);
SELECT documentdb_api.delete('advskiplim', '{ "delete": "coll", "deletes": [ { "q": { "_id": 5.5 }, "limit": 0 } ] }');

-- Dropping the collection out from under an open cursor. The streamed skip and
-- streamed limit paths both re-plan on resume, so the collection they resume
-- against can be gone. This must fail cleanly rather than returning documents
-- from a dropped collection.
--
-- The message pinned here is an internal "should never happen" ereport with no
-- error code, reached through the not-streaming branch of the getMore path. It
-- is captured as-is to record that this scenario is user-reachable; if that
-- branch is later given a proper cursor-killed error code, this expectation and
-- the tampered_missing_lim one above are the two that need updating.
SELECT documentdb_api.insert_one('advskiplim', 'dropme', '{ "_id": 1, "a": 1 }'::documentdb_core.bson);
DO $$
BEGIN
    FOR g IN 2..20 LOOP
        PERFORM documentdb_api.insert_one('advskiplim', 'dropme',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;
SELECT continuation AS dropcont
FROM find_cursor_first_page('advskiplim', '{ "find": "dropme", "limit": 8, "batchSize": 3 }', 9802) \gset
SELECT documentdb_api.drop_collection('advskiplim', 'dropme');
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS resume_after_collection_dropped
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9802" }, "collection": "dropme", "batchSize": 3 }'::bson, :'dropcont'::bson);

-- The same scenario with the feature disabled takes the persistent path, which
-- drains the snapshot it captured on the first page. Pinning both sides makes
-- the behavioural difference the feature introduces explicit rather than
-- incidental.
DO $$
BEGIN
    FOR g IN 1..20 LOOP
        PERFORM documentdb_api.insert_one('advskiplim', 'dropme2',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
SELECT continuation AS dropcont2, persistconnection AS persist2
FROM find_cursor_first_page('advskiplim', '{ "find": "dropme2", "limit": 8, "batchSize": 3 }', 9803) \gset
SELECT :'persist2'::bool AS guc_off_first_page_persistent;
SELECT documentdb_api.drop_collection('advskiplim', 'dropme2');
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS guc_off_resume_after_collection_dropped
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9803" }, "collection": "dropme2", "batchSize": 3 }'::bson, :'dropcont2'::bson);
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;

-- Sharding the collection between pages. Streaming skip/limit is restricted to
-- unsharded collections, so the resume re-plans against a collection that no
-- longer qualifies: the eligibility that authorized the first page is gone by
-- the time the second one is planned. An explicit sort keeps the resumed page
-- deterministic, since an unsorted read of a hash-sharded collection has no
-- defined order to assert against.
DO $$
BEGIN
    FOR g IN 1..20 LOOP
        PERFORM documentdb_api.insert_one('advskiplim', 'shardme',
            FORMAT('{"_id": %s, "sk": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;
SELECT continuation AS shardcont, persistconnection AS shardpersist
FROM find_cursor_first_page('advskiplim', '{ "find": "shardme", "sort": { "_id": 1 }, "skip": 2, "limit": 8, "batchSize": 3 }', 9804) \gset
SELECT :'shardpersist'::bool AS shard_first_page_persistconnection;
SELECT documentdb_api.shard_collection('advskiplim', 'shardme', '{ "sk": "hashed" }'::documentdb_core.bson, false);
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id" }') AS resume_after_collection_sharded
FROM cursor_get_more('advskiplim', '{ "getMore": { "$numberLong": "9804" }, "collection": "shardme", "batchSize": 3 }'::bson, :'shardcont'::bson);

------------------------------------------------------------
-- 4. Nested limit and offset nodes.
--
-- Views can introduce nested count nodes that cannot be safely rewritten on
-- resume, so all view-backed find skip/limit shapes remain persistent.
--
-- These views are built over their own collection, seeded once and never
-- mutated. An unsorted view pipeline returns rows in heap order, so reusing a
-- collection that earlier sections deleted from and reinserted into would make
-- the expected ids depend on where the reinserted row landed in the heap rather
-- than on whether a nested count was applied at the wrong level.
------------------------------------------------------------
DO $$
BEGIN
    FOR g IN 1..20 LOOP
        PERFORM documentdb_api.insert_one('advskiplim', 'vcoll',
            FORMAT('{"_id": %s, "a": %s}', g, g)::documentdb_core.bson);
    END LOOP;
END;
$$;

-- A view carrying both a skip and a limit, with a further skip and limit applied
-- by the find. Three stacked Limit nodes; none of them may stream.
SELECT documentdb_api.create_collection_view('advskiplim',
    '{ "create": "vw_skiplimit", "viewOn": "vcoll", "pipeline": [ { "$skip": 2 }, { "$limit": 10 } ] }'::documentdb_core.bson);
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('advskiplim', '{ "find": "vw_skiplimit", "skip": 3, "limit": 4 }');

-- The view yields ids 3-12; the find then skips 3 and takes 4, so the only
-- correct answer is 6,7,8,9. Re-applying either nested count on the second page
-- would move the second page off that sequence.
SELECT adv_drain(
    '{ "find": "vw_skiplimit", "skip": 3, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9900" }, "collection": "vw_skiplimit", "batchSize": 2 }',
    9900) AS view_nested_skip_limit;

-- A view with only a limit, with the skip supplied by the find: the view limit
-- ends up below the find's offset, which is the ordering that would let a
-- re-applied offset read past the view's own bound. The view yields ids 1-8, so
-- skipping 3 and taking 4 must return 4,5,6,7.
SELECT documentdb_api.create_collection_view('advskiplim',
    '{ "create": "vw_limit", "viewOn": "vcoll", "pipeline": [ { "$limit": 8 } ] }'::documentdb_core.bson);
SELECT adv_drain(
    '{ "find": "vw_limit", "skip": 3, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9901" }, "collection": "vw_limit", "batchSize": 2 }',
    9901) AS view_limit_then_find_skip;

-- A view whose limit is smaller than the find's skip: the correct answer is
-- empty, and a nested count applied at the wrong level would produce documents.
SELECT documentdb_api.create_collection_view('advskiplim',
    '{ "create": "vw_tiny", "viewOn": "vcoll", "pipeline": [ { "$limit": 2 } ] }'::documentdb_core.bson);
SELECT adv_drain(
    '{ "find": "vw_tiny", "skip": 5, "limit": 4, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9902" }, "collection": "vw_tiny", "batchSize": 2 }',
    9902) AS view_limit_smaller_than_skip;

-- A view over a view, so the nested counts are two subquery levels down. The
-- inner view yields ids 3-12, the outer view drops one more to 4-12, and the
-- find then skips 2 and takes 3, so the correct answer is 6,7,8.
SELECT documentdb_api.create_collection_view('advskiplim',
    '{ "create": "vw_nested", "viewOn": "vw_skiplimit", "pipeline": [ { "$skip": 1 } ] }'::documentdb_core.bson);
SELECT adv_drain(
    '{ "find": "vw_nested", "skip": 2, "limit": 3, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "9903" }, "collection": "vw_nested", "batchSize": 2 }',
    9903) AS view_over_view;

-- An aggregation whose $skip/$limit sit after a $sort is not the find path and
-- must not pick up the find-only streaming authorization.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('advskiplim', '{ "aggregate": "vcoll", "pipeline": [ { "$sort": { "_id": 1 } }, { "$skip": 3 }, { "$limit": 6 } ], "cursor": { "batchSize": 2 } }');

DROP FUNCTION adv_drain(text, text, bigint);
DROP FUNCTION adv_drain_shape(text, text, bigint);
