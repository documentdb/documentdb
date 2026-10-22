SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog;
SET documentdb.next_collection_id TO 25703000;
SET documentdb.next_collection_index_id TO 25703000;

-- Delete all old create index requests from other tests
DELETE from documentdb_api_catalog.documentdb_index_queue;

SET documentdb.enableUniqueReindex TO true;

------------------------------------------------------------
-- Setup: Create a collection with data and a unique index
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_db', 'reindex_unique_coll');
SELECT COUNT(documentdb_api.insert_one('reindex_db', 'reindex_unique_coll', FORMAT('{"_id": %s, "a": %s, "b": %s}', i, i, i)::documentdb_core.bson)) FROM generate_series(1, 20) i;

-- Create a unique index
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_db',
  '{ "createIndexes": "reindex_unique_coll", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true } ] }', true);

-- Create a non-unique index for comparison
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_db',
  '{ "createIndexes": "reindex_unique_coll", "indexes": [ { "key": { "b": 1 }, "name": "b_1" } ] }', true);

-- Verify indexes before reindex
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('reindex_db', '{ "listIndexes": "reindex_unique_coll" }');

------------------------------------------------------------
-- Error case: reindex must be true
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": false } }');

------------------------------------------------------------
-- Error case: index not found
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "nonexistent_idx", "reindex": true } }');

------------------------------------------------------------
-- Error case: reindex of unique index when feature is disabled
------------------------------------------------------------
SET documentdb.enableUniqueReindex TO false;
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": true } }');
SET documentdb.enableUniqueReindex TO true;

------------------------------------------------------------
-- Error case: reindex combined with other options
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": true, "hidden": true } }');

------------------------------------------------------------
-- Error case: updateOptions requires reindex
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "updateOptions": true } }');

-- Capture collection_id for \d checks
SELECT collection_id as unique_coll_id FROM documentdb_api_catalog.collections WHERE database_name = 'reindex_db' AND collection_name = 'reindex_unique_coll' \gset

-- Show table state before any reindex
\d documentdb_data.documents_:unique_coll_id

-- Show constraints before any reindex (only stable fields, no OIDs)
SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :unique_coll_id)::regclass
  AND contype IN ('p', 'x')
ORDER BY conname;

------------------------------------------------------------
-- Reindex a unique index via collMod
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "a_1_unique", "reindex": true } }');

-- Verify the reindex request is in the queue
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- Process the reindex queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the queue is empty after processing
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- Verify no _ccold/_ccnew artifacts remain and constraint is intact
\d documentdb_data.documents_:unique_coll_id

-- Verify only expected constraints exist (no _ccold/_ccnew constraint artifacts)
SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :unique_coll_id)::regclass
  AND contype IN ('p', 'x')
ORDER BY conname;

-- Verify the unique index still exists and is valid
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('reindex_db', '{ "listIndexes": "reindex_unique_coll" }');

-- Verify uniqueness constraint still works after reindex (duplicate should fail)
SELECT documentdb_api.insert_one('reindex_db', 'reindex_unique_coll', '{"_id": 100, "a": 1}');

-- Verify the reindexed unique index is used for queries
SET enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('reindex_db', '{ "find": "reindex_unique_coll", "filter": { "a": 5 } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('reindex_db', '{ "find": "reindex_unique_coll", "filter": { "a": 5 } }');
RESET enable_seqscan;

------------------------------------------------------------
-- Reindex a non-unique index via collMod (for comparison)
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "b_1", "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

------------------------------------------------------------
-- Reindex _id_ unique index via keyPattern
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "keyPattern": { "_id": 1 }, "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- Verify no _ccold/_ccnew artifacts remain after _id reindex and primary key is intact
\d documentdb_data.documents_:unique_coll_id

-- Verify only expected constraints exist after _id reindex (no _ccold/_ccnew artifacts)
SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :unique_coll_id)::regclass
  AND contype IN ('p', 'x')
ORDER BY conname;

-- Verify _id index still works after reindex
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('reindex_db', '{ "find": "reindex_unique_coll", "filter": { "_id": 10 } }');

------------------------------------------------------------
-- Error case: reindex with updateOptions is not supported for the _id_ index
-- (its opclass options are fixed and must not be regenerated). Both the
-- name-based and keyPattern-based forms must be rejected, and nothing should be
-- queued.
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "name": "_id_", "reindex": true, "updateOptions": true } }');
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "keyPattern": { "_id": 1 }, "reindex": true, "updateOptions": true } }');
-- The queue must be empty: the rejected requests were never enqueued.
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

