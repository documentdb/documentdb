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

-- print list_indexes to see that the option is set
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

-- sort of works for top level arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1, "b": { "c": [ 1, 2, 3 ] } }', 'b.c');

-- doesn't really work for parent arrays
SELECT documentdb_api_internal.bson_stats_project('{ "a": 1, "b": [ { "c": 1 }, { "c": 2 } ] }', 'b.c');

-- now test the stats usage.
SELECT COUNT(documentdb_api.insert_one('stats_db', 'planner_stats', bson_build_document('_id', i, 'b', 1, 'c', i, 'padding', repeat('x', 1010)))) FROM generate_series(1, 1000) i;
SELECT COUNT(documentdb_api.insert_one('stats_db', 'planner_stats', bson_build_document('_id', i, 'b', i, 'c', i, 'padding', repeat('x', 1010)))) FROM generate_series(1, 10) i;

-- the selectivity for 'b': 1 is ~50% - without custom stats it assumes that it's 1% and it should pick the index on b,c
ANALYZE documentdb_data.documents_6401;
set documentdb.enableCompositeIndexPlanner to on;
set documentdb.enablePerCollectionPlannerStatistics to off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "planner_stats", "filter": { "b": 1 } }');

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