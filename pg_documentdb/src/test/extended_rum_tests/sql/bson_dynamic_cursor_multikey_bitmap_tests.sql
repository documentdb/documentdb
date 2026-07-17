-- Dynamic cursors over a non-wildcard composite (ordered) index that is multikey.
-- An ordered (streaming) index scan yields one row per index entry, and a multikey
-- document has several entries (one per array element) that can fall at different
-- positions in the index ordering. The streaming continuation only remembers a
-- single (key, row pointer) position, so it cannot suppress a document already
-- returned at an earlier key, and the document is re-emitted across cursor pages.
--
-- The dynamic cursor can force a de-duplicating bitmap scan whenever the
-- composite index is multikey. This safeguard is gated by the
-- enable_dynamic_cursor_multikey_bitmap GUC (default off, opt-in for tests);
-- this test exercises both states.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 93500;
SET documentdb.next_collection_index_id TO 93500;

-- Force the ordered index scan candidate so the multikey gate is what decides
-- between an ordered index scan and a de-duplicating bitmap scan.
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;
SET enable_indexonlyscan TO off;

SELECT documentdb_api.create_collection('mkbitmap_db', 'mk');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'mkbitmap_db',
    '{ "createIndexes": "mk", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableOrderedIndex": 1 } ] }', TRUE);

-- 200 scalar documents plus one multikey document with three array elements.
SELECT COUNT(documentdb_api.insert_one('mkbitmap_db', 'mk', FORMAT('{ "_id": %s, "a": %s }', i, i)::bson)) FROM generate_series(1, 200) AS i;
SELECT documentdb_api.insert_one('mkbitmap_db', 'mk', '{ "_id": 9999, "a": [1, 90, 100] }'::bson);

ANALYZE documentdb_data.documents_93501;

------------------------------------------------------------------------------
-- Bitmap safeguard on: the multikey index forces a de-duplicating bitmap scan
-- (dc.type = 4). Draining { "a": { "$exists": true } } returns all 201 documents
-- exactly once (the multikey document is not re-emitted).
------------------------------------------------------------------------------
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enable_dynamic_cursor_multikey_bitmap TO on;

SELECT bson_dollar_project(continuation, '{ "qp": 1, "dc.type": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'mkbitmap_db',
    commandSpec => '{ "find": "mk", "filter": { "a": { "$exists": true } }, "hint": "a_1", "batchSize": 1 }',
    cursorId => 93501);

DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_batch bigint;
    v_total bigint := 0;
BEGIN
    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(
        database => 'mkbitmap_db',
        commandSpec => '{ "find": "mk", "filter": { "a": { "$exists": true } }, "hint": "a_1", "batchSize": 1 }'::documentdb_core.bson,
        cursorId => 93502);
    SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
    v_total := v_total + COALESCE(v_batch, 0);

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'mkbitmap_db',
            getMoreSpec => '{ "getMore": { "$numberLong": "93502" }, "collection": "mk", "batchSize": 1 }'::documentdb_core.bson,
            continuationSpec => v_cont) gm;
        SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
        v_total := v_total + COALESCE(v_batch, 0);
    END LOOP;

    RAISE NOTICE 'multikey bitmap gate on - drained total rows: %', v_total;
END$$;

------------------------------------------------------------------------------
-- Default (GUC off): the safeguard is disabled, so the cursor takes the ordered
-- Secondary Index Scan (dc.type = 3). This scan carries its deduplication state
-- forward in the continuation token, so the multikey document is still returned
-- only once across pages and the drained total is 201.
------------------------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_multikey_bitmap TO off;

SELECT bson_dollar_project(continuation, '{ "qp": 1, "dc.type": 1 }') AS continuation_flags
FROM find_cursor_first_page(
    database => 'mkbitmap_db',
    commandSpec => '{ "find": "mk", "filter": { "a": { "$exists": true } }, "hint": "a_1", "batchSize": 1 }',
    cursorId => 93503);

DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_batch bigint;
    v_total bigint := 0;
BEGIN
    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(
        database => 'mkbitmap_db',
        commandSpec => '{ "find": "mk", "filter": { "a": { "$exists": true } }, "hint": "a_1", "batchSize": 1 }'::documentdb_core.bson,
        cursorId => 93504);
    SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
    v_total := v_total + COALESCE(v_batch, 0);

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'mkbitmap_db',
            getMoreSpec => '{ "getMore": { "$numberLong": "93504" }, "collection": "mk", "batchSize": 1 }'::documentdb_core.bson,
            continuationSpec => v_cont) gm;
        SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
        v_total := v_total + COALESCE(v_batch, 0);
    END LOOP;

    RAISE NOTICE 'multikey bitmap gate off - drained total rows: %', v_total;
END$$;

RESET documentdb.enable_dynamic_cursor_multikey_bitmap;

SELECT documentdb_api.drop_collection('mkbitmap_db', 'mk');
