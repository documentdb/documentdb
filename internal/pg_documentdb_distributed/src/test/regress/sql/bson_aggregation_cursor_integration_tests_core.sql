-- Integration coverage for the end-to-end cursor path: a first-page call
-- followed by getMore continuations, for both find and aggregate, with and
-- without an explicit database argument. All first-page / getMore calls go
-- through the run_first_page / run_get_more wrappers defined below, which call
-- the cursor functions directly.
CREATE SCHEMA cursor_integration_test;

DO $$
DECLARE i int;
BEGIN
    FOR i IN 1..10 LOOP
        PERFORM documentdb_api.insert_one('intgdb', 'cursor_integration',
            FORMAT('{ "_id": %s, "a": %s, "b": "val-%s" }', i, i % 3, i)::documentdb_core.bson);
    END LOOP;
END;
$$;

-- Deterministic masking of the continuation. The server / gateway assigns the
-- cursor id, so the top level cursor id ("qi") and the streaming cursor name
-- ("qn") are per-run volatile and are replaced with a constant. The same is done
-- for the remote worker fields ("wc.qi"/"wc.qn"/"wc.qf" and the routed shard oid
-- "dr"), and the per-shard streaming resume token ("continuation.value") is
-- dropped. The "$type" guards make each replacement a no-op when the field is
-- absent, so the function works for streaming, file and remote continuations.
CREATE FUNCTION cursor_integration_test.mask_continuation(cont documentdb_core.bson)
    RETURNS documentdb_core.bson
    LANGUAGE sql
AS $fn$
    SELECT documentdb_api_catalog.bson_dollar_add_fields(
        documentdb_api_catalog.bson_dollar_project(cont, '{ "continuation.value": 0 }'::documentdb_core.bson),
        '{ "qi": { "$cond": [ { "$eq": [ { "$type": "$qi" }, "missing" ] }, "$$REMOVE", "XXX" ] },'
        '  "qn": { "$cond": [ { "$eq": [ { "$type": "$qn" }, "missing" ] }, "$$REMOVE", "XXX" ] },'
        '  "wc": { "$cond": [ { "$eq": [ { "$type": "$wc" }, "missing" ] }, "$$REMOVE", { "qi": "XXX", "qp": "$wc.qp", "qk": "$wc.qk", "qn": "XXX", "qf": "XXX", "numIters": "$wc.numIters", "sn": "$wc.sn" } ] },'
        '  "dr": { "$cond": [ { "$eq": [ { "$type": "$dr" }, "missing" ] }, "$$REMOVE", "XXX" ] },'
        '  "qf": { "$cond": [ { "$eq": [ { "$type": "$qf" }, "missing" ] }, "$$REMOVE", "XXX" ] } }'::documentdb_core.bson);
$fn$;

-- Compact, cursor-id-independent projection of a cursor page. The cursor id is
-- assigned by the server / gateway and is intentionally omitted so the output is
-- deterministic across runs.
CREATE FUNCTION cursor_integration_test.mask_page(page documentdb_core.bson)
    RETURNS documentdb_core.bson
    LANGUAGE sql
AS $fn$
    SELECT documentdb_api_catalog.bson_dollar_project(page,
        '{ "ok": 1, "cursor.ns": 1, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }'::documentdb_core.bson);
$fn$;

-- First-page / getMore wrappers. These call the cursor functions directly and
-- are STRICT, so a NULL database short-circuits to a NULL row.
CREATE FUNCTION cursor_integration_test.run_first_page(p_key int, p_db text, p_spec documentdb_core.bson)
    RETURNS TABLE (cursorPage documentdb_core.bson, continuation documentdb_core.bson, persistConnection bool, cursorId int8)
    LANGUAGE plpgsql
AS $fn$
BEGIN
    IF p_key = 1 THEN
        RETURN QUERY SELECT t.cursorPage, t.continuation, t.persistConnection, t.cursorId
            FROM documentdb_api.find_cursor_first_page(p_db, p_spec, 0) t;
    ELSE
        RETURN QUERY SELECT t.cursorPage, t.continuation, t.persistConnection, t.cursorId
            FROM documentdb_api.aggregate_cursor_first_page(p_db, p_spec, 0) t;
    END IF;
END;
$fn$;

