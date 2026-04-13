SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 10000;
SET documentdb.next_collection_index_id TO 10000;

SET documentdb.enableStreamingCursorDrainViaDestReceiver TO on;

\i sql/bson_aggregation_cursor_tests_core.sql
