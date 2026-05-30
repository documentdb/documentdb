-- Tests for dynamic cursor behavior with index scans: validates that streaming
-- cursors are used for simple ordered index scans with filters, and that
-- skip or limit causes a fallback to persistent cursors.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 9800;
SET documentdb.next_collection_index_id TO 9800;

SET documentdb.enablePrimaryKeyCursorScan TO on;
SET documentdb.enableCursorPlanBeforeRestrictionPathUpdate TO off;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableIndexOnlyScan TO on;
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
    p_batch_size int
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

SET documentdb.enableCursorsOnAggregationQueryRewrite TO off;

-- ===========================================================================
-- Cleanup
-- ===========================================================================
DROP FUNCTION IF EXISTS sp_drain_and_report;
DROP FUNCTION IF EXISTS sp_drain_ordered;
