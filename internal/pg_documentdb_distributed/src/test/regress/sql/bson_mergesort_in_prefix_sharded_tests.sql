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

-- =====================================================================
-- Multi-key coverage. Every document's prefix array a = [1,2,3,4,5] matches all
-- five $in branches, so each document is reached through all five MergeAppend
-- children: the per-shard raw merged stream has 5x as many rows as documents.
-- Sharded on _id (hashed) so the $in spans shards and each document lives on a
-- single shard -- its cross-branch duplicates therefore arise within that
-- shard's scan and are removed by the shard-local heap-TID de-dup, so the
-- coordinator merge introduces no new duplicates.
--
-- This pins the LIMIT invariant under sharding: the Limit must count UNIQUE
-- emitted rows, not the raw merged rows. LIMIT 3 returns 3 distinct documents
-- (b = 1,2,3), identical feature off vs on; if the Limit counted raw rows it
-- would return one document repeated. With a LIMIT the engine pushes
-- "ORDER BY b LIMIT 3" into each shard task, so the rewrite (and its de-dup)
-- engages shard-locally.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 1, "a": [1, 2, 3, 4, 5], "b": 1 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 2, "a": [1, 2, 3, 4, 5], "b": 2 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 3, "a": [1, 2, 3, 4, 5], "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 4, "a": [1, 2, 3, 4, 5], "b": 4 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 5, "a": [1, 2, 3, 4, 5], "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 6, "a": [1, 2, 3, 4, 5], "b": 6 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 7, "a": [1, 2, 3, 4, 5], "b": 7 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 8, "a": [1, 2, 3, 4, 5], "b": 8 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 9, "a": [1, 2, 3, 4, 5], "b": 9 }');
SELECT documentdb_api.insert_one('msdb','coll_mk','{ "_id": 10, "a": [1, 2, 3, 4, 5], "b": 10 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_mk", "indexes": [ { "key": { "a": 1, "b": 1 }, "enableCompositeTerm": true, "name": "a_1_b_1" } ] }', true);

SELECT documentdb_api.shard_collection('{ "shardCollection": "msdb.coll_mk", "key": { "_id": "hashed" }, "numInitialChunks": 2 }');

ANALYZE documentdb_data.documents_79003;

-- Correctness (no LIMIT): each of the 10 documents appears exactly once, in b
-- order, identical feature off vs on -- despite the 5x raw duplication.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk", "filter": { "a": { "$in": [1, 2, 3, 4, 5] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk", "filter": { "a": { "$in": [1, 2, 3, 4, 5] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- Correctness (LIMIT 3): the Limit counts UNIQUE emitted rows, so it returns 3
-- distinct documents (_id 1,2,3), identical off vs on.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk", "filter": { "a": { "$in": [1, 2, 3, 4, 5] } }, "projection": { "_id": 1 }, "sort": { "b": 1 }, "limit": 3 }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk", "filter": { "a": { "$in": [1, 2, 3, 4, 5] } }, "projection": { "_id": 1 }, "sort": { "b": 1 }, "limit": 3 }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- Plan shape with feature ON (LIMIT 3): each shard task produces a heap-TID
-- de-dup CustomScan over an ordered "Limit -> Merge Append" (one index scan per
-- $in value), so the shard-local de-dup drops the cross-branch repeats before
-- the coordinator merge. The flag is SET LOCAL so citus.propagate_set_commands
-- forwards it to the shard task connections.
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
         '{ "find": "coll_mk", "filter": { "a": { "$in": [1, 2, 3, 4, 5] } }, "sort": { "b": 1 }, "limit": 3 }') $$,
    p_ignore_heap_fetches => true,
    p_ignore_distributed_runtime_details => true);
ROLLBACK;

