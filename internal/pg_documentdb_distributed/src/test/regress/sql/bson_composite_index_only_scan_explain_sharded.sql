SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET citus.next_shard_id TO 9200000;
SET documentdb.next_collection_id TO 92000;
SET documentdb.next_collection_index_id TO 92000;
SET documentdb.enableExtendedExplainPlans to on;
SET documentdb.enableIndexOnlyScan to on;

-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname
FROM pg_extension
WHERE extname = 'documentdb_extended_rum';

-- Verify IOS pushes down to shard workers for covered $group on sharded collection.
-- This test is in a separate file because distributed EXPLAIN with $group
-- hits a known Citus cstring pseudo-type serialization bug on PG 15/16.
SELECT documentdb_api.create_collection('idx_only_scan_explain_db', 'ios_sharded_accum_explain');

SELECT COUNT(documentdb_api.insert_one('idx_only_scan_explain_db', 'ios_sharded_accum_explain',
    bson_build_document('_id', i, 'city', CASE WHEN i % 3 = 0 THEN 'NYC' WHEN i % 3 = 1 THEN 'Seattle' ELSE 'Chicago' END,
                        'rent', 1000 + (i * 100), 'sqft', 200 + (i * 50))))
FROM generate_series(1, 30) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('idx_only_scan_explain_db',
    '{ "createIndexes": "ios_sharded_accum_explain", "indexes": [ { "key": { "city": 1, "rent": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "city_rent_1" }] }', true);

SELECT documentdb_api.shard_collection('{ "shardCollection": "idx_only_scan_explain_db.ios_sharded_accum_explain", "key": { "_id": "hashed" } }');

VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_92001;

set citus.propagate_set_commands to 'local';
BEGIN;
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;
set local citus.explain_analyze_sort_method to taskId;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim(
       $$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_explain_db', '{ "aggregate" : "ios_sharded_accum_explain", "pipeline" : [{ "$group" : { "_id" : "$city", "cnt" : { "$sum" : 1 } } }, { "$sort": { "_id": 1 } }], "cursor" : {}}')$$,
       p_ignore_heap_fetches => true,
       p_ignore_distributed_runtime_details => true
);
ROLLBACK;
