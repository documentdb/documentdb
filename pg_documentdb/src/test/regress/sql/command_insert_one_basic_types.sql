
SET search_path TO documentdb_api,documentdb_core;
SET documentdb.next_collection_id TO 1000;
SET documentdb.next_collection_index_id TO 1000;

-- insert int32
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"1", "value": { "$numberInt" : "11" }, "valueMax": { "$numberInt" : "2147483647" }, "valueMin": { "$numberInt" : "-2147483648" }}', NULL);

-- insert int64
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"2", "value":{"$numberLong" : "134311"}, "valueMax": { "$numberLong" : "9223372036854775807" }, "valueMin": { "$numberLong" : "-9223372036854775808" }}', NULL);

-- insert double
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"3", "value":{"$numberDouble" : "0"}, "valueMax": { "$numberDouble" : "1.7976931348623157E+308" }, "valueMin": { "$numberDouble" : "-1.7976931348623157E+308" }, "valueEpsilon": { "$numberDouble": "4.94065645841247E-324"}, "valueinfinity": {"$numberDouble":"Infinity"}}', NULL);

-- insert string
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"4", "value": "Bright stars illuminate the calm ocean during a peaceful night."}', NULL);

-- insert binary
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"5", "value": {"$binary": { "base64": "U29tZVRleHRUb0VuY29kZQ==", "subType": "02"}}}', NULL);

-- minKey/maxKey
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"6", "valueMin": { "$minKey": 1 }, "valueMax": { "$maxKey": 1 }}', NULL);

-- oid, date, time
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"7", "tsField": {"$timestamp":{"t":1565545664,"i":1}}, "dateBefore1970": {"$date":{"$numberLong":"-1577923200000"}}, "dateField": {"$date":{"$numberLong":"1565546054692"}}, "oidField": {"$oid":"5d505646cf6d4fe581014ab2"}}', NULL);

-- array & nested object
SELECT documentdb_api.insert_one('db','bsontypetests','{"_id":"8", "arrayOfObject": [{ "こんにちは": "ありがとう" }, { "¿Cómo estás?": "Muy bien!" }, { "Что ты делал на этой неделе?": "Ничего" }]}', NULL);

-- fetch all rows
SELECT shard_key_value, object_id, document FROM documentdb_data.documents_1001 ORDER BY 1,2,3;

-- project two fields out.
SELECT document->'_id', document->'value' FROM documentdb_data.documents_1001 ORDER BY object_id;

-- insert document with $ or . in the field path
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 9, "$field": 1}');
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 10, "field": { "$subField": 1 } }');
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 11, "field": [ { "$subField": 1 } ] }');
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 12, ".field": 1}');
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 13, "fie.ld": 1}');
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 14, "field": { ".subField": 1 } }');
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 15, "field": { "sub.Field": 1 } }');
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": 16, "field": [ { "sub.Field": 1 } ] }');

/* Test to validate that _id field cannot have regex as it's value */
select documentdb_api.insert_one('db', 'bsontypetests', '{"_id": {"$regex": "^A", "$options": ""}}');

/* Test _id cannot have nested paths with $ */
SELECT documentdb_api.insert_one('db', 'bsontypetests', '{ "_id": { "a": 2, "$c": 3 } }');

/* Test to validate that _id field cannot have array as it's value */
select documentdb_api.insert_one('db', 'bsontypetests', '{"_id": [1]}');

-- assert object_id matches the '_id' from the content - should be numRows.
SELECT COUNT(*) FROM documentdb_data.documents_1001 where object_id::bson = bson_get_value(document, '_id');

-- Test empty timestamp replacement
CREATE OR REPLACE FUNCTION test_insert_empty_timestamp() RETURNS text AS $$
DECLARE
    doc bson;
    v_collection_id bigint;
    v_data_table_name text;
    v_query text;
BEGIN
    PERFORM documentdb_api.insert_one('db', 'testTsEmpty', '{"_id": 1, "k": {"$timestamp": {"t":0, "i":0}}}');
    
    SELECT collection_id INTO v_collection_id
    FROM documentdb_api_catalog.collections
    WHERE collection_name = 'testTsEmpty' AND database_name = 'db';
    
    v_data_table_name := format('documentdb_data.documents_%s', v_collection_id);
    v_query := format('SELECT document FROM %s WHERE object_id OPERATOR(documentdb_core.=) ''{"": 1}''::documentdb_core.bson', v_data_table_name);
    EXECUTE v_query INTO doc;
    
    IF (doc::text) LIKE '%"$timestamp" : { "t" : 0, "i" : 0 }%' THEN
        RETURN 'FAIL: Timestamp was not replaced. Doc: ' || doc::text;
    END IF;
    
    RETURN 'SUCCESS';
END;
$$ LANGUAGE plpgsql;

SELECT test_insert_empty_timestamp();

-- Test populated timestamp is NOT replaced
CREATE OR REPLACE FUNCTION test_insert_populated_timestamp() RETURNS text AS $$
DECLARE
    doc bson;
    v_collection_id bigint;
    v_data_table_name text;
    v_query text;
BEGIN
    PERFORM documentdb_api.insert_one('db', 'testTsPopulated', '{"_id": 1, "k": {"$timestamp": {"t":1, "i":0}}}');
    
    SELECT collection_id INTO v_collection_id
    FROM documentdb_api_catalog.collections
    WHERE collection_name = 'testTsPopulated' AND database_name = 'db';
    
    v_data_table_name := format('documentdb_data.documents_%s', v_collection_id);
    v_query := format('SELECT document FROM %s WHERE object_id OPERATOR(documentdb_core.=) ''{"": 1}''::documentdb_core.bson', v_data_table_name);
    EXECUTE v_query INTO doc;
    
    IF (doc::text) LIKE '%"$timestamp" : { "t" : 1, "i" : 0 }%' THEN
        RETURN 'SUCCESS';
    END IF;
    
    RETURN 'FAIL: Timestamp was replaced or missing. Doc: ' || doc::text;
END;
$$ LANGUAGE plpgsql;

SELECT test_insert_populated_timestamp();
