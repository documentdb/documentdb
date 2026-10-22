-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

-- ============================================================================
-- Dynamic Cursor Selection Tests
-- ============================================================================
--
-- This test validates which query shapes are streamable (use dynamic cursors)
-- vs non-streamable (use persistent cursors). The table below summarizes all
-- scenarios and their current/desired streamability status.
--
-- Legend:
--   Streamable     = uses DocumentDBApiCursorScan (dynamic cursor)
--   Non-streamable = uses DocumentDBApiScan (persistent cursor)
--   TODO           = currently non-streamable, but should be made streamable
--
-- +----------+------------------------------------------+-----------------+------------------------------------------+
-- | Scenario | Description                              | Status          | Notes                                    |
-- +----------+------------------------------------------+-----------------+------------------------------------------+
-- | 1        | Simple find (no filter)                  | Streamable      |                                          |
-- | 2        | Find with equality filter                | Streamable      |                                          |
-- | 3        | Find with range filter                   | Streamable      |                                          |
-- | 4        | Find with projection                    | Streamable      |                                          |
-- | 5        | Find with filter + projection            | Streamable      |                                          |
-- | 6        | Find with skip                           | Non-streamable  | TODO: track skip offset in continuation  |
-- | 7        | Find with sort (indexed field)           | Non-streamable  | TODO: push sort to index                 |
-- | 8        | Find with limit                          | Non-streamable  | TODO: track limit in continuation        |
-- | 9        | Find with sort + limit                   | Non-streamable  | TODO: push sort to index                 |
-- | 10       | Find with sort + skip + limit            | Non-streamable  | TODO: push sort to index                 |
-- | 11       | Find with filter + skip                  | Non-streamable  | TODO: track skip offset in continuation  |
-- | 12       | Find with filter + sort                  | Non-streamable  | TODO: push sort to index                 |
-- | 13       | Find with filter + limit                 | Non-streamable  | TODO: track limit in continuation        |
-- | 14       | Find with filter + sort + limit          | Non-streamable  | TODO: push sort to index                 |
-- | 15       | Find with filter + skip + limit          | Non-streamable  | TODO: track skip/limit in continuation   |
-- | 16       | Find with sort + skip (no limit)         | Non-streamable  | TODO: push sort to index                 |
-- +----------+------------------------------------------+-----------------+------------------------------------------+
--
-- Aggregation Pipeline Stages:
-- +----------+------------------------------------------+-----------------+------------------------------------------+
-- | Stage    | Description                              | Status          | Notes                                    |
-- +----------+------------------------------------------+-----------------+------------------------------------------+
-- | $match   | Filter stage                             | Streamable      |                                          |
-- | $addFlds | Add/compute fields                       | Streamable      |                                          |
-- | $project | Field projection                         | Streamable      |                                          |
-- | $set     | Set fields (alias of $addFields)         | Streamable      |                                          |
-- | $unset   | Remove fields                            | Streamable      |                                          |
-- | $replace | Replace root/with                        | Streamable      |                                          |
-- | $unionW  | Union with another collection            | Non-streamable  |                                          |
-- | $limit=1 | Single-row limit                         | Streamable      |                                          |
-- | $skip=0  | No-op skip                               | Streamable      |                                          |
-- | $limit>1 | Multi-row limit                          | Non-streamable  | TODO: track remaining limit              |
-- | $skip>0  | Non-zero skip                            | Non-streamable  | TODO: track skip offset                  |
-- | $sort    | Sort stage                               | Non-streamable  | TODO: push sort to index                 |
-- | $group   | Group/aggregate stage                    | Non-streamable  | TODO: index-pushed distinct-style group  |
-- | $sortGrp | $sort + $group optimization              | Non-streamable  | TODO: push sort+group to index           |
-- | $unwind  | Array unwind                             | Non-streamable  |                                          |
-- | $lookup  | Join with another collection             | Non-streamable  |                                          |
-- | $bucket  | Bucket grouping                          | Non-streamable  |                                          |
-- | $sortCnt | Sort by count                            | Non-streamable  |                                          |
-- | $sample  | Random sample                            | Non-streamable  |                                          |
-- | $count   | Count documents                          | Non-streamable  |                                          |
-- | $facet   | Multi-faceted aggregation                | Non-streamable  |                                          |
-- | $redact  | Field-level redaction                    | Streamable      |                                          |
-- | $bktAuto | Auto-bucketing                           | Non-streamable  |                                          |
-- | $densify | Densify time series                      | Non-streamable  |                                          |
-- | $fill    | Fill missing values                      | Non-streamable  |                                          |
-- | $graphLk | Graph lookup                             | Non-streamable  |                                          |
-- | $setWFld | Set window fields                        | Non-streamable  |                                          |
-- | $collSts | Collection stats                         | Non-streamable  |                                          |
-- | $docs    | Documents stage                          | Non-streamable  |                                          |
-- | $inhibit | Inhibit optimization                     | Streamable      | CTE wraps streaming inner scan           |
-- | $search  | Vector/text search                       | Non-streamable  |                                          |
-- | $vecSrch | Vector search                            | Non-streamable  |                                          |
-- | $geoNear | Geospatial near                          | Non-streamable  |                                          |
-- | $idxStat | Index statistics                         | Non-streamable  |                                          |
-- | $merge   | Merge output                             | Non-streamable  |                                          |
-- | $out     | Output to collection                     | Non-streamable  |                                          |
-- | $lkpUnwd | Lookup + unwind optimization             | Non-streamable  |                                          |
-- | $currOp  | Current operations (admin)               | Non-streamable  |                                          |
-- +----------+------------------------------------------+-----------------+------------------------------------------+
--
-- Combined Pipeline Stages:
-- +----------+------------------------------------------+-----------------+------------------------------------------+
-- | Combo    | Description                              | Status          | Notes                                    |
-- +----------+------------------------------------------+-----------------+------------------------------------------+
-- | m+addF   | $match + $addFields                      | Streamable      |                                          |
-- | p+unset  | $project + $unset                        | Streamable      |                                          |
-- | m+sort   | $match + $sort                           | Non-streamable  | TODO: push sort to index                 |
-- | m+group  | $match + $group                          | Non-streamable  | TODO: push group to index                |
-- | m+skip   | $match + $skip                           | Non-streamable  | TODO: track skip in continuation         |
-- | m+limit  | $match + $limit (limit>1)                | Non-streamable  | TODO: track limit in continuation        |
-- | m+s+lim  | $match + $sort + $limit                  | Non-streamable  | TODO: push sort to index                 |
-- +----------+------------------------------------------+-----------------+------------------------------------------+

SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 2600;
SET documentdb.next_collection_index_id TO 2600;

-- Create a test collection and insert sample data
SELECT documentdb_api.insert_one('dyncurdb', 'dyncoll', '{ "_id": 1, "a": 1, "b": "hello" }');
SELECT documentdb_api.insert_one('dyncurdb', 'dyncoll', '{ "_id": 2, "a": 2, "b": "world" }');
SELECT documentdb_api.insert_one('dyncurdb', 'dyncoll', '{ "_id": 3, "a": 3, "b": "test" }');
SELECT documentdb_api.insert_one('dyncurdb', 'dyncoll', '{ "_id": 4, "a": 1, "b": "foo" }');
SELECT documentdb_api.insert_one('dyncurdb', 'dyncoll', '{ "_id": 5, "a": 2, "b": "bar" }');

-- Create a secondary index on field 'a'
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncurdb', '{ "createIndexes": "dyncoll", "indexes": [{ "key": { "a": 1 }, "name": "idx_a" }] }', true);

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

------------------------------------------------------------
-- For each query scenario we run EXPLAIN twice:
--   1) with enableDynamicCursors = on  (expect DocumentDBApiCursorScan when streamable)
--   2) with enableDynamicCursors = off (expect DocumentDBApiScan when streamable)
-- Queries that are streamable should show a cursor wrapper in both modes.
-- Queries that are non-streamable should show no cursor wrapper in both modes.
------------------------------------------------------------

-- Scenario 1: Simple find with no filter (streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll" }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll" }');

-- Scenario 2: Find with equality filter (streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 } }');

-- Scenario 3: Find with range filter on indexed field (streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gt": 1 } } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gt": 1 } } }');

-- Scenario 4: Find with projection (streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "projection": { "a": 1 } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "projection": { "a": 1 } }');

-- Scenario 5: Find with filter and projection (streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "projection": { "b": 1 } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "projection": { "b": 1 } }');

-- Scenario 6: Find with skip only (non-streamable)
-- TODO: skip should be streamable with dynamic cursors when the skip offset
-- can be tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "skip": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "skip": 2 }');

-- Scenario 7: Find with sort only (non-streamable)
-- TODO: sort on an indexed field should be streamable with dynamic cursors
-- when the sort order matches the index order (index-pushed sort).
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 } }');

-- Scenario 8: Find with limit only (non-streamable)
-- TODO: limit should be streamable with dynamic cursors when the limit count
-- can be tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "limit": 3 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "limit": 3 }');

-- Scenario 9: Find with sort + limit (non-streamable)
-- TODO: sort + limit should be streamable when the sort is pushed to an index.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "limit": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "limit": 2 }');

-- Scenario 10: Find with sort + skip + limit (non-streamable)
-- TODO: sort + skip + limit should be streamable when the sort is pushed to an index.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "skip": 1, "limit": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "skip": 1, "limit": 2 }');

-- Scenario 11: Find with filter + skip (non-streamable)
-- TODO: filter + skip should be streamable when skip offset is tracked in continuation.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "skip": 1 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "skip": 1 }');

-- Scenario 12: Find with filter + sort (non-streamable)
-- TODO: filter + sort should be streamable when the sort is pushed to an index.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gt": 1 } }, "sort": { "a": 1 } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gt": 1 } }, "sort": { "a": 1 } }');

-- Scenario 13: Find with filter + limit (non-streamable)
-- TODO: filter + limit should be streamable when the limit count is tracked
-- in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gte": 1 } }, "limit": 3 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gte": 1 } }, "limit": 3 }');

-- Scenario 14: Find with filter + sort + limit (non-streamable)
-- TODO: filter + sort + limit should be streamable when the sort is pushed
-- to an index and limit is tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gte": 1 } }, "sort": { "a": -1 }, "limit": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gte": 1 } }, "sort": { "a": -1 }, "limit": 2 }');

-- Scenario 15: Find with filter + skip + limit (non-streamable)
-- TODO: filter + skip + limit should be streamable when skip and limit are
-- tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "skip": 1, "limit": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "skip": 1, "limit": 2 }');

-- Scenario 16: Find with sort + skip (non-streamable)
-- TODO: sort + skip should be streamable when the sort is pushed to an index
-- and skip offset is tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "skip": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "skip": 2 }');

------------------------------------------------------------
-- Query output correctness tests with dynamic cursors enabled.
-- Validate that the actual query results are correct.
-- ERROR: Queries that use DocumentDBApiCursorScan (streamable queries
-- without limit) crash the server at runtime. Only non-streamable
-- queries (with limit) can be tested for output correctness currently.
------------------------------------------------------------
SET documentdb.enableDynamicCursors TO on;

-- Output 1: Limit (non-streamable, no CursorScan - works)
SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "limit": 2 }');

-- Output 2: Sort + limit (non-streamable, no CursorScan - works)
SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "limit": 2 }');

-- Output 3: Filter + sort + limit (non-streamable, no CursorScan - works)
SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gte": 1 } }, "sort": { "a": -1 }, "limit": 3 }');

-- Output 4: Sort + skip + limit (non-streamable, no CursorScan - works)
SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "skip": 1, "limit": 2 }');

