SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, documentdb_api_internal, public;
SET documentdb.next_collection_id TO 6400;
SET documentdb.next_collection_index_id TO 6400;

-- create a collection
SELECT documentdb_api.create_collection('stats_db', 'planner_stats');

\d documentdb_data.documents_6401

SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "planner_stats", "indexes": [ { "key": { "b": 1, "c": 1 }, "name": "b_c_1" } ] }', TRUE);

-- enable planner statistics for the collection (should fail)
SELECT documentdb_api.coll_mod('stats_db', 'planner_stats', '{ "collMod": "planner_stats", "enableStats": true }');

-- enable the feature and try again (should succeed)
set documentdb.enablePerCollectionPlannerStatistics to on;
SELECT documentdb_api.coll_mod('stats_db', 'planner_stats', '{ "collMod": "planner_stats", "enableStats": true }');

-- verify statsEnabled is now in the collections.options column (not on the _id_ index)
SELECT options FROM documentdb_api_catalog.collections WHERE collection_id = 6401;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "planner_stats" }') ORDER BY 1;

-- now create an index on the collection and verify that the planner statistics are updated for the index
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "planner_stats", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', TRUE);

\d documentdb_data.documents_6401

-- dropping the index should remove the stats.
CALL documentdb_api.drop_indexes('stats_db', '{ "dropIndexes": "planner_stats", "index": "a_1" }');

\d documentdb_data.documents_6401

-- test the stats function
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1, "b": 1 }', 'b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1, "b": { "c": 1 } }', 'b.c');

-- works for top level arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1, "b": { "c": [ 1, 2, 3 ] } }', 'b.c');

-- works for parent arrays via traversal
-- A path that does not resolve (parent arrays, or an entirely absent field)
-- now projects an explicit null rather than SQL NULL. This lets absent values
-- be captured in the collected statistics so that a sparse $exists estimates
-- the true (tiny) presence fraction instead of matching every row.
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1, "b": [ { "c": 1 }, { "c": 2 } ] }', 'b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1 }', 'missing');
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1, "b": { "c": 1 } }', 'b.d');

-- ============================================================================
-- Tests for bson_stats_project: null, missing, and nested array paths
-- ============================================================================

-- Null values at leaf
SELECT documentdb_api_internal.bson_stats_project('{ "a": null }', 'a');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": null } }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": null } } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": { "d": null } } } }', 'a.b.c.d');

-- Missing values (field does not exist at all)
SELECT documentdb_api_internal.bson_stats_project('{ "x": 1 }', 'a');
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1 }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "x": 1 } }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": 1 } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "x": 1 } } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": 1 } } }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": { "x": 1 } } } }', 'a.b.c.d');

-- Null at intermediate path (parent is null, child is requested)
SELECT documentdb_api_internal.bson_stats_project('{ "a": null }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": null }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": null } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": null } }', 'a.b.c.d');

-- Leaf is an array
SELECT documentdb_api_internal.bson_stats_project('{ "a": [1, 2, 3] }', 'a');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [1, 2, 3] } }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": [1, 2, 3] } } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": { "d": [1, 2, 3] } } } }', 'a.b.c.d');

-- Leaf array contains nulls and missing-equivalent values
SELECT documentdb_api_internal.bson_stats_project('{ "a": [1, null, 3] }', 'a');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [null, null] } }', 'a.b');

-- Array at first level of a.b.c.d path
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": { "c": { "d": 1 } } }, { "b": { "c": { "d": 2 } } } ] }', 'a.b.c.d');

-- Array at second level of a.b.c.d path
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [ { "c": { "d": 1 } }, { "c": { "d": 2 } } ] } }', 'a.b.c.d');

-- Array at third level of a.b.c.d path
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": [ { "d": 1 }, { "d": 2 } ] } } }', 'a.b.c.d');

-- Array at fourth level (d is itself an array)
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": { "d": [1, 2, 3] } } } }', 'a.b.c.d');

