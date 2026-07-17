-- Cross-page deduplication for streaming (ordered) index scans over a multikey
-- (array-path) composite index.
--
-- An ordered index scan yields one index entry per array element, so a single
-- multikey document is visited several times at different key positions. When the
-- scan is paginated by a dynamic cursor, the same document could therefore be
-- re-emitted on a later page unless the set of already-returned row pointers is
-- carried forward in the continuation token.
--
-- The scan builds a row-pointer bitmap (the "dedup state") and serializes it into
-- the continuation as the "sds" field. On a subsequent getMore the bitmap is
-- restored so previously-returned documents are suppressed, and each document is
-- returned exactly once across pages.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 96000;
SET documentdb.next_collection_index_id TO 96000;

-- Force the ordered (streaming) index scan and disable the multikey bitmap
-- safeguard, so the cursor takes the de-duplicating ordered Secondary Index Scan
-- path (dc.type = 3) whose continuation carries the serialized dedup state.
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;
SET enable_indexonlyscan TO off;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enable_dynamic_cursor_multikey_bitmap TO off;

SELECT documentdb_api.create_collection('dedup_db', 'mk');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dedup_db',
    '{ "createIndexes": "mk", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableOrderedIndex": 1 } ] }', TRUE);

-- 200 scalar documents plus one multikey document whose three array elements
-- (1, 90, 100) land at three different key positions in the ordered scan.
SELECT COUNT(documentdb_api.insert_one('dedup_db', 'mk', FORMAT('{ "_id": %s, "a": %s }', i, i)::bson)) FROM generate_series(1, 200) AS i;
SELECT documentdb_api.insert_one('dedup_db', 'mk', '{ "_id": 9999, "a": [1, 90, 100] }'::bson);

ANALYZE documentdb_data.documents_96001;

------------------------------------------------------------------------------
-- The scan is the ordered Secondary Index Scan (dc.type = 3), and its first-page
-- continuation carries the serialized dedup state ("sds").
------------------------------------------------------------------------------
SELECT bson_dollar_project(
           continuation,
           '{ "dc.type": 1, "has_sds": { "$ne": [ { "$type": "$dc.sds" }, "missing" ] } }') AS first_page_flags
FROM find_cursor_first_page(
    database => 'dedup_db',
    commandSpec => '{ "find": "mk", "filter": { "a": { "$gte": 1 } }, "hint": "a_1", "batchSize": 10 }',
    cursorId => 96001);

------------------------------------------------------------------------------
-- Drain the whole cursor and count how many documents come back. The multikey
-- document is suppressed after its first emission, so the total is 201 (200
-- scalar docs + the multikey doc once) and the distinct _id count is 201.
------------------------------------------------------------------------------
DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_batch bigint;
    v_total bigint := 0;
