-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

CREATE OR REPLACE FUNCTION __API_SCHEMA__.custom_action(
    p_spec __CORE_SCHEMA__.bson)
RETURNS __CORE_SCHEMA__.bson
LANGUAGE C
VOLATILE PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $function$documentdb_custom_action$function$;

REVOKE ALL ON FUNCTION __API_SCHEMA__.custom_action(__CORE_SCHEMA__.bson) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION __API_SCHEMA__.custom_action(__CORE_SCHEMA__.bson) TO __API_ADMIN_ROLE__;
