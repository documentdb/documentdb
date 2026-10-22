-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

/*
 * Drop-in replacement for delete_expired_rows. This will be called periodically by the
 * background worker framework and will coexist with the previous UDF until it reaches
 * stability.
 */
CREATE OR REPLACE PROCEDURE __API_SCHEMA_INTERNAL_V2__.delete_expired_rows_background(IN p_batch_size int default -1)
    LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$delete_expired_rows_background$procedure$;
COMMENT ON PROCEDURE __API_SCHEMA_INTERNAL_V2__.delete_expired_rows_background(int)
    IS 'Drops expired rows from applicable collections based on TTL indexes.';

REVOKE EXECUTE ON PROCEDURE __API_SCHEMA_INTERNAL_V2__.delete_expired_rows_background(int)
    FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE __API_SCHEMA_INTERNAL_V2__.delete_expired_rows_background(int)
    TO __API_BG_WORKER_ROLE__;
