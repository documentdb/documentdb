SET documentdb.next_collection_id TO 32000;
SET documentdb.next_collection_index_id TO 32000;

-- Drop all the collections that are created by the create_indexes_background_core.sql
-- This ensures test stability and prevents conflicts with existing collections.
\set prevEcho :ECHO
\set ECHO none
\o /dev/null

SELECT documentdb_api.drop_collection('db', 'collection_6') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'createIndex_background_1') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'intermediate') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'mycol') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'constraint') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'LargeKeySize') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'UnsupportedLanguage') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'backgroundcoll1') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'backgroundcoll2') IS NOT NULL;
SELECT documentdb_api.drop_collection('db', 'skip_wait_coll') IS NOT NULL;

\o
\set ECHO :prevEcho

ALTER SYSTEM SET documentdb.indexBuildsScheduledOnBgWorker = off;
SELECT pg_reload_conf();

\i sql/create_indexes_background_core.sql

BEGIN;
-- test config update, documentdb_api_internal.schedule_background_index_build_jobs reads default guc values
SELECT FROM documentdb_api_internal.schedule_background_index_build_jobs();
SELECT schedule, jobname FROM cron.job WHERE jobname LIKE 'documentdb_index_build_task_%' ORDER BY jobId;

-- now set guc values and verify that they take effect
SET LOCAL documentdb.maxNumActiveUsersIndexBuilds TO 1;
-- default value for the indexBuildScheduleInSec
SELECT FROM documentdb_api_internal.schedule_background_index_build_jobs();
SELECT schedule, jobname FROM cron.job WHERE jobname LIKE 'documentdb_index_build_task_%' ORDER BY jobId;

SET LOCAL documentdb.maxNumActiveUsersIndexBuilds TO 1;
SET LOCAL documentdb.indexBuildScheduleInSec TO 3;
SELECT FROM documentdb_api_internal.schedule_background_index_build_jobs();
SELECT schedule, jobname FROM cron.job WHERE jobname LIKE 'documentdb_index_build_task_%' ORDER BY jobId;

ROLLBACK;

SELECT schedule, jobname FROM cron.job WHERE jobname LIKE 'documentdb_index_build_task_%' ORDER BY jobId;

-- Reset -- so that other tests do not get impacted
SELECT documentdb_test_helpers.change_index_jobs_status(false);
SELECT documentdb_test_helpers.stop_index_jobs();

-- A discarded request must not retain its collection lock in this session.
SET documentdb.enable_background_index_build_notify TO on;
SET documentdb.indexBuildScheduleInSec TO 1;
SELECT documentdb_api.create_collection('db', 'background_lock_cleanup');
SELECT ok FROM documentdb_api.create_indexes_background('db',
  '{"createIndexes":"background_lock_cleanup","indexes":[{"key":{"a":1},"name":"stale_1"}]}');
DELETE FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections
  WHERE database_name = 'db' AND collection_name = 'background_lock_cleanup')
  AND (index_spec).index_name = 'stale_1';
CALL documentdb_api_internal.build_index_concurrently(1);
SELECT NOT EXISTS (
  SELECT 1 FROM pg_locks WHERE pid = pg_backend_pid()
    AND locktype = 'advisory' AND mode = 'ShareUpdateExclusiveLock'
) AS stale_request_lock_released;

SELECT ok FROM documentdb_api.create_indexes_background('db',
  '{"createIndexes":"background_lock_cleanup","indexes":[{"key":{"b":1},"name":"exhausted_1"}]}');
UPDATE documentdb_api_catalog.documentdb_index_queue
SET attempt = current_setting('documentdb.maxIndexBuildAttempts')::integer
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections
  WHERE database_name = 'db' AND collection_name = 'background_lock_cleanup');
CALL documentdb_api_internal.build_index_concurrently(1);
SELECT NOT EXISTS (
  SELECT 1 FROM pg_locks WHERE pid = pg_backend_pid()
    AND locktype = 'advisory' AND mode = 'ShareUpdateExclusiveLock'
) AS exhausted_request_lock_released;
UPDATE documentdb_api_catalog.documentdb_index_queue
SET update_time = '-infinity'
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections
  WHERE database_name = 'db' AND collection_name = 'background_lock_cleanup');
CALL documentdb_api_internal.build_index_concurrently(1);
SELECT NOT EXISTS (
  SELECT 1 FROM documentdb_api_catalog.documentdb_index_queue
  WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections
    WHERE database_name = 'db' AND collection_name = 'background_lock_cleanup')
) AS expired_request_pruned;
SELECT NOT EXISTS (
  SELECT 1 FROM pg_locks WHERE pid = pg_backend_pid()
    AND locktype = 'advisory' AND mode = 'ShareUpdateExclusiveLock'
) AS pruned_request_lock_released;
DELETE FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections
  WHERE database_name = 'db' AND collection_name = 'background_lock_cleanup');
SELECT documentdb_api.drop_collection('db', 'background_lock_cleanup');
RESET documentdb.indexBuildScheduleInSec;
RESET documentdb.enable_background_index_build_notify;