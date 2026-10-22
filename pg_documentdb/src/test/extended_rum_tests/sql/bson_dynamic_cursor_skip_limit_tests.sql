-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

-- Tests for dynamic cursor pagination correctness across skip (offset) and
-- limit, on a single-node unsharded collection. This is the Tier 1 suite from
-- the "Required coverage: skip / offset / limit" test plan: it drains cursors
-- across a batch-size sweep and asserts the EXACT windowed result set (correct
-- offset applied, correct count, correct ordering, no gaps/duplicates across
-- page boundaries) plus the cursor classification (streamable vs persistent).
--
-- Design rule under test: eligible find commands with skip or limit use a
-- dynamic streaming cursor when the underlying scan is streamable. Aggregation
-- stages and blocking plans remain persistent. Results must be identical
-- regardless of batch size and whether the query uses an index.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 9900;
SET documentdb.next_collection_index_id TO 9900;

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;
SET documentdb.enable_dynamic_cursor_with_skiplimit TO on;
SET enable_seqscan TO off;

-- ===========================================================================
-- Data setup
--   slc_coll : 30 docs, _id = val = i (1..30), cat = even/odd, indexed on val
--              (asc + desc) and (cat, val). Deterministic ordered windows.
--   slc_noidx: 25 docs, _id = i, k = i, NO secondary index (PK / seq only) -
--              used for the "not pushed to an index" cases.
-- ===========================================================================
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_coll');
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_noidx');
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_pk');
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_bm');

SELECT COUNT(documentdb_api.insert_one('dyncur_slc_db', 'slc_coll',
    FORMAT('{ "_id": %s, "val": %s, "cat": "%s" }',
           i, i, CASE WHEN i % 2 = 0 THEN 'even' ELSE 'odd' END)::documentdb_core.bson))
FROM generate_series(1, 30) AS i;

SELECT COUNT(documentdb_api.insert_one('dyncur_slc_db', 'slc_noidx',
    FORMAT('{ "_id": %s, "k": %s }', i, i)::documentdb_core.bson))
FROM generate_series(1, 25) AS i;

-- slc_pk: 1000 docs, _id = v = i, NO secondary index. Large-scale primary-key
-- drain (P0-2): the default streaming path for find({}) and _id-sorted queries.
SELECT COUNT(documentdb_api.insert_one('dyncur_slc_db', 'slc_pk',
    FORMAT('{ "_id": %s, "v": %s }', i, i)::documentdb_core.bson))
FROM generate_series(1, 1000) AS i;

-- slc_bm: 1000 docs with two independent moderate-selectivity fields for bitmap
-- scans (P1-4). x = i%10 (10 values), y = i%7 (7 values); coprime moduli give
-- independent distributions. Padding creates many heap pages so the planner
-- prefers bitmap scans over plain index scans when index scan is disabled.
SELECT COUNT(documentdb_api.insert_one('dyncur_slc_db', 'slc_bm',
    FORMAT('{ "_id": %s, "x": %s, "y": %s, "pad": "%s" }',
           i, i % 10, i % 7, repeat('P', 200))::documentdb_core.bson))
FROM generate_series(0, 999) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_slc_db',
    '{"createIndexes": "slc_coll", "indexes": [{"key": {"val": 1}, "name": "idx_val_asc"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_slc_db',
    '{"createIndexes": "slc_coll", "indexes": [{"key": {"val": -1}, "name": "idx_val_desc"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_slc_db',
    '{"createIndexes": "slc_coll", "indexes": [{"key": {"cat": 1, "val": 1}, "name": "idx_cat_val"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_slc_db',
    '{"createIndexes": "slc_bm", "indexes": [{"key": {"x": 1}, "name": "x_1"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_slc_db',
    '{"createIndexes": "slc_bm", "indexes": [{"key": {"y": 1}, "name": "y_1"}]}', true);

ANALYZE;

-- ===========================================================================
-- Core drain helpers: drain a find/aggregate cursor across all pages and
-- return the ordered concatenation of returned _id values (",1,2,3"), the total
-- count, the persistConnection flag, the first-page dc.type (NULL for
-- persistent cursors), and the number of round trips.
-- ===========================================================================
CREATE OR REPLACE FUNCTION slc_drain(p_find text, p_getmore text)
RETURNS TABLE(ids text, total bigint, persist bool, first_type int, pages int) AS $body$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_ids text := '';
    v_total bigint := 0;
    v_type int := NULL;
    v_pages int := 0;
    v_n bigint;
