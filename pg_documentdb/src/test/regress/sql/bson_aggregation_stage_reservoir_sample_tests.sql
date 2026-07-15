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
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "category": "A" } }, { "$sample": { "size": 2 } } ], "cursor": {} }') $$);
RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET documentdb.enableExtendedExplainPlans;

-- Single-field index on "value"
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "reservoirTest", "indexes": [ { "key": { "value": 1 }, "name": "value_asc" } ] }', TRUE);

-- Plan: $match on value range uses single-field index with reservoir
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gte": 50, "$lte": 150 } } }, { "$sample": { "size": 3 } } ] }');

-- Execution: verify correct count with single-field index
SELECT count(*) FROM (
  SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gte": 50, "$lte": 150 } } }, { "$sample": { "size": 3 } } ] }')
) q;

-- EXPLAIN ANALYZE in heap skip mode: reports how skipped rows were resolved (VM vs heap fetch).
-- The counts are run dependent, so run_explain_and_trim masks them; filter to the reservoir lines.
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SELECT l FROM documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "reservoirTest", "pipeline": [ { "$match": { "value": { "$gte": 50, "$lte": 150 } } }, { "$sample": { "size": 3 } } ], "cursor": {} }') $$) AS l
WHERE l ~ 'Sample (Reservoir Method|Rows Skipped|Heap Skips)';
RESET documentdb.enableDollarSampleHeapSkipReservoirScan;

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
-- HEAP-SKIP MODE TESTS (btree)
-- When the child is a plain Index Scan with no residual filter, skipped rows are
-- counted by advancing the index and checking the visibility map, so the heap is
-- only read for sampled rows. btree matches are never lossy, so no recheck runs.
-- =============================================================================

SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','indexSkipSample', FORMAT('{ "_id": %s, "value": %s }', g, g*10)::documentdb_core.bson, NULL) FROM generate_series(1, 50) g) ig;

