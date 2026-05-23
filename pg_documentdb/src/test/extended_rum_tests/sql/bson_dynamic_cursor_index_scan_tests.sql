-- Tests for Index Only Scan (IOS) dynamic cursor continuation with compound
-- and multi-path indexes. Verifies that getMore correctly advances past the
-- continuation point for all sort-direction combinations and various batch sizes.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

-- Clean up from any prior runs
SELECT documentdb_api.drop_collection('ios_idx_db', 'ios_coll');
SELECT documentdb_api.drop_collection('ios_idx_db', 'ios_cross_coll');

SET documentdb.next_collection_id TO 9600;
SET documentdb.next_collection_index_id TO 9600;

SET documentdb.enablePrimaryKeyCursorScan TO on;
SET documentdb.enableCursorPlanBeforeRestrictionPathUpdate TO off;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableIndexOnlyScan TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;
SET enable_seqscan TO off;

-- ---------------------------------------------------------------------------
-- Data setup: 18 docs with a="v1", b in {1,2,3}, c in {1..6} per b value.
-- Each compound key (a,b) has 6 docs; each 3-key compound key (a,b,c) is unique.
-- ---------------------------------------------------------------------------
SELECT documentdb_api.insert_one('ios_idx_db', 'ios_coll',
    FORMAT('{ "a": "v1", "b": %s, "c": %s }',
           ((i - 1) / 6) + 1,
           ((i - 1) % 6) + 1
    )::documentdb_core.bson)
FROM generate_series(1, 18) AS i;

ANALYZE;

-- ---------------------------------------------------------------------------
-- Indexes: cover all ASC/DESC combinations across 2 and 3 paths.
-- ---------------------------------------------------------------------------
-- 2-path indexes
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": 1, "b": 1}, "name": "idx_ab_aa"}]}', true);

SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": 1, "b": -1}, "name": "idx_ab_ad"}]}', true);

SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": -1, "b": 1}, "name": "idx_ab_da"}]}', true);

SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": -1, "b": -1}, "name": "idx_ab_dd"}]}', true);

-- 3-path indexes
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": 1, "b": 1, "c": 1}, "name": "idx_abc_aaa"}]}', true);

SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": 1, "b": -1, "c": 1}, "name": "idx_abc_ada"}]}', true);

SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": 1, "b": 1, "c": -1}, "name": "idx_abc_aad"}]}', true);

SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_coll", "indexes": [{"key": {"a": 1, "b": -1, "c": -1}, "name": "idx_abc_add"}]}', true);

-- ---------------------------------------------------------------------------
-- Drain helper: reports only batch sizes for stability.
-- 18 docs total:
--   batchSize=1 -> 18 pages of 1
--   batchSize=2 ->  9 pages of 2
--   batchSize=5 ->  4 pages (5+5+5+3)
--   batchSize=8 ->  3 pages (8+8+2)
-- ---------------------------------------------------------------------------
PREPARE drain_ios(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation
          FROM find_cursor_first_page(database => 'ios_idx_db',
                                      commandSpec => $1, cursorId => 536)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation
          FROM cte,
               cursor_get_more(database => 'ios_idx_db',
                               getMoreSpec => $2,
                               continuationSpec => cte.continuation) gm
         WHERE cte.continuation IS NOT NULL
    )
    SELECT bson_dollar_project(cursorPage,
        '{"batchSize": { "$max": [
            { "$size": { "$ifNull": ["$cursor.firstBatch", []]}},
            { "$size": { "$ifNull": ["$cursor.nextBatch", []]}}
          ]}}')
      FROM cte);

-- ===========================================================================
-- EXPLAIN ANALYZE: verify plan shapes and continuation bounds for composite
-- index scans. One representative case for each category:
--   2-path ASC+DESC, 3-path ASC+DESC+ASC, cross-boundary DESC+ASC+DESC
-- ===========================================================================
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- ---------------------------------------------------------------------------
-- 2-path ASC+DESC {a:1, b:-1}: first page + getMore with continuation
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('ios_idx_db',
        '{ "find": "ios_coll", "filter": { "a": "v1" }, "projection": { "a": 1, "b": 1, "_id": 0 }, "batchSize": 5, "hint": "idx_ab_ad" }');
