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
-- | $unionW  | Union with another collection            | Streamable      |                                          |
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
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

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

-- Stage: $sample (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sample": { "size": 2 } }], "cursor": {} }');
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

-- Stage: $unionWith (streamable - RequiresPersistentCursorFalseNoSingleRow)
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