------------------------------------------------------------
-- Aggregation pipeline stage tests.
-- For each testable aggregation stage, run EXPLAIN with dynamic
-- cursors on and off to verify the streaming cursor state matches.
-- Stages with requiresPersistentCursor=False should be streamable.
-- Stages with requiresPersistentCursor=True should be non-streamable.
------------------------------------------------------------

-- Also create a second collection for $lookup tests
SELECT documentdb_api.insert_one('dyncurdb', 'lookup_coll', '{ "_id": 1, "x": 1 }');
SELECT documentdb_api.insert_one('dyncurdb', 'lookup_coll', '{ "_id": 2, "x": 2 }');

-- Stage: $match (streamable - RequiresPersistentCursorFalse)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }], "cursor": {} }');

-- Stage: $addFields (streamable - RequiresPersistentCursorFalse)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$addFields": { "c": 1 } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$addFields": { "c": 1 } }], "cursor": {} }');

-- Stage: $project (streamable - RequiresPersistentCursorFalse)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$project": { "a": 1 } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$project": { "a": 1 } }], "cursor": {} }');

-- Stage: $set (streamable - RequiresPersistentCursorFalse, same as $addFields)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$set": { "d": "val" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$set": { "d": "val" } }], "cursor": {} }');

-- Stage: $unset (streamable - RequiresPersistentCursorFalse)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$unset": "b" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$unset": "b" }], "cursor": {} }');

-- Stage: $replaceRoot (streamable - RequiresPersistentCursorFalse)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$replaceRoot": { "newRoot": { "val": "$a" } } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$replaceRoot": { "newRoot": { "val": "$a" } } }], "cursor": {} }');

-- Stage: $replaceWith (streamable - RequiresPersistentCursorFalse)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$replaceWith": { "val": "$a" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$replaceWith": { "val": "$a" } }], "cursor": {} }');

-- Stage: $limit with limit=1 (streamable - RequiresPersistentCursorLimit returns false for limit=1)
-- Note: Dynamic cursors produces DocumentDBApiCursorScan but streaming does not
-- produce DocumentDBApiScan. This is valid because limit=1 is a single-row result
-- that the dynamic cursor path can handle directly.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$limit": 1 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$limit": 1 }], "cursor": {} }');

-- Stage: $limit with limit>1 (non-streamable - RequiresPersistentCursorLimit returns true)
-- TODO: $limit with limit>1 should be streamable when the remaining limit count
-- is tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$limit": 5 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$limit": 5 }], "cursor": {} }');

-- Stage: $skip with skip=0 (streamable - RequiresPersistentCursorSkip returns false for skip=0)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$skip": 0 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$skip": 0 }], "cursor": {} }');

-- Stage: $skip with skip>0 (non-streamable - RequiresPersistentCursorSkip returns true)
-- TODO: $skip with skip>0 should be streamable when the skip offset is tracked
-- in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$skip": 2 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$skip": 2 }], "cursor": {} }');

-- Stage: $sort (non-streamable - RequiresPersistentCursorTrue)
-- TODO: $sort should be streamable when the sort order matches an index
-- (index-pushed sort).
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sort": { "a": 1 } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sort": { "a": 1 } }], "cursor": {} }');

-- Stage: $group (non-streamable - RequiresPersistentCursorTrue)
-- TODO: $group should be streamable when the group key matches an index
-- (index-pushed distinct-style group).
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$group": { "_id": "$a", "count": { "$sum": 1 } } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$group": { "_id": "$a", "count": { "$sum": 1 } } }], "cursor": {} }');

set enable_seqscan to off;
SET documentdb.enableDynamicCursors TO on;
SELECT documentdb_test_helpers.explain_uses_index_only_scan($Q$ SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "_id": { "$gt": 0 } } }, { "$group": { "_id": null, "count": { "$sum": 1 } } }], "cursor": {} }') $Q$) AS uses_index_only_scan;
SET documentdb.enableDynamicCursors TO off;
SELECT documentdb_test_helpers.explain_uses_index_only_scan($Q$ SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "_id": { "$gt": 0 } } }, { "$group": { "_id": null, "count": { "$sum": 1 } } }], "cursor": {} }') $Q$) AS uses_index_only_scan;
reset enable_seqscan;

-- Stage: $unwind (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$unwind": "$b" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$unwind": "$b" }], "cursor": {} }');

-- Stage: $lookup (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$lookup": { "from": "lookup_coll", "localField": "a", "foreignField": "x", "as": "joined" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$lookup": { "from": "lookup_coll", "localField": "a", "foreignField": "x", "as": "joined" } }], "cursor": {} }');

-- Stage: $bucket (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$bucket": { "groupBy": "$a", "boundaries": [0, 2, 4], "default": "other" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$bucket": { "groupBy": "$a", "boundaries": [0, 2, 4], "default": "other" } }], "cursor": {} }');

-- Stage: $sortByCount (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sortByCount": "$a" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sortByCount": "$a" }], "cursor": {} }');

-- Stage: $sample with cursor tracker remains eligible for TABLESAMPLE
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sample": { "size": 2 } }], "cursor": {} }');

-- An empty match remains eligible for TABLESAMPLE.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": {} }, { "$sample": { "size": 2 } }], "cursor": {} }');

-- A user filter remains ineligible for TABLESAMPLE.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }, { "$sample": { "size": 2 } }], "cursor": {} }');

-- Disabling sample scan pushdown restores reservoir sampling.
SET documentdb.enable_sample_scan_pushdown_for_dynamic_cursor TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sample": { "size": 2 } }], "cursor": {} }');

-- An empty match also restores reservoir sampling when pushdown is disabled.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": {} }, { "$sample": { "size": 2 } }], "cursor": {} }');

-- The flag does not affect sampling when dynamic cursors are disabled.
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sample": { "size": 2 } }], "cursor": {} }');
RESET documentdb.enable_sample_scan_pushdown_for_dynamic_cursor;

