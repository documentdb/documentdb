-- Test: enableGroupByCompoundIdIndexPushdown=on, enableGroupSubqueryElimination=on
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 864000;
SET documentdb.next_collection_id TO 8640;
SET documentdb.next_collection_index_id TO 8640;

SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET documentdb.enableGroupSubqueryElimination TO on;

\i sql/bson_group_compound_id_correctness_core.sql
