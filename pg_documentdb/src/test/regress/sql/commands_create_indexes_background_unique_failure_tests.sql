SET documentdb.next_collection_id TO 25820000;
SET documentdb.next_collection_index_id TO 25820000;

SET search_path to documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- Disable cron jobs to prevent interference since we call build_index directly
SELECT documentdb_test_helpers.change_index_jobs_status(false);

-- Delete all old create index requests from other tests
DELETE from documentdb_api_catalog.documentdb_index_queue;

-- Enable feature flags
SET documentdb.enableNonBlockingUniqueIndexBuild TO true;
SET documentdb.enableUniqueReindex TO true;

-- ===================================================================
-- PART A: Background Unique Index Build Failure Points (1, 2, 3, 7)
-- ===================================================================

-------------------------------------------------------------------
-- Test A1: Failure point 1 - Before registering exclusion constraint
-- Expected: Physical index exists but NO exclusion constraint.
-- The build fails and is marked failed. On retry (new request with
-- failure cleared), should succeed.
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('faildb','bg_fail_1', '{"_id": 1, "a": 10}', NULL);
SELECT documentdb_api.insert_one('faildb','bg_fail_1', '{"_id": 2, "a": 20}', NULL);

-- Set failure point
SET documentdb.indexBuildFailurePoint TO 1;

-- Queue the index build request
SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_1", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp1", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);

-- Process the queue (will fail at failure point 1)
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'faildb' AND collection_name = 'bg_fail_1')
ORDER BY index_id DESC LIMIT 1;

-- The index record exists (physical build succeeded) but has no uniqueness constraint
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_1') ORDER BY 1,2;

-- Check PG catalog: NO exclusion constraint should exist
SELECT collection_id as coll_bg_fail_1 FROM documentdb_api_catalog.collections
WHERE database_name = 'faildb' AND collection_name = 'bg_fail_1' \gset

SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :coll_bg_fail_1)::regclass
  AND contype = 'x'
ORDER BY conname;

-- Duplicates should be insertable (no constraint protecting uniqueness)
SELECT documentdb_api.insert_one('faildb','bg_fail_1', '{"_id": 3, "a": 10}', NULL);

-- Clear failure point
SET documentdb.indexBuildFailurePoint TO 0;

-- Remove the duplicate so a new attempt can succeed
SELECT documentdb_api.delete('faildb', '{"delete": "bg_fail_1", "deletes": [{"q": {"_id": 3}, "limit": 1}]}');

-- Create the index again (fresh request since the old one was marked failed)
SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_1", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp1", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Now the index should exist and uniqueness enforced
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_1') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','bg_fail_1', '{"_id": 4, "a": 10}', NULL);

-------------------------------------------------------------------
-- Test A2: Failure point 2 - After constraint registration, before commit
-- Expected: Exclusion constraint IS registered but not yet committed.
-- Error fires before CommitTransactionCommand, so the transaction
-- aborts and the constraint is rolled back.
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('faildb','bg_fail_2', '{"_id": 1, "a": 100}', NULL);
SELECT documentdb_api.insert_one('faildb','bg_fail_2', '{"_id": 2, "a": 200}', NULL);

SET documentdb.indexBuildFailurePoint TO 2;

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_2", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp2", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'faildb' AND collection_name = 'bg_fail_2')
ORDER BY index_id DESC LIMIT 1;

-- The index should NOT be marked valid yet (post-processing failed)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_2') ORDER BY 1,2;

-- Check PG catalog: exclusion constraint rolled back (error before commit)
SELECT collection_id as coll_bg_fail_2 FROM documentdb_api_catalog.collections
WHERE database_name = 'faildb' AND collection_name = 'bg_fail_2' \gset

SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :coll_bg_fail_2)::regclass
  AND contype = 'x'
ORDER BY conname;

-- Clear failure point and create fresh request
SET documentdb.indexBuildFailurePoint TO 0;

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_2", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp2", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Now the index should be valid and uniqueness enforced
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_2') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','bg_fail_2', '{"_id": 3, "a": 100}', NULL);

