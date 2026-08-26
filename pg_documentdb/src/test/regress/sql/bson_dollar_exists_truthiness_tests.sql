SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET citus.next_shard_id TO 25850000;
SET documentdb.next_collection_id TO 25850000;
SET documentdb.next_collection_index_id TO 25850000;

-- Regression coverage for the $exists operator argument coercion.
-- The $exists argument is coerced to a boolean using truthiness semantics
-- (false, 0, null and undefined are negative; every other value is positive),
-- it is NOT matched against the stored field value. Previously a null or
-- undefined argument fell through to the positive branch, so { $exists: null }
-- behaved like { $exists: true } instead of { $exists: false }.

SELECT documentdb_api.insert_one('existsdb', 'roles', '{ "_id": 1, "type": "USER_CLIENT" }');
SELECT documentdb_api.insert_one('existsdb', 'roles', '{ "_id": 2, "type": "USER_CLIENT", "company": null }');
SELECT documentdb_api.insert_one('existsdb', 'roles', '{ "_id": 3, "type": "USER_CLIENT", "company": "655c11f4d156cc5e6fd6a837" }');
SELECT documentdb_api.insert_one('existsdb', 'roles', '{ "_id": 4, "type": "USER_CLIENT", "company": "other_company" }');
SELECT documentdb_api.insert_one('existsdb', 'roles', '{ "_id": 5, "type": "USER_CLIENT" }');

-- $exists: true -> documents that contain the field (_id 2,3,4)
SELECT object_id FROM documentdb_api.collection('existsdb', 'roles') WHERE document @@ '{ "company": { "$exists": true } }' ORDER BY object_id;
-- $exists: false -> documents missing the field (_id 1,5)
SELECT object_id FROM documentdb_api.collection('existsdb', 'roles') WHERE document @@ '{ "company": { "$exists": false } }' ORDER BY object_id;

-- Falsy arguments must all behave like $exists: false (_id 1,5).
-- $exists: null
SELECT object_id FROM documentdb_api.collection('existsdb', 'roles') WHERE document @@ '{ "company": { "$exists": null } }' ORDER BY object_id;
-- $exists: 0
SELECT object_id FROM documentdb_api.collection('existsdb', 'roles') WHERE document @@ '{ "company": { "$exists": 0 } }' ORDER BY object_id;

-- Truthy non-boolean arguments must all behave like $exists: true (_id 2,3,4).
-- $exists: 1
SELECT object_id FROM documentdb_api.collection('existsdb', 'roles') WHERE document @@ '{ "company": { "$exists": 1 } }' ORDER BY object_id;
-- $exists: "yes"
SELECT object_id FROM documentdb_api.collection('existsdb', 'roles') WHERE document @@ '{ "company": { "$exists": "yes" } }' ORDER BY object_id;

-- Compound shape: $or combining $exists: null with an equality null on a missing field.
-- { company: null } matches both missing and null, so combined with the now
-- negative { $exists: null } the result is _id 1,2,5 (never the full set).
SELECT object_id FROM documentdb_api.collection('existsdb', 'roles') WHERE document @@ '{ "type": "USER_CLIENT", "$or": [ { "company": { "$exists": null } }, { "company": null } ] }' ORDER BY object_id;

SELECT documentdb_api.drop_collection('existsdb', 'roles');
