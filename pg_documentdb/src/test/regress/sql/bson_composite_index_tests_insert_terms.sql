SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 5600;
SET documentdb.next_collection_index_id TO 5600;


CREATE OR REPLACE FUNCTION documentdb_test_helpers.gin_bson_get_composite_path_generated_terms(document documentdb_core.bson, pathSpec text, termLimit int4, addMetadata bool, wildcardIndex int4 = -1)
    RETURNS SETOF documentdb_core.bson LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT AS '$libdir/pg_documentdb',
$$gin_bson_get_composite_path_generated_terms$$;

CREATE SCHEMA IF NOT EXISTS composite_terms_metadata;
CREATE FUNCTION composite_terms_metadata.gin_bson_get_composite_path_generated_terms(
    documentdb_core.bson, text, int4, bool, p_wildcardIndex int4 = -1,
    p_reduced_correlated bool = false, p_enable_global_term_metadata bool = false)
    RETURNS SETOF documentdb_core.bson LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT AS '$libdir/pg_documentdb',
$$gin_bson_get_composite_path_generated_terms$$;

-- test scenarios of term generation for composite path
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": 1, "b": 2 }', '[ "a", "b" ]', 2000, false);
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": [ 1, 2, 3 ], "b": 2 }', '[ "a", "b" ]', 2000, false);
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": 1, "b": [ true, false ] }', '[ "a", "b" ]', 2000, false);
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": [ 1, 2, 3 ], "b": [ true, false ] }', '[ "a", "b" ]', 2000, false);

-- test when one doesn't exist
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "b": [ true, false ] }', '[ "a", "b" ]', 2000, false);
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": [ 1, 2, 3 ] }', '[ "a", "b" ]', 2000, false);

-- a is a shared array ancestor, so every indexed descendant is multi-key even
-- when a.z is absent. The term blob metadata notice includes the overall
-- multi-key bit and all three path bits: 0b1111 = 15.
SELECT * FROM composite_terms_metadata.gin_bson_get_composite_path_generated_terms(
    '{ "a": [ { "x": 1, "y": 2 } ] }',
    '[ "a.x", "a.y", "a.z" ]',
    2000, true, -1, false, true);

-- test when one gets truncated (a has 29 letters, truncation limit is 50 /2 so 25 per path)
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": "aaaaaaaaaaaaaaaaaaaaaaaaaaaa", "b": 1 }', '[ "a", "b" ]', 50, true);

-- nested paths
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b": { "c": 1 } } }', '[ "a.b", "a.b.c" ]', 2000, true);

-- term generation for dotted path index keys with literal vs nested fields
-- index on "a.b.c" with a nested document a -> b -> c
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b": { "c": 1 } } }', '[ "a.b.c" ]', 2000, true);

-- index on "a.b.c" with a literal dotted field "a.b.c"
-- should generate $undefined since dotted path traversal should not match literal field names
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a.b.c": 1 }', '[ "a.b.c" ]', 2000, true);

-- index on "a.b.c" with both literal and nested
-- should only generate terms for the nested path value (3), not the literal field (99)
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a.b.c": 99, "a": { "b": { "c": 3 } } }', '[ "a.b.c" ]', 2000, true);

-- index on "a.b.c" with no matching path at all
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b": { "d": 1 } } }', '[ "a.b.c" ]', 2000, true);

-- composite index with two dotted paths: both nested
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "x": { "y": 10 }, "p": { "q": 20 } }', '[ "x.y", "p.q" ]', 2000, true);

-- composite index with two dotted paths: both literal dotted field names
-- should generate $undefined for both paths
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "x.y": 10, "p.q": 20 }', '[ "x.y", "p.q" ]', 2000, true);

-- composite index with two dotted paths: mixed (nested x.y, literal "p.q")
-- should generate term for x.y=10 and $undefined for p.q
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "x": { "y": 10 }, "p.q": 20 }', '[ "x.y", "p.q" ]', 2000, true);

-- term generation for dotted fields in sub-paths (e.g. a: { "b.c": 1 })
-- index on "a.b.c": a -> "b.c" (literal dotted sub-field) should NOT generate a term
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b.c": 1 } }', '[ "a.b.c" ]', 2000, true);

-- index on "a.b.c": both sub-path literal "b.c" and nested b -> c present - should only generate term for nested value (5)
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b.c": 1, "b": { "c": 5 } } }', '[ "a.b.c" ]', 2000, true);

