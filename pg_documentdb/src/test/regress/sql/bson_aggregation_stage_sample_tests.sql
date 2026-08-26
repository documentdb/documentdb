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

-- OVERSIZED SAMPLE SIZE TESTS (regression: size >= 2^63 must not produce a negative LIMIT)

-- samplePlanTest is sharded above, so $sample on it uses the TABLESAMPLE path:
-- an oversized size returns all documents, sorted deterministically.
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDouble": "1e19" } } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- order-by-random LIMIT path (subquery RTE after $limit): oversized size must not error
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$limit": 1000 }, { "$sample": { "size": { "$numberDouble": "1e19" } } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- order-by-random LIMIT path with size just above INT64_MAX
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$limit": 1000 }, { "$sample": { "size": { "$numberDouble": "9.3e18" } } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- Unsharded collection eligible for the reservoir: eligibility is capped by
-- work_mem (the reservoir buffers K HeapTuple copies), so a size whose buffer
-- would exceed that budget skips the reservoir and falls back to an
-- ORDER BY random() sort, returning all matching documents instead of erroring.
SET work_mem TO '1MB';
SELECT documentdb_api.insert_one('sampledb','sampleOversizeUnsharded', FORMAT('{ "_id": %s, "v": %s }', g, g)::documentdb_core.bson, NULL) FROM generate_series(1, 5) g;

-- size within the INT32 range but above the cap derived from work_mem (and above
-- the palloc capacity): must fall back to an ORDER BY random() sort and return
-- all 5 documents rather than failing the reservoir allocation at execution time.
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleOversizeUnsharded", "pipeline": [ { "$sample": { "size": 200000000 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- size just above INT32_MAX: falls back, returns all 5 documents
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleOversizeUnsharded", "pipeline": [ { "$sample": { "size": 2200000000 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- huge double size: clamped, falls back, returns all 5 documents
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleOversizeUnsharded", "pipeline": [ { "$sample": { "size": { "$numberDouble": "1e19" } } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- small size stays within the work_mem cap and uses the reservoir, returning exactly K documents
SELECT count(*) AS reservoir_k FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "sampleOversizeUnsharded", "pipeline": [ { "$sample": { "size": 3 } } ] }')) t;
RESET work_mem;

-- SHARDED COLLECTION TESTS WITH FIX DISABLED (regression)

SET documentdb.enableSampleScanFixOnSharded TO off;
SET documentdb.enableDollarSampleReservoirScan TO off;

-- Empty $match + $sample on sharded collection (no TABLESAMPLE without fix)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } } ] }');

-- Empty $match + $sample + $project + $sort on sharded collection (no TABLESAMPLE without fix)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Multiple empty $match + $sample + $project + $sort on sharded collection (no TABLESAMPLE without fix)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$match": {} }, { "$match": {} }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

RESET documentdb.enableSampleScanFixOnSharded;
RESET documentdb.enableDollarSampleReservoirScan;

-- SIZE VALIDATION TESTS

-- size 0 must be a positive integer and is rejected (error 28747)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 0 } } ] }');

-- negative size is rejected (error 28747)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": -5 } } ] }');

-- a fractional size that rounds down to zero is rejected (error 28747)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDouble": "0.5" } } } ] }');

-- NaN coerces to zero and is rejected (error 28747)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDouble": "NaN" } } } ] }');

-- negative infinity clamps to the int64 lower bound and is rejected (error 28747)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDouble": "-Infinity" } } } ] }');

-- positive infinity clamps to the int64 upper bound: returns all documents rather than erroring
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDouble": "Infinity" } } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- non-numeric size is rejected (error 28746)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": "five" } } ] }');

-- missing size is rejected (error 28749)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { } } ] }');

-- unrecognized option is rejected (error 28748)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": 2, "foo": 1 } } ] }');

-- a non-numeric size takes precedence over a later unrecognized option (error 28746, not 28748)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": "bad", "foo": 1 } } ] }');

-- non-object specification is rejected (error 28745)
SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": 3 } ] }');

-- SIZE NUMERIC COERCION TESTS (use COUNT so the result is deterministic regardless of which rows are sampled)

-- doubles truncate toward zero: 1.9 -> 1
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDouble": "1.9" } } } ] }')) q;

-- doubles truncate toward zero: 2.1 -> 2
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDouble": "2.1" } } } ] }')) q;

-- Decimal128 uses round-half-to-even: 1.5 -> 2
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDecimal": "1.5" } } } ] }')) q;

-- Decimal128 uses round-half-to-even: 2.5 -> 2
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDecimal": "2.5" } } } ] }')) q;

-- Decimal128 uses round-half-to-even: 3.5 -> 4
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDecimal": "3.5" } } } ] }')) q;

-- Decimal128 just above the half rounds up: 0.51 -> 1
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDecimal": "0.51" } } } ] }')) q;

-- Decimal128 exactly one half rounds to even (zero): a valid empty sample (no error)
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDecimal": "0.5" } } } ] }')) q;

-- Decimal128 overflow saturates and returns all documents rather than erroring
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDecimal": "1E6144" } } } ] }')) q;

-- Decimal128 infinity saturates and returns all documents rather than erroring
SELECT COUNT(*) FROM (SELECT document FROM bson_aggregation_pipeline('sampledb', '{ "aggregate": "samplePlanTest", "pipeline": [ { "$sample": { "size": { "$numberDecimal": "Infinity" } } } ] }')) q;
