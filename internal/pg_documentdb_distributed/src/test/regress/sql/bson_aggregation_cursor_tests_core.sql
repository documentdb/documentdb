CREATE SCHEMA aggregation_cursor_test;

DO $$
DECLARE i int;
BEGIN
-- each doc is "a": 500KB, "c": 5 MB - ~5.5 MB & there's 10 of them
FOR i IN 1..10 LOOP
PERFORM documentdb_api.insert_one('db', 'get_aggregation_cursor_test', FORMAT('{ "_id": %s, "a": "%s", "c": [ %s "d" ] }',  i, repeat('Sample', 100000), repeat('"' || repeat('a', 1000) || '", ', 5000))::documentdb_core.bson);
END LOOP;
END;
$$;

CREATE TYPE aggregation_cursor_test.drain_result AS (filteredDoc bson, docSize int, continuationFiltered bson, persistConnection bool);

-- A remote dynamic cursor continuation embeds per-run volatile worker state: the
-- worker cursor id ("wc.qi"), its uniquely named cursor ("wc.qn") and the
-- serialized file state ("wc.qf"), plus the routed shard table oid ("dr"). These
-- differ on every run / environment. Replace them with a constant so the
-- continuation is deterministic, while echoing the surrounding worker fields so
-- the structure is still validated. The "$type" guards make this a no-op for
-- streaming / non-remote continuations that have none of these fields.
CREATE FUNCTION aggregation_cursor_test.mask_continuation(cont bson)
    RETURNS bson
    LANGUAGE sql
AS $fn$
    SELECT documentdb_api_catalog.bson_dollar_add_fields(cont,
        '{ "wc": { "$cond": [ { "$eq": [ { "$type": "$wc" }, "missing" ] }, "$$REMOVE", { "qi": "XXX", "qp": "$wc.qp", "qk": "$wc.qk", "qn": "XXX", "qf": "XXX", "numIters": "$wc.numIters", "sn": "$wc.sn" } ] },'
        '  "dr": { "$cond": [ { "$eq": [ { "$type": "$dr" }, "missing" ] }, "$$REMOVE", "XXX" ] },'
        '  "qf": { "$cond": [ { "$eq": [ { "$type": "$qf" }, "missing" ] }, "$$REMOVE", "XXX" ] } }'::documentdb_core.bson);
$fn$;

-- Drain-output variant: additionally drops the volatile per-shard streaming
-- resume token ("continuation.value") that the drain assertions don't compare.
CREATE FUNCTION aggregation_cursor_test.mask_drain_continuation(cont bson)
    RETURNS bson
    LANGUAGE sql
AS $fn$
    SELECT aggregation_cursor_test.mask_continuation(
        documentdb_api_catalog.bson_dollar_project(cont, '{ "continuation.value": 0 }'::documentdb_core.bson));
$fn$;


CREATE FUNCTION aggregation_cursor_test.drain_find_query(
    loopCount int, pageSize int, project bson DEFAULT NULL, skipVal int4 DEFAULT NULL, limitVal int4 DEFAULT NULL,
    sort bson DEFAULT NULL, filter bson default null,
    obfuscate_id bool DEFAULT false, singleBatch bool DEFAULT NULL) RETURNS SETOF aggregation_cursor_test.drain_result AS
