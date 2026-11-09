-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core,pg_catalog;

SET documentdb.next_collection_id TO 25700000;
SET documentdb.next_collection_index_id TO 25700000;
SET documentdb_core.enableCollation TO on;

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

-- A constant comparison must use collation before deciding whether _id needs the document.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "$cond": [ { "$eq": ["ALPHA", "alpha"] }, "$category", null ] },
            "firstId": { "$min": "$_id" },
            "count": { "$sum": 1 }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "$cond": [ { "$eq": ["ALPHA", "alpha"] }, "$category", null ] },
            "firstId": { "$min": "$_id" },
            "count": { "$sum": 1 }
        } },
        { "$sort": { "firstId": 1 } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": { "$cond": [ { "$eq": ["ALPHA", "alpha"] }, "$category", null ] },
            "firstId": { "$min": "$_id" },
            "count": { "$sum": 1 }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "simple" } }');

-- A collated constant condition must preserve the document for accumulator input.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "average": { "$avg": { "$cond": [ { "$eq": ["ALPHA", "alpha"] }, "$value", 0 ] } }
        } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "average": { "$avg": { "$cond": [ { "$eq": ["ALPHA", "alpha"] }, "$value", 0 ] } }
        } }
    ], "collation": { "locale": "simple" } }');

-- The same classification applies to accumulators that evaluate their input expression.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "deviation": { "$stdDevPop": { "$cond": [ { "$eq": ["ALPHA", "alpha"] }, { "$mod": ["$value", 20] }, 0 ] } }
        } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": {
            "_id": null,
            "deviation": { "$stdDevPop": { "$cond": [ { "$eq": ["ALPHA", "alpha"] }, { "$mod": ["$value", 20] }, 0 ] } }
        } }
    ], "collation": { "locale": "simple" } }');

-- A fully constant _id comparison follows the same collation.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": { "$eq": ["ALPHA", "alpha"] }, "count": { "$sum": 1 } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": { "$eq": ["ALPHA", "alpha"] }, "count": { "$sum": 1 } } }
    ], "collation": { "locale": "simple" } }');

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

-- $addToSet deduplicates with collation but returns the original values.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": {
            "_id": null,
            "categories": { "$addToSet": "$category" }
        } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Each group has its own collation-aware set.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "regions": { "$addToSet": "$region" }
        } },
        { "$sort": { "firstId": 1 } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Collation applies to computed inputs and command variables too.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": {
            "_id": null,
            "categories": { "$addToSet": {
                "$cond": [ { "$eq": ["$$expected", "alpha"] }, "$category", "$region" ]
            } }
        } }
    ], "let": { "expected": "ALPHA" }, "collation": { "locale": "en", "strength": 1 } }');

-- Recurse into values, not field names; retain types, field order and array order.
-- Missing values and $$REMOVE retain the same behavior with and without collation.
SELECT documentdb_api.insert_one('db', 'add_to_set_collation_test', doc::bson)
FROM (VALUES
    ('{ "_id": 1, "value": "Caf\u00e9" }'),
    ('{ "_id": 2, "value": "CAFE" }'),
    ('{ "_id": 3, "value": "cafe" }'),
    ('{ "_id": 4, "value": { "x": "A", "y": ["B"] } }'),
    ('{ "_id": 5, "value": { "x": "a", "y": ["b"] } }'),
    ('{ "_id": 6, "value": { "X": "a", "y": ["b"] } }'),
    ('{ "_id": 7, "value": { "y": ["b"], "x": "a" } }'),
    ('{ "_id": 8, "value": ["A", "B"] }'),
    ('{ "_id": 9, "value": ["a", "b"] }'),
    ('{ "_id": 10, "value": ["b", "a"] }'),
    ('{ "_id": 11, "value": 1 }'),
    ('{ "_id": 12, "value": { "$numberLong": "1" } }'),
    ('{ "_id": 13, "value": "1" }'),
    ('{ "_id": 14, "value": "" }'),
    ('{ "_id": 15, "value": null }'),
    ('{ "_id": 16 }')
) AS inputs(doc);
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "add_to_set_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": { "_id": null, "values": { "$addToSet": "$value" }, "removed": { "$addToSet": "$$REMOVE" } } }
    ] }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "add_to_set_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": { "_id": null, "values": { "$addToSet": "$value" }, "removed": { "$addToSet": "$$REMOVE" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "add_to_set_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": { "_id": null, "values": { "$addToSet": "$value" }, "removed": { "$addToSet": "$$REMOVE" } } }
    ], "collation": { "locale": "en", "strength": 2 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "add_to_set_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": { "_id": null, "values": { "$addToSet": "$value" }, "removed": { "$addToSet": "$$REMOVE" } } }
    ], "collation": { "locale": "en", "strength": 3 } }');
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "add_to_set_collation_test", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": { "_id": null, "values": { "$addToSet": "$value" }, "removed": { "$addToSet": "$$REMOVE" } } }
    ], "collation": { "locale": "simple" } }');
SELECT documentdb_api.drop_collection('db', 'add_to_set_collation_test');

SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": 1, "pipeline": [
        { "$documents": [{ "value": "First" }, { "value": "FIRST" }, { "value": "Last" }] },
        { "$group": { "_id": null, "values": { "$addToSet": "$value" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');

-- Parsed metadata remains authoritative after expression evaluation.
BEGIN;
CREATE TEMP TABLE add_to_set_metadata AS
SELECT id, doc::bson AS document,
    documentdb_api_internal.bson_expression_get(
        doc::bson, '{ "": "$value" }'::bson, false, '{}'::bson, 'en-u-ks-level1') AS value
FROM (VALUES
    (1, '{ "value": "Alpha" }'),
    (2, '{ "value": "ALPHA" }'),
    (3, '{ "value": { "key": "Cafe" } }'),
    (4, '{ "value": { "key": "CAF\u00c9" } }'),
    (5, '{ "value": ["North", { "key": "First" }] }'),
    (6, '{ "value": ["NORTH", { "key": "FIRST" }] }')
) AS inputs(id, doc);
SELECT documentdb_api_internal.bson_add_to_set(value ORDER BY id)
FROM add_to_set_metadata;
SET LOCAL documentdb_core.enableCollation TO off;
SELECT documentdb_api_internal.bson_add_to_set(value ORDER BY id)
FROM add_to_set_metadata;
-- Disabling collation before evaluation still produces binary inputs.
SELECT documentdb_api_internal.bson_add_to_set(
    documentdb_api_internal.bson_expression_get(
        document, '{ "": "$value" }'::bson, false, '{}'::bson, 'en-u-ks-level1') ORDER BY id)
FROM add_to_set_metadata;
ROLLBACK;

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

-- skipFailOnCollation does not disable collation for supported accumulators.
SET documentdb.skipFailOnCollation TO on;
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "group_collation_test", "pipeline": [
        { "$group": { "_id": null, "acc": { "$addToSet": "$category" } } }
    ], "collation": { "locale": "en", "strength": 1 } }');
RESET documentdb.skipFailOnCollation;

SELECT documentdb_api.drop_collection('db', 'group_collation_test');

RESET documentdb_core.enableCollation;
