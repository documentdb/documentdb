-- Tests for dynamic cursor behavior with index scans: validates that streaming
-- cursors are used for simple ordered index scans with filters, and that
-- skip or limit causes a fallback to persistent cursors.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 9800;
SET documentdb.next_collection_index_id TO 9800;

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;
SET enable_seqscan TO off;

-- ===========================================================================
-- Data setup: 20 documents with a secondary index on "val" for ordered scans
-- ===========================================================================
SELECT documentdb_api.drop_collection('dyncur_sp_db', 'sp_coll');

SELECT COUNT(documentdb_api.insert_one('dyncur_sp_db', 'sp_coll',
    FORMAT('{ "_id": %s, "val": %s, "cat": "%s", "tag": %s }',
           i, i * 10, CASE WHEN i % 2 = 0 THEN 'even' ELSE 'odd' END, i % 5
    )::documentdb_core.bson))
FROM generate_series(1, 20) AS i;

-- Create a compound index on val (ascending) for ordered index scans
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_coll", "indexes": [{"key": {"val": 1}, "name": "idx_val_asc"}]}', true);

-- Create a compound index on (cat, val) for filtered ordered scans
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_coll", "indexes": [{"key": {"cat": 1, "val": 1}, "name": "idx_cat_val"}]}', true);

-- Create a descending index on val
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_coll", "indexes": [{"key": {"val": -1}, "name": "idx_val_desc"}]}', true);

ANALYZE;

-- ===========================================================================
-- Helper: drain all pages and report batch sizes + cursor type from continuation
-- ===========================================================================
CREATE OR REPLACE FUNCTION sp_drain_and_report(
    p_find_spec text,
    p_getmore_spec text,
    p_batch_size int,
    p_expected_cursor_type int DEFAULT 3
) RETURNS TABLE(page_num int, batch_count bigint, cursor_type int, persist_conn bool) AS $$
DECLARE
    v_cursor_page documentdb_core.bson;
    v_continuation documentdb_core.bson;
    v_persist bool;
    v_batch_count bigint;
    v_cursor_type int;
    v_page int := 1;
BEGIN
    -- First page
    SELECT fp.cursorPage, fp.continuation, fp.persistconnection
    INTO v_cursor_page, v_continuation, v_persist
    FROM find_cursor_first_page(
        database => 'dyncur_sp_db',
        commandSpec => p_find_spec::documentdb_core.bson,
        cursorId => 538
    ) fp;

    SELECT (bson_dollar_project(v_cursor_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }')
        ->> 'c')::bigint INTO v_batch_count;

    IF v_continuation IS NOT NULL THEN
        SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO v_cursor_type;

        -- For streaming cursors, validate dc.type is set and matches expected
        IF NOT v_persist THEN
            IF v_cursor_type IS NULL THEN
                RAISE EXCEPTION 'Page 1: streaming cursor but dc.type is NULL';
            END IF;
            IF v_cursor_type != p_expected_cursor_type THEN
                RAISE EXCEPTION 'Page 1: expected dc.type=%, got dc.type=%', p_expected_cursor_type, v_cursor_type;
            END IF;
        END IF;
    ELSE
        v_cursor_type := -1;
    END IF;

    page_num := v_page; batch_count := v_batch_count;
    cursor_type := v_cursor_type; persist_conn := v_persist;
    RETURN NEXT;

    -- Iterate getMore
    WHILE v_continuation IS NOT NULL LOOP
        v_page := v_page + 1;
        SELECT gm.cursorPage, gm.continuation
        INTO v_cursor_page, v_continuation
        FROM cursor_get_more(
            database => 'dyncur_sp_db',
            getMoreSpec => p_getmore_spec::documentdb_core.bson,
            continuationSpec => v_continuation
        ) gm;

        SELECT (bson_dollar_project(v_cursor_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
            ->> 'c')::bigint INTO v_batch_count;

        IF v_continuation IS NOT NULL THEN
            SELECT (bson_dollar_project(v_continuation, '{ "dc.type": 1 }') ->> 'dc.type')::int
                INTO v_cursor_type;

            -- For streaming cursors, validate dc.type is set and matches expected
            IF NOT v_persist THEN
                IF v_cursor_type IS NULL THEN
                    RAISE EXCEPTION 'Page %: streaming cursor but dc.type is NULL', v_page;
                END IF;
                IF v_cursor_type != p_expected_cursor_type THEN
                    RAISE EXCEPTION 'Page %: expected dc.type=%, got dc.type=%', v_page, p_expected_cursor_type, v_cursor_type;
                END IF;
            END IF;
        ELSE
            v_cursor_type := -1;
        END IF;

        page_num := v_page; batch_count := v_batch_count;
        cursor_type := v_cursor_type; persist_conn := v_persist;
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ===========================================================================
-- SECTION A: Cursors with sort and/or filter (no skip/limit)
-- With enableOrderedIndex (default on in extended_rum_tests), sort queries
-- that match the index order produce streaming cursors. Filter-only queries
-- also produce streaming cursors.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test A1: Simple ordered index scan with sort matching index
-- sort: { val: 1 } with idx_val_asc → streaming (index serves sort)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test A2: Descending sort matching descending index
-- sort: { val: -1 } with idx_val_desc → streaming (index serves sort)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": -1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test A3: Filter + sort on compound index
-- filter: { cat: "even" }, sort: { val: 1 } on idx_cat_val
-- 10 "even" docs, batchSize=3 should produce 4 pages (3+3+3+1)
-- Equality filter on prefix + sort on next key → streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "filter": { "cat": "even" }, "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 3, "hint": "idx_cat_val" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test A4: Filter only, no explicit sort - dynamic streaming cursor
-- filter: { val: { $gte: 50, $lte: 150 } }
-- vals 50..150 by 10s => docs with val 50,60,70,80,90,100,110,120,130,140,150 (11 docs)
-- Streaming cursor (cursor_type=3, persist_conn=f) - this is correct
-- behavior: no sort clause, filter servable by index.
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "filter": { "val": { "$gte": 50, "$lte": 150 } }, "projection": { "_id": 1, "val": 1 }, "batchSize": 4 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 4 }',
    4);

-- ===========================================================================
-- SECTION B: Cursors with skip or limit
-- Skip and limit force persistent cursors (the planner wraps the scan with
-- Limit/Offset nodes, preventing streaming). This applies regardless of
-- whether the sort matches the index.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test B1: sort + limit - persistent cursor (limit wraps scan node)
-- limit: 10 with batchSize: 3
-- OBSERVATION: persistent cursor - limit node wraps the custom scan
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "limit": 10, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test B2: sort + skip - persistent cursor
-- skip: 5, batchSize: 3
-- OBSERVATION: persistent cursor, 15 docs returned (20 - 5 skipped)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 5, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test B3: sort + skip + limit - persistent cursor
-- skip: 3, limit: 7, batchSize: 2
-- OBSERVATION: persistent cursor, 7 docs returned (docs 4-10 by val order)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 3, "limit": 7, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test B4: sort + skip=0 behaves same as sort only (persistent cursor)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 0, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test B5: sort + limit >= total docs - still persistent
-- limit: 100 with only 20 docs
-- OBSERVATION: persistent cursor even though limit exceeds row count
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "limit": 100, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 5 }',
    5);

-- ===========================================================================
-- SECTION C: Filter + sort + skip/limit combinations on compound index
-- All produce persistent cursors because sort is present.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test C1: Filter + sort + limit on compound index
-- filter: { cat: "odd" }, sort: { val: 1 }, limit: 5, batchSize: 2
-- 10 "odd" docs, limited to 5 => persistent cursor
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "filter": { "cat": "odd" }, "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "limit": 5, "batchSize": 2, "hint": "idx_cat_val" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test C2: Filter + sort + skip on compound index
-- filter: { cat: "even" }, sort: { val: 1 }, skip: 3, batchSize: 2
-- 10 "even" docs, skip 3 => 7 docs, persistent cursor
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "filter": { "cat": "even" }, "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 3, "batchSize": 2, "hint": "idx_cat_val" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test C3: Filter + sort + skip + limit on compound index
-- filter: { cat: "even" }, sort: { val: 1 }, skip: 2, limit: 4, batchSize: 2
-- 10 "even" docs, skip 2, take 4 => 4 docs, persistent cursor
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "filter": { "cat": "even" }, "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 2, "limit": 4, "batchSize": 2, "hint": "idx_cat_val" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 2 }',
    2);

-- ===========================================================================
-- SECTION D: EXPLAIN verification of plan shapes
-- Verifies which plan nodes are used for streaming vs persistent cursors
-- ===========================================================================

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ---------------------------------------------------------------------------
-- Test D1: EXPLAIN for streaming cursor (no skip/limit)
-- Should show DocumentDBApiCursorScan wrapping an index scan
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test D2: EXPLAIN for cursor with limit
-- The limit should cause the planner to produce a Limit node which prevents
-- the dynamic cursor scan from streaming
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "limit": 10, "batchSize": 5 }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test D3: EXPLAIN for cursor with skip
-- The skip should cause the planner to produce an Offset node
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 5, "batchSize": 5 }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test D4: EXPLAIN for cursor with skip + limit
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 3, "limit": 7, "batchSize": 5 }');
$cmd$);