-- Verify cursor execution succeeds and returns the complete sample.
SET documentdb.enableDynamicCursors TO on;
SELECT persistconnection,
       continuation IS NULL AS fully_drained,
       bson_dollar_project(cursorpage, '{ "_id": 0, "batchCount": { "$size": "$cursor.firstBatch" } }') AS result
FROM aggregate_cursor_first_page(
    'dyncurdb',
    '{ "aggregate": "dyncoll", "pipeline": [{ "$sample": { "size": 2 } }], "cursor": { "batchSize": 10 } }',
    2601);

SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sample": { "size": 2 } }], "cursor": {} }');

-- Stage: $count (non-streamable - RequiresPersistentCursorTrueSingleRow)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$count": "total" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$count": "total" }], "cursor": {} }');

-- Stage: $facet (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$facet": { "byA": [{ "$match": { "a": 1 } }] } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$facet": { "byA": [{ "$match": { "a": 1 } }] } }], "cursor": {} }');

-- Stage: $redact (streamable - RequiresPersistentCursorFalse)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$redact": "$$KEEP" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$redact": "$$KEEP" }], "cursor": {} }');

-- Stage: $bucketAuto (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$bucketAuto": { "groupBy": "$a", "buckets": 2 } }], "cursor": {} }')
$cmd$, p_normalize_window := true);
SET documentdb.enableDynamicCursors TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$bucketAuto": { "groupBy": "$a", "buckets": 2 } }], "cursor": {} }')
$cmd$, p_normalize_window := true);

-- Stage: $densify (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$densify": { "field": "a", "range": { "step": 1, "bounds": "full" } } }], "cursor": {} }')
$cmd$, p_normalize_window := true);
SET documentdb.enableDynamicCursors TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$densify": { "field": "a", "range": { "step": 1, "bounds": "full" } } }], "cursor": {} }')
$cmd$, p_normalize_window := true);

-- Stage: $fill (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$fill": { "sortBy": { "a": 1 }, "output": { "b": { "method": "locf" } } } }], "cursor": {} }')
$cmd$, p_normalize_window := true);
SET documentdb.enableDynamicCursors TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$fill": { "sortBy": { "a": 1 }, "output": { "b": { "method": "locf" } } } }], "cursor": {} }')
$cmd$, p_normalize_window := true);

-- Stage: $graphLookup (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$graphLookup": { "from": "dyncoll", "startWith": "$a", "connectFromField": "a", "connectToField": "_id", "as": "linked" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$graphLookup": { "from": "dyncoll", "startWith": "$a", "connectFromField": "a", "connectToField": "_id", "as": "linked" } }], "cursor": {} }');

-- Stage: $setWindowFields (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$setWindowFields": { "sortBy": { "a": 1 }, "output": { "rank": { "$rank": {} } } } }], "cursor": {} }')
$cmd$, p_normalize_window := true);
SET documentdb.enableDynamicCursors TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$setWindowFields": { "sortBy": { "a": 1 }, "output": { "rank": { "$rank": {} } } } }], "cursor": {} }')
$cmd$, p_normalize_window := true);

-- Stage: $unionWith (non-streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$unionWith": "lookup_coll" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$unionWith": "lookup_coll" }], "cursor": {} }');

-- Stage: $collStats (non-streamable - RequiresPersistentCursorTrueSingleRow)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$collStats": { "storageStats": {} } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$collStats": { "storageStats": {} } }], "cursor": {} }');

-- Stage: $documents (non-streamable - RequiresPersistentCursorTrue, collection-agnostic)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": 1, "pipeline": [{ "$documents": [{ "x": 1 }, { "x": 2 }] }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": 1, "pipeline": [{ "$documents": [{ "x": 1 }, { "x": 2 }] }], "cursor": {} }');

-- Stage: $_internalInhibitOptimization (streamable - CTE wraps a streaming inner scan)
-- The CTE materializes results, but the inner scan still uses DocumentDBApiCursorScan.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$_internalInhibitOptimization": {} }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$_internalInhibitOptimization": {} }], "cursor": {} }');

-- Combined: $match + $addFields (both streamable, pipeline should remain streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }, { "$addFields": { "c": "new" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }, { "$addFields": { "c": "new" } }], "cursor": {} }');

-- Combined: $match + $sort (non-streamable due to $sort)
-- TODO: $match + $sort should be streamable when the sort is pushed to an index.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }, { "$sort": { "a": -1 } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }, { "$sort": { "a": -1 } }], "cursor": {} }');

-- Combined: $match + $group (non-streamable due to $group)
-- TODO: $match + $group should be streamable when the group key can be
-- pushed to an index (index-pushed distinct-style group).
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$group": { "_id": "$a" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$group": { "_id": "$a" } }], "cursor": {} }');

-- Combined: $project + $unset (both streamable, pipeline should remain streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$project": { "a": 1, "b": 1 } }, { "$unset": "b" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$project": { "a": 1, "b": 1 } }, { "$unset": "b" }], "cursor": {} }');

-- Combined: $match + $skip (non-streamable due to $skip)
-- TODO: $match + $skip should be streamable when skip offset is tracked
-- in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$skip": 2 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$skip": 2 }], "cursor": {} }');

-- Combined: $match + $limit with limit>1 (non-streamable due to $limit)
-- TODO: $match + $limit should be streamable when the remaining limit count
-- is tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$limit": 3 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$limit": 3 }], "cursor": {} }');

-- Combined: $match + $sort + $limit (non-streamable due to $sort + $limit)
-- TODO: $match + $sort + $limit should be streamable when the sort is pushed
-- to an index and limit is tracked in the continuation state.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$sort": { "a": 1 } }, { "$limit": 2 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$sort": { "a": 1 } }, { "$limit": 2 }], "cursor": {} }');

-- ============================================================================
-- Section 6: $search and $vectorSearch tests (require vector index)
-- ============================================================================