-- Freeze so the visibility map marks every page all visible. The samples below
-- then run over an all-visible heap, so TrySkipHeapEntry can take the
-- VM_ALL_VISIBLE fast path (skip the heap, take only the page predicate lock).
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'indexSkipSample' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Plan: $match on _id (pushed into the _id btree index) + $sample.
-- Expect "Sample Reservoir Method: Heap Skip" over an Index Scan using _id_.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "indexSkipSample", "pipeline": [ { "$match": { "_id": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }');

-- Correctness on the all-visible heap: a sample of K (< population) returns
-- exactly K distinct documents from 50.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "indexSkipSample", "pipeline": [ { "$match": { "_id": { "$gte": 0 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Oversample: requesting more than the population returns every document once.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "indexSkipSample", "pipeline": [ { "$match": { "_id": { "$gte": 0 } } }, { "$sample": { "size": 100 } } ] }')) t;

-- Update _id 25's unindexed "value" field. The write clears the visibility map
-- bit for that page. SQL output can't observe which branch ran, so the two
-- queries below are correctness guards rather than path assertions. First, an
-- oversample (size >= population never skips, so every row is read) must surface
-- the refreshed value; a stale read would drop 99999.
SELECT documentdb_api.update('reservoirdb', '{ "update": "indexSkipSample", "updates": [ { "q": { "_id": 25 }, "u": { "$set": { "value": 99999 } } } ] }');
SELECT count(*) AS updated_seen FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "indexSkipSample", "pipeline": [ { "$match": { "_id": { "$gte": 0 } } }, { "$sample": { "size": 100 } } ] }')) t WHERE document::text LIKE '%99999%';

-- Then a subset sample (size < population) does skip rows, so it reaches the
-- page whose visibility map bit was cleared through index_fetch_heap and must
-- still return exactly K distinct documents.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "indexSkipSample", "pipeline": [ { "$match": { "_id": { "$gte": 0 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Flag off: falls back to "Sample Reservoir Method: Materialize".
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "indexSkipSample", "pipeline": [ { "$match": { "_id": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }');

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- HEAP-SKIP MODE OVER A LOSSY (RUM) INDEX
-- A wildcard index produces a plain Index Scan whose matches can be lossy
-- (xs_recheck set per row). Heap skip still applies: the lossy rows are fetched
-- from the heap and rechecked, so a false positive never joins the sample. The
-- index qual lives in the Index Cond (no residual Filter), so the scan stays
-- eligible.
-- =============================================================================

-- value = id*10; tags is an array, so range predicates over it are lossy on the
-- wildcard index, exercising the recheck branch.
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','rumHeapSkipSample', FORMAT('{ "_id": %s, "value": %s, "tags": [ %s, %s ] }', g, g*10, g, g+1)::documentdb_core.bson, NULL) FROM generate_series(1, 60) g) ig;

-- Build the wildcard (RUM) index and freeze so the visibility map is set.
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "rumHeapSkipSample", "indexes": [ { "key": { "$**": 1 }, "name": "wildcard_all" } ] }', TRUE);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'rumHeapSkipSample' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Plan: $match (value > 100) maps to the wildcard Index Scan as an Index Cond
-- with no residual Filter. Expect "Sample Reservoir Method: Heap Skip".
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumHeapSkipSample", "pipeline": [ { "$match": { "value": { "$gt": 100 } } }, { "$sample": { "size": 5 } } ] }');

-- Subset correctness: value > 100 matches _id 11..60 (50 rows). A sample of 10
-- returns exactly 10 distinct docs, all in range (no lossy false positive).
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "value": { "$gt": 100 } }'::bson)) AS not_matching
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumHeapSkipSample", "pipeline": [ { "$match": { "value": { "$gt": 100 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Oversample (size >= matches) returns exactly the matched set.
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumHeapSkipSample", "pipeline": [ { "$match": { "value": { "$gt": 540 } } }, { "$sample": { "size": 100 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- Multikey lossy match: tags >= 30 returns the same heap TID once per qualifying
-- array element. The recheck still keeps every sampled doc within the filter.
SELECT count(*) FILTER (WHERE NOT (document @@ '{ "tags": { "$gte": 30 } }'::bson)) AS not_matching
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumHeapSkipSample", "pipeline": [ { "$match": { "tags": { "$gte": 30 } } }, { "$sample": { "size": 8 } } ] }')) t;

-- Flag off: the same lossy index scan falls back to "Sample Reservoir Method: Materialize".
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumHeapSkipSample", "pipeline": [ { "$match": { "value": { "$gt": 100 } } }, { "$sample": { "size": 5 } } ] }');

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- HEAP-SKIP MODE OVER RUM INDEXES: INDEX SHAPE AND PREDICATE VARIETY
-- Heap skip applies to any plain Index Scan over a RUM index whose $match lands
-- entirely in the Index Cond (no residual Filter). These cases cover range,
-- equality, $in, a nested path, a string key and a multikey array. Each EXPLAIN
-- shows "Sample Reservoir Method: Heap Skip" and each result stays in range.
-- =============================================================================

-- a is a scalar, s a string, nested.x a nested scalar, b a two element array.
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','rumVariety', FORMAT('{ "_id": %s, "a": %s, "s": "k%s", "nested": { "x": %s }, "b": [ %s, %s ] }', g, g, lpad(g::text, 3, '0'), g*2, g, g+100)::documentdb_core.bson, NULL) FROM generate_series(1, 80) g) ig;

SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "rumVariety", "indexes": [ { "key": { "a": 1 }, "name": "a_1" }, { "key": { "s": 1 }, "name": "s_1" }, { "key": { "nested.x": 1 }, "name": "nx_1" }, { "key": { "b": 1 }, "name": "b_1" } ] }', TRUE);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'rumVariety' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Range $gt on a scalar index.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": { "$gt": 10 } } }, { "$sample": { "size": 5 } } ] }');
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "a": { "$gt": 10 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": { "$gt": 10 } } }, { "$sample": { "size": 5 } } ] }')) t;

-- Equality on a scalar index; population is a single document.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": 42 } }, { "$sample": { "size": 5 } } ] }');
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": 42 } }, { "$sample": { "size": 5 } } ] }')) t;

-- $in over a scalar index.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3, 50, 60 ] } } }, { "$sample": { "size": 3 } } ] }');
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "a": { "$in": [ 1, 2, 3, 50, 60 ] } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3, 50, 60 ] } } }, { "$sample": { "size": 3 } } ] }')) t;
-- Oversample (size >= matches) returns exactly the five matched documents.
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": { "$in": [ 1, 2, 3, 50, 60 ] } } }, { "$sample": { "size": 100 } }, { "$sort": { "a": 1 } }, { "$project": { "_id": 0, "a": 1 } } ] }');

