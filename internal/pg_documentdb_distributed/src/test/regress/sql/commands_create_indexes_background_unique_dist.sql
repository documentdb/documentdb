SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 198450000;
SET documentdb.next_collection_id TO 1984500;
SET documentdb.next_collection_index_id TO 1984500;

-- Delete all old create index requests from other tests
DELETE from documentdb_api_catalog.documentdb_index_queue;

-- Disable the background index build cron job so we control execution manually
SELECT documentdb_distributed_test_helpers.change_index_jobs_status(false);

-- Enable the feature flag
SET documentdb.enableNonBlockingUniqueIndexBuild TO true;

------------------------------------------------------------
-- Test 1: Background unique index on unsharded collection
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_dist_db', 'unshard_unique');
SELECT COUNT(documentdb_api.insert_one('bg_unique_dist_db', 'unshard_unique', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

-- Create unique index in background (must be ordered/composite for non-blocking build)
SELECT documentdb_api.create_indexes_background('bg_unique_dist_db',
  '{ "createIndexes": "unshard_unique", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }');

-- Capture the index_id for verification
SELECT max(index_id) AS test1_index_id FROM documentdb_api_catalog.documentdb_index_queue \gset

-- Process the index build queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify queue is empty for this index
SELECT count(*) FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id = :test1_index_id;

-- Verify uniqueness is enforced
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'unshard_unique', '{"_id": 100, "a": 1}');

-- Verify non-duplicate succeeds
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'unshard_unique', '{"_id": 101, "a": 100}');

------------------------------------------------------------
-- Test 2: Background unique index on sharded collection
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_dist_db', 'shard_unique');
SELECT COUNT(documentdb_api.insert_one('bg_unique_dist_db', 'shard_unique', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

-- Shard on the unique field so duplicates land on the same shard
SELECT documentdb_api.shard_collection('{ "shardCollection": "bg_unique_dist_db.shard_unique", "key": { "a": "hashed" }, "numInitialChunks": 3 }');

-- Create unique index in background on sharded collection
SELECT documentdb_api.create_indexes_background('bg_unique_dist_db',
  '{ "createIndexes": "shard_unique", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }');

-- Capture the index_id for verification
SELECT max(index_id) AS test2_index_id FROM documentdb_api_catalog.documentdb_index_queue \gset

-- Process the index build queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify queue is empty for this index
SELECT count(*) FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id = :test2_index_id;

-- Verify uniqueness is enforced on sharded collection
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'shard_unique', '{"_id": 100, "a": 1}');

-- Verify non-duplicate succeeds
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'shard_unique', '{"_id": 101, "a": 100}');

------------------------------------------------------------
-- Test 3: Background unique index with duplicates on UNSHARDED collection
-- Verifies that when duplicates exist, the index build fails and the
-- physical index is properly cleaned up.
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_dist_db', 'unshard_dup');
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'unshard_dup', '{"_id": 1, "a": 50}');
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'unshard_dup', '{"_id": 2, "a": 50}');

-- Create unique index — should fail during post-processing due to duplicates
SELECT documentdb_api.create_indexes_background('bg_unique_dist_db',
  '{ "createIndexes": "unshard_dup", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unshard_dup", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }');

-- Capture the index_id for verification
SELECT max(index_id) AS test3_index_id FROM documentdb_api_catalog.documentdb_index_queue \gset

-- Process the index build queue (will fail during post-processing)
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- The index build should have failed; verify only _id_ index exists in the catalog
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('bg_unique_dist_db', '{ "listIndexes": "unshard_dup" }');

-- Verify the failed entry is marked as skippable
SELECT index_cmd_status FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id = :test3_index_id;

-- \d to confirm physical index is cleaned up
\d documentdb_data.documents_1984503

------------------------------------------------------------
-- Test 4: Background unique index with duplicates on sharded collection
-- Verifies that when a shard has duplicates, the index build fails
-- and the index is rolled back on ALL shards (not just the failed one).
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_dist_db', 'shard_dup');
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'shard_dup', '{"_id": 1, "a": 100}');
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'shard_dup', '{"_id": 2, "a": 100}');

-- Shard on the unique field so duplicates land on the same shard (2 chunks only)
SELECT documentdb_api.shard_collection('{ "shardCollection": "bg_unique_dist_db.shard_dup", "key": { "a": "hashed" }, "numInitialChunks": 2 }');

-- Create unique index — should fail during post-processing due to duplicates
SELECT documentdb_api.create_indexes_background('bg_unique_dist_db',
  '{ "createIndexes": "shard_dup", "indexes": [ { "key": { "a": 1 }, "name": "a_1_dup", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }');

