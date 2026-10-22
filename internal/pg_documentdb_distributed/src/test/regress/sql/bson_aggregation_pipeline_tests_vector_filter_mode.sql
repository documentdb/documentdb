SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET citus.next_shard_id TO 10000000;
SET documentdb.next_collection_id TO 10000;
SET documentdb.next_collection_index_id TO 10000;
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO on;
SET documentdb.enableVectorPreFilter TO on;
SET documentdb.enableVectorPreFilterV2 TO off;

SELECT vartype = 'real' AS real_guc,
	   setting::float8 = 0.01 AS default_threshold,
	   min_val::float8 = 0 AS minimum_threshold,
	   max_val::float8 = 1 AS maximum_threshold
FROM pg_settings WHERE name LIKE '%.vector_auto_filter_selectivity_threshold';

-- Exercise filterMode with both vector index access methods available in OSS.
-- IVF
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_ivf', '{ "_id": 1, "meta": { "b": 1 }, "v": [3.0, 5.0, 1.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_ivf', '{ "_id": 2, "meta": { "b": 2 }, "v": [8.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_ivf', '{ "_id": 3, "meta": { "b": 3 }, "v": [13.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_ivf', '{ "_id": 4, "meta": { "b": 4 }, "v": [15.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_ivf', '{ "_id": 5, "meta": { "b": 1 } }');

SELECT documentdb_distributed_test_helpers.drop_primary_key('filter_mode_db', 'vector_filter_mode_ivf');
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_ivf", "indexes": [ { "key": { "meta.b": 1 }, "name": "filter_index" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_ivf", "indexes": [ { "key": { "v": "cosmosSearch" }, "name": "vector_index", "cosmosSearchOptions": { "kind": "vector-ivf", "numLists": 4, "similarity": "COS", "dimensions": 3 } } ] }', true);
ANALYZE;

SET documentdb.enableVectorPreFilter TO off;
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_ivf","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,5,0.1],"k":4,"path":"v","filter":{"meta.b":1},"filterMode":"approximate"}}}],"cursor":{}}');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_ivf","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,5,0.1],"k":4,"path":"v","filter":{"meta.b":1},"filterMode":"exact"}}}],"cursor":{}}');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_ivf","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,5,0.1],"k":4,"path":"v","filterMode":"autoSelect","filter":{"meta.b":1}}}}],"cursor":{}}');
SET documentdb.enableVectorPreFilter TO on;

SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": 1}, "nProbes": 4, "filterMode": "approximate" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }');

BEGIN;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": 1}, "nProbes": 4, "filterMode": "approximate" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
ROLLBACK;

SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": {"$gt": 1}}, "nProbes": 4, "filterMode": "exact" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }');
BEGIN;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": {"$gt": 1}}, "nProbes": 4, "filterMode": "exact" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.enableExplainScanIndexCosts TO on;
-- A selectivity threshold of 1 keeps this estimate on the filter path.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 1;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": 1}, "nProbes": 4, "filterMode": "autoSelect" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
-- A zero threshold sends this above-floor estimate to the vector index.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": {"$gt": 1}}, "nProbes": 4, "filterMode": "autoSelect" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
ROLLBACK;

-- exact must still exclude documents that lack the vector field even when
-- the filter itself matches them: _id 5 has meta.b=1 but no 'v', so the retained
-- bson_extract_vector(...) IS NOT NULL recheck must drop it and only _id 1 remains.
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 10, "path": "v", "filter": {"meta.b": 1}, "nProbes": 10, "filterMode": "exact" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
BEGIN;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 10, "path": "v", "filter": {"meta.b": 1}, "nProbes": 10, "filterMode": "exact" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);
ROLLBACK;

-- exact and approximate differ only in access path, not in results: for the
-- same filter, k, and query vector they must return the same documents in the
-- same distance order. nProbes=4 with numLists=4 scans every list so the vector
-- path is exact here, matching the filter path's explicit distance sort.
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": {"$gt": 1}}, "filterMode": "approximate" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_ivf", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": {"$gt": 1}}, "filterMode": "exact" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');

SELECT documentdb_api.drop_collection('filter_mode_db', 'vector_filter_mode_ivf');