-- Multiple levels are arrays: a and b are arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": [ { "c": { "d": 1 } } ] }, { "b": [ { "c": { "d": 2 } } ] } ] }', 'a.b.c.d');

-- Multiple levels are arrays: a and c are arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": { "c": [ { "d": 1 }, { "d": 2 } ] } }, { "b": { "c": [ { "d": 3 } ] } } ] }', 'a.b.c.d');

-- Multiple levels are arrays: b and c are arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [ { "c": [ { "d": 1 }, { "d": 2 } ] }, { "c": [ { "d": 3 } ] } ] } }', 'a.b.c.d');

-- Multiple levels are arrays: b and d are arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [ { "c": { "d": [1, 2] } }, { "c": { "d": [3, 4] } } ] } }', 'a.b.c.d');

-- All levels are arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": [ { "c": [ { "d": [1] } ] } ] } ] }', 'a.b.c.d');

-- Array paths where some elements have the sub-path and others don't
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": { "c": { "d": 1 } } }, { "b": { "c": { "x": 2 } } } ] }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": { "c": { "d": 1 } } }, { "b": { "x": 2 } } ] }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": { "c": { "d": 1 } } }, { "x": 2 } ] }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": { "c": { "d": 1 } } }, { } ] }', 'a.b.c.d');

-- Array with mix of objects and scalars at intermediate level
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ { "b": 1 }, { "b": { "c": { "d": 2 } } } ] }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [ 1, { "c": { "d": 2 } } ] } }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": [ 1, { "d": 2 } ] } } }', 'a.b.c.d');

-- Array with mix of nulls and valid objects
SELECT documentdb_api_internal.bson_stats_project('{ "a": [ null, { "b": { "c": { "d": 1 } } } ] }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [ null, { "c": { "d": 1 } } ] } }', 'a.b.c.d');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": [ null, { "d": 1 } ] } } }', 'a.b.c.d');

-- Empty arrays at various levels
SELECT documentdb_api_internal.bson_stats_project('{ "a": [] }', 'a');
SELECT documentdb_api_internal.bson_stats_project('{ "a": [] }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [] } }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": [] } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": [] } } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": [] } } }', 'a.b.c.d');

-- Empty document at various levels
SELECT documentdb_api_internal.bson_stats_project('{ "a": { } }', 'a.b');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { } } }', 'a.b.c');
SELECT documentdb_api_internal.bson_stats_project('{ "a": { "b": { "c": { } } } }', 'a.b.c.d');

-- Deeply nested arrays with some paths missing at different depths
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ { "b": [ { "c": [ { "d": 1 }, { "d": 2 } ] }, { "c": [ { "d": 3 } ] } ] }, { "b": [ { "c": [ { "x": 99 } ] } ] } ] }',
    'a.b.c.d');

-- ============================================================================
-- Tests for bson_stats_project: arrays with duplicates and larger arrays
-- ============================================================================

-- 10-element array at leaf, no duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [7, 3, 9, 1, 5, 10, 2, 8, 4, 6] }', 'a');

-- 10-element array at leaf, with duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [3, 1, 2, 1, 3, 2, 1, 3, 1, 2] }', 'a');

-- 20-element array at leaf, no duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [14, 7, 2, 19, 11, 5, 16, 3, 20, 8, 1, 13, 6, 18, 10, 4, 17, 9, 15, 12] }', 'a');

-- 20-element array at leaf, with duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [3, 5, 1, 4, 2, 5, 3, 1, 2, 4, 1, 5, 3, 2, 4, 1, 3, 5, 2, 4] }', 'a');

-- 30-element array at leaf, no duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [22, 7, 15, 3, 28, 11, 19, 1, 25, 9, 30, 14, 6, 21, 17, 4, 26, 12, 8, 23, 2, 29, 16, 5, 27, 10, 20, 13, 24, 18] }', 'a');

-- 30-element array at leaf, all duplicates (same value)
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7] }', 'a');

