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

-- Full plan for the inherited expression predicate.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
        'collation_aggregate_dist_db',
        '{ "aggregate": "source", "pipeline": [
            { "$match": { "$expr": { "$eq": ["$category", "CAFE"] } } }
        ] }')
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

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

SELECT query_plan
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

-- Full plan for the explicit simple override.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_aggregate_dist_db',
    '{ "aggregate": "source", "pipeline": [
        { "$match": { "category": "cafe" } },
        { "$sort": { "rank": 1 } },
        { "$project": { "_id": 1, "category": 1, "rank": 1 } }
    ], "collation": { "locale": "simple" } }')
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

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

-- Full plan with collection-default collation disabled.
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
ROLLBACK;

SELECT documentdb_api.drop_collection('collation_aggregate_dist_db', 'source');

-- Nested pipeline collection-default collation inheritance.

SELECT documentdb_api.create_collection('collation_nested_dist_db', 'source');
SELECT documentdb_api.create_collection('collation_nested_dist_db', 'lookup_target');
SELECT documentdb_api.create_collection('collation_nested_dist_db', 'union_target');
SELECT documentdb_api.create_collection('collation_nested_dist_db', 'graph_target');
SELECT documentdb_api.create_collection('collation_nested_dist_db', 'binary_source');
SELECT documentdb_api.create_collection('collation_nested_dist_db', 'defaulted_target');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": {
    "locale": "en",
    "strength": 1,
    "numericOrdering": true
} }'::documentdb_core.bson
WHERE database_name = 'collation_nested_dist_db'
  AND collection_name = 'source';

-- Foreign collection defaults must not replace the command-wide collation.
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "simple" } }'::documentdb_core.bson
WHERE database_name = 'collation_nested_dist_db'
  AND collection_name IN ('lookup_target', 'union_target', 'graph_target');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": {
    "locale": "en",
    "strength": 1,
    "numericOrdering": true
} }'::documentdb_core.bson
WHERE database_name = 'collation_nested_dist_db'
  AND collection_name = 'defaulted_target';

SELECT documentdb_api_internal.invalidate_collection_cache();

SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'source',
    '{ "_id": 1, "key": "cafe", "rank": "10", "graphStart": "root" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'source',
    '{ "_id": 2, "key": "tea", "rank": "2", "graphStart": "missing" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'source',
    '{ "_id": 3, "key": "CAFE", "rank": "1", "graphStart": "missing" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'source',
    '{ "_id": 4, "key": "café", "rank": "20", "graphStart": "missing" }');

SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'lookup_target',
    '{ "_id": 101, "key": "CAFE", "state": "ACTIVE" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'lookup_target',
    '{ "_id": 102, "key": "café", "state": "active" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'lookup_target',
    '{ "_id": 103, "key": "cafe", "state": "inactive" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'lookup_target',
    '{ "_id": 104, "key": "tea", "state": "ACTIVE" }');

SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'union_target',
    '{ "_id": 201, "key": "CAFE", "rank": "3" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'union_target',
    '{ "_id": 202, "key": "café", "rank": "11" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'union_target',
    '{ "_id": 203, "key": "cafe", "rank": "4" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'union_target',
    '{ "_id": 204, "key": "coffee", "rank": "5" }');

SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'graph_target',
    '{ "_id": 301, "node": "ROOT", "next": "branch", "state": "ACTIVE" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'graph_target',
    '{ "_id": 302, "node": "BRANCH", "next": "leaf", "state": "active" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'graph_target',
    '{ "_id": 303, "node": "LEAF", "next": null, "state": "inactive" }');

SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'binary_source',
    '{ "_id": 1, "key": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'defaulted_target',
    '{ "_id": 401, "key": "CAFE" }');
SELECT documentdb_api.insert_one(
    'collation_nested_dist_db', 'defaulted_target',
    '{ "_id": 402, "key": "cafe" }');

SELECT documentdb_api.shard_collection(
    'collation_nested_dist_db', 'source', '{ "_id": "hashed" }', false);
SELECT documentdb_api.shard_collection(
    'collation_nested_dist_db', 'binary_source', '{ "_id": "hashed" }', false);

BEGIN;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL documentdb_core.enableCollation TO on;

-- $lookup join equality and its sub-pipeline inherit the source default across
-- the distributed outer query.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $lookup with inherited collection default.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $lookup with explicit simple override.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- Correlated $lookup expressions inherit the same effective collation.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for correlated $lookup with inherited collection default.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for correlated $lookup with explicit simple override.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- $facet propagates the inherited default through matching, ordering, and a
-- second nested-pipeline boundary.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $facet with inherited collection default.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $facet with explicit simple override.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- $unionWith uses the outer collection default in its sub-pipeline and in
-- comparison accumulators after the union.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $unionWith with inherited collection default.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $unionWith with explicit simple override.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- $graphLookup supports a distributed source when the target remains
-- unsharded, and both traversal and restriction inherit the source default.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $graphLookup with inherited collection default.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $graphLookup with explicit simple override.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

-- A foreign default is not inherited when the distributed outer collection
-- has no default. An explicit command collation governs both collections.
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $lookup foreign-default isolation.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $lookup with explicit command collation.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $unionWith foreign-default isolation.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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

-- Full plan for $unionWith with explicit command collation.
SELECT query_plan
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_pipeline(
    'collation_nested_dist_db',
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
$cmd$, p_ignore_distributed_subplan_ids => true) AS plan(query_plan);

ROLLBACK;

SELECT documentdb_api.drop_database('collation_nested_dist_db');

RESET citus.propagate_set_commands;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb_core.enableCollation;
