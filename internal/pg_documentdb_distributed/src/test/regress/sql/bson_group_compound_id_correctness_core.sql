-- Core correctness tests for composite group-by.
-- Included by wrapper test files that set GUC combinations for
-- enableGroupByCompoundIdIndexPushdown and enableGroupSubqueryElimination.

-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

set documentdb.defaultUseCompositeOpClass to on;
set documentdb_core.enableWriteDocumentsInRepath to on;

-- Clean up from any prior run
SELECT documentdb_api.drop_collection('group_corr_db', 'group_push') IS NOT NULL;

-- Setup: create collection, indexes, and insert data
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'group_corr_db', '{ "createIndexes": "group_push", "indexes": [ { "name": "a_1", "key": { "a": 1 } }, { "name": "b_c_1", "key": { "b": 1, "c": 1 } } ] }', TRUE);

SELECT COUNT(documentdb_api.insert_one('group_corr_db', 'group_push', bson_build_document('_id', i, 'a', i % 100, 'b', i % 10, 'c', i) )) FROM generate_series(1, 1000) AS i;

-----------------------------------------------------------------------------------------------------
-- correctness: multi-field group by with 2 fields
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } }, { "$limit": 5 } ] }');

-- EDGE CASE: 3-field _id (only b,c match index)
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c", "a": "$a" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: both _id fields reference same source field
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "x": "$b", "y": "$b" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: _id doc with non-existent field
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "z": "$nonexistent" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: no accumulators at all
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: many accumulators
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "cnt": { "$sum": 1 }, "mx": { "$max": "$a" }, "mn": { "$min": "$a" }, "av": { "$avg": "$a" } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: accumulator references grouped field (was the original bug)
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: $group followed by $group on _id subfield
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$group": { "_id": "$_id.b", "total": { "$sum": "$count" } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: $group + $project accessing nested _id
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$project": { "myB": "$_id.b", "myC": "$_id.c", "count": 1 } }, { "$sort": { "myB": 1, "myC": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: $match after $group on _id subfield
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$match": { "_id.b": 5 } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- EDGE CASE: $push accumulator with decomposed group
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "ids": { "$push": "$_id" } } }, { "$sort": { "_id": 1 } }, { "$limit": 2 } ] }');

-- EXHAUSTIVE: verify total count and all groups have count=1
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$group": { "_id": null, "total": { "$sum": "$count" }, "groups": { "$sum": 1 } } } ] }');

-- EXHAUSTIVE: no group should have count != 1 (since c=i is unique per row)
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$match": { "count": { "$ne": 1 } } } ] }');

-- EDGE CASE: empty collection
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "nonexistent_coll", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-----------------------------------------------------------------------------------------------------
-- ARRAY TEST: insert docs with array fields and verify decomposed group handles them
SELECT documentdb_api.insert_one('group_corr_db', 'group_push', '{ "_id": 1001, "a": [1, 2], "b": 1, "c": 1001 }');
SELECT documentdb_api.insert_one('group_corr_db', 'group_push', '{ "_id": 1002, "a": 1, "b": [1, 2], "c": 1002 }');

-- array in non-grouped field (a) should still work with decomposed group on b,c
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "_id": 1001 } }, { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-- array in grouped field (b) should use the array value as-is as the group key
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "_id": 1002 } }, { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ] }');

-- clean up array docs
SELECT documentdb_api.delete('group_corr_db', '{ "delete": "group_push", "deletes": [{ "q": { "_id": { "$gte": 1001 } }, "limit": 0 }] }');

-----------------------------------------------------------------------------------------------------
-- correctness: dotted path group by still works (even without decomposition)
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "x": "$b.nested", "y": "$c" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-----------------------------------------------------------------------------------------------------
-- SHARDED CORRECTNESS TESTS
-----------------------------------------------------------------------------------------------------
SELECT documentdb_api.shard_collection('{ "shardCollection": "group_corr_db.group_push", "key": { "_id": "hashed" } }');

-- sharded: multi-field group by must produce correct results
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } }, { "$limit": 5 } ] }');

-- sharded: total count must equal 1000 and every group has count=1
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$group": { "_id": null, "total": { "$sum": "$count" }, "groups": { "$sum": 1 } } } ] }');

-- sharded: no group should have count != 1
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$match": { "count": { "$ne": 1 } } } ] }');

-- sharded: many accumulators
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "cnt": { "$sum": 1 }, "mx": { "$max": "$a" }, "mn": { "$min": "$a" }, "av": { "$avg": "$a" } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- sharded: accumulator references grouped field
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- sharded: $group followed by $group on _id subfield
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$group": { "_id": "$_id.b", "total": { "$sum": "$count" } } }, { "$sort": { "_id": 1 } }, { "$limit": 3 } ] }');

-- sharded: $group + $project accessing nested _id
SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$project": { "myB": "$_id.b", "myC": "$_id.c", "count": 1 } }, { "$sort": { "myB": 1, "myC": 1 } }, { "$limit": 3 } ] }');

-- sharded: deterministic 4-group test
SELECT documentdb_api.insert_one('group_corr_db', 'group_push', '{"_id": 2001, "b": 1, "c": 1}');
SELECT documentdb_api.insert_one('group_corr_db', 'group_push', '{"_id": 2002, "b": 1, "c": 2}');
SELECT documentdb_api.insert_one('group_corr_db', 'group_push', '{"_id": 2003, "b": 2, "c": 1}');
SELECT documentdb_api.insert_one('group_corr_db', 'group_push', '{"_id": 2004, "b": 2, "c": 2}');

SELECT document FROM bson_aggregation_pipeline('group_corr_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "_id": { "$gte": 2001, "$lte": 2004 } } }, { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ] }');

SELECT documentdb_api.delete('group_corr_db', '{ "delete": "group_push", "deletes": [{ "q": { "_id": { "$gte": 2001 } }, "limit": 0 }] }');