-- 10-element intermediate array with path traversal, no duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": 6}, {"b": 2}, {"b": 9}, {"b": 4}, {"b": 10}, {"b": 1}, {"b": 7}, {"b": 3}, {"b": 8}, {"b": 5} ] }', 'a.b');

-- 10-element intermediate array with path traversal, with duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": 2}, {"b": 1}, {"b": 2}, {"b": 1}, {"b": 2}, {"b": 1}, {"b": 1}, {"b": 2}, {"b": 2}, {"b": 1} ] }', 'a.b');

-- 20-element intermediate array with path traversal, with duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": 3}, {"b": 1}, {"b": 2}, {"b": 3}, {"b": 1}, {"b": 2}, {"b": 1}, {"b": 3}, {"b": 2}, {"b": 1}, {"b": 3}, {"b": 2}, {"b": 1}, {"b": 3}, {"b": 2}, {"b": 3}, {"b": 1}, {"b": 2}, {"b": 1}, {"b": 3} ] }', 'a.b');

-- 10-element intermediate array with nested path, no duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": {"c": 8}}, {"b": {"c": 3}}, {"b": {"c": 6}}, {"b": {"c": 1}}, {"b": {"c": 10}}, {"b": {"c": 5}}, {"b": {"c": 9}}, {"b": {"c": 2}}, {"b": {"c": 7}}, {"b": {"c": 4}} ] }', 'a.b.c');

-- 10-element intermediate array with nested path, with duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": {"c": 2}}, {"b": {"c": 3}}, {"b": {"c": 1}}, {"b": {"c": 3}}, {"b": {"c": 1}}, {"b": {"c": 2}}, {"b": {"c": 1}}, {"b": {"c": 3}}, {"b": {"c": 2}}, {"b": {"c": 1}} ] }', 'a.b.c');

-- Multiple arrays at different levels with duplicates: a has 3 elements, each b has 3 elements
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": [{"c": 2}, {"c": 1}, {"c": 1}]}, {"b": [{"c": 1}, {"c": 3}, {"c": 3}]}, {"b": [{"c": 2}, {"c": 1}, {"c": 2}]} ] }', 'a.b.c');

-- Large nested array with duplicates and some missing paths
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": 2}, {"b": 1}, {"x": 99}, {"b": 3}, {"b": 1}, {"b": 4}, {"x": 88}, {"b": 1}, {"b": 2}, {"b": 1} ] }', 'a.b');

-- Large nested array with duplicates, nulls, and missing paths mixed
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": null}, {"b": 1}, null, {"b": 2}, {"b": 1}, {"x": 5}, {"b": null}, {"b": 1}, {"b": 2}, {"b": 1} ] }', 'a.b');

-- 20-element array at nested path a.b.c.d with duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": {"c": {"d": 3}}}, {"b": {"c": {"d": 1}}}, {"b": {"c": {"d": 2}}}, {"b": {"c": {"d": 1}}}, {"b": {"c": {"d": 3}}}, {"b": {"c": {"d": 2}}}, {"b": {"c": {"d": 1}}}, {"b": {"c": {"d": 3}}}, {"b": {"c": {"d": 2}}}, {"b": {"c": {"d": 3}}}, {"b": {"c": {"d": 1}}}, {"b": {"c": {"d": 2}}}, {"b": {"c": {"d": 3}}}, {"b": {"c": {"d": 1}}}, {"b": {"c": {"d": 2}}}, {"b": {"c": {"d": 1}}}, {"b": {"c": {"d": 3}}}, {"b": {"c": {"d": 2}}}, {"b": {"c": {"d": 1}}}, {"b": {"c": {"d": 3}}} ] }',
    'a.b.c.d');

-- Leaf array with 20 elements containing duplicates and nulls
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": { "b": [3, null, 1, 5, 2, null, 4, 1, 3, 2, null, 5, 1, 4, 3, null, 2, 1, 5, 3] } }', 'a.b');

