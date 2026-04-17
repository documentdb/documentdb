-- Test: enableGroupByCompoundIdIndexPushdown=off, enableGroupSubqueryElimination=on
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 863000;
SET documentdb.next_collection_id TO 8630;
SET documentdb.next_collection_index_id TO 8630;

SET documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET documentdb.enableGroupSubqueryElimination TO on;

\i sql/bson_group_compound_id_correctness_core.sql
