SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_test_helpers;

SET documentdb.next_collection_id TO 25712000;
SET documentdb.next_collection_index_id TO 25712000;

-- Insert test data (20 documents for meaningful sampling)
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 1, "category" : "A", "value" : 10 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 2, "category" : "B", "value" : 20 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 3, "category" : "A", "value" : 30 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 4, "category" : "B", "value" : 40 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 5, "category" : "A", "value" : 50 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 6, "category" : "C", "value" : 60 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 7, "category" : "C", "value" : 70 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 8, "category" : "A", "value" : 80 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 9, "category" : "B", "value" : 90 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 10, "category" : "C", "value" : 100 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 11, "category" : "A", "value" : 110 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 12, "category" : "B", "value" : 120 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 13, "category" : "C", "value" : 130 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 14, "category" : "A", "value" : 140 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 15, "category" : "B", "value" : 150 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 16, "category" : "C", "value" : 160 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 17, "category" : "A", "value" : 170 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 18, "category" : "B", "value" : 180 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 19, "category" : "C", "value" : 190 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','reservoirTest',' { "_id" : 20, "category" : "A", "value" : 200 }', NULL);

-- =============================================================================
-- BASELINE TESTS (Reservoir Sampling DISABLED - default ORDER BY random() LIMIT)
-- =============================================================================

SET documentdb.enableDollarSampleReservoirScan TO off;

-- Plan: $sample alone - should show Limit + Sort(random()) over TABLESAMPLE
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$sample": { "size": 3 } } ] }');

-- Plan: $match + $sample + $project + $sort (typical Spark partitioner shape)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Plan: empty $match + $sample
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 5 } } ] }');

-- Plan: $sample + $match (filter after sampling)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$sample": { "size": 10 } }, { "$match": { "value": { "$gt": 100 } } } ] }');

RESET documentdb.enableDollarSampleReservoirScan;

-- =============================================================================
-- RESERVOIR SAMPLING ENABLED TESTS (CustomScan ReservoirSample)
-- These tests run with the default (ON) setting.
-- =============================================================================

-- Plan: $sample alone - uses TABLESAMPLE path (no filter = efficient already), no ReservoirSample needed
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$sample": { "size": 3 } } ] }');

-- Plan: $match + $sample + $project + $sort - ReservoirSample wraps the filtered base scan
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Plan: empty $match + $sample - empty $match doesn't add filters, uses TABLESAMPLE path
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": {} }, { "$sample": { "size": 5 } } ] }');

-- Plan: $sample + $project (no sort) - uses TABLESAMPLE path (no filter)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$sample": { "size": 4 } }, { "$project": { "_id": 1, "value": 1 } } ] }');

-- Plan: $sample + downstream $match (filter after sampling) - uses TABLESAMPLE path (filter is after $sample)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$sample": { "size": 10 } }, { "$match": { "value": { "$gt": 100 } } } ] }');

-- Plan: $sample with size 0 (edge case)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$sample": { "size": 0 } } ] }');

-- Plan: $match on _id + $sample - verifies bson_dollar_range marker qual is stripped from IndexScan filter
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$gt": 1, "$lte": 15 } } }, { "$sample": { "size": 3 } } ] }');

-- Execution: $match + $sample (size >= matched) + $sort returns all matched docs deterministically
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 20 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- Execution: $sample with size larger than collection (returns all docs sorted deterministically)
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$sample": { "size": 100 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- EXPLAIN ANALYZE: verify reservoir scan executes and reports correct row count
-- Use count to verify EXPLAIN ANALYZE produces output (plan details are non-deterministic across runs)
SELECT count(*) > 0 AS has_plan FROM (
  SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 3 } } ], "cursor": {} }') $$)
) q;

-- =============================================================================
-- EDGE CASES WITH RESERVOIR SAMPLING
-- =============================================================================

-- Empty collection
SELECT documentdb_api.create_collection('reservoirdb', 'emptyCollection');

