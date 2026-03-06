SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 99800;
SET documentdb.next_collection_index_id TO 99800;

-- Test: $densify with partitionByFields on shard key should not crash (issue #464)
-- When partitionByFields matches the shard key, the partition expression uses INT8
-- shard_key_value column. The sort/eq operators must match that type.

SELECT insert_one('db','densify_shard_test','{ "_id": 1, "a": "abc", "cost": 10 }', NULL);
SELECT insert_one('db','densify_shard_test','{ "_id": 2, "a": "abc", "cost": 5 }', NULL);
SELECT insert_one('db','densify_shard_test','{ "_id": 3, "a": "def", "cost": 3 }', NULL);
SELECT insert_one('db','densify_shard_test','{ "_id": 4, "a": "def", "cost": 7 }', NULL);

-- Shard the collection on the field used as partitionByFields
SELECT documentdb_api.shard_collection('db', 'densify_shard_test', '{"a": "hashed"}', false);

-- Partition mode: should densify within each partition without crashing
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$densify": { "field": "cost", "partitionByFields": ["a"], "range": { "bounds": "partition", "step": 1 } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Range mode with shard key partition
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$densify": { "field": "cost", "partitionByFields": ["a"], "range": { "bounds": [4, 8], "step": 1 } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Full mode with shard key partition
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$densify": { "field": "cost", "partitionByFields": ["a"], "range": { "bounds": "full", "step": 1 } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Test: $setWindowFields with partitionBy on shard key should not crash
-- Same root cause as $densify: INT8 shard_key_value used as partition expression
-- with BSON sort operators causes a segfault.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$setWindowFields": { "partitionBy": "$a", "sortBy": {"cost": 1}, "output": { "runningTotal": { "$sum": "$cost" } } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Cleanup
SELECT drop_collection('db', 'densify_shard_test');