-- =====================================================================
-- Per-path multi-key coverage under sharding. Same shape as coll_mk except the
-- multi-key column is the SORT key b, while the exploded prefix a stays scalar,
-- and the index is created with per-path multi-key tracking on. A multi-key sort
-- column cannot route a document to two MergeAppend children (each per-value
-- ordered scan already emits it once), so the shard-local plan must skip the
-- heap-TID de-dup entirely.
--
-- This also pins the distribution-specific half of that claim: the shard-local
-- planner can only skip the de-dup if the per-path mask is present on the SHARD
-- index definitions, not just the coordinator's. Note how it gets there --
-- shard_collection does NOT copy the coordinator's index definition verbatim for
-- this access method; it replays the stored index spec through
-- create_indexes_non_concurrently, which re-derives the per-path marker from the
-- CURRENT value of enableIndexMetadataGlobalTracking. The GUC is therefore held
-- on across shard_collection below, and the negative case (resharding with it
-- off) is pinned separately at the end of this section.
--
-- Sort keys are the per-document minimum of b, all distinct, so the order is
-- deterministic without a tiebreaker. Expected b ascending: 0,1,2,4,5,6,10.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 1, "a": 1, "b": [2, 8] }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 2, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 3, "a": 1, "b": 6 }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 4, "a": 4, "b": [1, 9] }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 5, "a": 2, "b": 3 }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 6, "a": 1, "b": [4, 7] }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 7, "a": 4, "b": 0 }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp','{ "_id": 8, "a": 1, "b": [10, 12] }');

SET documentdb.enableIndexMetadataGlobalTracking TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_mk_pp", "indexes": [ { "key": { "a": 1, "b": 1 }, "enableCompositeTerm": true, "name": "a_1_b_1" } ] }', true);

SELECT documentdb_api.shard_collection('{ "shardCollection": "msdb.coll_mk_pp", "key": { "_id": "hashed" }, "numInitialChunks": 2 }');
RESET documentdb.enableIndexMetadataGlobalTracking;

ANALYZE documentdb_data.documents_79004;

-- The per-path multi-key mask must be present on the SHARD index definitions,
-- not just the coordinator's -- otherwise the shard-local planner cannot tell
-- that the exploded column is scalar. Scoped to the composite opclass (the PG
-- index is named documents_rum_index_*, not a_1_b_1) so it cannot be satisfied
-- by the pk or the _id single-path index. Reported per shard as
-- <marked>/<in-scope>, so an index that disappeared shows as 0/0 instead of
-- silently passing. Both shards must report 1/1.
SELECT bool_and(result = '1/1') AS all_shards_composite_marked
FROM run_command_on_shards('documentdb_data.documents_79004',
  'SELECT count(*) FILTER (WHERE strpos(pg_get_indexdef(indexrelid), ''mkp='') > 0)
          || ''/'' || count(*) FROM pg_index
     WHERE indrelid = ''%s''::regclass
       AND strpos(pg_get_indexdef(indexrelid), ''composite_path_ops'') > 0');

-- Correctness (no LIMIT): identical feature off vs on, b ascending.
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk_pp", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk_pp", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 } }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- Correctness (LIMIT 3): identical off vs on (_id 7,4,1).
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk_pp", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 }, "limit": 3 }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk_pp", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 }, "limit": 3 }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- Plan shape with feature ON (LIMIT 3): each shard task produces an ordered
-- "Limit -> Merge Append" with NO de-dup CustomScan above it, unlike the coll_mk
-- case above where the exploded column itself is multi-key.
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
         '{ "find": "coll_mk_pp", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }') $$,
    p_ignore_heap_fetches => true,
    p_ignore_distributed_runtime_details => true);
ROLLBACK;

