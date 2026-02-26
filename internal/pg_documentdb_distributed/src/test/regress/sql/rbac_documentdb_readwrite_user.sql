SET citus.next_shard_id TO 19841000;
SET documentdb.next_collection_id TO 1984100;
SET documentdb.next_collection_index_id TO 1984100;

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SHOW documentdb.enableRbacCompliantSchemas;

SELECT documentdb_api.create_user('{"createUser":"user_rw", "pwd":"Password@9", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}]}');

\c regression user_rw

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog;

-- Should not have access to the earlier API schemas
SELECT documentdb_api.create_collection('test', 'my_coll1');

SELECT documentdb_api_v2.create_collection('test', 'my_coll1');

-- Should not be able to drop database
SELECT documentdb_api_v2.drop_database('test');
      
SELECT documentdb_api_v2.drop_collection('test','my_coll1');

SELECT documentdb_api_v2.create_collection_view('db', '{ "create": "create_view_tests_not_capped1", "capped": false}');

SELECT * FROM documentdb_api_v2.create_indexes_background('db', '{"createIndexes": "collection_6", "indexes": [{"key": {"a$**foo": 1}, "name": "my_idx_1"}]}');

SELECT documentdb_api_internal_readwrite.create_indexes_non_concurrently('db', '{"createIndexes": "my_coll1", "indexes": [{"key": {"a": 1}, "name": "idx_1", "unique": true }]}', true);

SELECT documentdb_api_v2.insert('db', '{"insert":"into", "documents":[{"a":1}],"ordered":true}');

SELECT documentdb_api_v2.delete('db', '{"delete":"into","deletes":[{"q":{"a":1},"limit":1}],"ordered":true}');

SELECT documentdb_api_v2.rename_collection('db','my_coll1', 'my_coll1_renamed');

select 1 from documentdb_api_v2.insert_one('db', 'updateme', '{"a":1,"_id":1,"b":1}');

SELECT documentdb_api_v2.update(
  'db',
  '{"update":"updateme",
    "updates":[
      {"q":{"_id":1}, "u":{"$set":{"b":2}}, "multi":false, "upsert":false}
    ],
    "ordered":true}'
);

SELECT * FROM documentdb_api_v2.list_databases('{"listDatabases": 1, "nameOnly":true}');

select 1 from documentdb_api_v2.insert_one('bulkdb', 'updateme', '{"a":1,"_id":1,"b":1}');
select 1 from documentdb_api_v2.insert_one('bulkdb', 'updateme', '{"a":2,"_id":2,"b":2}');
select 1 from documentdb_api_v2.insert_one('bulkdb', 'updateme', '{"a":3,"_id":3,"b":3}');
CALL documentdb_api_v2.update_bulk('bulkdb', '{"update":"updateme", "updates":[{"q":{},"u":{"$set":{"b":0}},"multi":true}]}');

-- Count documents where b = 0 (should be 3)
SELECT document FROM documentdb_api_v2.count_query('bulkdb', '{ "count": "updateme", "query": { "b": 0 } }');

SELECT documentdb_api_v2.insert_one('db','aggregation_pipeline','{"_id":"1", "int": 10, "a" : { "b" : [ "x", 1, 2.0, true ] } }', NULL);
SELECT documentdb_api_v2.insert_one('db','aggregation_pipeline','{"_id":"2", "double": 2.0, "a" : { "b" : {"c": 3} } }', NULL);
SELECT documentdb_api_v2.insert_one('db','aggregation_pipeline','{"_id":"3", "boolean": false, "a" : "no", "b": "yes", "c": true }', NULL);

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "aggregation_pipeline", "pipeline": [ { "$addFields": { "newField" : "1", "a.y": ["p", "q"] } } ], "cursor": {} }');

SELECT document FROM documentdb_api_v2.count_query('db', '{ "count": "aggregation_pipeline", "query": { "_id": { "$gt": "1" } } }');

SELECT document FROM documentdb_api_v2.distinct_query('db', '{ "distinct": "aggregation_pipeline", "key": "_id" }');

SELECT documentdb_api_v2.db_stats('db');

SELECT 1 FROM documentdb_api_v2.insert_one('db', 'coll_to_update', '{"a": 10,"b":7}');
SELECT documentdb_api_v2.find_and_modify('db', '{"findAndModify": "coll_to_update", "query": {"a": 10}, "update": {"$set": {"a": 1000}}, "fields": {"_id": 0}, "new": true}');

SELECT documentdb_api_v2.create_collection('db','newColl');
SELECT COUNT(documentdb_api_v2.insert_one('db','newColl', FORMAT('{"_id":"%s", "a": %s }', i, i )::documentdb_core.bson)) FROM generate_series(1, 100) i;
SELECT documentdb_api_internal_readwrite.create_indexes_non_concurrently('db', '{"createIndexes": "newColl", "indexes": [{"key": {"a": 1}, "name": "my_idx_1" }]}', TRUE);

DO $$
DECLARE i int;
BEGIN
FOR i IN 1..10 LOOP
PERFORM documentdb_api_v2.insert_one('db', 'aggregation_cursor_txn', FORMAT('{ "_id": %s, "sk": %s, "a": "%s", "c": [ %s "d" ] }',  i, mod(i, 2), repeat('Sample', 10), repeat('"' || repeat('a', 10) || '", ', 5))::documentdb_core.bson);
END LOOP;
END;
$$;

SELECT documentdb_api_internal_readwrite.create_indexes_non_concurrently('db', '{"createIndexes": "aggregation_cursor_txn", "indexes": [{"key": {"a": 1}, "name": "a_1" }]}', TRUE);

CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    documentdb_api_v2.find_cursor_first_page(database => 'db', commandSpec => '{ "find": "aggregation_cursor_txn", "batchSize": 5 }', cursorId => 4294967294);