-- index on "a.b.c.d": deeper nesting with a literal dotted sub-field at different levels
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b": { "c": { "d": 7 } } } }', '[ "a.b.c.d" ]', 2000, true);

-- index on "a.b.c.d": literal "b.c" at the a level - should NOT match
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b.c": { "d": 7 } } }', '[ "a.b.c.d" ]', 2000, true);

-- index on "a.b.c.d": literal "c.d" at the b level - should NOT match
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b": { "c.d": 7 } } }', '[ "a.b.c.d" ]', 2000, true);

-- composite index: one path has sub-path literal, other is nested - should generate $undefined for sub-path literal
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms('{ "a": { "b.c": 1 }, "x": { "y": 10 } }', '[ "a.b.c", "x.y" ]', 2000, true);

-- create a table and insert some data.

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "comp_index", "key": { "a": 1, "b": -1 } } ] }', TRUE);

-- create an index
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "comp_index1", "key": { "a": 1, "b": 1 } } ] }', TRUE);

-- create a non composite index with a different name and same key (works)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "comp_index4", "key": { "a": 1, "b": 1 }, "enableCompositeTerm": false } ] }', TRUE);

-- check the index
\d documentdb_data.documents_5601

-- now drop the extra indexes
CALL documentdb_api.drop_indexes('comp_db', '{ "dropIndexes": "comp_collection", "index": "comp_index" }');
CALL documentdb_api.drop_indexes('comp_db', '{ "dropIndexes": "comp_collection", "index": "comp_index4" }');

\d documentdb_data.documents_5601

SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 1, "a": 1, "b": true }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 2, "a": [ 1, 2 ], "b": true }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 3, "a": 1, "b": [ true, false ] }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 4, "a": [ 1, 2 ], "b": [ true, false ] }');

-- pushes to the composite index
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 1, "b": true } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 2, "b": true } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 2, "b": false } }');

-- validate specifying just one path
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 2 } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "b": false } }');

-- prefix inequality
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$gt": 0 }, "b": false } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$gt": 1 }, "b": false } }');

-- suffix inequality
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 1, "b":  { "$gt": false } } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 2, "b":  { "$gt": false } } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 1, "b":  { "$gt": true } } }');

-- now add some cross-type members
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 5, "a": "string1", "b": true }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 6, "a": "string2", "b": true }');

SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 7, "a": { "key": "string2" }, "b": true }');

-- has cross type values
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$exists": true }, "b": true } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$gte": { "$minKey": 1 } }, "b": true } }');

-- applies type bracketing
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$gt": 0 }, "b": true } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$gte": "string0" }, "b": true } }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$type": "string" }, "b": true } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$type": "object" }, "b": true } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$type": "number" }, "b": true } }');

-- runtime recheck
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$regex": ".+2$" }, "b": true } }');

-- add large keys
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', FORMAT('{ "_id": 8, "a": { "key": "%s" }, "b": "%s" }', repeat('a', 10000), repeat('a', 10000))::bson);

SELECT FORMAT('{ "find": "comp_collection", "filter": { "a": { "key": "%s" }, "b": "%s" }, "projection": { "_id": 1 } }', repeat('a', 5000), repeat('a', 5000)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', :'q1'::bson);

SELECT FORMAT('{ "find": "comp_collection", "filter": { "a": { "key": "%s" }, "b": "%s" }, "projection": { "_id": 1 } }', repeat('a', 8000), repeat('a', 8000)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', :'q1'::bson);

SELECT FORMAT('{ "find": "comp_collection", "filter": { "a": { "key": "%s" }, "b": "%s" }, "projection": { "_id": 1 } }', repeat('a', 10000), repeat('a', 10000)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', :'q1'::bson);

SELECT FORMAT('{ "find": "comp_collection", "filter": { "a": { "key": "%s" } }, "projection": { "_id": 1 } }', repeat('a', 10000)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', :'q1'::bson);

SELECT FORMAT('{ "find": "comp_collection", "filter": { "b": "%s" }, "projection": { "_id": 1 } }', repeat('a', 10000)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', :'q1'::bson);

-- multi-bound queries
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$in": [ 1, 2 ] }, "b": true } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$in": [ 1, 2 ] }, "b": false } }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$in": [ 2, "string1" ] }, "b": { "$in": [ true, false ] } } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$in": [ 1, 2 ] }, "b": { "$in": [ true, false ] } } }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": { "$in": [ 1, 2 ] }, "a": { "$lt": 2 }, "b": { "$in": [ true, false ] } } }');

