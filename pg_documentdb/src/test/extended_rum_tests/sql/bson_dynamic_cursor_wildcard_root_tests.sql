-- Dynamic cursors over a collection whose only usable index is a wildcard index
-- on the root ("$**"). A filter that pushes down to the wildcard root index must
-- stream correctly: the leading column of a root wildcard has an empty index
-- path, so the ordered-scan qual injected by the dynamic cursor carries an empty
-- path that routes to the wildcard column.
--
-- A wildcard index explodes arrays into one index entry per element, so an
-- ordered (streaming) index scan over a multikey wildcard would emit a document
-- once per matching array element (duplicates). The dynamic cursor therefore
-- only takes the ordered path when the wildcard-leading index is provably
-- non-multikey; otherwise it falls back to a de-duplicating bitmap scan. A
-- wildcard index records its multikey status by default (no special reloption is
-- required), so the cursor can rely on it. This test exercises both paths.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 93000;
SET documentdb.next_collection_index_id TO 93000;

SET enable_seqscan TO off;

------------------------------------------------------------------------------
-- Path A: scalar (non-multikey) wildcard root index. The wildcard-leading index
-- is non-multikey, so the dynamic cursor takes the ordered Secondary Index Scan
-- (dc.type = 3) with a streaming continuation ("qp": false) and drains every
-- matching row exactly once.
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('wcroot_db', 'wcscalar');

SELECT COUNT(documentdb_api.insert_one('wcroot_db', 'wcscalar', FORMAT('{ "_id": %s, "a": %s, "b": %s }', i, i, i % 5)::bson)) FROM generate_series(1, 200) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'wcroot_db',
    '{ "createIndexes": "wcscalar", "indexes": [ { "key": { "$**": 1 }, "name": "wc_1" } ] }', TRUE);

ANALYZE documentdb_data.documents_93001;

-- Baseline (dynamic cursors OFF): the filter pushes down to the wildcard root
-- index.
SET documentdb.enableDynamicCursors TO off;

EXPLAIN (VERBOSE OFF, COSTS OFF) SELECT document FROM bson_aggregation_find(
    'wcroot_db', '{ "find": "wcscalar", "filter": { "b": { "$gt": 2 } } }');

SET documentdb.enableDynamicCursors TO on;

-- Ordered scan (dc.type = 3), streaming continuation ("qp": false).
SELECT bson_dollar_project(continuation, '{ "qp": 1, "dc.type": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'wcroot_db',
    commandSpec => '{ "find": "wcscalar", "filter": { "b": { "$gt": 2 } }, "batchSize": 3 }',
    cursorId => 93001);

-- The same holds when the projection makes an index-only scan eligible.
SET documentdb.enableIndexOnlyScanForFindProject TO on;

SELECT bson_dollar_project(continuation, '{ "qp": 1, "dc.type": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'wcroot_db',
    commandSpec => '{ "find": "wcscalar", "filter": { "b": { "$gt": 2 } }, "projection": { "_id": 1 }, "batchSize": 3 }',
    cursorId => 93002);

SET documentdb.enableIndexOnlyScanForFindProject TO off;

-- Drain the whole cursor across getMore pages. The filter (b in {3, 4}) matches
-- 80 of 200 documents; an ordered scan over a non-multikey wildcard returns each
-- exactly once, so the total is 80 (a duplicating scan would exceed 80).
DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_batch bigint;
    v_total bigint := 0;
BEGIN
    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(
        database => 'wcroot_db',
        commandSpec => '{ "find": "wcscalar", "filter": { "b": { "$gt": 2 } }, "batchSize": 7 }'::documentdb_core.bson,
        cursorId => 93003);
    SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
    v_total := v_total + COALESCE(v_batch, 0);

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'wcroot_db',
            getMoreSpec => '{ "getMore": { "$numberLong": "93003" }, "collection": "wcscalar", "batchSize": 7 }'::documentdb_core.bson,
            continuationSpec => v_cont) gm;
        SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
        v_total := v_total + COALESCE(v_batch, 0);
    END LOOP;

    RAISE NOTICE 'scalar wildcard drained total rows: %', v_total;
END$$;

SELECT documentdb_api.drop_collection('wcroot_db', 'wcscalar');

------------------------------------------------------------------------------
-- Path B: multikey (array) wildcard root index. A wildcard entry per array
-- element means an ordered scan would duplicate documents, so the dynamic
-- cursor falls back to a de-duplicating bitmap scan (dc.type = 4). Every "b" is
-- an array of two values; the filter "b > 2" matches every document, and the
-- drain returns each matching document exactly once.
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('wcroot_db', 'wcarray');

SELECT COUNT(documentdb_api.insert_one('wcroot_db', 'wcarray', FORMAT('{ "_id": %s, "a": %s, "b": [%s, %s] }', i, i, i % 5, (i % 5) + 10)::bson)) FROM generate_series(1, 200) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'wcroot_db',
    '{ "createIndexes": "wcarray", "indexes": [ { "key": { "$**": 1 }, "name": "wc_1" } ] }', TRUE);

ANALYZE documentdb_data.documents_93002;