-- ---------------------------------------------------------------------------
-- Test D5: EXPLAIN for filtered streaming cursor (no skip/limit)
-- filter on compound index should still allow streaming
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_coll", "filter": { "cat": "even" }, "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 3, "hint": "idx_cat_val" }');
$cmd$);

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- SECTION E: Data correctness verification
-- Validates that the actual documents returned are correct, not just counts
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test E1: Streaming cursor returns correct ordered results
-- sort: { val: 1 }, no skip/limit - verify first batch contains docs with
-- lowest val values in ascending order
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE sp_first_page_response AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.firstBatch.val": 1, "cursor.id": 1 }') as cp,
       continuation, persistconnection, cursorid
FROM find_cursor_first_page(database => 'dyncur_sp_db',
    commandSpec => '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    cursorId => 538);

SELECT cp, persistconnection FROM sp_first_page_response;

SELECT continuation AS r1_continuation FROM sp_first_page_response \gset

-- getMore should return next 5 docs
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.nextBatch.val": 1, "cursor.id": 1 }'),
       continuation IS NOT NULL as has_more
FROM cursor_get_more(database => 'dyncur_sp_db',
    getMoreSpec => '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 5 }',
    continuationSpec => :'r1_continuation');

DROP TABLE sp_first_page_response;

-- ---------------------------------------------------------------------------
-- Test E2: Persistent cursor with skip returns correct offset results
-- skip: 5, sort: { val: 1 } - first batch should start from val=60 (6th doc)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE sp_skip_response AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.firstBatch.val": 1, "cursor.id": 1 }') as cp,
       continuation, persistconnection, cursorid
FROM find_cursor_first_page(database => 'dyncur_sp_db',
    commandSpec => '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 5, "batchSize": 3 }',
    cursorId => 538);

-- persistconnection should be true for persistent cursor
SELECT cp, persistconnection FROM sp_skip_response;

DROP TABLE sp_skip_response;

-- ---------------------------------------------------------------------------
-- Test E3: Persistent cursor with limit returns correct count
-- limit: 7, sort: { val: 1 }, batchSize: 3
-- Should return exactly 7 docs total across all batches
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_coll", "sort": { "val": 1 }, "projection": { "_id": 1, "val": 1 }, "limit": 7, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_coll", "batchSize": 3 }',
    3);

-- ===========================================================================
-- SECTION F: Streaming sort with dynamic cursors — sort-index matching
--
-- This section tests whether the dynamic cursor planner correctly identifies
-- when a sort can be fully served by an index (→ streaming) vs when it cannot
-- (→ persistent). Indexes are created with enableOrderedIndex: true which is
-- required for ordered index scans.
--
-- ┌─────┬──────────────────────────────────────────────────────────┬───────────┬───────────┐
-- │ Test│ Scenario                                                 │ Expected  │ Correct?  │
-- ├─────┼──────────────────────────────────────────────────────────┼───────────┼───────────┤
-- │ F1  │ sort {a:1} on idx {a:1,b:1,c:1} (prefix, 1<3 keys)     │ streaming │ see below │
-- │ F2  │ sort {a:1,b:1} on idx {a:1,b:1,c:1} (prefix, 2<3)      │ streaming │ see below │
-- │ F3  │ sort {a:1,b:1,c:1} on idx {a:1,b:1,c:1} (exact, 3==3)  │ streaming │ see below │
-- │ F4  │ sort {a:1,b:1,c:1,d:1} on idx (extra key, 4>3)         │ persistent│ see below │
-- │ F5  │ sort {x:1} on idx {a:1,b:1,c:1} (no match)             │ persistent│ see below │
-- │ F6  │ sort {b:1} on idx {a:1,b:1,c:1} (non-prefix)           │ persistent│ see below │
-- │ F7  │ filter {a $in [1,2,3]} + sort {b:1} (not servable)      │ persistent│ see below │
-- │ F8  │ filter {a:1} + sort {b:1} (equality+next key, servable) │ streaming │ see below │
-- │ F9  │ filter {a >= 1} + sort {b:1} (range+next key)           │ persistent│ see below │
-- │ F10 │ filter only {a:1, b > 0} no sort (streaming baseline)   │ streaming │ see below │
-- │ F11 │ sort {a:1} only, no filter (just sort, ordered index)   │ streaming │ see below │
-- │ F12 │ sort {a:1,b:1,c:1} only, no filter (full match)        │ streaming │ see below │
-- │ F13 │ sort {a:-1} on idx {a:1,b:1,c:1} (backward prefix)     │ streaming │ see below │
-- │ F14 │ sort {a:1,b:-1} on idx {a:1,b:1,c:1} (direction mismatch)│persistent│ see below │
-- │ F15 │ sort {a:1} on single-key idx {a:1} (exact single)       │ streaming │ see below │
-- └─────┴──────────────────────────────────────────────────────────┴───────────┴───────────┘
-- ===========================================================================

-- New collection with richer fields for sort/index matching tests
SELECT documentdb_api.drop_collection('dyncur_sp_db', 'sp_sort_coll');

SELECT COUNT(documentdb_api.insert_one('dyncur_sp_db', 'sp_sort_coll',
    FORMAT('{ "_id": %s, "a": %s, "b": %s, "c": %s, "d": %s, "x": %s }',
           i, i % 4, i % 5, i % 3, i * 2, i % 7
    )::documentdb_core.bson))
FROM generate_series(1, 30) AS i;

-- Compound index on (a, b, c) - 3 paths (enableOrderedIndex is default on in extended_rum)
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_sort_coll", "indexes": [{"key": {"a": 1, "b": 1, "c": 1}, "name": "idx_abc"}]}', true);

-- Single-key index on (a)
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_sort_coll", "indexes": [{"key": {"a": 1}, "name": "idx_a_only"}]}', true);

ANALYZE;

-- ---------------------------------------------------------------------------
-- Test F1: sortKeys < numPathsOfIndex (1 sort key, 3-path index)
-- sort: { a: 1 }, hint: idx_abc
-- Prefix sort matches index prefix → should be streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F2: sortKeys < numPathsOfIndex (2 sort keys, 3-path index)
-- sort: { a: 1, b: 1 }, hint: idx_abc
-- Prefix sort matches index prefix → should be streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1, "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F3: sortKeys == numPathsOfIndex (3 sort keys, 3-path index)
-- sort: { a: 1, b: 1, c: 1 }, hint: idx_abc
-- Full sort matches index exactly → should be streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1, "b": 1, "c": 1 }, "projection": { "_id": 1, "a": 1, "b": 1, "c": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F4: sortKeys > numPathsOnIndex (4 sort keys, 3-path index)
-- sort: { a: 1, b: 1, c: 1, d: 1 }, hint: idx_abc
-- Extra sort key "d" not in index → persistent is correct (index cannot
-- fully satisfy the sort order)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1, "b": 1, "c": 1, "d": 1 }, "projection": { "_id": 1, "a": 1, "b": 1, "c": 1, "d": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F5: sortKeys has paths that don't match index at all
-- sort: { x: 1 }, hint: idx_abc
-- Sort on "x" which is not in the index → persistent is correct
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "x": 1 }, "projection": { "_id": 1, "x": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F6: sortKeys partial match but not prefix
-- sort: { b: 1 }, hint: idx_abc
-- "b" is in the index but is not the first key → persistent is correct
-- (non-prefix sort cannot use index ordering)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "b": 1 }, "projection": { "_id": 1, "b": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F7: filter + sort not servable by index
-- filter: { a: { $in: [1, 2, 3] } }, sort: { b: 1 }, hint: idx_abc
-- The $in on "a" produces multiple ranges; sorting by "b" across those
-- ranges cannot be served by the index alone → persistent is correct
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "filter": { "a": { "$in": [1, 2, 3] } }, "sort": { "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F8: filter equality on prefix + sort on next key (servable)
-- filter: { a: 1 }, sort: { b: 1 }, hint: idx_abc
-- Equality on "a" + sort on "b" is fully servable by idx_abc → should stream
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "filter": { "a": 1 }, "sort": { "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test F9: filter range on prefix + sort on next key (not fully servable)
-- filter: { a: { $gte: 1 } }, sort: { b: 1 }, hint: idx_abc
-- Range on "a" means multiple "a" values; sorting by "b" across them
-- cannot use index order → persistent is correct
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "filter": { "a": { "$gte": 1 } }, "sort": { "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F10: filter only (no sort) on compound index prefix → streaming
-- filter: { a: 1, b: { $gt: 0 } }, hint: idx_abc
-- No sort, filter fully servable by index → streaming is correct
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "filter": { "a": 1, "b": { "$gt": 0 } }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test F11: sort only, no filter - single prefix key on ordered compound index
-- sort: { a: 1 }, NO filter, hint: idx_abc
-- Pure sort with no filter on an ordered index → should be streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F12: sort only, no filter - full match on all index keys
-- sort: { a: 1, b: 1, c: 1 }, NO filter, hint: idx_abc
-- Pure sort matching all index paths → should be streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1, "b": 1, "c": 1 }, "projection": { "_id": 1, "a": 1, "b": 1, "c": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F13: backward scan - descending sort on ascending index prefix
-- sort: { a: -1 }, hint: idx_abc
-- RUM indexes support backward scan for descending sort on ascending index
-- → should be streaming (backward index scan)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": -1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F14: mixed sort directions that don't match index
-- sort: { a: 1, b: -1 }, hint: idx_abc (index is {a:1, b:1, c:1})
-- Direction mismatch on "b" (sort DESC, index ASC) → persistent is correct
-- (cannot serve mixed direction unless index matches exactly or fully reversed)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1, "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 5, "hint": "idx_abc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test F15: sort on single-key index (exact match, 1 == 1 path)
-- sort: { a: 1 }, hint: idx_a_only
-- Single-key ordered index, sort matches exactly → should be streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_sort_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5, "hint": "idx_a_only" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_sort_coll", "batchSize": 5 }',
    5);

-- ===========================================================================
-- SECTION F RESULTS SUMMARY
-- ===========================================================================
-- Index: idx_abc = {a:1, b:1, c:1}, idx_a_only = {a:1}
-- enableOrderedIndex is default on in extended_rum_tests
--
-- | Test | Sort          | Filter       | Index    | Expected    | Actual      | Correct? |
-- |------|---------------|--------------|----------|-------------|-------------|----------|
-- | F1   | {a:1}         | -            | idx_abc  | streaming   | streaming   | YES      |
-- | F2   | {a:1,b:1}    | -            | idx_abc  | streaming   | streaming   | YES      |
-- | F3   | {a:1,b:1,c:1}| -            | idx_abc  | streaming   | streaming   | YES      |
-- | F4   | {a:1,b:1,c:1,d:1}| -        | idx_abc  | persistent  | persistent  | YES      |
-- | F5   | {x:1}        | -            | idx_abc  | persistent  | persistent  | YES      |
-- | F6   | {b:1}        | -            | idx_abc  | persistent  | persistent  | YES      |
-- | F7   | {b:1}        | a $in [1,2,3]| idx_abc  | persistent  | persistent  | YES      |
-- | F8   | {b:1}        | a = 1        | idx_abc  | streaming   | streaming   | YES      |
-- | F9   | {b:1}        | a >= 1       | idx_abc  | persistent  | persistent  | YES      |
-- | F10  | -            | a=1,b>0      | idx_abc  | streaming   | streaming   | YES      |
-- | F11  | {a:1}        | -            | idx_abc  | streaming   | streaming   | YES      |
-- | F12  | {a:1,b:1,c:1}| -            | idx_abc  | streaming   | streaming   | YES      |
-- | F13  | {a:-1}       | -            | idx_abc  | streaming   | streaming   | YES      |
-- | F14  | {a:1,b:-1}   | -            | idx_abc  | persistent  | persistent  | YES      |
-- | F15  | {a:1}        | -            | idx_a_only| streaming  | streaming   | YES      |
--
-- All sort-index streaming scenarios are working correctly with ordered indexes.
-- Key contract verified:
--   - Prefix sort ≤ index keys → streaming
--   - Sort > index keys or non-matching → persistent
--   - Backward scan (reversed direction on all keys) → streaming
--   - Mixed directions (partial reversal) → persistent
--   - Equality filter + next-key sort → streaming
--   - Range/$in filter + non-prefix sort → persistent
-- ===========================================================================

-- ===========================================================================
-- SECTION F EXPLAIN: Plan shapes for sort-index matching scenarios
-- ===========================================================================

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- Test F1 EXPLAIN: partial prefix sort (1 of 3 keys)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_sort_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5, "hint": "idx_abc" }');
$cmd$);

-- Test F4 EXPLAIN: sort keys > index paths — verify a Sort node wraps the scan
-- (PG16+ uses Incremental Sort; PG15 uses full Sort — just check top node)
-- Also verify no DocumentDBApiCursorScan (persistent cursor, not streaming)
SELECT
    (array_agg(run_explain_and_trim))[1] LIKE '%Sort%' AS has_sort_node,
    count(*) FILTER (WHERE run_explain_and_trim LIKE '%DocumentDBApiCursorScan%') = 0 AS no_cursor_scan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_sort_coll", "sort": { "a": 1, "b": 1, "c": 1, "d": 1 }, "projection": { "_id": 1, "a": 1, "b": 1, "c": 1, "d": 1 }, "batchSize": 5, "hint": "idx_abc" }');
$cmd$);