$$
    DECLARE
        i int;
        doc bson;
        docSize int;
        cont bson;
        contProcessed bson;
        persistConn bool;
        findSpec bson;
        getMoreSpec bson;
    BEGIN

    WITH r1 AS (SELECT 'get_aggregation_cursor_test' AS "find", filter AS "filter", sort AS "sort", project AS "projection", skipVal AS "skip", limitVal as "limit", pageSize AS "batchSize", singleBatch AS "singleBatch")
    SELECT row_get_bson(r1) INTO findSpec FROM r1;

    WITH r1 AS (SELECT 'get_aggregation_cursor_test' AS "collection", 4294967294::int8 AS "getMore", pageSize AS "batchSize")
    SELECT row_get_bson(r1) INTO getMoreSpec FROM r1;

    SELECT cursorPage, continuation, persistConnection INTO STRICT doc, cont, persistConn FROM
                    documentdb_api.find_cursor_first_page(database => 'db', commandSpec => findSpec, cursorId => 4294967294);
    SELECT documentdb_api_catalog.bson_dollar_project(doc,
        ('{ "ok": 1, "cursor.id": 1, "cursor.ns": 1, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, ' ||
        ' "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }')::documentdb_core.bson), length(doc::bytea)::int INTO STRICT doc, docSize;

    IF obfuscate_id THEN
        SELECT documentdb_api_catalog.bson_dollar_add_fields(doc, '{ "ids.a": "1" }'::documentdb_core.bson) INTO STRICT doc;
    END IF;
    
    SELECT aggregation_cursor_test.mask_drain_continuation(cont) INTO STRICT contProcessed;
    RETURN NEXT ROW(doc, docSize, contProcessed, persistConn)::aggregation_cursor_test.drain_result;

    FOR i IN 1..loopCount LOOP
        SELECT cursorPage, continuation INTO STRICT doc, cont FROM documentdb_api.cursor_get_more(database => 'db', getMoreSpec => getMoreSpec, continuationSpec => cont);

        SELECT documentdb_api_catalog.bson_dollar_project(doc,
        ('{ "ok": 1, "cursor.id": 1, "cursor.ns": 1, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, ' ||
        ' "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }')::documentdb_core.bson), length(doc::bytea)::int INTO STRICT doc, docSize;

        IF obfuscate_id THEN
            SELECT documentdb_api_catalog.bson_dollar_add_fields(doc, '{ "ids.a": "1" }'::documentdb_core.bson) INTO STRICT doc;
        END IF;

        SELECT aggregation_cursor_test.mask_drain_continuation(cont) INTO STRICT contProcessed;
        RETURN NEXT ROW(doc, docSize, contProcessed, FALSE)::aggregation_cursor_test.drain_result;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION aggregation_cursor_test.drain_aggregation_query(
    loopCount int, pageSize int, pipeline bson DEFAULT NULL, obfuscate_id bool DEFAULT false, singleBatch bool DEFAULT NULL, collection_name text DEFAULT 'get_aggregation_cursor_test') RETURNS SETOF aggregation_cursor_test.drain_result AS
$$
    DECLARE
        i int;
        doc bson;
        docSize int;
        cont bson;
        contProcessed bson;
        persistConn bool;
        aggregateSpec bson;
        getMoreSpec bson;
    BEGIN

    IF pipeline IS NULL THEN
        pipeline = '{ "": [] }'::bson;
    END IF;

    WITH r0 AS (SELECT pageSize AS "batchSize", singleBatch AS "singleBatch" ),
    r1 AS (SELECT collection_name AS "aggregate", pipeline AS "pipeline", row_get_bson(r0) AS "cursor" FROM r0)
    SELECT row_get_bson(r1) INTO aggregateSpec FROM r1;

    WITH r1 AS (SELECT collection_name AS "collection", 4294967294::int8 AS "getMore", pageSize AS "batchSize" )
    SELECT row_get_bson(r1) INTO getMoreSpec FROM r1;

    SELECT cursorPage, continuation, persistConnection INTO STRICT doc, cont, persistConn FROM
                    documentdb_api.aggregate_cursor_first_page(database => 'db', commandSpec => aggregateSpec, cursorId => 4294967294);
    SELECT documentdb_api_catalog.bson_dollar_project(doc,
        ('{ "ok": 1, "cursor.id": 1, "cursor.ns": 1, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, ' ||
        ' "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }')::documentdb_core.bson), length(doc::bytea)::int INTO STRICT doc, docSize;

    IF obfuscate_id THEN
        SELECT documentdb_api_catalog.bson_dollar_add_fields(doc, '{ "ids.a": "1" }'::documentdb_core.bson) INTO STRICT doc;
    END IF;
    
    SELECT aggregation_cursor_test.mask_drain_continuation(cont) INTO STRICT contProcessed;
    RETURN NEXT ROW(doc, docSize, contProcessed, persistConn)::aggregation_cursor_test.drain_result;

    FOR i IN 1..loopCount LOOP
        SELECT cursorPage, continuation INTO STRICT doc, cont FROM documentdb_api.cursor_get_more(database => 'db', getMoreSpec => getMoreSpec, continuationSpec => cont);

        SELECT documentdb_api_catalog.bson_dollar_project(doc,
        ('{ "ok": 1, "cursor.id": 1, "cursor.ns": 1, "batchCount": { "$size": { "$ifNull": [ "$cursor.firstBatch", "$cursor.nextBatch" ] } }, ' ||
        ' "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] } }')::documentdb_core.bson), length(doc::bytea)::int INTO STRICT doc, docSize;

        IF obfuscate_id THEN
            SELECT documentdb_api_catalog.bson_dollar_add_fields(doc, '{ "ids.a": "1" }'::documentdb_core.bson) INTO STRICT doc;
        END IF;

        SELECT aggregation_cursor_test.mask_drain_continuation(cont) INTO STRICT contProcessed;
        RETURN NEXT ROW(doc, docSize, contProcessed, FALSE)::aggregation_cursor_test.drain_result;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- STREAMING BASED:
-- test getting the first page (with max page size) - should limit to 2 docs at a time.
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 6, pageSize => 100000);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 6, pageSize => 100000);


-- test smaller docs (500KB)
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 100000, project => '{ "a": 1 }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, pipeline => '{ "": [{ "$project": { "a": 1 } }]}');

-- test smaller batch size(s)
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 0, project => '{ "a": 1 }');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 12, pageSize => 1, project => '{ "a": 1 }');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 2, project => '{ "a": 1 }');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 3, project => '{ "a": 1 }');

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 0, pipeline => '{ "": [{ "$project": { "a": 1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 12, pageSize => 1, pipeline => '{ "": [{ "$project": { "a": 1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$project": { "a": 1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 3, pipeline => '{ "": [{ "$project": { "a": 1 } }]}');

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 3, pipeline => '{ "": [{ "$project": { "a": 1 } }, { "$skip": 0 }]}');

-- test singleBatch
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 3, pipeline => '{ "": [{ "$project": { "a": 1 } }]}', singleBatch => TRUE);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 3, pipeline => '{ "": [{ "$project": { "a": 1 } }]}', singleBatch => FALSE);

-- ===========================================================================
-- singleBatch must return exactly one batch and close the cursor (id = 0), even
-- for an otherwise non-streamable query (a blocking $group), and must never fall
-- back to a persisted/file cursor that drains the whole result. Verified by
-- counting the returned batch and confirming a follow-up getMore yields nothing.
-- ===========================================================================
-- find singleBatch, streamable PK sort: one batch of 3 (ids 10,9,8), cursor closed.
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 3, project => '{ "_id": 1 }', sort => '{ "_id": -1 }', singleBatch => TRUE);
-- aggregate singleBatch, non-streamable $group + $sort: one batch of 3, cursor closed.
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 3, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": 1 } } }, { "$sort": { "_id": 1 } }]}', singleBatch => TRUE);
-- find singleBatch with an effectively unbounded batch: all 10 ids in one batch, closed.
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 100000, project => '{ "_id": 1 }', sort => '{ "_id": 1 }', singleBatch => TRUE);

-- Drive the worker drain UDF directly (identical on the streaming and
-- remote-dispatch configs) and confirm via the cursor-type feature counter that
-- a singleBatch query — even a non-streamable $group — runs as a single-batch
-- cursor, not a file/persisted cursor that would drain everything.
SELECT collection_id AS sb_coll_id FROM documentdb_api_catalog.collections
    WHERE database_name = 'db' AND collection_name = 'get_aggregation_cursor_test' \gset
SELECT count(*) * 0 AS reset FROM documentdb_api_internal.command_feature_counter_stats(true);
SELECT documentdb_api_catalog.bson_dollar_project(
    (documentdb_api_internal.cursor_dynamic_drain_page('db',
        '{ "find": "get_aggregation_cursor_test", "projection": { "_id": 1 }, "sort": { "_id": -1 }, "singleBatch": true, "batchSize": 3 }'::documentdb_core.bson,
        ('documentdb_data.documents_' || :'sb_coll_id')::regclass, '{}'::documentdb_core.bson, 1,
        '{ "p_use_file_based_cursor": true, "p_batch_size": 3, "p_namespace": "db.get_aggregation_cursor_test" }'::documentdb_core.bson))[1],
    '{ "cursorId": "$cursor.id", "batchCount": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }'::documentdb_core.bson) AS find_singlebatch_worker;
