SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET citus.next_shard_id TO 680000;
SET documentdb.next_collection_id TO 68000;
SET documentdb.next_collection_index_id TO 68000;

\i sql/bson_composite_order_by_index_tests_core.sql