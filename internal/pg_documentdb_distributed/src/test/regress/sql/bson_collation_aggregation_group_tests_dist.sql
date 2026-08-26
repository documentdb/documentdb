-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,pg_catalog;

SET citus.next_shard_id TO 257000000;
SET documentdb.next_collection_id TO 25700000;
SET documentdb.next_collection_index_id TO 25700000;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.useLocalExecutionShardQueries TO off;
SET citus.enable_local_execution TO off;

SELECT documentdb_api.insert_one('db', 'group_collation_dist_test',
    '{ "_id": 1, "category": "Cat", "region": "North", "value": 10 }');
SELECT documentdb_api.insert_one('db', 'group_collation_dist_test',
    '{ "_id": 2, "category": "cat", "region": "north", "value": 20 }');
SELECT documentdb_api.insert_one('db', 'group_collation_dist_test',
    '{ "_id": 3, "category": "CAT", "region": "NORTH", "value": 30 }');
SELECT documentdb_api.insert_one('db', 'group_collation_dist_test',
    '{ "_id": 4, "category": "Dog", "region": "South", "value": 40 }');
SELECT documentdb_api.insert_one('db', 'group_collation_dist_test',
    '{ "_id": 5, "category": "dog", "region": "south", "value": 50 }');
SELECT documentdb_api.insert_one('db', 'group_collation_dist_test',
    '{ "_id": 6, "category": "DOG", "region": "SOUTH", "value": 60 }');

BEGIN;
SET local documentdb_core.enableCollation TO on;

-- Strength 1 merges case variants into two groups.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": "$category", "firstId": { "$min": "$_id" }, "count": { "$sum": 1 } } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Each string value in the compound key uses the command collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Decomposed multi-field grouping uses the command collation for every key field.
SET local documentdb.enableGroupByCompoundIdIndexPushdown TO on;
-- This matches the decomposed $sum pipeline used by the true multinode test.
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Other accumulators preserve the same decomposed key semantics.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "values": { "$max": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- The command collation also applies to a computed string key.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": {
            "_id": { "$concat": ["$category", "-", "$region"] },
            "firstId": { "$min": "$_id" },
            "average": { "$avg": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Grouping after $skip preserves the command collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$skip": 1 },
        { "$group": { "_id": "$category", "firstId": { "$min": "$_id" }, "total": { "$sum": "$value" } } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Grouping after multiple projection stages preserves the command collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$project": {
            "_id": 1,
            "projectedCategory": "$category",
            "projectedRegion": "$region",
            "projectedValue": "$value"
        } },
        { "$addFields": {
            "projectedKey": { "$concat": ["$projectedCategory", "-", "$projectedRegion"] }
        } },
        { "$project": { "_id": 1, "projectedKey": 1, "projectedValue": 1 } },
        { "$group": {
            "_id": "$projectedKey",
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$projectedValue" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- A collection-less pipeline rooted at $documents uses the command collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": 1, "pipeline": [
        { "$documents": [
            { "_id": 1, "category": "Cat", "value": 10 },
            { "_id": 2, "category": "cat", "value": 20 },
            { "_id": 3, "category": "Dog", "value": 40 },
            { "_id": 4, "category": "DOG", "value": 60 }
        ] },
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Case-sensitive control: strength 3 keeps all case variants separate.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "values": { "$max": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 3 } }');
ROLLBACK;

-- $push cannot honor a collation, so it is rejected.
BEGIN;
SET local documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "values": { "$push": "$value" }
        } }
    ], "collation": { "locale": "en", "strength": 1 } }');
ROLLBACK;

-- These only do arithmetic, so the collation applies to the input expression.
-- With it all six rows contribute 100; without it only two do.
BEGIN;
SET local documentdb_core.enableCollation TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevPop": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevPop": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevSamp": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevSamp": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$median": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "method": "approximate" } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$median": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "method": "approximate" } } } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$percentile": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "p": [ 0.5, 0.9 ], "method": "approximate" } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_dist_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$percentile": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "p": [ 0.5, 0.9 ], "method": "approximate" } } } }
    ] }');
ROLLBACK;

SELECT documentdb_api.drop_collection('db', 'group_collation_dist_test');

RESET citus.enable_local_execution;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb.enableNewWithExprAccumulators;
RESET documentdb_core.enableCollation;
