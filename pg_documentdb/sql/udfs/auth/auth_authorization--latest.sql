/* Get required privileges for a command */
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.get_required_privileges(
    p_command __CORE_SCHEMA_V2__.bson)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE C
PARALLEL SAFE STABLE
AS 'MODULE_PATHNAME', $$command_get_required_privileges$$;
COMMENT ON FUNCTION __API_SCHEMA_INTERNAL_V2__.get_required_privileges(__CORE_SCHEMA_V2__.bson)
    IS 'Extracts required resource privileges from a MongoDB command specification';