-- test that we can create side by side non composite and composite indexes with the same key when forcing composite op class.
set documentdb.defaultUseCompositeOpClass to off;
select documentdb_api.drop_database('comp_db');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_1", "key": { "a": 1 } } ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_-1", "key": { "a": -1} } ] }', TRUE);

SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('comp_db','{ "listIndexes": "comp_collection" }') ORDER BY 1;
SELECT (index_spec).index_name, index_spec FROM documentdb_api_catalog.collection_indexes ci JOIN documentdb_api_catalog.collections c ON c.collection_id = ci.collection_id WHERE c.database_name = 'comp_db' AND c.collection_name = 'comp_collection';


set documentdb.defaultUseCompositeOpClass to on;

-- these should preserve the old non composite indexes (src False, and target DefaultTrue should resolve to equivalent) - 
-- and since the names match, it should be no-op
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_1", "key": { "a": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_-1", "key": { "a": -1 } } ] }', TRUE);

-- These are treated as equivalent options but different names, so error is thrown
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_1_comp", "key": { "a": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_-1_comp", "key": { "a": -1} } ] }', TRUE);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "_id_1_comp", "key": { "_id": 1} } ] }', TRUE);

SELECT collection_id as collid FROM documentdb_api_catalog.collections where database_name = 'comp_db' and collection_name = 'comp_collection' \gset 
SELECT index_spec FROM documentdb_api_catalog.collection_indexes where collection_id = :'collid'::int4;

-- drop the unordered ones and create new ones with composite terms
CALL documentdb_api.drop_indexes('comp_db', '{ "dropIndexes": "comp_collection", "index": "a_1" }');
CALL documentdb_api.drop_indexes('comp_db', '{ "dropIndexes": "comp_collection", "index": "a_-1" }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_1_comp", "key": { "a": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_-1_comp", "key": { "a": -1} } ] }', TRUE);


-- creating two with composite and different names fails
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_1_comp_2", "key": { "a": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_-1_comp_2", "key": { "a": -1 } } ] }', TRUE);


-- test that having side by side indexes we prefer composite index
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 1, "a": 1, "b": true }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 2, "a": [ 1, 2 ], "b": true }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 3, "a": 1, "b": [ true, false ] }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 4, "a": [ 1, 2 ], "b": [ true, false ] }');

SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 5, "a": "string1", "b": true }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 6, "a": "string2", "b": true }');
SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 7, "a": { "key": "string2" }, "b": true }');

SELECT documentdb_api.insert_one('comp_db', 'comp_collection', FORMAT('{ "_id": 8, "a": { "key": "%s" }, "b": "%s" }', repeat('a', 10000), repeat('a', 10000))::bson);

set documentdb.logRelationIndexesOrder to on;
set client_min_messages to log;
EXPLAIN VERBOSE SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 1 } }');

EXPLAIN VERBOSE SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 1, "b": {"$exists": true} } }');
reset client_min_messages;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_1_b_1_c_1", "key": { "a": 1, "b": 1, "c": 1}, "enableOrderedIndex": false } ] }', TRUE);

SELECT documentdb_api.insert_one('comp_db', 'comp_collection', '{ "_id": 7, "a": { "key": "string2" }, "b": true, "c": 1 }');

set documentdb.forceDisableSeqScan to on;
set client_min_messages to log;
EXPLAIN VERBOSE SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 1, "b": {"$exists": true}, "c": {"$exists": true} } }');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "comp_collection", "indexes": [ { "name": "a_1_b_1_c_1_comp", "key": { "a": 1, "b": 1, "c": 1} } ] }', TRUE);

EXPLAIN VERBOSE SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "comp_collection", "filter": { "a": 1, "b": {"$exists": true}, "c": {"$exists": true} } }');

reset client_min_messages;
reset documentdb.forceDisableSeqScan;

set documentdb.logRelationIndexesOrder to off;
set documentdb.defaultUseCompositeOpClass to off;

