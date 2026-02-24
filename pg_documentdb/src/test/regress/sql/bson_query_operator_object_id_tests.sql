
SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET citus.next_shard_id TO 860000;
SET documentdb.next_collection_id TO 8600;
SET documentdb.next_collection_index_id TO 8600;


SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('objectIdTestDb', 'test_object_id_index', FORMAT('{ "_id": %s, "a": %s, "otherField": "aaaa" }', g, g)::bson) FROM generate_series(1, 10000) g) i;

EXPLAIN (COSTS ON) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": 15 }';
EXPLAIN (COSTS ON) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$in": [ 15, 55, 90 ] } }';
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$gt": 50 } }' $cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$gt": 50, "$lt": 60 } }' $cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$gte": 50, "$lte": 60 } }' $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "$and": [ {"_id": 15 }, { "_id": 16 } ] }' $cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "$and": [ {"_id": { "$in": [ 15, 16, 17] }}, { "_id": { "$in": [ 16, 17, 18 ] } } ] }' $cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "$and": [ {"_id": { "$gt": 50 } }, { "_id": { "$lt": 60 } } ] }' $cmd$);

-- create a scenario where there's an alternate filter and that can be matched in the RUM index.
SELECT documentdb_api_internal.create_indexes_non_concurrently('objectIdTestDb', '{ "createIndexes": "test_object_id_index", "indexes": [ { "key": { "otherField": 1 }, "name": "idx_1" } ]}', true);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$in": [ 15, 20 ] }, "otherField": "aaaa" }' $cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$in": [ 15 ] }, "otherField": "aaaa" }' $cmd$);

-- we shouldn't have object_id filters unless we also have shard key filters
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": 15 }' $cmd$);

BEGIN;
SET LOCAL documentdb.ForceUseIndexIfAvailable to OFF;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$in": [ 15, 55, 90 ] } }' $cmd$);
ROLLBACK;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": 15, "a": 15 }' $cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": 15, "a": { "$gt": 15 } }' $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM documentdb_api.collection('objectIdTestDb', 'test_object_id_index') WHERE document @@ '{ "_id": { "$in": [ 15, 20 ] }, "otherField": "aaaa" }' $cmd$);

-- Run with multiple object_id filters in the query
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('objectIdTestDb', '{ "find": "test_object_id_index",  "filter": { "$and": [ { "$or": [ { "_id": { "$in": [15, 16, 17] } } ] } ], "otherField": {"$ne": "bbb"}, "_id": 15 }, "limit": 1 }') $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('objectIdTestDb', '{ "find": "test_object_id_index",  "filter": { "$and": [ { "$or": [ { "_id": { "$in": [15, 16, 17] } } ] } ], "otherField": {"$ne": "bbb"}, "$or": [ { "_id": 15 }, { "_id": 16 } ] }, "limit": 1 }') $cmd$);