-- =====================================================================
-- Negative counterpart to the probe above: because shard_collection re-derives
-- the per-path marker from the live GUC rather than carrying it over from the
-- coordinator's index, resharding while enableIndexMetadataGlobalTracking is OFF
-- drops per-path tracking from the shard indexes even though the pre-shard index
-- had it. The shard-local planner then falls back to the conservative
-- whole-index answer and the de-dup node reappears on every shard.
--
-- This is a performance-only, fail-safe-direction difference (results stay
-- correct either way), but it is silent, so it is pinned here rather than left
-- to be rediscovered. If the rebuild is ever changed to preserve the marker,
-- this expectation should flip to true.
-- =====================================================================
SELECT documentdb_api.insert_one('msdb','coll_mk_pp_off','{ "_id": 1, "a": 1, "b": [2, 8] }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp_off','{ "_id": 2, "a": 4, "b": 5 }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp_off','{ "_id": 3, "a": 1, "b": 6 }');
SELECT documentdb_api.insert_one('msdb','coll_mk_pp_off','{ "_id": 4, "a": 4, "b": [1, 9] }');

SET documentdb.enableIndexMetadataGlobalTracking TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('msdb',
  '{ "createIndexes": "coll_mk_pp_off", "indexes": [ { "key": { "a": 1, "b": 1 }, "enableCompositeTerm": true, "name": "a_1_b_1" } ] }', true);
RESET documentdb.enableIndexMetadataGlobalTracking;

-- Pre-shard, the coordinator index carries the marker. Reported as
-- <marked>/<in-scope> so that the index vanishing shows up as 0/0 rather than
-- silently satisfying the assertion. Expected 1/1.
SELECT count(*) FILTER (WHERE strpos(pg_get_indexdef(indexrelid), 'mkp=') > 0)
       || '/' || count(*) AS marked_over_composite_before_shard
FROM pg_index WHERE indrelid = 'documentdb_data.documents_79005'::regclass
  AND strpos(pg_get_indexdef(indexrelid), 'composite_path_ops') > 0;

SELECT documentdb_api.shard_collection('{ "shardCollection": "msdb.coll_mk_pp_off", "key": { "_id": "hashed" }, "numInitialChunks": 2 }');

ANALYZE documentdb_data.documents_79005;

-- After resharding with the GUC off, the shard indexes have lost it: the
-- composite index is still there (denominator 1) but carries no marker.
SELECT bool_and(result = '0/1') AS all_shards_composite_present_but_unmarked
FROM run_command_on_shards('documentdb_data.documents_79005',
  'SELECT count(*) FILTER (WHERE strpos(pg_get_indexdef(indexrelid), ''mkp='') > 0)
          || ''/'' || count(*) FROM pg_index
     WHERE indrelid = ''%s''::regclass
       AND strpos(pg_get_indexdef(indexrelid), ''composite_path_ops'') > 0');

-- Correctness (LIMIT 3) is unaffected: identical off vs on (_id 4,1,2).
SET documentdb.enable_merge_sort_for_in_prefix TO off;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk_pp_off", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 }, "limit": 3 }');

SET documentdb.enable_merge_sort_for_in_prefix TO on;
SELECT document FROM bson_aggregation_find('msdb',
  '{ "find": "coll_mk_pp_off", "filter": { "a": { "$in": [1, 4] } }, "projection": { "_id": 1 }, "sort": { "b": 1 }, "limit": 3 }');
RESET documentdb.enable_merge_sort_for_in_prefix;

-- The planner consequence: same query and same data as coll_mk_pp above, but
-- because resharding dropped the per-path marker the shard-local plan falls back
-- to the conservative whole-index answer and the de-dup CustomScan is back --
-- even though the only multi-key column is the sort key and it drops nothing.
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
         '{ "find": "coll_mk_pp_off", "filter": { "a": { "$in": [1, 4] } }, "sort": { "b": 1 }, "limit": 3 }') $$,
    p_ignore_heap_fetches => true,
    p_ignore_distributed_runtime_details => true);
ROLLBACK;

-- cleanup
SELECT documentdb_api.drop_collection('msdb','coll');
SELECT documentdb_api.drop_collection('msdb','coll_sk');
SELECT documentdb_api.drop_collection('msdb','coll_mk');
SELECT documentdb_api.drop_collection('msdb','coll_mk_pp');
SELECT documentdb_api.drop_collection('msdb','coll_mk_pp_off');
