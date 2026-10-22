/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * Licensed under the MIT License.
 * SPDX-License-Identifier: MIT
 *
 *-------------------------------------------------------------------------
 */

/*
 * The ordinary create_indexes_dispatch remains invoker-security because it is
 * also the entrypoint when privileged DDL dispatch is disabled. The restricted
 * security-definer function (__API_SCHEMA_INTERNAL__.create_indexes_with_privs)
 * handles both background and non-concurrent index creation, selected by the
 * dispatch options document.
 */
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.create_indexes_dispatch(
    p_database_name text,
    p_collection_name text,
    p_index_spec __CORE_SCHEMA__.bson,
    p_dispatch_options __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C VOLATILE PARALLEL UNSAFE STRICT
AS 'MODULE_PATHNAME', $function$command_create_indexes_dispatch$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.create_indexes_with_privs(
    p_database_name text,
    p_collection_name text,
    p_index_spec __CORE_SCHEMA__.bson,
    p_dispatch_options __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C VOLATILE PARALLEL UNSAFE STRICT SECURITY DEFINER
SET search_path TO pg_catalog, pg_temp
AS 'MODULE_PATHNAME', $function$command_create_indexes_with_privs$function$;

REVOKE ALL ON FUNCTION __API_SCHEMA_INTERNAL__.create_indexes_with_privs(
    text, text, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL__.create_indexes_with_privs(
    text, text, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
TO documentdb_rbac_api_index_create_role;

ALTER FUNCTION __API_SCHEMA_INTERNAL__.create_indexes_with_privs(
    text, text, __CORE_SCHEMA__.bson, __CORE_SCHEMA__.bson)
OWNER TO documentdb_rbac_api_index_create_role;
