SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core;

SET documentdb.next_collection_id TO 200;
SET documentdb.next_collection_index_id TO 200;

SELECT COUNT(documentdb_api.insert_one('exprdb', 'exprcoll', bson_build_document('_id'::text, i, 'a'::text, i, 'b'::text, i))) FROM generate_series(1, 1000) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('exprdb', '{ "createIndexes": "exprcoll", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableOrderedIndex": true }] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('exprdb', '{ "createIndexes": "exprcoll", "indexes": [ { "key": { "b": 1 }, "name": "b_1", "enableOrderedIndex": false }] }', TRUE);

-- no pushdown for arbitrary operators
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$isArray": "$a" } } }');

-- pushdown does not work for a non-ordered index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$eq": [ "$b", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$eq": [ 10, "$b" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gt": [ "$b", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gt": [ 10, "$b" ] } } }');

-- simple pushdown of operators
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$eq": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$eq": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gt": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gt": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gte": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gte": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lte": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lte": [ 10, "$a" ] } } }');

-- partial pushdown if it's conjunction
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$and": [ { "$lt": [ "$a", 10 ] }, { "$isArray": "$c" } ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$and": [ { "$lt": [ "$a", 10 ] }, { "$gt": [ "$b", 6 ] } ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$and": [ { "$lt": [ "$a", 10 ] }, { "$or": [ { "$eq": [ "$a", 5 ] }, { "$lt": [ "$a", 6 ] } ] } ] } } }');

-- full pushdown of supported conjunction
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$and": [ { "$lt": [ "$a", 10 ] }, { "$gt": [ "$a", 5 ] } ] } } }');

-- pushdown of expressions that evaluate to constants
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ { "$add": [ 2, 3 ] }, "$a" ] } } }');

-- Support pushdown of expressions that are variables.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ "$$myvar", "$a" ] } }, "let": { "myvar": 3 } }');

-- TODO: Support pushdown of expressions that evaluate to constants with variables.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ { "$add": [ 2, "$$myvar" ] }, "$a" ] } }, "let": { "myvar": 3 } }');

set documentdb.enableExtendedExplainPlans to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ "$$myvar", "$a" ] } }, "let": { "myvar": 3 } }') $cmd$);

-- now try with $lookup
SELECT COUNT(documentdb_api.insert_one('exprdb', 'exprcollright', bson_build_document('_id'::text, i, 'a'::text, i, 'b'::text, i))) FROM generate_series(1, 1000) i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('exprdb', '{ "createIndexes": "exprcollright", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableOrderedIndex": true }] }', TRUE);

-- standard lookup
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('exprdb',
        '{ "aggregate": "exprcoll", "pipeline":[ { "$match": { "$expr": { "$gte": [ "$a", 10 ] } } }, { "$lookup": { "from": "exprcollright", "as": "res", "localField": "a", "foreignField": "a" } } ] }') $cmd$);

SHOW documentdb.force_nested_lookup_pipeline_after_join;
SET documentdb.force_nested_lookup_pipeline_after_join TO on;

-- nested lookup should enrich only documents matched by the parent equality join
SELECT documentdb_api.insert_one(
    'exprdb',
    'lookup_orders',
    '{ "_id": 1, "itemCode": 42 }'
);

SELECT COUNT(documentdb_api.insert_one(
    'exprdb',
    'lookup_items',
    bson_build_document(
        '_id'::text, i,
        'code'::text, i,
        'supplierCode'::text, i
    )
))
FROM generate_series(1, 1000) i;

SELECT COUNT(documentdb_api.insert_one(
    'exprdb',
    'lookup_suppliers',
    bson_build_document(
        '_id'::text, i,
        'code'::text, i
    )
))
FROM generate_series(1, 1000) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'exprdb',
    '{
      "createIndexes": "lookup_items",
      "indexes": [
        {
          "key": { "code": 1 },
          "name": "lookup_items_code_1",
          "enableOrderedIndex": true
        }
      ]
    }',
    TRUE
);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'exprdb',
    '{
      "createIndexes": "lookup_suppliers",
      "indexes": [
        {
          "key": { "code": 1 },
          "name": "lookup_suppliers_code_1",
          "enableOrderedIndex": true
        }
      ]
    }',
    TRUE
);