-- Create collection with vector data
SELECT documentdb_api.insert_one('dyncurdb', 'veccoll', '{ "_id": 1, "v": [1.0, 2.0, 3.0], "a": "hello" }');
SELECT documentdb_api.insert_one('dyncurdb', 'veccoll', '{ "_id": 2, "v": [4.0, 5.0, 6.0], "a": "world" }');
SELECT documentdb_api.insert_one('dyncurdb', 'veccoll', '{ "_id": 3, "v": [7.0, 8.0, 9.0], "a": "test" }');

-- Create vector-ivf index
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncurdb', '{ "createIndexes": "veccoll", "indexes": [{ "key": { "v": "cosmosSearch" }, "name": "vec_idx", "cosmosSearchOptions": { "kind": "vector-ivf", "numLists": 1, "similarity": "COS", "dimensions": 3 } }] }', true);

-- $search (cosmosSearch) — non-streamable (RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "veccoll", "pipeline": [{ "$search": { "cosmosSearch": { "vector": [1.0, 2.0, 3.0], "k": 2, "path": "v" } } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "veccoll", "pipeline": [{ "$search": { "cosmosSearch": { "vector": [1.0, 2.0, 3.0], "k": 2, "path": "v" } } }], "cursor": {} }');

-- $vectorSearch — non-streamable (RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "veccoll", "pipeline": [{ "$vectorSearch": { "queryVector": [1.0, 2.0, 3.0], "limit": 2, "path": "v" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "veccoll", "pipeline": [{ "$vectorSearch": { "queryVector": [1.0, 2.0, 3.0], "limit": 2, "path": "v" } }], "cursor": {} }');

-- ============================================================================
-- Section 7: $geoNear and $indexStats tests
-- ============================================================================

-- Create collection with geo data and 2dsphere index
SELECT documentdb_api.insert_one('dyncurdb', 'geocoll', '{ "_id": 1, "loc": { "type": "Point", "coordinates": [0, 0] } }');
SELECT documentdb_api.insert_one('dyncurdb', 'geocoll', '{ "_id": 2, "loc": { "type": "Point", "coordinates": [1, 1] } }');

-- Create 2dsphere index
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncurdb', '{ "createIndexes": "geocoll", "indexes": [{ "key": { "loc": "2dsphere" }, "name": "geo_idx" }] }', true);

-- $geoNear — non-streamable (RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "geocoll", "pipeline": [{ "$geoNear": { "near": { "type": "Point", "coordinates": [0, 0] }, "distanceField": "dist" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "geocoll", "pipeline": [{ "$geoNear": { "near": { "type": "Point", "coordinates": [0, 0] }, "distanceField": "dist" } }], "cursor": {} }');

-- $indexStats — non-streamable (RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$indexStats": {} }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$indexStats": {} }], "cursor": {} }');

-- ============================================================================
-- Section 8: $merge and $out tests (output stages)
-- ============================================================================

-- $merge — non-streamable (RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$merge": { "into": "merge_output" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$merge": { "into": "merge_output" } }], "cursor": {} }');

-- $out — non-streamable (RequiresPersistentCursorTrue)
-- $out creates the target collection, so we need it to exist first
SELECT documentdb_api.insert_one('dyncurdb', 'out_target', '{ "_id": 0 }');
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$out": "out_target" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$out": "out_target" }], "cursor": {} }');

-- ============================================================================
-- Section 9: Internal combined stages and admin stages
-- ============================================================================

-- $sortGroup (internal optimization: $sort followed by $group) — non-streamable (RequiresPersistentCursorTrue)
-- TODO: $sortGroup should be streamable when the sort+group can be pushed to an index.
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sort": { "a": 1 } }, { "$group": { "_id": "$a", "count": { "$sum": 1 } } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sort": { "a": 1 } }, { "$group": { "_id": "$a", "count": { "$sum": 1 } } }], "cursor": {} }');

-- $lookupUnwind (internal optimization: $lookup followed by $unwind on the "as" field) — non-streamable (RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$lookup": { "from": "lookup_coll", "localField": "a", "foreignField": "x", "as": "joined" } }, { "$unwind": "$joined" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$lookup": { "from": "lookup_coll", "localField": "a", "foreignField": "x", "as": "joined" } }, { "$unwind": "$joined" }], "cursor": {} }');

