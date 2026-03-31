SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 860000;
SET documentdb.next_collection_id TO 8600;
SET documentdb.next_collection_index_id TO 8600;


-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

set documentdb.defaultUseCompositeOpClass to on;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'group_idx_db', '{ "createIndexes": "group_push", "indexes": [ { "name": "a_1", "key": { "a": 1 } }, { "name": "b_c_1", "key": { "b": 1, "c": 1 } } ] }', TRUE);

SELECT COUNT(documentdb_api.insert_one('group_idx_db', 'group_push', bson_build_document('_id', i, 'a', i % 100, 'b', i % 10, 'c', i) )) FROM generate_series(1, 1000) AS i;

ANALYZE documentdb_data.documents_8601;

set enable_seqscan to off;
set enable_bitmapscan to off;

-- push basic group to the index.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- works with filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "a": { "$exists": true } } }, { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');

-- works with suffix filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- equality with group suffix works.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": 10 } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }');


---------------------------------------------------------------------------------------------------
-- these scenarios don't work (even though they should).
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b" }, "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-- same with filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-----------------------------------------------------------------------------------------------------
-- these don't work:
-- does not work with inequality prefix
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": { "$exists": true } } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }');

-- insert an array breaks pushdown
SELECT documentdb_api.insert_one('group_idx_db', 'group_push', '{ "_id": 1001, "a": [ 1, 2, 3 ], "b": [ 1, 2, 3 ], "c": 1 }' );

-- can no longer push down.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

TRUNCATE documentdb_data.documents_8601;
SELECT COUNT(documentdb_api.insert_one('group_idx_db', 'group_push', bson_build_document('_id', i, 'a', i % 100, 'b', i % 10, 'c', i) )) FROM generate_series(1, 1000) AS i;

-----------------------------------------------------------------------------------------------------
-- shard and try again
SELECT documentdb_api.shard_collection('{ "shardCollection": "group_idx_db.group_push", "key": { "_id": "hashed" } }');

-- the ones that work should work
BEGIN;
set local enable_seqscan to off;
set enable_bitmapscan to off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- works with filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "a": { "$exists": true } } }, { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');

-- works with suffix filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- equality with group suffix works.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": 10 } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }');

ROLLBACK;