-- Range on a nested path index.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "nested.x": { "$gte": 100 } } }, { "$sample": { "size": 4 } } ] }');
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "nested.x": { "$gte": 100 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "nested.x": { "$gte": 100 } } }, { "$sample": { "size": 4 } } ] }')) t;

-- Range on a string key index.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "s": { "$gt": "k040" } } }, { "$sample": { "size": 4 } } ] }');
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "s": { "$gt": "k040" } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "s": { "$gt": "k040" } } }, { "$sample": { "size": 4 } } ] }')) t;

-- Multikey array index: array-element matches are lossy, so the recheck drops false positives.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "b": { "$gte": 150 } } }, { "$sample": { "size": 4 } } ] }');
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "b": { "$gte": 150 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "b": { "$gte": 150 } } }, { "$sample": { "size": 4 } } ] }')) t;

-- Sample size of one over the range scan.
SELECT count(*) AS cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": { "$gt": 10 } } }, { "$sample": { "size": 1 } } ] }')) t;

-- Flag off: the same scalar index scan falls back to "Sample Reservoir Method: Materialize".
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "rumVariety", "pipeline": [ { "$match": { "a": { "$gt": 10 } } }, { "$sample": { "size": 5 } } ] }');

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- MATERIALIZE MODE: ineligible child shapes
-- Heap skip only applies to a plain Index Scan with no residual Filter. With the
-- flag on, the reservoir still falls back to "Sample Reservoir Method: Materialize" when
-- the child is a Seq Scan or an Index Scan that carries a residual Filter (part of
-- the $match not pushed into the Index Cond). Each case must still sample
-- correctly: K distinct documents from the matched set.
-- =============================================================================

-- a is indexed, b is left unindexed so predicates on it become a Seq Scan or a
-- residual Filter.
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','matSample', FORMAT('{ "_id": %s, "a": %s, "b": %s }', g, g, g % 5)::documentdb_core.bson, NULL) FROM generate_series(1, 60) g) ig;
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "matSample", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'matSample' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;

