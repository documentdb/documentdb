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

-- Nested pipeline collection-default collation inheritance.

SELECT documentdb_api.create_collection('collation_nested_db', 'source');
SELECT documentdb_api.create_collection('collation_nested_db', 'lookup_target');
SELECT documentdb_api.create_collection('collation_nested_db', 'union_target');
SELECT documentdb_api.create_collection('collation_nested_db', 'graph_target');
SELECT documentdb_api.create_collection('collation_nested_db', 'binary_source');
SELECT documentdb_api.create_collection('collation_nested_db', 'defaulted_target');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": {
    "locale": "en",
    "strength": 1,
    "numericOrdering": true
} }'::documentdb_core.bson
WHERE database_name = 'collation_nested_db'
  AND collection_name = 'source';

-- Foreign collection defaults must not replace the command-wide collation.
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "simple" } }'::documentdb_core.bson
WHERE database_name = 'collation_nested_db'
  AND collection_name IN ('lookup_target', 'union_target', 'graph_target');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": {
    "locale": "en",
    "strength": 1,
    "numericOrdering": true
} }'::documentdb_core.bson
WHERE database_name = 'collation_nested_db'
  AND collection_name = 'defaulted_target';

SELECT documentdb_api_internal.invalidate_collection_cache();

SELECT documentdb_api.insert_one(
    'collation_nested_db', 'source',
    '{ "_id": 1, "key": "cafe", "rank": "10", "graphStart": "root" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'source',
    '{ "_id": 2, "key": "tea", "rank": "2", "graphStart": "missing" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'source',
    '{ "_id": 3, "key": "CAFE", "rank": "1", "graphStart": "missing" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'source',
    '{ "_id": 4, "key": "café", "rank": "20", "graphStart": "missing" }');

SELECT documentdb_api.insert_one(
    'collation_nested_db', 'lookup_target',
    '{ "_id": 101, "key": "CAFE", "state": "ACTIVE" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'lookup_target',
    '{ "_id": 102, "key": "café", "state": "active" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'lookup_target',
    '{ "_id": 103, "key": "cafe", "state": "inactive" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'lookup_target',
    '{ "_id": 104, "key": "tea", "state": "ACTIVE" }');

SELECT documentdb_api.insert_one(
    'collation_nested_db', 'union_target',
    '{ "_id": 201, "key": "CAFE", "rank": "3" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'union_target',
    '{ "_id": 202, "key": "café", "rank": "11" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'union_target',
    '{ "_id": 203, "key": "cafe", "rank": "4" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'union_target',
    '{ "_id": 204, "key": "coffee", "rank": "5" }');

SELECT documentdb_api.insert_one(
    'collation_nested_db', 'graph_target',
    '{ "_id": 301, "node": "ROOT", "next": "branch", "state": "ACTIVE" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'graph_target',
    '{ "_id": 302, "node": "BRANCH", "next": "leaf", "state": "active" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'graph_target',
    '{ "_id": 303, "node": "LEAF", "next": null, "state": "inactive" }');

SELECT documentdb_api.insert_one(
    'collation_nested_db', 'binary_source',
    '{ "_id": 1, "key": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'defaulted_target',
    '{ "_id": 401, "key": "CAFE" }');
SELECT documentdb_api.insert_one(
    'collation_nested_db', 'defaulted_target',
    '{ "_id": 402, "key": "cafe" }');

-- $lookup join equality and its sub-pipeline inherit the source default.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "localField": "key",
            "foreignField": "key",
            "pipeline": [
                { "$match": { "state": "active" } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ] }');

-- Explicit simple applies to both the join and the nested predicate.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "localField": "key",
            "foreignField": "key",
            "pipeline": [
                { "$match": { "state": "active" } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ], "collation": { "locale": "simple" } }');