-- Intermediate array (10 elements) where leaf is also an array with duplicates
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": [2, 1, 1]}, {"b": [3, 2, 2]}, {"b": [1, 3, 3]}, {"b": [2, 1, 1]}, {"b": [3, 2, 2]}, {"b": [1, 3, 3]}, {"b": [2, 1, 1]}, {"b": [3, 2, 2]}, {"b": [1, 3, 3]}, {"b": [2, 1, 1]} ] }', 'a.b');

-- 21-element intermediate array: 20 duplicates followed by a unique value on the 21st
-- The unique value (999) should appear in the sample
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 999} ] }', 'a.b');

-- ============================================================================
-- Tests for bson_stats_project: 1KB truncation threshold
-- The output array is truncated after the first value that crosses 1024 bytes
-- ============================================================================

-- 10 unique strings of ~150 bytes each: should truncate around 6-7 values (~1024 bytes)
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa02", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa03", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa04", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa05", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa06", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa07", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa08", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa09", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa10"] }', 'a');

-- 10 unique strings of ~300 bytes each: should truncate around 3-4 values
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa02", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa03", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa04", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa05", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa06", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa07", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa08", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa09", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa10"] }', 'a');

-- Single value > 1024 bytes: should still include it (first value always written)
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }', 'a');

-- Intermediate array with long string values: truncation on path traversal
SELECT documentdb_api_internal.bson_stats_project(
    '{ "a": [ {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx01"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx02"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx03"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx04"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx05"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx06"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx07"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx08"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx09"}, {"b": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx10"} ] }', 'a.b');

-- ============================================================================
-- Memory leak tests for bson_stats_project using test_bson_stats_project_with_memcheck
-- Validates that bson_stats_project does not allocate/leak memory in the calling context
-- ============================================================================

CREATE OR REPLACE FUNCTION test_bson_stats_project_with_memcheck(
    document documentdb_core.bson, field text, loop_count int)
RETURNS documentdb_core.bson
LANGUAGE C STRICT
AS 'pg_documentdb', $$test_bson_stats_project_with_memcheck$$;

-- Validate truncation with the memcheck function (no leaks during truncation)
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa02", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa03", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa04", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa05", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa06", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa07", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa08", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa09", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa10"] }', 'a', 100);

-- Simple scalar values
SELECT test_bson_stats_project_with_memcheck('{ "a": 1, "b": "hello" }', 'b', 100);
SELECT test_bson_stats_project_with_memcheck('{ "a": 1, "b": 3.14159 }', 'b', 100);

-- Null values
SELECT test_bson_stats_project_with_memcheck('{ "a": null }', 'a', 100);
SELECT test_bson_stats_project_with_memcheck('{ "a": { "b": null } }', 'a.b', 100);

-- Missing values
SELECT test_bson_stats_project_with_memcheck('{ "x": 1 }', 'a', 100);
SELECT test_bson_stats_project_with_memcheck('{ "a": { "x": 1 } }', 'a.b.c', 100);

-- Simple leaf array
SELECT test_bson_stats_project_with_memcheck('{ "a": [1, 2, 3, 4, 5] }', 'a', 100);

-- Leaf array with duplicates
SELECT test_bson_stats_project_with_memcheck('{ "a": [3, 1, 3, 2, 1, 3, 2, 1] }', 'a', 100);

-- Intermediate array with path traversal
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": 10}, {"b": 20}, {"b": 30}, {"b": 10}, {"b": 20} ] }', 'a.b', 100);

-- Nested path through intermediate array with duplicates
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": {"c": 5}}, {"b": {"c": 5}}, {"b": {"c": 10}}, {"b": {"c": 10}}, {"b": {"c": 15}} ] }', 'a.b.c', 100);

-- Multiple levels of arrays: a is array, each element has b as array
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": [1, 2, 3]}, {"b": [2, 3, 4]}, {"b": [3, 4, 5]} ] }', 'a.b', 100);