-- HNSW
SET documentdb.enableVectorPreFilter TO off;
SET documentdb.enableVectorPreFilterV2 TO on;
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_hnsw', '{ "_id": 1, "meta": { "b": 1 }, "v": [3.0, 5.0, 1.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_hnsw', '{ "_id": 2, "meta": { "b": 2 }, "v": [8.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_hnsw', '{ "_id": 3, "meta": { "b": 3 }, "v": [13.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_hnsw', '{ "_id": 4, "meta": { "b": 4 }, "v": [15.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_hnsw', '{ "_id": 5, "meta": { "b": 1 } }');

SELECT documentdb_distributed_test_helpers.drop_primary_key('filter_mode_db', 'vector_filter_mode_hnsw');
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_hnsw", "indexes": [ { "key": { "meta.b": 1 }, "name": "filter_index" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_hnsw", "indexes": [ { "key": { "v": "cosmosSearch" }, "name": "vector_index", "cosmosSearchOptions": { "kind": "vector-hnsw", "m": 4, "efConstruction": 16, "similarity": "COS", "dimensions": 3 } } ] }', true);
ANALYZE;

SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_hnsw", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": 1}, "efSearch": 16, "filterMode": "approximate" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }');

BEGIN;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_hnsw", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": 1}, "efSearch": 16, "filterMode": "approximate" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
ROLLBACK;

SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_hnsw", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 10, "path": "v", "filter": {"meta.b": {"$gte": 1}}, "efSearch": 16, "filterMode": "exact" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_hnsw", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 10, "path": "v", "filter": {"meta.b": {"$gte": 1}}, "efSearch": 16, "filterMode": "exact" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);

-- Failed when seqscan was disabled and no non-vector path survived
BEGIN;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_hnsw", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": {"$gt": 1}}, "efSearch": 16, "filterMode": "exact" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.enableExplainScanIndexCosts TO on;
-- A selectivity threshold of 1 keeps this estimate on the filter path.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 1;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_hnsw", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": 1}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
-- A zero threshold sends this above-floor estimate to the vector index.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_hnsw", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"meta.b": {"$gt": 1}}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"rank": {"$round": [ {"$multiply": [{"$meta": "searchScore"}, 100000]}]} } } ], "cursor": {} }') $cmd$);
ROLLBACK;
SELECT documentdb_api.drop_collection('filter_mode_db', 'vector_filter_mode_hnsw');

-- filterMode 'autoSelect' estimates the filter from per-path statistics, so the
-- value kind a path holds and the number of conditions both feed the same
-- estimate. Cover string, boolean, and integer paths and conjunctions over
-- them, with compound indexes present so their two-expression statistics
-- objects are available to the estimate.
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 1, "s": "alpha", "f": true, "n": 10, "v": [3.0, 5.0, 1.1], "v2": [3.0, 5.0, 1.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 2, "s": "alpha", "f": false, "n": 20, "v": [8.0, 5.0, 0.1], "v2": [8.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 3, "s": "beta", "f": true, "n": 30, "v": [13.0, 5.0, 0.1], "v2": [13.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 4, "s": "beta", "f": false, "n": 40, "v": [15.0, 5.0, 0.1], "v2": [15.0, 5.0, 0.1] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 5, "s": "gamma", "f": true, "n": 10, "v": [2.0, 1.0, 0.5], "v2": [2.0, 1.0, 0.5] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 6, "s": "gamma", "f": false, "n": 20, "v": [4.0, 2.0, 0.5], "v2": [4.0, 2.0, 0.5] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 7, "s": "alpha", "f": true, "n": 30, "v": [12.0, 4.0, 0.2], "v2": [12.0, 4.0, 0.2] }');
-- No vector field: must never match, whichever path is chosen.
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_types', '{ "_id": 8, "s": "beta", "f": true, "n": 40}');

SELECT documentdb_distributed_test_helpers.drop_primary_key('filter_mode_db', 'vector_filter_mode_types');
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_types", "indexes": [ { "key": { "s": 1 }, "name": "string_index" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_types", "indexes": [ { "key": { "f": 1 }, "name": "bool_index" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_types", "indexes": [ { "key": { "n": 1 }, "name": "int_index" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_types", "indexes": [ { "key": { "n": 1, "s": 1, "f": 1 }, "name": "compound_nsf_index", "enableCompositeTerm": true } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_types", "indexes": [ { "key": { "v": "cosmosSearch" }, "name": "vector_index", "cosmosSearchOptions": { "kind": "vector-hnsw", "m": 4, "efConstruction": 16, "similarity": "COS", "dimensions": 3 } } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_types", "indexes": [ { "key": { "v2": "cosmosSearch" }, "name": "vector_index_v2", "cosmosSearchOptions": { "kind": "vector-ivf", "numLists": 4, "similarity": "COS", "dimensions": 3 } } ] }', true);
ANALYZE;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.enableExplainScanIndexCosts TO on;
-- A selectivity threshold of 1 keeps each estimate on the filter path.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 1;

-- Single condition on a string path.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"s": "alpha"}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- Single condition on a boolean path.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"f": true}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- Two conditions on different paths.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"s": "alpha", "f": true}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- Single condition on an integer path.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"n": 30}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);
-- An integer and a string condition, both keys of one compound index.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"n": 40, "s": "beta"}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- Three conditions spanning all three value kinds.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"n": { "$gt": 20 }, "s": "beta", "f": true}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- A zero threshold sends the same conjunction to the vector index instead.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"s": "alpha", "f": true}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);
ROLLBACK;

