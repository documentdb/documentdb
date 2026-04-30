SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 198440000;
SET documentdb.next_collection_id TO 1984400;
SET documentdb.next_collection_index_id TO 1984400;

-- Insert test data
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('objid_support_db', 'test_support_func', FORMAT('{ "_id": %s, "a": %s }', g, g)::bson) FROM generate_series(1, 100) g) i;

-- Test 1: Direct invocation of the 3-argument UDFs to validate runtime results.
-- These are the object_id overloads (bson, bson, bsonquery) used for btree index pushdown.

-- bson_dollar_eq: should return true when _id matches
SELECT bson_dollar_eq('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 5 }');
-- bson_dollar_eq: should return false when _id does not match
SELECT bson_dollar_eq('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');

-- bson_dollar_gt: should return true when _id > value
SELECT bson_dollar_gt('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 5 }');
-- bson_dollar_gt: should return false when _id <= value
SELECT bson_dollar_gt('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');

-- bson_dollar_gte: should return true when _id >= value
SELECT bson_dollar_gte('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 10 }');
-- bson_dollar_gte: should return false when _id < value
SELECT bson_dollar_gte('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');

-- bson_dollar_lt: should return true when _id < value
SELECT bson_dollar_lt('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');
-- bson_dollar_lt: should return false when _id >= value
SELECT bson_dollar_lt('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 5 }');

-- bson_dollar_lte: should return true when _id <= value
SELECT bson_dollar_lte('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 10 }');
-- bson_dollar_lte: should return false when _id > value
SELECT bson_dollar_lte('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 5 }');

-- bson_dollar_in: should return true when _id is in the array
SELECT bson_dollar_in('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": [1, 5, 10] }');
-- bson_dollar_in: should return false when _id is not in the array
SELECT bson_dollar_in('{ "_id": 7, "a": 7 }', '{ "": 7 }', '{ "_id": [1, 5, 10] }');

-- Test 2: Verify runtime results and NOTICE from support function (btree _id index).
-- The support function emits a NOTICE when invoked during planning.
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 97 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gte(document, object_id, '{ "_id": 99 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lt(document, object_id, '{ "_id": 3 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lte(document, object_id, '{ "_id": 2 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');

-- Test 3: Verify the support function is invoked for the RUM index path.
-- Create a compound index on (a, _id) to trigger the RUM support function path.
SELECT documentdb_api_internal.create_indexes_non_concurrently('objid_support_db', '{ "createIndexes": "test_support_func", "indexes": [ { "key": { "a": 1, "_id": 1 }, "name": "idx_a_id" } ]}', true);

-- These queries should emit NOTICE for RUM path
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 97 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
