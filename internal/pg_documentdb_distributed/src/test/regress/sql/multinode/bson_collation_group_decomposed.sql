-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

SET citus.next_shard_id TO 121000;
SET documentdb.next_collection_id TO 12100;
SET documentdb.next_collection_index_id TO 12100;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
SET citus.enable_local_execution TO off;
SET citus.propagate_set_commands TO 'local';

SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed',
    '{ "_id": 1, "category": "Cat", "region": "North", "value": 10 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed',
    '{ "_id": 2, "category": "cat", "region": "north", "value": 20 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed',
    '{ "_id": 3, "category": "CAT", "region": "NORTH", "value": 30 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed',
    '{ "_id": 4, "category": "Dog", "region": "South", "value": 40 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed',
    '{ "_id": 5, "category": "dog", "region": "south", "value": 50 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed',
    '{ "_id": 6, "category": "DOG", "region": "SOUTH", "value": 60 }');

CALL documentdb_distributed_test_helpers.place_collection_on_node(
    'group_collation_mn', 'decomposed', 1);

BEGIN;
SET local documentdb_core.enableCollation TO on;
SET local documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET local enable_seqscan TO off;
SET local enable_bitmapscan TO off;
SET local enable_indexscan TO on;

-- Remote decomposed grouping applies collation to every field in the compound key.
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('group_collation_mn',
    '{ "aggregate": "decomposed", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('group_collation_mn',
    '{ "aggregate": "decomposed", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

ROLLBACK;

SELECT documentdb_api.create_collection('group_collation_mn', 'decomposed_default');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'group_collation_mn' AND collection_name = 'decomposed_default';

SELECT documentdb_api_internal.invalidate_collection_cache();

SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed_default',
    '{ "_id": 1, "category": "Cat", "region": "North", "value": 10 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed_default',
    '{ "_id": 2, "category": "cat", "region": "north", "value": 20 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed_default',
    '{ "_id": 3, "category": "CAT", "region": "NORTH", "value": 30 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed_default',
    '{ "_id": 4, "category": "Dog", "region": "South", "value": 40 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed_default',
    '{ "_id": 5, "category": "dog", "region": "south", "value": 50 }');
SELECT documentdb_api.insert_one('group_collation_mn', 'decomposed_default',
    '{ "_id": 6, "category": "DOG", "region": "SOUTH", "value": 60 }');

CALL documentdb_distributed_test_helpers.place_collection_on_node(
    'group_collation_mn', 'decomposed_default', 1);

BEGIN;
SET local documentdb_core.enableCollation TO on;
SET local documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET local enable_seqscan TO off;
SET local enable_bitmapscan TO off;
SET local enable_indexscan TO on;

-- Collection-default collation reaches the remote decomposed group runtime and plan.
SELECT document FROM bson_aggregation_pipeline('group_collation_mn',
    '{ "aggregate": "decomposed_default", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$project": {
            "_id": 0,
            "firstId": 1,
            "total": 1
        } },
        { "$sort": { "firstId": 1 } }
    ] }');

SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('group_collation_mn',
    '{ "aggregate": "decomposed_default", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$project": {
            "_id": 0,
            "firstId": 1,
            "total": 1
        } },
        { "$sort": { "firstId": 1 } }
    ] }')
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- Explicit simple collation overrides the collection default.
SELECT document FROM bson_aggregation_pipeline('group_collation_mn',
    '{ "aggregate": "decomposed_default", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "simple" } }');

ROLLBACK;

SELECT documentdb_api.drop_collection('group_collation_mn', 'decomposed');
SELECT documentdb_api.drop_collection('group_collation_mn', 'decomposed_default');

RESET citus.enable_local_execution;
RESET citus.propagate_set_commands;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb.enableGroupByCompoundIdIndexPushdown;
RESET documentdb_core.enableCollation;
