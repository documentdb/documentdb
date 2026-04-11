SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core;
SET documentdb.next_collection_id TO 6700;
SET documentdb.next_collection_index_id TO 6700;

SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 1, "a": { "b": 1, "c": 1} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 2, "a": { "b": 1, "c": 2} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 3, "a": { "b": 1, "c": 3} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 4, "a": { "b": 2, "c": 1} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 5, "a": { "b": 2, "c": 2} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 6, "a": { "b": 2, "c": 3} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 7, "a": { "b": 3, "c": 1} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 8, "a": { "b": 3, "c": 2} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group_exp','{ "_id": 9, "a": { "b": 3, "c": 3} }', NULL);

-- test non projection for const expressions
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "1", "c": { "$count": {} }}}]}');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": 1, "c": { "$sum": 10 }}}]}');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": 1, "c": { "$max": 10 }}}]}');

SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": 1, "c": { "$sum": 10 }}}]}');
SET documentdb.enableNewWithExprAccumulators TO off;

SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": 1, "c": { "$max": 10 }}}]}');
SET documentdb.enableNewWithExprAccumulators TO off;

-- test where only some are non-const
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": 1, "c": { "$max": "$a" }}}]}');

SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": 1, "c": { "$max": "$a" }}}]}');
SET documentdb.enableNewWithExprAccumulators TO off;

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "$a", "c": { "$count": {} }}}]}');

-- both are non const
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "$a", "c": { "$max": "$b" }}}]}');

SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "$a", "c": { "$max": "$b" }}}]}');
SET documentdb.enableNewWithExprAccumulators TO off;

-- $sum with non-const expression
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "$a", "c": { "$sum": "$b" }}}]}');

SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "$a", "c": { "$sum": "$b" }}}]}');
SET documentdb.enableNewWithExprAccumulators TO off;

-- $avg with non-const expression
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "$a", "c": { "$avg": "$b" }}}]}');

SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group_exp", "pipeline": [ { "$group": { "_id": "$a", "c": { "$avg": "$b" }}}]}');
SET documentdb.enableNewWithExprAccumulators TO off;

-- Subquery elimination EXPLAIN tests (using $documents so no collection setup needed)

-- Non-constant _id: subquery eliminated (no Subquery Scan)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": 1, "pipeline": [ { "$documents": [ { "a": 1 }, { "a": 2 } ] }, { "$group": { "_id": "$a", "c": { "$count": {} } } } ], "cursor": {}}');

-- Constant _id: subquery eliminated
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": 1, "pipeline": [ { "$documents": [ { "a": 1 }, { "a": 2 } ] }, { "$group": { "_id": "1", "c": { "$count": {} } } } ], "cursor": {}}');

-- Legacy path with enableGroupSubqueryElimination = off (should show Subquery Scan)
SET documentdb.enableGroupSubqueryElimination TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": 1, "pipeline": [ { "$documents": [ { "a": 1 }, { "a": 2 } ] }, { "$group": { "_id": "$a", "c": { "$count": {} } } } ], "cursor": {}}');
SET documentdb.enableGroupSubqueryElimination TO on;
