SET citus.next_shard_id TO 8400000;
SET documentdb.next_collection_id TO 8400;
SET documentdb.next_collection_index_id TO 8400;

\i sql/bson_collation_query_tests_core.sql
