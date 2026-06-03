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
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "auto_on", "filter": { "x": 1 } }');

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