-- Seq Scan child: $match on the unindexed field b. Expect Materialize.
SET enable_seqscan TO on;
SET enable_indexscan TO off;
SET enable_bitmapscan TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "matSample", "pipeline": [ { "$match": { "b": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }');
-- Correctness: b >= 0 matches all 60; a sample of 10 is 10 distinct documents.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "matSample", "pipeline": [ { "$match": { "b": { "$gte": 0 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Index Scan with a residual Filter: a maps to the Index Cond but the unindexed
-- b predicate stays as a Filter, so the scan is ineligible. Expect Materialize.
SET enable_seqscan TO off;
SET enable_indexscan TO on;
SET enable_bitmapscan TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "matSample", "pipeline": [ { "$match": { "a": { "$gte": 10 }, "b": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }');
-- Correctness: a >= 10 and b >= 0 matches 51; a sample of 10 is 10 distinct documents.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "matSample", "pipeline": [ { "$match": { "a": { "$gte": 10 }, "b": { "$gte": 0 } } }, { "$sample": { "size": 10 } } ] }')) t;

RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET documentdb.forceUseIndexIfAvailable;
RESET documentdb.enableDollarSampleHeapSkipReservoirScan;

-- =============================================================================
-- HEAP-SKIP MODE: DEAD TUPLES, EMPTY POPULATION, AND SIZE BOUNDARIES
-- Paths the other sections don't reach: dead index entries (deleted but not yet
-- vacuumed) that the skip phase must not count, an empty match set, and sizes 0
-- and 1.
-- =============================================================================

SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','extraHS', FORMAT('{ "_id": %s, "a": %s }', g, g)::documentdb_core.bson, NULL) FROM generate_series(1, 60) g) ig;
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "extraHS", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'extraHS' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Delete a >= 31 (30 rows) without vacuuming, leaving dead index entries. Live
-- rows are a = 1..30.
SELECT documentdb_api.delete('reservoirdb', '{ "delete": "extraHS", "deletes": [ { "q": { "a": { "$gte": 31 } }, "limit": 0 } ] }');

-- An oversample (size > live population) never fills the reservoir, so the skip
-- phase stays off. Plain correctness check that deleted rows are not returned.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE document @@ '{ "a": { "$gte": 31 } }'::bson) AS deleted_seen
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "extraHS", "pipeline": [ { "$match": { "a": { "$gte": 1 } } }, { "$sample": { "size": 100 } } ] }')) t;

-- A subset sample (size 10 < 30 live rows) fills the reservoir, so the skip phase
-- engages and walks the dead index entries. They fetch the heap, fail the MVCC
-- visibility check, and are not counted, so exactly 10 distinct live rows come
-- back with no deleted documents.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE document @@ '{ "a": { "$gte": 31 } }'::bson) AS deleted_seen
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "extraHS", "pipeline": [ { "$match": { "a": { "$gte": 1 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Empty match set: Heap Skip plan, zero rows out.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "extraHS", "pipeline": [ { "$match": { "a": { "$gte": 100000 } } }, { "$sample": { "size": 5 } } ] }');
SELECT count(*) AS cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "extraHS", "pipeline": [ { "$match": { "a": { "$gte": 100000 } } }, { "$sample": { "size": 5 } } ] }')) t;

-- Size 0: empty result.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "extraHS", "pipeline": [ { "$match": { "a": { "$gte": 1 } } }, { "$sample": { "size": 0 } } ] }');
SELECT count(*) AS cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "extraHS", "pipeline": [ { "$match": { "a": { "$gte": 1 } } }, { "$sample": { "size": 0 } } ] }')) t;

-- Size 1: one document.
SELECT count(*) AS cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "extraHS", "pipeline": [ { "$match": { "a": { "$gte": 1 } } }, { "$sample": { "size": 1 } } ] }')) t;

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- HEAP-SKIP MODE: DESCENDING-KEY INDEX
-- Heap skip works over a descending-key index. (The scan still runs forward; a
-- true backward scan can't arise from $sample, since any sort sits above the
-- reservoir rather than feeding the scan.)
-- =============================================================================

SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','descHS', FORMAT('{ "_id": %s, "a": %s }', g, g)::documentdb_core.bson, NULL) FROM generate_series(1, 60) g) ig;
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "descHS", "indexes": [ { "key": { "a": -1 }, "name": "a_desc" } ] }', true);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'descHS' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Expect "Sample Reservoir Method: Heap Skip" over the a_desc index.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "descHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 5 } } ] }');
-- a >= 10 matches 51; a sample of 10 is 10 distinct in-range docs.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "a": { "$gte": 10 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "descHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 10 } } ] }')) t;

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- HEAP-SKIP MODE: SHARDED COLLECTION (does not engage)
-- A sharded $sample takes the Sort-on-random() plus Limit path, so the reservoir
-- (and heap skip) never engages. The plan has no ReservoirSample node.
-- =============================================================================

SELECT documentdb_api.create_collection('reservoirdb', 'shardHS');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','shardHS', FORMAT('{ "_id": %s, "a": %s }', g, g)::documentdb_core.bson, NULL) FROM generate_series(1, 60) g) ig;
SELECT documentdb_api.shard_collection('reservoirdb','shardHS', '{ "_id": "hashed" }', false);
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "shardHS", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- No ReservoirSample node; a Sort on random() with a Limit instead.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "shardHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 5 } } ] }');
-- a >= 10 matches 51; a sample of 10 is 10 distinct in-range docs.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "a": { "$gte": 10 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "shardHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 10 } } ] }')) t;

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- ORDER BY (vector) SCAN + $sample: reservoir sampling must NOT engage
-- An ordering operator Index Scan (vector search) reaches $sample through a Sort
-- on random() plus a Limit, so the reservoir custom scan is never applied to it
-- (and heap skip, which only exists inside that scan, is never reached). This
-- pins that behavior with the flag on: the plan keeps the ordered Index Scan
-- under a Sort (no ReservoirSample node) and the results stay correct over the
-- set of nearest neighbors.
-- TODO: support reservoir sampling on upper paths (e.g. above $unwind, $search).
-- =============================================================================

-- v = [id/10, 0, 0]; nearest to [0,0,0] under L2 is the smallest id.
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','vecSample', FORMAT('{ "_id": %s, "v": [ %s, 0, 0 ] }', g, g::float8/10)::documentdb_core.bson, NULL) FROM generate_series(1, 10) g) ig;

SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "vecSample", "indexes": [ { "key": { "v": "cosmosSearch" }, "cosmosSearchOptions": { "kind": "vector-ivf", "numLists": 1, "similarity": "L2", "dimensions": 3 }, "name": "vidx" } ] }', TRUE);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'vecSample' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Plan: vector search becomes a Sort on random() plus a Limit over the ordered
-- Index Scan. No ReservoirSample custom scan and no "Sample Reservoir Method" line appear.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "vecSample", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [ 0, 0, 0 ], "path": "v", "k": 5 } } }, { "$sample": { "size": 3 } } ] }');

