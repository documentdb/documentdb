SET documentdb.next_collection_id TO 42000;
SET documentdb.next_collection_index_id TO 42000;

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
SELECT documentdb_api.drop_collection('db', 'collmod_reindex_coll') IS NOT NULL;

\o
\set ECHO :prevEcho

-- Reset the status so that cron build jobs are stopped.
-- Wait for background worker to be ready rather than a fixed sleep.
-- Shaves a few seconds off the test execution time by avoiding an
-- unnecessarily long sleep while still ensuring stability.
SELECT documentdb_test_helpers.change_index_jobs_status(false);
CALL documentdb_test_helpers.wait_for_background_worker_ready();

\i sql/create_indexes_background_core.sql

-- Reset -- so that other tests do not get impacted
SELECT documentdb_test_helpers.change_index_jobs_status(false);