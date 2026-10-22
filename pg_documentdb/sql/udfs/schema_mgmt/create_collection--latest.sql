-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

-- SPDX-License-Identifier: MIT

/* SQL API function that creates a collection given a database and collection */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.create_collection(p_database_name text, p_collection_name text)
RETURNS bool
LANGUAGE c
 STRICT
AS 'MODULE_PATHNAME', $function$command_create_collection_core$function$;
COMMENT ON FUNCTION __API_SCHEMA_V2__.create_collection(p_database_name text, p_collection_name text)
    IS 'create a collection';

CREATE OR REPLACE FUNCTION __API_SCHEMA__.create_collection_with_options(
    p_database_name text, p_collection_name text, p_options __CORE_SCHEMA__.bson)
RETURNS bool LANGUAGE c STRICT
AS 'MODULE_PATHNAME', $function$command_create_collection_core$function$;
COMMENT ON FUNCTION __API_SCHEMA__.create_collection_with_options(text, text, __CORE_SCHEMA__.bson)
    IS 'create a collection with options';


#ifdef __RBAC_SCHEMA_ENABLED__
/* SQL API function that creates a collection given a database and collection */
CREATE OR REPLACE FUNCTION documentdb_api_v2.create_collection(p_database_name text, p_collection_name text)
RETURNS bool
LANGUAGE c
 STRICT
AS 'MODULE_PATHNAME', $function$command_create_collection_core$function$;
COMMENT ON FUNCTION documentdb_api_v2.create_collection(p_database_name text, p_collection_name text)
    IS 'create a collection';
#endif