-- Oversample (size >= k) over the 5 nearest returns exactly those 5 documents.
SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "vecSample", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [ 0, 0, 0 ], "path": "v", "k": 5 } } }, { "$sample": { "size": 50 } }, { "$sort": { "_id": 1 } }, { "$project": { "_id": 1 } } ] }');

-- Subset (size < k): exactly 3 distinct docs, all drawn from the 5 nearest.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "_id": { "$lte": 5 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "vecSample", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [ 0, 0, 0 ], "path": "v", "k": 5 } } }, { "$sample": { "size": 3 } } ] }')) t;

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- HEAP-SKIP MODE: bitmap heap scan conversion
-- A Bitmap Heap Scan whose bitmapqual is a single Bitmap Index Scan is rewritten
-- to a plain Index Scan so heap skip can engage, but only when the index covers
-- every restriction. A multi-index bitmap (BitmapOr / BitmapAnd) or a residual
-- filter is left untouched, and with the flag off no conversion happens.
-- =============================================================================
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','bitmapConv', FORMAT('{ "_id": %s, "a": %s, "b": %s, "c": %s }', g, g, g % 7, g)::documentdb_core.bson, NULL) FROM generate_series(1, 200) g) ig;
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "bitmapConv", "indexes": [ { "key": { "a": 1 }, "name": "a_1" }, { "key": { "b": 1 }, "name": "b_1" } ] }', true);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'bitmapConv' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET enable_indexscan TO off;
SET enable_bitmapscan TO on;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Single-index bitmap: only a Bitmap Heap Scan over a_1 is available. It is
-- rewritten to an Index Scan, so expect "Sample Reservoir Method: Heap Skip".
-- Wrapped in run_explain_and_trim to strip the PG18-only "Disabled: true" line that
-- appears because the Index Scan is produced while enable_indexscan is off.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "a": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }') $$);
-- Correctness: a >= 0 matches all 200; a sample of 10 is 10 distinct documents.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "a": { "$gte": 0 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Multi-clause single index: a range on "a" yields two index clauses (>= and <=),
-- both covered by a_1. The coverage check passes on every clause, so the bitmap is
-- still rewritten to an Index Scan. Expect "Sample Reservoir Method: Heap Skip".
-- Wrapped in run_explain_and_trim to strip the PG18-only "Disabled: true" line that
-- appears because the Index Scan is produced while enable_indexscan is off.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "a": { "$gte": 10, "$lte": 50 } } }, { "$sample": { "size": 5 } } ] }') $$);
-- Correctness: 10 <= a <= 50 matches 41; a sample of 10 is 10 distinct documents.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "a": { "$gte": 10, "$lte": 50 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Residual filter: c is not indexed, so a bitmap over a_1 keeps a Filter on c.
-- The index does not cover every restriction, so the bitmap is left as is and
-- the plan stays Materialize (converting would gain no heap skip).
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "a": { "$gte": 0 }, "c": { "$gte": 0 } } }, { "$sample": { "size": 3 } } ] }');

-- Multi-index bitmap: a $or across a_1 and b_1 builds a BitmapOr, which is not a
-- single Bitmap Index Scan, so the Bitmap Heap Scan is left as is. Expect Materialize.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "$or": [ { "a": { "$gte": 190 } }, { "b": { "$eq": 3 } } ] } }, { "$sample": { "size": 3 } } ] }');
-- Correctness: the $or matches a mix; a sample of 5 stays distinct.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "$or": [ { "a": { "$gte": 190 } }, { "b": { "$eq": 3 } } ] } }, { "$sample": { "size": 5 } } ] }')) t;

