/*
 * __API_SCHEMA_V2__.grant_roles_to_user processes a grantRolesToUser command.
 */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.grant_roles_to_user(
    p_spec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE C
 VOLATILE
AS 'MODULE_PATHNAME', $function$command_grant_roles_to_user$function$;
