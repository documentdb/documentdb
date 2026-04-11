SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET citus.next_shard_id TO 313000;
SET documentdb.next_collection_id TO 3130;
SET documentdb.next_collection_index_id TO 3130;

SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 1, "a": { "b": 1, "c": 1} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 2, "a": { "b": 1, "c": 2} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 3, "a": { "b": 1, "c": 3} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 4, "a": { "b": 2, "c": 1} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 5, "a": { "b": 2, "c": 2} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 6, "a": { "b": 2, "c": 3} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 7, "a": { "b": 3, "c": 1} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 8, "a": { "b": 3, "c": 2} }', NULL);
SELECT documentdb_api.insert_one('db','agg_facet_group','{ "_id": 9, "a": { "b": 3, "c": 3} }', NULL);

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } }, { "$facet": { "facet1" : [ { "$group": { "_id": "$a.b", "first": { "$first" : "$name" } } } ], "facet2" : [ { "$group": { "_id": "$a.b", "last": { "$last" : "$name" }}}]}} ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } }, { "$facet": { "facet1" : [ { "$group": { "_id": "$a.b", "first": { "$first" : "$name" } } } ], "facet1" : [ { "$group": { "_id": "$a.b", "last": { "$last" : "$name" }}}]}} ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT documentdb_api.shard_collection('db', 'agg_facet_group', '{ "_id": "hashed" }', false);

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } }, { "$facet": { "facet1" : [ { "$group": { "_id": "$a.b", "first": { "$first" : "$name" } } } ], "facet2" : [ { "$group": { "_id": "$a.b", "last": { "$last" : "$name" }}}]}} ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } }, { "$facet": { "facet1" : [ { "$group": { "_id": "$a.b", "first": { "$first" : "$name" } } } ], "facet1" : [ { "$group": { "_id": "$a.b", "last": { "$last" : "$name" }}}]}} ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

-- Sharded + non-constant _id: should use legacy path (read_intermediate_result present).
-- NOTE: This test is expected to change (has_legacy_subplan -> 'f') once we consume a
-- Citus version that correctly handles the inlined bson_repath_and_build target list
-- during distributed decomposition. At that point the forceGroupSubqueryElimination
-- guard can be removed and this assertion should flip to 'f'.
SELECT COUNT(*) > 0 AS has_legacy_subplan FROM
  documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$group": { "_id": "$a", "c": { "$count": {} }}}]}')$$) AS plan
WHERE plan LIKE '%intermediate_result%';

-- Sharded + constant _id: should use inline path (no intermediate_result)
SELECT COUNT(*) > 0 AS has_legacy_subplan FROM
  documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$group": { "_id": "1", "c": { "$count": {} }}}]}')$$) AS plan
WHERE plan LIKE '%intermediate_result%';

-- Force subquery elimination for sharded + non-constant _id (no intermediate_result)
SET documentdb.forceGroupSubqueryElimination TO on;
SELECT COUNT(*) > 0 AS has_legacy_subplan FROM
  documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$group": { "_id": "$a", "c": { "$count": {} }}}]}')$$) AS plan
WHERE plan LIKE '%intermediate_result%';

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$group": { "_id": "const", "c": { "$count": {} }}}]}');
SET documentdb.forceGroupSubqueryElimination TO off;
