SET citus.next_shard_id TO 60000;
SET documentdb.next_collection_id TO 6000;
SET documentdb.next_collection_index_id TO 6000;
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

\i sql/bson_aggregation_stage_lookup_tests_core.sql