-- Deeply nested arrays: a.b.c.d with arrays at multiple levels
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": [ {"c": [ {"d": 1}, {"d": 2} ]}, {"c": [ {"d": 3} ]} ]}, {"b": [ {"c": [ {"d": 4}, {"d": 5} ]} ]} ] }', 'a.b.c.d', 100);

-- Large array (20 elements) with duplicates
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [7, 3, 9, 3, 7, 1, 9, 5, 3, 7, 1, 5, 9, 3, 7, 1, 5, 9, 3, 7] }', 'a', 100);

-- Large intermediate array (20 elements) with path traversal and duplicates
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": 5}, {"b": 12}, {"b": 5}, {"b": 8}, {"b": 12}, {"b": 3}, {"b": 5}, {"b": 8}, {"b": 3}, {"b": 12}, {"b": 5}, {"b": 8}, {"b": 3}, {"b": 12}, {"b": 5}, {"b": 8}, {"b": 3}, {"b": 12}, {"b": 5}, {"b": 999} ] }', 'a.b', 100);

-- 30-element array with heavy duplicates
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [2, 8, 2, 5, 8, 2, 5, 8, 2, 5, 8, 2, 5, 8, 2, 5, 8, 2, 5, 8, 2, 5, 8, 2, 5, 8, 2, 5, 8, 99] }', 'a', 100);

-- Mixed types in array (strings, numbers, nulls)
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [1, "hello", null, 3.14, "world", null, 1, "hello", 42] }', 'a', 100);

-- Intermediate array with some elements missing the target field
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": 1}, {"x": 2}, {"b": 3}, {"y": 4}, {"b": 5}, {"b": 1}, {"x": 6} ] }', 'a.b', 100);

-- Intermediate array with nulls at leaf and missing paths mixed
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": {"c": null}}, {"b": {"c": 5}}, {"b": {"x": 1}}, {"b": null}, {"b": {"c": 5}}, {"b": {"c": null}} ] }', 'a.b.c', 100);

-- Large document with many fields (only projecting one)
SELECT test_bson_stats_project_with_memcheck(
    '{ "f1": "aaaa", "f2": "bbbb", "f3": "cccc", "f4": "dddd", "f5": "eeee", "f6": "ffff", "f7": "gggg", "f8": "hhhh", "f9": "iiii", "f10": "jjjj", "target": [5, 3, 8, 3, 5, 1, 8, 3] }', 'target', 100);

-- 21-element intermediate array: 20 duplicates then unique (high iteration count)
SELECT test_bson_stats_project_with_memcheck(
    '{ "a": [ {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 5}, {"b": 999} ] }', 'a.b', 500);

DROP FUNCTION test_bson_stats_project_with_memcheck(documentdb_core.bson, text, int);

-- now test the stats usage.
SELECT COUNT(documentdb_api.insert_one('stats_db', 'planner_stats', bson_build_document('_id', i, 'b', 1, 'c', i, 'padding', repeat('x', 1010)))) FROM generate_series(1, 1000) i;
SELECT COUNT(documentdb_api.insert_one('stats_db', 'planner_stats', bson_build_document('_id', i, 'b', i, 'c', i, 'padding', repeat('x', 1010)))) FROM generate_series(1, 10) i;

-- the selectivity for 'b': 1 is ~50% - without custom stats it assumes that it's 1% and it should pick the index on b,c
ANALYZE documentdb_data.documents_6401;
set documentdb.enableCompositeIndexPlanner to on;
set documentdb.enablePerCollectionPlannerStatistics to off;
-- Bitmap scans are disabled so the plan shape is a stable index scan across PG versions.
set enable_bitmapscan to off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "planner_stats", "filter": { "b": 1 } }');
reset enable_bitmapscan;

-- with stats on this is now correctly reflected and will pick a seqscan.
set documentdb.enablePerCollectionPlannerStatistics to on;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "planner_stats", "filter": { "b": 1 } }');

