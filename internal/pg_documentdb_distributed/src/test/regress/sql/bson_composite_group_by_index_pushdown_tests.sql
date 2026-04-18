SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 860000;
SET documentdb.next_collection_id TO 8600;
SET documentdb.next_collection_index_id TO 8600;


-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

set documentdb.defaultUseCompositeOpClass to on;
set documentdb.enableGroupByCompoundIdIndexPushdown to on;
set documentdb_core.enableWriteDocumentsInRepath to on;

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
-- single-field document _id pushdown
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b" }, "count": { "$sum": 1 } } } ] }');

-- multi-field document _id pushdown
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-- multi-field with non-indexed field in _id
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "d": "$d" }, "total": { "$sum": "$a" } } } ] }');

-- same with filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-- multi-field with nested document path
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "total": { "$sum": "$a" } } } ] }');

-- multi-field with multiple accumulators
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 }, "maxA": { "$max": "$a" } } } ] }');

-----------------------------------------------------------------------------------------------------
-- EDGE CASE: no accumulators at all
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" } } } ] }');

-- EDGE CASE: many accumulators
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "cnt": { "$sum": 1 }, "mx": { "$max": "$a" }, "mn": { "$min": "$a" }, "av": { "$avg": "$a" } } } ] }');

-- EDGE CASE: accumulator references grouped field (was the original bug)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } } ] }');

-- EDGE CASE: GUC off - should NOT decompose
SET documentdb.enableGroupByCompoundIdIndexPushdown TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');
SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;

-----------------------------------------------------------------------------------------------------
-- these don't work:
-- does not work with inequality prefix
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": { "$exists": true } } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }');

-- $$variable expression in _id field should not decompose.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "offset": "$$myVar" }, "count": { "$sum": 1 } } } ], "let": { "myVar": 42 } }');

BEGIN;
set citus.enable_local_execution to off;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local enable_seqscan to off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "offset": "$$myVar" }, "count": { "$sum": 1 } } } ], "let": { "myVar": 42 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } } ] }');
ROLLBACK;

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
set citus.enable_local_execution to off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- works with filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "a": { "$exists": true } } }, { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');

-- works with suffix filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- equality with group suffix works.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": 10 } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }');

---------------------------------------------------------------------------------------------------
-- single-field document _id pushdown (sharded)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b" }, "count": { "$sum": 1 } } } ] }');

-- multi-field document _id pushdown (sharded)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

---------------------------------------------------------------------------------------------------
-- dotted path: _id fields use dotted paths.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "x": "$b.nested", "y": "$c.nested" }, "count": { "$sum": 1 } } } ] }');

-- expression in _id field: not a simple $path, should NOT decompose
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": { "$add": ["$b", 1] }, "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-- mixed: one field is $path, one is constant expression, should NOT decompose
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "constant" }, "count": { "$sum": 1 } } } ] }');

ROLLBACK;