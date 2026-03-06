/*
 * Remove Privileged Action System Role
 * 
 * Supported Operations: delete
 */

DO
$do$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'documentdb_api_remove_role') THEN
        CREATE ROLE documentdb_api_remove_role;
    END IF;
END
$do$;

GRANT USAGE ON SCHEMA __API_SCHEMA_INTERNAL__ TO documentdb_api_remove_role;
GRANT USAGE ON SCHEMA __API_SCHEMA_INTERNAL_V2__ TO documentdb_api_remove_role;

GRANT USAGE ON SCHEMA __API_CATALOG_SCHEMA_V2__ TO documentdb_api_remove_role;
GRANT USAGE ON SCHEMA __API_CATALOG_SCHEMA__ TO documentdb_api_remove_role;

GRANT USAGE ON SCHEMA documentdb_api_internal_readwrite TO documentdb_api_remove_role;
GRANT USAGE ON SCHEMA documentdb_api_internal_readonly TO documentdb_api_remove_role;

GRANT USAGE ON SCHEMA documentdb_api_v2 TO documentdb_api_remove_role;

GRANT USAGE ON SCHEMA __CORE_SCHEMA_V2__ TO documentdb_api_remove_role;

GRANT USAGE ON SCHEMA __API_DATA_SCHEMA__ TO documentdb_api_remove_role;

-- Grant execute on delete-related functions
GRANT EXECUTE ON FUNCTION documentdb_api_v2.delete(text, documentdb_core.bson, documentdb_core.bsonsequence, text) TO documentdb_api_remove_role;
