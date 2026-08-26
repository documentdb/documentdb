SET citus.next_shard_id TO 9300000;
SET documentdb.next_collection_id TO 9300;
SET documentdb.next_collection_index_id TO 9300;

\i sql/bson_collation_operators_tests_core.sql
