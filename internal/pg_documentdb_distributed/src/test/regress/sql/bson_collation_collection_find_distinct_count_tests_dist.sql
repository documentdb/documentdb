-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,pg_catalog;

SET citus.next_shard_id TO 271300000;
SET documentdb.next_collection_id TO 27130000;
SET documentdb.next_collection_index_id TO 27130000;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
SET citus.enable_local_execution TO off;

SELECT documentdb_api.create_collection('collation_default_dist_db', 'default_match');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "fr", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_default_dist_db' AND collection_name = 'default_match';

SELECT documentdb_api.insert_one(
    'collation_default_dist_db', 'default_match', '{ "_id": 1, "value": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_default_dist_db', 'default_match', '{ "_id": 2, "value": "CAFÉ" }');
SELECT documentdb_api.insert_one(
    'collation_default_dist_db', 'default_match', '{ "_id": 3, "value": "CAFE" }');

SELECT documentdb_api.shard_collection(
    'collation_default_dist_db', 'default_match', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;

-- Find, distinct, and count inherit the default across shards.
SELECT document FROM bson_aggregation_find(
    'collation_default_dist_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 } }');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_find(
    'collation_default_dist_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 } }')
$cmd$);
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_default_dist_db',
    '{ "distinct": "default_match", "key": "value" }');
SELECT document FROM documentdb_api.count_query(
    'collation_default_dist_db',
    '{ "count": "default_match", "query": { "value": "cafe" } }');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_default_dist_db',
    '{ "count": "default_match", "query": { "value": "cafe" } }')
$cmd$);

-- An explicit simple collation remains binary across shards.
SELECT document FROM documentdb_api.count_query(
    'collation_default_dist_db',
    '{ "count": "default_match", "query": { "value": "cafe" }, "collation": { "locale": "simple" } }');

END;

RESET citus.enable_local_execution;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb.enableExtendedExplainPlans;
RESET documentdb_core.enableCollation;
RESET search_path;