-- Flag off: the single-index bitmap is not converted. Expect Materialize.
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapConv", "pipeline": [ { "$match": { "a": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }');

RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET documentdb.forceUseIndexIfAvailable;
RESET documentdb.enableDollarSampleHeapSkipReservoirScan;

-- =============================================================================
-- HEAP-SKIP MODE: SURROUNDING PIPELINE STAGE COMBINATIONS
-- Stages around $sample keep the plain Index Scan child intact, so heap skip holds;
-- a $sample with no $match feeding it takes the system_rows tablesample instead.
-- =============================================================================

SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','stageHS', FORMAT('{ "_id": %s, "a": %s }', g, g)::documentdb_core.bson, NULL) FROM generate_series(1, 60) g) ig;
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "stageHS", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'stageHS' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- Bare $sample (no $match): nothing drives an Index Scan, so $sample takes the
-- system_rows tablesample fast path. No reservoir scan and no heap skip.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$sample": { "size": 5 } } ] }');
-- Correctness: a sample of 10 from 60 is 10 distinct documents.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$sample": { "size": 10 } } ] }')) t;

-- $match + $sample + $project: the $project is applied above the reservoir. Expect Heap Skip.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 5 } }, { "$project": { "_id": 1 } } ] }');
-- Correctness: a >= 10 matches 51; a sample of 10 keeps 10 distinct _id values.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 10 } }, { "$project": { "_id": 1 } } ] }')) t;

-- $match + $sample + $sort: the $sort is applied above the reservoir. Expect Heap Skip.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 5 } }, { "$sort": { "a": 1 } } ] }');
-- Correctness: a >= 10 matches 51; a sample of 10 is 10 distinct in-range docs.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "a": { "$gte": 10 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 10 } }, { "$sort": { "a": 1 } } ] }')) t;

-- $match + $sample + $skip + $limit: skip/limit are applied above the reservoir. Expect Heap Skip.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 20 } }, { "$skip": 2 }, { "$limit": 5 } ] }');
-- Correctness: sampling 20 then skipping 2 and limiting to 5 yields 5 distinct in-range docs.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "a": { "$gte": 10 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$sample": { "size": 20 } }, { "$skip": 2 }, { "$limit": 5 } ] }')) t;

-- $sample followed by $match: the $match sits above $sample and does not feed an
-- Index Scan, so $sample still takes the system_rows tablesample (no reservoir).
-- The trailing $match then filters the sampled rows.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$sample": { "size": 20 } }, { "$match": { "a": { "$gte": 10 } } } ] }');
-- Correctness: an oversample (size >= 60) returns every doc once, so the trailing
-- $match yields exactly the 51 in-range docs and none out of range.
SELECT count(*) AS cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "a": { "$gte": 10 } }'::bson)) AS out_of_range
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$sample": { "size": 100 } }, { "$match": { "a": { "$gte": 10 } } } ] }')) t;

-- $match + $project + $sample: the $project ahead of $sample is applied above the
-- Index Scan, so an eligible plain Index Scan child remains and heap skip engages.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$project": { "_id": 1, "a": 1 } }, { "$sample": { "size": 5 } } ] }');
-- Correctness: a >= 10 matches 51; a sample of 10 keeps 10 distinct docs.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "stageHS", "pipeline": [ { "$match": { "a": { "$gte": 10 } } }, { "$project": { "_id": 1, "a": 1 } }, { "$sample": { "size": 10 } } ] }')) t;

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- HEAP-SKIP MODE: partial-index coverage detection (Index Scan and Bitmap Scan)
-- A partial index predicate implies part of the match, so that clause never
-- becomes a residual Filter. Coverage is checked against indrestrictinfo, which
-- for a partial index already excludes clauses the predicate implies (unlike
-- baserestrictinfo). This must hold for both eligibility paths:
--   - a plain Index Scan child (IsHeapSkipEligible), and
--   - a Bitmap Heap Scan child rewritten to an Index Scan (bitmap conversion).
-- In each, a match fully covered by the index heap skips, while a match with a
-- clause on an unindexed field (a residual Filter) falls back to Materialize.
-- =============================================================================
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('reservoirdb','bitmapPartial', FORMAT('{ "_id": %s, "a": %s, "b": %s, "c": %s }', g, g, g, g)::documentdb_core.bson, NULL) FROM generate_series(1, 200) g) ig;
SELECT documentdb_api_internal.create_indexes_non_concurrently('reservoirdb', '{ "createIndexes": "bitmapPartial", "indexes": [ { "key": { "a": 1 }, "name": "a_partial", "partialFilterExpression": { "b": { "$gt": 100 } } } ] }', true);
SELECT collection_id AS reservoir_col FROM documentdb_api_catalog.collections WHERE database_name = 'reservoirdb' AND collection_name = 'bitmapPartial' \gset
SELECT FORMAT('VACUUM (FREEZE ON) documentdb_data.documents_%s', :reservoir_col) \gexec

