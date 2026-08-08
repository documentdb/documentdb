SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 43000;
SET citus.next_shard_id TO 4300000;
SET documentdb.next_collection_index_id TO 43000;

-- ===========================================================================
-- Regression: $collStats gathers worker statistics by fanning out through
-- run_command_on_all_nodes, and resolves its collection from the collections
-- reference table. When the enclosing aggregation is already running as a
-- distributed task on a worker (for example a $collStats sub-pipeline in
-- $lookup / $unionWith, or a $collStats run after a write in the same
-- transaction), those steps are nested distributed executions and must be
-- explicitly allowed. Placing the collection entirely on a worker node forces
-- the enclosing query onto a shard so the nested path is exercised.
--
-- The output deliberately avoids the collStats "count", whose value is derived
-- from per-node table statistics and therefore varies with the cluster
-- topology. This test only asserts that the nested $collStats runs without the
-- "query on a shard" error, so the projections emit topology-independent shapes.
-- ===========================================================================

SELECT documentdb_api.drop_collection('collstats_nd_db', 'nd_coll');

SELECT COUNT(documentdb_api.insert_one('collstats_nd_db', 'nd_coll',
    FORMAT('{ "_id": %s, "a": %s }', i, i)::documentdb_core.bson))
FROM generate_series(1, 10) AS i;

ANALYZE;

CALL documentdb_distributed_test_helpers.place_collection_on_node('collstats_nd_db', 'nd_coll', 1);

-- $collStats in a $lookup sub-pipeline: the outer query runs on the worker that
-- holds the collection, so the sub-pipeline's $collStats resolves its catalog
-- entry and gathers worker statistics from that on-shard context.
SELECT document FROM bson_aggregation_pipeline('collstats_nd_db', '{ "aggregate": "nd_coll", "pipeline": [
    { "$lookup": { "from": "nd_coll", "pipeline": [
        { "$collStats": { "count": {} } } ], "as": "stats" } },
    { "$match": { "_id": 1 } },
    { "$project": { "_id": 0, "collstats_ran": { "$gt": [ { "$size": "$stats" }, 0 ] } } } ] }');

-- $collStats in a $unionWith sub-pipeline from an on-shard context. Both the
-- main and the sub-pipeline $collStats must run; the literal marks which is which.
SELECT document FROM bson_aggregation_pipeline('collstats_nd_db', '{ "aggregate": "nd_coll", "pipeline": [
    { "$collStats": { "count": {} } },
    { "$project": { "_id": 0, "src": { "$literal": "main" } } },
    { "$unionWith": { "coll": "nd_coll", "pipeline": [
        { "$collStats": { "count": {} } },
        { "$project": { "_id": 0, "src": { "$literal": "union" } } } ] } } ] }');

-- $collStats after a write in the same transaction: the write establishes a
-- distributed execution context before the $collStats fan-out.
BEGIN;
SELECT documentdb_api.insert_one('collstats_nd_db', 'nd_coll', '{ "_id": 11, "a": 11 }');
SELECT document FROM bson_aggregation_pipeline('collstats_nd_db', '{ "aggregate": "nd_coll", "pipeline": [
    { "$collStats": { "count": {} } },
    { "$project": { "_id": 0, "ns": 1 } } ] }');
ROLLBACK;

SELECT documentdb_api.drop_collection('collstats_nd_db', 'nd_coll');
