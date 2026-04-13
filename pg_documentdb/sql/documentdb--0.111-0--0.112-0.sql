-- Revoke public execute on all functions, procedures and aggregates in documentdb_api_v2 schema
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA documentdb_api_v2 FROM PUBLIC;

-- Grant execute on readwrite routines to documentdb_readwrite_role
GRANT EXECUTE ON PROCEDURE documentdb_api_v2.create_indexes(text, documentdb_core.bson, documentdb_core.bson, boolean) TO documentdb_readwrite_role;
GRANT EXECUTE ON PROCEDURE documentdb_api_v2.drop_indexes(text, documentdb_core.bson, documentdb_core.bson) TO documentdb_readwrite_role;
GRANT EXECUTE ON PROCEDURE documentdb_api_v2.insert_bulk(text, documentdb_core.bson, documentdb_core.bsonsequence, text, documentdb_core.bson, boolean) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.coll_stats(text, text, float8) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.collection(text, text) TO documentdb_readwrite_role;

-- Grant execute on read-only routines to documentdb_readonly_role
GRANT EXECUTE ON FUNCTION documentdb_api_v2.aggregate_cursor_first_page(text, documentdb_core.bson, bigint) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.coll_stats(text, text, float8) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.collection(text, text) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.count_query(text, documentdb_core.bson) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.cursor_get_more(text, documentdb_core.bson, documentdb_core.bson) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.db_stats(text, double precision, boolean) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.distinct_query(text, documentdb_core.bson) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.find_cursor_first_page(text, documentdb_core.bson, bigint) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.list_collections_cursor_first_page(text, documentdb_core.bson, bigint) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.list_databases(documentdb_core.bson) TO documentdb_readonly_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.list_indexes_cursor_first_page(text, documentdb_core.bson, bigint) TO documentdb_readonly_role;

-- Grant execute on admin-only routines to documentdb_admin_role
GRANT EXECUTE ON FUNCTION documentdb_api_v2.current_op_command(documentdb_core.bson) TO documentdb_admin_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.drop_database(text, documentdb_core.bson) TO documentdb_admin_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.validate(text, documentdb_core.bson) TO documentdb_admin_role;