SET documentdb.enableDollarSampleReservoirScan TO on;
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;

-- --- Plain Index Scan child (enable_indexscan on, enable_bitmapscan off) ---
SET enable_indexscan TO on;
SET enable_bitmapscan TO off;

-- Covered: a >= 0 is the index clause; b > 100 matches the partial predicate, so
-- it is implied and never becomes a Filter. indrestrictinfo carries no residual,
-- so the plain Index Scan is eligible. Expect "Sample Reservoir Method: Heap Skip".
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapPartial", "pipeline": [ { "$match": { "a": { "$gte": 0 }, "b": { "$gt": 100 } } }, { "$sample": { "size": 5 } } ] }') $$);

-- Not covered: c is unindexed and not implied by the partial predicate, so it
-- remains in indrestrictinfo as a residual Filter on the Index Scan. The scan is
-- ineligible. Expect "Sample Reservoir Method: Materialize".
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapPartial", "pipeline": [ { "$match": { "a": { "$gte": 0 }, "b": { "$gt": 100 }, "c": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }') $$);

-- --- Bitmap Heap Scan child (enable_indexscan off, enable_bitmapscan on) ---
SET enable_indexscan TO off;
SET enable_bitmapscan TO on;

-- Covered: the single-index bitmap is rewritten to an Index Scan because every
-- indrestrictinfo clause is redundant with the index clauses (b implied by the
-- partial predicate). Expect "Sample Reservoir Method: Heap Skip".
-- Wrapped in run_explain_and_trim to strip the PG18-only "Disabled: true" line
-- that appears because the Index Scan is produced while enable_indexscan is off.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapPartial", "pipeline": [ { "$match": { "a": { "$gte": 0 }, "b": { "$gt": 100 } } }, { "$sample": { "size": 5 } } ] }') $$);
-- Correctness: b > 100 matches _id 101..200 (100 docs); a sample of 10 keeps 10
-- distinct documents, all within the filter.
SELECT count(*) AS cnt, count(DISTINCT document) AS distinct_cnt,
       count(*) FILTER (WHERE NOT (document @@ '{ "b": { "$gt": 100 } }'::bson)) AS not_matching
FROM (SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapPartial", "pipeline": [ { "$match": { "a": { "$gte": 0 }, "b": { "$gt": 100 } } }, { "$sample": { "size": 10 } } ] }')) t;

-- Not covered: c remains a residual Filter, so indrestrictinfo is not fully
-- redundant with the index clauses and the bitmap is left as a Bitmap Heap Scan
-- (converting would gain no heap skip). Expect "Sample Reservoir Method: Materialize".
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapPartial", "pipeline": [ { "$match": { "a": { "$gte": 0 }, "b": { "$gt": 100 }, "c": { "$gte": 0 } } }, { "$sample": { "size": 5 } } ] }') $$);

-- Flag off: no conversion, so the bitmap stays and the plan falls back to Materialize.
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('reservoirdb', '{ "aggregate": "bitmapPartial", "pipeline": [ { "$match": { "a": { "$gte": 0 }, "b": { "$gt": 100 } } }, { "$sample": { "size": 5 } } ] }') $$);

RESET documentdb.enableDollarSampleHeapSkipReservoirScan;
RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET documentdb.forceUseIndexIfAvailable;

-- =============================================================================
-- CLEANUP
-- =============================================================================

RESET documentdb.enableDollarSampleReservoirScan;