BEGIN
    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
      INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page(database => 'dyncur_slc_db',
        commandSpec => p_find::documentdb_core.bson, cursorId => 600) fp;
    v_pages := 1;
    v_ids := v_ids || COALESCE(bson_dollar_project(v_page,
        '{ "s": { "$reduce": { "input": "$cursor.firstBatch", "initialValue": "", "in": { "$concat": ["$$value", ",", { "$toString": "$$this._id" }] } } } }') ->> 's', '');
    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_n;
    v_total := v_total + COALESCE(v_n, 0);
    IF v_cont IS NOT NULL THEN
        v_type := (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int;
    END IF;

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(database => 'dyncur_slc_db',
            getMoreSpec => p_getmore::documentdb_core.bson, continuationSpec => v_cont) gm;
        v_pages := v_pages + 1;
        v_ids := v_ids || COALESCE(bson_dollar_project(v_page,
            '{ "s": { "$reduce": { "input": "$cursor.nextBatch", "initialValue": "", "in": { "$concat": ["$$value", ",", { "$toString": "$$this._id" }] } } } }') ->> 's', '');
        SELECT (bson_dollar_project(v_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_n;
        v_total := v_total + COALESCE(v_n, 0);
    END LOOP;

    ids := v_ids; total := v_total; persist := v_persist; first_type := v_type; pages := v_pages;
    RETURN NEXT;
END;
$body$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION slc_drain_agg(p_agg text, p_getmore text)
RETURNS TABLE(ids text, total bigint, persist bool, first_type int, pages int) AS $body$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_ids text := '';
    v_total bigint := 0;
    v_type int := NULL;
    v_pages int := 0;
    v_n bigint;
BEGIN
    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
      INTO v_page, v_cont, v_persist
    FROM aggregate_cursor_first_page(database => 'dyncur_slc_db',
        commandSpec => p_agg::documentdb_core.bson, cursorId => 600) fp;
    v_pages := 1;
    v_ids := v_ids || COALESCE(bson_dollar_project(v_page,
        '{ "s": { "$reduce": { "input": "$cursor.firstBatch", "initialValue": "", "in": { "$concat": ["$$value", ",", { "$toString": "$$this._id" }] } } } }') ->> 's', '');
    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_n;
    v_total := v_total + COALESCE(v_n, 0);
    IF v_cont IS NOT NULL THEN
        v_type := (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int;
    END IF;

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(database => 'dyncur_slc_db',
            getMoreSpec => p_getmore::documentdb_core.bson, continuationSpec => v_cont) gm;
        v_pages := v_pages + 1;
        v_ids := v_ids || COALESCE(bson_dollar_project(v_page,
            '{ "s": { "$reduce": { "input": "$cursor.nextBatch", "initialValue": "", "in": { "$concat": ["$$value", ",", { "$toString": "$$this._id" }] } } } }') ->> 's', '');
        SELECT (bson_dollar_project(v_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_n;
        v_total := v_total + COALESCE(v_n, 0);
    END LOOP;

    ids := v_ids; total := v_total; persist := v_persist; first_type := v_type; pages := v_pages;
    RETURN NEXT;
END;
$body$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Assertion helper for ORDERED (sorted) queries: drains the query at every
-- batch size and asserts the exact ordered _id window equals p_expected_ids.
-- Also asserts the cursor classification (persist / dc.type) is identical
-- across all batch sizes. p_expected_type / p_expected_persist are optional
-- extra assertions. Returns a compact one-line summary for the .out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION slc_ordered(
    p_label text, p_find_tmpl text, p_getmore_tmpl text,
    p_batch_sizes int[], p_expected_ids text,
    p_is_agg bool DEFAULT false,
    p_expected_persist bool DEFAULT NULL,
    p_expected_type int DEFAULT NULL
) RETURNS text AS $body$
DECLARE
    v_bs int; r record; v_first bool := true; v_rp bool; v_rt int;
    v_expected_count bigint :=
        length(p_expected_ids) - length(replace(p_expected_ids, ',', ''));
BEGIN
    FOREACH v_bs IN ARRAY p_batch_sizes LOOP
        IF p_is_agg THEN
            SELECT * INTO r FROM slc_drain_agg(format(p_find_tmpl, v_bs), format(p_getmore_tmpl, v_bs));
        ELSE
            SELECT * INTO r FROM slc_drain(format(p_find_tmpl, v_bs), format(p_getmore_tmpl, v_bs));
        END IF;

        IF r.ids IS DISTINCT FROM p_expected_ids THEN
            RAISE EXCEPTION '%: batchSize=%: id window mismatch: got=[%] expected=[%]',
                p_label, v_bs, r.ids, p_expected_ids;
        END IF;
        IF v_bs < v_expected_count AND r.pages < 2 THEN
            RAISE EXCEPTION '%: batchSize=%: expected pagination for % rows, got % page',
                p_label, v_bs, v_expected_count, r.pages;
        END IF;
        IF p_expected_persist IS NOT NULL AND r.persist IS DISTINCT FROM p_expected_persist THEN
            RAISE EXCEPTION '%: batchSize=%: expected persist=%, got %', p_label, v_bs, p_expected_persist, r.persist;
        END IF;
        -- dc.type is only observable when a continuation exists (multi-page).
        IF p_expected_type IS NOT NULL AND v_bs < v_expected_count AND
           r.first_type IS DISTINCT FROM p_expected_type THEN
            RAISE EXCEPTION '%: batchSize=%: expected dc.type=%, got %', p_label, v_bs, p_expected_type, r.first_type;
        END IF;

        -- persistConnection must be stable across batch sizes; capture the first
        -- observable (non-NULL) dc.type for the summary.
        IF v_first THEN
            v_rp := r.persist; v_first := false;
        ELSIF r.persist IS DISTINCT FROM v_rp THEN
            RAISE EXCEPTION '%: persistConnection changed across batch sizes (%/%)', p_label, v_rp, r.persist;
        END IF;
        IF v_rt IS NULL AND r.first_type IS NOT NULL THEN v_rt := r.first_type; END IF;
    END LOOP;

    RETURN format('%s: OK  count=%s  persist=%s  dc.type=%s', p_label,
        v_expected_count, v_rp, COALESCE(v_rt::text, '-'));
END;
$body$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Assertion helper for UNSORTED queries (natural order is unspecified, so we
-- assert the total count, the absence of duplicates across pages, and the
-- classification - not a specific ordered sequence).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION slc_count(
    p_label text, p_find_tmpl text, p_getmore_tmpl text,
    p_batch_sizes int[], p_expected_count bigint,
    p_is_agg bool DEFAULT false,
    p_expected_persist bool DEFAULT NULL,
    p_expected_type int DEFAULT NULL
) RETURNS text AS $body$
DECLARE
    v_bs int; r record; v_first bool := true; v_rp bool; v_rt int;
    v_arr text[]; v_distinct bigint;
BEGIN
    FOREACH v_bs IN ARRAY p_batch_sizes LOOP
        IF p_is_agg THEN
            SELECT * INTO r FROM slc_drain_agg(format(p_find_tmpl, v_bs), format(p_getmore_tmpl, v_bs));
        ELSE
            SELECT * INTO r FROM slc_drain(format(p_find_tmpl, v_bs), format(p_getmore_tmpl, v_bs));
        END IF;

        IF r.total IS DISTINCT FROM p_expected_count THEN
            RAISE EXCEPTION '%: batchSize=%: expected % rows, got %', p_label, v_bs, p_expected_count, r.total;
        END IF;
        IF v_bs < p_expected_count AND r.pages < 2 THEN
            RAISE EXCEPTION '%: batchSize=%: expected pagination for % rows, got % page',
                p_label, v_bs, p_expected_count, r.pages;
        END IF;
        IF r.total > 0 THEN
            v_arr := string_to_array(ltrim(r.ids, ','), ',');
            SELECT count(DISTINCT x) INTO v_distinct FROM unnest(v_arr) AS x;
            IF v_distinct <> r.total THEN
                RAISE EXCEPTION '%: batchSize=%: duplicate ids across pages (% distinct of %)',
                    p_label, v_bs, v_distinct, r.total;
            END IF;
        END IF;
        IF p_expected_persist IS NOT NULL AND r.persist IS DISTINCT FROM p_expected_persist THEN
            RAISE EXCEPTION '%: batchSize=%: expected persist=%, got %', p_label, v_bs, p_expected_persist, r.persist;
        END IF;
        -- dc.type is only observable when a continuation exists (multi-page).
        IF p_expected_type IS NOT NULL AND v_bs < p_expected_count AND
           r.first_type IS DISTINCT FROM p_expected_type THEN
            RAISE EXCEPTION '%: batchSize=%: expected dc.type=%, got %', p_label, v_bs, p_expected_type, r.first_type;
        END IF;

        -- persistConnection must be stable across batch sizes; capture the first
        -- observable (non-NULL) dc.type for the summary.
        IF v_first THEN
            v_rp := r.persist; v_first := false;
        ELSIF r.persist IS DISTINCT FROM v_rp THEN
            RAISE EXCEPTION '%: persistConnection changed across batch sizes (%/%)', p_label, v_rp, r.persist;
        END IF;
        IF v_rt IS NULL AND r.first_type IS NOT NULL THEN v_rt := r.first_type; END IF;
    END LOOP;

    RETURN format('%s: OK  count=%s  persist=%s  dc.type=%s  (no dups)', p_label,
        p_expected_count, v_rp, COALESCE(v_rt::text, '-'));
END;
$body$ LANGUAGE plpgsql;

-- Batch sizes swept for every case: 1 forces max round-trips, 30/100 force a
-- single page, 2/5/7 land page boundaries at various offsets relative to
-- skip/limit.
-- expected id builder: ids_asc(a,b) => ",a,...,b" ; ids_desc(a,b) => ",a,...,b" desc

-- ===========================================================================
-- SECTION S: skip / offset
-- ===========================================================================

-- S5: find sort {val:1} skip 5 -> streaming, ids 6..30 (offset applied once)
SELECT slc_ordered('S5 sort+skip>0',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 5, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,30,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(6,30) g),
    false, false);

-- S4: filter cat=even + sort {val:1} + skip 3 -> streaming, even ids 8..30
SELECT slc_ordered('S4 filter+sort+skip>0',
    '{ "find": "slc_coll", "filter": { "cat": "even" }, "sort": { "val": 1 }, "skip": 3, "batchSize": %s, "hint": "idx_cat_val" }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(8,30,2) g),
    false, false);

-- S2: find skip 5 (no filter/sort) -> streaming, natural order, count 25
SELECT slc_count('S2 skip>0 no-sort',
    '{ "find": "slc_coll", "skip": 5, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,30,100], 25, false, false);

-- S3: find filter cat=even + skip 3 (no sort) -> streaming, count 12
SELECT slc_count('S3 filter+skip>0 no-sort',
    '{ "find": "slc_coll", "filter": { "cat": "even" }, "skip": 3, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,100], 12, false, false);

-- S6: large streaming skip with small batches -> ids 21..30
SELECT slc_ordered('S6 skip spans pages',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 20, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,3,4,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(21,30) g),
    false, false);

-- S7: skip >= total -> empty window
SELECT slc_ordered('S7 skip=total (empty)',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 30, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,5,100], '', false, false);
SELECT slc_ordered('S7 skip>total (empty)',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 40, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,5,100], '', false, false);

-- S1: find skip 0 (streamable baseline) -> streaming PK scan (type 2), count 30
SELECT slc_count('S1 skip=0 streamable',
    '{ "find": "slc_coll", "skip": 0, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,30,100], 30, false, false, 2);

-- S8: aggregate $skip:0 (streamable baseline) -> streaming, count 30
SELECT slc_count('S8 $skip:0 streamable',
    '{ "aggregate": "slc_coll", "pipeline": [ { "$skip": 0 } ], "cursor": { "batchSize": %s } }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,30,100], 30, true, false);

-- S9: aggregate $skip>0 -> persistent, count 25
SELECT slc_count('S9 $skip>0 persistent',
    '{ "aggregate": "slc_coll", "pipeline": [ { "$skip": 5 } ], "cursor": { "batchSize": %s } }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,100], 25, true, true);

-- ===========================================================================
-- SECTION L: limit
-- ===========================================================================

-- L4: find sort {val:1} limit 10 -> streaming, ids 1..10
SELECT slc_ordered('L4 sort+limit>1',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "limit": 10, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,10,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,10) g),
    false, false);

-- L5: filter cat=odd + sort {val:1} + limit 5 -> streaming, odd ids 1..9
SELECT slc_ordered('L5 filter+sort+limit>1',
    '{ "find": "slc_coll", "filter": { "cat": "odd" }, "sort": { "val": 1 }, "limit": 5, "batchSize": %s, "hint": "idx_cat_val" }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,9,2) g),
    false, false);

-- L2: find limit 10 (no sort) -> streaming, count 10
SELECT slc_count('L2 limit>1 no-sort',
    '{ "find": "slc_coll", "limit": 10, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,100], 10, false, false);

-- L3: find filter cat=even + limit 5 (no sort) -> streaming, count 5
SELECT slc_count('L3 filter+limit>1 no-sort',
    '{ "find": "slc_coll", "filter": { "cat": "even" }, "limit": 5, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100], 5, false, false);

-- L1: find limit 1 -> single-batch streamable cursor (fits in one page), 1 doc
SELECT slc_count('L1 limit=1',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "limit": 1, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,5,100], 1, false, false);

-- L6: limit smaller than batch (single page) and limit spanning batches
SELECT slc_ordered('L6 limit<batch and limit spans',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "limit": 3, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,3,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,3) g),
    false, false);

-- L: limit >= total -> full set 1..30
SELECT slc_ordered('L limit>=total',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "limit": 100, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,5,7,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,30) g),
    false, false);

-- L8: aggregate $limit:1 remains persistent and returns exactly 1 doc
SELECT slc_count('L8 $limit:1',
    '{ "aggregate": "slc_coll", "pipeline": [ { "$sort": { "val": 1 } }, { "$limit": 1 } ], "cursor": { "batchSize": %s } }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,5,100], 1, true, true);

-- L9: aggregate $limit>1 -> persistent, count 10
SELECT slc_count('L9 $limit>1 persistent',
    '{ "aggregate": "slc_coll", "pipeline": [ { "$limit": 10 } ], "cursor": { "batchSize": %s } }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,100], 10, true, true);

-- ===========================================================================
-- SECTION SL: skip + limit combined
-- ===========================================================================

-- SL1: sort {val:1} skip 3 limit 7 -> streaming ids 4..10
SELECT slc_ordered('SL1 sort+skip+limit',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 3, "limit": 7, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(4,10) g),
    false, false);

-- SL2: filtered sorted skip + limit -> streaming even ids 6,8,10,12
SELECT slc_ordered('SL2 filter+sort+skip+limit',
    '{ "find": "slc_coll", "filter": { "cat": "even" }, "sort": { "val": 1 }, "skip": 2, "limit": 4, "batchSize": %s, "hint": "idx_cat_val" }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,3,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(6,12,2) g),
    false, false);

-- SL3: filter cat=even + skip 3 + limit 4 (NO sort) -> streaming, count 4
SELECT slc_count('SL3 filter+skip+limit no-sort',
    '{ "find": "slc_coll", "filter": { "cat": "even" }, "skip": 3, "limit": 4, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,3,100], 4, false, false);

-- SL4: skip 5 + limit 10 (NO filter/sort) -> streaming, count 10
SELECT slc_count('SL4 skip+limit no-sort',
    '{ "find": "slc_coll", "skip": 5, "limit": 10, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,7,100], 10, false, false);

-- SL5: skip + limit where skip+limit > total (partial window) -> ids 29,30
SELECT slc_ordered('SL5 skip+limit past end',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 28, "limit": 5, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(29,30) g),
    false, false);

-- SL7: aggregate $skip + $limit -> persistent, count 7
SELECT slc_count('SL7 $skip+$limit',
    '{ "aggregate": "slc_coll", "pipeline": [ { "$skip": 3 }, { "$limit": 7 } ], "cursor": { "batchSize": %s } }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100], 7, true, true);

-- ===========================================================================
-- SECTION DESC: descending sort windows (backward PK / descending index)
-- ===========================================================================

-- descending sort on indexed field + skip + limit -> ids 25,24,23,22,21
SELECT slc_ordered('DESC sort{val:-1}+skip+limit',
    '{ "find": "slc_coll", "sort": { "val": -1 }, "skip": 5, "limit": 5, "batchSize": %s, "hint": "idx_val_desc" }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g DESC) FROM generate_series(21,25) g),
    false, false);

-- descending sort on _id + skip + limit -> ids 25..21 desc (backward PK scan window)
SELECT slc_ordered('DESC sort{_id:-1}+skip+limit',
    '{ "find": "slc_coll", "sort": { "_id": -1 }, "skip": 5, "limit": 5, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g DESC) FROM generate_series(21,25) g),
    false, false);

-- ===========================================================================
-- SECTION EQ: index-ON vs index-OFF equivalence (pushed to index or not)
-- The same sorted skip/limit query must return the identical window whether it
-- is served by an index scan or forced onto a sequential scan.
-- ===========================================================================

-- Index available (default: seqscan off, indexes on) - already validated above
-- for the ascending window; run the descending _id window with the index on.
SELECT slc_ordered('EQ index-ON sort{val:1}+skip+limit',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 7, "limit": 8, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(8,15) g),
    false, false);

-- Disable ordinary index and bitmap scans. The dynamic planner still selects a
-- streamable ordered path, and the result window must remain identical.
SET enable_indexscan TO off;
SET enable_bitmapscan TO off;
SET enable_seqscan TO on;
SELECT slc_ordered('EQ index-OFF sort{val:1}+skip+limit (seq)',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "skip": 7, "limit": 8, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,5,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(8,15) g),
    false, false);
RESET enable_indexscan;
RESET enable_bitmapscan;
SET enable_seqscan TO off;

-- ===========================================================================
-- SECTION NIX: "not pushed to an index" - collection with no secondary index
-- ===========================================================================

-- Streamable baseline on a collection with no secondary index: find {} skip 0
-- still streams via the primary-key cursor scan (the _id index always exists),
-- count 25.
SELECT slc_count('NIX no-secondary-index streamable skip=0',
    '{ "find": "slc_noidx", "skip": 0, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_noidx", "batchSize": %s }',
    ARRAY[1,2,5,7,25,100], 25, false, false);

-- S10: skip>0 on a non-indexed field -> streaming via PK fallback, count 22
SELECT slc_count('NIX S10 skip>0 no-index',
    '{ "find": "slc_noidx", "filter": { "k": { "$gte": 1 } }, "skip": 3, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_noidx", "batchSize": %s }',
    ARRAY[1,2,5,7,100], 22, false, false);

-- L10: limit>1 with no secondary index -> streaming via PK fallback, count 7
SELECT slc_count('NIX L10 limit>1 no-index',
    '{ "find": "slc_noidx", "limit": 7, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_noidx", "batchSize": %s }',
    ARRAY[1,2,5,100], 7, false, false);

-- SL6: skip + limit with no secondary index -> streaming via PK fallback
SELECT slc_count('NIX SL6 skip+limit no-index',
    '{ "find": "slc_noidx", "skip": 4, "limit": 6, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_noidx", "batchSize": %s }',
    ARRAY[1,2,3,100], 6, false, false);

-- ===========================================================================
-- SECTION P0: blocking-confidence gaps from the coverage report
--   P0-2  large-scale primary-key multi-page drain / batch-size sweep
--   P0-1  "not pushed to an index" seq/TID path -> documented PK fallback
--   P0-3  same query, index-ON vs index-OFF, identical FULL result sequence
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- P0-2: primary-key large-scale drain over 1000 docs. PK is the default path
-- for find({}) and _id-sorted queries, so prove it paginates the entire set
-- correctly across a batch-size sweep (including batchSize=1 -> 1000 pages) in
-- both scan directions, streaming as dc.type=2.
-- ---------------------------------------------------------------------------

-- P0-2a: find {} skip 0 -> streaming PK scan (type 2), full 1000 docs.
SELECT slc_count('P0-2a PK large streamable skip=0',
    '{ "find": "slc_pk", "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_pk", "batchSize": %s }',
    ARRAY[1,100,1000], 1000, false, false, 2);

-- P0-2b: forward _id sort, full ordered window 1..1000, streams (type 2).
SELECT slc_ordered('P0-2b PK large sort{_id:1}',
    '{ "find": "slc_pk", "sort": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_pk", "batchSize": %s }',
    ARRAY[1,250,1000],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,1000) g),
    false, false, 2);

-- P0-2c: backward _id sort, full ordered window 1000..1 (backward PK scan).
SELECT slc_ordered('P0-2c PK large sort{_id:-1}',
    '{ "find": "slc_pk", "sort": { "_id": -1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_pk", "batchSize": %s }',
    ARRAY[1,250,1000],
    (SELECT string_agg(',' || g::text, '' ORDER BY g DESC) FROM generate_series(1,1000) g),
    false, false, 2);

-- P0-2d: large offset + limit streams the deep window 501..700.
SELECT slc_ordered('P0-2d PK large skip+limit deep',
    '{ "find": "slc_pk", "sort": { "_id": 1 }, "skip": 500, "limit": 200, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_pk", "batchSize": %s }',
    ARRAY[1,64,1000],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(501,700) g),
    false, false);