-------------------------------------------------------------------
-- Test A3: Failure point 3 - After table walk completes
-- Expected: Constraint IS registered and committed (committed before
-- table walk), but the post-processing PG_TRY catches the error and
-- cleanup drops the index (cascading to drop the constraint).
-- On retry, should go through full post-processing and succeed.
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('faildb','bg_fail_3', '{"_id": 1, "a": 1000}', NULL);
SELECT documentdb_api.insert_one('faildb','bg_fail_3', '{"_id": 2, "a": 2000}', NULL);

SET documentdb.indexBuildFailurePoint TO 3;

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_3", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp3", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'faildb' AND collection_name = 'bg_fail_3')
ORDER BY index_id DESC LIMIT 1;

-- The index should NOT be marked valid yet
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_3') ORDER BY 1,2;

-- Check PG state: constraint dropped with index during cleanup
SELECT collection_id as coll_bg_fail_3 FROM documentdb_api_catalog.collections
WHERE database_name = 'faildb' AND collection_name = 'bg_fail_3' \gset

SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :coll_bg_fail_3)::regclass
  AND contype = 'x'
ORDER BY conname;

-- Clear failure point and retry
SET documentdb.indexBuildFailurePoint TO 0;

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_3", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp3", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Now the index should be valid
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_3') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','bg_fail_3', '{"_id": 3, "a": 1000}', NULL);

-------------------------------------------------------------------
-- Test A7: Failure point 7 - After physical build, before post-processing
-- Expected: Physical index built but no constraint registered.
-- On retry, should go through full post-processing and succeed.
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('faildb','bg_fail_7', '{"_id": 1, "a": 7000}', NULL);
SELECT documentdb_api.insert_one('faildb','bg_fail_7', '{"_id": 2, "a": 7001}', NULL);

SET documentdb.indexBuildFailurePoint TO 7;

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_7", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp7", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'faildb' AND collection_name = 'bg_fail_7')
ORDER BY index_id DESC LIMIT 1;

-- Index should not be marked valid
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_7') ORDER BY 1,2;

-- Check PG catalog: no exclusion constraint (post-processing never ran)
SELECT collection_id as coll_bg_fail_7 FROM documentdb_api_catalog.collections
WHERE database_name = 'faildb' AND collection_name = 'bg_fail_7' \gset

SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :coll_bg_fail_7)::regclass
  AND contype = 'x'
ORDER BY conname;

-- Duplicates should be insertable (no constraint)
SELECT documentdb_api.insert_one('faildb','bg_fail_7', '{"_id": 3, "a": 7000}', NULL);

-- Clear failure point and retry
SET documentdb.indexBuildFailurePoint TO 0;

-- Remove duplicate
SELECT documentdb_api.delete('faildb', '{"delete": "bg_fail_7", "deletes": [{"q": {"_id": 3}, "limit": 1}]}');

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_7", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp7", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Now index should be valid and enforcing uniqueness
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_7') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','bg_fail_7', '{"_id": 4, "a": 7000}', NULL);

-------------------------------------------------------------------
-- Test A8: Failure point 8 - After constraint commit, before table walk
-- Expected: Constraint IS registered and committed (visible to other
-- backends). The error fires before the table walk runs.
-- Cleanup drops the index (cascading constraint drop).
-- On retry, should go through full post-processing and succeed.
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('faildb','bg_fail_8', '{"_id": 1, "a": 8000}', NULL);
SELECT documentdb_api.insert_one('faildb','bg_fail_8', '{"_id": 2, "a": 8001}', NULL);

SET documentdb.indexBuildFailurePoint TO 8;

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_8", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp8", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'faildb' AND collection_name = 'bg_fail_8')
ORDER BY index_id DESC LIMIT 1;

-- Index should not be marked valid
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_8') ORDER BY 1,2;

-- Check PG catalog: constraint was committed but then dropped during cleanup
SELECT collection_id as coll_bg_fail_8 FROM documentdb_api_catalog.collections
WHERE database_name = 'faildb' AND collection_name = 'bg_fail_8' \gset

SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :coll_bg_fail_8)::regclass
  AND contype = 'x'
ORDER BY conname;

