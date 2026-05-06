SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, documentdb_api_internal, public;
SET citus.next_shard_id TO 740000;
SET documentdb.next_collection_id TO 7400;
SET documentdb.next_collection_index_id TO 7400;

-- create a collection
SELECT documentdb_api.create_collection('stats_db', 'planner_stats');

\d documentdb_data.documents_7401

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

\d documentdb_data.documents_7401

-- it's also on the shard table
\d documentdb_data.documents_7401_740002

-- dropping the index should remove the stats.
CALL documentdb_api.drop_indexes('stats_db', '{ "dropIndexes": "planner_stats", "index": "a_1" }');

\d documentdb_data.documents_7401
-- it's also removed on the shard table
\d documentdb_data.documents_7401_740002

-- now test the stats usage.
SELECT COUNT(documentdb_api.insert_one('stats_db', 'planner_stats', bson_build_document('_id', i, 'b', 1, 'c', i, 'padding', repeat('x', 1010)))) FROM generate_series(1, 1000) i;
SELECT COUNT(documentdb_api.insert_one('stats_db', 'planner_stats', bson_build_document('_id', i, 'b', i, 'c', i, 'padding', repeat('x', 1010)))) FROM generate_series(1, 10) i;

-- the selectivity for 'b': 1 is ~50% - without custom stats it assumes that it's 1% and it should pick the index on b,c
ANALYZE documentdb_data.documents_7401;
set documentdb.enableCompositeIndexPlanner to on;
set documentdb.enablePerCollectionPlannerStatistics to off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "planner_stats", "filter": { "b": 1 } }');

-- with stats on this is now correctly reflected and will pick a seqscan.
set documentdb.enablePerCollectionPlannerStatistics to on;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('stats_db', '{ "find": "planner_stats", "filter": { "b": 1 } }');

-- now shard the collection.
SELECT documentdb_api.shard_collection('{ "shardCollection": "stats_db.planner_stats", "key": { "_id": "hashed" } }');

set citus.show_shards_for_app_name_prefixes to '*';
\d documentdb_data.documents_7401
\d documentdb_data.documents_7401_740004

SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "planner_stats" }') ORDER BY 1;

------------------------------------------------------------------------------
-- Tests for documentdb.enablePlannerStatisticsNewCollections in the
-- distributed flow.
------------------------------------------------------------------------------
RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enablePlannerStatisticsNewCollections;

-- With the new GUC on, create_collection auto-enables stats.
set documentdb.enablePlannerStatisticsNewCollections to on;
SELECT documentdb_api.create_collection('stats_db', 'auto_dist');
SELECT collection_id AS auto_dist_id FROM documentdb_api_catalog.collections WHERE database_name = 'stats_db' AND collection_name = 'auto_dist' \gset

-- listIndexes shows statsEnabled=true on the _id_ index.
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "auto_dist" }') ORDER BY 1;

-- Add a compound index so a stats object is materialized before sharding.
SELECT documentdb_api_internal.create_indexes_non_concurrently('stats_db', '{ "createIndexes": "auto_dist", "indexes": [ { "key": { "p": 1, "q": 1 }, "name": "p_q_1" } ] }', TRUE);
\d documentdb_data.documents_:auto_dist_id

-- Sharding the collection. With the new GUC still on, stats are preserved
-- on the parent table and the new shard tables (the OR with the per-collection
-- GUC in ShardCollectionCore lets the new GUC keep stats across sharding).
SELECT documentdb_api.shard_collection('{ "shardCollection": "stats_db.auto_dist", "key": { "_id": "hashed" } }');
\d documentdb_data.documents_:auto_dist_id

-- listIndexes still reports statsEnabled=true after sharding.
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "auto_dist" }') ORDER BY 1;

-- Turning the new GUC off and sharding a *different* collection that was
-- created with the GUC off does not enable stats. Sharding here is a no-op
-- for stats since the collection never had them enabled.
set documentdb.enablePlannerStatisticsNewCollections to off;
SELECT documentdb_api.create_collection('stats_db', 'no_stats_dist');
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "no_stats_dist" }') ORDER BY 1;
SELECT documentdb_api.shard_collection('{ "shardCollection": "stats_db.no_stats_dist", "key": { "_id": "hashed" } }');
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('stats_db', '{ "listIndexes": "no_stats_dist" }') ORDER BY 1;

RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enablePlannerStatisticsNewCollections;
