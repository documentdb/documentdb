-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.is_reserved_user(
    p_user_name text)
RETURNS boolean
LANGUAGE C
STABLE
STRICT
PARALLEL SAFE
AS 'MODULE_PATHNAME', $function$documentdb_is_reserved_user$function$;