-- Duplicates should be insertable (constraint dropped with index)
SELECT documentdb_api.insert_one('faildb','bg_fail_8', '{"_id": 3, "a": 8000}', NULL);

-- Clear failure point and retry
SET documentdb.indexBuildFailurePoint TO 0;

-- Remove duplicate
SELECT documentdb_api.delete('faildb', '{"delete": "bg_fail_8", "deletes": [{"q": {"_id": 3}, "limit": 1}]}');

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_8", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp8", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Now index should be valid and enforcing uniqueness
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_8') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','bg_fail_8', '{"_id": 4, "a": 8000}', NULL);

-------------------------------------------------------------------
-- Test A9: Failure point 9 - Before marking index as valid
-- Expected: Post-processing (constraint + table walk) completed
-- successfully, but the failure fires before MarkIndexAsValid.
-- The subtransaction rolls back, so the index stays invalid.
-- On retry, the index already has the constraint so post-processing
-- succeeds and the index is marked valid.
-------------------------------------------------------------------
SELECT documentdb_api.insert_one('faildb','bg_fail_9', '{"_id": 1, "a": 9000}', NULL);
SELECT documentdb_api.insert_one('faildb','bg_fail_9', '{"_id": 2, "a": 9001}', NULL);

SET documentdb.indexBuildFailurePoint TO 9;

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_9", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp9", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections WHERE database_name = 'faildb' AND collection_name = 'bg_fail_9')
ORDER BY index_id DESC LIMIT 1;

-- Index should NOT be marked valid (subtransaction rolled back)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_9') ORDER BY 1,2;

-- Check PG catalog: constraint is NOT present (cleanup dropped the index + constraint)
SELECT collection_id as coll_bg_fail_9 FROM documentdb_api_catalog.collections
WHERE database_name = 'faildb' AND collection_name = 'bg_fail_9' \gset

SELECT conname, contype, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :coll_bg_fail_9)::regclass
  AND contype = 'x'
ORDER BY conname;

-- Duplicates are insertable (constraint dropped with index during cleanup)
SELECT documentdb_api.insert_one('faildb','bg_fail_9', '{"_id": 3, "a": 9000}', NULL);

-- Clear failure point and retry
SET documentdb.indexBuildFailurePoint TO 0;

-- Remove the duplicate so a new attempt can succeed
SELECT documentdb_api.delete('faildb', '{"delete": "bg_fail_9", "deletes": [{"q": {"_id": 3}, "limit": 1}]}');

SELECT documentdb_api.create_indexes_background(
  'faildb',
  '{ "createIndexes": "bg_fail_9", "indexes": [{"key": {"a": 1}, "name": "idx_a_fp9", "unique": true, "storageEngine": { "enableOrderedIndex": true }}] }'
);
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Now index should be valid and enforcing uniqueness
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'bg_fail_9') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','bg_fail_9', '{"_id": 4, "a": 9000}', NULL);


-- ===================================================================
-- PART B: Reindex Failure Points (4, 5, 6)
-- ===================================================================

-------------------------------------------------------------------
-- Setup: Create a collection with a unique ordered index for reindex tests
-------------------------------------------------------------------
SELECT documentdb_api.create_collection('faildb', 'reindex_fail_coll');
SELECT COUNT(documentdb_api.insert_one('faildb', 'reindex_fail_coll', FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)) FROM generate_series(1, 10) i;

-- Create unique index via blocking path (ordered)
SELECT documentdb_api_internal.create_indexes_non_concurrently('faildb',
  '{ "createIndexes": "reindex_fail_coll", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }', true);

-- Verify initial state
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'reindex_fail_coll') ORDER BY 1,2;

SELECT collection_id as coll_reindex_fail FROM documentdb_api_catalog.collections
WHERE database_name = 'faildb' AND collection_name = 'reindex_fail_coll' \gset

-- Verify uniqueness works before reindex
SELECT documentdb_api.insert_one('faildb','reindex_fail_coll', '{"_id": 100, "a": 1}', NULL);

-------------------------------------------------------------------
-- Test B4: Failure point 4 - Before prepareUnique during reindex
-- Expected: The _ccnew index exists but has no exclusion constraint.
-- Old index still has constraint and serves uniqueness.
-------------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 4;