$cmd$, true);

CREATE TEMP TABLE ios_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'ios_idx_db',
    commandSpec => '{ "find": "ios_coll", "filter": { "a": "v1" }, "projection": { "a": 1, "b": 1, "_id": 0 }, "batchSize": 5, "hint": "idx_ab_ad" }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM ios_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('ios_idx_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "ios_coll", "batchSize": 5 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE ios_explain_resp;

-- ---------------------------------------------------------------------------
-- 3-path ASC+DESC+ASC {a:1, b:-1, c:1}: first page + getMore with continuation
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('ios_idx_db',
        '{ "find": "ios_coll", "filter": { "a": "v1" }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "batchSize": 5, "hint": "idx_abc_ada" }');
$cmd$, true);

CREATE TEMP TABLE ios_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'ios_idx_db',
    commandSpec => '{ "find": "ios_coll", "filter": { "a": "v1" }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "batchSize": 5, "hint": "idx_abc_ada" }',
    cursorId => 536);
SELECT continuation AS r1_continuation FROM ios_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('ios_idx_db',
        '{ "getMore": { "$numberLong": "536" }, "collection": "ios_coll", "batchSize": 5 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE ios_explain_resp;

-- ===========================================================================
-- 2-path ASC+ASC {a:1, b:1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 1, "hint": "idx_ab_aa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 2, "hint": "idx_ab_aa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "idx_ab_aa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "idx_ab_aa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- 2-path ASC+DESC {a:1, b:-1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 1, "hint": "idx_ab_ad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 2, "hint": "idx_ab_ad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "idx_ab_ad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "idx_ab_ad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- 2-path DESC+ASC {a:-1, b:1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 1, "hint": "idx_ab_da"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 2, "hint": "idx_ab_da"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "idx_ab_da"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "idx_ab_da"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- 2-path DESC+DESC {a:-1, b:-1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 1, "hint": "idx_ab_dd"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 2, "hint": "idx_ab_dd"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "idx_ab_dd"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "idx_ab_dd"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- 3-path ASC+ASC+ASC {a:1, b:1, c:1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 1, "hint": "idx_abc_aaa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 2, "hint": "idx_abc_aaa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "idx_abc_aaa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "idx_abc_aaa"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- 3-path ASC+DESC+ASC {a:1, b:-1, c:1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 1, "hint": "idx_abc_ada"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 2, "hint": "idx_abc_ada"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "idx_abc_ada"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "idx_abc_ada"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- 3-path ASC+ASC+DESC {a:1, b:1, c:-1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 1, "hint": "idx_abc_aad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 2, "hint": "idx_abc_aad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "idx_abc_aad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "idx_abc_aad"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- 3-path ASC+DESC+DESC {a:1, b:-1, c:-1}
-- ===========================================================================
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 1, "hint": "idx_abc_add"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 1}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 2, "hint": "idx_abc_add"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 2}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "idx_abc_add"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 5}');
EXECUTE drain_ios(
    '{"find": "ios_coll", "filter": {"a": "v1"}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "idx_abc_add"}',
    '{"getMore": {"$numberLong": "536"}, "collection": "ios_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary tests: first column has 2 distinct values ("v1" and "v2"),
-- each covering 50% of rows. No equality filter on the first column, so the
-- scan traverses all 36 docs and crosses the first-column boundary mid-batch.
-- ===========================================================================

-- Data: 36 docs total. a in {"v1","v2"}, b in {1..3}, c in {1..6} per (a,b).
SELECT documentdb_api.insert_one('ios_idx_db', 'ios_cross_coll',
    FORMAT('{ "a": "v%s", "b": %s, "c": %s }',
           ((i - 1) / 18) + 1,
           (((i - 1) % 18) / 6) + 1,
           ((i - 1) % 6) + 1
    )::documentdb_core.bson)
FROM generate_series(1, 36) AS i;

ANALYZE;

-- 2-path indexes (all direction combos)
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": 1, "b": 1}, "name": "xidx_ab_aa"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": 1, "b": -1}, "name": "xidx_ab_ad"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": -1, "b": 1}, "name": "xidx_ab_da"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": -1, "b": -1}, "name": "xidx_ab_dd"}]}', true);

