SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET citus.next_shard_id TO 25840000;
SET documentdb.next_collection_id TO 25840000;
SET documentdb.next_collection_index_id TO 25840000;

-- Regression coverage for $size applied to a sub-path nested inside $elemMatch.
-- Previously the value-variant of $size discarded the filter path, so it
-- evaluated the array size against the array element itself instead of the
-- nested field, returning wrong results for every requested size.

SELECT documentdb_api.insert_one('sizedb', 'size_elemmatch', '{ "_id": 1, "companyMetrics": [ { "metricConfigId": "M1", "companyIds": [ "a", "b", "c" ] } ] }');
SELECT documentdb_api.insert_one('sizedb', 'size_elemmatch', '{ "_id": 2, "companyMetrics": [ { "metricConfigId": "M2", "companyIds": [] } ] }');
SELECT documentdb_api.insert_one('sizedb', 'size_elemmatch', '{ "_id": 3, "companyMetrics": [ { "metricConfigId": "M3" } ] }');
SELECT documentdb_api.insert_one('sizedb', 'size_elemmatch', '{ "_id": 4, "companyMetrics": [ { "metricConfigId": "M4", "companyIds": [ "x" ] }, { "metricConfigId": "M5", "companyIds": [ "y", "z" ] } ] }');

-- $size on the nested companyIds field inside $elemMatch.
-- size 3 -> matches _id:1
SELECT object_id, document FROM documentdb_api.collection('sizedb', 'size_elemmatch') WHERE document @@ '{ "companyMetrics": { "$elemMatch": { "companyIds": { "$size": 3 } } } }' ORDER BY object_id;
-- size 0 -> matches _id:2 (empty array); must NOT match _id:3 (missing field)
SELECT object_id, document FROM documentdb_api.collection('sizedb', 'size_elemmatch') WHERE document @@ '{ "companyMetrics": { "$elemMatch": { "companyIds": { "$size": 0 } } } }' ORDER BY object_id;
-- size 2 -> matches _id:4 (its second element has 2 ids)
SELECT object_id, document FROM documentdb_api.collection('sizedb', 'size_elemmatch') WHERE document @@ '{ "companyMetrics": { "$elemMatch": { "companyIds": { "$size": 2 } } } }' ORDER BY object_id;
-- size 9 -> matches nothing
SELECT object_id, document FROM documentdb_api.collection('sizedb', 'size_elemmatch') WHERE document @@ '{ "companyMetrics": { "$elemMatch": { "companyIds": { "$size": 9 } } } }' ORDER BY object_id;

-- $size on the nested field combined with $or inside $elemMatch (original report shape).
SELECT object_id, document FROM documentdb_api.collection('sizedb', 'size_elemmatch') WHERE document @@ '{ "companyMetrics": { "$elemMatch": { "$or": [ { "companyIds": { "$size": 0 } }, { "companyIds": "a" } ] } } }' ORDER BY object_id;

-- Controls: $size via dot-path (no $elemMatch) must keep working.
SELECT object_id, document FROM documentdb_api.collection('sizedb', 'size_elemmatch') WHERE document @@ '{ "companyMetrics.companyIds": { "$size": 3 } }' ORDER BY object_id;
SELECT object_id, document FROM documentdb_api.collection('sizedb', 'size_elemmatch') WHERE document @@ '{ "companyMetrics.companyIds": { "$size": 0 } }' ORDER BY object_id;

SELECT documentdb_api.drop_collection('sizedb', 'size_elemmatch');
