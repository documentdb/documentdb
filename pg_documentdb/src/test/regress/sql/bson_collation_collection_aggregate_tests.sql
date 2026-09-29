-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core,pg_catalog;

SET documentdb.next_collection_id TO 782300;
SET documentdb.next_collection_index_id TO 782300;
SET documentdb_core.enableCollation TO on;

SELECT documentdb_api.create_collection('collation_aggregate_db', 'source');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }'::documentdb_core.bson
WHERE database_name = 'collation_aggregate_db' AND collection_name = 'source';

SELECT documentdb_api_internal.invalidate_collection_cache();

SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'source',
    '{ "_id": 1, "category": "cafe", "rank": "10", "tags": ["CAFE"], "vals": ["apple", "Banana"] }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'source',
    '{ "_id": 2, "category": "café", "rank": "2", "tags": ["CAFÉ"] }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'source',
    '{ "_id": 3, "category": "CAFE", "rank": "1", "tags": ["other"] }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'source',
    '{ "_id": 4, "category": "tea", "rank": "20", "tags": ["tea"] }');

-- Missing, null, and empty command collations inherit the collection default.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "category": 1 } }
    ] }');
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "category": 1 } }
    ], "collation": null }');
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "category": 1 } }
    ], "collation": {} }');

-- Explicit non-simple and simple collations override the collection default.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "category": 1 } }
    ], "collation": { "locale": "en", "strength": 3 } }');
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "category": 1 } }
    ], "collation": { "locale": "simple" } }');

-- $expr predicates inside $match use the inherited collation.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "$expr": { "$eq": ["$category", "CAFE"] } } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "category": 1 } }
    ] }');

-- The inherited numeric ordering is used by $sort.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$sort": { "rank": 1 } },
        { "$project": { "_id": 1, "rank": 1 } }
    ] }');

-- Group key equality uses the inherited collation.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$group": {
            "_id": "$category",
            "firstId": { "$min": "$_id" },
            "count": { "$sum": 1 }
        } },
        { "$project": {
            "_id": 0,
            "firstId": 1,
            "count": 1
        } },
        { "$sort": { "firstId": 1 } }
    ] }');

-- String group accumulators use the inherited numeric ordering.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$group": {
            "_id": null,
            "minimum": { "$min": "$rank" },
            "maximum": { "$max": "$rank" }
        } }
    ] }');

-- Expression comparisons, array search, set equality, ordering, and min/max
-- share the inherited effective collation.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$project": {
            "_id": 0,
            "eq": { "$eq": ["$category", "CAFE"] },
            "cmp": { "$cmp": ["$category", "CAFE"] },
            "index": { "$indexOfArray": ["$tags", "cafe"] },
            "setEquals": { "$setEquals": ["$tags", ["cafe"]] },
            "sorted": { "$sortArray": { "input": ["10", "2", "1"], "sortBy": 1 } },
            "minimum": { "$min": "$vals" },
            "maximum": { "$max": "$vals" }
        } }
    ] }');

-- Projection-family stages use the inherited collation in expressions.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$addFields": {
            "addFieldsEqual": { "$eq": ["$category", "CAFE"] }
        } },
        { "$set": {
            "setEqual": { "$eq": ["$category", "CAFÉ"] }
        } },
        { "$project": {
            "_id": 1,
            "addFieldsEqual": 1,
            "setEqual": 1
        } }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$replaceRoot": {
            "newRoot": {
                "sourceId": "$_id",
                "equal": { "$eq": ["$category", "CAFE"] }
            }
        } }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$replaceWith": {
            "sourceId": "$_id",
            "equal": { "$eq": ["$category", "CAFÉ"] }
        } }
    ] }');

-- $redact decisions use the inherited collation.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$redact": {
            "$cond": {
                "if": { "$eq": ["$category", "CAFE"] },
                "then": "$$KEEP",
                "else": "$$PRUNE"
            }
        } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "category": 1 } }
    ] }');

-- Collation remains effective across $unwind and into the following $match.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$unwind": "$tags" },
        { "$match": { "tags": "cafe" } },
        { "$sort": { "_id": 1 } },
        { "$project": { "_id": 1, "tags": 1 } }
    ] }');

-- A terminal $count observes the inherited match result.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$count": "matchingCategories" }
    ] }');

-- Accumulators that cannot honor a collation retain their existing rejection.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$group": { "_id": null, "categories": { "$addToSet": "$category" } } }
    ] }');

-- A collection with no default collation keeps binary behavior.
SELECT documentdb_api.create_collection('collation_aggregate_db', 'no_default');
SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'no_default', '{ "_id": 1, "value": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'no_default', '{ "_id": 2, "value": "CAFE" }');
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "no_default", "pipeline": [
        { "$match": { "value": "cafe" } },
        { "$project": { "_id": 1, "value": 1 } }
    ] }');

-- A simple collection default also keeps binary behavior.
SELECT documentdb_api.create_collection('collation_aggregate_db', 'simple_default');
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "simple" } }'::documentdb_core.bson
WHERE database_name = 'collation_aggregate_db'
  AND collection_name = 'simple_default';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'simple_default', '{ "_id": 1, "value": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_aggregate_db', 'simple_default', '{ "_id": 2, "value": "CAFE" }');
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "simple_default", "pipeline": [
        { "$match": { "value": "cafe" } },
        { "$project": { "_id": 1, "value": 1 } }
    ] }');
-- A missing collection has no metadata to inherit.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "missing", "pipeline": [
        { "$match": { "value": "cafe" } }
    ] }');

-- Collectionless aggregate commands do not inherit collection metadata.
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": 1, "pipeline": [
        { "$documents": [
            { "_id": 1, "value": "cafe" },
            { "_id": 2, "value": "CAFE" }
        ] },
        { "$match": { "value": "cafe" } }
    ] }');

-- Disabling collation disables collection-default inheritance.
SET documentdb_core.enableCollation TO off;
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$project": { "_id": 1, "category": 1 } }
    ] }');
SET documentdb_core.enableCollation TO on;

SELECT documentdb_api.drop_database('collation_aggregate_db');

RESET documentdb_core.enableCollation;