SELECT documentdb_api_catalog.bson_dollar_project(
    (documentdb_api_internal.cursor_dynamic_drain_page('db',
        '{ "aggregate": "get_aggregation_cursor_test", "pipeline": [ { "$group": { "_id": "$_id", "c": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "cursor": { "singleBatch": true, "batchSize": 3 } }'::documentdb_core.bson,
        ('documentdb_data.documents_' || :'sb_coll_id')::regclass, '{}'::documentdb_core.bson, 2,
        '{ "p_use_file_based_cursor": true, "p_batch_size": 3, "p_namespace": "db.get_aggregation_cursor_test" }'::documentdb_core.bson))[1],
    '{ "cursorId": "$cursor.id", "batchCount": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }'::documentdb_core.bson) AS agg_singlebatch_worker;
-- Expect cursor_type_single_batch = 2 and no file/persisted cursor counter.
SELECT feature_name, usage_count FROM documentdb_api_internal.command_feature_counter_stats(false)
    WHERE feature_name LIKE 'cursor_type%' ORDER BY feature_name;

-- Assert no singleBatch drain materialized a file/persisted/hold-portal cursor:
-- the single-batch counter must be the only cursor-type feature recorded.
DO $assert$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(feature_name || '=' || usage_count, ', ' ORDER BY feature_name)
    INTO v_bad
    FROM documentdb_api_internal.command_feature_counter_stats(false)
    WHERE feature_name LIKE 'cursor_type%'
      AND feature_name <> 'cursor_type_single_batch';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'singleBatch must not create a file/persisted/hold-portal cursor, found: %', v_bad;
    END IF;
END
$assert$;

-- FIND: Test streaming vs not
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, skipVal => 2);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, filter => '{ "_id": { "$gt": 2 }} ');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, limitVal => 3);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 100000, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 0, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, sort => '{ "_id": -1 }');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, filter => '{ "_id": { "$gt": 2 }} ', skipVal => 0, limitVal => 0);

-- AGGREGATE: Test streaming vs not
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$skip": 2 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$limit": 3 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 0, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$sort": { "_id": -1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }, { "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }, { "$limit": 1 }, { "$addFields": { "c": "$a" }}]}');

BEGIN;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 0, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }, { "$limit": 1 }, { "$addFields": { "c": "$a" }}]}');
ROLLBACK;

-- inside a transaction block
BEGIN;
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, skipVal => 2);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, filter => '{ "_id": { "$gt": 2 }} ');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, limitVal => 3);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 100000, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 0, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, sort => '{ "_id": -1 }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$skip": 2 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$limit": 3 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 0, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$sort": { "_id": -1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
ROLLBACK;

-- With local execution off.
BEGIN;
set citus.enable_local_execution to off;
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, skipVal => 2);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, filter => '{ "_id": { "$gt": 2 }} ');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, limitVal => 3);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 100000, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 0, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, sort => '{ "_id": -1 }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$skip": 2 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$limit": 3 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 0, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$sort": { "_id": -1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
ROLLBACK;

-- with sharded
SELECT documentdb_api.shard_collection('db', 'get_aggregation_cursor_test', '{ "_id": "hashed" }', false);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 6, pageSize => 100000);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 6, pageSize => 100000);

-- FIND: Test streaming vs not
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, skipVal => 2);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, filter => '{ "_id": { "$gt": 2 }} ');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, limitVal => 3);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 100000, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 0, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, sort => '{ "_id": -1 }');

-- AGGREGATE: Test streaming vs not
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$skip": 2 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$limit": 3 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 0, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$sort": { "_id": -1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

-- inside a transaction block
BEGIN;
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, skipVal => 2);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, filter => '{ "_id": { "$gt": 2 }} ');
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, limitVal => 3);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 100000, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 0, limitVal => 1);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, sort => '{ "_id": -1 }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$skip": 2 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$limit": 3 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 0, pipeline => '{ "": [{ "$limit": 1 }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$sort": { "_id": -1 } }]}');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }');
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
ROLLBACK;

-- With local execution off.
BEGIN;
set citus.enable_local_execution to off;
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, skipVal => 2, obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, filter => '{ "_id": { "$gt": 2 }} ', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 4, pageSize => 100000, limitVal => 3, obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 2, pageSize => 100000, limitVal => 1, obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 1, pageSize => 0, limitVal => 1, obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 100000, sort => '{ "_id": -1 }');
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$skip": 2 }]}', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$match": { "_id": { "$gt": 2 }} }]}', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 100000, pipeline => '{ "": [{ "$limit": 3 }]}', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, pipeline => '{ "": [{ "$limit": 1 }]}', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 0, pipeline => '{ "": [{ "$limit": 1 }]}', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 100000, pipeline => '{ "": [{ "$sort": { "_id": -1 } }]}', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }', obfuscate_id => true);
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$sum": "$a" } } }] }', obfuscate_id => true);
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$avg": "$a" } } }] }', obfuscate_id => true);
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }', obfuscate_id => true);
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, pipeline => '{ "": [{ "$group": { "_id": "$_id", "c": { "$max": "$a" } } }] }', obfuscate_id => true);
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
ROLLBACK;

