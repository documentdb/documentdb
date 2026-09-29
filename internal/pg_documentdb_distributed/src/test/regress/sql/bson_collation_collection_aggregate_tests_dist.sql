-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,pg_catalog;

SET citus.next_shard_id TO 782300000;
SET documentdb.next_collection_id TO 78230000;
SET documentdb.next_collection_index_id TO 78230000;
SET documentdb_core.enableCollation TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
SET citus.propagate_set_commands TO 'local';

SELECT documentdb_api.create_collection('collation_aggregate_dist_db', 'source');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }'::documentdb_core.bson
WHERE database_name = 'collation_aggregate_dist_db' AND collection_name = 'source';

SELECT documentdb_api_internal.invalidate_collection_cache();

SELECT documentdb_api.insert_one(
    'collation_aggregate_dist_db', 'source',
    '{ "_id": 1, "category": "cafe", "rank": "10" }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_dist_db', 'source',
    '{ "_id": 2, "category": "café", "rank": "2" }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_dist_db', 'source',
    '{ "_id": 3, "category": "CAFE", "rank": "1" }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_dist_db', 'source',
    '{ "_id": 4, "category": "tea", "rank": "20" }');

SELECT documentdb_api.shard_collection(
    'collation_aggregate_dist_db', 'source', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL documentdb_core.enableCollation TO on;

-- The collection default reaches the distributed runtime and plan.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_dist_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "rank": 1 } },
        { "$project": { "_id": 1, "category": 1, "rank": 1 } }
    ] }');

SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_dist_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "rank": 1 } },
        { "$project": { "_id": 1, "category": 1, "rank": 1 } }
    ] }')
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- Expression predicates use the inherited collection default.
SELECT count(*) AS inherited_expression_matches
FROM (
    SELECT document FROM bson_aggregation_pipeline(
        'collation_aggregate_dist_db',
        '{ "aggregate": "source", "pipeline": [
            { "$match": { "$expr": { "$eq": ["$category", "CAFE"] } } }
        ] }')
) matches;

-- The inherited collection default survives worker partial-state transport
-- and coordinator combine for a non-shard grouping key.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_dist_db',
    '{ "aggregate": "source", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "minimumRank": { "$min": "$rank" },
            "maximumRank": { "$max": "$rank" },
            "count": { "$sum": 1 }
        } },
        { "$project": {
            "_id": 0,
            "firstId": 1,
            "minimumRank": 1,
            "maximumRank": 1,
            "count": 1
        } },
        { "$sort": { "firstId": 1 } }
    ] }');

SELECT
    count(*) FILTER (WHERE query_plan ~ '^\s*Task Count: 8$') > 0
        AS has_eight_tasks,
    count(*) FILTER (
        WHERE query_plan ~ 'worker(_binary)?_partial_agg') > 0
        AS has_worker_partial,
    count(*) FILTER (
        WHERE query_plan ~ 'coord(_binary)?_combine_agg') > 0
        AS has_coord_combine,
    count(*) FILTER (
        WHERE query_plan LIKE '%en-u-ks-level1-kn-true%') > 0
        AS has_default_collation
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_dist_db',
    '{ "aggregate": "source", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "minimumRank": { "$min": "$rank" },
            "maximumRank": { "$max": "$rank" },
            "count": { "$sum": 1 }
        } },
        { "$project": {
            "_id": 0,
            "firstId": 1,
            "minimumRank": 1,
            "maximumRank": 1,
            "count": 1
        } },
        { "$sort": { "firstId": 1 } }
    ] }')
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- An explicit simple collation overrides the collection default.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_dist_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "rank": 1 } },
        { "$project": { "_id": 1, "category": 1, "rank": 1 } }
    ], "collation": { "locale": "simple" } }');

ROLLBACK;

-- Disabling collation prevents collection-default inheritance.
BEGIN;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL documentdb_core.enableCollation TO off;
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_dist_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "rank": 1 } },
        { "$project": { "_id": 1, "category": 1, "rank": 1 } }
    ] }');
ROLLBACK;

SELECT documentdb_api.drop_collection('collation_aggregate_dist_db', 'source');

RESET citus.propagate_set_commands;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb_core.enableCollation;