-- ivf vector index
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.enableExplainScanIndexCosts TO on;
-- A selectivity threshold of 1 keeps each estimate on the filter path.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 1;

-- Single condition on a string path.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v2", "filter": {"s": "alpha"}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- Single condition on a boolean path.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v2", "filter": {"f": true}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- Two conditions on different paths.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v2", "filter": {"s": "alpha", "f": true}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- Single condition on an integer path.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v2", "filter": {"n": 30}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);

-- A zero threshold sends the same conjunction to the vector index instead.
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v2", "filter": {"s": "alpha", "f": true}, "nProbes": 4, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }') $cmd$);
ROLLBACK;

-- three 'autoSelect' modes, the results must match exactly
-- check for a string and boolean condition, which is a compound index key
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"s": "beta", "f": true}, "efSearch": 16, "filterMode": "exact" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"s": "beta", "f": true}, "efSearch": 16, "filterMode": "approximate" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"s": "beta", "f": true}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');

-- check for a single boolean condition.
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"f": false}, "efSearch": 16, "filterMode": "exact" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"f": false}, "efSearch": 16, "filterMode": "approximate" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"f": false}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');

-- check for an integer condition combined with a string one.
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"n": 40, "s": "beta"}, "efSearch": 16, "filterMode": "exact" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"n": 40, "s": "beta"}, "efSearch": 16, "filterMode": "approximate" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_types", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0, 5.0, 0.1], "k": 4, "path": "v", "filter": {"n": 40, "s": "beta"}, "efSearch": 16, "filterMode": "autoSelect" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');

SELECT documentdb_api.drop_collection('filter_mode_db', 'vector_filter_mode_types');

-- Test for vector filter mode with n = entry_id % 4, selectivity is 1/4 = 0.25
SELECT count(documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_threshold',
	format('{"_id":%s,"n":%s,"v":[%s,1,1],"v6":[%s,1,1,1,1,1]}',
		   entry_id, entry_id % 4, entry_id, entry_id)::bson))
FROM generate_series(1, 512) AS entries(entry_id);
SELECT documentdb_distributed_test_helpers.drop_primary_key('filter_mode_db', 'vector_filter_mode_threshold');
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{"createIndexes":"vector_filter_mode_threshold","indexes":[{"key":{"n":1},"name":"filter_index"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{"createIndexes":"vector_filter_mode_threshold","indexes":[{"key":{"v":"cosmosSearch"},"name":"vector_index","cosmosSearchOptions":{"kind":"vector-ivf","numLists":4,"similarity":"COS","dimensions":3}}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{"createIndexes":"vector_filter_mode_threshold","indexes":[{"key":{"v6":"cosmosSearch"},"name":"vector_index_6d","cosmosSearchOptions":{"kind":"vector-ivf","numLists":4,"similarity":"COS","dimensions":6}}]}', true);
ANALYZE;

-- Test for different values of the vector_auto_filter_selectivity_threshold
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.01;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$);

SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.2;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$);

SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.3;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1,1,1,1],"path":"v6","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1,1,1,1],"path":"v6","k":40,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$);

SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 1;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$);

SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":5},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$);
ROLLBACK;

-- Test for vector filter mode with different statistics targets
BEGIN;
SET LOCAL enable_seqscan TO off;

-- estimated selectivity floor = 0.5
SET LOCAL default_statistics_target TO 2;
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.01;
SELECT bool_or(plan LIKE '%filter_index%') AS below_statistics_floor_uses_filter
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$) AS plan;
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0;
SELECT bool_or(plan LIKE '%filter_index%') AS zero_threshold_preserves_floor
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$) AS plan;