-- Bitmap scan (dc.type = 4): the wildcard index is multikey, so the ordered path
-- is not taken.
SELECT bson_dollar_project(continuation, '{ "qp": 1, "dc.type": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'wcroot_db',
    commandSpec => '{ "find": "wcarray", "filter": { "b": { "$gt": 2 } }, "batchSize": 3 }',
    cursorId => 93004);

-- Drain the whole cursor: the filter matches all 200 documents; the bitmap scan
-- de-duplicates the per-array-element entries so each document appears once (an
-- ordered multikey scan would exceed 200 by re-emitting documents whose two
-- elements both match).
DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_batch bigint;
    v_total bigint := 0;
BEGIN
    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(
        database => 'wcroot_db',
        commandSpec => '{ "find": "wcarray", "filter": { "b": { "$gt": 2 } }, "batchSize": 7 }'::documentdb_core.bson,
        cursorId => 93005);
    SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
    v_total := v_total + COALESCE(v_batch, 0);

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'wcroot_db',
            getMoreSpec => '{ "getMore": { "$numberLong": "93005" }, "collection": "wcarray", "batchSize": 7 }'::documentdb_core.bson,
            continuationSpec => v_cont) gm;
        SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
        v_total := v_total + COALESCE(v_batch, 0);
    END LOOP;

    RAISE NOTICE 'array wildcard drained total rows: %', v_total;
END$$;

SELECT documentdb_api.drop_collection('wcroot_db', 'wcarray');

------------------------------------------------------------------------------
-- Path C: empty arrays make a wildcard path multikey even though they produce no
-- scalar entries. The wildcard index records this multikey status by default, so
-- the cursor conservatively falls back to a bitmap scan (dc.type = 4).
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('wcroot_db', 'wcempty');

SELECT COUNT(documentdb_api.insert_one('wcroot_db', 'wcempty', FORMAT('{ "_id": %s, "b": [], "c": %s }', i, i % 5)::bson)) FROM generate_series(1, 200) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'wcroot_db',
    '{ "createIndexes": "wcempty", "indexes": [ { "key": { "$**": 1 }, "name": "wc_1" } ] }', TRUE);

ANALYZE documentdb_data.documents_93003;

-- The empty-array documents flag the wildcard index as multikey, so the ordered
-- path is not taken (dc.type = 4).
SELECT bson_dollar_project(continuation, '{ "qp": 1, "dc.type": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'wcroot_db',
    commandSpec => '{ "find": "wcempty", "filter": { "c": { "$gt": 2 } }, "batchSize": 3 }',
    cursorId => 93006);

SELECT documentdb_api.drop_collection('wcroot_db', 'wcempty');

------------------------------------------------------------------------------
-- Path D: a wildcard-leading index that becomes multikey after the first page.
-- The multikey state of an index is monotonic, so a document with array values
-- inserted mid-cursor flips a previously non-multikey wildcard index to
-- multikey. The ordered and bitmap resume strategies consume rows in different
-- orders, so the cursor cannot switch mid-stream; instead the plan is killed so
-- the client restarts and re-classifies the index as a bitmap scan. This avoids
-- silently returning a document more than once.
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('wcroot_db', 'wcflip');

SELECT COUNT(documentdb_api.insert_one('wcroot_db', 'wcflip', FORMAT('{ "_id": %s, "b": %s }', i, i % 5)::bson)) FROM generate_series(1, 200) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'wcroot_db',
    '{ "createIndexes": "wcflip", "indexes": [ { "key": { "$**": 1 }, "name": "wc_1" } ] }', TRUE);

ANALYZE documentdb_data.documents_93004;

-- First page: the index is still non-multikey, so the ordered scan (dc.type = 3)
-- is chosen.
SELECT bson_dollar_project(continuation, '{ "qp": 1, "dc.type": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'wcroot_db',
    commandSpec => '{ "find": "wcflip", "filter": { "b": { "$gt": 2 } }, "batchSize": 3 }',
    cursorId => 93007);

-- Take the first page of a fresh cursor, insert an array document to flip the
-- index to multikey, then resume: the getMore is rejected with a plan-killed
-- error instead of continuing an ordered scan that could duplicate documents.
DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
BEGIN
    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(
        database => 'wcroot_db',
        commandSpec => '{ "find": "wcflip", "filter": { "b": { "$gt": 2 } }, "batchSize": 3, "projection": { "_id": 1 } }'::documentdb_core.bson,
        cursorId => 93008);

    PERFORM documentdb_api.insert_one('wcroot_db', 'wcflip', '{ "_id": 9001, "b": [3, 4] }'::documentdb_core.bson);

    SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
    FROM cursor_get_more(
        database => 'wcroot_db',
        getMoreSpec => '{ "getMore": { "$numberLong": "93008" }, "collection": "wcflip", "batchSize": 3 }'::documentdb_core.bson,
        continuationSpec => v_cont) gm;

    RAISE NOTICE 'unexpected: getMore succeeded after multikey flip';
END$$;

SELECT documentdb_api.drop_collection('wcroot_db', 'wcflip');