-- expr stats are created for the table post analyze
SELECT expr, statistics_name, array_length(most_common_vals::text::bson[], 1), (most_common_vals::text::bson[])[1:5],
    array_length(most_common_elems::text::bson[], 1),(most_common_elems::text::bson[])[1:5],
    array_length(histogram_bounds::text::bson[], 1), (histogram_bounds::text::bson[])[1:5] FROM pg_stats_ext_exprs WHERE tablename = 'documents_6401' ORDER BY statistics_name;

-- for the compound index, correlation stats are collected as well.
SELECT statistics_name, exprs, n_distinct FROM pg_stats_ext WHERE tablename = 'documents_6401';

-- validate now for other index types
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "planner_stats", "indexes": [ { "key": { "a.$**": 1 }, "name": "a_wk_1" } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "planner_stats", "indexes": [ { "key": { "b": "hashed" }, "name": "b_hashed" } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "planner_stats", "indexes": [ { "key": { "$**": 1 }, "wildcardProjection": { "a": 1 }, "name": "c_wp1" } ] }', TRUE);

\d documentdb_data.documents_6401

------------------------------------------------------------------------------
-- Tests for documentdb.enablePlannerStatisticsNewCollections
--
-- This GUC only takes effect at create_collection time, causing newly created
-- collections to have planner statistics auto-enabled. For the custom
-- statistics to be USED during query planning, the
-- enablePerCollectionPlannerStatistics GUC must also be on at query time.
------------------------------------------------------------------------------
RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enablePlannerStatisticsNewCollections;

-- Baseline: with both GUCs off, a new collection has stats disabled.
SELECT documentdb_api.create_collection('stats_db', 'auto_off');
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "auto_off" }') ORDER BY 1;
\d documentdb_data.documents_6402

-- With enablePlannerStatisticsNewCollections=on, a new collection auto-enables stats.
set documentdb.enablePlannerStatisticsNewCollections to on;
SELECT documentdb_api.create_collection('stats_db', 'auto_on');
-- collections.options shows statsEnabled=true (stored at creation time via INSERT).
SELECT options FROM documentdb_api_catalog.collections WHERE collection_id = 6403;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "auto_on" }') ORDER BY 1;
\d documentdb_data.documents_6403

-- Creating an index on the auto-stats collection materializes a Statistics object.
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "auto_on", "indexes": [ { "key": { "x": 1, "y": 1 }, "name": "x_y_1" } ] }', TRUE);
\d documentdb_data.documents_6403

-- Wildcard / hashed indexes follow the same exclusion rules as the existing
-- per-collection flow (no expression stats for wildcard / hashed indexes).
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "auto_on", "indexes": [ { "key": { "$**": 1 }, "name": "wc_1" } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "auto_on", "indexes": [ { "key": { "z": "hashed" }, "name": "z_hashed" } ] }', TRUE);
\d documentdb_data.documents_6403

-- Toggling the new GUC off after creation does NOT remove stats. The flag persists.
set documentdb.enablePlannerStatisticsNewCollections to off;
SELECT options FROM documentdb_api_catalog.collections WHERE collection_id = 6403;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "auto_on" }') ORDER BY 1;
\d documentdb_data.documents_6403

-- A collection created with the GUC off behaves as before (no stats).
SELECT documentdb_api.create_collection('stats_db', 'auto_off2');
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "auto_off2" }') ORDER BY 1;
\d documentdb_data.documents_6404

-- Toggling the new GUC on does NOT retroactively enable stats on an existing
-- collection (the GUC only takes effect at create_collection time).
set documentdb.enablePlannerStatisticsNewCollections to on;
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "auto_off" }') ORDER BY 1;
\d documentdb_data.documents_6402

-- The new GUC alone does not enable on-demand coll_mod stats management.
-- That continues to require enablePerCollectionPlannerStatistics.
set documentdb.enablePerCollectionPlannerStatistics to off;
SELECT documentdb_api.coll_mod('stats_db', 'auto_off', '{ "collMod": "auto_off", "enableStats": true }');