-- estimated selectivity floor = 0.2
SET LOCAL default_statistics_target TO 5;
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.01;
SELECT bool_or(plan LIKE '%Index Scan using vector_index%') AS changed_statistics_target_uses_vector
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$) AS plan;
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.75;
SELECT bool_or(plan LIKE '%filter_index%') AS configured_threshold_above_floor_uses_filter
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$) AS plan;

-- estimated selectivity floor = 1
SET LOCAL default_statistics_target TO 1;
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0;
SELECT bool_or(plan LIKE '%filter_index%') AS unit_statistics_floor_uses_filter
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filterMode":"autoSelect","filter":{"n":1}}}}],"cursor":{}}') $cmd$) AS plan;
SELECT bool_or(plan LIKE '%Index Scan using vector_index%') AS explicit_vector_ignores_auto_floor
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filterMode":"approximate","filter":{"n":1}}}}],"cursor":{}}') $cmd$) AS plan;
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO off;

-- estimated selectivity < threshold
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.26;
SELECT bool_or(plan LIKE '%filter_index%') AS below_threshold_uses_filter
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$) AS plan;

-- estimated selectivity > threshold
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.24;
SELECT bool_or(plan LIKE '%Index Scan using vector_index%') AS above_threshold_uses_vector
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$) AS plan;