BEGIN
    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(
        database => 'dedup_db',
        commandSpec => '{ "find": "mk", "filter": { "a": { "$gte": 1 } }, "hint": "a_1", "batchSize": 10 }'::documentdb_core.bson,
        cursorId => 96002);
    SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
    v_total := v_total + COALESCE(v_batch, 0);

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'dedup_db',
            getMoreSpec => '{ "getMore": { "$numberLong": "96002" }, "collection": "mk", "batchSize": 10 }'::documentdb_core.bson,
            continuationSpec => v_cont) gm;
        SELECT (bson_dollar_project(v_page, '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_batch;
        v_total := v_total + COALESCE(v_batch, 0);
    END LOOP;

    -- Each document is returned exactly once across pages.
    RAISE NOTICE 'drained total rows: %', v_total;
END$$;

SELECT documentdb_api.drop_collection('dedup_db', 'mk');

------------------------------------------------------------------------------
-- Exhaustive proof of cross-page dedup correctness.
--
-- The remaining scenarios drain the whole cursor, collect every returned _id, and
-- assert that (1) no _id is emitted twice and (2) the returned set exactly matches
-- the expected set - across many batch sizes (which exercises every page boundary)
-- and across single-field, multi-field composite, and wildcard-root ordered
-- indexes, including duplicate-heavy data. The GUCs set at the top of this file
-- (ordered scan forced, bitmap safeguard off) still apply.
------------------------------------------------------------------------------

-- Scratch tables used by the drain/verify helpers.
CREATE TEMP TABLE dedup_drained_ids (id bigint);
CREATE TEMP TABLE dedup_expected_ids (id bigint);

-- Drain a whole cursor (find + getMore until the continuation is exhausted) and
-- record every returned _id into dedup_drained_ids, one row per emission (so a
-- re-emitted document would show up as a duplicate row).
CREATE OR REPLACE FUNCTION dedup_drain_ids(
    p_db text, p_coll text, p_filter text, p_hint text, p_batch int, p_cursor_id bigint
) RETURNS void AS $$
DECLARE
    v_find text;
    v_getmore text;
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_size int;
    v_i int;
    v_id bigint;
    v_field text := 'firstBatch';
BEGIN
    TRUNCATE dedup_drained_ids;

    v_find := FORMAT('{ "find": "%s", "filter": %s, "hint": "%s", "batchSize": %s }',
                     p_coll, p_filter, p_hint, p_batch);
    v_getmore := FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "%s", "batchSize": %s }',
                        p_cursor_id, p_coll, p_batch);

    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(
        database => p_db,
        commandSpec => v_find::documentdb_core.bson,
        cursorId => p_cursor_id);

    LOOP
        SELECT (bson_dollar_project(v_page,
                    FORMAT('{ "c": { "$size": { "$ifNull": ["$cursor.%s", []] } } }', v_field)::documentdb_core.bson) ->> 'c')::int
            INTO v_size;

        IF v_size IS NOT NULL AND v_size > 0 THEN
            FOR v_i IN 0 .. v_size - 1 LOOP
                SELECT (bson_dollar_project(v_page,
                            FORMAT('{ "v": { "$arrayElemAt": ["$cursor.%s._id", %s] } }', v_field, v_i)::documentdb_core.bson) ->> 'v')::bigint
                    INTO v_id;
                INSERT INTO dedup_drained_ids(id) VALUES (v_id);
            END LOOP;
        END IF;

        EXIT WHEN v_cont IS NULL;

        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => p_db,
            getMoreSpec => v_getmore::documentdb_core.bson,
            continuationSpec => v_cont) gm;
        v_field := 'nextBatch';
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Assert that the drained _ids contain no duplicates and exactly match the set in
-- dedup_expected_ids. Raises (failing the test) if dedup dropped, duplicated, or
-- skipped any document; otherwise stays silent so the batch-size sweep is quiet.
CREATE OR REPLACE FUNCTION dedup_verify(p_label text) RETURNS void AS $$
DECLARE
    v_total bigint;
    v_distinct bigint;
    v_expected bigint;
    v_missing bigint;
    v_extra bigint;
BEGIN
    SELECT count(*), count(DISTINCT id) INTO v_total, v_distinct FROM dedup_drained_ids;
    SELECT count(*) INTO v_expected FROM dedup_expected_ids;

    SELECT count(*) INTO v_missing FROM (
        SELECT id FROM dedup_expected_ids EXCEPT SELECT id FROM dedup_drained_ids) m;
    SELECT count(*) INTO v_extra FROM (
        SELECT DISTINCT id FROM dedup_drained_ids EXCEPT SELECT id FROM dedup_expected_ids) e;

    IF v_total <> v_distinct THEN
        RAISE EXCEPTION '% : % duplicate emissions (total=%, distinct=%)',
            p_label, v_total - v_distinct, v_total, v_distinct;
    END IF;
    IF v_missing <> 0 OR v_extra <> 0 THEN
        RAISE EXCEPTION '% : set mismatch (missing=%, extra=%, distinct=%, expected=%)',
            p_label, v_missing, v_extra, v_distinct, v_expected;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Sweep every batch size in [p_min, p_max]: drain and verify at each. A single OK
-- line summarizes the whole sweep so the expected output stays stable.
CREATE OR REPLACE FUNCTION dedup_sweep(
    p_db text, p_coll text, p_filter text, p_hint text, p_min int, p_max int, p_cursor_id bigint
) RETURNS void AS $$
DECLARE
    v_bs int;
BEGIN
    FOR v_bs IN p_min .. p_max LOOP
        PERFORM dedup_drain_ids(p_db, p_coll, p_filter, p_hint, v_bs, p_cursor_id);
        PERFORM dedup_verify(FORMAT('%s batch=%s', p_coll, v_bs));
    END LOOP;
    RAISE NOTICE '% : every batch size in [%, %] returns each document exactly once',
        p_coll, p_min, p_max;
END;
$$ LANGUAGE plpgsql;

------------------------------------------------------------------------------
-- Scenario 1: single-field composite (ordered) index, one multikey document.
-- 200 scalar docs plus one document whose array elements land at three distinct
-- key positions. Expected distinct set is the 200 scalars + the multikey doc.
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('dedup_db', 'single');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dedup_db',
    '{ "createIndexes": "single", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableOrderedIndex": 1 } ] }', TRUE);

