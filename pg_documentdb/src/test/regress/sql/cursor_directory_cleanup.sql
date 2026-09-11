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
