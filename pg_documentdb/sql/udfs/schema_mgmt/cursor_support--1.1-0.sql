-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.cursor_directory_cleanup(expiry_time_seconds int8 DEFAULT NULL)
RETURNS void
LANGUAGE c
VOLATILE
AS 'MODULE_PATHNAME', $function$cursor_directory_cleanup$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.delete_cursors(cursorids int8[])
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE c
 VOLATILE
AS 'MODULE_PATHNAME', $function$command_delete_cursors$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.cursor_directory_cleanup_background()
RETURNS void
LANGUAGE c
VOLATILE
AS 'MODULE_PATHNAME', $function$cursor_directory_cleanup_background$function$;

REVOKE EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL_V2__.cursor_directory_cleanup_background()
	FROM PUBLIC;
GRANT EXECUTE ON FUNCTION __API_SCHEMA_INTERNAL_V2__.cursor_directory_cleanup_background()
	TO __API_BG_WORKER_ROLE__;