-- ---------------------------------------------------------------------------
-- P0-1: "not pushed to an index" seq/TID-range path. A collection with no
-- secondary index, with index & bitmap scans forced OFF and sequential scan
-- forced ON, would plan a SeqScan. The dynamic-cursor scan converts that
-- SeqScan to a primary-key cursor scan (the _id PK always exists), so it
-- streams the full set as dc.type=2 rather than a TID-range cursor (dc.type=1).
-- This documents the fallback: a true TID-range dynamic cursor is not
-- reachable while an _id primary key exists. Correctness of the full drained
-- window is the guarantee under test.
-- ---------------------------------------------------------------------------
SET enable_indexscan TO off;
SET enable_bitmapscan TO off;
SET enable_seqscan TO on;

-- P0-1a: forced seq path, find {} skip 0 -> streams via PK fallback, count 25.
SELECT slc_count('P0-1a seq-path streamable (PK fallback)',
    '{ "find": "slc_noidx", "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_noidx", "batchSize": %s }',
    ARRAY[1,2,5,7,100], 25, false, false, 2);

-- P0-1b: the forced sequential path needs a blocking sort, so it persists.
SELECT slc_ordered('P0-1b seq-path sort+skip+limit',
    '{ "find": "slc_noidx", "sort": { "_id": 1 }, "skip": 5, "limit": 10, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_noidx", "batchSize": %s }',
    ARRAY[1,2,5,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(6,15) g),
    false, true);

