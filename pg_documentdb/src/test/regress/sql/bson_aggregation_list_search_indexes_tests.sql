SET search_path TO documentdb_api,documentdb_core;

SET documentdb.next_collection_id TO 66600;
SET documentdb.next_collection_index_id TO 66600;

-- Setup
SELECT documentdb_api.insert_one('listsearchindexes_db', 'test_coll', '{ "_id": 1, "a": "hello" }');

-- not enabled
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": {} } ] }');

-- not enabled
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "name": "idx1" } } ] }');

-- not enabled
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$match": {} }, { "$listSearchIndexes": {} } ] }');

-- not enabled
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": 1 } ] }');

SET documentdb.enableExtendedIndexes TO true;

-- not supported
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": {} } ] }');

-- not supported
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "name": "idx1" } } ] }');

-- $listSearchIndexes must be the first stage
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$match": {} }, { "$listSearchIndexes": {} } ] }');

-- $listSearchIndexes requires a document argument
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": 1 } ] }');

-- invalid filter field
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "invalid": 1 } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "name": "idx1", "invalid": 1 } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "name": "idx1", "id": 123 } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "id": "12345abc" } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "id": "-12345" } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "id": "12345.6" } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "id": "123456789101112" } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "id": "" } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "id": " 123" } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "name": 12345 } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "name": "" } } ] }' );
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('listsearchindexes_db', '{ "aggregate": "test_coll", "pipeline": [ { "$listSearchIndexes": { "name": {} } } ] }' );