SELECT documentdb_api.coll_mod('faildb', 'reindex_fail_coll', '{ "collMod": "reindex_fail_coll", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = :coll_reindex_fail
ORDER BY index_id DESC LIMIT 1;

-- Index should still be valid (old index is still in place)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'reindex_fail_coll') ORDER BY 1,2;

-- Uniqueness still enforced via original index
SELECT documentdb_api.insert_one('faildb','reindex_fail_coll', '{"_id": 101, "a": 1}', NULL);

-- Check PG state
\d documentdb_data.documents_:coll_reindex_fail

-- Clear failure point and retry reindex
SET documentdb.indexBuildFailurePoint TO 0;

SELECT documentdb_api.coll_mod('faildb', 'reindex_fail_coll', '{ "collMod": "reindex_fail_coll", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify clean state after successful reindex
\d documentdb_data.documents_:coll_reindex_fail
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'reindex_fail_coll') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','reindex_fail_coll', '{"_id": 102, "a": 1}', NULL);

-------------------------------------------------------------------
-- Test B5: Failure point 5 - After prepareUnique, before first rename
-- Expected: The _ccnew index has the exclusion constraint registered,
-- but the rename hasn't happened. Old base index name still intact.
-- Transaction aborts so constraint on _ccnew is also rolled back.
-------------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 5;

SELECT documentdb_api.coll_mod('faildb', 'reindex_fail_coll', '{ "collMod": "reindex_fail_coll", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = :coll_reindex_fail
ORDER BY index_id DESC LIMIT 1;

-- Index should still be valid (transaction aborted, old index intact)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'reindex_fail_coll') ORDER BY 1,2;

-- Uniqueness still enforced via original index
SELECT documentdb_api.insert_one('faildb','reindex_fail_coll', '{"_id": 103, "a": 1}', NULL);

-- Check PG state
\d documentdb_data.documents_:coll_reindex_fail

-- Clear failure point and retry reindex
SET documentdb.indexBuildFailurePoint TO 0;

SELECT documentdb_api.coll_mod('faildb', 'reindex_fail_coll', '{ "collMod": "reindex_fail_coll", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify clean state
\d documentdb_data.documents_:coll_reindex_fail
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'reindex_fail_coll') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','reindex_fail_coll', '{"_id": 104, "a": 1}', NULL);

-------------------------------------------------------------------
-- Test B6: Failure point 6 - After first rename, before second rename
-- Expected: First rename happened (base→old) but transaction aborts,
-- so renames are undone.
-------------------------------------------------------------------
SET documentdb.indexBuildFailurePoint TO 6;

SELECT documentdb_api.coll_mod('faildb', 'reindex_fail_coll', '{ "collMod": "reindex_fail_coll", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify the build failed with the expected FP error message
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = :coll_reindex_fail
ORDER BY index_id DESC LIMIT 1;

-- The index catalog entry should still be valid (transaction aborted)
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'reindex_fail_coll') ORDER BY 1,2;

-- Uniqueness still enforced via original index (renames rolled back)
SELECT documentdb_api.insert_one('faildb','reindex_fail_coll', '{"_id": 105, "a": 1}', NULL);

-- Check PG state
\d documentdb_data.documents_:coll_reindex_fail

-- Clear failure point and retry reindex
SET documentdb.indexBuildFailurePoint TO 0;

SELECT documentdb_api.coll_mod('faildb', 'reindex_fail_coll', '{ "collMod": "reindex_fail_coll", "index": { "name": "a_1_unique", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Verify clean state after successful retry
\d documentdb_data.documents_:coll_reindex_fail
SELECT * FROM documentdb_test_helpers.count_collection_indexes('faildb', 'reindex_fail_coll') ORDER BY 1,2;
SELECT documentdb_api.insert_one('faildb','reindex_fail_coll', '{"_id": 106, "a": 1}', NULL);


-- ===================================================================
-- Cleanup
-- ===================================================================
RESET documentdb.enableUniqueReindex;
RESET documentdb.indexBuildFailurePoint;
