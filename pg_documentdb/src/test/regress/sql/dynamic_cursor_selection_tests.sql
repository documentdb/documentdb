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
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "skip": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "skip": 2 }');

-- Scenario 7: Find with sort only (non-streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 } }');

-- Scenario 8: Find with limit only (non-streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "limit": 3 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "limit": 3 }');

-- Scenario 9: Find with sort + limit (non-streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "limit": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "limit": 2 }');

-- Scenario 10: Find with sort + skip + limit (non-streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "skip": 1, "limit": 2 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "sort": { "a": 1 }, "skip": 1, "limit": 2 }');

-- Scenario 11: Find with filter + skip (non-streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "skip": 1 }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": 1 }, "skip": 1 }');

-- Scenario 12: Find with filter + sort (non-streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gt": 1 } }, "sort": { "a": 1 } }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('dyncurdb', '{ "find": "dyncoll", "filter": { "a": { "$gt": 1 } }, "sort": { "a": 1 } }');

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
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$skip": 2 }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$skip": 2 }], "cursor": {} }');

-- Stage: $sort (non-streamable - RequiresPersistentCursorTrue)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sort": { "a": 1 } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$sort": { "a": 1 } }], "cursor": {} }');

-- Stage: $group (non-streamable - RequiresPersistentCursorTrue)
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

-- Stage: $redact (non-streamable - RequiresPersistentCursorTrue)
-- Note: Dynamic cursors produces DocumentDBApiCursorScan but streaming does not
-- produce DocumentDBApiScan. $redact should be streaming enabled; the streaming
-- cursor path is missing the equivalent DocumentDBApiScan wrapper.
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

-- Stage: $_internalInhibitOptimization (non-streamable - RequiresPersistentCursorTrue)
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
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }, { "$sort": { "a": -1 } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": 1 } }, { "$sort": { "a": -1 } }], "cursor": {} }');

-- Combined: $match + $group (non-streamable due to $group)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$group": { "_id": "$a" } }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$match": { "a": { "$gte": 1 } } }, { "$group": { "_id": "$a" } }], "cursor": {} }');

-- Combined: $project + $unset (both streamable, pipeline should remain streamable)
SET documentdb.enableDynamicCursors TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$project": { "a": 1, "b": 1 } }, { "$unset": "b" }], "cursor": {} }');
SET documentdb.enableDynamicCursors TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('dyncurdb', '{ "aggregate": "dyncoll", "pipeline": [{ "$project": { "a": 1, "b": 1 } }, { "$unset": "b" }], "cursor": {} }');

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
-- Aggregation stages pending testing:
--   $changeStream      — requires change stream infrastructure
--   $inverseMatch      — internal stage with special path parameter
--   $listLocalSessions — not supported in native pipeline
--   $listSessions      — not supported in native pipeline
--   $searchMeta        — not supported yet in native pipeline
-- ============================================================================
