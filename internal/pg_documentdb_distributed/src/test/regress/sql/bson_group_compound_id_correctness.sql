-- Test: enableGroupByCompoundIdIndexPushdown=off, enableGroupSubqueryElimination=off
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 861000;
SET documentdb.next_collection_id TO 8610;
SET documentdb.next_collection_index_id TO 8610;

SET documentdb.enableGroupByCompoundIdIndexPushdown TO off;
SET documentdb.enableGroupSubqueryElimination TO off;

\i sql/bson_group_compound_id_correctness_core.sql