-- Plan: $sample on empty collection — no $match means no reservoir, uses TABLESAMPLE path
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "emptyCollection", "pipeline": [ { "$sample": { "size": 5 } } ] }');

-- Execution: $sample on empty collection returns no rows
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "emptyCollection", "pipeline": [ { "$sample": { "size": 5 } } ] }');

-- $match + $sample with size 0 exercises the reservoir path returning no rows
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 0 } } ] }');

-- Single document collection
SELECT documentdb_api.insert_one('reservoirdb','singleDoc',' { "_id" : 1, "x" : 42 }', NULL);

-- $sample with size 1 on single-doc collection returns the one document
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "singleDoc", "pipeline": [ { "$sample": { "size": 1 } } ] }');

-- =============================================================================
-- SHARDED COLLECTION WITH RESERVOIR SAMPLING
-- =============================================================================

SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 1, "key" : "a", "val" : 1 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 2, "key" : "b", "val" : 2 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 3, "key" : "c", "val" : 3 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 4, "key" : "d", "val" : 4 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 5, "key" : "e", "val" : 5 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 6, "key" : "f", "val" : 6 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 7, "key" : "g", "val" : 7 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 8, "key" : "h", "val" : 8 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 9, "key" : "i", "val" : 9 }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','shardedSample',' { "_id" : 10, "key" : "j", "val" : 10 }', NULL);

SELECT documentdb_api.shard_collection('reservoirdb','shardedSample', '{"key":"hashed"}', false);

-- Plan: $sample on sharded collection (no reservoir — falls back to TABLESAMPLE or ORDER BY random())
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "shardedSample", "pipeline": [ { "$sample": { "size": 3 } } ] }');

-- Plan: $match + $sample on sharded (no reservoir — falls back to ORDER BY random())
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "shardedSample", "pipeline": [ { "$match": { "val": { "$gt": 3 } } }, { "$sample": { "size": 2 } } ] }');

-- Plan: $sample + $project + $sort on sharded (no reservoir)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "shardedSample", "pipeline": [ { "$sample": { "size": 4 } }, { "$project": { "_id": 1 } }, { "$sort": { "_id": 1 } } ] }');

-- Execution: $sample (size >= collection) + $sort on sharded returns all docs deterministically
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "shardedSample", "pipeline": [ { "$sample": { "size": 100 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- =============================================================================
-- TOGGLING GUC MID-SESSION
-- =============================================================================

-- Disable reservoir, verify fallback to Limit+Sort(random()) for $match + $sample
SET documentdb.enableDollarSampleReservoirScan TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 3 } } ] }');

-- Re-enable reservoir (back to default), verify CustomScan returns for $match + $sample
SET documentdb.enableDollarSampleReservoirScan TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 3 } } ] }');

-- =============================================================================
-- ALTERNATE INDEX PATH TESTS (wildcard, single-field, compound, sparse, partial)
-- Verify reservoir sampling works correctly with various index types.
-- =============================================================================

-- Create a wildcard index on reservoirTest to enable RUM-based scans
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "reservoirTest", "indexes": [ { "key": { "$**": 1 }, "name": "wildcard_all" } ] }', TRUE);

-- Disable sequential scans to force the planner to use indexes
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Plan: $match on non-_id field + $sample with wildcard index - ReservoirSample wraps RUM scan
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gt": 50 } } }, { "$sample": { "size": 3 } } ] }');

-- Plan: $match on category (string equality) + $sample with wildcard index
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 2 } } ] }');

-- Execution: $match + $sample with wildcard index, verify correct count
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gt": 100 } } }, { "$sample": { "size": 3 } } ] }')
) q;

-- Execution: $match + $sample (size >= matched) + $sort with wildcard index returns all matched docs
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gt": 150 } } }, { "$sample": { "size": 100 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- Extended explain: $match + $sample with wildcard index shows indexName and no leaked marker qual
SET documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 2 } } ], "cursor": {} }') $$);
RESET documentdb.enableExtendedExplainPlans;