-- Correlated $lookup expressions inherit the same effective collation.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "let": {
                "sourceKey": "$key",
                "wantedState": "active"
            },
            "pipeline": [
                { "$match": {
                    "$expr": {
                        "$and": [
                            { "$eq": ["$key", "$$sourceKey"] },
                            { "$eq": ["$state", "$$wantedState"] }
                        ]
                    }
                } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "let": {
                "sourceKey": "$key",
                "wantedState": "active"
            },
            "pipeline": [
                { "$match": {
                    "$expr": {
                        "$and": [
                            { "$eq": ["$key", "$$sourceKey"] },
                            { "$eq": ["$state", "$$wantedState"] }
                        ]
                    }
                } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ], "collation": { "locale": "simple" } }');

-- $facet propagates the inherited default through matching, ordering, and a
-- second nested-pipeline boundary.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$facet": {
            "matched": [
                { "$match": { "key": "cafe" } },
                { "$count": "count" }
            ],
            "ordered": [
                { "$sort": { "rank": 1 } },
                { "$project": { "_id": 1, "rank": 1 } }
            ],
            "nestedLookup": [
                { "$match": { "_id": 1 } },
                { "$lookup": {
                    "from": "lookup_target",
                    "let": {
                        "sourceKey": "$key",
                        "wantedState": "active"
                    },
                    "pipeline": [
                        { "$match": {
                            "$expr": {
                                "$and": [
                                    { "$eq": ["$key", "$$sourceKey"] },
                                    { "$eq": ["$state", "$$wantedState"] }
                                ]
                            }
                        } }
                    ],
                    "as": "matches"
                } },
                { "$project": {
                    "_id": 0,
                    "matchCount": { "$size": "$matches" }
                } }
            ]
        } }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$facet": {
            "matched": [
                { "$match": { "key": "cafe" } },
                { "$count": "count" }
            ],
            "ordered": [
                { "$sort": { "rank": 1 } },
                { "$project": { "_id": 1, "rank": 1 } }
            ],
            "nestedLookup": [
                { "$match": { "_id": 1 } },
                { "$lookup": {
                    "from": "lookup_target",
                    "let": {
                        "sourceKey": "$key",
                        "wantedState": "active"
                    },
                    "pipeline": [
                        { "$match": {
                            "$expr": {
                                "$and": [
                                    { "$eq": ["$key", "$$sourceKey"] },
                                    { "$eq": ["$state", "$$wantedState"] }
                                ]
                            }
                        } }
                    ],
                    "as": "matches"
                } },
                { "$project": {
                    "_id": 0,
                    "matchCount": { "$size": "$matches" }
                } }
            ]
        } }
    ], "collation": { "locale": "simple" } }');

-- $unionWith uses the outer collection default in its sub-pipeline and in
-- comparison accumulators after the union.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$project": { "_id": 1, "rank": 1 } },
        { "$unionWith": {
            "coll": "union_target",
            "pipeline": [
                { "$match": { "key": "cafe" } },
                { "$project": { "_id": 1, "rank": 1 } }
            ]
        } },
        { "$group": {
            "_id": null,
            "count": { "$sum": 1 },
            "minimumRank": { "$min": "$rank" },
            "maximumRank": { "$max": "$rank" }
        } },
        { "$project": {
            "_id": 0,
            "count": 1,
            "minimumRank": 1,
            "maximumRank": 1
        } }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$project": { "_id": 1, "rank": 1 } },
        { "$unionWith": {
            "coll": "union_target",
            "pipeline": [
                { "$match": { "key": "cafe" } },
                { "$project": { "_id": 1, "rank": 1 } }
            ]
        } },
        { "$group": {
            "_id": null,
            "count": { "$sum": 1 },
            "minimumRank": { "$min": "$rank" },
            "maximumRank": { "$max": "$rank" }
        } },
        { "$project": {
            "_id": 0,
            "count": 1,
            "minimumRank": 1,
            "maximumRank": 1
        } }
    ], "collation": { "locale": "simple" } }');

-- $graphLookup traversal and restrictSearchWithMatch inherit the source
-- collection default.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$graphLookup": {
            "from": "graph_target",
            "startWith": "$graphStart",
            "connectFromField": "next",
            "connectToField": "node",
            "as": "destinations",
            "restrictSearchWithMatch": { "state": "active" }
        } },
        { "$project": {
            "_id": 1,
            "destinationCount": { "$size": "$destinations" }
        } }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$graphLookup": {
            "from": "graph_target",
            "startWith": "$graphStart",
            "connectFromField": "next",
            "connectToField": "node",
            "as": "destinations",
            "restrictSearchWithMatch": { "state": "active" }
        } },
        { "$project": {
            "_id": 1,
            "destinationCount": { "$size": "$destinations" }
        } }
    ], "collation": { "locale": "simple" } }');