-- test index limits
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "cmpcollcreate", "indexes": [ { "name": "comp_index", "key": { "a1": 1, "a2": 1, "a3": 1, "a4": 1, "a5": 1, "a6": 1, "a7": 1, "a8": 1, "a9": 1, "a10": 1, "a11": 1, "a12": 1, "a13": 1, "a14": 1, "a15": 1, "a16": 1, "a17": 1, "a18": 1, "a19": 1, "a20": 1, "a21": 1, "a22": 1, "a23": 1, "a24": 1, "a25": 1, "a26": 1, "a27": 1, "a28": 1, "a29": 1, "a30": 1, "a31": 1, "a32": 1 }, "enableCompositeTerm": true } ] }', TRUE);

-- fails
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "cmpcollcreate", "indexes": [ { "name": "comp_index22", "key": { "a1": 1, "a2": 1, "a3": 1, "a4": 1, "a5": 1, "a6": 1, "a7": 1, "a8": 1, "a9": 1, "a10": 1, "a11": 1, "a12": 1, "a13": 1, "a14": 1, "a15": 1, "a16": 1, "a17": 1, "a18": 1, "a19": 1, "a20": 1, "a21": 1, "a22": 1, "a23": 1, "a24": 1, "a25": 1, "a26": 1, "a27": 1, "a28": 1, "a29": 1, "a30": 1, "a31": 1, "a32": 1, "a33": 1 }, "enableCompositeTerm": true } ] }', TRUE);

-- test dotted path fields: index on "a.b.c" should match nested documents
-- but NOT documents with a literal field named "a.b.c"
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "dotted_path_coll", "indexes": [ { "name": "dotted_idx", "key": { "a.b.c": 1 } } ] }', TRUE);

-- doc with nested path a -> b -> c (should match queries on "a.b.c")
SELECT documentdb_api.insert_one('comp_db', 'dotted_path_coll', '{ "_id": 1, "a": { "b": { "c": 1 } } }');
-- doc with literal dotted field name "a.b.c" (should NOT match queries on "a.b.c")
SELECT documentdb_api.insert_one('comp_db', 'dotted_path_coll', '{ "_id": 2, "a.b.c": 1 }');
-- doc with nested path and different value
SELECT documentdb_api.insert_one('comp_db', 'dotted_path_coll', '{ "_id": 3, "a": { "b": { "c": 2 } } }');
-- doc with both a literal "a.b.c" field and a nested a.b.c path
SELECT documentdb_api.insert_one('comp_db', 'dotted_path_coll', '{ "_id": 4, "a.b.c": 99, "a": { "b": { "c": 3 } } }');
-- doc with nested path but missing "c"
SELECT documentdb_api.insert_one('comp_db', 'dotted_path_coll', '{ "_id": 5, "a": { "b": { "d": 1 } } }');

-- exact match on a.b.c = 1: should match only the nested doc (_id 1),
-- not the literal dotted field doc (_id 2).
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_path_coll", "filter": { "a.b.c": 1 } }');

-- exact match on a.b.c = 2: should match only _id 3 (nested)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_path_coll", "filter": { "a.b.c": 2 } }');

-- exact match on a.b.c = 3: should match only _id 4 (nested part)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_path_coll", "filter": { "a.b.c": 3 } }');

-- range query (inequality) on a.b.c: should match _id 1, 3, 4 (nested only)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_path_coll", "filter": { "a.b.c": { "$gte": 1 } } }');

-- $exists on a.b.c: should match docs with nested path (_id 1, 3, 4) only
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_path_coll", "filter": { "a.b.c": { "$exists": true } } }');

-- $type filter on a.b.c (runtime recheck path): should match _id 1, 3, 4 only
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_path_coll", "filter": { "a.b.c": { "$type": "int" } } }');

-- now test with a composite index on two dotted paths
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "dotted_comp_coll", "indexes": [ { "name": "dotted_comp_idx", "key": { "x.y": 1, "p.q": 1 } } ] }', TRUE);

-- nested paths
SELECT documentdb_api.insert_one('comp_db', 'dotted_comp_coll', '{ "_id": 1, "x": { "y": 10 }, "p": { "q": 20 } }');
-- literal dotted field names
SELECT documentdb_api.insert_one('comp_db', 'dotted_comp_coll', '{ "_id": 2, "x.y": 10, "p.q": 20 }');
-- mixed: nested x.y, literal "p.q"
SELECT documentdb_api.insert_one('comp_db', 'dotted_comp_coll', '{ "_id": 3, "x": { "y": 10 }, "p.q": 20 }');

