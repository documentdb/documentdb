SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 29300;
SET documentdb.next_collection_index_id TO 29300;

SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableFailureOnParallelIndexArrays TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_mkp_db',
    '{"createIndexes":"docs","indexes":[{"key":{"a.b":1,"a.c":1},"name":"ab_ac_idx","enableOrderedIndex":1}]}',
    true);

-- Independent leaf arrays are parallel and fail by default on an MKP index.
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'docs',
    '{"_id":1,"a":{"b":[1,2],"c":[3,4]}}');

-- Correlated paths under one shared array remain valid.
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'docs',
    '{"_id":2,"a":[{"b":1,"c":10},{"b":2,"c":20}]}');

-- The scoped GUC provides an emergency opt-out for metadata-backed indexes.
SET documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking TO off;
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'docs',
    '{"_id":3,"a":{"b":[1,2],"c":[3,4]}}');
RESET documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking;

SELECT document
FROM documentdb_api.collection('parallel_mkp_db', 'docs')
ORDER BY object_id;

SELECT documentdb_api.drop_collection('parallel_mkp_db', 'docs');