-- Full plans for every nested-pipeline collation case.

-- $lookup with inherited collection default.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "localField": "key",
            "foreignField": "key",
            "pipeline": [
                { "$match": { "state": "active" } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ] }')
$cmd$) AS plan(query_plan);

-- $lookup with explicit simple override.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "localField": "key",
            "foreignField": "key",
            "pipeline": [
                { "$match": { "state": "active" } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ], "collation": { "locale": "simple" } }')
$cmd$) AS plan(query_plan);

-- correlated $lookup with inherited collection default.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "let": {
                "sourceKey": "$key",
                "wantedState": "active"
            },
            "pipeline": [
                { "$match": {
                    "$expr": {
                        "$and": [
                            { "$eq": ["$key", "$$sourceKey"] },
                            { "$eq": ["$state", "$$wantedState"] }
                        ]
                    }
                } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ] }')
$cmd$) AS plan(query_plan);

-- correlated $lookup with explicit simple override.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": { "$in": [1, 2] } } },
        { "$lookup": {
            "from": "lookup_target",
            "let": {
                "sourceKey": "$key",
                "wantedState": "active"
            },
            "pipeline": [
                { "$match": {
                    "$expr": {
                        "$and": [
                            { "$eq": ["$key", "$$sourceKey"] },
                            { "$eq": ["$state", "$$wantedState"] }
                        ]
                    }
                } }
            ],
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } },
        { "$sort": { "_id": 1 } }
    ], "collation": { "locale": "simple" } }')
$cmd$) AS plan(query_plan);

-- $facet with inherited collection default.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$facet": {
            "matched": [
                { "$match": { "key": "cafe" } },
                { "$count": "count" }
            ],
            "ordered": [
                { "$sort": { "rank": 1 } },
                { "$project": { "_id": 1, "rank": 1 } }
            ],
            "nestedLookup": [
                { "$match": { "_id": 1 } },
                { "$lookup": {
                    "from": "lookup_target",
                    "let": {
                        "sourceKey": "$key",
                        "wantedState": "active"
                    },
                    "pipeline": [
                        { "$match": {
                            "$expr": {
                                "$and": [
                                    { "$eq": ["$key", "$$sourceKey"] },
                                    { "$eq": ["$state", "$$wantedState"] }
                                ]
                            }
                        } }
                    ],
                    "as": "matches"
                } },
                { "$project": {
                    "_id": 0,
                    "matchCount": { "$size": "$matches" }
                } }
            ]
        } }
    ] }')
$cmd$) AS plan(query_plan);

-- $facet with explicit simple override.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$facet": {
            "matched": [
                { "$match": { "key": "cafe" } },
                { "$count": "count" }
            ],
            "ordered": [
                { "$sort": { "rank": 1 } },
                { "$project": { "_id": 1, "rank": 1 } }
            ],
            "nestedLookup": [
                { "$match": { "_id": 1 } },
                { "$lookup": {
                    "from": "lookup_target",
                    "let": {
                        "sourceKey": "$key",
                        "wantedState": "active"
                    },
                    "pipeline": [
                        { "$match": {
                            "$expr": {
                                "$and": [
                                    { "$eq": ["$key", "$$sourceKey"] },
                                    { "$eq": ["$state", "$$wantedState"] }
                                ]
                            }
                        } }
                    ],
                    "as": "matches"
                } },
                { "$project": {
                    "_id": 0,
                    "matchCount": { "$size": "$matches" }
                } }
            ]
        } }
    ], "collation": { "locale": "simple" } }')
$cmd$) AS plan(query_plan);

-- $unionWith with inherited collection default.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$project": { "_id": 1, "rank": 1 } },
        { "$unionWith": {
            "coll": "union_target",
            "pipeline": [
                { "$match": { "key": "cafe" } },
                { "$project": { "_id": 1, "rank": 1 } }
            ]
        } },
        { "$group": {
            "_id": null,
            "count": { "$sum": 1 },
            "minimumRank": { "$min": "$rank" },
            "maximumRank": { "$max": "$rank" }
        } },
        { "$project": {
            "_id": 0,
            "count": 1,
            "minimumRank": 1,
            "maximumRank": 1
        } }
    ] }')