-- composite query on x.y and p.q: should only match _id 1 (both nested)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_comp_coll", "filter": { "x.y": 10, "p.q": 20 } }');

-- single path query on x.y = 10: should only match _id 1 and _id 3 (nested x.y)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_comp_coll", "filter": { "x.y": 10 } }');

-- single path query on p.q = 20: should only match _id 1 (nested p.q)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_comp_coll", "filter": { "p.q": 20 } }');

-- test runtime filter (no index) with dotted path fields
-- create a collection with no indexes other than _id and insert docs with literal vs nested paths
SELECT documentdb_api.insert_one('comp_db', 'dotted_runtime_coll', '{ "_id": 1, "a": { "b": { "c": 1 } } }');
SELECT documentdb_api.insert_one('comp_db', 'dotted_runtime_coll', '{ "_id": 2, "a.b.c": 1 }');
SELECT documentdb_api.insert_one('comp_db', 'dotted_runtime_coll', '{ "_id": 3, "a": { "b": { "c": 2 } } }');
SELECT documentdb_api.insert_one('comp_db', 'dotted_runtime_coll', '{ "_id": 4, "a.b.c": 99, "a": { "b": { "c": 3 } } }');
SELECT documentdb_api.insert_one('comp_db', 'dotted_runtime_coll', '{ "_id": 5, "a": { "b": { "d": 1 } } }');

-- runtime filter only (no index on a.b.c, seq scan): exact match
-- runtime filter correctly excludes _id 2 (literal "a.b.c" field)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_runtime_coll", "filter": { "a.b.c": 1 } }');

-- runtime filter only: range query
-- runtime filter correctly excludes _id 2 (literal "a.b.c" field)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_runtime_coll", "filter": { "a.b.c": { "$gte": 1 } } }');

-- runtime filter only: $exists
-- runtime filter correctly excludes _id 2 (literal "a.b.c" field)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_runtime_coll", "filter": { "a.b.c": { "$exists": true } } }');

-- runtime filter only: $type check
-- runtime filter correctly excludes _id 2 (literal "a.b.c" field)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_runtime_coll", "filter": { "a.b.c": { "$type": "int" } } }');

-- runtime filter via direct @@ operator: exact match on a.b.c
-- these use the BSON match operator directly, bypassing any index
-- nested doc: should match
SELECT '{ "a": { "b": { "c": 1 } } }'::bson @@ '{ "a.b.c": 1 }';
-- literal dotted field: should NOT match - runtime filter correctly returns false
SELECT '{ "a.b.c": 1 }'::bson @@ '{ "a.b.c": 1 }';
-- nested doc with different value: should not match
SELECT '{ "a": { "b": { "c": 2 } } }'::bson @@ '{ "a.b.c": 1 }';
-- both literal and nested: should match (via nested path)
SELECT '{ "a.b.c": 99, "a": { "b": { "c": 1 } } }'::bson @@ '{ "a.b.c": 1 }';
-- no matching path: should not match
SELECT '{ "a": { "b": { "d": 1 } } }'::bson @@ '{ "a.b.c": 1 }';

-- runtime filter via @@ with $gte on dotted path
SELECT '{ "a": { "b": { "c": 5 } } }'::bson @@ '{ "a.b.c": { "$gte": 1 } }';
-- literal dotted field: runtime filter correctly returns false
SELECT '{ "a.b.c": 5 }'::bson @@ '{ "a.b.c": { "$gte": 1 } }';

-- runtime filter via @@ with $exists on dotted path
SELECT '{ "a": { "b": { "c": 1 } } }'::bson @@ '{ "a.b.c": { "$exists": true } }';
-- literal dotted field: runtime filter correctly returns false
SELECT '{ "a.b.c": 1 }'::bson @@ '{ "a.b.c": { "$exists": true } }';
-- no nested c: should return false
SELECT '{ "a": { "b": { "d": 1 } } }'::bson @@ '{ "a.b.c": { "$exists": true } }';

-- test dotted fields in sub-paths: a: { "b.c": 1 } vs a: { b: { c: 1 } }
-- index on "a.b.c" - queries should only match nested a -> b -> c, not a -> "b.c"
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_db', '{ "createIndexes": "dotted_subpath_coll", "indexes": [ { "name": "subpath_idx", "key": { "a.b.c": 1 } } ] }', TRUE);