-- $currentOp (admin stage) — non-streamable (RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('admin', '{ "aggregate": 1, "pipeline": [{ "$currentOp": {} }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('admin', '{ "aggregate": 1, "pipeline": [{ "$currentOp": {} }], "cursor": {} }');

-- ============================================================================
-- Section 10: Config virtual database queries with dynamic cursors enabled
-- ============================================================================
--
-- Regression test: when dynamic cursors are enabled, the planner must NOT
-- inject the cursor_tracker(document, ...) qual on the base RTE of queries
-- that target the "config" virtual database. Those queries produce a Query
-- whose first RTE is RTE_RELATION pointing at documentdb_api_catalog.collections
-- (or a VALUES / empty rtable for some pseudo-collections), not a real
-- documents_<id> table.
------------------------------------------------------------

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- Ensure there is at least one user database/collection so config.collections
-- and config.chunks produce rows.
SELECT documentdb_api.shard_collection('dyncurdb', 'dyncoll', '{ "_id": "hashed" }', false);

-- config.collections via find — the exact shape that originally failed.
-- Filter to our database so the row set is deterministic regardless of any
-- other databases/collections created by sibling tests in the same regress run.
SELECT document FROM bson_aggregation_find('config', '{ "find": "collections", "filter": { "_id": "dyncurdb.dyncoll" } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('config', '{ "find": "collections", "filter": { "_id": "dyncurdb.dyncoll" } }');

-- Same shape against find_cursor_first_page (the user-facing entrypoint).
-- Use a filter that produces a deterministic, bounded result set so the
-- continuation/cursorPage payload is stable across runs.
SELECT cursorPage IS NOT NULL AS has_page, continuation IS NOT NULL AS has_continuation
    FROM documentdb_api.find_cursor_first_page(
        'config',
        '{ "find": "collections", "filter": { "_id": "dyncurdb.dyncoll" } }');

-- config.databases via find — filter to our database for deterministic output.
SELECT document FROM bson_aggregation_find('config', '{ "find": "databases", "filter": { "_id": "dyncurdb" } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('config', '{ "find": "databases", "filter": { "_id": "dyncurdb" } }');

-- config.chunks via find.
SELECT document FROM bson_aggregation_find('config', '{ "find": "chunks", "filter": { "ns": "dyncurdb.dyncoll" } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('config', '{ "find": "chunks", "filter": { "ns": "dyncurdb.dyncoll" } }');

-- config.settings (RTE_VALUES base) — was not broken, included to lock in coverage.
SELECT document FROM bson_aggregation_find('config', '{ "find": "settings", "sort": { "_id": 1 } }');

-- config.version (NIL rtable) — was not broken, included to lock in coverage.
SELECT document FROM bson_aggregation_find('config', '{ "find": "version" }');

-- Same set of pseudo-collections exercised through the aggregation code path
-- (the second TryAddDynamicCursorQuery call site).
SELECT document FROM bson_aggregation_pipeline('config', '{ "aggregate": "collections", "pipeline": [{ "$match": { "_id": "dyncurdb.dyncoll" } }], "cursor": {} }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('config', '{ "aggregate": "collections", "pipeline": [{ "$match": { "_id": "dyncurdb.dyncoll" } }], "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('config', '{ "aggregate": "databases", "pipeline": [{ "$match": { "_id": "dyncurdb" } }], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('config', '{ "aggregate": "chunks", "pipeline": [{ "$match": { "ns": "dyncurdb.dyncoll" } }], "cursor": {} }');

-- A view-backed find with $near remains non-streamable. The view pipeline
-- forces the find filter through the optimizer-visible synthetic match stage.
SELECT documentdb_api.create_collection_view('dyncurdb', '{ "create": "geoview", "viewOn": "geocoll", "pipeline": [{ "$match": { "_id": { "$gt": 0 } } }] }');
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "geoview", "filter": { "loc": { "$near": { "$geometry": { "type": "Point", "coordinates": [0, 0] } } } } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "geoview", "filter": { "loc": { "$near": { "$geometry": { "type": "Point", "coordinates": [0, 0] } } } } }');
SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "geoview", "filter": { "loc": { "$near": { "$geometry": { "type": "Point", "coordinates": [0, 0] } } } } }');

-- $unwind prevents dynamic streaming, so its persistent fallback must use total
-- cost. Without collection statistics, fast-start planning would leave a
-- selective equality predicate at runtime on an ordered primary-key scan.
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO off;
SET documentdb.defaultUseCompositeOpClass TO off;
SET documentdb.enableCompositeIndexPlanner TO off;
SET documentdb.enableOrderByIdOnCostFunction TO on;
SET documentdb.useFileBasedPersistedCursors TO off;
SET enable_seqscan TO on;
SET max_parallel_workers_per_gather TO 0;
SET cursor_tuple_fraction TO 0.1;

SELECT count(documentdb_api.insert_one('dyncurdb', 'unwind_eq_coll',
    jsonb_build_object('_id', i, 'tag', i % 100, 'items', jsonb_build_array(1, 2),
        'label', CASE WHEN i % 100 = 1 THEN 'MATCH' ELSE 'other' END,
        'padding', repeat(md5(i::text), 4096))::text::documentdb_core.bson))
FROM generate_series(1, 10000) AS documents(i);
SELECT documentdb_api_internal.create_indexes_non_concurrently('dyncurdb',
    '{"createIndexes":"unwind_eq_coll","indexes":[{"key":{"tag":1},"name":"tag_1"}]}', true);
SELECT documentdb_api.compact('{"compact":"unwind_eq_coll","$db":"dyncurdb","mode":"updateStats"}');
SELECT bool_and(pg_column_size(document) < octet_length(document::bytea)) AS compressed
FROM documentdb_api.collection('dyncurdb', 'unwind_eq_coll');

CREATE TEMP TABLE unwind_eq_cursor_results (
    mode text,
    persistent boolean,
    ids integer[],
    items integer[]
);

-- Call first_page outside this helper so its planning is not inside a function.
CREATE FUNCTION pg_temp.drain_unwind_eq_cursor(
    page documentdb_core.bson, continuation documentdb_core.bson, persist_connection boolean)
RETURNS TABLE (persistent boolean, ids integer[], items integer[])
LANGUAGE plpgsql AS $$
DECLARE
    batch jsonb;
BEGIN
    persistent := persist_connection AND (continuation ->> 'qp')::boolean
        AND (continuation ->> 'dc.type') IS NULL;
    ids := '{}';
    items := '{}';
    LOOP
        batch := documentdb_api_catalog.bson_dollar_project(page,
            '{"ids":{"$ifNull":["$cursor.firstBatch._id","$cursor.nextBatch._id"]},
              "items":{"$ifNull":["$cursor.firstBatch.items","$cursor.nextBatch.items"]}}')::text::jsonb;
        ids := ids || ARRAY(SELECT (value ->> '$numberInt')::integer
            FROM jsonb_array_elements(batch -> 'ids'));
        items := items || ARRAY(SELECT (value ->> '$numberInt')::integer
            FROM jsonb_array_elements(batch -> 'items'));
        EXIT WHEN continuation IS NULL;
        SELECT gm.cursorPage, gm.continuation INTO STRICT page, continuation
        FROM documentdb_api.cursor_get_more('dyncurdb',
            '{"getMore":{"$numberLong":"4294967294"},"collection":"unwind_eq_coll","batchSize":1000}',
            continuation) AS gm;
    END LOOP;
    RETURN NEXT;
END;
$$;

-- With statistics disabled, total-cost planning uses tag_1 plus a runtime sort.
SET documentdb.enableDynamicCursors TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}');
$query$);
INSERT INTO unwind_eq_cursor_results
SELECT 'stats_off_dynamic_off', drained.*
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

-- Dynamic fallback must retain the selective plan even with a fast-start fraction.
SET documentdb.enableDynamicCursors TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}');
$query$);
INSERT INTO unwind_eq_cursor_results
SELECT 'stats_off_dynamic_on', drained.*
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

-- Nested SQL rewrites must remain unplanned until the enclosing query is planned.
SELECT count(*) AS nested_rows
FROM (SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}')) AS documents;

-- The fallback must preserve command collation for residual string matching.
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1},"label":"match"}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"collation":{"locale":"en","strength":2},"cursor":{"batchSize":1}}');
$query$);
INSERT INTO unwind_eq_cursor_results
SELECT 'stats_off_dynamic_on_collation', drained.*
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1},"label":"match"}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"collation":{"locale":"en","strength":2},"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;
-- Set operations must not install streaming paths in either collated branch.
-- UNION retains setOperations; simple UNION ALL is flattened into append relations.
SELECT bool_or(line LIKE '%DocumentDBApiCursorScan%') AS union_uses_dynamic_cursor
FROM documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":1,"label":"match"}}],"collation":{"locale":"en","strength":2},"cursor":{}}')
UNION
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":1,"label":"match"}}],"collation":{"locale":"en","strength":2},"cursor":{}}');
$query$) AS plan(line);
SELECT bool_or(line LIKE '%DocumentDBApiCursorScan%') AS union_all_uses_dynamic_cursor
FROM documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":1,"label":"match"}}],"collation":{"locale":"en","strength":2},"cursor":{}}')
UNION ALL
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":1,"label":"match"}}],"collation":{"locale":"en","strength":2},"cursor":{}}');
$query$) AS plan(line);
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;