-- Test F7 EXPLAIN: $in filter + non-prefix sort
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_sort_coll", "filter": { "a": { "$in": [1, 2, 3] } }, "sort": { "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 5, "hint": "idx_abc" }');
$cmd$);

-- Test F8 EXPLAIN: equality filter + next-key sort (servable)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_sort_coll", "filter": { "a": 1 }, "sort": { "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_abc" }');
$cmd$);

-- Test F11 EXPLAIN: sort only, no filter (pure ordered scan)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_sort_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5, "hint": "idx_abc" }');
$cmd$);

-- Test F13 EXPLAIN: backward scan (descending sort on ascending index)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_sort_coll", "sort": { "a": -1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5, "hint": "idx_abc" }');
$cmd$);

-- Test F15 EXPLAIN: sort on single-key index
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_sort_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 5, "hint": "idx_a_only" }');
$cmd$);

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- SECTION G: Sort correctness — validate documents returned in correct order
-- Tests use a dedicated collection with controlled data to verify ordering
-- across batches for streaming cursors with various index/sort combinations.
-- ===========================================================================

-- Create collection with predictable data for sort validation
SELECT documentdb_api.drop_collection('dyncur_sp_db', 'sp_order_coll');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 1, "a": 3, "b": 2, "c": 10 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 2, "a": 1, "b": 5, "c": 30 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 3, "a": 2, "b": 1, "c": 20 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 4, "a": 1, "b": 3, "c": 50 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 5, "a": 3, "b": 4, "c": 40 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 6, "a": 2, "b": 2, "c": 60 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 7, "a": 1, "b": 1, "c": 70 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 8, "a": 3, "b": 3, "c": 80 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 9, "a": 2, "b": 5, "c": 90 }');
SELECT documentdb_api.insert_one('dyncur_sp_db', 'sp_order_coll', '{ "_id": 10, "a": 1, "b": 4, "c": 100 }');

-- Ascending single-key index
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_order_coll", "indexes": [{"key": {"a": 1}, "name": "idx_order_a_asc"}]}', true);

-- Descending single-key index
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_order_coll", "indexes": [{"key": {"a": -1}, "name": "idx_order_a_desc"}]}', true);

-- Composite ascending index
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_order_coll", "indexes": [{"key": {"a": 1, "b": 1}, "name": "idx_order_ab_asc"}]}', true);

-- Mixed direction composite index
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_sp_db',
    '{"createIndexes": "sp_order_coll", "indexes": [{"key": {"a": 1, "b": -1}, "name": "idx_order_a_asc_b_desc"}]}', true);

ANALYZE;

-- Helper: drain cursor and return projected docs from all pages in order
CREATE OR REPLACE FUNCTION sp_drain_ordered(
    p_find text, p_getmore text, p_batch_size int
) RETURNS TABLE(page_num int, docs documentdb_core.bson) AS $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_cid bigint;
    v_page_num int := 0;
    v_cursor_type int;
BEGIN
    SELECT fp.cursorPage, fp.continuation, fp.persistconnection, fp.cursorid
    INTO v_page, v_cont, v_persist, v_cid
    FROM find_cursor_first_page(database => 'dyncur_sp_db',
        commandSpec => p_find::documentdb_core.bson, cursorId => 538) fp;

    IF v_persist THEN
        RAISE EXCEPTION 'Expected streaming cursor (persistconnection=false) on first page, got persistent';
    END IF;

    v_page_num := 1;
    page_num := v_page_num;
    docs := bson_dollar_project(v_page, '{ "cursor.firstBatch._id": 1, "cursor.firstBatch.a": 1, "cursor.firstBatch.b": 1 }');
    RETURN NEXT;

    WHILE v_cont IS NOT NULL LOOP
        -- Verify continuation has dc.type set (streaming indicator)
        SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO v_cursor_type;
        IF v_cursor_type IS NULL THEN
            RAISE EXCEPTION 'Expected streaming continuation (dc.type set) on page %, got persistent (dc.type is NULL)', v_page_num + 1;
        END IF;
        IF v_cursor_type NOT IN (3, 7) THEN
            RAISE EXCEPTION 'Expected cursor_type 3 (SecondaryIndexScan) or 7 (SecondaryIndexOnlyScan) on page %, got %', v_page_num + 1, v_cursor_type;
        END IF;

        SELECT gm.cursorPage, gm.continuation
        INTO v_page, v_cont
        FROM cursor_get_more(database => 'dyncur_sp_db',
            getMoreSpec => p_getmore::documentdb_core.bson,
            continuationSpec => v_cont) gm;

        v_page_num := v_page_num + 1;
        page_num := v_page_num;
        docs := bson_dollar_project(v_page, '{ "cursor.nextBatch._id": 1, "cursor.nextBatch.a": 1, "cursor.nextBatch.b": 1 }');
        RETURN NEXT;

        IF v_cont IS NULL THEN
            EXIT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ---------------------------------------------------------------------------