-- test for errors when returnKey is set to true
SELECT cursorPage FROM documentdb_api.find_cursor_first_page('db', '{ "find" : "movies", "filter" : { "title" : "a" }, "limit" : 1, "singleBatch" : true, "batchSize" : 1, "returnKey" : true, "lsid" : { "id" : { "$binary" : { "base64": "apfUje6LTzKH9YfO3smIGA==", "subType" : "04" } } }, "$db" : "db" }');

-- test for no errors when returnKey is set to false
SELECT cursorPage FROM documentdb_api.find_cursor_first_page('db', '{ "find" : "movies", "filter" : { "title" : "a" }, "limit" : 1, "singleBatch" : true, "batchSize" : 1, "returnKey" : false, "lsid" : { "id" : { "$binary" : { "base64": "apfUje6LTzKH9YfO3smIGA==", "subType" : "04" } } }, "$db" : "db" }');

-- test for errors when returnKey and showRecordId are set to true
SELECT cursorPage FROM documentdb_api.find_cursor_first_page('db', '{ "find" : "movies", "filter" : { "title" : "a" }, "limit" : 1, "singleBatch" : true, "batchSize" : 1, "showRecordId": true, "returnKey" : true, "lsid" : { "id" : { "$binary" : { "base64": "apfUje6LTzKH9YfO3smIGA==", "subType" : "04" } } }, "$db" : "db" }');

-- test for ntoreturn in find command with unset documentdb.version
SELECT cursorPage FROM documentdb_api.find_cursor_first_page('db', '{ "find" : "movies",  "limit" : 1,  "batchSize" : 1, "ntoreturn":1 ,"$db" : "db" }');
SELECT cursorPage FROM documentdb_api.find_cursor_first_page('db', '{ "find" : "movies", "ntoreturn":1 ,"$db" : "db" }');
SELECT cursorPage FROM documentdb_api.find_cursor_first_page('db', '{ "find" : "movies", "ntoreturn":1 , "batchSize":1, "$db" : "db" }');
SELECT cursorPage FROM documentdb_api.find_cursor_first_page('db', '{ "find" : "movies", "ntoreturn":1 , "limit":1, "$db" : "db" }');

-- Test $limit for large docs, even when batch size is enough to fit all limited docs, the response size should enforce persisted cursors for $limit
SELECT 1 FROM drop_collection('db','get_aggregation_cursor_test');
DO $$
DECLARE i int;
BEGIN
-- each doc is ~16MB
FOR i IN 1..5 LOOP
PERFORM documentdb_api.insert_one('db', 'get_aggregation_cursor_test', FORMAT('{ "_id": %s, "a": "%s" }',  i, repeat('a', 16777000))::documentdb_core.bson);
END LOOP;
END;
$$;

SELECT * FROM aggregation_cursor_test.drain_find_query(loopCount => 5, pageSize => 10, limitVal => 5);

-- add 200 docs with larger fields so that they use more pages and we test continuation with multiple pages.
DO $$
DECLARE i int;
BEGIN
FOR i IN 1..200 LOOP
PERFORM documentdb_api.insert_one('db', 'bitmap_cursor_continuation', FORMAT('{ "_id": %s, "sk": "skval", "a": "aval-%s%s", "c": [ "%s", "d" ] }', i, i, repeat('a', 200), repeat('b', 100))::documentdb_core.bson);
END LOOP;
END;
$$;

-- create an index on field 'a'
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{"createIndexes": "bitmap_cursor_continuation", "indexes": [{"key": {"a": 1}, "name": "a_1" }]}', TRUE);