RESET enable_indexscan;
RESET enable_bitmapscan;
SET enable_seqscan TO off;

-- ---------------------------------------------------------------------------
-- P0-3: same query drained with the index available vs genuinely removed must
-- return the IDENTICAL full result sequence. EQ (above) proves this for an
-- 8-row window via a GUC toggle; here we prove it for the ENTIRE 30-row set by
-- actually dropping the sort index (a GUC toggle alone does not force the
-- non-index path because the API planner drives the ordered index-path cost to
-- zero). This is the strongest "pushed to an index or not" correctness guard.
-- ---------------------------------------------------------------------------

-- Index available: streams via the secondary index (dc.type=3), full 1..30.
SELECT slc_ordered('P0-3 index-ON full sort{val:1}',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,7,30,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,30) g),
    false, false, 3);

-- Drop the val indexes so the SAME query has no usable index: it now plans a
-- sequential scan + Sort, which cannot stream and falls back to a persistent
-- cursor. The full ordered result window must be IDENTICAL to the indexed run.
SET enable_seqscan TO on;
CALL documentdb_api.drop_indexes('dyncur_slc_db',
    '{ "dropIndexes": "slc_coll", "index": ["idx_val_asc", "idx_val_desc"] }');
ANALYZE;
SELECT slc_ordered('P0-3 no-index full sort{val:1} (identical window)',
    '{ "find": "slc_coll", "sort": { "val": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,2,7,30,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,30) g),
    false, true);