-- Capture the index_id for verification
SELECT max(index_id) AS test4_index_id FROM documentdb_api_catalog.documentdb_index_queue \gset

-- Process the index build queue (will fail during post-processing)
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- The index build should have failed; verify only _id_ index exists in the catalog
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('bg_unique_dist_db', '{ "listIndexes": "shard_dup" }');

-- Verify the failed entry is marked as skippable
SELECT index_cmd_status FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id = :test4_index_id;

-- Check that the index is rolled back on ALL shards (both shard tables)
SET citus.show_shards_for_app_name_prefixes TO '*';
\d documentdb_data.documents_1984504_198450013
\d documentdb_data.documents_1984504_198450014
RESET citus.show_shards_for_app_name_prefixes;

------------------------------------------------------------
-- Test 5: Background unique compound index on sharded collection
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_dist_db', 'shard_compound');
SELECT COUNT(documentdb_api.insert_one('bg_unique_dist_db', 'shard_compound', FORMAT('{"_id": %s, "x": %s, "y": %s}', i, i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

-- Shard on one of the compound key fields so duplicates land on the same shard
SELECT documentdb_api.shard_collection('{ "shardCollection": "bg_unique_dist_db.shard_compound", "key": { "x": "hashed" }, "numInitialChunks": 3 }');

SELECT documentdb_api.create_indexes_background('bg_unique_dist_db',
  '{ "createIndexes": "shard_compound", "indexes": [ { "key": { "x": 1, "y": 1 }, "name": "xy_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }');

-- Capture the index_id for verification
SELECT max(index_id) AS test5_index_id FROM documentdb_api_catalog.documentdb_index_queue \gset

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify queue entry is consumed for the compound unique index
SELECT count(*) FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id = :test5_index_id;

-- Verify compound uniqueness is enforced
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'shard_compound', '{"_id": 100, "x": 1, "y": 1}');

-- Verify different compound key succeeds
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'shard_compound', '{"_id": 101, "x": 1, "y": 100}');

------------------------------------------------------------
-- Test 6: Inline unique index creation when collection does not exist
-- When create_indexes_background auto-creates a collection, the index
-- should be built inline (blocking) regardless of the GUC, to avoid
-- the overhead of the background queue.
-- We set the failure injection GUC to prove the background post-processing
-- path is never reached (if it were, the failure would trigger an error).
------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 1;

-- Capture queue count before
SELECT count(*) as queue_before FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984500 \gset

SELECT documentdb_api.create_indexes_background('bg_unique_dist_db',
  '{ "createIndexes": "inline_new_coll", "indexes": [ { "key": { "x": 1 }, "name": "x_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }');

-- Verify no new entry was added to the queue (index was built inline, not queued)
SELECT count(*) as queue_after FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984500 \gset
SELECT :queue_before = :queue_after AS no_new_queue_entry;

-- Verify uniqueness is enforced immediately (no build_index_concurrently needed)
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'inline_new_coll', '{"_id": 1, "x": 1}');
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'inline_new_coll', '{"_id": 2, "x": 1}');

-- Verify non-duplicate succeeds
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'inline_new_coll', '{"_id": 3, "x": 99}');

SET documentdb.indexBuildFailurePoint TO 0;

------------------------------------------------------------
-- Test 7: Non-background (blocking) unique index on sharded collection
-- Verifies that uniqueness is enforced per-shard only (not cross-shard)
-- when using the traditional blocking unique index build path.
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_dist_db', 'shard_blocking');
SELECT COUNT(documentdb_api.insert_one('bg_unique_dist_db', 'shard_blocking', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

-- Shard on _id (NOT on the unique key field) so same 'a' values may land on different shards
SELECT documentdb_api.shard_collection('{ "shardCollection": "bg_unique_dist_db.shard_blocking", "key": { "_id": "hashed" }, "numInitialChunks": 3 }');

-- Create unique ordered index using the foreground (blocking) path — goes through ALTER TABLE ADD CONSTRAINT
SELECT documentdb_api_internal.create_indexes_non_concurrently('bg_unique_dist_db',
  '{ "createIndexes": "shard_blocking", "indexes": [ { "key": { "a": 1 }, "name": "a_1_blocking_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }', true);

-- Uniqueness is per-shard: a duplicate 'a' value with a different _id may succeed
-- because the documents can land on different shards
SELECT documentdb_api.insert_one('bg_unique_dist_db', 'shard_blocking', '{"_id": 100, "a": 1}');

-- Clean up queue at end of test
DELETE FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 1984500;