-- Test G1: Ascending sort on single-key ASC index (no filter)
-- sort: { a: 1 }, hint: idx_order_a_asc
-- Expected order: a=1 (ids 2,4,7,10), a=2 (ids 3,6,9), a=3 (ids 1,5,8)
-- Within same "a" value, order is by _id (secondary sort from index)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G2: Descending sort on single-key DESC index (no filter)
-- sort: { a: -1 }, hint: idx_order_a_desc
-- Expected order: a=3 (ids 1,5,8), a=2 (ids 3,6,9), a=1 (ids 2,4,7,10)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G3: Descending sort on single-key ASC index (backward scan, no filter)
-- sort: { a: -1 }, hint: idx_order_a_asc
-- Should produce same ordering as G2 (backward scan on ascending index)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G4: Composite ascending sort on composite ASC index (no filter)
-- sort: { a: 1, b: 1 }, hint: idx_order_ab_asc
-- Expected: (a=1,b=1,id=7), (a=1,b=3,id=4), (a=1,b=4,id=10), (a=1,b=5,id=2),
--           (a=2,b=1,id=3), (a=2,b=2,id=6), (a=2,b=5,id=9),
--           (a=3,b=2,id=1), (a=3,b=3,id=8), (a=3,b=4,id=5)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": 1, "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G5: Mixed direction sort on mixed direction index (no filter)
-- sort: { a: 1, b: -1 }, hint: idx_order_a_asc_b_desc
-- Expected: (a=1,b=5,id=2), (a=1,b=4,id=10), (a=1,b=3,id=4), (a=1,b=1,id=7),
--           (a=2,b=5,id=9), (a=2,b=2,id=6), (a=2,b=1,id=3),
--           (a=3,b=4,id=5), (a=3,b=3,id=8), (a=3,b=2,id=1)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": 1, "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_asc_b_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G6: Single-key ascending sort WITH filter (no filter on sort key)
-- filter: { a: { $lte: 2 } }, sort: { a: 1 }, hint: idx_order_a_asc
-- Expected: a=1 docs (ids 2,4,7,10), then a=2 docs (ids 3,6,9) = 7 docs total
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "filter": { "a": { "$lte": 2 } }, "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1 }, "batchSize": 3, "hint": "idx_order_a_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G7: Composite sort with equality filter on prefix
-- filter: { a: 2 }, sort: { b: 1 }, hint: idx_order_ab_asc
-- Only a=2 docs: (b=1,id=3), (b=2,id=6), (b=5,id=9) = 3 docs in b-order
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "filter": { "a": 2 }, "sort": { "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 2, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test G8: Mixed direction index with equality filter + desc sort
-- filter: { a: 3 }, sort: { b: -1 }, hint: idx_order_a_asc_b_desc
-- Only a=3 docs: (b=4,id=5), (b=3,id=8), (b=2,id=1) = 3 docs in b-desc order
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "filter": { "a": 3 }, "sort": { "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 2, "hint": "idx_order_a_asc_b_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test G9: Full backward scan on composite ascending index (reverse all dirs)
-- sort: { a: -1, b: -1 }, hint: idx_order_ab_asc
-- Expected: (a=3,b=4,id=5), (a=3,b=3,id=8), (a=3,b=2,id=1),
--           (a=2,b=5,id=9), (a=2,b=2,id=6), (a=2,b=1,id=3),
--           (a=1,b=5,id=2), (a=1,b=4,id=10), (a=1,b=3,id=4), (a=1,b=1,id=7)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": -1, "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 4, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 4 }',
    4);

-- ---------------------------------------------------------------------------
-- Test G10: Verify all 10 documents are returned (count check)
-- sort: { a: 1, b: 1 }, hint: idx_order_ab_asc, batchSize: 2
-- Must return exactly 10 docs across multiple batches
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS total_pages FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": 1, "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 2, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test G11: Verify filtered count - filter: { a: 1 }, sort: { b: -1 }
-- idx_order_a_asc_b_desc, 4 docs where a=1, batchSize: 2
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS total_pages FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "filter": { "a": 1 }, "sort": { "b": -1 }, "projection": { "_id": 1 }, "batchSize": 2, "hint": "idx_order_a_asc_b_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test G12: Backward scan correctness — reversed mixed-direction index
-- sort: { a: -1, b: 1 }, hint: idx_order_a_asc_b_desc (index is {a:1,b:-1})
-- Full reverse of all index directions → backward scan → streaming
-- Expected: (a=3,b=2,id=1), (a=3,b=3,id=8), (a=3,b=4,id=5),
--           (a=2,b=1,id=3), (a=2,b=2,id=6), (a=2,b=5,id=9),
--           (a=1,b=1,id=7), (a=1,b=3,id=4), (a=1,b=4,id=10), (a=1,b=5,id=2)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": -1, "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_asc_b_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G13: Backward scan correctness — ascending sort on descending index
-- sort: { a: 1 }, hint: idx_order_a_desc (index is {a:-1})
-- Ascending sort on descending index → backward scan → streaming
-- Expected: a=1 (ids 2,4,7,10), a=2 (ids 3,6,9), a=3 (ids 1,5,8)
-- Same order as G1 (ascending sort on ascending index)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G14: Backward scan correctness — compound ASC index with filter
-- filter: { a: { $lte: 2 } }, sort: { a: -1, b: -1 }, hint: idx_order_ab_asc
-- Full reverse of {a:1,b:1} with range filter → backward scan → streaming
-- Expected: (a=2,b=5,id=9), (a=2,b=2,id=6), (a=2,b=1,id=3),
--           (a=1,b=5,id=2), (a=1,b=4,id=10), (a=1,b=3,id=4), (a=1,b=1,id=7)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "filter": { "a": { "$lte": 2 } }, "sort": { "a": -1, "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test G15: Backward scan correctness — equality filter + reversed next-key
-- filter: { a: 2 }, sort: { b: -1 }, hint: idx_order_ab_asc
-- Equality on prefix + descending sort on next key (reverse of {b:1})
-- → backward scan within equality range → streaming
-- Expected: (a=2,b=5,id=9), (a=2,b=2,id=6), (a=2,b=1,id=3)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "filter": { "a": 2 }, "sort": { "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 2, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test G16: Backward scan correctness — equality filter + reversed next-key
--           on mixed-direction index
-- filter: { a: 1 }, sort: { b: 1 }, hint: idx_order_a_asc_b_desc (idx {a:1,b:-1})
-- Equality on prefix + ascending sort on b (reverse of {b:-1})
-- → backward scan within equality range → streaming
-- Expected: (a=1,b=1,id=7), (a=1,b=3,id=4), (a=1,b=4,id=10), (a=1,b=5,id=2)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_ordered(
    '{ "find": "sp_order_coll", "filter": { "a": 1 }, "sort": { "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 2, "hint": "idx_order_a_asc_b_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 2 }',
    2);

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- SECTION H: Primary key dynamic cursors with sort
-- Tests verify dynamic cursor behavior when using primary key scans with sort.
-- Primary key scans use the built-in _id index. With sort on _id, the scan
-- should be streamable (cursor_type=2, PrimaryKeyScan). Currently primary key
-- scans with sort produce persistent cursors — these are marked as UNEXPECTED.
-- Also includes backward scan tests for secondary index scans.
--
-- cursor_type values: 2 = PrimaryKeyScan, 3 = SecondaryIndexScan,
--                     7 = SecondaryIndexOnlyScan, NULL = persistent
-- ===========================================================================

-- Create a collection with sequential _id values for primary key scan tests
SELECT documentdb_api.drop_collection('dyncur_sp_db', 'sp_pk_coll');
SELECT COUNT(documentdb_api.insert_one('dyncur_sp_db', 'sp_pk_coll',
    FORMAT('{ "_id": %s, "val": %s }', i, i * 10)::documentdb_core.bson))
FROM generate_series(1, 20) AS i;

ANALYZE;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ---------------------------------------------------------------------------
-- Test H1: Primary key scan with ascending _id sort (no filter)
-- sort: { _id: 1 }, no hint (uses built-in _id index)
-- EXPECTED: streaming (cursor_type=2, persist_conn=f) — OK
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_pk_coll", "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5, 2);

-- ---------------------------------------------------------------------------
-- Test H2: Primary key scan with descending _id sort (backward scan)
-- sort: { _id: -1 }, no hint
-- EXPECTED: streaming (cursor_type=2, persist_conn=f) — OK
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_pk_coll", "sort": { "_id": -1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5, 2);

-- ---------------------------------------------------------------------------
-- Test H3: Primary key scan with filter + ascending _id sort
-- filter: { _id: { $gte: 5 } }, sort: { _id: 1 }
-- EXPECTED: streaming (cursor_type=2, persist_conn=f) — OK
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_pk_coll", "filter": { "_id": { "$gte": 5 } }, "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5, 2);

-- ---------------------------------------------------------------------------
-- Test H4: Primary key scan with filter + descending _id sort (backward)
-- filter: { _id: { $lte: 15 } }, sort: { _id: -1 }
-- EXPECTED: streaming (cursor_type=2, persist_conn=f) — OK
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_pk_coll", "filter": { "_id": { "$lte": 15 } }, "sort": { "_id": -1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5, 2);

-- ---------------------------------------------------------------------------
-- Test H5: Primary key scan, filter only (no sort) — baseline streaming
-- filter: { _id: { $gte: 10, $lte: 18 } }
-- EXPECTED: streaming (cursor_type=2, persist_conn=f)
-- This should already work since filter-only primary key scans are streamable.
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_pk_coll", "filter": { "_id": { "$gte": 10, "$lte": 18 } }, "projection": { "_id": 1, "val": 1 }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 3 }',
    3, 2);

-- ---------------------------------------------------------------------------
-- Test H6: Primary key scan with skip + ascending sort → persistent
-- sort: { _id: 1 }, skip: 5
-- Skip always forces persistent regardless of scan type.
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_pk_coll", "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "skip": 5, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5, 2);

-- ---------------------------------------------------------------------------
-- Test H7: Primary key scan with limit + ascending sort → persistent
-- sort: { _id: 1 }, limit: 10
-- Limit always forces persistent regardless of scan type.
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_pk_coll", "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "limit": 10, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5, 2);

-- ---------------------------------------------------------------------------
-- SECTION H EXPLAIN: Plan shapes for primary key scans with sort
-- ---------------------------------------------------------------------------

-- Test H1 EXPLAIN: ascending _id sort
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_pk_coll", "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }');
$cmd$);

