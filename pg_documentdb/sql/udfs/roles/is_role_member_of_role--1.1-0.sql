-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.is_role_member_of_role(
    p_member_role_name text,
    p_role_name text)
RETURNS boolean
LANGUAGE C
STABLE
STRICT
PARALLEL SAFE
AS 'MODULE_PATHNAME', $function$documentdb_is_role_member_of_role$function$;