SELECT COUNT(documentdb_api.insert_one('dedup_db', 'single', FORMAT('{ "_id": %s, "a": %s }', i, i)::bson)) FROM generate_series(1, 200) AS i;
SELECT documentdb_api.insert_one('dedup_db', 'single', '{ "_id": 9999, "a": [1, 90, 100] }'::bson);
ANALYZE documentdb_data.documents_96002;

-- Confirm the ordered dedup path (dc.type = 3) carrying serialized dedup state.
SELECT bson_dollar_project(
           continuation,
           '{ "dc.type": 1, "has_sds": { "$ne": [ { "$type": "$dc.sds" }, "missing" ] } }') AS flags
FROM find_cursor_first_page(
    database => 'dedup_db',
    commandSpec => '{ "find": "single", "filter": { "a": { "$gte": 1 } }, "hint": "a_1", "batchSize": 7 }',
    cursorId => 96101);

TRUNCATE dedup_expected_ids;
INSERT INTO dedup_expected_ids SELECT generate_series(1, 200);
INSERT INTO dedup_expected_ids VALUES (9999);
SELECT dedup_sweep('dedup_db', 'single', '{ "a": { "$gte": 1 } }', 'a_1', 1, 15, 96110);

------------------------------------------------------------------------------
-- Scenario 2: duplicate-heavy single-field ordered index. Every document is
-- multikey with a 30-element array, and the arrays overlap heavily, so the
-- ordered scan produces 60 * 31 = 1860 index entries for only 60 documents.
-- Dedup must collapse those back to exactly 60 documents.
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('dedup_db', 'heavy');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dedup_db',
    '{ "createIndexes": "heavy", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableOrderedIndex": 1 } ] }', TRUE);

-- Each document carries the same 30 values [1..30] plus one unique value, so most
-- index entries collide across documents and every document appears 31 times.
SELECT COUNT(documentdb_api.insert_one('dedup_db', 'heavy',
    FORMAT('{ "_id": %s, "a": [%s, %s] }',
           i,
           (SELECT string_agg(g::text, ', ') FROM generate_series(1, 30) AS g),
           1000 + i)::bson))
FROM generate_series(1, 60) AS i;
ANALYZE documentdb_data.documents_96003;

SELECT bson_dollar_project(
           continuation,
           '{ "dc.type": 1, "has_sds": { "$ne": [ { "$type": "$dc.sds" }, "missing" ] } }') AS flags
FROM find_cursor_first_page(
    database => 'dedup_db',
    commandSpec => '{ "find": "heavy", "filter": { "a": { "$gte": 1 } }, "hint": "a_1", "batchSize": 7 }',
    cursorId => 96201);

TRUNCATE dedup_expected_ids;
INSERT INTO dedup_expected_ids SELECT generate_series(1, 60);
SELECT dedup_sweep('dedup_db', 'heavy', '{ "a": { "$gte": 1 } }', 'a_1', 1, 20, 96210);

------------------------------------------------------------------------------
-- Scenario 3: multi-field composite (ordered) index { a: 1, b: 1 } where b is a
-- multikey array. Dedup is by heap tuple regardless of which key positions a
-- document occupies, so every document is returned exactly once.
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('dedup_db', 'composite');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dedup_db',
    '{ "createIndexes": "composite", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }', TRUE);

-- 150 documents, each multikey on b (three elements), grouped into 10 "a" buckets.
SELECT COUNT(documentdb_api.insert_one('dedup_db', 'composite',
    FORMAT('{ "_id": %s, "a": %s, "b": [1, 2, 3] }', i, i % 10)::bson))
FROM generate_series(1, 150) AS i;
ANALYZE documentdb_data.documents_96004;

SELECT bson_dollar_project(
           continuation,
           '{ "dc.type": 1, "has_sds": { "$ne": [ { "$type": "$dc.sds" }, "missing" ] } }') AS flags
FROM find_cursor_first_page(
    database => 'dedup_db',
    commandSpec => '{ "find": "composite", "filter": { "a": { "$gte": 0 } }, "hint": "a_b_1", "batchSize": 7 }',
    cursorId => 96301);

TRUNCATE dedup_expected_ids;
INSERT INTO dedup_expected_ids SELECT generate_series(1, 150);
SELECT dedup_sweep('dedup_db', 'composite', '{ "a": { "$gte": 0 } }', 'a_b_1', 1, 15, 96310);

