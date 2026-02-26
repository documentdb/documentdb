/*
 * Find Privileged Action System Role
 * 
 * Supported Operations:  find, aggregate, count, distinct, cursor_get_more
 */

DO
$do$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'documentdb_api_find_role') THEN
        CREATE ROLE documentdb_api_find_role;
    END IF;
END
$do$;

GRANT USAGE ON SCHEMA __API_SCHEMA_INTERNAL__ TO documentdb_api_find_role;
GRANT USAGE ON SCHEMA __API_SCHEMA_INTERNAL_V2__ TO documentdb_api_find_role;

GRANT USAGE ON SCHEMA __API_CATALOG_SCHEMA_V2__ TO documentdb_api_find_role;
GRANT USAGE ON SCHEMA __API_CATALOG_SCHEMA__ TO documentdb_api_find_role;

GRANT USAGE ON SCHEMA documentdb_api_internal_readonly TO documentdb_api_find_role;

GRANT USAGE ON SCHEMA documentdb_api_v2 TO documentdb_api_find_role;

GRANT USAGE ON SCHEMA __CORE_SCHEMA_V2__ TO documentdb_api_find_role;

GRANT USAGE ON SCHEMA __API_DATA_SCHEMA__ TO documentdb_api_find_role;

-- Grant execute on find-related functions
GRANT EXECUTE ON FUNCTION documentdb_api_v2.aggregate_cursor_first_page(text, documentdb_core.bson, bigint) TO documentdb_api_find_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.count_query(text, documentdb_core.bson) TO documentdb_api_find_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.cursor_get_more(text, documentdb_core.bson, documentdb_core.bson) TO documentdb_api_find_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.distinct_query(text, documentdb_core.bson) TO documentdb_api_find_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.find_cursor_first_page(text, documentdb_core.bson, bigint) TO documentdb_api_find_role;