-- doc with fully nested path a -> b -> c (should match queries on "a.b.c")
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_coll', '{ "_id": 1, "a": { "b": { "c": 1 } } }');
-- doc with literal dotted sub-field a -> "b.c" (should NOT match queries on "a.b.c")
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_coll', '{ "_id": 2, "a": { "b.c": 1 } }');
-- doc with both sub-path literal and nested
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_coll', '{ "_id": 3, "a": { "b.c": 99, "b": { "c": 5 } } }');
-- doc with nested a -> b but no c
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_coll', '{ "_id": 4, "a": { "b": { "d": 1 } } }');
-- doc with deeper nesting and sub-path literal at second level: a -> b -> "c.d"
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_coll', '{ "_id": 5, "a": { "b": { "c.d": 1 } } }');

-- exact match on a.b.c = 1: should only match _id 1 (nested a -> b -> c)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_subpath_coll", "filter": { "a.b.c": 1 } }');

-- exact match on a.b.c = 5: should only match _id 3 (nested part)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_subpath_coll", "filter": { "a.b.c": 5 } }');

-- $exists on a.b.c: should match _id 1 and _id 3 (nested paths only)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_subpath_coll", "filter": { "a.b.c": { "$exists": true } } }');

-- $gte on a.b.c: should match _id 1, _id 3 (nested paths only)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_subpath_coll", "filter": { "a.b.c": { "$gte": 1 } } }');

-- runtime filter via @@ for sub-path dotted fields
-- nested a -> b -> c: should match
SELECT '{ "a": { "b": { "c": 1 } } }'::bson @@ '{ "a.b.c": 1 }';
-- sub-path literal a -> "b.c": should NOT match
SELECT '{ "a": { "b.c": 1 } }'::bson @@ '{ "a.b.c": 1 }';
-- both present: should match via nested path
SELECT '{ "a": { "b.c": 99, "b": { "c": 1 } } }'::bson @@ '{ "a.b.c": 1 }';
-- sub-path literal a -> b -> "c.d": query on a.b.c.d should not match
SELECT '{ "a": { "b": { "c.d": 7 } } }'::bson @@ '{ "a.b.c.d": 7 }';
-- fully nested a -> b -> c -> d: should match
SELECT '{ "a": { "b": { "c": { "d": 7 } } } }'::bson @@ '{ "a.b.c.d": 7 }';

-- runtime filter (no index) for sub-path dotted fields
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_runtime_coll', '{ "_id": 1, "a": { "b": { "c": 1 } } }');
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_runtime_coll', '{ "_id": 2, "a": { "b.c": 1 } }');
SELECT documentdb_api.insert_one('comp_db', 'dotted_subpath_runtime_coll', '{ "_id": 3, "a": { "b.c": 99, "b": { "c": 5 } } }');

-- runtime filter correctly excludes _id 2 (a -> "b.c" sub-path literal)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_subpath_runtime_coll", "filter": { "a.b.c": 1 } }');

-- runtime filter: $exists correctly excludes _id 2
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('comp_db', '{ "find": "dotted_subpath_runtime_coll", "filter": { "a.b.c": { "$exists": true } } }');


---------------------------------------------------------------------------------------------
-- Non-TTL index equivalency with defaultUseCompositeOpClass
---------------------------------------------------------------------------------------------

-- D1. Create non-TTL index with GUC off (undefined → no composite)
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d1", "indexes": [{"key": {"x": 1}, "name": "x_idx"}]}', true);
END;

-- Verify D1 — no storageEngine
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('comp_db','{ "listIndexes": "comp_equiv_d1" }') ORDER BY 1;
SELECT (index_spec).index_name, index_spec FROM documentdb_api_catalog.collection_indexes ci JOIN documentdb_api_catalog.collections c ON c.collection_id = ci.collection_id WHERE c.database_name = 'comp_db' AND c.collection_name = 'comp_equiv_d1' AND (index_spec).index_name = 'x_idx';

-- D2. Re-create same index with legacy GUC on (undefined → DefaultTrue) => equivalent (idempotent)
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d1", "indexes": [{"key": {"x": 1}, "name": "x_idx"}]}', true);
END;

