SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET citus.next_shard_id TO 910000;
SET documentdb.next_collection_id TO 9100;
SET documentdb.next_collection_index_id TO 9100;

-- This test verifies that on a hash-sharded collection, a $group whose grouping
-- key is not the shard key pushes the aggregate transition down to the shard
-- workers (worker_partial_agg) and combines the partial states on the
-- coordinator (coord_combine_agg) for the with-expression $min / $max / $first
-- accumulators. It uses plain EXPLAIN (no ANALYZE) so it is deterministic
-- across all supported PostgreSQL versions; the volatile distributed subplan
-- ids are normalized by the helper.

SELECT documentdb_api.insert_one('db','group_txn_combine_dist','{ "_id": 1, "category": "A", "val": 10 }', NULL);
SELECT documentdb_api.insert_one('db','group_txn_combine_dist','{ "_id": 2, "category": "B", "val": 20 }', NULL);
SELECT documentdb_api.insert_one('db','group_txn_combine_dist','{ "_id": 3, "category": "A", "val": 30 }', NULL);
SELECT documentdb_api.insert_one('db','group_txn_combine_dist','{ "_id": 4, "category": "B", "val": 40 }', NULL);
SELECT documentdb_api.insert_one('db','group_txn_combine_dist','{ "_id": 5, "category": "A", "val": 50 }', NULL);
SELECT documentdb_api.insert_one('db','group_txn_combine_dist','{ "_id": 6, "category": "C", "val": 60 }', NULL);

SELECT documentdb_api.shard_collection('db', 'group_txn_combine_dist', '{ "_id": "hashed" }', false);

-- ===== $max transition + combine pushdown =====
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
  EXPLAIN (COSTS OFF, VERBOSE ON)
  SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "group_txn_combine_dist", "pipeline": [ { "$group": { "_id": "$category", "maxVal": { "$max": "$val" } } } ], "cursor": {} }')
$cmd$, p_ignore_distributed_subplan_ids => true);

-- ===== $min transition + combine pushdown =====
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
  EXPLAIN (COSTS OFF, VERBOSE ON)
  SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "group_txn_combine_dist", "pipeline": [ { "$group": { "_id": "$category", "minVal": { "$min": "$val" } } } ], "cursor": {} }')
$cmd$, p_ignore_distributed_subplan_ids => true);

-- ===== $first transition + combine pushdown =====
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
  EXPLAIN (COSTS OFF, VERBOSE ON)
  SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "group_txn_combine_dist", "pipeline": [ { "$group": { "_id": "$category", "firstVal": { "$first": "$val" } } } ], "cursor": {} }')
$cmd$, p_ignore_distributed_subplan_ids => true);

-- Cleanup
SELECT documentdb_api.drop_collection('db', 'group_txn_combine_dist');
