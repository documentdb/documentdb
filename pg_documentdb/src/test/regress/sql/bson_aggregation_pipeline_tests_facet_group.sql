SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core;

SET documentdb.next_collection_id TO 4000;
SET documentdb.next_collection_index_id TO 4000;

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

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT documentdb_api.shard_collection('db', 'agg_facet_group', '{ "_id": "hashed" }', false);

-- $documents is a collectionless source stage and cannot appear inside a $facet sub-pipeline; reject at parse time.
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$documents": [ { "x": 1 } ] } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$lookup": { "from": "_facet_test_foreign", "let": {}, "pipeline": [ { "$indexStats": {} } ], "as": "j" } } ], "total": [ { "$count": "n" } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$unionWith": { "coll": "agg_facet_group", "pipeline": [ { "$indexStats": {} } ] } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$match": { "_id": "never" } }, { "$facet": { "a": [ { "$lookup": { "from": "_facet_test_foreign", "pipeline": [ { "$unionWith": { "coll": "agg_facet_group", "pipeline": [ { "$indexStats": {} } ] } } ], "as": "j" } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$lookup": { "from": "_facet_test_foreign", "let": {}, "pipeline": [ { "$collStats": {} } ], "as": "j" } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$lookup": { "from": "_facet_test_foreign", "let": {}, "pipeline": [ { "$geoNear": { "near": { "type": "Point", "coordinates": [0, 0] }, "distanceField": "d", "spherical": true } } ], "as": "j" } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$lookup": { "from": "_facet_test_foreign", "let": {}, "pipeline": [ { "$planCacheStats": {} } ], "as": "j" } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$lookup": { "from": "_facet_test_foreign", "let": {}, "pipeline": [ { "$facet": { "b": [ { "$match": {} } ] } } ], "as": "j" } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$unionWith": { "coll": "agg_facet_group", "pipeline": [ { "$facet": { "b": [ { "$count": "n" } ] } } ] } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$lookup": { "from": "_facet_test_foreign", "pipeline": [ 1, { "$indexStats": {} } ], "as": "j" } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$unionWith": { "coll": "agg_facet_group", "pipeline": [ { "$match": {}, "$indexStats": {} } ] } } ] } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$match": { "_id": 1 } }, { "$facet": { "a": [ { "$project": { "_id": 0, "value": { "$literal": { "$unionWith": { "pipeline": [ { "$indexStats": {} } ] } } } } } ] } } ] }');

-- $documents remains valid inside a nested collectionless $unionWith pipeline.
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$facet": { "a": [ { "$match": { "_id": "never" } }, { "$unionWith": { "pipeline": [ { "$documents": [ { "x": 1 } ] } ] } } ] } } ] }');

CREATE FUNCTION pg_temp.facet_pipeline_sqlstate(pipeline jsonb)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
	EXECUTE format('SELECT document FROM bson_aggregation_pipeline(''db'', %L::bson)',
		jsonb_build_object('aggregate', 'agg_facet_group', 'pipeline', pipeline)::text);
	RETURN '00000';
EXCEPTION WHEN OTHERS THEN
	RETURN SQLSTATE;
END;
$$;

WITH stages(stage_name, stage_spec) AS (
	VALUES ('$collStats', '{}'::jsonb),
		   ('$facet', '{"b": [{"$match": {}}]}'::jsonb),
		   ('$geoNear', '{"near": {"type": "Point", "coordinates": [0, 0]}, "distanceField": "d", "spherical": true}'::jsonb),
		   ('$indexStats', '{}'::jsonb),
		   ('$planCacheStats', '{}'::jsonb)
), pipelines AS (
	SELECT stage_name, jsonb_build_array(jsonb_build_object(stage_name, stage_spec)) AS pipeline
	FROM stages
), nested AS (
	SELECT stage_name, pipeline,
		   jsonb_build_array(jsonb_build_object('$lookup', jsonb_build_object(
			   'from', '_facet_test_foreign', 'let', '{}'::jsonb, 'pipeline', pipeline, 'as', 'j'))) AS lookup_pipeline,
		   jsonb_build_array(jsonb_build_object('$unionWith', jsonb_build_object(
			   'coll', 'agg_facet_group', 'pipeline', pipeline))) AS union_pipeline
	FROM pipelines
)
SELECT stage_name,
	   pg_temp.facet_pipeline_sqlstate(jsonb_build_array(jsonb_build_object(
		   '$facet', jsonb_build_object('a', pipeline)))) AS direct,
	   pg_temp.facet_pipeline_sqlstate(jsonb_build_array(jsonb_build_object(
		   '$facet', jsonb_build_object('a', lookup_pipeline)))) AS lookup,
	   pg_temp.facet_pipeline_sqlstate(jsonb_build_array(jsonb_build_object(
		   '$facet', jsonb_build_object('a', union_pipeline)))) AS union_with,
	   pg_temp.facet_pipeline_sqlstate(jsonb_build_array(jsonb_build_object(
		   '$facet', jsonb_build_object('a', jsonb_build_array(jsonb_build_object(
			   '$lookup', jsonb_build_object('from', '_facet_test_foreign', 'as', 'j',
				   'pipeline', union_pipeline))))))) AS lookup_union,
	   pg_temp.facet_pipeline_sqlstate(jsonb_build_array(jsonb_build_object(
		   '$facet', jsonb_build_object('a', jsonb_build_array(jsonb_build_object(
			   '$unionWith', jsonb_build_object('coll', 'agg_facet_group',
				   'pipeline', lookup_pipeline))))))) AS union_lookup
FROM nested ORDER BY stage_name;

WITH stages(stage_name, stage_spec) AS (
	VALUES ('$changeStream', '{}'::jsonb),
		   ('$merge', '{"into": "facet_rule_output"}'::jsonb),
		   ('$out', '"facet_rule_output"'::jsonb)
), pipelines AS (
	SELECT stage_name, jsonb_build_array(jsonb_build_object(stage_name, stage_spec)) AS pipeline
	FROM stages
), variants AS (
	SELECT stage_name, variant_name, variants.pipeline
	FROM pipelines CROSS JOIN LATERAL (
		VALUES ('alone', pipelines.pipeline),
			   ('before_facet_rule', pipelines.pipeline || '[{"$indexStats": {}}]'::jsonb),
			   ('after_facet_rule', '[{"$indexStats": {}}]'::jsonb || pipelines.pipeline)
	) AS variants(variant_name, pipeline)
)
SELECT stage_name, variant_name,
	   pg_temp.facet_pipeline_sqlstate(jsonb_build_array(jsonb_build_object(
		   '$facet', jsonb_build_object('a', jsonb_build_array(jsonb_build_object(
			   '$lookup', jsonb_build_object('from', '_facet_test_foreign', 'let', '{}'::jsonb,
				   'pipeline', pipeline, 'as', 'j'))))))) AS lookup,
	   pg_temp.facet_pipeline_sqlstate(jsonb_build_array(jsonb_build_object(
		   '$facet', jsonb_build_object('a', jsonb_build_array(jsonb_build_object(
			   '$unionWith', jsonb_build_object('coll', 'agg_facet_group',
				   'pipeline', pipeline))))))) AS union_with
FROM variants ORDER BY stage_name, variant_name;

SELECT pg_temp.facet_pipeline_sqlstate('[{"$facet": {"a": [{"$out": "facet_rule_output"}]}}]') AS direct_out,
	   pg_temp.facet_pipeline_sqlstate('[{"$facet": {"a": [{"$merge": {"into": "facet_rule_output"}}]}}]') AS direct_merge,
	   pg_temp.facet_pipeline_sqlstate('[{"$facet": {"a": [{"$changeStream": {}}]}}]') AS direct_change_stream,
	   pg_temp.facet_pipeline_sqlstate('[{"$facet": {"a": [{"$search": {}}]}}]') AS direct_search;

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$match": { "_id": 1 } }, { "$facet": { "a": [ { "$lookup": { "pipeline": [ { "$documents": [ { "x": 1 } ] } ], "as": "j" } }, { "$project": { "_id": 0, "j": 1 } } ] } } ] }');

SELECT pg_temp.facet_pipeline_sqlstate('[{"$match": {"_id": 1}}, {"$lookup": {"from": "_facet_test_foreign", "pipeline": [{"$facet": {"a": [{"$count": "n"}]}}], "as": "j"}}]') AS facet_without_facet_ancestor;

DROP FUNCTION pg_temp.facet_pipeline_sqlstate(jsonb);

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } }, { "$facet": { "facet1" : [ { "$group": { "_id": "$a.b", "first": { "$first" : "$name" } } } ], "facet2" : [ { "$group": { "_id": "$a.b", "last": { "$last" : "$name" }}}]}} ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : 1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": -1, "name" : -1 } },  { "$group": { "_id": "$a.b", "first": { "$first" : "$name" }, "last": { "$last": "$name" } } } ] }');
