SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb.next_collection_id TO 25800000;
SET documentdb.next_collection_index_id TO 25800000;

SELECT documentdb_api.create_collection('db', 'aggregation_update');
SELECT documentdb_api.insert_one(
	'db',
	'aggregation_update',
	'{ "_id": 1, "a": 1, "b": 0 }',
	NULL);

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [] }');

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 1 } }, "multi": true }, { "q": { "a": 2 }, "u": { "$set": { "b": 2 } }, "multi": true } ] }');

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 99 }, "u": { "$invalid": { "b": 1 } }, "multi": true } ] }');

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "b": 1 }, "multi": true } ] }');

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 1 } }, "multi": true, "sort": { "a": 1 } } ] }');

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$invalid": { "b": 1 } }, "multi": true, "sort": { "a": 1 } } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "b": 1 } }, "multi": false } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "_id": 1 }, "u": [ { "$set": { "b": 1 } } ], "multi": false } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 1 } }, "multi": false } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": [ { "$set": { "b": 1 } } ], "multi": false } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 1 } }, "multi": true } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": [ { "$set": { "b": 1 } } ], "multi": true } ] }');

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 1 } }, "multi": true } ] }');

SELECT document
FROM documentdb_api.collection('db', 'aggregation_update');

DO $$
BEGIN
	FOR document_id IN 2..1001 LOOP
		PERFORM documentdb_api.insert_one(
			'db',
			'aggregation_update',
			format('{ "_id": %s, "a": 2, "b": 0 }', document_id)::documentdb_core.bson,
			NULL);
	END LOOP;
END;
$$;

ANALYZE documentdb_data.documents_25800000;

SET enable_seqscan TO off;
SET enable_indexscan TO off;

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 2 } }, "multi": true } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 3 } }, "multi": false } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": [ { "$set": { "b": 3 } } ], "multi": false } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1, "b": 1 }, "u": { "$set": { "b": 3 } }, "multi": false } ] }');

SELECT document
FROM bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [ { "q": { "a": 1 }, "u": { "$set": { "b": 2 } }, "multi": true } ] }');

RESET enable_seqscan;
RESET enable_indexscan;

SELECT document
FROM documentdb_api.collection('db', 'aggregation_update')
WHERE document OPERATOR(documentdb_api_catalog.@=) '{ "_id": 1 }';

SELECT bson_aggregation_update(
	'db',
	'{ "update": "aggregation_update", "updates": [] }');