SET enable_seqscan TO off;

-- Restore the ascending index for the secondary-index boundary cases below.
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_slc_db',
    '{"createIndexes": "slc_coll", "indexes": [{"key": {"val": 1}, "name": "idx_val_asc"}]}', true);
ANALYZE;

-- ===========================================================================
-- SECTION P1: important gaps from the coverage report
--   P1-4  bitmap scans (single / AND / OR) drained across a batch-size sweep
--         over ~1000 docs - single-index bitmap resumes via a secondary-index
--         continuation (dc.type=3), BitmapAnd/BitmapOr keep their bitmap
--         continuations (dc.type=5 / dc.type=6)
-- (P1-5/P1-6/P1-7 are already covered above: unsorted skip/limit windows via
--  S2/S3/L2/L3/S6/SL3/SL4/NIX, aggregation $skip/$limit via S8/S9/L8/L9/SL7,
--  and the streamable find limit:1 via L1.)
-- ===========================================================================

-- Force the bitmap paths: with plain index scan and sequential scan disabled,
-- the planner chooses a Bitmap Heap Scan over the x_1 / y_1 indexes. These are
-- streamable dynamic cursors whose continuation is a TID-skip resume point.
SET enable_indexscan TO off;
SET enable_bitmapscan TO on;
SET enable_seqscan TO off;

-- P1-4a: single-index bitmap, filter { x: 5 }. Under enable_indexscan=off the
-- planner picks a Bitmap Heap Scan over x_1, but the dynamic-cursor scan resumes
-- a single-index bitmap via a Secondary Index Scan continuation (dc.type=3), so
-- it streams the full x=5 window (100 docs) across the sweep with no dups.
SELECT slc_count('P1-4a bitmap single {x:5}',
    '{ "find": "slc_bm", "filter": { "x": 5 }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_bm", "batchSize": %s }',
    ARRAY[1,7,50,1000],
    (SELECT count(*) FROM generate_series(0,999) i WHERE i % 10 = 5),
    false, false, 3);