-- Requesting all rows must select the same persistent plan.
SET cursor_tuple_fraction TO 1;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}');
$query$);
INSERT INTO unwind_eq_cursor_results
SELECT 'stats_off_dynamic_on_all_rows', drained.*
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

-- Without $unwind, the fast-start ordered scan remains streamable. Its
-- continuation must also survive getMore planning and return all matching rows.
SET cursor_tuple_fraction TO 0.1;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$project":{"_id":1,"items":"$tag"}}],"cursor":{"batchSize":1}}');
$query$);
SELECT NOT fp.persistConnection AND (fp.continuation ->> 'dc.type') IS NOT NULL AS dynamic,
       NOT drained.persistent AS not_persistent, cardinality(drained.ids) AS rows,
       drained.ids = ARRAY(SELECT i FROM generate_series(1, 10000) AS documents(i)
           WHERE i % 100 = 1 ORDER BY i) AS correct_ids,
       drained.items = array_fill(1, ARRAY[100]) AS correct_items
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$project":{"_id":1,"items":"$tag"}}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

-- Without dynamic streaming, total-cost planning selects the cheaper bitmap
-- scan. This must not replace the fast-start plan of the streamable query above.
SET documentdb.enableDynamicCursors TO off;
SET cursor_tuple_fraction TO 1;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$project":{"_id":1,"items":"$tag"}}],"cursor":{"batchSize":1}}');
$query$);
SELECT drained.persistent, cardinality(drained.ids) AS rows,
       drained.ids = ARRAY(SELECT i FROM generate_series(1, 10000) AS documents(i)
           WHERE i % 100 = 1 ORDER BY i) AS correct_ids,
       drained.items = array_fill(1, ARRAY[100]) AS correct_items
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$project":{"_id":1,"items":"$tag"}}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

-- Compare other stage shapes against dynamic-off and all-rows controls.
-- Keep the plans visible: a persistent cursor can still retain a fast-start
-- primary-key scan with a residual tag filter instead of using tag_1.
CREATE TEMP TABLE cursor_stage_cases (
    stage text PRIMARY KEY,
    pipeline jsonb,
    extra_id integer
);
INSERT INTO cursor_stage_cases VALUES
('group', '[{"$group":{"_id":"$_id","items":{"$first":"$tag"}}},{"$sort":{"_id":1}}]', NULL),
('lookup', '[{"$lookup":{"from":"lookup_coll","localField":"tag","foreignField":"x","as":"joined"}},
    {"$project":{"_id":1,"items":{"$size":"$joined"}}}]', NULL),
('lookup_unwind', '[{"$lookup":{"from":"lookup_coll","localField":"tag","foreignField":"x","as":"joined"}},
    {"$unwind":"$joined"},{"$project":{"_id":1,"items":"$joined.x"}}]', NULL),
('unionWith', '[{"$project":{"_id":1,"items":"$tag"}},
    {"$unionWith":{"coll":"lookup_coll","pipeline":[{"$match":{"x":1}},
        {"$project":{"_id":{"$literal":-1},"items":"$x"}}]}}]', -1),
('unionWith_group', '[{"$project":{"_id":1,"items":"$tag"}},
    {"$unionWith":{"coll":"lookup_coll","pipeline":[{"$match":{"x":1}},
        {"$group":{"_id":"$x","items":{"$sum":"$x"}}},
        {"$project":{"_id":{"$literal":-1},"items":1}}]}}]', -1),
('facet', '[{"$facet":{"rows":[{"$project":{"_id":1,"items":"$tag"}}]}},
    {"$unwind":"$rows"},{"$replaceWith":"$rows"}]', NULL),
('setWindowFields', '[{"$setWindowFields":{"sortBy":{"_id":1},
    "output":{"items":{"$sum":"$tag","window":{"documents":["current","current"]}}}}},
    {"$project":{"_id":1,"items":1}}]', NULL);