CREATE FUNCTION cursor_integration_test.run_get_more(p_db text, p_spec documentdb_core.bson, p_continuation documentdb_core.bson)
    RETURNS TABLE (cursorPage documentdb_core.bson, continuation documentdb_core.bson)
    LANGUAGE plpgsql
AS $fn$
BEGIN
    RETURN QUERY SELECT t.cursorPage, t.continuation
        FROM documentdb_api.cursor_get_more(p_db, p_spec, p_continuation) t;
END;
$fn$;

-- Drives a first-page call followed by up to p_loops getMore calls, returning a
-- masked, deterministic view of every page and continuation along the way.
-- When p_pass_db is true the database is passed as an explicit argument; when it
-- is false the database is resolved from the "$db" field of the spec (which the
-- caller must include), and "$db" is likewise injected into the getMore spec.
CREATE FUNCTION cursor_integration_test.drain(
    p_key int, p_db text, p_pass_db bool, p_spec documentdb_core.bson, p_collection text, p_getmore_batch int, p_loops int)
    RETURNS TABLE (stage text, page documentdb_core.bson, continuation documentdb_core.bson, persistConnection bool)
    LANGUAGE plpgsql
AS $fn$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_cid int8;
    v_getmore documentdb_core.bson;
    v_db text;
    i int;
BEGIN
    v_db := CASE WHEN p_pass_db THEN p_db ELSE NULL END;

    SELECT t.cursorPage, t.continuation, t.persistConnection, t.cursorId
        INTO v_page, v_cont, v_persist, v_cid
        FROM cursor_integration_test.run_first_page(p_key, v_db, p_spec) t;

    stage := 'firstPage';
    page := cursor_integration_test.mask_page(v_page);
    continuation := cursor_integration_test.mask_continuation(v_cont);
    persistConnection := v_persist;
    RETURN NEXT;

    FOR i IN 1..p_loops LOOP
        EXIT WHEN v_cont IS NULL OR v_cid IS NULL OR v_cid = 0;

        IF p_pass_db THEN
            v_getmore := FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "%s", "batchSize": %s }',
                v_cid, p_collection, p_getmore_batch)::documentdb_core.bson;
        ELSE
            v_getmore := FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "%s", "batchSize": %s, "$db": "%s" }',
                v_cid, p_collection, p_getmore_batch, p_db)::documentdb_core.bson;
        END IF;

        SELECT t.cursorPage, t.continuation INTO v_page, v_cont
            FROM cursor_integration_test.run_get_more(v_db, v_getmore, v_cont) t;

        stage := 'getMore';
        page := cursor_integration_test.mask_page(v_page);
        continuation := cursor_integration_test.mask_continuation(v_cont);
        persistConnection := NULL;
        RETURN NEXT;
    END LOOP;
END;
$fn$;

-- ===========================================================================
-- find: explicit database vs database resolved from "$db"
-- ===========================================================================
SELECT * FROM cursor_integration_test.drain(1, 'intgdb', true,
    '{ "find": "cursor_integration", "batchSize": 3 }', 'cursor_integration', 3, 6);
SELECT * FROM cursor_integration_test.drain(1, 'intgdb', false,
    '{ "find": "cursor_integration", "batchSize": 3, "$db": "intgdb" }', 'cursor_integration', 3, 6);

-- find: filter / sort / limit and combinations
SELECT * FROM cursor_integration_test.drain(1, 'intgdb', true,
    '{ "find": "cursor_integration", "filter": { "a": 1 }, "batchSize": 2 }', 'cursor_integration', 2, 6);
SELECT * FROM cursor_integration_test.drain(1, 'intgdb', true,
    '{ "find": "cursor_integration", "sort": { "_id": -1 }, "batchSize": 4 }', 'cursor_integration', 4, 6);
SELECT * FROM cursor_integration_test.drain(1, 'intgdb', true,
    '{ "find": "cursor_integration", "limit": 5, "batchSize": 2 }', 'cursor_integration', 2, 6);
SELECT * FROM cursor_integration_test.drain(1, 'intgdb', true,
    '{ "find": "cursor_integration", "filter": { "a": { "$gte": 1 } }, "sort": { "_id": -1 }, "limit": 4, "batchSize": 2 }',
    'cursor_integration', 2, 6);

-- ===========================================================================
-- aggregate: explicit database vs database resolved from "$db"
-- ===========================================================================
SELECT * FROM cursor_integration_test.drain(2, 'intgdb', true,
    '{ "aggregate": "cursor_integration", "pipeline": [ ], "cursor": { "batchSize": 3 } }', 'cursor_integration', 3, 6);
