/*
 * __API_SCHEMA_V2__.grant_privileges_to_role processes a grantPrivilegesToRole command.
 */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.grant_privileges_to_role(
    p_spec __CORE_SCHEMA__.bson)
 RETURNS __CORE_SCHEMA__.bson
 LANGUAGE C
 VOLATILE
AS 'MODULE_PATHNAME', $function$command_grant_privileges_to_role$function$;
