-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- ============================================================================
-- Dynamic Cursor Table Change Tests
-- ============================================================================
--
-- A continuation names the table that the previous page read and a position
-- in it. A getMore plans the query again by collection name, so if the name
-- now refers to a different table, because the collection was dropped and
-- created again or another collection was renamed onto the name, the saved
-- position does not belong to the table being read. The getMore must end the
-- cursor instead of resuming there.
-- ============================================================================
SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 26000000;
SET documentdb.next_collection_index_id TO 26000000;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;

-- The documents of the collection a cursor starts on have "from": "first";
-- those of the collection that takes over its name have "from": "second".

-- 1. Another collection is renamed onto the name. The table in the
-- continuation still exists, under the collection's new name.
SELECT count(documentdb_api.insert_one('dyncur_table_db', 'renamed_over',
    FORMAT('{ "_id": %s, "from": "first" }', i)::bson)) FROM generate_series(1, 10) i;
SELECT count(documentdb_api.insert_one('dyncur_table_db', 'replacement',
    FORMAT('{ "_id": %s, "from": "second" }', i)::bson)) FROM generate_series(1, 10) i;
SELECT cursorpage AS page, continuation AS cont FROM find_cursor_first_page('dyncur_table_db',
    '{ "find": "renamed_over", "batchSize": 3 }', 26000001) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id", "from": "$cursor.firstBatch.from" }') AS page1,
       bson_dollar_project(:'cont'::bson, '{ "_id": 0, "dc.type": 1 }') AS scan_type;
SELECT documentdb_api.rename_collection('dyncur_table_db', 'renamed_over', 'renamed_away');
SELECT documentdb_api.rename_collection('dyncur_table_db', 'replacement', 'renamed_over');
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id", "from": "$cursor.nextBatch.from" }') AS page2
FROM cursor_get_more('dyncur_table_db',
    '{ "getMore": { "$numberLong": "26000001" }, "collection": "renamed_over", "batchSize": 3 }', :'cont');

-- 2. The collection is dropped and created again: the table in the
-- continuation no longer exists. A getMore before the drop resumes as usual.
SELECT count(documentdb_api.insert_one('dyncur_table_db', 'recreated',
    FORMAT('{ "_id": %s, "from": "first" }', i)::bson)) FROM generate_series(1, 10) i;
SELECT cursorpage AS page, continuation AS cont FROM find_cursor_first_page('dyncur_table_db',
    '{ "find": "recreated", "batchSize": 3 }', 26000002) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id", "from": "$cursor.firstBatch.from" }') AS page1,
       bson_dollar_project(:'cont'::bson, '{ "_id": 0, "dc.type": 1 }') AS scan_type;
SELECT cursorpage AS page, continuation AS cont FROM cursor_get_more('dyncur_table_db',
    '{ "getMore": { "$numberLong": "26000002" }, "collection": "recreated", "batchSize": 3 }', :'cont') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.nextBatch._id", "from": "$cursor.nextBatch.from" }') AS page2;
SELECT documentdb_api.drop_collection('dyncur_table_db', 'recreated');
SELECT count(documentdb_api.insert_one('dyncur_table_db', 'recreated',
    FORMAT('{ "_id": %s, "from": "second" }', i)::bson)) FROM generate_series(1, 10) i;
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id", "from": "$cursor.nextBatch.from" }') AS page3
FROM cursor_get_more('dyncur_table_db',
    '{ "getMore": { "$numberLong": "26000002" }, "collection": "recreated", "batchSize": 3 }', :'cont');

-- 3. The same with a scan in TID order, which resumes from the saved TID
-- without consulting any index.
SELECT count(documentdb_api.insert_one('dyncur_table_db', 'recreated_no_pk',
    FORMAT('{ "_id": %s, "from": "first" }', i)::bson)) FROM generate_series(1, 10) i;
SELECT documentdb_test_helpers.drop_primary_key('dyncur_table_db', 'recreated_no_pk');
SELECT cursorpage AS page, continuation AS cont FROM find_cursor_first_page('dyncur_table_db',
    '{ "find": "recreated_no_pk", "batchSize": 3 }', 26000003) \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.firstBatch._id", "from": "$cursor.firstBatch.from" }') AS page1,
       bson_dollar_project(:'cont'::bson, '{ "_id": 0, "dc.type": 1 }') AS scan_type;
SELECT cursorpage AS page, continuation AS cont FROM cursor_get_more('dyncur_table_db',
    '{ "getMore": { "$numberLong": "26000003" }, "collection": "recreated_no_pk", "batchSize": 3 }', :'cont') \gset
SELECT bson_dollar_project(:'page'::bson, '{ "_id": 0, "ids": "$cursor.nextBatch._id", "from": "$cursor.nextBatch.from" }') AS page2;
SELECT documentdb_api.drop_collection('dyncur_table_db', 'recreated_no_pk');
SELECT count(documentdb_api.insert_one('dyncur_table_db', 'recreated_no_pk',
    FORMAT('{ "_id": %s, "from": "second" }', i)::bson)) FROM generate_series(1, 10) i;
SELECT bson_dollar_project(cursorpage, '{ "_id": 0, "ids": "$cursor.nextBatch._id", "from": "$cursor.nextBatch.from" }') AS page3
FROM cursor_get_more('dyncur_table_db',
    '{ "getMore": { "$numberLong": "26000003" }, "collection": "recreated_no_pk", "batchSize": 3 }', :'cont');

SELECT documentdb_api.drop_database('dyncur_table_db');
