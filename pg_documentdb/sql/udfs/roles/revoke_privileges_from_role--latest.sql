/*
 * __API_SCHEMA_V2__.revoke_privileges_from_role processes a revokePrivilegesFromRole command.
 */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.revoke_privileges_from_role(
    p_spec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE C
 VOLATILE
AS 'MODULE_PATHNAME', $function$command_revoke_privileges_from_role$function$;
