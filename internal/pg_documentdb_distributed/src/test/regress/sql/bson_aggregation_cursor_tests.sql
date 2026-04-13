SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET citus.next_shard_id TO 3120000;
SET documentdb.next_collection_id TO 3120;
SET documentdb.next_collection_index_id TO 3120;

SET citus.multi_shard_modify_mode TO 'sequential';

SET documentdb.enableStreamingCursorDrainViaDestReceiver TO off;

\i sql/bson_aggregation_cursor_tests_core.sql