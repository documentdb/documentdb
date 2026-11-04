-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET documentdb.next_collection_id TO 3300;
SET documentdb.next_collection_index_id TO 3300;

SET documentdb.enable_cursor_cleanup_in_recovery TO true;

SELECT documentdb_test_helpers.write_cursor_file(
    'recovery_cleanup_regression_test',
    'expired cursor');
SELECT pg_sleep(1.1);

-- The recovery-specific UDF is expected to be a no-op on a primary.
SELECT documentdb_api_internal.cursor_directory_cleanup_background();
SELECT COUNT(*) AS files_after_background_cleanup_on_primary
    FROM pg_ls_dir('pg_documentdb_cursor_files')
    WHERE pg_ls_dir = 'recovery_cleanup_regression_test';

SET ROLE documentdb_bg_worker_role;
SELECT documentdb_api_internal.cursor_directory_cleanup(1);
RESET ROLE;

SELECT COUNT(*) AS files_after_original_cleanup
    FROM pg_ls_dir('pg_documentdb_cursor_files')
    WHERE pg_ls_dir = 'recovery_cleanup_regression_test';

RESET documentdb.enable_cursor_cleanup_in_recovery;

-- Dynamic file cursors must be removable without the legacy creation flag.
SET documentdb.enableDynamicCursors TO on;
SET documentdb.useFileBasedPersistedCursors TO off;
SET documentdb.use_file_based_persisted_dynamic_cursors TO on;
SET documentdb_core.enableCollation TO on;

SELECT count(documentdb_api.insert_one('cursor_cleanup_db', 'file_cursors',
    jsonb_build_object('_id', i, 'value', 7 - i, 'label', 'MATCH',
        'payload', repeat('x', 262144))::text::documentdb_core.bson))
FROM generate_series(1, 6) AS documents(i);

\set file_cursor_command '{"aggregate":"file_cursors","pipeline":[{"$match":{"label":"match"}},{"$sort":{"value":1}}],"collation":{"locale":"en","strength":2},"cursor":{"batchSize":0}}'
SELECT continuation AS file_continuation
FROM documentdb_api.aggregate_cursor_first_page(
    'cursor_cleanup_db', :'file_cursor_command', 3301) \gset
SELECT (:'file_continuation'::documentdb_core.bson)::text::jsonb ? 'qf' AS file_cursor,
       (pg_stat_file('pg_documentdb_cursor_files/cursor_3301', true)).size > 0 AS file_created;

-- A second live cursor can be drained independently of the first.
SELECT continuation AS second_file_continuation
FROM documentdb_api.aggregate_cursor_first_page(
    'cursor_cleanup_db',
    '{"aggregate":"file_cursors","pipeline":[{"$match":{"_id":{"$lte":3},"label":"match"}},{"$sort":{"value":1}}],"collation":{"locale":"en","strength":2},"cursor":{"batchSize":0}}',
    3303) \gset
SELECT (:'second_file_continuation'::documentdb_core.bson)::text::jsonb ? 'qf' AS second_file_cursor,
       (pg_stat_file('pg_documentdb_cursor_files/cursor_3303', true)).size > 0 AS second_file_created;

SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
           '{"ids":"$cursor.nextBatch._id"}') AS second_cursor_result,
       continuation IS NULL AS second_cursor_exhausted
FROM documentdb_api.cursor_get_more(
    'cursor_cleanup_db',
    '{"getMore":{"$numberLong":"3303"},"collection":"file_cursors","batchSize":10}',
    :'second_file_continuation');
SELECT pg_stat_file('pg_documentdb_cursor_files/cursor_3303', true) IS NULL AS second_file_deleted;

\set file_getmore_command '{"getMore":{"$numberLong":"3301"},"collection":"file_cursors","batchSize":1}'

SELECT (pg_stat_file('pg_documentdb_cursor_files/cursor_3301', true)).size > 0 AS valid_file_preserved;
SELECT documentdb_api_catalog.bson_dollar_project(cursorPage,
    '{"ids":"$cursor.nextBatch._id"}') AS valid_continuation_result
FROM documentdb_api.cursor_get_more(
    'cursor_cleanup_db', :'file_getmore_command', :'file_continuation');

SELECT documentdb_api_internal.delete_cursors(ARRAY[3301]::bigint[]);
SELECT pg_stat_file('pg_documentdb_cursor_files/cursor_3301', true) IS NULL AS file_deleted;

-- Reusing the ID must create a new cursor, not collide with the deleted file.
SELECT continuation IS NOT NULL AS reused_cursor_id
FROM documentdb_api.aggregate_cursor_first_page(
    'cursor_cleanup_db', :'file_cursor_command', 3301);
SET documentdb.use_file_based_persisted_dynamic_cursors TO off;
SELECT documentdb_api_internal.delete_cursors(ARRAY[3301]::bigint[]);
SELECT pg_stat_file('pg_documentdb_cursor_files/cursor_3301', true) IS NULL AS deleted_with_creation_disabled;

-- An error while writing must remove the pending file before the ID is reused.
SET documentdb.use_file_based_persisted_dynamic_cursors TO on;
SET documentdb.maxCursorIntermediateFileSizeMB TO 1;
SELECT cursorId
FROM documentdb_api.aggregate_cursor_first_page(
    'cursor_cleanup_db', :'file_cursor_command', 3302);
SELECT pg_stat_file('pg_documentdb_cursor_files/cursor_3302', true) IS NULL AS aborted_file_deleted;
RESET documentdb.maxCursorIntermediateFileSizeMB;
SELECT continuation IS NOT NULL AS reused_aborted_cursor_id
FROM documentdb_api.aggregate_cursor_first_page(
    'cursor_cleanup_db', :'file_cursor_command', 3302);
SELECT documentdb_api_internal.delete_cursors(ARRAY[3302]::bigint[]);

SELECT documentdb_api.drop_collection('cursor_cleanup_db', 'file_cursors');
RESET documentdb.enableDynamicCursors;
RESET documentdb.useFileBasedPersistedCursors;
RESET documentdb.use_file_based_persisted_dynamic_cursors;
RESET documentdb_core.enableCollation;