-- Custom planner stats only take effect at query time when
-- enablePerCollectionPlannerStatistics is also on. Verify the same dataset
-- yields different plans depending on that GUC.
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "auto_on", "indexes": [ { "key": { "x": 1 }, "name": "x_1" } ] }', TRUE);
SELECT COUNT(documentdb_api.insert_one('stats_db', 'auto_on', bson_build_document('_id', i, 'x', 1, 'y', i, 'padding', repeat('q', 1010)))) FROM generate_series(1, 1000) i;
SELECT COUNT(documentdb_api.insert_one('stats_db', 'auto_on', bson_build_document('_id', i, 'x', i, 'y', i, 'padding', repeat('q', 1010)))) FROM generate_series(1001, 1010) i;
ANALYZE documentdb_data.documents_6403;
set documentdb.enableCompositeIndexPlanner to on;

-- per-collection GUC off: planner ignores custom stats and picks the index.
set documentdb.enablePerCollectionPlannerStatistics to off;
-- Bitmap scans are disabled so the plan shape is a stable index scan across PG versions.
set enable_bitmapscan to off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "auto_on", "filter": { "x": 1 } }');
reset enable_bitmapscan;

-- per-collection GUC on: planner consults custom stats and picks a seq scan.
set documentdb.enablePerCollectionPlannerStatistics to on;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "auto_on", "filter": { "x": 1 } }');

-- Expression stats objects exist on the auto-enabled collection.
SELECT statistics_name, exprs FROM pg_stats_ext WHERE tablename = 'documents_6403' ORDER BY statistics_name;

-- A collection created with the GUC off has no expression stats objects, even
-- after enabling the per-collection GUC.
SELECT statistics_name, exprs FROM pg_stats_ext WHERE tablename = 'documents_6402' ORDER BY statistics_name;

RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enableCompositeIndexPlanner;

------------------------------------------------------------------------------
-- Sparse $exists selectivity + covering composite index selection.
--
-- Summary of the behavior being locked in:
--   * An absent field projects an explicit null into the collected statistics
--     (see the bson_stats_project cases above), so a field that is present on
--     only a tiny fraction of rows shows that fraction in its statistics.
--   * As a result, a sparse "$exists: true" predicate is estimated with its
--     true (tiny) presence fraction rather than ~1.0.
--   * Composite-index correlation is sourced from the collected statistics as
--     well, so the covering index is not penalized with a hardcoded-zero
--     correlation.
--
-- The proof is the selectivity the planner actually assigns, read directly from
-- the extended EXPLAIN cost line (selectivity=...). A sparse "$exists: true" is
-- estimated as tiny (matching the true presence fraction), while a dense
-- "$exists: true" on an always-present field is estimated near 1.0. Because the
-- sparse selectivity is tiny, the covering (a, b, c) index becomes the cheapest
-- plan on its own cost and is chosen with no hint, pushing all three predicates.
--
-- Extremes are chosen so the fingerprint is decisive and stable: the field 'c'
-- exists on only 5 of 2005 rows (~0.25%), so its projected statistics carry an
-- explicit null MCV entry that drives the small $exists selectivity, while 'b'
-- is present on every row (dense).
------------------------------------------------------------------------------
set documentdb.enablePerCollectionPlannerStatistics to on;
set documentdb.enablePlannerStatisticsNewCollections to on;
set documentdb.enableCompositeIndexPlanner to on;

-- Helper: run an EXPLAIN and classify the estimated selectivity that the
-- planner assigned to a named index into coarse, environment-stable buckets so
-- the assertion does not depend on exact float formatting or PG version.
CREATE SCHEMA sparse_exists_helpers;
CREATE FUNCTION sparse_exists_helpers.classify_index_selectivity(p_query text, p_index text) RETURNS text
 LANGUAGE plpgsql AS $$
DECLARE
    v_row text;
    v_sel numeric;