-- Test H2 EXPLAIN: descending _id sort (backward scan)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('dyncur_sp_db',
    '{ "find": "sp_pk_coll", "sort": { "_id": -1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }');
$cmd$);

-- ===========================================================================
-- SECTION H2: Backward scan tests for secondary index scans
-- Validates that backward scans on secondary indexes (reversed sort direction
-- on all index keys) produce streaming cursors.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test H8: Backward scan on compound ASC index with full reverse sort
-- sort: { a: -1, b: -1 }, hint: idx_order_ab_asc (from Section G)
-- Full reverse of {a:1, b:1} → streaming backward index scan
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_order_coll", "sort": { "a": -1, "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test H9: Backward scan on mixed direction index with full reverse sort
-- sort: { a: -1, b: 1 }, hint: idx_order_a_asc_b_desc (from Section G)
-- Full reverse of {a:1, b:-1} → streaming backward index scan
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_order_coll", "sort": { "a": -1, "b": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_asc_b_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test H10: Backward scan on DESC index with ascending sort
-- sort: { a: 1 }, hint: idx_order_a_desc (from Section G)
-- Ascending sort on descending index → backward scan → streaming
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_order_coll", "sort": { "a": 1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_a_desc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test H11: Backward scan with filter on compound ASC index
-- filter: { a: { $lte: 2 } }, sort: { a: -1, b: -1 }, hint: idx_order_ab_asc
-- Full reverse of {a:1, b:1} with filter → streaming backward scan
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_order_coll", "filter": { "a": { "$lte": 2 } }, "sort": { "a": -1, "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 3, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test H12: Backward scan with equality filter + reversed next-key sort
-- filter: { a: 2 }, sort: { b: -1 }, hint: idx_order_ab_asc
-- Equality on prefix + descending sort on next key (reverse of {b:1})
-- → should be streaming (backward scan within equality range)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_and_report(
    '{ "find": "sp_order_coll", "filter": { "a": 2 }, "sort": { "b": -1 }, "projection": { "_id": 1, "a": 1, "b": 1 }, "batchSize": 2, "hint": "idx_order_ab_asc" }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_order_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- SECTION H RESULTS SUMMARY
-- ===========================================================================
-- | Test | Sort          | Filter       | Index/Scan   | Expected    | Status    |
-- |------|---------------|--------------|--------------|-------------|-----------|
-- | H1   | {_id:1}       | -            | primary key  | streaming   | OK        |
-- | H2   | {_id:-1}      | -            | primary key  | streaming   | OK        |
-- | H3   | {_id:1}       | _id >= 5     | primary key  | streaming   | OK        |
-- | H4   | {_id:-1}      | _id <= 15    | primary key  | streaming   | OK        |
-- | H5   | -             | _id range    | primary key  | streaming   | OK        |
-- | H6   | {_id:1}       | - (skip:5)   | primary key  | persistent  | OK        |
-- | H7   | {_id:1}       | - (limit:10) | primary key  | persistent  | OK        |
-- | H8   | {a:-1,b:-1}   | -            | idx_ab_asc   | streaming   | OK        |
-- | H9   | {a:-1,b:1}    | -            | idx_a1_b-1   | streaming   | OK        |
-- | H10  | {a:1}         | -            | idx_a_desc   | streaming   | OK        |
-- | H11  | {a:-1,b:-1}   | a <= 2       | idx_ab_asc   | streaming   | OK        |
-- | H12  | {b:-1}        | a = 2        | idx_ab_asc   | streaming   | OK        |
-- ===========================================================================

-- ===========================================================================
-- SECTION H3: Primary key scan ordering correctness
-- Validates that documents are returned in the correct order when sorting
-- by _id (forward and backward). Uses a simple drain helper without streaming
-- assertions to focus on document ordering.
-- ===========================================================================

-- Helper: drain cursor and return docs from all pages (asserts streaming PK scan)
CREATE OR REPLACE FUNCTION sp_drain_docs(
    p_find text, p_getmore text, p_batch_size int
) RETURNS TABLE(page_num int, docs documentdb_core.bson) AS $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_cid bigint;
    v_cursor_type int;
    v_page_num int := 0;
BEGIN
    SELECT fp.cursorPage, fp.continuation, fp.persistconnection, fp.cursorid
    INTO v_page, v_cont, v_persist, v_cid
    FROM find_cursor_first_page(database => 'dyncur_sp_db',
        commandSpec => p_find::documentdb_core.bson, cursorId => 538) fp;

    -- Assert streaming PK scan on first page
    IF v_persist THEN
        RAISE EXCEPTION 'sp_drain_docs page 1: expected streaming, got persistent';
    END IF;
    IF v_cont IS NOT NULL THEN
        SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_cursor_type;
        IF v_cursor_type IS DISTINCT FROM 2 THEN
            RAISE EXCEPTION 'sp_drain_docs page 1: expected dc.type=2 (PrimaryKeyScan), got %', v_cursor_type;
        END IF;
    END IF;

    v_page_num := 1;
    page_num := v_page_num;
    docs := bson_dollar_project(v_page, '{ "cursor.firstBatch._id": 1, "cursor.firstBatch.val": 1 }');
    RETURN NEXT;

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation
        INTO v_page, v_cont
        FROM cursor_get_more(database => 'dyncur_sp_db',
            getMoreSpec => p_getmore::documentdb_core.bson,
            continuationSpec => v_cont) gm;

        v_page_num := v_page_num + 1;

        -- Assert PK scan on subsequent pages
        IF v_cont IS NOT NULL THEN
            SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_cursor_type;
            IF v_cursor_type IS DISTINCT FROM 2 THEN
                RAISE EXCEPTION 'sp_drain_docs page %: expected dc.type=2 (PrimaryKeyScan), got %', v_page_num, v_cursor_type;
            END IF;
        END IF;

        page_num := v_page_num;
        docs := bson_dollar_project(v_page, '{ "cursor.nextBatch._id": 1, "cursor.nextBatch.val": 1 }');
        RETURN NEXT;

        IF v_cont IS NULL THEN
            EXIT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ---------------------------------------------------------------------------
-- Test H13: PK forward scan correctness — ascending _id sort (no filter)
-- sort: { _id: 1 }, batchSize: 5, 20 docs (_id=1..20, val=_id*10)
-- Expected: _id 1,2,3,4,5 | 6,7,8,9,10 | 11,12,13,14,15 | 16,17,18,19,20
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_docs(
    '{ "find": "sp_pk_coll", "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test H14: PK backward scan correctness — descending _id sort (no filter)
-- sort: { _id: -1 }, batchSize: 5, 20 docs
-- Expected: _id 20,19,18,17,16 | 15,14,13,12,11 | 10,9,8,7,6 | 5,4,3,2,1
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_docs(
    '{ "find": "sp_pk_coll", "sort": { "_id": -1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }',
    5);

-- ---------------------------------------------------------------------------
-- Test H15: PK forward scan with filter — ascending _id sort
-- filter: { _id: { $gte: 5, $lte: 14 } }, sort: { _id: 1 }, batchSize: 3
-- Expected: _id 5,6,7 | 8,9,10 | 11,12,13 | 14
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_docs(
    '{ "find": "sp_pk_coll", "filter": { "_id": { "$gte": 5, "$lte": 14 } }, "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test H16: PK backward scan with filter — descending _id sort
-- filter: { _id: { $gte: 5, $lte: 14 } }, sort: { _id: -1 }, batchSize: 3
-- Expected: _id 14,13,12 | 11,10,9 | 8,7,6 | 5
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_docs(
    '{ "find": "sp_pk_coll", "filter": { "_id": { "$gte": 5, "$lte": 14 } }, "sort": { "_id": -1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 3 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 3 }',
    3);

-- ---------------------------------------------------------------------------
-- Test H17: PK forward scan — no sort, filter only (baseline streaming)
-- filter: { _id: { $gte: 8, $lte: 12 } }, batchSize: 2
-- Expected: _id 8,9 | 10,11 | 12 (natural _id order from index scan)
-- ---------------------------------------------------------------------------
SELECT * FROM sp_drain_docs(
    '{ "find": "sp_pk_coll", "filter": { "_id": { "$gte": 8, "$lte": 12 } }, "projection": { "_id": 1, "val": 1 }, "batchSize": 2 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 2 }',
    2);

-- ---------------------------------------------------------------------------
-- Test H18: PK forward scan — total doc count check
-- sort: { _id: 1 }, batchSize: 7, 20 docs → 3 pages (7+7+6)
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS total_pages FROM sp_drain_docs(
    '{ "find": "sp_pk_coll", "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": 7 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 7 }',
    7);

-- ---------------------------------------------------------------------------
-- Test H19: PK backward scan — total doc count check with filter
-- filter: { _id: { $lte: 15 } }, sort: { _id: -1 }, batchSize: 4
-- 15 docs → 4 pages (4+4+4+3)
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS total_pages FROM sp_drain_docs(
    '{ "find": "sp_pk_coll", "filter": { "_id": { "$lte": 15 } }, "sort": { "_id": -1 }, "projection": { "_id": 1 }, "batchSize": 4 }',
    '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 4 }',
    4);

-- ===========================================================================
-- SECTION H4: Primary key scan persistence across getMore with index_scan disabled
-- Validates that once a streaming PK scan is established on the first page,
-- disabling enable_indexscan does not change the scan type on subsequent
-- getMore calls — the continuation should preserve cursor_type=2.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Test H20: PK forward sort, disable enable_indexscan after first page
-- First page: sort {_id: 1}, batchSize 5 → streaming cursor_type=2
-- Then SET enable_indexscan = off and do getMore — should still be PK scan
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_cursor_type int;
    v_batch_count bigint;
BEGIN
    -- Get first page (with index scans enabled — should pick PK scan)
    SELECT fp.cursorPage, fp.continuation, fp.persistconnection
    INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page(
        database => 'dyncur_sp_db',
        commandSpec => '{ "find": "sp_pk_coll", "sort": { "_id": 1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }'::documentdb_core.bson,
        cursorId => 538
    ) fp;

    -- Assert first page is streaming with PK scan
    IF v_persist THEN
        RAISE EXCEPTION 'H20: first page should be streaming, got persistent';
    END IF;

    SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_cursor_type;
    IF v_cursor_type IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'H20: first page expected dc.type=2 (PrimaryKeyScan), got %', v_cursor_type;
    END IF;

    RAISE NOTICE 'H20 first page: streaming=true, cursor_type=%, batch=5', v_cursor_type;

    -- Disable index scans, ensure seq scan is available
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_seqscan = on;

    -- getMore — the continuation should force PK scan regardless
    SELECT gm.cursorPage, gm.continuation
    INTO v_page, v_cont
    FROM cursor_get_more(
        database => 'dyncur_sp_db',
        getMoreSpec => '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }'::documentdb_core.bson,
        continuationSpec => v_cont
    ) gm;

    -- Assert getMore still has PK scan
    SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_cursor_type;
    IF v_cursor_type IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'H20: getMore expected dc.type=2 (PrimaryKeyScan) with index_scan off, got %', v_cursor_type;
    END IF;

    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
        ->> 'c')::bigint INTO v_batch_count;

    RAISE NOTICE 'H20 getMore (index_scan=off): cursor_type=%, batch=%', v_cursor_type, v_batch_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- Test H21: PK backward sort, disable enable_indexscan after first page
-- sort: { _id: -1 }, batchSize 5
-- First page: streaming cursor_type=2, then disable index scans
-- getMore should still preserve cursor_type=2 (PrimaryKeyScan)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_cursor_type int;
    v_batch_count bigint;
BEGIN
    -- Get first page with backward PK sort
    SELECT fp.cursorPage, fp.continuation, fp.persistconnection
    INTO v_page, v_cont, v_persist
    FROM find_cursor_first_page(
        database => 'dyncur_sp_db',
        commandSpec => '{ "find": "sp_pk_coll", "sort": { "_id": -1 }, "projection": { "_id": 1, "val": 1 }, "batchSize": 5 }'::documentdb_core.bson,
        cursorId => 538
    ) fp;

    -- Assert first page is streaming with PK scan
    IF v_persist THEN
        RAISE EXCEPTION 'H21: first page should be streaming, got persistent';
    END IF;

    SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_cursor_type;
    IF v_cursor_type IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'H21: first page expected dc.type=2 (PrimaryKeyScan), got %', v_cursor_type;
    END IF;

    RAISE NOTICE 'H21 first page: streaming=true, cursor_type=%', v_cursor_type;

    -- Disable index scans, ensure seq scan is available
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_seqscan = on;

    -- getMore — continuation should preserve PK scan regardless
    SELECT gm.cursorPage, gm.continuation
    INTO v_page, v_cont
    FROM cursor_get_more(
        database => 'dyncur_sp_db',
        getMoreSpec => '{ "getMore": { "$numberLong": "538" }, "collection": "sp_pk_coll", "batchSize": 5 }'::documentdb_core.bson,
        continuationSpec => v_cont
    ) gm;

    -- Assert getMore still has PK scan
    SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_cursor_type;
    IF v_cursor_type IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'H21: getMore expected dc.type=2 (PrimaryKeyScan) with index_scan off, got %', v_cursor_type;
    END IF;

    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }')
        ->> 'c')::bigint INTO v_batch_count;

    RAISE NOTICE 'H21 getMore (index_scan=off): cursor_type=%, batch=%', v_cursor_type, v_batch_count;