-- Generate top-level first-page calls, not calls inside a helper function.
-- Separate statements keep held cursors outside an implicit transaction block.
-- Union output is unordered, so compare complete ID multisets after getMore.
CREATE TEMP VIEW cursor_stage_statements AS
SELECT cases.stage, mode.name AS mode, statements.ordinal, statements.statement
FROM cursor_stage_cases AS cases
CROSS JOIN (VALUES
    ('dynamic_off', 'off', '0.1'),
    ('dynamic_on', 'on', '0.1'),
    ('dynamic_on_all_rows', 'on', '1')
) AS mode(name, dynamic, fraction)
CROSS JOIN LATERAL (
    SELECT jsonb_build_object('aggregate', 'unwind_eq_coll',
        'pipeline', '[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}}]'::jsonb || cases.pipeline,
        'cursor', '{"batchSize":1}'::jsonb)::text AS spec
) AS command
CROSS JOIN LATERAL (VALUES
    (1, format('SET documentdb.enableDynamicCursors TO %L;', mode.dynamic)),
    (2, format('SET cursor_tuple_fraction TO %L;', mode.fraction)),
    (3, format('SELECT %L AS stage, %L AS mode;', cases.stage, mode.name)),
    (4, format($explain$
SELECT line
FROM documentdb_test_helpers.run_explain_and_trim(%L, p_normalize_window := true) AS plan(line)
WHERE line !~ '^[[:space:]]+Storage: ';
$explain$,
        format('EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline(%L, %L);',
            'dyncurdb', command.spec))),
    (5, format($sql$
SELECT drained.persistent, cardinality(drained.ids) AS rows,
       ARRAY(SELECT id FROM unnest(drained.ids) AS ids(id) ORDER BY id) =
           ARRAY(SELECT id FROM (
               SELECT i AS id FROM generate_series(1, 10000) AS documents(i) WHERE i %% 100 = 1
               UNION ALL SELECT %L::integer WHERE %L::integer IS NOT NULL
           ) AS expected ORDER BY id) AS correct_ids,
       drained.items = array_fill(1, ARRAY[100 + %s]) AS correct_items
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb', %L, 4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;
$sql$, cases.extra_id, cases.extra_id,
        CASE WHEN cases.extra_id IS NULL THEN 0 ELSE 1 END, command.spec))
) AS statements(ordinal, statement);

SELECT statement FROM cursor_stage_statements ORDER BY stage, mode, ordinal
\gexec

-- ANALYZE alone does not enable field selectivity. Enable the collection's
-- statistics explicitly and refresh them before repeating the same query.
SELECT documentdb_api.coll_mod('dyncurdb', 'unwind_eq_coll',
    '{"collMod":"unwind_eq_coll","enableStats":true}');
SELECT documentdb_api.compact('{"compact":"unwind_eq_coll","$db":"dyncurdb","mode":"updateStats"}');
SELECT current_setting('documentdb.enablePerCollectionPlannerStatistics')::boolean AS cluster_statistics_enabled,
       (options ->> 'statsEnabled')::boolean AS statistics_enabled
FROM documentdb_api_catalog.collections
WHERE database_name = 'dyncurdb' AND collection_name = 'unwind_eq_coll';

SET cursor_tuple_fraction TO 0.1;
SET documentdb.enableDynamicCursors TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}');
$query$);
INSERT INTO unwind_eq_cursor_results
SELECT 'stats_on_dynamic_off', drained.*
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

SET documentdb.enableDynamicCursors TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}');
$query$);
INSERT INTO unwind_eq_cursor_results
SELECT 'stats_on_dynamic_on', drained.*
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

SET cursor_tuple_fraction TO 1;
SELECT documentdb_test_helpers.run_explain_and_trim($query$
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_pipeline('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}');
$query$);
INSERT INTO unwind_eq_cursor_results
SELECT 'stats_on_dynamic_on_all_rows', drained.*
FROM documentdb_api.aggregate_cursor_first_page('dyncurdb',
    '{"aggregate":"unwind_eq_coll","pipeline":[{"$match":{"tag":{"$eq":1}}},{"$sort":{"_id":1}},{"$unwind":"$items"}],"cursor":{"batchSize":1}}',
    4294967294) AS fp
CROSS JOIN LATERAL pg_temp.drain_unwind_eq_cursor(fp.cursorPage, fp.continuation, fp.persistConnection) AS drained;

-- Repeat every stage with statistics enabled against the same planning controls.
SELECT statement FROM cursor_stage_statements ORDER BY stage, mode, ordinal
\gexec
DROP VIEW cursor_stage_statements;
DROP TABLE cursor_stage_cases;

SELECT mode, persistent, cardinality(ids) AS rows,
       ids = ARRAY(SELECT i FROM generate_series(1, 10000) AS documents(i),
           generate_series(1, 2) AS elements(item) WHERE i % 100 = 1 ORDER BY i, item) AS correct_ids,
       items = ARRAY(SELECT item FROM generate_series(1, 10000) AS documents(i),
           generate_series(1, 2) AS elements(item) WHERE i % 100 = 1 ORDER BY i, item) AS correct_items
FROM unwind_eq_cursor_results ORDER BY mode;

DROP FUNCTION pg_temp.drain_unwind_eq_cursor(documentdb_core.bson, documentdb_core.bson, boolean);
DROP TABLE unwind_eq_cursor_results;
SELECT documentdb_api.drop_collection('dyncurdb', 'unwind_eq_coll');
RESET cursor_tuple_fraction;
RESET max_parallel_workers_per_gather;
RESET enable_seqscan;
RESET documentdb.useFileBasedPersistedCursors;
RESET documentdb.enableOrderByIdOnCostFunction;
RESET documentdb.enableCompositeIndexPlanner;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enablePerCollectionPlannerStatistics;

-- Reset for any tests that may run after this section.
SET documentdb.enableDynamicCursors TO off;
RESET documentdb.enableCursorsOnAggregationQueryRewrite;

-- ============================================================================
-- Aggregation stages pending testing:
--   $changeStream      — requires change stream infrastructure
--   $inverseMatch      — internal stage with special path parameter
--   $listLocalSessions — not supported in native pipeline
--   $listSessions      — not supported in native pipeline
--   $searchMeta        — not supported yet in native pipeline
-- ============================================================================
