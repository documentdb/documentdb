SET search_path TO documentdb_core, documentdb_api, public;
SET documentdb.next_collection_id TO 9100;
SET documentdb.next_collection_index_id TO 9100;

-- create a collection in db1
SELECT documentdb_api.create_collection('list_metadata_db1', 'list_metadata_coll1');

UPDATE documentdb_api_catalog.collections SET collection_uuid = NULL WHERE database_name = 'list_metadata_db1';
SELECT cursorpage, continuation, persistconnection, cursorid  FROM documentdb_api.list_collections_cursor_first_page('list_metadata_db1', '{ "listCollections": 1, "nameOnly": true }');

-- create a sharded collection in db1
SELECT documentdb_api.create_collection('list_metadata_db1', 'list_metadata_coll2');
SELECT documentdb_api.shard_collection('list_metadata_db1', 'list_metadata_coll2', '{ "_id": "hashed" }', false);

-- create 2 collection in db2
SELECT documentdb_api.create_collection('list_metadata_db2', 'list_metadata_db2_coll1');
SELECT documentdb_api.create_collection('list_metadata_db2', 'list_metadata_db2_coll2');

-- create 2 views (one for db1 and one for db2)
SELECT documentdb_api.create_collection_view('list_metadata_db1', '{ "create": "list_metadata_view1_1", "viewOn": "list_metadata_coll1", "pipeline": [{ "$limit": 100 }] }');
SELECT documentdb_api.create_collection_view('list_metadata_db2', '{ "create": "list_metadata_view2_1", "viewOn": "list_metadata_coll2", "pipeline": [{ "$skip": 100 }] }');

-- reset collection_uuids
UPDATE documentdb_api_catalog.collections SET collection_uuid = NULL WHERE database_name = 'list_metadata_db1';
UPDATE documentdb_api_catalog.collections SET collection_uuid = NULL WHERE database_name = 'list_metadata_db2';

SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_collections_cursor_first_page('list_metadata_db1', '{ "listCollections": 1 }') ORDER BY 1;

SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_collections_cursor_first_page('list_metadata_db2', '{ "listCollections": 1, "nameOnly": true }') ORDER BY 1;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_collections_cursor_first_page('list_metadata_db2', '{ "listCollections": 1 }') ORDER BY 1;

SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_collections_cursor_first_page('list_metadata_db1', '{ "listCollections": 1, "filter": { "type": "view" } }') ORDER BY 1;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_collections_cursor_first_page('list_metadata_db1', '{ "listCollections": 1, "filter": { "info.readOnly": false } }') ORDER BY 1;

-- create some indexes for the collections in db1
SELECT documentdb_api_internal.create_indexes_non_concurrently('list_metadata_db1', '{ "createIndexes": "list_metadata_coll1", "indexes": [ { "key": { "a": 1 }, "name": "a_1" }, { "key": { "b.$**": 1 }, "name": "b_1"} ]}', TRUE);

SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('list_metadata_db1', '{ "listIndexes": "list_metadata_coll1" }') ORDER BY 1;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('list_metadata_db1', '{ "listIndexes": "list_metadata_coll2" }') ORDER BY 1;

-- fails
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('list_metadata_db1', '{ "listIndexes": "list_metadata_view1_1" }') ORDER BY 1;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('list_metadata_db1', '{ "listIndexes": "list_metadata_non_existent" }') ORDER BY 1;

-- List indexes with all four enableCompositeTerm / enableOrderedIndex states:
--   DefaultTrue : GUC defaultUseCompositeOpClass=on  + no  enableCompositeTerm → stored as 2
--   True        : explicit enableCompositeTerm=true                             → stored as 1
--   Undefined   : GUC defaultUseCompositeOpClass=off + no  enableCompositeTerm → not stored
--   False       : explicit enableCompositeTerm=false                            → stored as -1

-- DefaultTrue — GUC on, no explicit enableCompositeTerm
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('list_metadata_db1',
    '{ "createIndexes": "list_idx_opts", "indexes": [ { "key": { "d": 1 }, "name": "d_defaulttrue" } ] }', TRUE);
END;

-- True — explicit enableCompositeTerm: true
SELECT documentdb_api_internal.create_indexes_non_concurrently('list_metadata_db1',
    '{ "createIndexes": "list_idx_opts", "indexes": [ { "key": { "e": 1 }, "name": "e_true", "enableCompositeTerm": true } ] }', TRUE);

-- Undefined — GUC off, no explicit enableCompositeTerm
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('list_metadata_db1',
    '{ "createIndexes": "list_idx_opts", "indexes": [ { "key": { "f": 1 }, "name": "f_undefined" } ] }', TRUE);
END;

-- False — explicit enableCompositeTerm: false
SELECT documentdb_api_internal.create_indexes_non_concurrently('list_metadata_db1',
    '{ "createIndexes": "list_idx_opts", "indexes": [ { "key": { "g": 1 }, "name": "g_false", "enableCompositeTerm": false } ] }', TRUE);

-- List all indexes: DefaultTrue→true, True→true, Undefined→(no field), False→false
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch')
FROM documentdb_api.list_indexes_cursor_first_page('list_metadata_db1', '{ "listIndexes": "list_idx_opts" }')
ORDER BY 1;

-- emitEnableOrderedIndexFalseInResponse GUC test
-- GUC OFF: False index omits enableOrderedIndex entirely; all other behaviour unchanged
SET documentdb.emitEnableOrderedIndexFalseInResponse TO off;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch')
FROM documentdb_api.list_indexes_cursor_first_page('list_metadata_db1', '{ "listIndexes": "list_idx_opts" }')
ORDER BY 1;

-- Reset to default
SET documentdb.emitEnableOrderedIndexFalseInResponse TO on;