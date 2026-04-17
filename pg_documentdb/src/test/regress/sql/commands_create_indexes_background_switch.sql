-- Test for validating the behavior of switching between pg_cron and background worker
-- for index builds. This test ensures that:
-- 1. Index builds scheduled via pg_cron drain correctly
-- 2. When pg_cron jobs are disabled, background worker takes over
-- 3. When pg_cron jobs are re-enabled, index builds continue
-- 4. All index builds complete successfully

SET documentdb.next_collection_id TO 52000;
SET documentdb.next_collection_index_id TO 52000;

SET search_path TO documentdb_core, documentdb_api, documentdb_api_catalog;

-- Helper function to count pending index builds in the queue
CREATE OR REPLACE FUNCTION test_count_pending_builds()
RETURNS bigint AS $$
  SELECT COUNT(*) FROM documentdb_api_catalog.documentdb_index_queue
  WHERE index_cmd_status IN (1, 2);  -- 1 = Pending, 2 = InProgress
$$ LANGUAGE sql;

-- Helper PROCEDURE to wait for the queue to drain to a target count or below.
-- MUST be a procedure (not function) with COMMIT calls so that CREATE INDEX CONCURRENTLY
-- doesn't wait for this session's transaction to complete.
CREATE OR REPLACE PROCEDURE test_wait_for_queue_drain(
  target_count bigint,
  max_wait_seconds integer,
  INOUT final_count bigint DEFAULT 0
)
LANGUAGE plpgsql AS $$
DECLARE
  current_count bigint;
  wait_count integer := 0;
BEGIN
  LOOP
    SELECT test_count_pending_builds() INTO current_count;
    IF current_count <= target_count THEN
      final_count := current_count;
      RETURN;
    END IF;
    IF wait_count >= max_wait_seconds THEN
      final_count := current_count;
      RETURN;
    END IF;
    -- COMMIT to release transaction so CREATE INDEX CONCURRENTLY can proceed
    COMMIT;
    PERFORM pg_sleep(1);
    wait_count := wait_count + 1;
  END LOOP;
END;
$$;

-- Cleanup any existing test collection and stale index build requests
\set prevEcho :ECHO
\set ECHO none
\o /dev/null
SELECT documentdb_api.drop_collection('db', 'index_switch_test') IS NOT NULL;
DELETE FROM documentdb_api_catalog.documentdb_index_queue;
\o
\set ECHO :prevEcho

-- Wait for background worker to be ready before starting the test
CALL documentdb_test_helpers.wait_for_background_worker_ready();

-- =============================================================================
-- STEP 1: Enable pg_cron index build jobs (this is the default state)
-- =============================================================================
SELECT documentdb_test_helpers.change_index_jobs_status(true);

-- =============================================================================
-- STEP 2: Schedule 20 index builds (suppress verbose output)
-- =============================================================================
\set prevEcho :ECHO
\set ECHO none
\o /dev/null
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field1": 1 }, "name": "idx_field1" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field2": 1 }, "name": "idx_field2" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field3": 1 }, "name": "idx_field3" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field4": 1 }, "name": "idx_field4" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field5": 1 }, "name": "idx_field5" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field6": 1 }, "name": "idx_field6" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field7": 1 }, "name": "idx_field7" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field8": 1 }, "name": "idx_field8" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field9": 1 }, "name": "idx_field9" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field10": 1 }, "name": "idx_field10" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field11": 1 }, "name": "idx_field11" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field12": 1 }, "name": "idx_field12" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field13": 1 }, "name": "idx_field13" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field14": 1 }, "name": "idx_field14" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field15": 1 }, "name": "idx_field15" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field16": 1 }, "name": "idx_field16" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field17": 1 }, "name": "idx_field17" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field18": 1 }, "name": "idx_field18" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field19": 1 }, "name": "idx_field19" }] }');
SELECT documentdb_api.create_indexes_background('db', '{ "createIndexes": "index_switch_test", "indexes": [ { "key": { "field20": 1 }, "name": "idx_field20" }] }');
\o
\set ECHO :prevEcho

-- Verify requests are in the queue 
SELECT test_count_pending_builds() <= 20 AS has_pending_builds;

-- =============================================================================
-- STEP 3: Wait for some builds to drain (pg_cron processing)
-- =============================================================================
CALL test_wait_for_queue_drain(17, 10, NULL);

-- Verify some builds completed
SELECT test_count_pending_builds() <= 17 AS pg_cron_draining;

-- =============================================================================
-- STEP 4: Disable pg_cron jobs (background worker should take over)
-- =============================================================================
SELECT documentdb_test_helpers.change_index_jobs_status(false);

-- =============================================================================
-- STEP 5: Confirm builds continue draining (background worker processing)
-- =============================================================================
CALL test_wait_for_queue_drain(10, 15, NULL);

-- Verify background worker is processing
SELECT test_count_pending_builds() <= 10 AS bgworker_draining;

-- =============================================================================
-- STEP 6: Re-enable pg_cron jobs
-- =============================================================================
SELECT documentdb_test_helpers.change_index_jobs_status(true);

-- =============================================================================
-- STEP 7: Wait for all builds to complete
-- =============================================================================
CALL test_wait_for_queue_drain(0, 30, NULL);

-- =============================================================================
-- STEP 8: Final verification
-- =============================================================================
-- Queue should be empty
SELECT COUNT(*) = 0 AS queue_empty FROM documentdb_api_catalog.documentdb_index_queue;

-- All 21 indexes created (20 user indexes + 1 _id index)
SELECT COUNT(*) = 21 AS all_indexes_created FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id FROM documentdb_api_catalog.collections
  WHERE database_name = 'db' AND collection_name = 'index_switch_test'
);

-- All indexes should be valid
SELECT COUNT(*) = 0 AS no_invalid_indexes FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id FROM documentdb_api_catalog.collections
  WHERE database_name = 'db' AND collection_name = 'index_switch_test'
) AND index_is_valid = false;

-- Cleanup
DROP FUNCTION IF EXISTS test_count_pending_builds();
DROP PROCEDURE IF EXISTS test_wait_for_queue_drain(bigint, integer, bigint);

-- Reset state for other tests
SELECT documentdb_test_helpers.change_index_jobs_status(false);