END;
$$;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- Cleanup
-- ===========================================================================
DROP FUNCTION IF EXISTS sp_drain_and_report;
DROP FUNCTION IF EXISTS sp_drain_ordered;
DROP FUNCTION IF EXISTS sp_drain_docs;


-- ===========================================================================
-- Runtime Sort vs forced index-order streaming.
--
-- When per-collection planner statistics are available the dynamic-cursor
-- planner keeps the runtime-Sort candidate paths instead of pruning every
-- candidate but the order-providing index path. For a query that filters on a
-- selective field and sorts on a different field, the planner then uses the
-- selective filter index plus a runtime Sort -- far cheaper than scanning the
-- entire ordered sort-index. That Sort makes the outermost plan node a Sort (not
-- a bare streaming custom scan), so the query is served by a persistent cursor.
-- With statistics disabled the planner has no reliable estimates, prunes every
-- candidate but the order-providing path, and forces the index-order streaming
-- plan for the same query.
--
-- "a" is the selective filter field (plain index); "b" is the sort field (ordered
-- index). The filter value matches no document, which keeps the selective-index
-- plan essentially free and makes the choice between the two plans unambiguous.
-- ===========================================================================

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
-- The runtime-Sort plan reads the selective "a" index; allow seq scan so the
-- planner's cost choice is not skewed by an artificial seq-scan penalty.
SET enable_seqscan TO on;

SELECT documentdb_api.drop_collection('runtime_sort_db', 'runtime_sort_coll');

-- 500 docs: "a" has 100 distinct values (selective); "b" is a scrambled
-- permutation of 0..499 so a broken sort would be detectable.
SELECT COUNT(documentdb_api.insert_one('runtime_sort_db', 'runtime_sort_coll',
    FORMAT('{ "_id": %s, "a": "grp_%s", "b": %s }', i, i % 100, (i * 37) % 500)::documentdb_core.bson))
FROM generate_series(1, 500) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('runtime_sort_db',
    '{"createIndexes": "runtime_sort_coll", "indexes": [{"key": {"a": 1}, "name": "idx_a"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('runtime_sort_db',
    '{"createIndexes": "runtime_sort_coll", "indexes": [{"key": {"b": 1}, "name": "idx_b_asc", "enableOrderedIndex": true}]}', true);

-- ---------------------------------------------------------------------------
-- Case 1: per-collection statistics enabled. The planner picks the selective
-- "a" index plus a runtime Sort; the Sort makes the outermost node non-streaming
-- so the query is served by a persistent cursor (persistConnection = true). The
-- filter matches no document, so the cursor drains zero rows.
-- ---------------------------------------------------------------------------
SELECT documentdb_api.coll_mod('runtime_sort_db', 'runtime_sort_coll',
    '{ "collMod": "runtime_sort_coll", "enableStats": true }');
ANALYZE;

