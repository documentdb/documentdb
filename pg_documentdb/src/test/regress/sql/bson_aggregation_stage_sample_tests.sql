SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 25711000;
SET documentdb.next_collection_index_id TO 25711000;

-- Insert test data
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 1, "product" : "p1", "unitPrice" : 5, "stock" : 100 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 2, "product" : "p2", "unitPrice" : 4, "stock" : 200 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 3, "product" : "p3", "unitPrice" : 6, "stock" : 50 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 4, "product" : "p4", "unitPrice" : 5, "stock" : 150 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 5, "product" : "p5", "unitPrice" : 7, "stock" : 75 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 6, "product" : "p6", "unitPrice" : 4, "stock" : 180 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 7, "product" : "p7", "unitPrice" : 5, "stock" : 90 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 8, "product" : "p8", "unitPrice" : 6, "stock" : 120 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 9, "product" : "p9", "unitPrice" : 7, "stock" : 60 }', NULL);
SELECT documentdb_api.insert_one('sampledb','samplePlanTest',' { "_id" : 10, "product" : "p10", "unitPrice" : 4, "stock" : 140 }', NULL);

-- UNSHARDED COLLECTION TESTS

-- $sample alone
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 3 } } ] }');

-- $sample + $project + $sort (Spark partitioner shape without empty $match)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Empty $match + $sample (should produce same plan as $sample alone)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } } ] }');

-- Empty $match + $sample + $project + $sort (exact Spark connector partitioner query)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Multiple empty $match stages + $sample + $project + $sort
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Non-empty $match + $sample (filter constrains input, TABLESAMPLE not expected)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": { "product": "p1" } }, { "$sample": { "size": 2 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- $sample + $match (filter applied after sampling, TABLESAMPLE expected)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 5 } }, { "$match": { "unitPrice": { "$gt": 4 } } } ] }');

-- SHARDED COLLECTION TESTS

SELECT documentdb_api.shard_collection('sampledb','samplePlanTest', '{"product":"hashed"}', false);

-- $sample alone on sharded collection
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 3 } } ] }');

-- $sample + $project + $sort on sharded collection (no empty $match)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Empty $match + $sample on sharded collection (TABLESAMPLE expected)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } } ] }');

-- Empty $match + $sample + $project + $sort on sharded collection (TABLESAMPLE expected)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Multiple empty $match + $sample + $project + $sort on sharded collection (TABLESAMPLE expected)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Non-empty $match + $sample on sharded collection (TABLESAMPLE not expected)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": { "product": "p1" } }, { "$sample": { "size": 2 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- $sample + $match on sharded collection (filter after sampling)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 5 } }, { "$match": { "unitPrice": { "$gt": 4 } } } ] }');

-- SHARDED COLLECTION TESTS WITH FIX DISABLED (regression)

SET documentdb.enableSampleScanFixOnSharded TO off;

-- Empty $match + $sample on sharded collection (no TABLESAMPLE without fix)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } } ] }');

-- Empty $match + $sample + $project + $sort on sharded collection (no TABLESAMPLE without fix)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Multiple empty $match + $sample + $project + $sort on sharded collection (no TABLESAMPLE without fix)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

RESET documentdb.enableSampleScanFixOnSharded;