-- Store results with fast bitmap lookup ON
set documentdb.enableContinuationFastBitmapLookup to on;
CREATE TEMP TABLE results_fast AS
SELECT row_number() OVER () as batch_num, (filteredDoc->>'ids')::text as ids
FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 40, 
    pipeline => '{ "": [{ "$match": { "a": { "$gte": "aval-" } } }] }', 
    collection_name => 'bitmap_cursor_continuation');

select * from results_fast;

-- Store results with fast bitmap lookup OFF
set documentdb.enableContinuationFastBitmapLookup to off;
CREATE TEMP TABLE results_slow AS
SELECT row_number() OVER () as batch_num, (filteredDoc->>'ids')::text as ids
FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 40, 
    pipeline => '{ "": [{ "$match": { "a": { "$gte": "aval-" } } }] }', 
    collection_name => 'bitmap_cursor_continuation');

select * from results_slow;

-- compare results
SELECT f.batch_num, 
       f.ids = s.ids as ids_match
FROM results_fast f
FULL OUTER JOIN results_slow s ON f.batch_num = s.batch_num
ORDER BY COALESCE(f.batch_num, s.batch_num);

-- now check the explain to make sure it is bitmap.
set documentdb.enableCursorsOnAggregationQueryRewrite to on;
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "bitmap_cursor_continuation", "projection": { "_id": 1 }, "filter": { "a": { "$gte": "aval-" } } , "batchSize": 1 }');

CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'db', commandSpec => '{ "find": "bitmap_cursor_continuation",  "projection": { "_id": 1 }, "filter": { "a": { "$gte": "aval-" } }, "batchSize": 2 }', cursorId => 4294967294);

-- Mask the volatile worker continuation fields before EXPLAIN so the embedded
-- continuation literal in the (non-executed) plan is deterministic. The plan
-- shape does not depend on the continuation contents.
SELECT aggregation_cursor_test.mask_continuation(continuation) AS r1_continuation FROM firstPageResponse \gset

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('db',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "bitmap_cursor_continuation", "batchSize": 1 }', :'r1_continuation');

DROP TABLE results_fast;
DROP TABLE results_slow;
DROP TABLE firstPageResponse;

BEGIN;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'db', commandSpec => '{ "find": "bitmap_cursor_continuation", "projection": { "_id": 1 }, "filter": { "a": { "$gte": "aval-" } }, "batchSize": 2  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- now delete in between to invalidate some of the bitmap entries.
SELECT documentdb_api.delete('db', '{ "delete": "bitmap_cursor_continuation", "deletes": [ {"q": {"_id": { "$gte": 1, "$lte": 190 } }, "limit": 0 } ]}');

SELECT cursorPage FROM cursor_get_more(database => 'db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "bitmap_cursor_continuation" }'::bson,
    continuationSpec => :'r1_continuation');

set documentdb.enableContinuationFastBitmapLookup to off;

SELECT cursorPage FROM cursor_get_more(database => 'db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "bitmap_cursor_continuation" }'::bson,
    continuationSpec => :'r1_continuation');

ROLLBACK;

-- now leave some blocks before and after the deleted range.
BEGIN;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'db', commandSpec => '{ "find": "bitmap_cursor_continuation", "projection": { "_id": 1 }, "filter": { "a": { "$gte": "aval-" } }, "batchSize": 100  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- now delete in between to invalidate some of the bitmap entries.
SELECT documentdb_api.delete('db', '{ "delete": "bitmap_cursor_continuation", "deletes": [ {"q": {"_id": { "$gte": 81, "$lte": 190 } }, "limit": 0 } ]}');

SELECT cursorPage FROM cursor_get_more(database => 'db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "bitmap_cursor_continuation" }'::bson,
    continuationSpec => :'r1_continuation');

set documentdb.enableContinuationFastBitmapLookup to off;

SELECT cursorPage FROM cursor_get_more(database => 'db',
    getMoreSpec => '{ "getMore": { "$numberLong": "4294967294" }, "collection": "bitmap_cursor_continuation" }'::bson,
    continuationSpec => :'r1_continuation');

ROLLBACK;


-- shard the collection and test again
SELECT documentdb_api.shard_collection('db', 'bitmap_cursor_continuation', '{ "_id": "hashed" }', false);
set documentdb.enableContinuationFastBitmapLookup to on;