------------------------------------------------------------------------------
-- Scenario 4: wildcard root index ("$**") over multikey documents. A wildcard
-- index explodes arrays into one entry per element; with the bitmap safeguard off
-- the cursor takes the ordered dedup path and must still return each document once.
------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('dedup_db', 'wildcard');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'dedup_db',
    '{ "createIndexes": "wildcard", "indexes": [ { "key": { "$**": 1 }, "name": "wc_1" } ] }', TRUE);

-- 80 documents each multikey on a (four elements that overlap across documents).
SELECT COUNT(documentdb_api.insert_one('dedup_db', 'wildcard',
    FORMAT('{ "_id": %s, "a": [1, 2, 3, %s] }', i, 100 + i)::bson))
FROM generate_series(1, 80) AS i;
ANALYZE documentdb_data.documents_96005;

SELECT bson_dollar_project(
           continuation,
           '{ "dc.type": 1, "has_sds": { "$ne": [ { "$type": "$dc.sds" }, "missing" ] } }') AS flags
FROM find_cursor_first_page(
    database => 'dedup_db',
    commandSpec => '{ "find": "wildcard", "filter": { "a": { "$gte": 1 } }, "hint": "wc_1", "batchSize": 7 }',
    cursorId => 96401);

TRUNCATE dedup_expected_ids;
INSERT INTO dedup_expected_ids SELECT generate_series(1, 80);
SELECT dedup_sweep('dedup_db', 'wildcard', '{ "a": { "$gte": 1 } }', 'wc_1', 1, 15, 96410);

------------------------------------------------------------------------------
-- Cross-check: the ordered dedup path returns the exact same document set as the
-- de-duplicating bitmap scan (the independent ground-truth path). Run the heavy
-- duplicate-laden collection through both and compare the distinct _id sets.
------------------------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_multikey_bitmap TO on;
SELECT dedup_drain_ids('dedup_db', 'heavy', '{ "a": { "$gte": 1 } }', 'a_1', 9, 96220);
CREATE TEMP TABLE dedup_bitmap_ids AS SELECT DISTINCT id FROM dedup_drained_ids;

SET documentdb.enable_dynamic_cursor_multikey_bitmap TO off;
SELECT dedup_drain_ids('dedup_db', 'heavy', '{ "a": { "$gte": 1 } }', 'a_1', 9, 96221);

SELECT
    (SELECT count(*) FROM (SELECT id FROM dedup_bitmap_ids EXCEPT SELECT DISTINCT id FROM dedup_drained_ids) x) AS only_in_bitmap,
    (SELECT count(*) FROM (SELECT DISTINCT id FROM dedup_drained_ids EXCEPT SELECT id FROM dedup_bitmap_ids) x) AS only_in_ordered,
    (SELECT count(DISTINCT id) FROM dedup_drained_ids) AS ordered_distinct,
    (SELECT count(*) FROM dedup_bitmap_ids) AS bitmap_distinct;

DROP TABLE dedup_bitmap_ids;

------------------------------------------------------------------------------
-- GUC gate: with enable_dynamic_cursor_dedup_tracking off, the ordered scan does
-- not track dedup state, so the continuation carries no serialized state (dc.sds
-- absent) while still taking the ordered scan path (dc.type = 3). Restoring the
-- default re-enables the carried dedup state.
------------------------------------------------------------------------------
SET documentdb.enable_dynamic_cursor_dedup_tracking TO off;
SELECT bson_dollar_project(
           continuation,
           '{ "dc.type": 1, "has_sds": { "$ne": [ { "$type": "$dc.sds" }, "missing" ] } }') AS flags_tracking_off
FROM find_cursor_first_page(
    database => 'dedup_db',
    commandSpec => '{ "find": "heavy", "filter": { "a": { "$gte": 1 } }, "hint": "a_1", "batchSize": 9 }',
    cursorId => 96230);

SET documentdb.enable_dynamic_cursor_dedup_tracking TO on;
SELECT bson_dollar_project(
           continuation,
           '{ "dc.type": 1, "has_sds": { "$ne": [ { "$type": "$dc.sds" }, "missing" ] } }') AS flags_tracking_on
FROM find_cursor_first_page(
    database => 'dedup_db',
    commandSpec => '{ "find": "heavy", "filter": { "a": { "$gte": 1 } }, "hint": "a_1", "batchSize": 9 }',
    cursorId => 96231);

SELECT documentdb_api.drop_collection('dedup_db', 'single');
SELECT documentdb_api.drop_collection('dedup_db', 'heavy');
SELECT documentdb_api.drop_collection('dedup_db', 'composite');
SELECT documentdb_api.drop_collection('dedup_db', 'wildcard');
