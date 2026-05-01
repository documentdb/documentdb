SET citus.next_shard_id TO 95000000;
SET documentdb.next_collection_id TO 95000;
SET documentdb.next_collection_index_id TO 95000;

\i sql/bson_collation_query_tests_dist_core.sql
