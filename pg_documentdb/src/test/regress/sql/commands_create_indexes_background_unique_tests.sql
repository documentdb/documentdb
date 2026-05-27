SET documentdb.next_collection_id TO 25710000;
SET documentdb.next_collection_index_id TO 25710000;

SET search_path to documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- Disable cron jobs to prevent interference since we call build_index directly
SELECT documentdb_test_helpers.change_index_jobs_status(false);

-- Delete all old create index requests from other tests
DELETE from documentdb_api_catalog.documentdb_index_queue;

-- Enable the feature flag for background unique index builds
SET documentdb.enableNonBlockingUniqueIndexBuild TO true;

-------------------------------------------------------------------
-- Test 1: Background unique index build with no duplicates
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_1', '{"_id": 1, "a": 10}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_1', '{"_id": 2, "a": 20}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_1', '{"_id": 3, "a": 30}', NULL);

-- Queue the index build request
SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_1", "indexes": [{"key": {"a": 1}, "name": "idx_a_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);

-- Process the queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the index exists and is unique
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_1') ORDER BY 1,2;

-- Verify uniqueness is enforced: insert a duplicate value for 'a'
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_1', '{"_id": 4, "a": 10}', NULL);

-------------------------------------------------------------------
-- Test 2: Background unique index build with pre-existing duplicates
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_2', '{"_id": 1, "a": 100}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_2', '{"_id": 2, "a": 100}', NULL);

-- Queue the index build (will fail during post-processing - table walk finds duplicates)
SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_2", "indexes": [{"key": {"a": 1}, "name": "idx_a_dup", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);

-- Process the queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- The index should NOT exist since duplicates were found
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_2') ORDER BY 1,2;

-------------------------------------------------------------------
-- Test 3: Background unique compound index build
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_3', '{"_id": 1, "a": 1, "b": "x"}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_3', '{"_id": 2, "a": 1, "b": "y"}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_3', '{"_id": 3, "a": 2, "b": "x"}', NULL);

-- Queue the index build
SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_3", "indexes": [{"key": {"a": 1, "b": 1}, "name": "idx_ab_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);

-- Process the queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the index exists
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_3') ORDER BY 1,2;

-- Verify uniqueness is enforced: duplicate compound key
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_3', '{"_id": 4, "a": 1, "b": "x"}', NULL);

-- Verify non-duplicate compound key is allowed
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_3', '{"_id": 5, "a": 1, "b": "z"}', NULL);

-------------------------------------------------------------------
-- Test 4: Inline unique index creation when collection does not exist
-- When create_indexes_background auto-creates a collection, the index
-- should be built inline (blocking) regardless of the GUC, to avoid
-- the overhead of the background queue.
-- We set the failure injection GUC to prove the background post-processing
-- path is never reached (if it were, the failure would trigger an error).
-------------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 1;

-- Capture queue count before to prove no new entry is added
SELECT count(*) as queue_before FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25710000 \gset

SELECT documentdb_api.create_indexes_background('bg_uniq_db',
  '{ "createIndexes": "bg_unique_4_new", "indexes": [ { "key": { "x": 1 }, "name": "x_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }');

-- Verify no new entry was added to the queue (index was built inline, not queued)
SELECT count(*) as queue_after FROM documentdb_api_catalog.documentdb_index_queue WHERE index_id >= 25710000 \gset
SELECT :queue_before = :queue_after AS no_new_queue_entry;

-- Verify uniqueness is enforced immediately (no build_index_concurrently needed)
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_4_new', '{"_id": 1, "x": 1}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_4_new', '{"_id": 2, "x": 1}', NULL);

-- Verify non-duplicate succeeds
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_4_new', '{"_id": 3, "x": 99}', NULL);

-- Cleanup
-- Cleanup: remove queue entries for this test's collections
DELETE FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id IN (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name LIKE 'bg_unique_%');


