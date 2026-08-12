-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET documentdb.next_collection_id TO 25720000;
SET documentdb.next_collection_index_id TO 25720000;

-- The fixture combines multiple outer rows, array join keys, duplicate foreign
-- matches, multiple nested matches, sibling lookups, and a three-level lookup
-- chain. This catches cross-row correlation and row loss while post-join
-- results are aggregated, unwound, processed, and aggregated again.
SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_db',
    'orders',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 1, "itemCodes": [10, 20] }'),
        ('{ "_id": 2, "itemCodes": [20] }'),
        ('{ "_id": 3, "itemCodes": [999] }'),
        ('{ "_id": 4, "supplierCode": "S1" }')
) AS docs(document);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_db',
    'items',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 101, "code": 10, "enabled": true,  "supplierCode": "S1", "supplier": { "code": "S1" } }'),
        ('{ "_id": 102, "code": 20, "enabled": true,  "supplierCode": "S2", "supplier": { "code": "S2" } }'),
        ('{ "_id": 103, "code": 20, "enabled": false, "supplierCode": "S3", "supplier": { "code": "S3" } }'),
        ('{ "_id": 104, "code": 20, "enabled": true,  "supplierCode": "S3", "supplier": { "code": "S3" } }')
) AS docs(document);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_db',
    'suppliers',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 201, "code": "S1", "regionCode": "R1" }'),
        ('{ "_id": 202, "code": "S1", "regionCode": "R2" }'),
        ('{ "_id": 203, "code": "S2", "regionCode": "R2" }'),
        ('{ "_id": 204, "code": "S3", "regionCode": "R3" }')
) AS docs(document);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_db',
    'regions',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 301, "code": "R1" }'),
        ('{ "_id": 302, "code": "R2" }'),
        ('{ "_id": 303, "code": "R3" }')
) AS docs(document);

SELECT COUNT(documentdb_api.insert_one(
    'lookup_post_join_db',
    'stock',
    document::bson
))
FROM (
    VALUES
        ('{ "_id": 401, "itemCode": 10, "warehouse": "A" }'),
        ('{ "_id": 402, "itemCode": 20, "warehouse": "A" }'),
        ('{ "_id": 403, "itemCode": 20, "warehouse": "B" }')
) AS docs(document);

SHOW documentdb.force_nested_lookup_pipeline_after_join;

-- Flag off establishes the semantic baseline.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "enabled": true } },
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
                        "from": "regions",
                        "localField": "regionCode",
                        "foreignField": "code",
                        "pipeline": [
                          { "$sort": { "_id": 1 } }
                        ],
                        "as": "region"
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              },
              {
                "$lookup": {
                  "from": "stock",
                  "localField": "code",
                  "foreignField": "itemCode",
                  "pipeline": [
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "stock"
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

SET documentdb.force_nested_lookup_pipeline_after_join TO on;

-- Flag on must preserve the same result after each parent equality join
-- narrows the rows consumed by the nested lookups.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "enabled": true } },
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
                        "from": "regions",
                        "localField": "regionCode",
                        "foreignField": "code",
                        "pipeline": [
                          { "$sort": { "_id": 1 } }
                        ],
                        "as": "region"
                      }
                    }
                  ],
                  "as": "suppliers"
                }
              },
              {
                "$lookup": {
                  "from": "stock",
                  "localField": "code",
                  "foreignField": "itemCode",
                  "pipeline": [
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "stock"
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

-- Lookup followed immediately by unwind uses the combined lookup-unwind path.
-- Full documents verify that the nested results remain correlated after the
-- combined stage expands the parent matches.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "enabled": true } },
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "enabled": true } },
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
        { "$unwind": "$items" },
        { "$count": "matchedOnlyCount" }
      ]
    }
    $pipeline$
);

