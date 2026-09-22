-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.is_custom_role(
    p_role_name text)
RETURNS boolean
LANGUAGE C
STABLE
STRICT
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $function$documentdb_is_custom_role$function$;
