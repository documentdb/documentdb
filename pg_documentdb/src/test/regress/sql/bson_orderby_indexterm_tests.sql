SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET documentdb.next_collection_id TO 900;
SET documentdb.next_collection_index_id TO 900;

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": 1 }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": null }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ] }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ] }', '{ "a": -1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ { "b": 0 }, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": -1 }'));

-- try with collation
set documentdb_core.enableCollation to on;
SELECT bsonindexterm_to_bson(bson_orderby_index('{ }', '{ "a": 1 }', 'en-u-ks-level1'));

-- case insensitive - picks cat
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ "Cat", "dog", "elephant" ] }', '{ "a": 1 }', 'en-u-ks-level1'));

-- case sensitive (default) - picks Dog
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ "cat", "Dog", "elephant" ] }', '{ "a": 1 }'));

-- try with a composite index term
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": 1, "b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": -1, "b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": -1, "b": -1 }'));