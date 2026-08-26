-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core,pg_catalog;

SET documentdb.next_collection_id TO 25700000;
SET documentdb.next_collection_index_id TO 25700000;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableNewWithExprAccumulators TO on;

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
            "maxValue": { "$max": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "category": "$category", "region": "$region" },
            "firstId": { "$min": "$_id" },
            "maxValue": { "$max": "$value" }
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

-- $addToSet compares values byte by byte, so it cannot honor the collation
-- and now errors instead of returning a set that ignores it.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "categories": { "$addToSet": "$category" }
        } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- A collation aware _id does not make the accumulator collation aware.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "regions": { "$addToSet": "$region" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- The remaining accumulators that cannot honor the collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$push": "$category" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$maxN": { "input": "$category", "n": 2 } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$minN": { "input": "$category", "n": 2 } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$firstN": { "input": "$category", "n": 2 } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$lastN": { "input": "$category", "n": 2 } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$top": { "output": "$category", "sortBy": { "category": 1 } } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$bottom": { "output": "$category", "sortBy": { "category": 1 } } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$topN": { "output": "$category", "sortBy": { "category": 1 }, "n": 2 } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$bottomN": { "output": "$category", "sortBy": { "category": 1 }, "n": 2 } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$mergeObjects": "$$ROOT" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- These only do arithmetic, so the collation applies to the input expression.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevPop": "$value" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevSamp": "$value" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$median": { "input": "$value", "method": "approximate" } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$percentile": { "input": "$value", "p": [0.5], "method": "approximate" } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- With the collation all six rows contribute 100; without it only two do.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevPop": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevPop": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevSamp": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$stdDevSamp": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] } } } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$median": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "method": "approximate" } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$median": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "method": "approximate" } } } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$percentile": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "p": [ 0.5, 0.9 ], "method": "approximate" } } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$percentile": { "input": { "$cond": [ { "$or": [ { "$eq": [ "$category", "cat" ] }, { "$eq": [ "$category", "dog" ] } ] }, 100, 0 ] }, "p": [ 0.5, 0.9 ], "method": "approximate" } } } }
    ] }');

-- $count and $sum: 1 only count rows, so the collation cannot change the
-- result. They stay allowed.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "n": { "$count": {} }, "total": { "$sum": 1 } } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Legacy accumulator paths cannot evaluate collation-sensitive expressions.
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$avg": "$value" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$sum": "$value" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$first": "$value" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$last": "$value" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
RESET documentdb.enableNewWithExprAccumulators;

-- After a $sort, $first and $last use the sorted accumulator, which sorts the
-- values itself byte by byte and cannot honor the collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": { "_id": "$category", "acc": { "$first": "$category" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": { "_id": "$category", "acc": { "$last": "$category" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Without that $sort they keep working.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": "$category", "f": { "$first": "$value" }, "l": { "$last": "$value" } } },
        { "$sort": { "_id": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');


-- With no collation requested, nothing changes.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "categories": { "$addToSet": "$category" },
            "values": { "$push": "$value" }
        } }
    ] }');

-- Case-sensitive control: strength 3 keeps all case variants separate.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "maxValue": { "$max": "$value" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 3 } }');

-- skipFailOnCollation lets a caller keep the old behavior: no error, and the
-- accumulator answers with a byte by byte comparison.
SET documentdb.skipFailOnCollation TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$addToSet": "$category" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
RESET documentdb.skipFailOnCollation;

SELECT documentdb_api.drop_collection('db', 'group_collation_test');

RESET documentdb.enableNewWithExprAccumulators;
RESET documentdb_core.enableCollation;
