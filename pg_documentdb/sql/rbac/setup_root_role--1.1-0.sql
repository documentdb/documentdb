-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

DO
$do$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_catalog.pg_roles
        WHERE rolname = 'documentdb_root_role')
    THEN
        CREATE ROLE documentdb_root_role;
    END IF;

    ALTER ROLE documentdb_root_role CREATEROLE;
END
$do$;

GRANT __API_ADMIN_ROLE__ TO documentdb_root_role;
