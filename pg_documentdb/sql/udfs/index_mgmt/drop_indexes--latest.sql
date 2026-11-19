CREATE OR REPLACE PROCEDURE __API_SCHEMA__.drop_indexes(IN p_database_name text, IN p_arg __CORE_SCHEMA__.bson,
                                                      INOUT retval __CORE_SCHEMA__.bson DEFAULT null)
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes$procedure$;
COMMENT ON PROCEDURE __API_SCHEMA__.drop_indexes(text, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
    IS 'drop index(es) from a collection';

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.drop_indexes_non_concurrently(p_database_name text, p_arg __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes$procedure$;

#ifdef __RBAC_SCHEMA_ENABLED__
CREATE OR REPLACE PROCEDURE documentdb_api_v2.drop_indexes(IN p_database_name text, IN p_arg __CORE_SCHEMA__.bson,
                                                      INOUT retval __CORE_SCHEMA__.bson DEFAULT null)
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes$procedure$;
COMMENT ON PROCEDURE documentdb_api_v2.drop_indexes(text, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
    IS 'drop index(es) from a collection';

CREATE OR REPLACE FUNCTION documentdb_api_internal_readwrite.drop_indexes_non_concurrently(p_database_name text, p_arg __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes$procedure$;
#endif