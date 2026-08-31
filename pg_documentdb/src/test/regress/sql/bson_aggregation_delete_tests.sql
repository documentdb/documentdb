SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb.next_collection_id TO 25802000;
SET documentdb.next_collection_index_id TO 25802000;

SELECT documentdb_api.create_collection('db', 'aggregation_delete');
SELECT documentdb_api.insert_one(
	'db',
	'aggregation_delete',
	'{ "_id": 1, "a": 1, "b": 0 }',
	NULL);
SELECT documentdb_api.insert_one(
	'db',
	'aggregation_delete',
	'{ "_id": 2, "a": 1, "b": 1 }',
	NULL);

SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [] }');

SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "a": 1 }, "limit": 0 }, { "q": { "a": 2 }, "limit": 0 } ] }');

SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "missing_collection", "deletes": [ { "q": { "a": 1 }, "limit": 0 } ] }');

SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "missing_collection", "deletes": [ { "q": { "a": { "$invalid": 1 } }, "limit": 0 } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "a": 1 }, "limit": 0 } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "_id": 1 }, "limit": 1 } ] }');

DO $$
BEGIN
	FOR document_id IN 3..102 LOOP
		PERFORM documentdb_api.insert_one(
			'db',
			'aggregation_delete',
			format('{ "_id": %s, "a": 2, "b": 0 }', document_id)::documentdb_core.bson,
			NULL);
	END LOOP;
END;
$$;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
	'db',
	'{ "createIndexes": "aggregation_delete", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }',
	true);

SET enable_seqscan TO off;
SET enable_indexscan TO off;

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "a": 1 }, "limit": 0 } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "a": 1 }, "limit": 1 } ] }');

RESET enable_seqscan;
RESET enable_indexscan;

SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "a": 1 }, "limit": 1 } ] }');

SELECT COUNT(*)
FROM documentdb_api.collection('db', 'aggregation_delete')
WHERE document OPERATOR(documentdb_api_catalog.@=) '{ "a": 1 }';

SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "a": 1 }, "limit": 0 } ] }');

SELECT COUNT(*)
FROM documentdb_api.collection('db', 'aggregation_delete')
WHERE document OPERATOR(documentdb_api_catalog.@=) '{ "a": 1 }';

SELECT document
FROM bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [ { "q": { "a": 99 }, "limit": 0 } ] }');

SELECT bson_aggregation_delete(
	'db',
	'{ "delete": "aggregation_delete", "deletes": [] }');