-- P1-4b: BitmapAnd, filter { x: 5, y: 3 } -> BitmapAnd of x_1 & y_1 (dc.type=5),
-- streams the conjunction window across the sweep, no dups.
SELECT slc_count('P1-4b bitmap AND {x:5,y:3}',
    '{ "find": "slc_bm", "filter": { "x": 5, "y": 3 }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_bm", "batchSize": %s }',
    ARRAY[1,2,5,1000],
    (SELECT count(*) FROM generate_series(0,999) i WHERE i % 10 = 5 AND i % 7 = 3),
    false, false, 5);

-- P1-4c: BitmapOr, filter { $or: [{x:5},{y:3}] } -> BitmapOr of x_1 & y_1
-- (dc.type=6), streams the union window across the sweep, no dups.
SELECT slc_count('P1-4c bitmap OR {$or:[{x:5},{y:3}]}',
    '{ "find": "slc_bm", "filter": { "$or": [ { "x": 5 }, { "y": 3 } ] }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_bm", "batchSize": %s }',
    ARRAY[1,10,100,1000],
    (SELECT count(*) FROM generate_series(0,999) i WHERE i % 10 = 5 OR i % 7 = 3),
    false, false, 6);

RESET enable_indexscan;
RESET enable_bitmapscan;
SET enable_seqscan TO off;

-- ===========================================================================
-- SECTION P2: hardening / edge cases from the coverage report
--   P2-9   same-transaction mutations between cursor page calls - documents
--          command-counter-visible resume behavior as a regression baseline
--   P2-10  empty and boundary result sets (0 rows; count == batch; batch-1;
--          batch+1) for each scan type (PK / secondary index / bitmap)
--   P2-11  merge-sort / merge-append ($in equality prefix of the sort key)
--          drained across a batch-size sweep
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- P2-9 helper: drain a streaming cursor and execute a mutation after the first
-- page but before the remaining getMore calls. The mutation and drain run in one
-- function invocation and transaction, so this covers command-counter-visible
-- inter-page changes. Separate-session committed concurrency remains distinct
-- coverage. The helper prints the observed id sequence and count so a future
-- change to this resume behavior surfaces as an expected-output diff.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION slc_drain_mut(
    p_label text, p_find text, p_getmore text, p_after_page1_sql text
) RETURNS text AS $body$
DECLARE
    v_page documentdb_core.bson; v_cont documentdb_core.bson; v_persist bool;
    v_ids text := ''; v_total bigint := 0; v_pages int := 0; v_n bigint;