CREATE TEMP TABLE results_fast AS
SELECT row_number() OVER () as batch_num, (filteredDoc->>'ids')::text as ids
FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 40, 
    pipeline => '{ "": [{ "$match": { "a": { "$gte": "aval-" } } }] }', 
    collection_name => 'bitmap_cursor_continuation');

select * from results_fast;

-- Store results with fast bitmap lookup OFF
set documentdb.enableContinuationFastBitmapLookup to off;
CREATE TEMP TABLE results_slow AS
SELECT row_number() OVER () as batch_num, (filteredDoc->>'ids')::text as ids
FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 40, 
    pipeline => '{ "": [{ "$match": { "a": { "$gte": "aval-" } } }] }', 
    collection_name => 'bitmap_cursor_continuation');

select * from results_slow;

-- compare results
SELECT f.batch_num, 
       f.ids = s.ids as ids_match
FROM results_fast f
FULL OUTER JOIN results_slow s ON f.batch_num = s.batch_num
ORDER BY COALESCE(f.batch_num, s.batch_num);

DROP TABLE results_fast;
DROP TABLE results_slow;


-- Regression tests for DrainSingleResultQuery DestReceiver migration:
-- Verify count/distinct produce correct results including NULL/empty cases.

-- Count on existing populated collection
SELECT document FROM documentdb_api.count_query('db', '{ "count": "get_aggregation_cursor_smalldoc_test" }');

-- Count with filter matching nothing (exercises NULL result → default response)
SELECT document FROM documentdb_api.count_query('db', '{ "count": "get_aggregation_cursor_smalldoc_test", "query": { "_id": { "$eq": "nonexistent_id" } } }');

-- Distinct on existing populated collection
SELECT document FROM documentdb_api.distinct_query('db', '{ "distinct": "get_aggregation_cursor_smalldoc_test", "key": "_id" }');

-- Distinct with filter matching nothing
SELECT document FROM documentdb_api.distinct_query('db', '{ "distinct": "get_aggregation_cursor_smalldoc_test", "key": "_id", "query": { "_id": { "$eq": "nonexistent_id" } } }');

-- Distinct on a key that does not exist in any document (exercises NULL datum path)
SELECT document FROM documentdb_api.distinct_query('db', '{ "distinct": "get_aggregation_cursor_smalldoc_test", "key": "no_such_field" }');

-- Count/Distinct on a large-document collection (exercises PG_DETOAST_DATUM_COPY path)
SELECT document FROM documentdb_api.count_query('db', '{ "count": "get_aggregation_cursor_test" }');
-- distinct output has no ordering guarantee and this collection is hash-sharded,
-- so the values-array order varies by environment. Unwind and sort the values for
-- a deterministic assertion while still exercising the distinct_query
-- PG_DETOAST_DATUM_COPY path on this large-document collection.
SELECT documentdb_api_catalog.bson_dollar_unwind(document, '$values') FROM documentdb_api.distinct_query('db', '{ "distinct": "get_aggregation_cursor_test", "key": "_id" }') ORDER BY 1;

-- Count/Distinct on a nonexistent collection (exercises error/default handling)
SELECT document FROM documentdb_api.count_query('db', '{ "count": "completely_nonexistent_collection" }');
SELECT document FROM documentdb_api.distinct_query('db', '{ "distinct": "completely_nonexistent_collection", "key": "a" }');
-- Regression tests for DrainStreamingQuery DestReceiver migration:
-- These tests exercise the streaming cursor path (cursorMap != NULL)
-- which extracts data (col1) + continuation tokens (col2) from the executor.
-- This core file is included with the GUC on and off to test both paths.

-- Create a collection with an odd number of documents (7) to test partial final batch
DO $$
DECLARE i int;
BEGIN
FOR i IN 1..7 LOOP
PERFORM documentdb_api.insert_one('db', 'partial_final_batch_coll', FORMAT('{ "_id": %s, "val": "item-%s" }', i, i)::documentdb_core.bson);
END LOOP;
END;
$$;

-- Streaming aggregate: 7 docs with batchSize=3 → batches of [3, 3, 1] then empty
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 3, collection_name => 'partial_final_batch_coll');

-- Streaming aggregate: 7 docs with batchSize=4 → batches of [4, 3] then empty
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 3, pageSize => 4, collection_name => 'partial_final_batch_coll');