-- 3-path indexes (mixed directions)
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": 1, "b": 1, "c": 1}, "name": "xidx_abc_aaa"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": 1, "b": -1, "c": 1}, "name": "xidx_abc_ada"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": -1, "b": 1, "c": -1}, "name": "xidx_abc_dad"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ios_idx_db',
    '{"createIndexes": "ios_cross_coll", "indexes": [{"key": {"a": -1, "b": -1, "c": -1}, "name": "xidx_abc_ddd"}]}', true);

-- Drain helper for cross-boundary collection (no filter → scans all 36 docs).
-- 36 docs total:
--   batchSize=5 → 8 pages (5+5+5+5+5+5+5+1), crosses at page 4
--   batchSize=8 → 5 pages (8+8+8+8+4), crosses at page 3
PREPARE drain_cross(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation
          FROM find_cursor_first_page(database => 'ios_idx_db',
                                      commandSpec => $1, cursorId => 537)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation
          FROM cte,
               cursor_get_more(database => 'ios_idx_db',
                               getMoreSpec => $2,
                               continuationSpec => cte.continuation) gm
         WHERE cte.continuation IS NOT NULL
    )
    SELECT bson_dollar_project(cursorPage,
        '{"batchSize": { "$max": [
            { "$size": { "$ifNull": ["$cursor.firstBatch", []]}},
            { "$size": { "$ifNull": ["$cursor.nextBatch", []]}}
          ]}}')
      FROM cte);

-- ---------------------------------------------------------------------------
-- Cross-boundary EXPLAIN: DESC+ASC+DESC {a:-1, b:1, c:-1} first page + getMore
-- ---------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('ios_idx_db',
        '{ "find": "ios_cross_coll", "filter": { "a": { "$gte": "v1" } }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "batchSize": 5, "hint": "xidx_abc_dad" }');
$cmd$, true);

CREATE TEMP TABLE ios_cross_explain_resp AS
SELECT cursorPage, continuation FROM find_cursor_first_page(
    database => 'ios_idx_db',
    commandSpec => '{ "find": "ios_cross_coll", "filter": { "a": { "$gte": "v1" } }, "projection": { "a": 1, "b": 1, "c": 1, "_id": 0 }, "batchSize": 5, "hint": "xidx_abc_dad" }',
    cursorId => 537);
SELECT continuation AS r1_continuation FROM ios_cross_explain_resp \gset

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_getmore('ios_idx_db',
        '{ "getMore": { "$numberLong": "537" }, "collection": "ios_cross_coll", "batchSize": 5 }', $cmd$ || quote_literal(:'r1_continuation') || $cmd$::documentdb_core.bson);
$cmd$, true);
DROP TABLE ios_cross_explain_resp;

-- ===========================================================================
-- Cross-boundary 2-path ASC+ASC {a:1, b:1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_ab_aa"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_ab_aa"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary 2-path ASC+DESC {a:1, b:-1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_ab_ad"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_ab_ad"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary 2-path DESC+ASC {a:-1, b:1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_ab_da"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_ab_da"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary 2-path DESC+DESC {a:-1, b:-1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_ab_dd"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_ab_dd"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary 3-path ASC+ASC+ASC {a:1, b:1, c:1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_abc_aaa"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_abc_aaa"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary 3-path ASC+DESC+ASC {a:1, b:-1, c:1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_abc_ada"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_abc_ada"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary 3-path DESC+ASC+DESC {a:-1, b:1, c:-1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_abc_dad"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_abc_dad"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');

-- ===========================================================================
-- Cross-boundary 3-path DESC+DESC+DESC {a:-1, b:-1, c:-1}
-- ===========================================================================
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 5, "hint": "xidx_abc_ddd"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 5}');
EXECUTE drain_cross(
    '{"find": "ios_cross_coll", "filter": {"a": {"$gte": "v1"}}, "projection": {"a": 1, "b": 1, "c": 1, "_id": 0}, "batchSize": 8, "hint": "xidx_abc_ddd"}',
    '{"getMore": {"$numberLong": "537"}, "collection": "ios_cross_coll", "batchSize": 8}');