-- D3. Create non-TTL index with legacy GUC on (undefined → DefaultTrue)
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": [{"key": {"y": 1}, "name": "y_idx"}]}', true);
END;

-- Verify D3 — should have storageEngine with enableOrderedIndex: true
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('comp_db','{ "listIndexes": "comp_equiv_d3" }') ORDER BY 1;
SELECT (index_spec).index_name, index_spec FROM documentdb_api_catalog.collection_indexes ci JOIN documentdb_api_catalog.collections c ON c.collection_id = ci.collection_id WHERE c.database_name = 'comp_db' AND c.collection_name = 'comp_equiv_d3' AND (index_spec).index_name = 'y_idx';

-- D4. Re-create D3 with GUC off, same name, undefined => equivalent (Undefined matches DefaultTrue)
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": [{"key": {"y": 1}, "name": "y_idx"}]}', true);
END;

-- D5. Re-create D3 with explicit false (-1), different name => NOT equivalent (creates new index)
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": [{"key": {"y": 1}, "enableCompositeTerm": false, "name": "y_idx_nocomp"}]}', true);
END;

-- D6. Verify both indexes coexist
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('comp_db','{ "listIndexes": "comp_equiv_d3" }') ORDER BY 1;

-- D7. Create two indexes in the same collection with the same key but different enableCompositeTerm settings => NOT equivalent (creates new index)
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": 
    [
        {"key": {"z": 1}, "enableCompositeTerm": false, "name": "z_idx_nocomp"},
        {"key": {"z": 1}, "enableCompositeTerm": true, "name": "z_idx_comp"}
    ]}', true);
END;

-- D8. Verify both indexes coexist
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('comp_db','{ "listIndexes": "comp_equiv_d3" }') ORDER BY 1;

-- D9. Create two indexes in the same collection with the same key but different enableCompositeTerm settings => NOT equivalent (creates new index)
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": 
    [
        {"key": {"w": 1}, "name": "w_idx"},
        {"key": {"w": 1}, "enableCompositeTerm": false, "name": "w_idx_nocomp"},
        {"key": {"w": 1}, "enableCompositeTerm": true, "name": "w_idx_comp"}
    ]}', true);
END;

BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": 
    [
        {"key": {"w": 1}, "name": "w_idx"},
        {"key": {"w": 1}, "enableCompositeTerm": false, "name": "w_idx_nocomp"},
        {"key": {"w": 1}, "enableCompositeTerm": true, "name": "w_idx_comp"}
    ]}', true);
END;

BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": 
    [
        {"key": {"w": 1}, "name": "w_idx"}
    ]}', true);
END;

BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": 
    [
        {"key": {"w": 1}, "name": "w_idx"}
    ]}', true);
END;

BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": 
    [
        {"key": {"w": 1}, "enableCompositeTerm": true, "name": "w_idx"}
    ]}', true);
END;

BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_equiv_d3", "indexes": 
    [
        {"key": {"p": 1}, "enableCompositeTerm": -1, "name": "p_idx"}
    ]}', true);
END;


-- D10. Verify both indexes coexist
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('comp_db','{ "listIndexes": "comp_equiv_d3" }') ORDER BY 1;

-- D11. Test emitEnableOrderedIndexFalseInResponse GUC
-- Create a collection with one composite (True) and one explicitly-false index.
BEGIN;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_db', '{"createIndexes": "comp_emit_guc", "indexes": [
    {"key": {"a": 1}, "enableCompositeTerm": true,  "name": "a_comp"},
    {"key": {"b": 1}, "enableCompositeTerm": false, "name": "b_nocomp"}
]}', true);
END;

-- D11a. GUC ON (default): explicitly-false index emits "enableOrderedIndex": false
SET documentdb.emitEnableOrderedIndexFalseInResponse TO on;
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch')
FROM documentdb_api.list_indexes_cursor_first_page('comp_db', '{ "listIndexes": "comp_emit_guc" }')
ORDER BY 1;

-- D11b. GUC OFF: explicitly-false index omits enableOrderedIndex entirely
SET documentdb.emitEnableOrderedIndexFalseInResponse TO off;
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch')
FROM documentdb_api.list_indexes_cursor_first_page('comp_db', '{ "listIndexes": "comp_emit_guc" }')
ORDER BY 1;

-- Reset to default
SET documentdb.emitEnableOrderedIndexFalseInResponse TO on;