-------------------------------------------------------------------
-- Test 5: Table walk SKIPPED — existing enableOrderedIndex:false unique index,
-- new enableOrderedIndex:true unique index on same key with a different name.
-- Both enforce the same uniqueness constraint (same key, same sparse,
-- same PFE = NULL). The table walk should be skipped because the
-- existing index already proves uniqueness.
-- We inject FP3 (after table walk) — if the skip works correctly,
-- FP3 is never reached and the build succeeds.
-------------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 0;
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_5', '{"_id": 1, "a": 1}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_5', '{"_id": 2, "a": 2}', NULL);

-- Create first unique index (explicitly non-ordered) successfully
SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_5", "indexes": [{"key": {"a": 1}, "name": "idx_a_first", "unique": true, "storageEngine": { "enableOrderedIndex": false }}] }'
);

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify first index is valid
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_5') ORDER BY 1,2;

-- Now set FP3 and create the second unique index (ordered) on same key.
-- If the table walk is skipped, FP3 will NOT fire and the build succeeds.
SET documentdb.indexBuildFailurePoint TO 3;

SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_5", "indexes": [{"key": {"a": 1}, "name": "idx_a_second", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Both indexes should exist (FP3 did NOT fire = table walk was skipped)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_5') ORDER BY 1,2;

-- Verify uniqueness is still enforced
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_5', '{"_id": 3, "a": 1}', NULL);

-- Cleanup: remove queue entries for this test's collections
DELETE FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id IN (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name LIKE 'bg_unique_%');


-------------------------------------------------------------------
-- Test 6: Table walk NOT skipped — different partial filter expression.
-- Even with same key and both unique, different PFE means different
-- document coverage, so uniqueness is not proven by the existing index.
-- The table walk must happen for the second index.
-- FP3 fires after the table walk, proving it was reached.
-------------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 0;
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_6', '{"_id": 1, "a": 1, "b": 1}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_6', '{"_id": 2, "a": 2, "b": 2}', NULL);

-- Create first unique index with a partial filter expression (no failure injection)
SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_6", "indexes": [{"key": {"a": 1}, "name": "idx_a_pfe_b_gt_0", "unique": true, "partialFilterExpression": {"b": {"$gt": 0}}, "storageEngine": { "enableOrderedIndex": true }}] }'
);

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify first index is valid (should have _id + idx_a_pfe_b_gt_0)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_6') ORDER BY 1,2;

-- Now set FP3 and create a unique index with a DIFFERENT PFE on same key.
-- The table walk must happen because the PFEs cover different subsets.
SET documentdb.indexBuildFailurePoint TO 3;

SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_6", "indexes": [{"key": {"a": 1}, "name": "idx_a_pfe_b_gt_5", "unique": true, "partialFilterExpression": {"b": {"$gt": 5}}, "storageEngine": { "enableOrderedIndex": true }}] }'
);

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- FP3 fired (table walk was reached), second index should NOT exist
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_6') ORDER BY 1,2;

-- Cleanup: remove queue entries for this test's collections
DELETE FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id IN (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name LIKE 'bg_unique_%');


-------------------------------------------------------------------
-- Test 7: Table walk NOT skipped — different sparse setting.
-- Existing: non-sparse unique index. New: sparse unique index.
-- Sparse indexes exclude null-valued documents, so the existing
-- non-sparse index does NOT prove uniqueness for the sparse subset.
-- FP3 fires after the table walk, proving it was reached.
-------------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 0;
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_7', '{"_id": 1, "a": 1}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_7', '{"_id": 2, "a": 2}', NULL);

-- Create non-sparse unique index (no failure injection)
SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_7", "indexes": [{"key": {"a": 1}, "name": "idx_a_nonsparse", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify it is valid
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_7') ORDER BY 1,2;

-- Create sparse unique index on same key — should do table walk
SET documentdb.indexBuildFailurePoint TO 3;

SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_7", "indexes": [{"key": {"a": 1}, "name": "idx_a_sparse", "unique": true, "sparse": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- FP3 fired (table walk was reached), sparse index should NOT exist
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_7') ORDER BY 1,2;

-- Cleanup: remove queue entries for this test's collections
DELETE FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id IN (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name LIKE 'bg_unique_%');

RESET documentdb.indexBuildFailurePoint;

-------------------------------------------------------------------
-- Test 8: Index dropped before background worker picks it up.
-- The build should detect the dropped index (indexDetails == NULL)
-- and remove the queue entry entirely (cleanup).
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_8', '{"_id": 1, "a": 1}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_8', '{"_id": 2, "a": 2}', NULL);

-- Create a unique index in background (queued but not built yet)
SELECT documentdb_api.create_indexes_background(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_8", "indexes": [{"key": {"a": 1}, "name": "idx_a_unique", "unique": true}] }'
);

-- Verify it is queued
SELECT index_cmd_status FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name = 'bg_unique_8') ORDER BY index_id DESC LIMIT 1;

-- Drop the index before the worker picks it up
CALL documentdb_api.drop_indexes('bg_uniq_db', '{ "dropIndexes": "bg_unique_8", "index": "idx_a_unique"}');

-- Now run the background worker — it should detect the index was dropped and remove from queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify queue entry is removed (no rows returned)
SELECT index_cmd_status FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name = 'bg_unique_8') ORDER BY index_id DESC LIMIT 1;

-- Verify no extra indexes remain on the collection (only _id)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_8') ORDER BY 1,2;

-- Cleanup: remove queue entries for this test's collections
DELETE FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id IN (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name LIKE 'bg_unique_%');

-------------------------------------------------------------------
-- Test 9: Index already valid when background worker picks it up.
-- Simulates a race where the index was concurrently built (e.g., by
-- a non-concurrent create_indexes call) while still in the queue.
-- The worker should detect the index is already valid, skip cleanup
-- of the underlying PG index, and just remove the queue entry.
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_9', '{"_id": 1, "a": 1}', NULL);
SELECT documentdb_api.insert_one('bg_uniq_db','bg_unique_9', '{"_id": 2, "a": 2}', NULL);

-- Create a unique index non-concurrently (already valid and built)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'bg_uniq_db',
  '{ "createIndexes": "bg_unique_9", "indexes": [{"key": {"a": 1}, "name": "idx_a_unique", "unique": true}] }',
  TRUE
);

-- Verify the index is built (2 indexes: _id + idx_a_unique)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_9') ORDER BY 1,2;

-- Manually insert a queue entry for the same index (simulating a stale queue entry)
INSERT INTO documentdb_api_catalog.documentdb_index_queue (index_cmd, cmd_type, index_id, index_cmd_status, collection_id)
SELECT 'CREATE INDEX CONCURRENTLY dummy ON documentdb_data.documents_' || c.collection_id || ' USING documentdb_rum (document)',
       'C',
       ci.index_id,
       1,
       ci.collection_id
FROM documentdb_api_catalog.collection_indexes ci
JOIN documentdb_api_catalog.collections c ON ci.collection_id = c.collection_id
WHERE c.database_name = 'bg_uniq_db' AND c.collection_name = 'bg_unique_9'
AND (ci.index_spec).index_name = 'idx_a_unique';

-- Verify it is queued
SELECT index_cmd_status FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name = 'bg_unique_9') ORDER BY index_id DESC LIMIT 1;

-- Now run the background worker — it should detect the index is already valid and remove from queue
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify queue entry is removed (no rows returned)
SELECT index_cmd_status FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name = 'bg_unique_9') ORDER BY index_id DESC LIMIT 1;

-- Verify the index is still present and valid (was NOT dropped, still 2 indexes)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('bg_uniq_db', 'bg_unique_9') ORDER BY 1,2;

-- Cleanup
DELETE FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id IN (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'bg_uniq_db' AND collection_name LIKE 'bg_unique_%');