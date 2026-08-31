SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb.next_collection_id TO 25801000;
SET documentdb.next_collection_index_id TO 25801000;

SELECT document
FROM bson_aggregation_find_and_modify(
	'db',
	'{ "findAndModify": "aggregation_find_and_modify", "query": {} }');

SELECT bson_aggregation_find_and_modify(
	'db',
	'{ "findAndModify": "aggregation_find_and_modify", "query": {} }');