-- Streaming aggregate: 7 docs with batchSize=2 → batches of [2, 2, 2, 1] then empty
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 5, pageSize => 2, collection_name => 'partial_final_batch_coll');

-- Streaming aggregate: all 7 docs in one batch (batchSize large enough)
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 2, pageSize => 100000, collection_name => 'partial_final_batch_coll');

-- Streaming aggregate on nonexistent collection (exercises CursorCompletion on first iteration)
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 1, pageSize => 10, collection_name => 'nonexistent_streaming_coll');

-- Streaming aggregate with $match that filters to subset + continuation across batches
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 3, pageSize => 2, pipeline => '{ "": [{ "$match": { "_id": { "$gte": 3 } } }] }', collection_name => 'partial_final_batch_coll');

-- Streaming aggregate with $match + $limit across batch boundaries
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 3, pageSize => 2, pipeline => '{ "": [{ "$match": { "_id": { "$lte": 5 } } }, { "$limit": 3 }] }', collection_name => 'partial_final_batch_coll');

-- Streaming aggregate with batchSize=1 and filter: single-row batches with continuation
SELECT * FROM aggregation_cursor_test.drain_aggregation_query(loopCount => 4, pageSize => 1, pipeline => '{ "": [{ "$match": { "_id": { "$gte": 5 } } }] }', collection_name => 'partial_final_batch_coll');

-- ===========================================================================
-- SECTION R-PointLookup: point _id lookup + sort on a non-indexed field, batchSize 1
-- A fresh collection of 100 documents (string _ids plus a createdDateTime),
-- including the specific _id the query targets. A unique-_id point lookup
-- returns a single document and drains in one page (cursor closed, no
-- continuation) on every cursor config.
-- ===========================================================================
SELECT documentdb_api.drop_collection('db', 'pointLookup');

-- The specific document the query targets.
SELECT documentdb_api.insert_one('db', 'pointLookup',
    '{ "_id": "dsdsdasdasdasdadewe68676wqeeq", "createdDateTime": { "$date": { "$numberLong": "1744859493000" } }, "app": "iconic" }');

-- 99 more documents to bring the collection to 100 records.
SELECT COUNT(documentdb_api.insert_one('db', 'pointLookup',
    FORMAT('{ "_id": "pointLookup_%s", "createdDateTime": { "$date": { "$numberLong": "%s" } }, "app": "doc_%s" }',
        i, 1744859493000 + i * 1000, i)::documentdb_core.bson))
FROM generate_series(1, 99) AS i;

ANALYZE;

-- EXPLAIN: a point _id lookup is served by the _id primary-key index. The sort
-- on the non-indexed createdDateTime is elided because a unique _id match yields
-- at most one row, so the plan is a bare Index Scan (no Sort node).
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
    '{ "find": "pointLookup", "filter": { "_id": "dsdsdasdasdasdadewe68676wqeeq" }, "sort": { "createdDateTime": -1 }, "batchSize": 100 }');

-- Test R-PointLookup: find({ _id: "dsds..." }) sort { createdDateTime: -1 }, batchSize 1.
-- The unique-_id match returns one document and drains in a single page: the
-- cursor closes (cursor.id 0, no continuation) without needing a getMore.
SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
        '{ "ok": 1, "cursor.id": 1, "batchCount": { "$size": "$cursor.firstBatch" }, "ids": "$cursor.firstBatch._id" }'::documentdb_core.bson) AS page,
    continuation IS NULL AS drained,
    persistConnection
FROM documentdb_api.find_cursor_first_page(database => 'db',
    commandSpec => '{ "find": "pointLookup", "filter": { "_id": "dsdsdasdasdasdadewe68676wqeeq" }, "sort": { "createdDateTime": -1 }, "batchSize": 100 }'::documentdb_core.bson,
    cursorId => 4294967294);

-- Clean up the collection so the next run (with different GUC) starts fresh
SELECT documentdb_api.drop_collection('db', 'partial_final_batch_coll');
SELECT documentdb_api.drop_collection('db', 'get_aggregation_cursor_test');
SELECT documentdb_api.drop_collection('db', 'get_aggregation_cursor_smalldoc_test');
SELECT documentdb_api.drop_collection('db', 'bitmap_cursor_continuation');
SELECT documentdb_api.drop_collection('db', 'pointLookup');

DROP SCHEMA aggregation_cursor_test CASCADE;