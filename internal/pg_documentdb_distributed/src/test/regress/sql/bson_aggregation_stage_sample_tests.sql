SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- CREATE EXTENSION IF NOT EXISTS tsm_system_rows;

SET citus.next_shard_id TO 70000;
SET documentdb.next_collection_id TO 7000;
SET documentdb.next_collection_index_id TO 7000;

-- Insert data
SELECT documentdb_api.insert_one('sampledb','sampleTest',' { "_id" : 1, "product" : "beer", "unitPrice" : 1, "stock" : 1 }', NULL);
SELECT documentdb_api.insert_one('sampledb','sampleTest',' { "_id" : 2, "product" : "beer", "unitPrice" : 1, "stock" : 1 }', NULL);
SELECT documentdb_api.insert_one('sampledb','sampleTest',' { "_id" : 3, "product" : "beer", "unitPrice" : 1, "stock" : 1 }', NULL);
SELECT documentdb_api.insert_one('sampledb','sampleTest',' { "_id" : 4, "product" : "beer", "unitPrice" : 1, "stock" : 1 }', NULL);
SELECT documentdb_api.insert_one('sampledb','sampleTest',' { "_id" : 5, "product" : "beer", "unitPrice" : 1, "stock" : 1 }', NULL);
SELECT documentdb_api.insert_one('sampledb','sampleTest',' { "_id" : 6, "product" : "beer", "unitPrice" : 1, "stock" : 1 }', NULL);

-- Tests and explain for collection with data
-- SYSTEM sampling method, SYSTEM_ROWS performs block-level sampling,
-- so that the sample is not completely random but may be subject to clustering effects.
-- especially if only a small number of rows are requested.
-- https://www.postgresql.org/docs/current/tsm-system-rows.html

-- Sample with cursor for unsharded collection not supported - use persisted cursor
SELECT * FROM documentdb_api.aggregate_cursor_first_page(database => 'sampledb', commandSpec => '{ "aggregate": "sampleTest", "pipeline": [ { "$sample": { "size": 3 } }, { "$project": { "_id": 0 } } ], "cursor": { "batchSize": 1 } }', cursorId => 4294967294);

-- Shard orders collection on item 
SELECT documentdb_api.shard_collection('sampledb','sampleTest', '{"product":"hashed"}', false);

-- If the collection is sharded, have to call TABLESAMPLE SYSTEM_ROWS(n) LIMIT n
-- SYSTEM_ROWS(n) may always be optimal, but important, as one but all shards may be 
-- emptty. If we use SYSTEM_ROWS(<n), we might have to go back to get more data.
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$sample": { "size": 3 } }, { "$project": { "_id": 0 } } ] }');
SELECT documentdb_distributed_test_helpers.mask_plan_id_from_distributed_subplan($Q$
EXPLAIN(costs off) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$sample": { "size": 3 } }, { "$project": { "_id": 0 } } ] }');
$Q$);

-- Empty $match + $sample on sharded collection (TABLESAMPLE expected with fix)
SELECT documentdb_distributed_test_helpers.mask_plan_id_from_distributed_subplan($Q$
EXPLAIN(costs off) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 0 } } ] }');
$Q$);

-- Empty $match + $sample + $project + $sort on sharded collection (TABLESAMPLE expected)
SELECT documentdb_distributed_test_helpers.mask_plan_id_from_distributed_subplan($Q$
EXPLAIN(costs off) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 0 } }, { "$sort": { "_id": 1 } } ] }');
$Q$);

-- Disable fix: empty $match + $sample on sharded collection (no TABLESAMPLE without fix)
SET documentdb.enableSampleScanFixOnSharded TO off;

SELECT documentdb_distributed_test_helpers.mask_plan_id_from_distributed_subplan($Q$
EXPLAIN(costs off) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 0 } } ] }');
$Q$);

RESET documentdb.enableSampleScanFixOnSharded;

-- ============================================================
-- $match + $sample on sharded collection uses ORDER BY random() LIMIT
-- (reservoir sampling is not applied to sharded collections)
-- ============================================================

-- $match + $sample on sharded collection: verify correct row count
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 3 } } ] }')
) q;

-- EXPLAIN: $match + $sample should show Sort + random() on sharded (no ReservoirSample)
SELECT documentdb_distributed_test_helpers.mask_plan_id_from_distributed_subplan($Q$
EXPLAIN(costs off) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } } ] }');
$Q$);

-- $match + $sample + $sort: verify result count
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 4 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }')
) q;

-- $sample size larger than collection: should return all rows
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 100 } } ] }')
) q;

-- $match narrowing to subset + $sample
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleTest", "pipeline": [ { "$match": { "_id": { "$lte": 3 } } }, { "$sample": { "size": 2 } } ] }')
) q;

-- Create and shard a collection for multi-shard $sample tests
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 1, "val": 10 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 2, "val": 20 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 3, "val": 30 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 4, "val": 40 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 5, "val": 50 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 6, "val": 60 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 7, "val": 70 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 8, "val": 80 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 9, "val": 90 }', NULL);
SELECT documentdb_api.insert_one('sampledb','multiShardSample', '{ "_id": 10, "val": 100 }', NULL);
SELECT documentdb_api.shard_collection('sampledb','multiShardSample', '{"_id":"hashed"}', false);

-- $match narrowing + $sample: filter to 5 rows, sample 3 → must return exactly 3
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "multiShardSample", "pipeline": [ { "$match": { "val": { "$lte": 50 } } }, { "$sample": { "size": 3 } } ] }')
) q;

-- $sample size larger than matching set: all 10 rows match, sample 100 → returns 10
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "multiShardSample", "pipeline": [ { "$match": { "val": { "$gte": 10 } } }, { "$sample": { "size": 100 } } ] }')
) q;

-- EXPLAIN showing coordinator Limit caps multi-shard results
SELECT documentdb_distributed_test_helpers.mask_plan_id_from_distributed_subplan($Q$
EXPLAIN(costs off) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "multiShardSample", "pipeline": [ { "$match": { "val": { "$gte": 10 } } }, { "$sample": { "size": 3 } } ] }');
$Q$);
