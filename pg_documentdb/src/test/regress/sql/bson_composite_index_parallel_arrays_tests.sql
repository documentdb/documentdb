SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 25704000;
SET documentdb.next_collection_index_id TO 25704000;

-- helper for term generation
CREATE SCHEMA parallel_arrays_tests;
CREATE FUNCTION parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(documentdb_core.bson, text, int4, bool, p_wildcardIndex int4 = -1, p_reduced_correlated bool = TRUE)
    RETURNS SETOF documentdb_core.bson LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT AS '$libdir/pg_documentdb',
$$gin_bson_get_composite_path_generated_terms$$;

------------------------------------------------------------
-- Section 1: Term generation with parallel arrays (flag OFF - default)
-- When EnableFailureOnParallelIndexArrays is off (default),
-- parallel arrays should succeed and report feature usage.
------------------------------------------------------------

-- independent parallel arrays at top level: "a" and "b" are both arrays
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [1, 2], "b": [3, 4] }', '[ "a", "b" ]', 2000, false);

-- independent parallel arrays at nested paths
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "x": { "y": [1, 2] }, "p": { "q": [3, 4] } }', '[ "x.y", "p.q" ]', 2000, false);

-- parallel arrays with common parent but uncorrelated sibling paths
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": { "b": [1, 2], "c": [3, 4] } }', '[ "a.b", "a.c" ]', 2000, false);

-- 3-path composite with parallel arrays on two independent paths
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [1, 2], "b": [3, 4], "c": 5 }', '[ "a", "b", "c" ]', 2000, false);

-- non-parallel: only one path is an array
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [1, 2, 3], "b": 1 }', '[ "a", "b" ]', 2000, false);

SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": 1, "b": [1, 2, 3] }', '[ "a", "b" ]', 2000, false);

-- non-parallel: correlated arrays under common parent (elemMatch-style)
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [{ "b": 1, "c": 10 }, { "b": 2, "c": 20 }] }', '[ "a.b", "a.c" ]', 2000, false);

-- scalars only
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": 1, "b": 2 }', '[ "a", "b" ]', 2000, false);

------------------------------------------------------------
-- Section 2: Term generation with flag ON
-- Parallel arrays on uncorrelated paths should error.
-- Correlated arrays under common parent should succeed.
------------------------------------------------------------
SET documentdb.enableFailureOnParallelIndexArrays TO on;

-- independent parallel arrays at top level: should error
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [1, 2], "b": [3, 4] }', '[ "a", "b" ]', 2000, false);

-- independent parallel arrays at nested paths: should error
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "x": { "y": [1, 2] }, "p": { "q": [3, 4] } }', '[ "x.y", "p.q" ]', 2000, false);

-- parallel arrays with common parent but uncorrelated sibling paths: should error
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": { "b": [1, 2], "c": [3, 4] } }', '[ "a.b", "a.c" ]', 2000, false);

-- 3-path composite with parallel arrays: should error
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [1, 2], "b": [3, 4], "c": 5 }', '[ "a", "b", "c" ]', 2000, false);

-- single array + scalar: should succeed (not parallel arrays)
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [1, 2, 3], "b": 1 }', '[ "a", "b" ]', 2000, false);

SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": 1, "b": [1, 2, 3] }', '[ "a", "b" ]', 2000, false);

-- correlated arrays under common parent - should succeed (uses correlated path)
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [{ "b": 1, "c": 10 }, { "b": 2, "c": 20 }] }', '[ "a.b", "a.c" ]', 2000, false);

-- scalars only: should succeed (not parallel arrays)
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": 1, "b": 2 }', '[ "a", "b" ]', 2000, false);

-- single path composite: should succeed (no cross-path product)
SELECT * FROM parallel_arrays_tests.gin_bson_get_composite_path_generated_terms(
    '{ "a": [1, 2, 3] }', '[ "a" ]', 2000, false);

RESET documentdb.enableFailureOnParallelIndexArrays;

