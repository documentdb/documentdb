-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

-- SPDX-License-Identifier: MIT

/*
 * Same body as create_collection, with three differences.
 *
 * SECURITY DEFINER, so the creation runs as the function owner. The owner is
 * the collection create role, which is where the rights a namespace write
 * needs in order to bring that namespace into existence are collected. The
 * caller keeps none of those rights of its own, and what the creation produces
 * is handed on to the collection owner role, which holds none of them either.
 *
 * Access is removed from PUBLIC and given only to the administrator, so the
 * function is not a way for an arbitrary role to reach the creation path. It
 * remains the caller's responsibility to authorize the namespace before
 * calling this, because the function itself performs no privilege check.
 *
 * search_path is pinned, since an unqualified name resolved through a
 * caller-controlled search_path would run under the owner's rights.
 */
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_privs(
    p_database_name text, p_collection_name text)
RETURNS bool
LANGUAGE C VOLATILE PARALLEL UNSAFE STRICT SECURITY DEFINER
SET search_path TO pg_catalog, pg_temp
AS 'MODULE_PATHNAME', $function$command_create_collection_core$function$;
COMMENT ON FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_privs(text, text)
    IS 'create a collection using the rights of the collection create role';

REVOKE ALL ON FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_privs(text, text)
    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_privs(text, text)
    TO __API_ADMIN_ROLE__, documentdb_rbac_api_collection_create_role;

ALTER FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_privs(text, text)
    OWNER TO documentdb_rbac_api_collection_create_role;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_options_privs(
    p_database_name text, p_collection_name text, p_options __CORE_SCHEMA__.bson)
RETURNS bool
LANGUAGE C VOLATILE PARALLEL UNSAFE STRICT SECURITY DEFINER
SET search_path TO pg_catalog, pg_temp
AS 'MODULE_PATHNAME', $function$command_create_collection_core$function$;
COMMENT ON FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_options_privs(text, text, __CORE_SCHEMA__.bson)
    IS 'create a collection with options using the rights of the collection create role';
REVOKE ALL ON FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_options_privs(text, text, __CORE_SCHEMA__.bson)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_options_privs(text, text, __CORE_SCHEMA__.bson)
    TO __API_ADMIN_ROLE__, documentdb_rbac_api_collection_create_role;
ALTER FUNCTION __API_SCHEMA_INTERNAL__.create_collection_with_options_privs(text, text, __CORE_SCHEMA__.bson)
    OWNER TO documentdb_rbac_api_collection_create_role;