------------------------------------------------------------
-- Reindex unique index via collMod using keyPattern
------------------------------------------------------------
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_coll', '{ "collMod": "reindex_unique_coll", "index": { "keyPattern": { "a": 1 }, "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- Verify data still accessible and unique constraint intact
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('reindex_db', '{ "find": "reindex_unique_coll", "filter": { "a": 5 } }');
SELECT documentdb_api.insert_one('reindex_db', 'reindex_unique_coll', '{"_id": 101, "a": 2}');

------------------------------------------------------------
-- Test with compound unique index
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_db', 'reindex_compound_unique');
SELECT COUNT(documentdb_api.insert_one('reindex_db', 'reindex_compound_unique', FORMAT('{"_id": %s, "x": %s, "y": %s}', i, i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_db',
  '{ "createIndexes": "reindex_compound_unique", "indexes": [ { "key": { "x": 1, "y": 1 }, "name": "xy_unique", "unique": true } ] }', true);

-- Reindex the compound unique index
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_compound_unique', '{ "collMod": "reindex_compound_unique", "index": { "name": "xy_unique", "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- Verify uniqueness still works on compound index
SELECT documentdb_api.insert_one('reindex_db', 'reindex_compound_unique', '{"_id": 100, "x": 1, "y": 1}');

-- Verify the index is used
SET enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('reindex_db', '{ "find": "reindex_compound_unique", "filter": { "x": 5, "y": 5 } }');
RESET enable_seqscan;

------------------------------------------------------------
-- Test with shard_collection (sharded unique index reindex)
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_db', 'reindex_unique_sharded');
SELECT COUNT(documentdb_api.insert_one('reindex_db', 'reindex_unique_sharded', FORMAT('{"_id": %s, "a": %s, "b": %s}', i, i, i)::documentdb_core.bson)) FROM generate_series(1, 20) i;

-- Create a unique index before sharding
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_db',
  '{ "createIndexes": "reindex_unique_sharded", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true } ] }', true);

-- Shard the collection
SELECT documentdb_api.shard_collection('reindex_db', 'reindex_unique_sharded', '{ "a": "hashed" }', false);

-- Reindex the unique index on the sharded collection via collMod
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_sharded', '{ "collMod": "reindex_unique_sharded", "index": { "name": "a_1_unique", "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- Verify uniqueness still works after sharded reindex
SELECT documentdb_api.insert_one('reindex_db', 'reindex_unique_sharded', '{"_id": 100, "a": 1}');

-- Verify data is accessible
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('reindex_db', '{ "find": "reindex_unique_sharded", "filter": { "a": 10 } }');

-- Reindex the _id_ index on the sharded collection
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_unique_sharded', '{ "collMod": "reindex_unique_sharded", "index": { "keyPattern": { "_id": 1 }, "reindex": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- Verify indexes after all reindex operations
SELECT documentdb_api_catalog.bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('reindex_db', '{ "listIndexes": "reindex_unique_sharded" }');

------------------------------------------------------------
-- Test: skipIndexCleanupOnReindex leaves old index behind
------------------------------------------------------------
SELECT documentdb_api.create_collection('reindex_db', 'reindex_skip_cleanup');
SELECT COUNT(documentdb_api.insert_one('reindex_db', 'reindex_skip_cleanup', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_db',
  '{ "createIndexes": "reindex_skip_cleanup", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true } ] }', true);

-- Show table state before reindex
SELECT collection_id as skip_cleanup_collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'reindex_db' AND collection_name = 'reindex_skip_cleanup' \gset
\d documentdb_data.documents_:skip_cleanup_collection_id

-- Set the GUC to skip cleanup of old index after reindex
SET documentdb.skipIndexCleanupOnReindex TO true;

-- Reindex the unique index
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_skip_cleanup', '{ "collMod": "reindex_skip_cleanup", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- The old index (_ccold) should still be present on the table
\d documentdb_data.documents_:skip_cleanup_collection_id

RESET documentdb.skipIndexCleanupOnReindex;

------------------------------------------------------------
-- Test: reindex via create with planner statistics enabled moves the
-- statistics dependency to the rebuilt index so the old index can be dropped
-- concurrently.
------------------------------------------------------------
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SELECT documentdb_api.create_collection('reindex_db', 'reindex_with_stats');
SELECT COUNT(documentdb_api.insert_one('reindex_db', 'reindex_with_stats', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "enableStats": true }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_db',
  '{ "createIndexes": "reindex_with_stats", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', true);

SELECT collection_id as stats_coll_id FROM documentdb_api_catalog.collections WHERE database_name = 'reindex_db' AND collection_name = 'reindex_with_stats' \gset

-- The statistics object depends on the index
SELECT s.stxname, d.refobjid::regclass AS depends_on_index, d.deptype
FROM pg_statistic_ext s JOIN pg_depend d ON d.classid = 'pg_statistic_ext'::regclass AND d.objid = s.oid AND d.refclassid = 'pg_class'::regclass
JOIN pg_class c ON c.oid = d.refobjid AND c.relkind = 'i'
WHERE s.stxrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass ORDER BY 1;

-- Reindex via create (updateOptions) renames the old index to _ccold and drops it concurrently
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "index": { "name": "a_1", "reindex": true, "updateOptions": true } }');
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25703000 AND index_id <= 25703100 ORDER BY index_id;

-- The old _ccold index is gone and the statistics object now depends on the rebuilt index
\d documentdb_data.documents_:stats_coll_id
SELECT s.stxname, d.refobjid::regclass AS depends_on_index, d.deptype
FROM pg_statistic_ext s JOIN pg_depend d ON d.classid = 'pg_statistic_ext'::regclass AND d.objid = s.oid AND d.refclassid = 'pg_class'::regclass
JOIN pg_class c ON c.oid = d.refobjid AND c.relkind = 'i'
WHERE s.stxrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass ORDER BY 1;

-- A plain reindex of a non-unique index uses REINDEX CONCURRENTLY and leaves no _ccold index
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "index": { "name": "a_1", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT COUNT(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass AND c.relname LIKE '%_ccold';
SELECT s.stxname, d.refobjid::regclass AS depends_on_index, d.deptype
FROM pg_statistic_ext s JOIN pg_depend d ON d.classid = 'pg_statistic_ext'::regclass AND d.objid = s.oid AND d.refclassid = 'pg_class'::regclass
JOIN pg_class c ON c.oid = d.refobjid AND c.relkind = 'i'
WHERE s.stxrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass ORDER BY 1;

-- A plain reindex of a unique index rebuilds via create and drops the _ccold index
SELECT documentdb_api_internal.create_indexes_non_concurrently('reindex_db',
  '{ "createIndexes": "reindex_with_stats", "indexes": [ { "key": { "a": -1 }, "name": "a_-1_unique", "unique": true } ] }', true);
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "index": { "name": "a_-1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT COUNT(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass AND c.relname LIKE '%_ccold';
SELECT s.stxname, d.refobjid::regclass AS depends_on_index, d.deptype
FROM pg_statistic_ext s JOIN pg_depend d ON d.classid = 'pg_statistic_ext'::regclass AND d.objid = s.oid AND d.refclassid = 'pg_class'::regclass
JOIN pg_class c ON c.oid = d.refobjid AND c.relkind = 'i'
WHERE s.stxrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass ORDER BY 1;
CALL documentdb_api.drop_indexes('reindex_db', '{ "dropIndexes": "reindex_with_stats", "index": "a_-1_unique" }');

-- A _ccold index left behind by a reindex via create can be dropped concurrently by hand
SET documentdb.skipIndexCleanupOnReindex TO true;
SELECT documentdb_api.coll_mod('reindex_db', 'reindex_with_stats', '{ "collMod": "reindex_with_stats", "index": { "name": "a_1", "reindex": true, "updateOptions": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
RESET documentdb.skipIndexCleanupOnReindex;
SELECT 'documentdb_data.documents_rum_index_' || index_id || '_ccold' AS ccold_index_name
FROM documentdb_api_catalog.collection_indexes WHERE collection_id = :stats_coll_id AND (index_spec).index_name = 'a_1' \gset
SELECT COUNT(*) FROM pg_class WHERE oid = to_regclass(:'ccold_index_name');
DROP INDEX CONCURRENTLY :ccold_index_name;
\d documentdb_data.documents_:stats_coll_id
SELECT s.stxname, d.refobjid::regclass AS depends_on_index, d.deptype
FROM pg_statistic_ext s JOIN pg_depend d ON d.classid = 'pg_statistic_ext'::regclass AND d.objid = s.oid AND d.refclassid = 'pg_class'::regclass
JOIN pg_class c ON c.oid = d.refobjid AND c.relkind = 'i'
WHERE s.stxrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass ORDER BY 1;

-- Dropping the rebuilt index still removes the statistics object
CALL documentdb_api.drop_indexes('reindex_db', '{ "dropIndexes": "reindex_with_stats", "index": "a_1" }');
SELECT COUNT(*) FROM pg_statistic_ext WHERE stxrelid = ('documentdb_data.documents_' || :stats_coll_id)::regclass;
RESET documentdb.enablePerCollectionPlannerStatistics;