SELECT document
FROM bson_aggregation_pipeline(
    'exprdb',
    $pipeline$
    {
      "aggregate": "lookup_orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "lookup_items",
            "localField": "itemCode",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "lookup_suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
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

SET documentdb.forceDisableSeqScan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (
        COSTS OFF,
        ANALYZE ON,
        SUMMARY OFF,
        TIMING OFF,
        BUFFERS OFF
    )
    SELECT document
    FROM bson_aggregation_pipeline(
        'exprdb',
        $pipeline$
        {
          "aggregate": "lookup_orders",
          "pipeline": [
            { "$match": { "_id": 1 } },
            {
              "$lookup": {
                "from": "lookup_items",
                "localField": "itemCode",
                "foreignField": "code",
                "pipeline": [
                  {
                    "$lookup": {
                      "from": "lookup_suppliers",
                      "localField": "supplierCode",
                      "foreignField": "code",
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
    )
$cmd$);

RESET documentdb.forceDisableSeqScan;

-- The force setting keeps the nested lookup post-join even when a later stage
-- also consumes the enriched document.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (
        COSTS OFF,
        ANALYZE ON,
        SUMMARY OFF,
        TIMING OFF,
        BUFFERS OFF
    )
    SELECT document
    FROM bson_aggregation_pipeline(
        'exprdb',
        $pipeline$
        {
          "aggregate": "lookup_orders",
          "pipeline": [
            { "$match": { "_id": 1 } },
            {
              "$lookup": {
                "from": "lookup_items",
                "localField": "itemCode",
                "foreignField": "code",
                "pipeline": [
                  { "$match": { "code": 42 } },
                  {
                    "$lookup": {
                      "from": "lookup_suppliers",
                      "localField": "supplierCode",
                      "foreignField": "code",
                      "as": "supplier"
                    }
                  },
                  { "$match": { "supplier.code": 42 } }
                ],
                "as": "items"
              }
            }
          ]
        }
        $pipeline$
    )
$cmd$);

RESET documentdb.force_nested_lookup_pipeline_after_join;

-- Flag off: the inline policy preserves the matched document at the dotted
-- output path.
SELECT document
FROM bson_aggregation_pipeline(
    'exprdb',
    $pipeline$
    {
      "aggregate": "lookup_orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "lookup_items",
            "localField": "itemCode",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "lookup_suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "supplier"
                }
              }
            ],
            "as": "nested.items"
          }
        }
      ]
    }
    $pipeline$
);

-- PRE-EXISTING LIMITATION:
-- A foreign _id lookup with a non-empty pipeline already uses the post-join
-- transport while the GUC is off, so a dotted output path silently loses the
-- matched item.
SELECT document
FROM bson_aggregation_pipeline(
    'exprdb',
    $pipeline$
    {
      "aggregate": "lookup_orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "lookup_items",
            "localField": "itemCode",
            "foreignField": "_id",
            "pipeline": [
              { "$match": { "code": 42 } },
              {
                "$lookup": {
                  "from": "lookup_suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "supplier"
                }
              }
            ],
            "as": "nested.items"
          }
        }
      ]
    }
    $pipeline$
);

SET documentdb.force_nested_lookup_pipeline_after_join TO on;

-- SHOULD SUCCEED BUT SILENTLY RETURNS THE WRONG RESULT:
-- The matching item is dropped and the dotted output path contains an empty
-- array when the post-join transport uses the user path as its temporary key.
SELECT document
FROM bson_aggregation_pipeline(
    'exprdb',
    $pipeline$
    {
      "aggregate": "lookup_orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "lookup_items",
            "localField": "itemCode",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "lookup_suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "supplier"
                }
              }
            ],
            "as": "nested.items"
          }
        }
      ]
    }
    $pipeline$
);

RESET documentdb.force_nested_lookup_pipeline_after_join;

