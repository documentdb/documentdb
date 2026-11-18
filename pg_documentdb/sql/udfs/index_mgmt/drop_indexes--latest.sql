-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

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

CREATE OR REPLACE PROCEDURE __API_SCHEMA_INTERNAL_V2__.drop_indexes_background_internal(
    IN p_database_name text,
    IN p_arg __CORE_SCHEMA_V2__.bson,
    OUT retval __CORE_SCHEMA_V2__.bson)
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes_background_internal$procedure$;
COMMENT ON PROCEDURE __API_SCHEMA_INTERNAL_V2__.drop_indexes_background_internal(text, __CORE_SCHEMA_V2__.bson)
    IS 'background index-drop entry point on the metadata coordinator';

CREATE OR REPLACE PROCEDURE __API_SCHEMA_V2__.drop_indexes_background(
    IN p_database_name text,
    IN p_index_spec __CORE_SCHEMA_V2__.bson,
    OUT retval __CORE_SCHEMA_V2__.bson,
    OUT ok boolean,
    OUT requests __CORE_SCHEMA_V2__.bson)
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes_background$procedure$;
COMMENT ON PROCEDURE __API_SCHEMA_V2__.drop_indexes_background(text, __CORE_SCHEMA_V2__.bson)
    IS 'background index-drop entry point returning an index-operation polling descriptor';

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

CREATE OR REPLACE PROCEDURE documentdb_api_internal_readwrite.drop_indexes_background_internal(
    IN p_database_name text,
    IN p_arg __CORE_SCHEMA__.bson,
    OUT retval __CORE_SCHEMA__.bson)
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes_background_internal$procedure$;
COMMENT ON PROCEDURE documentdb_api_internal_readwrite.drop_indexes_background_internal(text, __CORE_SCHEMA__.bson)
    IS 'background index-drop entry point on the metadata coordinator';

CREATE OR REPLACE PROCEDURE documentdb_api_v2.drop_indexes_background(
    IN p_database_name text,
    IN p_index_spec __CORE_SCHEMA__.bson,
    OUT retval __CORE_SCHEMA__.bson,
    OUT ok boolean,
    OUT requests __CORE_SCHEMA__.bson)
 LANGUAGE c
AS 'MODULE_PATHNAME', $procedure$command_drop_indexes_background$procedure$;
COMMENT ON PROCEDURE documentdb_api_v2.drop_indexes_background(text, __CORE_SCHEMA__.bson)
    IS 'background index-drop entry point returning an index-operation polling descriptor';

REVOKE ALL ON PROCEDURE documentdb_api_v2.drop_indexes_background(text, __CORE_SCHEMA__.bson) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE documentdb_api_v2.drop_indexes_background(text, __CORE_SCHEMA__.bson) TO documentdb_readwrite_role;
#endif