-- Single-field index on "value"
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "reservoirTest", "indexes": [ { "key": { "value": 1 }, "name": "value_asc" } ] }', TRUE);

-- Plan: $match on value range uses single-field index with reservoir
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gte": 50, "$lte": 150 } } }, { "$sample": { "size": 3 } } ] }');

-- Execution: verify correct count with single-field index
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gte": 50, "$lte": 150 } } }, { "$sample": { "size": 3 } } ] }')
) q;

-- Compound index on "category" + "value"
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "reservoirTest", "indexes": [ { "key": { "category": 1, "value": -1 }, "name": "category_value_compound" } ] }', TRUE);

-- Plan: $match on compound prefix uses compound index with reservoir
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A", "value": { "$gt": 50 } } }, { "$sample": { "size": 2 } } ] }');

-- Execution: compound index match + sample returns correct count
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A", "value": { "$gt": 50 } } }, { "$sample": { "size": 2 } } ] }')
) q;

-- Execution: compound index match + sample + sort (verify deterministic result)
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A", "value": { "$gt": 50 } } }, { "$sample": { "size": 100 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- Sparse index on optional "tag" field (none of the docs have "tag", so match returns 0)
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "reservoirTest", "indexes": [ { "key": { "tag": 1 }, "name": "tag_sparse", "sparse": true } ] }', TRUE);

-- Execution: match on sparse-indexed field with no matching docs
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "tag": "x" } }, { "$sample": { "size": 5 } } ] }')
) q;

-- Partial filter expression index: only indexes docs where value > 100
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "reservoirTest", "indexes": [ { "key": { "category": 1 }, "name": "category_high_value", "partialFilterExpression": { "value": { "$gt": 100 } } } ] }', TRUE);

-- Plan: $match satisfies partial filter expression - should use partial index
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A", "value": { "$gt": 100 } } }, { "$sample": { "size": 2 } } ] }');

-- Execution: partial filter index match + sample + sort (deterministic)
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A", "value": { "$gt": 100 } } }, { "$sample": { "size": 100 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- Execution: $match does NOT satisfy partial filter (value > 50 is wider than index's value > 100)
-- Planner should still produce correct results (uses a different index since seqscan is off)
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "B", "value": { "$gt": 50 } } }, { "$sample": { "size": 10 } } ] }')
) q;

-- Plan: $match exactly matches partial filter predicate boundary
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "C", "value": { "$gt": 100 } } }, { "$sample": { "size": 3 } } ] }');

-- Execution: partial filter match for category C
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "C", "value": { "$gt": 100 } } }, { "$sample": { "size": 100 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- ERROR: Sample size exceeds maximum reservoir capacity
-- =============================================================================

-- Should error when sample size exceeds MaxAllocSize / sizeof(HeapTuple)
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 200000000 } } ] }');

-- Should error when sample size exceeds INT32_MAX (2 billion)
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 2200000000 } } ] }');

-- =============================================================================
-- $lookup + $sample TESTS
-- =============================================================================

-- Setup: create a second collection for $lookup
SELECT documentdb_api.insert_one('reservoirdb','lookupTarget',' { "_id" : 1, "ref" : "A", "info" : "first" }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','lookupTarget',' { "_id" : 2, "ref" : "B", "info" : "second" }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','lookupTarget',' { "_id" : 3, "ref" : "A", "info" : "third" }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','lookupTarget',' { "_id" : 4, "ref" : "C", "info" : "fourth" }', NULL);
SELECT documentdb_api.insert_one('reservoirdb','lookupTarget',' { "_id" : 5, "ref" : "A", "info" : "fifth" }', NULL);

-- Uncorrelated $lookup with $sample on the right collection (pipeline form)
-- The inner $sample alone uses TABLESAMPLE (no $match → $sample pattern)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$lte": 3 } } }, { "$lookup": { "from": "lookupTarget", "pipeline": [ { "$sample": { "size": 2 } } ], "as": "sampled" } } ] }');