SELECT * FROM cursor_integration_test.drain(2, 'intgdb', false,
    '{ "aggregate": "cursor_integration", "pipeline": [ ], "cursor": { "batchSize": 3 }, "$db": "intgdb" }', 'cursor_integration', 3, 6);

-- aggregate: $match / $sort / $limit and combinations
SELECT * FROM cursor_integration_test.drain(2, 'intgdb', true,
    '{ "aggregate": "cursor_integration", "pipeline": [ { "$match": { "a": 1 } } ], "cursor": { "batchSize": 2 } }', 'cursor_integration', 2, 6);
SELECT * FROM cursor_integration_test.drain(2, 'intgdb', true,
    '{ "aggregate": "cursor_integration", "pipeline": [ { "$sort": { "_id": -1 } } ], "cursor": { "batchSize": 4 } }', 'cursor_integration', 4, 6);
SELECT * FROM cursor_integration_test.drain(2, 'intgdb', true,
    '{ "aggregate": "cursor_integration", "pipeline": [ { "$limit": 5 } ], "cursor": { "batchSize": 2 } }', 'cursor_integration', 2, 6);
SELECT * FROM cursor_integration_test.drain(2, 'intgdb', true,
    '{ "aggregate": "cursor_integration", "pipeline": [ { "$match": { "a": { "$gte": 1 } } }, { "$sort": { "_id": -1 } }, { "$limit": 4 } ], "cursor": { "batchSize": 2 } }',
    'cursor_integration', 2, 6);

-- ===========================================================================
-- batch size variations on the first page: -1 (invalid), 0 (cursor only), 10
-- ===========================================================================
SELECT cursor_integration_test.mask_page(cursorPage) FROM cursor_integration_test.run_first_page(1, 'intgdb',
    '{ "find": "cursor_integration", "batchSize": -1 }');
SELECT cursor_integration_test.mask_page(cursorPage), cursor_integration_test.mask_continuation(continuation), persistConnection
    FROM cursor_integration_test.run_first_page(1, 'intgdb', '{ "find": "cursor_integration", "batchSize": 0 }');
SELECT cursor_integration_test.mask_page(cursorPage) FROM cursor_integration_test.run_first_page(1, 'intgdb',
    '{ "find": "cursor_integration", "batchSize": 10 }');

SELECT cursor_integration_test.mask_page(cursorPage) FROM cursor_integration_test.run_first_page(2, 'intgdb',
    '{ "aggregate": "cursor_integration", "pipeline": [ ], "cursor": { "batchSize": -1 } }');
SELECT cursor_integration_test.mask_page(cursorPage), cursor_integration_test.mask_continuation(continuation), persistConnection
    FROM cursor_integration_test.run_first_page(2, 'intgdb', '{ "aggregate": "cursor_integration", "pipeline": [ ], "cursor": { "batchSize": 0 } }');
SELECT cursor_integration_test.mask_page(cursorPage) FROM cursor_integration_test.run_first_page(2, 'intgdb',
    '{ "aggregate": "cursor_integration", "pipeline": [ ], "cursor": { "batchSize": 10 } }');

-- ===========================================================================
-- getMore driven by a tampered continuation: a real continuation is captured
-- and its query-kind marker ("qk") is flipped (find -> aggregate) while the
-- embedded command still describes a find. The output is masked so the result
-- is deterministic whether the tampering is rejected (streaming cursors) or
-- tolerated by re-planning from the embedded request (remote cursors).
-- ===========================================================================
SELECT continuation AS tampered_cont, cursorId AS tampered_cid
    FROM cursor_integration_test.run_first_page(1, 'intgdb', '{ "find": "cursor_integration", "batchSize": 2 }') \gset

SELECT cursor_integration_test.mask_page(cursorPage), cursor_integration_test.mask_continuation(continuation)
    FROM cursor_integration_test.run_get_more('intgdb',
        FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "cursor_integration", "batchSize": 2 }', :'tampered_cid')::documentdb_core.bson,
        documentdb_api_catalog.bson_dollar_add_fields((:'tampered_cont')::documentdb_core.bson, '{ "qk": { "$numberInt": "2" } }'::documentdb_core.bson));

SELECT documentdb_api.drop_database('intgdb');
DROP SCHEMA cursor_integration_test CASCADE;
