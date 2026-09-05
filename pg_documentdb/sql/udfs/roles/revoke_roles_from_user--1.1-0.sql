/*
 * __API_SCHEMA_V2__.revoke_roles_from_user processes a revokeRolesFromUser command.
 */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.revoke_roles_from_user(
    p_spec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE C
 VOLATILE
AS 'MODULE_PATHNAME', $function$command_revoke_roles_from_user$function$;