-- A dotted output path on a nested lookup with its own non-inline suffix is
-- also a pre-existing post-join transport limitation.
SELECT document
FROM bson_aggregation_pipeline(
    'exprdb',
    $pipeline$
    {
      "aggregate": "lookup_orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "lookup_items",
            "localField": "itemCode",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "lookup_suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "pipeline": [
                    { "$sort": { "_id": 1 } },
                    { "$limit": 1 }
                  ],
                  "as": "nested.suppliers"
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

-- Flag-off/flag-on coverage for the combined lookup-unwind path with a dotted
-- parent output path.
SELECT document
FROM bson_aggregation_pipeline(
    'exprdb',
    $pipeline$
    {
      "aggregate": "lookup_orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "lookup_items",
            "localField": "itemCode",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "lookup_suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "supplier"
                }
              }
            ],
            "as": "nested.items"
          }
        },
        {
          "$unwind": {
            "path": "$nested.items",
            "preserveNullAndEmptyArrays": true
          }
        }
      ]
    }
    $pipeline$
);

SET documentdb.force_nested_lookup_pipeline_after_join TO on;

-- SHOULD SUCCEED BUT SILENTLY RETURNS THE WRONG RESULT:
-- The dotted parent output path is lost when lookup and unwind are combined,
-- so the matched document is missing from the flag-on result.
SELECT document
FROM bson_aggregation_pipeline(
    'exprdb',
    $pipeline$
    {
      "aggregate": "lookup_orders",
      "pipeline": [
        { "$match": { "_id": 1 } },
        {
          "$lookup": {
            "from": "lookup_items",
            "localField": "itemCode",
            "foreignField": "code",
            "pipeline": [
              {
                "$lookup": {
                  "from": "lookup_suppliers",
                  "localField": "supplierCode",
                  "foreignField": "code",
                  "as": "supplier"
                }
              }
            ],
            "as": "nested.items"
          }
        },
        {
          "$unwind": {
            "path": "$nested.items",
            "preserveNullAndEmptyArrays": true
          }
        }
      ]
    }
    $pipeline$
);

RESET documentdb.force_nested_lookup_pipeline_after_join;

-- lookup with let
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('exprdb',
        '{ "aggregate": "exprcoll", "pipeline":[ { "$match": { "$expr": { "$gte": [ "$a", 10 ] } } }, { "$lookup": { "from": "exprcollright", "as": "res", "let": { "myvar": "$a" }, "pipeline": [ { "$match": { "$expr": { "$eq": [ "$a", "$$myvar" ] } } } ] } } ] }') $cmd$);

-- composite with partial $expr to the index
SELECT documentdb_api_internal.create_indexes_non_concurrently('exprdb', '{ "createIndexes": "exprcoll", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1, "d": 1 }, "name": "abcd_1", "enableOrderedIndex": true }] }', TRUE);

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb',
    '{ "find": "exprcoll", "filter": { "a": 5, "b": 5, "c": 5, "$expr": { "$and": [ { "$eq": [ "$f", "$g" ] }, { "$gt": [ "$d", 5 ] } ] } } }');


-- a scalar $expr argument carries no operator conditions to push down. These used to
-- fail the whole query with "expected a document or array to init iterator" as soon as
-- an eligible ordered index existed, while working fine without one.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": "$a" } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "a": 5, "$expr": "$a" } }');

-- field path: truthy for every document, missing path matches nothing
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": "$a" } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": "$missingPath" } }, { "$count": "n" } ] }');

-- constants of every scalar type
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": 1 } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": 0 } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": -1 } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": true } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": false } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": null } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": "literal" } }, { "$count": "n" } ] }');

-- an array argument is not pushed down either, only evaluated at runtime
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": [] } }, { "$count": "n" } ] }');
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "$expr": [ 1, 2 ] } }, { "$count": "n" } ] }');

-- the scalar argument must not disable pushdown of the sibling operators
SELECT document FROM bson_aggregation_pipeline('exprdb', '{ "aggregate": "exprcoll", "pipeline": [ { "$match": { "a": 5, "$expr": "$a" } }, { "$count": "n" } ] }');


-- after adding a row with arrays, can no longer push down (multikey expr not supported)
SELECT documentdb_api.insert_one('exprdb', 'exprcoll', '{ "_id": "array", "a": [ 1, 2, 3 ] }');

-- cannot push down any of these
set documentdb.forceDisableSeqScan to on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$eq": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$eq": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gt": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gt": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gte": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$gte": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lt": [ 10, "$a" ] } } }');

EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lte": [ "$a", 10 ] } } }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('exprdb', '{ "find": "exprcoll", "filter": { "$expr": { "$lte": [ 10, "$a" ] } } }');