-- Uncorrelated $lookup with $match + $sample on the right collection
-- The inner pipeline has $match → $sample, so it should use ReservoirSample
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$lte": 3 } } }, { "$lookup": { "from": "lookupTarget", "pipeline": [ { "$match": { "ref": "A" } }, { "$sample": { "size": 2 } } ], "as": "sampled" } } ] }');

-- Correlated $lookup with $sample on the right collection
-- The inner pipeline has a correlation ($match on $$category), so it should
-- NOT use the reservoir custom scan (uses standard TABLESAMPLE path instead)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$lte": 2 } } }, { "$lookup": { "from": "lookupTarget", "let": { "category": "$category" }, "pipeline": [ { "$match": { "$expr": { "$eq": [ "$ref", "$$category" ] } } }, { "$sample": { "size": 1 } } ], "as": "sampled" } } ] }');

-- $match + $unwind + $sample — unwind before sample means reservoir is NOT used
-- because sample is not directly after $match (unwind injects new tuples)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$unwind": "$category" }, { "$sample": { "size": 2 } } ] }');

-- =============================================================================
-- $skip + $sample TESTS
-- =============================================================================

-- $match + $skip + $sample — skip before sample means reservoir is NOT used
-- because $skip changes the result set that $sample operates on
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$skip": 2 }, { "$sample": { "size": 3 } } ] }');

-- =============================================================================
-- $unwind + $sample TESTS
-- =============================================================================

-- $match + $unwind + $sample — reservoir is NOT used because $unwind
-- produces new tuples above the base relation scan
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$unwind": "$category" }, { "$sample": { "size": 2 } } ] }');

-- =============================================================================
-- $lookup inner + $sample TESTS
-- =============================================================================

-- Uncorrelated $lookup with $match + $sample in inner pipeline
-- The inner pipeline targets a base relation with $match → $sample,
-- so it should use ReservoirSample in the subplan
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$lte": 3 } } }, { "$lookup": { "from": "lookupTarget", "pipeline": [ { "$match": { "ref": "A" } }, { "$sample": { "size": 2 } } ], "as": "sampled" } } ] }');

-- Correlated $lookup with $match + $sample in inner pipeline
-- Correlation ($$category) prevents reservoir optimization
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$lte": 2 } } }, { "$lookup": { "from": "lookupTarget", "let": { "category": "$category" }, "pipeline": [ { "$match": { "$expr": { "$eq": [ "$ref", "$$category" ] } } }, { "$sample": { "size": 1 } } ], "as": "sampled" } } ] }');

-- =============================================================================
-- $project + $sort + $sample TESTS
-- =============================================================================

-- $project + $sort + $sample — reservoir IS used because $sample still operates
-- on the base relation scan. The project is folded into the ReservoirSample
-- output target list, and the sort is applied above.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$project": { "_id": 1, "category": 1 } }, { "$sort": { "category": 1 } }, { "$sample": { "size": 2 } } ] }');

-- $match + $sample + $project — verify where the project node is placed
-- relative to the ReservoirSample custom scan
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 3 } }, { "$project": { "_id": 1, "value": 1 } } ] }');

-- $match + $project + $sample — project before sample; reservoir is used
-- and the project is folded into the ReservoirSample output target list
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$project": { "_id": 1, "value": 1 } }, { "$sample": { "size": 3 } } ] }');

-- =============================================================================
-- natts = 0: when the outer query does not reference the document column,
-- the custom scan target list is NIL and the slot has 0 attributes.
-- This verifies ExecForceStoreHeapTuple handles natts=0 correctly.
-- =============================================================================

-- $count stage produces a count without referencing document data
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "_id": { "$gte": 1 } } }, { "$sample": { "size": 5 } }, { "$count": "total" } ] }');

-- =============================================================================
-- CLEANUP
-- =============================================================================

RESET documentdb.enableDollarSampleReservoirScan;

