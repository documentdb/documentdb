SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET citus.next_shard_id TO 58100000;
SET documentdb.next_collection_id TO 58100;
SET documentdb.next_collection_index_id TO 58100;

SET citus.multi_shard_modify_mode TO 'sequential';

SET documentdb.enableStreamingCursorDrainViaDestReceiver TO on;

\i sql/bson_aggregation_cursor_tests_core.sql
