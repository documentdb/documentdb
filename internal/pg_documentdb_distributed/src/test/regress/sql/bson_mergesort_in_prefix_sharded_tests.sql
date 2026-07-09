-- Sharded coverage for merge-sort pushdown when an $in filter is an equality
-- prefix of the sort key on a composite (order-capable) index.
--
-- Distributed behavior depends on whether the per-shard task query carries an
-- ORDER BY:
--   * With a LIMIT, the engine pushes "ORDER BY <sort> LIMIT n" into each shard
--     task query (top-N pushdown). That gives the shard-local planner the pathkeys
--     the rewrite needs, so each shard produces "Limit -> Merge Append" over one
--     ordered index scan per $in value (early termination). The coordinator merges
--     and re-applies the limit. This is the case this suite anchors on -- it is the
--     stable, observable win on the current engine.
--   * Without a LIMIT, the shard task query has no ORDER BY (ordering happens only
--     at the coordinator), so the rewrite does not engage on the shard and the
--     coordinator keeps its blocking Sort. We therefore only assert correctness for
--     the no-LIMIT case, not a plan shape (which is engine-version dependent).
--
-- Gated by documentdb.enable_merge_sort_for_in_prefix (default off); with the flag off
-- the plan must remain the existing coordinator blocking Sort.
SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET citus.next_shard_id TO 7900000;
SET documentdb.next_collection_id TO 79000;
SET documentdb.next_collection_index_id TO 79000;
SET documentdb.enableExtendedExplainPlans TO on;

-- if documentdb_extended_rum exists, set the alternate index handler so suffix
-- order-by pushdown (which this optimization depends on) is available.
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname
FROM pg_extension WHERE extname = 'documentdb_extended_rum';

-- =====================================================================
-- Setup: composite term index {a:1,b:1}, sharded on _id (hashed) so an
-- $in on the prefix path "a" spans every shard (exercises coordinator merge).
-- Data is chosen so that, within the {a in [1,4]} selection, the sort-key
-- values for b are distinct, making sort {b:1} deterministic without a
-- tiebreaker. Expected b ascending: 0,1,2,3,5,7,9.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 3, "a": 1, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 4, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 5, "a": 2, "b": 4 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 6, "a": 1, "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 7, "a": 4, "b": 7 }');
SELECT documentdb_api.insert_one('msdb','coll','{ "_id": 8, "a": 1, "b": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "enableCompositeTerm": true, "name": "a_1_b_1" } ] }', true);

SELECT documentdb_api.shard_collection('{ "shardCollection": "msdb.coll", "key": { "_id": "hashed" }, "numInitialChunks": 2 }');

ANALYZE documentdb_data.documents_79001;

-- =====================================================================
-- Correctness (no LIMIT): results must be identical with the feature OFF and
-- ON, and ordered by b ascending (0,1,2,3,5,7,9).
-- =====================================================================
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 } }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Correctness (LIMIT 3): top-N must be identical with the feature OFF and ON
-- (b = 0,1,2).
-- =====================================================================
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Plan shape with feature OFF (LIMIT 3): coordinator blocking Sort over the
-- per-shard scan. Rollout-default guard -- must remain unchanged.
-- =====================================================================
SET documentdb.enable_merge_sort_for_in_prefix TO off;
BEGIN;
SET LOCAL citus.propagate_set_commands TO 'local';
SET LOCAL citus.max_adaptive_executor_pool_size TO 1;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL citus.explain_analyze_sort_method TO taskId;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_sort TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim(
    $$ EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
       SELECT document FROM bson_aggregation_find('msdb',
         '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }') $$,
    p_ignore_heap_fetches => true,
    p_ignore_distributed_runtime_details => true);
ROLLBACK;
RESET documentdb.enable_merge_sort_for_in_prefix;

-- =====================================================================
-- Plan shape with feature ON (LIMIT 3): each shard task produces an ordered
-- "Limit -> Merge Append" over one index scan per $in value, with the limit
-- pushed into the task query. enable_sort is disabled so the assertion
-- deterministically isolates the merge path from the cost model's top-N choice.
-- =====================================================================
-- The feature flag must be SET LOCAL inside the transaction (not at session
-- level) so that citus.propagate_set_commands forwards it to the shard task
-- connections; otherwise the rewrite is off on the workers.
BEGIN;
SET LOCAL citus.propagate_set_commands TO 'local';
SET LOCAL documentdb.enable_merge_sort_for_in_prefix TO on;
SET LOCAL citus.max_adaptive_executor_pool_size TO 1;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL citus.explain_analyze_sort_method TO taskId;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_sort TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim(
    $$ EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
       SELECT document FROM bson_aggregation_find('msdb',
         '{ "find": "coll", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }') $$,
    p_ignore_heap_fetches => true,
    p_ignore_distributed_runtime_details => true);
ROLLBACK;

-- =====================================================================
-- $in on the shard key (prefix == shard key). Sharded on "a" (hashed) so an
-- $in on "a" prunes to a subset of shards; sort {b:1} should still be
-- mergeable shard-locally with a LIMIT. Correctness + plan shape ON.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 2, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 3, "a": 1, "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 4, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 5, "a": 2, "b": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 6, "a": 1, "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 7, "a": 4, "b": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_sk','{ "_id": 8, "a": 1, "b": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_sk", "indexes": [ { "key": { "a": 1, "b": 1 }, "enableCompositeTerm": true, "name": "a_1_b_1" } ] }', true);

SELECT documentdb_api.shard_collection('{ "shardCollection": "msdb.coll_sk", "key": { "a": "hashed" }, "numInitialChunks": 2 }');

ANALYZE documentdb_data.documents_79002;

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_sk", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- cleanup
SELECT documentdb_api.drop_collection('msdb','coll');
SELECT documentdb_api.drop_collection('msdb','coll_sk');