BEGIN
    FOR v_row IN EXECUTE p_query
    LOOP
        IF v_row LIKE '%' || p_index || ': (startup cost=%selectivity=%' THEN
            v_sel := substring(v_row from 'selectivity=([0-9.eE+-]+)')::numeric;
            IF v_sel < 0.001 THEN
                RETURN p_index || ': very selective (selectivity < 0.001)';
            ELSIF v_sel < 0.5 THEN
                RETURN p_index || ': moderately selective (0.001 <= selectivity < 0.5)';
            ELSE
                RETURN p_index || ': not selective (selectivity >= 0.5)';
            END IF;
        END IF;
    END LOOP;
    RETURN 'index ' || p_index || ' not found in EXPLAIN output';
END;
$$;

SELECT documentdb_api.create_collection('stats_db', 'sparse_exists');

-- A covering composite index over (a, b, c) and a single-column competitor
-- over (a).
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "sparse_exists", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_b_c_1" } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "sparse_exists", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', TRUE);

-- 2000 rows without 'c' (10 distinct 'a' values, 200 rows each; 'b' 0..99),
-- then 5 rows that carry 'c'.
SELECT COUNT(documentdb_api.insert_one('stats_db', 'sparse_exists', bson_build_document('_id', i, 'a', ((i - 1) / 200), 'b', ((i - 1) % 100), 'padding', repeat('x', 1010)))) FROM generate_series(1, 2000) i;
SELECT COUNT(documentdb_api.insert_one('stats_db', 'sparse_exists', bson_build_document('_id', 3000 + i, 'a', 0, 'b', i, 'c', 1, 'padding', repeat('x', 1010)))) FROM generate_series(1, 5) i;
ANALYZE documentdb_data.documents_6405;

-- The projected statistics for the sparse field 'c' capture absence as an
-- explicit null MCV entry (n_distinct = 2: the null and the single present
-- value), which is what drives the small $exists selectivity.
SELECT expr, null_frac, n_distinct, (most_common_vals::text::bson[]) AS mcv
FROM pg_stats_ext_exprs WHERE tablename = 'documents_6405' AND expr LIKE '%''c''%';

-- Direct proof of the fix: read the selectivity the planner assigns to the
-- covering (a, b, c) index from the extended EXPLAIN cost line.
--   * A sparse "$exists: true" on 'c' (present on ~0.25% of rows) is estimated
--     as very selective (selectivity < 0.001) - i.e. the true presence
--     fraction, not ~1.0.
--   * A dense "$exists: true" on 'b' (present on every row) is estimated as not
--     selective (selectivity >= 0.5).
set documentdb.enableExplainScanIndexCosts to on;
set documentdb.enableExtendedExplainPlans to on;

SELECT sparse_exists_helpers.classify_index_selectivity($cmd$
    EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "sparse_exists", "filter": { "a": 0, "c": { "$exists": true } } }');
$cmd$, 'a_b_c_1');

SELECT sparse_exists_helpers.classify_index_selectivity($cmd$
    EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "sparse_exists", "filter": { "a": 0, "b": { "$exists": true } } }');
$cmd$, 'a_b_c_1');

reset documentdb.enableExplainScanIndexCosts;
reset documentdb.enableExtendedExplainPlans;

-- End-to-end effect: because the sparse $exists is estimated as very selective,
-- the covering (a, b, c) index is the cheapest plan on its own cost and is
-- chosen with no hint, pushing all three predicates - including the sparse
-- $exists - as Index Cond with no runtime filter on 'b' or 'c'. Bitmap scans are
-- disabled here so the plan shape is a stable index scan across PG versions.
set enable_bitmapscan to off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "sparse_exists", "filter": { "a": 0, "b": { "$lte": 50 }, "c": { "$exists": true } } }');
reset enable_bitmapscan;

RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enableCompositeIndexPlanner;
DROP SCHEMA sparse_exists_helpers CASCADE;