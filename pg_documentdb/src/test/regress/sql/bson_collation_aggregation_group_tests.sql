-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core,pg_catalog;

SET documentdb.next_collection_id TO 25700000;
SET documentdb.next_collection_index_id TO 25700000;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.enableCollationWithNewGroupAccumulators TO on;

SELECT documentdb_api.insert_one('db', 'group_collation_test',
    '{ "_id": 1, "category": "Cat", "region": "North", "value": 10 }');
SELECT documentdb_api.insert_one('db', 'group_collation_test',
    '{ "_id": 2, "category": "cat", "region": "north", "value": 20 }');
SELECT documentdb_api.insert_one('db', 'group_collation_test',
    '{ "_id": 3, "category": "CAT", "region": "NORTH", "value": 30 }');
SELECT documentdb_api.insert_one('db', 'group_collation_test',
    '{ "_id": 4, "category": "Dog", "region": "South", "value": 40 }');
SELECT documentdb_api.insert_one('db', 'group_collation_test',
    '{ "_id": 5, "category": "dog", "region": "south", "value": 50 }');
SELECT documentdb_api.insert_one('db', 'group_collation_test',
    '{ "_id": 6, "category": "DOG", "region": "SOUTH", "value": 60 }');

-- Strength 1 merges case variants into two groups.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": "$category", "firstId": { "$min": "$_id" }, "count": { "$sum": 1 } } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Each string value in the compound key uses the command collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "total": { "$sum": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Decomposed multi-field grouping uses the command collation for every key field.
SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "values": { "$push": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "values": { "$push": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');
RESET documentdb.enableGroupByCompoundIdIndexPushdown;

-- The command collation also applies to a computed string key.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "$concat": ["$category", "-", "$region"] },
            "firstId": { "$min": "$_id" },
            "average": { "$avg": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Grouping after $skip preserves the command collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$skip": 1 },
        { "$group": { "_id": "$category", "firstId": { "$min": "$_id" }, "total": { "$sum": "$value" } } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Grouping after multiple projection stages preserves the command collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
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

-- $addToSet: the group key is collation-aware but the accumulator's set
-- membership is still byte-wise, so the case variants are NOT deduped. This
-- pins the current behavior; see the strength 3 control below, which produces
-- the identical set.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "categories": { "$addToSet": "$category" }
        } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- The two rows below show where the collation is and is not applied: the _id
-- groups merge the case variants of "category", while the accumulated
-- "region" set keeps every spelling.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "regions": { "$addToSet": "$region" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Case-sensitive control: strength 3 yields the same $addToSet result as
-- strength 1 above, confirming the accumulator ignores the collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "categories": { "$addToSet": "$category" }
        } }
    ], "collation": { "locale": "en", "strength": 3 } }');

-- Case-sensitive control: strength 3 keeps all case variants separate.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "values": { "$push": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 3 } }');

SELECT documentdb_api.drop_collection('db', 'group_collation_test');

RESET documentdb.enableCollationWithNewGroupAccumulators;
RESET documentdb.enableNewWithExprAccumulators;
RESET documentdb_core.enableCollation;