-- let remains correlated with the matched item rather than the outer order or
-- another matched item.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "let": {
                    "supplierCode": "$supplierCode"
                  },
                  "pipeline": [
                    {
                      "$match": {
                        "$expr": {
                          "$eq": [ "$code", "$$supplierCode" ]
                        }
                      }
                    },
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "suppliersViaLet"
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

-- The nested lookup output replaces the parent foreign path. The equality
-- match must consume the original supplier.code before that replacement.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 4 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "supplierCode",
            "foreignField": "supplier.code",
            "pipeline": [
              { "$sort": { "_id": 1 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplier.code",
                  "foreignField": "code",
                  "pipeline": [
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "supplier"
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

-- A missing nested namespace contributes an empty array without removing the
-- parent foreign document.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "missing_nested_collection",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "missing"
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

RESET documentdb.force_nested_lookup_pipeline_after_join;

-- Flag-off controls for the specialized paths exercised above with the flag
-- enabled.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "enabled": true } },
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "enabled": true } },
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
        { "$unwind": "$items" },
        { "$count": "matchedOnlyCount" }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "let": {
                    "supplierCode": "$supplierCode"
                  },
                  "pipeline": [
                    {
                      "$match": {
                        "$expr": {
                          "$eq": [ "$code", "$$supplierCode" ]
                        }
                      }
                    },
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "suppliersViaLet"
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 4 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "supplierCode",
            "foreignField": "supplier.code",
            "pipeline": [
              { "$sort": { "_id": 1 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplier.code",
                  "foreignField": "code",
                  "pipeline": [
                    { "$sort": { "_id": 1 } }
                  ],
                  "as": "supplier"
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "missing_nested_collection",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "missing"
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

-- Immediate outer, parent-foreign, and nested views use order-sensitive view
-- pipelines so placement mistakes cannot be hidden by equivalent row sets.
SELECT documentdb_api.create_collection_view(
    'lookup_post_join_db',
    '{
      "create": "orders_first_view",
      "viewOn": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        { "$limit": 1 }
      ]
    }'
);

SELECT documentdb_api.create_collection_view(
    'lookup_post_join_db',
    '{
      "create": "items_last_view",
      "viewOn": "items",
      "pipeline": [
        { "$match": { "enabled": true } },
        { "$sort": { "_id": -1 } },
        { "$limit": 1 }
      ]
    }'
);

SELECT documentdb_api.create_collection_view(
    'lookup_post_join_db',
    '{
      "create": "suppliers_ordered_view",
      "viewOn": "suppliers",
      "pipeline": [
        { "$sort": { "_id": 1 } }
      ]
    }'
);

-- Flag-off view baselines.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders_first_view",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$sort": { "_id": 1 } },
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items_last_view",
            "localField": "itemCodes",
            "foreignField": "code",
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "suppliers_ordered_view",
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

SET documentdb.force_nested_lookup_pipeline_after_join TO on;

-- Flag-on view comparisons.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders_first_view",
      "pipeline": [
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$sort": { "_id": 1 } },
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items_last_view",
            "localField": "itemCodes",
            "foreignField": "code",
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

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "suppliers_ordered_view",
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

RESET documentdb.force_nested_lookup_pipeline_after_join;

-- Parent-level let must remain bound to the correct outer row when its
-- pipeline also contains a nested lookup.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "let": {
              "outerOrderId": "$_id"
            },
            "pipeline": [
              {
                "$match": {
                  "$expr": {
                    "$eq": [ "$$outerOrderId", 1 ]
                  }
                }
              },
              { "$sort": { "_id": 1 } },
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

SET documentdb.force_nested_lookup_pipeline_after_join TO on;

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "let": {
              "outerOrderId": "$_id"
            },
            "pipeline": [
              {
                "$match": {
                  "$expr": {
                    "$eq": [ "$$outerOrderId", 1 ]
                  }
                }
              },
              { "$sort": { "_id": 1 } },
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

RESET documentdb.force_nested_lookup_pipeline_after_join;

-- Flag-off controls for pipelines with stages after the first nested lookup.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              },
              { "$match": { "suppliers.regionCode": "R2" } },
              { "$sort": { "_id": 1 } }
            ],
            "as": "items"
          }
        }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              },
              { "$sort": { "_id": 1 } },
              { "$skip": 1 },
              { "$limit": 1 }
            ],
            "as": "items"
          }
        }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              },
              {
                "$group": {
                  "_id": "$supplierCode",
                  "itemCount": { "$sum": 1 }
                }
              },
              { "$sort": { "_id": 1 } }
            ],
            "as": "groups"
          }
        }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "supplier"
                }
              },
              { "$unwind": "$supplier" },
              { "$sort": { "supplier._id": 1 } }
            ],
            "as": "items"
          }
        }
      ]
    }
    $pipeline$
);

SET documentdb.force_nested_lookup_pipeline_after_join TO on;

-- The force setting keeps the nested lookup post-join for these suffix-stage
-- pipelines.
SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              },
              { "$match": { "suppliers.regionCode": "R2" } },
              { "$sort": { "_id": 1 } }
            ],
            "as": "items"
          }
        }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              },
              { "$sort": { "_id": 1 } },
              { "$skip": 1 },
              { "$limit": 1 }
            ],
            "as": "items"
          }
        }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$sort": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "suppliers"
                }
              },
              {
                "$group": {
                  "_id": "$supplierCode",
                  "itemCount": { "$sum": 1 }
                }
              },
              { "$sort": { "_id": 1 } }
            ],
            "as": "groups"
          }
        }
      ]
    }
    $pipeline$
);

SELECT document
FROM bson_aggregation_pipeline(
    'lookup_post_join_db',
    $pipeline$
    {
      "aggregate": "orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "items",
            "localField": "itemCodes",
            "foreignField": "code",
            "pipeline": [
              { "$match": { "code": 10 } },
              {
                "$lookup": {
                  "from": "suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "supplier"
                }
              },
              { "$unwind": "$supplier" },
              { "$sort": { "supplier._id": 1 } }
            ],
            "as": "items"
          }
        }
      ]
    }
    $pipeline$
);

RESET documentdb.force_nested_lookup_pipeline_after_join;