-- estimated selectivity = threshold
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.25;
SELECT bool_or(plan LIKE '%filter_index%') AS equal_threshold_uses_filter
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{"aggregate":"vector_filter_mode_threshold","pipeline":[{"$search":{"cosmosSearch":{"vector":[13,1,1],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}') $cmd$) AS plan;
ROLLBACK;
SELECT documentdb_api.drop_collection('filter_mode_db', 'vector_filter_mode_threshold');

-- Each shard plans autoSelect from its local per-path statistics. 
-- Overall selectivity for n=1 is 36/1200 = 0.03
SELECT count(documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_multishard',
	format('{"_id":%s,"n":%s,"v":[%s], "padding":"%s"}',
		   entry_id, CASE WHEN entry_id <= 36 THEN 1 ELSE 2 END,
		   entry_id || repeat(',1', 15),
		   repeat('x', 8000)
		   )::bson))
FROM generate_series(1, 1200) AS entries(entry_id);

SELECT documentdb_distributed_test_helpers.drop_primary_key('filter_mode_db', 'vector_filter_mode_multishard');
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{"createIndexes":"vector_filter_mode_multishard","indexes":[{"key":{"n":1},"name":"filter_index"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{"createIndexes":"vector_filter_mode_multishard","indexes":[{"key":{"v":"cosmosSearch"},"name":"vector_index","cosmosSearchOptions":{"kind":"vector-hnsw","similarity":"COS","dimensions":16}}]}', true);
SELECT documentdb_api.shard_collection('{"shardCollection":"filter_mode_db.vector_filter_mode_multishard","key":{"_id":"hashed"},"numInitialChunks":3}');
ANALYZE;

-- force filter path
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL citus.explain_analyze_sort_method TO 'taskId';
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', ('{"aggregate":"vector_filter_mode_multishard","pipeline":[{"$search":{"cosmosSearch":{"vector":[500' || repeat(',1', 15) || '],"path":"v","k":4,"nProbes":4,"filter":{"n":1},"filterMode":"exact"}}}, { "$project":{"_id":1, "score": {"$meta": "searchScore"}}}],"cursor":{}}')::bson) $cmd$);
END;

-- the result of exact and approximate, they should be same when we have only few matching entries
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', ('{"aggregate":"vector_filter_mode_multishard","pipeline":[{"$search":{"cosmosSearch":{"vector":[500' || repeat(',1', 15) || '],"path":"v","k":4,"filter":{"n":1},"filterMode":"exact"}}}, {"$project":{"_id":1, "score": {"$meta": "searchScore"} } }],"cursor":{}}')::bson);
SELECT document FROM bson_aggregation_pipeline('filter_mode_db', ('{"aggregate":"vector_filter_mode_multishard","pipeline":[{"$search":{"cosmosSearch":{"vector":[500' || repeat(',1', 15) || '],"path":"v","k":4,"filter":{"n":1},"filterMode":"approximate"}}}, {"$project":{"_id":1, "score": {"$meta": "searchScore"} } }],"cursor":{}}')::bson);

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL citus.explain_analyze_sort_method TO 'taskId';
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', ('{"aggregate":"vector_filter_mode_multishard","pipeline":[{"$search":{"cosmosSearch":{"vector":[500' || repeat(',1', 15) || '],"path":"v","k":4,"nProbes":4,"filter":{"n":2},"filterMode":"approximate"}}}, {"$project":{"_id":1, "score": {"$meta": "searchScore"} } }],"cursor":{}}')::bson) $cmd$);
END;

BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL citus.explain_all_tasks TO on;
SET LOCAL documentdb.vector_auto_filter_selectivity_threshold TO 0.05;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SET LOCAL documentdb.enableExplainScanIndexCosts TO on;

-- n = 1, selectivity < threshold
SELECT count(*) = 3 AS low_selectivity_uses_filter_on_all_shards
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', ('{"aggregate":"vector_filter_mode_multishard","pipeline":[{"$search":{"cosmosSearch":{"vector":[500' || repeat(',1', 15) || '],"path":"v","k":4,"filter":{"n":1},"filterMode":"autoSelect"}}}],"cursor":{}}')::bson) $cmd$) AS plan
WHERE plan LIKE '%Index Scan using filter_index%';

-- n = 2, selectivity > threshold
SELECT count(*) = 3 AS high_selectivity_uses_vector_on_all_shards
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('filter_mode_db', ('{"aggregate":"vector_filter_mode_multishard","pipeline":[{"$search":{"cosmosSearch":{"vector":[500' || repeat(',1', 15) || '],"path":"v","k":4,"filter":{"n":2},"filterMode":"autoSelect"}}}],"cursor":{}}')::bson) $cmd$) AS plan
WHERE plan LIKE '%Index Scan using vector_index%';
ROLLBACK;

SELECT documentdb_api.drop_collection('filter_mode_db', 'vector_filter_mode_multishard');

SELECT coalesce(bool_or(feature_name = 'search_vector_pre_filter_autoselect_filter' AND usage_count > 0), false) AS filter_counter_recorded,
	   coalesce(bool_or(feature_name = 'search_vector_pre_filter_autoselect_vector' AND usage_count > 0), false) AS vector_counter_recorded
FROM documentdb_api_internal.command_feature_counter_stats(false);

RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enableVectorPreFilter;
RESET documentdb.enableVectorPreFilterV2;

-- filter mode is not supported for compressed indexes.
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_half', '{ "_id": 1, "meta": { "b": 1 }, "v": [3.0001, 5.0001, 1.1001] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_half', '{ "_id": 2, "meta": { "b": 1 }, "v": [8.0001, 5.0001, 0.1001] }');
SELECT documentdb_api.insert_one('filter_mode_db', 'vector_filter_mode_half', '{ "_id": 3, "meta": { "b": 2 }, "v": [13.0001, 5.0001, 0.1001] }');
SELECT documentdb_distributed_test_helpers.drop_primary_key('filter_mode_db', 'vector_filter_mode_half');
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_half", "indexes": [ { "key": { "meta.b": 1 }, "name": "filter_index" } ] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('filter_mode_db', '{ "createIndexes": "vector_filter_mode_half", "indexes": [ { "key": { "v": "cosmosSearch" }, "name": "vector_index", "cosmosSearchOptions": { "kind": "vector-hnsw", "m": 4, "efConstruction": 16, "similarity": "COS", "dimensions": 3, "compression": "half" } } ] }', true);
ANALYZE;

SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_half", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0001, 5.0001, 0.1001], "k": 2, "path": "v", "filter": {"meta.b": 1}, "efSearch": 16, "filterMode": "exact" } } }, { "$project": {"_id": 1} } ], "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_half", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0001, 5.0001, 0.1001], "k": 2, "path": "v", "filter": {"meta.b": 1}, "efSearch": 16, "filterMode": "autoSelect" } } } ], "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('filter_mode_db', '{ "aggregate": "vector_filter_mode_half", "pipeline": [ { "$search": { "cosmosSearch": { "vector": [13.0001, 5.0001, 0.1001], "k": 2, "path": "v", "filter": {"meta.b": 1}, "efSearch": 16, "filterMode": "approximate" } } } ], "cursor": {} }');

SELECT documentdb_api.drop_collection('filter_mode_db', 'vector_filter_mode_half');