------------------------------------------------------------
-- Section 3: Insert with parallel arrays and composite index (flag OFF)
-- Inserts should succeed when flag is off (default).
------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('parr_db',
    '{ "createIndexes": "coll_noerr", "indexes": [{ "key": { "a": 1, "b": 1 }, "name": "ab_idx", "enableOrderedIndex": 1 }] }');

-- insert with parallel arrays - succeeds with flag off
SELECT documentdb_api.insert_one('parr_db', 'coll_noerr', '{ "_id": 1, "a": [1, 2], "b": [3, 4] }');

-- insert with single array
SELECT documentdb_api.insert_one('parr_db', 'coll_noerr', '{ "_id": 2, "a": [1, 2], "b": 5 }');
SELECT documentdb_api.insert_one('parr_db', 'coll_noerr', '{ "_id": 3, "a": 1, "b": [3, 4] }');

-- insert with scalars only
SELECT documentdb_api.insert_one('parr_db', 'coll_noerr', '{ "_id": 4, "a": 1, "b": 2 }');

-- verify all docs inserted
SELECT document FROM documentdb_api.collection('parr_db', 'coll_noerr') ORDER BY object_id;

------------------------------------------------------------
-- Section 4: Insert with parallel arrays and composite index (flag ON)
-- Inserts with parallel arrays should fail.
------------------------------------------------------------
SET documentdb.enableFailureOnParallelIndexArrays TO on;

SELECT documentdb_api_internal.create_indexes_non_concurrently('parr_db',
    '{ "createIndexes": "coll_err", "indexes": [{ "key": { "a": 1, "b": 1 }, "name": "ab_idx", "enableOrderedIndex": 1 }] }');

-- parallel arrays - should fail
SELECT documentdb_api.insert_one('parr_db', 'coll_err', '{ "_id": 1, "a": [1, 2], "b": [3, 4] }');

-- different types of parallel arrays - should fail
SELECT documentdb_api.insert_one('parr_db', 'coll_err', '{ "_id": 2, "a": [1, 2, 3], "b": [true, false] }');

-- verify no docs inserted
SELECT document FROM documentdb_api.collection('parr_db', 'coll_err') ORDER BY object_id;

------------------------------------------------------------
-- Section 5: Insert with nested composite index and parallel arrays (flag ON)
------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('parr_db',
    '{ "createIndexes": "coll_nested", "indexes": [{ "key": { "x.y": 1, "p.q": 1 }, "name": "xy_pq_idx", "enableOrderedIndex": 1 }] }');

-- parallel arrays at nested paths - should fail
SELECT documentdb_api.insert_one('parr_db', 'coll_nested', '{ "_id": 1, "x": { "y": [1, 2] }, "p": { "q": [3, 4] } }');

-- verify no docs inserted
SELECT document FROM documentdb_api.collection('parr_db', 'coll_nested') ORDER BY object_id;

------------------------------------------------------------
-- Section 6: Insert correlated arrays with flag ON - should succeed
-- Correlated arrays under common parent use the correlated term path.
------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('parr_db',
    '{ "createIndexes": "coll_correlated", "indexes": [{ "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac_idx", "enableOrderedIndex": 1 }] }');

-- correlated arrays under common parent "a" - should succeed
SELECT documentdb_api.insert_one('parr_db', 'coll_correlated', '{ "_id": 1, "a": [{ "b": 1, "c": 10 }, { "b": 2, "c": 20 }] }');
SELECT documentdb_api.insert_one('parr_db', 'coll_correlated', '{ "_id": 2, "a": [{ "b": 3, "c": 30 }] }');

-- verify correlated docs inserted
SELECT document FROM documentdb_api.collection('parr_db', 'coll_correlated') ORDER BY object_id;

RESET documentdb.enableFailureOnParallelIndexArrays;

-- cleanup
DROP SCHEMA parallel_arrays_tests CASCADE;