BEGIN
    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
      INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page(database => 'dyncur_slc_db',
        commandSpec => p_find::documentdb_core.bson, cursorId => 601) fp;
    v_pages := 1;
    v_ids := v_ids || COALESCE(bson_dollar_project(v_page,
        '{ "s": { "$reduce": { "input": "$cursor.firstBatch", "initialValue": "", "in": { "$concat": ["$$value", ",", { "$toString": "$$this._id" }] } } } }') ->> 's', '');
    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint INTO v_n;
    v_total := v_total + COALESCE(v_n, 0);

    -- Apply the mutation between page 1 and the rest of the drain.
    IF p_after_page1_sql IS NOT NULL THEN EXECUTE p_after_page1_sql; END IF;

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(database => 'dyncur_slc_db',
            getMoreSpec => p_getmore::documentdb_core.bson, continuationSpec => v_cont) gm;
        v_pages := v_pages + 1;
        v_ids := v_ids || COALESCE(bson_dollar_project(v_page,
            '{ "s": { "$reduce": { "input": "$cursor.nextBatch", "initialValue": "", "in": { "$concat": ["$$value", ",", { "$toString": "$$this._id" }] } } } }') ->> 's', '');
        SELECT (bson_dollar_project(v_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint INTO v_n;
        v_total := v_total + COALESCE(v_n, 0);
    END LOOP;

    RETURN format('%s: drained=%s  persist=%s  ids=[%s]', p_label, v_total, v_persist, ltrim(v_ids, ','));
END;
$body$ LANGUAGE plpgsql;

-- slc_mut: a small no-secondary-index collection (PK streaming cursor,
-- dc.type=2). Recreated fresh before every mutation case so each case starts
-- from an identical 20-doc baseline (_id = 1..20).
CREATE OR REPLACE FUNCTION slc_mut_reset() RETURNS void AS $body$
BEGIN
    PERFORM documentdb_api.drop_collection('dyncur_slc_db', 'slc_mut');
    PERFORM COUNT(documentdb_api.insert_one('dyncur_slc_db', 'slc_mut',
        FORMAT('{ "_id": %s, "k": %s }', i, i)::documentdb_core.bson))
    FROM generate_series(1, 20) AS i;
END;
$body$ LANGUAGE plpgsql;

-- P2-9a: INSERT a new document (_id 99) between page calls. Baseline before the
-- write is 20 docs; the insert runs after page 1 (batchSize 5).
SELECT slc_mut_reset();
SELECT slc_drain_mut('P2-9a insert mid-cursor',
    '{ "find": "slc_mut", "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "601" }, "collection": "slc_mut", "batchSize": 5 }',
    $$ SELECT documentdb_api.insert_one('dyncur_slc_db', 'slc_mut', '{ "_id": 99, "k": 99 }') $$);

-- P2-9b: DELETE a not-yet-returned document (_id 12) mid-cursor after page 1.
SELECT slc_mut_reset();
SELECT slc_drain_mut('P2-9b delete-unreturned mid-cursor',
    '{ "find": "slc_mut", "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "601" }, "collection": "slc_mut", "batchSize": 5 }',
    $$ SELECT documentdb_api.delete('dyncur_slc_db', '{ "delete": "slc_mut", "deletes": [ { "q": { "_id": 12 }, "limit": 1 } ] }') $$);

-- P2-9c: DELETE an already-returned document (_id 3) mid-cursor after page 1 -
-- must not disturb the remaining window.
SELECT slc_mut_reset();
SELECT slc_drain_mut('P2-9c delete-returned mid-cursor',
    '{ "find": "slc_mut", "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "601" }, "collection": "slc_mut", "batchSize": 5 }',
    $$ SELECT documentdb_api.delete('dyncur_slc_db', '{ "delete": "slc_mut", "deletes": [ { "q": { "_id": 3 }, "limit": 1 } ] }') $$);

-- P2-9d: UPDATE a not-yet-returned document's non-_id field (_id 15) mid-cursor.
SELECT slc_mut_reset();
SELECT slc_drain_mut('P2-9d update-unreturned mid-cursor',
    '{ "find": "slc_mut", "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "601" }, "collection": "slc_mut", "batchSize": 5 }',
    $$ SELECT documentdb_api.update('dyncur_slc_db', '{ "update": "slc_mut", "updates": [ { "q": { "_id": 15 }, "u": { "$set": { "k": 1500 } } } ] }') $$);

SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_mut');

-- ---------------------------------------------------------------------------
-- P2-10: empty and boundary result sets. For a K-row window, a batch-size sweep
-- of [1, K-1, K, K+1] exercises maximum pagination and the sizes immediately
-- around an exact page fill. The exact ordered/counted window must be identical
-- at every size, and sizes below K must issue a continuation.
-- ---------------------------------------------------------------------------

-- P2-10 PK boundary: _id range [1,10] -> ids 1..10 (dc.type=2), sweep the boundary.
SELECT slc_ordered('P2-10a PK boundary [1..10]',
    '{ "find": "slc_coll", "filter": { "_id": { "$gte": 1, "$lte": 10 } }, "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,9,10,11],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,10) g),
    false, false, 2);

-- P2-10 secondary boundary: val range [1,10] -> ids 1..10, sweep boundary and
-- require a streaming secondary-index continuation (dc.type=3).
SELECT slc_ordered('P2-10b secondary boundary val[1..10]',
    '{ "find": "slc_coll", "filter": { "val": { "$gte": 1, "$lte": 10 } }, "sort": { "val": 1 }, "projection": { "_id": 1 }, "hint": "idx_val_asc", "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,9,10,11],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(1,10) g),
    false, false, 3);

-- P2-10 empty PK: filter matches nothing -> first page empty, getMore closes.
SELECT slc_count('P2-10c empty PK ({_id>100000})',
    '{ "find": "slc_coll", "filter": { "_id": { "$gt": 100000 } }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,5], 0::bigint);

-- P2-10 empty secondary: sorted, empty window.
SELECT slc_count('P2-10d empty secondary ({val>100000})',
    '{ "find": "slc_coll", "filter": { "val": { "$gt": 100000 } }, "sort": { "val": 1 }, "projection": { "_id": 1 }, "hint": "idx_val_asc", "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_coll", "batchSize": %s }',
    ARRAY[1,5], 0::bigint, false, false, 3);

-- P2-10 bitmap boundary + empty: BitmapAnd {x:5,y:3} = 14 docs (dc.type=5), and
-- an empty bitmap window. Force the bitmap paths as in SECTION P1.
SET enable_indexscan TO off;
SET enable_bitmapscan TO on;
SET enable_seqscan TO off;

SELECT slc_count('P2-10e bitmap-AND boundary {x:5,y:3}',
    '{ "find": "slc_bm", "filter": { "x": 5, "y": 3 }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_bm", "batchSize": %s }',
    ARRAY[1,13,14,15],
    (SELECT count(*) FROM generate_series(0,999) i WHERE i % 10 = 5 AND i % 7 = 3),
    false, false, 5);

SELECT slc_count('P2-10f empty bitmap ({x:5,y:99})',
    '{ "find": "slc_bm", "filter": { "x": 5, "y": 99 }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_bm", "batchSize": %s }',
    ARRAY[1,5], 0::bigint);

RESET enable_indexscan;
RESET enable_bitmapscan;
SET enable_seqscan TO off;

-- ---------------------------------------------------------------------------
-- P2-11: merge-sort / merge-append. An $in equality on the prefix column of a
-- composite {a:1,b:1} index, sorted by the suffix column b, produces one ordered
-- index scan per $in value merged by a MergeAppend so the sort is served by the
-- index instead of a blocking Sort. This drains that plan across a batch-size
-- sweep to catch any off-by-one at a MergeAppend boundary.
-- ---------------------------------------------------------------------------

-- slc_merge: 40 docs, a cycles 1..4 (a = ((i-1) % 4) + 1), b = _id = i. So
-- a in {1,3} selects the odd _ids 1..39, and sorting by b returns them in
-- ascending _id order (1,3,5,...,39).
SET documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_merge');
SELECT COUNT(documentdb_api.insert_one('dyncur_slc_db', 'slc_merge',
    FORMAT('{ "_id": %s, "a": %s, "b": %s }', i, ((i - 1) % 4) + 1, i)::documentdb_core.bson))
FROM generate_series(1, 40) AS i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_slc_db',
    '{ "createIndexes": "slc_merge", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }', true);
ANALYZE;
RESET documentdb.defaultUseCompositeOpClass;

-- Force the merge-sort-in-prefix rewrite and the index path.
SET documentdb.enable_merge_sort_for_in_prefix TO on;
SET documentdb.forceDisableSeqScan TO on;

-- P2-11: $in prefix + suffix sort -> MergeAppend of two ordered index scans,
-- drained across the sweep. Expected ordered window = odd _ids 1..39.
SELECT slc_ordered('P2-11 merge-append $in-prefix sort{b:1}',
    '{ "find": "slc_merge", "filter": { "a": { "$in": [ 1, 3 ] } }, "sort": { "b": 1 }, "projection": { "_id": 1 }, "batchSize": %s }',
    '{ "getMore": { "$numberLong": "600" }, "collection": "slc_merge", "batchSize": %s }',
    ARRAY[1,2,5,20,100],
    (SELECT string_agg(',' || g::text, '' ORDER BY g) FROM generate_series(0,19) i CROSS JOIN LATERAL (SELECT 2*i+1 AS g) t));

RESET documentdb.enable_merge_sort_for_in_prefix;
RESET documentdb.forceDisableSeqScan;
SET enable_seqscan TO off;

-- A broad _id range with a deep skip can retain only the shard-key index bound.
-- Two histogram endpoints make each broad _id predicate estimate 0.99.
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SET default_statistics_target TO 1;
SELECT COUNT(documentdb_api.insert_one('dyncur_slc_db', 'a',
    bson_build_document('_id'::text, i)))
FROM generate_series(10, 30009) AS i;
SET documentdb_core.enableBsonSelectivityFromBtreeStats TO on;
DO $$
DECLARE
    collection_id bigint;
    predicate text;
    plan jsonb;
BEGIN
    SELECT collections.collection_id INTO collection_id
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'dyncur_slc_db' AND collection_name = 'a';
    EXECUTE format(
        'CREATE STATISTICS documentdb_test_helpers.id_skip_selectivity ON (documentdb_api_internal.bson_stats_project(document, ''_id'')) FROM documentdb_data.documents_%s',
        collection_id);
    EXECUTE format('ANALYZE documentdb_data.documents_%s', collection_id);
    FOREACH predicate IN ARRAY ARRAY[
        $p$document @>= '{"_id":5}'::bson$p$,
        $p$object_id >= '{"":5}'::bson$p$,
        $p$object_id <= '{"":{"$numberDouble":"Infinity"}}'::bson$p$
    ]
    LOOP
        EXECUTE format(
            'EXPLAIN (FORMAT JSON) SELECT document FROM documentdb_data.documents_%s WHERE %s',
            collection_id, predicate) INTO plan;
        IF (plan->0->'Plan'->>'Plan Rows')::bigint IS DISTINCT FROM 29700 THEN
            RAISE EXCEPTION 'Expected 0.99 selectivity for %, estimated % rows',
                predicate, plan->0->'Plan'->>'Plan Rows';
        END IF;
        RAISE NOTICE 'selectivity of %: %', predicate,
            ((plan->0->'Plan'->>'Plan Rows')::numeric / 30000)::numeric(3, 2);
    END LOOP;
END;
$$;

SET enable_seqscan TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.enableOrderByIdOnCostFunction TO off;
SET documentdb.enable_order_by_id_on_cost_function_with_stats TO off;
SET documentdb.enable_btree_order_by_with_filters TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('dyncur_slc_db',
        '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
$cmd$);
SELECT document FROM bson_aggregation_find('dyncur_slc_db',
    '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }');
SET documentdb.enable_btree_order_by_with_filters TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('dyncur_slc_db',
        '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
$cmd$);
SELECT document FROM bson_aggregation_find('dyncur_slc_db',
    '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }');
SET documentdb.enable_btree_order_by_with_filters TO off;
SET documentdb.enable_order_by_id_on_cost_function_with_stats TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('dyncur_slc_db',
        '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
$cmd$);
SELECT document FROM bson_aggregation_find('dyncur_slc_db',
    '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }');
SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;
SET documentdb.enable_order_by_id_on_cost_function_with_stats TO off;
SET documentdb.enable_btree_order_by_with_filters TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('dyncur_slc_db',
        '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
$cmd$);
SELECT document FROM bson_aggregation_find('dyncur_slc_db',
    '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }');
SET documentdb.enable_btree_order_by_with_filters TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('dyncur_slc_db',
        '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
$cmd$);
SELECT document FROM bson_aggregation_find('dyncur_slc_db',
    '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }');
SET documentdb.enable_btree_order_by_with_filters TO off;
SET documentdb.enable_order_by_id_on_cost_function_with_stats TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('dyncur_slc_db',
        '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
$cmd$);
SELECT document FROM bson_aggregation_find('dyncur_slc_db',
    '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }');
DROP STATISTICS documentdb_test_helpers.id_skip_selectivity;
SET documentdb.enableCompositeIndexPlanner TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('dyncur_slc_db',
        '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
$cmd$);
SET documentdb_core.enableBsonSelectivityFromBtreeStats TO off;
SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;
DO $$
DECLARE
    collection_oid oid;
    plan_with_flag jsonb;
    plan_without_flag jsonb;
    query text := $query$
        EXPLAIN (FORMAT JSON, COSTS OFF)
        SELECT document FROM bson_aggregation_find('dyncur_slc_db',
            '{ "find": "a", "filter": { "_id": { "$gte": 5 } }, "skip": 23000, "limit": 1, "sort": { "_id": 1 } }')
    $query$;
BEGIN
    SELECT format('documentdb_data.documents_%s', collection_id)::regclass
    INTO collection_oid
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'dyncur_slc_db' AND collection_name = 'a';
    IF EXISTS (SELECT FROM pg_statistic_ext WHERE stxrelid = collection_oid) THEN
        RAISE EXCEPTION 'Expected no collection statistics';
    END IF;
    PERFORM set_config('documentdb.enable_order_by_id_on_cost_function_with_stats', 'off', true);
    EXECUTE query INTO plan_without_flag;
    PERFORM set_config('documentdb.enable_order_by_id_on_cost_function_with_stats', 'on', true);
    EXECUTE query INTO plan_with_flag;
    IF plan_with_flag IS DISTINCT FROM plan_without_flag THEN
        RAISE EXCEPTION 'Statistics-only ordering changed the plan without statistics';
    END IF;
    RAISE NOTICE 'Composite planner alone does not enable statistics-only ordering';
END;
$$;
RESET documentdb.enableCompositeIndexPlanner;
RESET documentdb.enable_btree_order_by_with_filters;
RESET documentdb.enable_order_by_id_on_cost_function_with_stats;
RESET documentdb.enableOrderByIdOnCostFunction;
RESET documentdb.enableCursorsOnAggregationQueryRewrite;
RESET documentdb.enableExplainScanIndexCosts;
RESET documentdb.enableExtendedExplainPlans;
SET enable_seqscan TO off;
RESET documentdb_core.enableBsonSelectivityFromBtreeStats;
RESET default_statistics_target;
RESET documentdb.enablePerCollectionPlannerStatistics;
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'a');

-- ===========================================================================
-- Cleanup
-- ===========================================================================
RESET documentdb.enable_dynamic_cursor_with_skiplimit;
DROP FUNCTION IF EXISTS slc_ordered(text, text, text, int[], text, bool, bool, int);
DROP FUNCTION IF EXISTS slc_count(text, text, text, int[], bigint, bool, bool, int);
DROP FUNCTION IF EXISTS slc_drain(text, text);
DROP FUNCTION IF EXISTS slc_drain_agg(text, text);
DROP FUNCTION IF EXISTS slc_drain_mut(text, text, text, text);
DROP FUNCTION IF EXISTS slc_mut_reset();
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_coll');
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_noidx');
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_pk');
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_bm');
SELECT documentdb_api.drop_collection('dyncur_slc_db', 'slc_merge');
