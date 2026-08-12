-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET citus.next_shard_id TO 257300000;
SET documentdb.next_collection_id TO 25730000;
SET documentdb.next_collection_index_id TO 25730000;

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_dist',
    'orders',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 1, "orderKey": "K1" }'),
        ('{ "_id": 2, "orderKey": "missing" }')
) AS docs(document);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_dist',
    'items',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 11, "itemKey": "K1", "supplierCode": "S1" }'),
        ('{ "_id": 12, "itemKey": "K1", "supplierCode": "S2" }')
) AS docs(document);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_dist',
    'suppliers',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 21, "code": "S1", "regionCode": "R1" }'),
        ('{ "_id": 22, "code": "S2", "regionCode": "R2" }')
) AS docs(document);

SELECT documentdb_api.insert_one(
    'lookup_post_join_dist',
    'archive_suppliers',
    '{ "_id": 31, "code": "A1", "regionCode": "R1" }'
);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_dist',
    'regions_sharded',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 41, "regionCode": "R1" }'),
        ('{ "_id": 42, "regionCode": "R2" }')
) AS docs(document);

SELECT documentdb_api.shard_collection(
    'lookup_post_join_dist',
    'regions_sharded',
    '{ "regionCode": "hashed" }',
    false
);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_dist',
    'orders_sharded',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 51, "orderKey": "K1" }'),
        ('{ "_id": 52, "orderKey": "missing" }')
) AS docs(document);

SELECT documentdb_api.shard_collection(
    'lookup_post_join_dist',
    'orders_sharded',
    '{ "orderKey": "hashed" }',
    false
);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_dist',
    'items_sharded',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 61, "itemKey": "K1", "supplierCode": "S1" }'),
        ('{ "_id": 62, "itemKey": "K1", "supplierCode": "S2" }')
) AS docs(document);

SELECT documentdb_api.shard_collection(
    'lookup_post_join_dist',
    'items_sharded',
    '{ "itemKey": "hashed" }',
    false
);

SHOW documentdb.force_nested_lookup_pipeline_after_join;

-- Fully unsharded control before enabling the forced post-join policy.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              { "$sort": { "_id": 1 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- Flag-off controls for container stages whose subpipelines reach a
-- user-sharded collection.
-- The $unionWith shape succeeds under the inline policy.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    {
                      "$unionWith": {
                        "coll": "archive_suppliers",
                        "pipeline": [
                          {
                            "$lookup": {
                              "from": "regions_sharded",
                              "localField": "regionCode",
                              "foreignField": "regionCode",
                              "as": "regions"
                            }
                          }
                        ]
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- PRE-EXISTING LIMITATION:
-- A lookup inside a $facet branch that reaches a user-sharded collection
-- already produces the correlated CTE error with the GUC disabled.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    {
                      "$facet": {
                        "enriched": [
                          {
                            "$lookup": {
                              "from": "regions_sharded",
                              "localField": "regionCode",
                              "foreignField": "regionCode",
                              "as": "regions"
                            }
                          }
                        ],
                        "summary": [
                          { "$count": "count" }
                        ]
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- Flag off also establishes the result for a three-level lookup chain that
-- reaches a user-sharded collection.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              { "$sort": { "_id": 1 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    { "$sort": { "_id": 1 } },
                    {
                      "$lookup": {
                        "from": "regions_sharded",
                        "localField": "regionCode",
                        "foreignField": "regionCode",
                        "as": "regions"
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- Flag-off baselines for user-sharded outer and parent-foreign topologies.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders_sharded",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items_sharded",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- The flag-off lookup-unwind control must preserve the nested documents, not
-- only the number of parent matches.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders_sharded",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        {
          "$unwind": {
            "path": "$items",
            "preserveNullAndEmptyArrays": true
          }
        },
        { "$sort": { "_id": 1, "items._id": 1 } }
      ]
    }
    $pipeline$
);

SET documentdb.force_nested_lookup_pipeline_after_join TO on;

-- The forced plan must expose the post-join correlated subplan.
EXPLAIN (COSTS OFF)
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        }
      ]
    }
    $pipeline$
);

-- Fully unsharded post-join execution must preserve the flag-off result.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              { "$sort": { "_id": 1 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- The force setting has no deep topology fallback. This query is expected to
-- fail when the post-join plan reaches the user-sharded regions collection.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              { "$sort": { "_id": 1 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    { "$sort": { "_id": 1 } },
                    {
                      "$lookup": {
                        "from": "regions_sharded",
                        "localField": "regionCode",
                        "foreignField": "regionCode",
                        "as": "regions"
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- The force setting has no fallback for user-sharded outer or parent-foreign
-- collections. These queries are expected to fail when Citus cannot plan the
-- correlated shape.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders_sharded",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items_sharded",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- The force setting also leaves the combined lookup-unwind shape without a
-- distributed fallback.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders_sharded",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        {
          "$unwind": {
            "path": "$items",
            "preserveNullAndEmptyArrays": true
          }
        },
        { "$sort": { "_id": 1, "items._id": 1 } }
      ]
    }
    $pipeline$
);

-- The force setting does not inspect or fall back for a $unionWith subpipeline
-- that reaches a user-sharded collection.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    {
                      "$unionWith": {
                        "coll": "archive_suppliers",
                        "pipeline": [
                          {
                            "$lookup": {
                              "from": "regions_sharded",
                              "localField": "regionCode",
                              "foreignField": "regionCode",
                              "as": "regions"
                            }
                          }
                        ]
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

-- The force setting does not widen support for the same $facet shape; it
-- continues to produce the correlated CTE error.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_dist',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "orderKey",
            "foreignField": "itemKey",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    {
                      "$facet": {
                        "enriched": [
                          {
                            "$lookup": {
                              "from": "regions_sharded",
                              "localField": "regionCode",
                              "foreignField": "regionCode",
                              "as": "regions"
                            }
                          }
                        ],
                        "summary": [
                          { "$count": "count" }
                        ]
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              }
            ],
            "as": "items"
          }
        },
        { "$sort": { "_id": 1 } }
      ]
    }
    $pipeline$
);

RESET documentdb.force_nested_lookup_pipeline_after_join;