$cmd$) AS plan(query_plan);

-- $unionWith with explicit simple override.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$project": { "_id": 1, "rank": 1 } },
        { "$unionWith": {
            "coll": "union_target",
            "pipeline": [
                { "$match": { "key": "cafe" } },
                { "$project": { "_id": 1, "rank": 1 } }
            ]
        } },
        { "$group": {
            "_id": null,
            "count": { "$sum": 1 },
            "minimumRank": { "$min": "$rank" },
            "maximumRank": { "$max": "$rank" }
        } },
        { "$project": {
            "_id": 0,
            "count": 1,
            "minimumRank": 1,
            "maximumRank": 1
        } }
    ], "collation": { "locale": "simple" } }')
$cmd$) AS plan(query_plan);

-- $graphLookup with inherited collection default.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$graphLookup": {
            "from": "graph_target",
            "startWith": "$graphStart",
            "connectFromField": "next",
            "connectToField": "node",
            "as": "destinations",
            "restrictSearchWithMatch": { "state": "active" }
        } },
        { "$project": {
            "_id": 1,
            "destinationCount": { "$size": "$destinations" }
        } }
    ] }')
$cmd$) AS plan(query_plan);

-- $graphLookup with explicit simple override.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "_id": 1 } },
        { "$graphLookup": {
            "from": "graph_target",
            "startWith": "$graphStart",
            "connectFromField": "next",
            "connectToField": "node",
            "as": "destinations",
            "restrictSearchWithMatch": { "state": "active" }
        } },
        { "$project": {
            "_id": 1,
            "destinationCount": { "$size": "$destinations" }
        } }
    ], "collation": { "locale": "simple" } }')
$cmd$) AS plan(query_plan);

-- $lookup foreign-default isolation.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$lookup": {
            "from": "defaulted_target",
            "localField": "key",
            "foreignField": "key",
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } }
    ] }')
$cmd$) AS plan(query_plan);

-- $lookup with explicit command collation.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$lookup": {
            "from": "defaulted_target",
            "localField": "key",
            "foreignField": "key",
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } }
    ], "collation": {
        "locale": "en",
        "strength": 1,
        "numericOrdering": true
    } }')
$cmd$) AS plan(query_plan);

-- $unionWith foreign-default isolation.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$unionWith": {
            "coll": "defaulted_target",
            "pipeline": [
                { "$match": { "key": "cafe" } }
            ]
        } },
        { "$count": "matchingDocuments" }
    ] }')
$cmd$) AS plan(query_plan);

-- $unionWith with explicit command collation.
SELECT query_plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$unionWith": {
            "coll": "defaulted_target",
            "pipeline": [
                { "$match": { "key": "cafe" } }
            ]
        } },
        { "$count": "matchingDocuments" }
    ], "collation": {
        "locale": "en",
        "strength": 1,
        "numericOrdering": true
    } }')
$cmd$) AS plan(query_plan);

-- A foreign default is not inherited when the outer collection has no
-- default. An explicit command collation still governs both collections.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$lookup": {
            "from": "defaulted_target",
            "localField": "key",
            "foreignField": "key",
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$lookup": {
            "from": "defaulted_target",
            "localField": "key",
            "foreignField": "key",
            "as": "matches"
        } },
        { "$project": {
            "_id": 1,
            "matchCount": { "$size": "$matches" }
        } }
    ], "collation": {
        "locale": "en",
        "strength": 1,
        "numericOrdering": true
    } }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$unionWith": {
            "coll": "defaulted_target",
            "pipeline": [
                { "$match": { "key": "cafe" } }
            ]
        } },
        { "$count": "matchingDocuments" }
    ] }');

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_db',
    '{ "aggregate": "binary_source", "pipeline": [
        { "$match": { "key": "cafe" } },
        { "$unionWith": {
            "coll": "defaulted_target",
            "pipeline": [
                { "$match": { "key": "cafe" } }
            ]
        } },
        { "$count": "matchingDocuments" }
    ], "collation": {
        "locale": "en",
        "strength": 1,
        "numericOrdering": true
    } }');

SELECT documentdb_api.drop_database('collation_nested_db');

RESET documentdb_core.enableCollation;
