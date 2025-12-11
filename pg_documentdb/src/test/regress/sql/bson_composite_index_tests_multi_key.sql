SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 500;
SET documentdb.next_collection_index_id TO 500;

CREATE SCHEMA multi_key_tests;
CREATE FUNCTION multi_key_tests.gin_bson_get_composite_path_generated_terms(documentdb_core.bson, text, int4, bool)
    RETURNS SETOF documentdb_core.bson LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT AS '$libdir/pg_documentdb',
$$gin_bson_get_composite_path_generated_terms$$;

-- this should only generate 2 index keys since the multi-key is on the parent of the index path (/a/b/1, /a/c/1) and (/a/b/2, /a/c/2)
-- todo: this is inefficient.
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": 1, "c": 1 }, { "b": 2, "c": 2 }] }', '[ "a.b", "a.c" ]', 2000, false);

-- this should generate 2 index keys (/a/b/1, /a/c/1) and (/a/b/2, /a/c/1)
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": { "b": [ 1, 2 ], "c": 1 } }', '[ "a.b", "a.c" ]', 2000, false);

-- this should generate 2 index keys (/a/b/1, /a/c/1) and (/a/b/1, /a/c/2)
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": { "b": 1, "c": [ 1, 2 ] } }', '[ "a.b", "a.c" ]', 2000, false);

-- this should generate 4 keys:  (/a/b/1, /a/c/1),  (/a/b/2, /a/c/1),  (/a/b/3, /a/c/4),  (/a/b/4, /a/c/4)
-- todo: this is inefficient.
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": [ 1, 2 ], "c": 1 }, { "b": [ 3, 4 ], "c": 4 } ] }', '[ "a.b", "a.c" ]', 2000, false);

-- this should generate 4 keys:  (/a/b/1, /a/c/1),  (/a/b/1, /a/c/2),  (/a/b/4, /a/c/3),  (/a/b/4, /a/c/4)
-- todo: this is inefficient.
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": 1, "c": [ 1, 2 ] }, { "b": 4, "c": [ 3, 4 ] } ] }', '[ "a.b", "a.c" ]', 2000, false);

-- todo: should these error out
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": { "b": [ 1, 2 ], "c": [ 1, 2 ] } }', '[ "a.b", "a.c" ]', 2000, false);
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": [ 1, 2 ], "c": [1, 2] }, { "b": 3, "c": [ 3, 4 ] } ] }', '[ "a.b", "a.c" ]', 2000, false);

-- this works and generates 4 terms  (/a/b/1, /a/c/1),  (/a/b/1, /a/c/2),  (/a/b/3, /a/c/3),  (/a/b/3, /a/c/4)
-- todo: this is inefficient.
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": [ 1, 2 ], "c": 1 }, { "b": 3, "c": [ 3, 4 ] } ] }', '[ "a.b", "a.c" ]', 2000, false);

-- term generation with independent parent paths:
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": { "b": 1 }, "c": { "d": 2 } }', '[ "a.b", "c.d" ]', 2000, false);

-- generates 2 terms (/a/b/1, /c/d/2), (/a/b/2, /c/d/2)
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": { "b": [ 1, 2 ] }, "c": { "d": 2 } }', '[ "a.b", "c.d" ]', 2000, false);

-- generates 4 terms
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": [ 1, 2 ] }, { "b": [ 3, 4 ] } ], "c": { "d": 2 } }', '[ "a.b", "c.d" ]', 2000, false);
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": { "b": 2 }, "c": { "d": [ 2, 3 ] } }', '[ "a.b", "c.d" ]', 2000, false);
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": { "b": 2 }, "c": [ { "d": [ 2, 3 ] }, { "d": [ 4, 5 ] } ] }', '[ "a.b", "c.d" ]', 2000, false);

-- todo: should these error out 
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": [ 1, 2 ] }, { "b": [ 3, 4 ] } ], "c": { "d": [ 2, 3 ] } }', '[ "a.b", "c.d" ]', 2000, false);
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": [ 1, 2 ] }, { "b": [ 3, 4 ] } ], "c": [ { "d": 2 }, { "d": 3 } ] }', '[ "a.b", "c.d" ]', 2000, false);

-- when one path has some terms and another doesn't generates the right type of null terms.
-- here a.b has "some paths" existing, and "a.c" has none
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": 2 }, { "d": 2 } ] }', '[ "a.b", "a.c" ]', 2000, false);
SELECT * FROM multi_key_tests.gin_bson_get_composite_path_generated_terms('{ "a": [ { "b": 2 }, { "d": 2, "c": 5 } ] }', '[ "a.b", "a.c" ]', 2000, false);

-- now test query path pushdown
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkey_db', '{ "createIndexes": "mkey_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }');

-- multikey path on "a" - query on a.c can't be pushed
SELECT documentdb_api.insert_one('mkey_db', 'mkey_coll', '{ "_id": 1, "a": [ { "b": 1, "c": 1 }, { "b": 2, "c": 2 }] }');

set documentdb.enableExtendedExplainPlans to on;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkey_db', '{ "find": "mkey_coll", "filter": { "a.b": { "$gt": 0 }, "a.c": 2 }}') $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkey_db', '{ "find": "mkey_coll", "filter": { "a.b": 1, "a.c": 2 }}') $cmd$);

-- multikey on a.b - query on a.c can be pushed
TRUNCATE documentdb_data.documents_501;

SELECT documentdb_api.insert_one('mkey_db', 'mkey_coll', '{ "_id": 1, "a": { "b": [ 1, 2 ], "c": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkey_db', '{ "find": "mkey_coll", "filter": { "a.b": { "$gt": 0 }, "a.c": 2 }}') $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkey_db', '{ "find": "mkey_coll", "filter": { "a.b": 1, "a.c": 2 }}') $cmd$);