SELECT * FROM firstPageResponse;

-- now drain it
SELECT continuation AS r1_continuation FROM firstPageResponse \gset
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation FROM documentdb_api_v2.cursor_get_more(database => 'db', getMoreSpec => '{ "collection": "aggregation_cursor_txn", "getMore": 4294967294, "batchSize": 6 }', continuationSpec => :'r1_continuation');

SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid 
FROM documentdb_api_v2.aggregate_cursor_first_page(
    database => 'db', 
    commandSpec => '{ "aggregate": "aggregation_cursor_txn", "pipeline": [{ "$match": { "sk": 0 } }], "cursor": { "batchSize": 3 } }', 
    cursorId => 4294967295
);

SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') 
FROM documentdb_api_v2.list_indexes_cursor_first_page('db', '{ "listIndexes": "newColl" }') 
ORDER BY 1;

SELECT cursorpage, continuation, persistconnection, cursorid 
FROM documentdb_api_v2.list_collections_cursor_first_page('db', '{ "listCollections": 1, "nameOnly": true }');

SELECT documentdb_api_v2.insert_one('db', 'coll_agg_proj', '{ "_id": 1, "a": "cat" }');
SELECT documentdb_api_v2.insert_one('db', 'coll_agg_proj', '{ "_id": 2, "a": "dog" }');
SELECT documentdb_api_v2.insert_one('db', 'coll_agg_proj', '{ "_id": 3, "a": "cAt" }');
SELECT documentdb_api_v2.insert_one('db', 'coll_agg_proj', '{ "_id": 4, "a": "dOg" }');
SELECT documentdb_api_v2.insert_one('db', 'coll_agg_proj', '{ "_id": "hen", "a": "hen" }');
SELECT documentdb_api_v2.insert_one('db', 'coll_agg_proj', '{ "_id": "bat", "a": "bat" }');

SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$ne": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fi", "strength" : 1 } }');

SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 1, "a": { "b": 1, "c": 1} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 2, "a": { "b": 1, "c": 2} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 3, "a": { "b": 1, "c": 3} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 4, "a": { "b": 2, "c": 1} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 5, "a": { "b": 2, "c": 2} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 6, "a": { "b": 2, "c": 3} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 7, "a": { "b": 3, "c": 1} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 8, "a": { "b": 3, "c": 2} }', NULL);
SELECT documentdb_api_v2.insert_one('db','agg_facet_group','{ "_id": 9, "a": { "b": 3, "c": 3} }', NULL);

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } }, { "$facet": { "facet1" : [ { "$group": { "_id": "$a.b", "first": { "$first" : "$name" } } } ], "facet2" : [ { "$group": { "_id": "$a.b", "last": { "$last" : "$name" }}}]}} ] }');
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "agg_facet_group", "pipeline": [ { "$addFields": {"name": "$a.c"} }, { "$sort": { "a.b": 1, "name" : 1 } }, { "$facet": { "facet1" : [ { "$group": { "_id": "$a.b", "first": { "$first" : "$name" } } } ], "facet1" : [ { "$group": { "_id": "$a.b", "last": { "$last" : "$name" }}}]}} ] }');

SELECT * FROM bson_dollar_project('{"a":{"$numberDouble": "10.2"}}', '{"result": { "$multiply": [ "$a", 1]}}');

SELECT documentdb_api_v2.insert_one('db', 'graphlookup_places', '{ "_id" : 0, "placeCode" : "P1", "nearby" : [ "P2", "P3" ] }');
SELECT documentdb_api_v2.insert_one('db', 'graphlookup_places', '{ "_id" : 1, "placeCode" : "P2", "nearby" : [ "P1", "P4" ] }');
SELECT documentdb_api_v2.insert_one('db', 'graphlookup_places', '{ "_id" : 2, "placeCode" : "P3", "nearby" : [ "P1" ] }');
SELECT documentdb_api_v2.insert_one('db', 'graphlookup_places', '{ "_id" : 3, "placeCode" : "P4", "nearby" : [ "P2", "P5" ] }');
SELECT documentdb_api_v2.insert_one('db', 'graphlookup_places', '{ "_id" : 4, "placeCode" : "P5", "nearby" : [ "P4" ] }');

SELECT documentdb_api_v2.insert_one('db', 'graphlookup_visitors', '{ "_id" : 1, "userName" : "Sam", "homePlace" : "P1" }');
SELECT documentdb_api_v2.insert_one('db', 'graphlookup_visitors', '{ "_id" : 2, "userName" : "Alex", "homePlace" : "P1" }');
SELECT documentdb_api_v2.insert_one('db', 'graphlookup_visitors', '{ "_id" : 3, "userName" : "Jamie", "homePlace" : "P2" }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db',
    '{ "aggregate": "graphlookup_visitors", "pipeline": [ { "$graphLookup": { "from": "graphlookup_places", "startWith": "$homePlace", "connectFromField": "nearby", "connectToField": "placeCode", "as": "reachablePlaces", "maxDepth": 2 } } ]}');

SELECT * FROM bson_dollar_project('{}', '{"result": { "$in": [3, [1, 2, {"$add": [1, 1, 1]}]]}}');
SELECT * FROM bson_dollar_project('{}', '{"result": { "$in": [3, [1, 2, {"$add": [1, 1, 3]}]]}}');
SELECT * FROM bson_dollar_project('{"a": true, "b": [1, 2]}', '{"result": { "$in": ["$a", [1, 2, {"$isArray": "$b"}]]}}');
SELECT * FROM bson_dollar_project('{"a": {}}', '{"result": { "$in": [{"$literal": "$a"}, [1, 2, {"$literal": "$a"}]]}}');