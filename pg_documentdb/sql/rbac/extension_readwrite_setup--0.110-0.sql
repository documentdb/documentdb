DO
$do$
BEGIN
	/*
	 * The role is a system-wide object which is not dropped if the extension
	 * is dropped. Therefore, if __API_SCHEMA__ api is repeatedly created and dropped,
	 * a regular CREATE ROLE would fail since documentdb_readwrite_role still exists.
	 * We therefore only create the role if it does not exist.
	 */
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'documentdb_readwrite_role') THEN
		/* 
		* For distributed shard movements/rebalancing scenarios
		* the owner of the table must have a login capability for shards
		* to be moved around. Consequently we ensure that the readwrite role has
		* login capabilities in this case
		*/
        CREATE ROLE documentdb_readwrite_role WITH LOGIN;
    END IF;
END
$do$;

/* 
 *  We're granting usage on old internal schemas for now since there are several places where these are referred to directly 
 *  in our C files. We'll fix these references and revoke access to old internal API schemas in a future PR 
*/
GRANT USAGE ON SCHEMA __API_SCHEMA_INTERNAL__ TO documentdb_readwrite_role;
GRANT USAGE ON SCHEMA __API_SCHEMA_INTERNAL_V2__ TO documentdb_readwrite_role;

-- Grant usage on the catalog schema since that's where all the bson operators are defined
GRANT USAGE ON SCHEMA __API_CATALOG_SCHEMA_V2__ TO documentdb_readwrite_role;
GRANT USAGE ON SCHEMA __API_CATALOG_SCHEMA__ TO documentdb_readwrite_role;

-- Grant usage on both the internal schemas whose methods the readWriteAnyDatabase role should be able to execute
GRANT USAGE ON SCHEMA documentdb_api_internal_readwrite TO documentdb_readwrite_role;
GRANT USAGE ON SCHEMA documentdb_api_internal_readonly TO documentdb_readwrite_role;

-- Grant usage on the new documentdb_api_v2
GRANT USAGE ON SCHEMA documentdb_api_v2 TO documentdb_readwrite_role;

-- Grant usage on __CORE_SCHEMA_V2__ since that is where the bson datatype is defined
GRANT USAGE ON SCHEMA __CORE_SCHEMA_V2__ TO documentdb_readwrite_role;

-- Grant usage and create on __API_DATA_SCHEMA__ since that is where we create tables for new collections
GRANT USAGE, CREATE ON SCHEMA __API_DATA_SCHEMA__ TO documentdb_readwrite_role;

GRANT documentdb_readwrite_role to __API_ADMIN_ROLE__;

GRANT EXECUTE ON FUNCTION documentdb_api_v2.create_collection(text, text) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.create_collection_view(text, __CORE_SCHEMA_V2__.bson) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.drop_collection(text, text, __CORE_SCHEMA_V2__.bson, uuid, bool) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.create_indexes_background(text, __CORE_SCHEMA__.bson) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.insert(text, __CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bsonsequence, text) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.delete(text, __CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bsonsequence, text) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.rename_collection(text, text, text, boolean) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.insert_one(text, text, __CORE_SCHEMA_V2__.bson, text) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.aggregate_cursor_first_page(text, __CORE_SCHEMA_V2__.bson, bigint) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.update(text, __CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bsonsequence, text) TO documentdb_readwrite_role;
GRANT EXECUTE ON PROCEDURE documentdb_api_v2.update_bulk(text, __CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bsonsequence, text, __CORE_SCHEMA_V2__.bson, boolean) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.count_query(text, __CORE_SCHEMA__.bson) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.distinct_query(text, __CORE_SCHEMA__.bson) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.db_stats(text, double precision, boolean) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.find_and_modify(text, __CORE_SCHEMA_V2__.bson, text) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.list_databases(__CORE_SCHEMA__.bson) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.find_cursor_first_page(text, __CORE_SCHEMA_V2__.bson, bigint) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.list_indexes_cursor_first_page(text, __CORE_SCHEMA_V2__.bson, bigint) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.list_collections_cursor_first_page(text, __CORE_SCHEMA_V2__.bson, bigint) TO documentdb_readwrite_role;
GRANT EXECUTE ON FUNCTION documentdb_api_v2.cursor_get_more(text, __CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bson) TO documentdb_readwrite_role;