EXPLAIN (COSTS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('runtime_sort_db',
        '{ "find": "runtime_sort_coll", "filter": { "a": "grp_missing" }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }');

SELECT CASE WHEN persistConnection THEN 'persistent (runtime sort)' ELSE 'streaming (index order)' END AS cursor_kind,
       COALESCE(jsonb_array_length((cursorPage::text::jsonb) -> 'cursor' -> 'firstBatch'), 0) AS docs
FROM find_cursor_first_page(database => 'runtime_sort_db',
    commandSpec => '{ "find": "runtime_sort_coll", "filter": { "a": "grp_missing" }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }'::documentdb_core.bson,
    cursorId => 4294967290);

-- ---------------------------------------------------------------------------
-- Case 2: no reliable operator selectivity -- per-collection statistics disabled
-- AND the composite-index planner disabled, so isOperatorSelectivityEnabled
-- (= EnableCompositeIndexPlanner || perCollectionStats) is false. The path walk
-- then prunes every candidate but the order-providing "b" ordered index and
-- forces the index-order streaming plan (persistConnection = false) for the same
-- zero-result query. (With either signal present the planner would instead be
-- free to choose the cheaper runtime Sort, as in Case 1.)
-- ---------------------------------------------------------------------------
SET documentdb.enableCompositeIndexPlanner TO off;
SELECT documentdb_api.coll_mod('runtime_sort_db', 'runtime_sort_coll',
    '{ "collMod": "runtime_sort_coll", "enableStats": false }');
ANALYZE;

EXPLAIN (COSTS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('runtime_sort_db',
        '{ "find": "runtime_sort_coll", "filter": { "a": "grp_missing" }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }');

SELECT CASE WHEN persistConnection THEN 'persistent (runtime sort)' ELSE 'streaming (index order)' END AS cursor_kind,
       COALESCE(jsonb_array_length((cursorPage::text::jsonb) -> 'cursor' -> 'firstBatch'), 0) AS docs
FROM find_cursor_first_page(database => 'runtime_sort_db',
    commandSpec => '{ "find": "runtime_sort_coll", "filter": { "a": "grp_missing" }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }'::documentdb_core.bson,
    cursorId => 4294967291);

-- Restore the composite-index planner for the coverage section below.
SET documentdb.enableCompositeIndexPlanner TO on;

-- ===========================================================================
-- Additional coverage for the dynamic-cursor path-walk switch cases.
--
-- Exercises every branch of WalkRelPathsAndCreateCustomPathsForFirstPage --
-- the secondary-index case, the primary-key case (including the
-- ConsiderBtreeOrderByPushdown path), the bitmap/"default" case, and the
-- no-sort path (switch skipped) -- under per-collection statistics both enabled
-- and disabled. These do NOT assert a streaming-vs-persistent outcome; they only
-- verify that each shape plans, executes, drains cleanly, and returns correctly
-- ordered results regardless of the GUC state. The drained result set is
-- invariant across the GUC, so both blocks below produce identical output.
-- ===========================================================================
CREATE OR REPLACE FUNCTION runtime_sort_cov_check(
    p_coll text, p_find text, p_sort_field text, p_dir int, p_cursor_id bigint)
    RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_page    documentdb_core.bson;
    v_cont    documentdb_core.bson;
    v_batch   jsonb;
    v_docs    int := 0;
    v_vals    numeric[] := '{}';
    v_getmore text := format(
        '{ "getMore": { "$numberLong": "%s" }, "collection": "%s", "batchSize": 100 }',
        p_cursor_id, p_coll);
    v_ordered text;
BEGIN
    SELECT cursorPage, continuation INTO v_page, v_cont
    FROM find_cursor_first_page(database => 'runtime_sort_db',
        commandSpec => p_find::documentdb_core.bson, cursorId => p_cursor_id);

    v_batch := COALESCE((v_page::text::jsonb) -> 'cursor' -> 'firstBatch', '[]'::jsonb);
    v_docs := v_docs + jsonb_array_length(v_batch);
    IF p_dir <> 0 THEN
        v_vals := v_vals || COALESCE((
            SELECT array_agg((e -> p_sort_field ->> '$numberInt')::numeric ORDER BY ord)
            FROM jsonb_array_elements(v_batch) WITH ORDINALITY AS t(e, ord)), '{}');
    END IF;

    WHILE v_cont IS NOT NULL LOOP
        SELECT cursorPage, continuation INTO v_page, v_cont
        FROM cursor_get_more(database => 'runtime_sort_db',
            getMoreSpec => v_getmore::documentdb_core.bson, continuationSpec => v_cont);
        v_batch := COALESCE((v_page::text::jsonb) -> 'cursor' -> 'nextBatch', '[]'::jsonb);
        v_docs := v_docs + jsonb_array_length(v_batch);
        IF p_dir <> 0 THEN
            v_vals := v_vals || COALESCE((
                SELECT array_agg((e -> p_sort_field ->> '$numberInt')::numeric ORDER BY ord)
                FROM jsonb_array_elements(v_batch) WITH ORDINALITY AS t(e, ord)), '{}');
        END IF;
    END LOOP;

    IF p_dir = 0 THEN
        v_ordered := 'n/a';
    ELSIF p_dir > 0 THEN
        v_ordered := (v_vals = (SELECT array_agg(x ORDER BY x) FROM unnest(v_vals) AS x))::text;
    ELSE
        v_ordered := (v_vals = (SELECT array_agg(x ORDER BY x DESC) FROM unnest(v_vals) AS x))::text;
    END IF;

    RETURN format('docs=%s, ordered=%s', v_docs, v_ordered);
END;
$fn$;

-- Block 1: per-collection statistics enabled (switch cases keep every candidate).
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SELECT documentdb_api.coll_mod('runtime_sort_db', 'runtime_sort_coll',
    '{ "collMod": "runtime_sort_coll", "enableStats": true }');
ANALYZE;

SELECT q.label, r.result
FROM (VALUES
    ('1_secondary_b_asc',  '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', 1, 4294967280::bigint),
    ('2_secondary_b_desc', '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "b": -1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', -1, 4294967281::bigint),
    ('3_pk_id_asc',        '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": 100 }', '_id', 1, 4294967282::bigint),
    ('4_pk_id_desc',       '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "_id": -1 }, "projection": { "_id": 1 }, "batchSize": 100 }', '_id', -1, 4294967283::bigint),
    ('5_filter_a_sort_b',  '{ "find": "runtime_sort_coll", "filter": { "a": "grp_1" }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', 1, 4294967284::bigint),
    ('6_bitmap_in_a',      '{ "find": "runtime_sort_coll", "filter": { "a": { "$in": [ "grp_1", "grp_2", "grp_3" ] } }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', 1, 4294967285::bigint),
    ('7_no_sort_a',        '{ "find": "runtime_sort_coll", "filter": { "a": "grp_2" }, "projection": { "_id": 1 }, "batchSize": 100 }', '_id', 0, 4294967286::bigint)
) AS q(label, find, field, dir, cid)
CROSS JOIN LATERAL (SELECT runtime_sort_cov_check('runtime_sort_coll', q.find, q.field, q.dir, q.cid) AS result) r
ORDER BY q.label;

-- Block 2: per-collection statistics disabled (switch cases prune to the
-- order-providing path). Same shapes, same expected results.
SELECT documentdb_api.coll_mod('runtime_sort_db', 'runtime_sort_coll',
    '{ "collMod": "runtime_sort_coll", "enableStats": false }');
ANALYZE;

SELECT q.label, r.result
FROM (VALUES
    ('1_secondary_b_asc',  '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', 1, 4294967280::bigint),
    ('2_secondary_b_desc', '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "b": -1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', -1, 4294967281::bigint),
    ('3_pk_id_asc',        '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "_id": 1 }, "projection": { "_id": 1 }, "batchSize": 100 }', '_id', 1, 4294967282::bigint),
    ('4_pk_id_desc',       '{ "find": "runtime_sort_coll", "filter": { }, "sort": { "_id": -1 }, "projection": { "_id": 1 }, "batchSize": 100 }', '_id', -1, 4294967283::bigint),
    ('5_filter_a_sort_b',  '{ "find": "runtime_sort_coll", "filter": { "a": "grp_1" }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', 1, 4294967284::bigint),
    ('6_bitmap_in_a',      '{ "find": "runtime_sort_coll", "filter": { "a": { "$in": [ "grp_1", "grp_2", "grp_3" ] } }, "sort": { "b": 1 }, "projection": { "_id": 0, "b": 1 }, "batchSize": 100 }', 'b', 1, 4294967285::bigint),
    ('7_no_sort_a',        '{ "find": "runtime_sort_coll", "filter": { "a": "grp_2" }, "projection": { "_id": 1 }, "batchSize": 100 }', '_id', 0, 4294967286::bigint)
) AS q(label, find, field, dir, cid)
CROSS JOIN LATERAL (SELECT runtime_sort_cov_check('runtime_sort_coll', q.find, q.field, q.dir, q.cid) AS result) r
ORDER BY q.label;

DROP FUNCTION runtime_sort_cov_check(text, text, text, int, bigint);

-- Cleanup
SELECT documentdb_api.drop_collection('runtime_sort_db', 'runtime_sort_coll');


-- ===========================================================================
-- SECTION I: $group streaming vs persistent cursors.
--
-- A $group normally forces a persistent cursor (a hash aggregate is blocking
-- and has no resumable scan position). But when the group keys can be provided
-- in order by a composite (ordered) index, the planner builds a sorted
-- GroupAggregate over an ordered index-only scan with no blocking Sort, which
-- streams one group at a time. documentdb.enable_group_by_dynamic_streaming
-- gates whether that streamable shape is served by a dynamic (streaming) cursor
-- or falls back to the persistent cursor.
-- ===========================================================================

-- Composite op class + compound-id pushdown + repath write are what turn the
-- $group into a GroupAggregate over an ordered index scan (no Sort).
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET documentdb_core.enableWriteDocumentsInRepath TO on;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

SELECT documentdb_api.drop_collection('dyncur_grp_db', 'grp_coll');

-- g = i % 5 -> 5 distinct values, 40 rows per group (multi-row groups);
-- s = i     -> unique per row (single-row groups when grouping on {g,s});
-- w = i * 3 -> a field that is NOT indexed (forces a heap fetch when accumulated).
SELECT COUNT(documentdb_api.insert_one('dyncur_grp_db', 'grp_coll',
    documentdb_core.bson_build_document('_id', i, 'g', i % 5, 's', i, 'w', i * 3)))
FROM generate_series(1, 200) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncur_grp_db',
    '{ "createIndexes": "grp_coll", "indexes": [ { "key": { "g": 1, "s": 1 }, "name": "g_s_1" } ] }',
    true);

ANALYZE;

-- ---------------------------------------------------------------------------
-- Helper: drain an aggregate ($group) cursor and report the cursor kind
-- (streaming vs persistent), the total number of groups returned, and the scan
-- type recorded in the first continuation (7 = streaming secondary index-only
-- scan; NULL when the batch fully drains in the first page or when persistent).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION grp_drain_kind(p_agg text, p_batch_size int, p_cursor_id bigint)
RETURNS TABLE(cursor_kind text, total bigint, first_type int) AS $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_batch bigint;
BEGIN
    total := 0;
    first_type := NULL;

    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
    INTO v_page, v_cont, v_persist
    FROM aggregate_cursor_first_page(
        database => 'dyncur_grp_db', commandSpec => p_agg::documentdb_core.bson,
        cursorId => p_cursor_id) fp;

    cursor_kind := CASE WHEN v_persist THEN 'persistent' ELSE 'streaming' END;

    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint
        INTO v_batch;
    total := total + COALESCE(v_batch, 0);

    IF v_cont IS NOT NULL THEN
        SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int
            INTO first_type;
    END IF;

    WHILE v_cont IS NOT NULL LOOP
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'dyncur_grp_db',
            getMoreSpec => FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "grp_coll", "batchSize": %s }', p_cursor_id, p_batch_size)::documentdb_core.bson,
            continuationSpec => v_cont) gm;

        SELECT (bson_dollar_project(v_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint
            INTO v_batch;
        total := total + COALESCE(v_batch, 0);
    END LOOP;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Helper: like grp_drain_kind, but strictly asserts the cursor stays streaming
-- on EVERY page -- the first page AND every getMore page. For a $group served
-- by a secondary (composite) index the resumed scan is rebuilt on each getMore
-- from the continuation; this helper verifies that rebuilt path keeps the index
-- ordering (no blocking Sort) so the continuation is always the streaming shape
-- with dc.type = p_expected_type. It raises if any continuation-bearing page is
-- persistent (dc.type NULL) or reports a different scan type, catching a getMore
-- that silently flips a secondary-index $group to a persistent cursor.
-- Returns the total groups drained and the number of getMore pages that carried
-- a streaming continuation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION grp_drain_assert_streaming(
    p_agg text, p_batch_size int, p_cursor_id bigint, p_expected_type int)
RETURNS TABLE(total bigint, getmore_streaming_pages int) AS $$
DECLARE
    v_page documentdb_core.bson;
    v_cont documentdb_core.bson;
    v_persist bool;
    v_batch bigint;
    v_type int;
    v_page_num int := 1;
BEGIN
    total := 0;
    getmore_streaming_pages := 0;

    SELECT fp.cursorPage, fp.continuation, fp.persistConnection
    INTO v_page, v_cont, v_persist
    FROM aggregate_cursor_first_page(
        database => 'dyncur_grp_db', commandSpec => p_agg::documentdb_core.bson,
        cursorId => p_cursor_id) fp;

    IF v_persist THEN
        RAISE EXCEPTION 'Page 1: expected streaming cursor, got persistent';
    END IF;

    SELECT (bson_dollar_project(v_page,
        '{ "c": { "$size": { "$ifNull": ["$cursor.firstBatch", []] } } }') ->> 'c')::bigint
        INTO v_batch;
    total := total + COALESCE(v_batch, 0);

    IF v_cont IS NOT NULL THEN
        SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_type;
        IF v_type IS DISTINCT FROM p_expected_type THEN
            RAISE EXCEPTION 'Page 1: expected streaming dc.type=%, got %', p_expected_type, v_type;
        END IF;
    END IF;

    WHILE v_cont IS NOT NULL LOOP
        v_page_num := v_page_num + 1;
        SELECT gm.cursorPage, gm.continuation INTO v_page, v_cont
        FROM cursor_get_more(
            database => 'dyncur_grp_db',
            getMoreSpec => FORMAT('{ "getMore": { "$numberLong": "%s" }, "collection": "grp_coll", "batchSize": %s }', p_cursor_id, p_batch_size)::documentdb_core.bson,
            continuationSpec => v_cont) gm;

        SELECT (bson_dollar_project(v_page,
            '{ "c": { "$size": { "$ifNull": ["$cursor.nextBatch", []] } } }') ->> 'c')::bigint
            INTO v_batch;
        total := total + COALESCE(v_batch, 0);

        -- A non-NULL continuation means more pages remain; it must stay streaming.
        IF v_cont IS NOT NULL THEN
            SELECT (bson_dollar_project(v_cont, '{ "dc.type": 1 }') ->> 'dc.type')::int INTO v_type;
            IF v_type IS NULL THEN
                RAISE EXCEPTION 'Page %: getMore flipped to persistent (dc.type is NULL)', v_page_num;
            END IF;
            IF v_type <> p_expected_type THEN
                RAISE EXCEPTION 'Page %: expected streaming dc.type=%, got %', v_page_num, p_expected_type, v_type;
            END IF;
            getmore_streaming_pages := getmore_streaming_pages + 1;
        END IF;
    END LOOP;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Test I1: GUC on, compound-id $group ({g,s}) -> streaming cursor (type 7),
-- draining all 200 single-row groups across small batches.
-- ---------------------------------------------------------------------------
SET documentdb.enable_group_by_dynamic_streaming TO on;

SELECT * FROM grp_drain_kind(
    '{ "aggregate": "grp_coll", "hint": "g_s_1", "pipeline": [ { "$group": { "_id": { "g": "$g", "s": "$s" } } } ], "cursor": { "batchSize": 7 } }',
    7, 5101);

-- ---------------------------------------------------------------------------
-- Test I2: GUC on, multi-row group ({g}) with a $sum accumulator -> streaming
-- cursor. Exercises the sorted GroupAggregate read-ahead: a group is only
-- emitted after the first row of the next group is read, so the continuation
-- must resume at the next group without dropping or duplicating a group.
-- All 5 groups must be returned across every small batch size.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_bs int; v_kind text; v_total bigint; v_type int;
BEGIN
    FOREACH v_bs IN ARRAY ARRAY[1, 2, 3, 4, 5, 6] LOOP
        SELECT cursor_kind, total, first_type INTO v_kind, v_total, v_type
        FROM grp_drain_kind(
            FORMAT('{ "aggregate": "grp_coll", "hint": "g_s_1", "pipeline": [ { "$group": { "_id": { "g": "$g" }, "n": { "$sum": 1 } } } ], "cursor": { "batchSize": %s } }', v_bs),
            v_bs, 5102);
        IF v_total <> 5 THEN
            RAISE EXCEPTION 'multi-row group batchSize=%: got % groups, expected 5', v_bs, v_total;
        END IF;
        IF v_kind <> 'streaming' THEN
            RAISE EXCEPTION 'multi-row group batchSize=%: expected streaming cursor, got %', v_bs, v_kind;
        END IF;
    END LOOP;
    RAISE NOTICE 'multi-row group: all batch sizes stream 5 groups (read-ahead correct)';
END $$;

-- ---------------------------------------------------------------------------
-- Test I3: accumulator values are correct on the streamed groups
-- (each g has 40 rows).
-- ---------------------------------------------------------------------------
SELECT bson_dollar_project(cursorPage, '{ "cursor.firstBatch": 1 }')
FROM aggregate_cursor_first_page(
    database => 'dyncur_grp_db',
    commandSpec => '{ "aggregate": "grp_coll", "hint": "g_s_1", "pipeline": [ { "$group": { "_id": { "g": "$g" }, "n": { "$sum": 1 } } }, { "$sort": { "_id.g": 1 } } ], "cursor": { "batchSize": 100 } }'::documentdb_core.bson,
    cursorId => 5103);

-- ---------------------------------------------------------------------------
-- Test I4: GUC off -> the same streamable $group falls back to a persistent
-- cursor, still returning all 5 groups correctly.
-- ---------------------------------------------------------------------------
SET documentdb.enable_group_by_dynamic_streaming TO off;

SELECT * FROM grp_drain_kind(
    '{ "aggregate": "grp_coll", "hint": "g_s_1", "pipeline": [ { "$group": { "_id": { "g": "$g" }, "n": { "$sum": 1 } } } ], "cursor": { "batchSize": 2 } }',
    2, 5104);

-- ---------------------------------------------------------------------------
-- Test I5: GUC on, group with an accumulator on a NON-indexed field ($sum: "$w")
-- -> the ordering index still serves the group order, but the scan must fetch
-- "w" from the heap, so it is a plain (heap-fetching) secondary index scan
-- (dc.type 3) rather than an index-only scan (dc.type 7). It must still stream.
-- ---------------------------------------------------------------------------
SET documentdb.enable_group_by_dynamic_streaming TO on;

SELECT * FROM grp_drain_kind(
    '{ "aggregate": "grp_coll", "hint": "g_s_1", "pipeline": [ { "$group": { "_id": { "g": "$g" }, "sw": { "$sum": "$w" } } } ], "cursor": { "batchSize": 2 } }',
    2, 5105);

-- ---------------------------------------------------------------------------
-- Test I6: GUC on, compound-id $group ({g,s}) on the secondary index, drained
-- with a tiny batch size so the cursor is resumed across many getMore pages.
-- Asserts the SecondaryIndexOnlyScan branch (dc.type 7) stays streaming on the
-- first page AND on every getMore page -- i.e. the resumed secondary-index scan
-- keeps its index ordering and never flips to a persistent cursor mid-stream.
-- 200 single-row groups over batchSize 3 -> at least ~66 streaming getMore pages.
-- ---------------------------------------------------------------------------
SET documentdb.enable_group_by_dynamic_streaming TO on;

SELECT total, (getmore_streaming_pages > 0) AS drained_across_getmores
FROM grp_drain_assert_streaming(
    '{ "aggregate": "grp_coll", "hint": "g_s_1", "pipeline": [ { "$group": { "_id": { "g": "$g", "s": "$s" } } } ], "cursor": { "batchSize": 3 } }',
    3, 5106, 7);

-- ---------------------------------------------------------------------------
-- Test I7: GUC on, multi-row group ({g}) with a heap-fetching accumulator
-- ($sum: "$w" on a non-indexed field). Asserts the plain SecondaryIndexScan
-- branch (dc.type 3) also stays streaming across every getMore page while the
-- read-ahead GroupAggregate resumes group-by-group over the ordered index.
-- ---------------------------------------------------------------------------
SELECT total, (getmore_streaming_pages > 0) AS drained_across_getmores
FROM grp_drain_assert_streaming(
    '{ "aggregate": "grp_coll", "hint": "g_s_1", "pipeline": [ { "$group": { "_id": { "g": "$g" }, "sw": { "$sum": "$w" } } } ], "cursor": { "batchSize": 1 } }',
    1, 5107, 3);

-- Cleanup
DROP FUNCTION grp_drain_kind(text, int, bigint);
DROP FUNCTION grp_drain_assert_streaming(text, int, bigint, int);
SELECT documentdb_api.drop_collection('dyncur_grp_db', 'grp_coll');
SET documentdb.enable_group_by_dynamic_streaming TO off;
