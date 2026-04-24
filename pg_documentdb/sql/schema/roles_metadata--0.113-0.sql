-- Add role table grants and schema USAGE WITH GRANT OPTION for the root role,
-- so it can manage custom roles via createRole/dropRole.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'documentdb_root_role') THEN
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE documentdb_api_catalog.roles TO documentdb_root_role';
        EXECUTE 'GRANT USAGE ON SCHEMA documentdb_api_catalog, documentdb_core, documentdb_data, documentdb_api, documentdb_api_internal TO documentdb_root_role WITH GRANT OPTION';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'documentdb_root_role') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA documentdb_api_internal_readonly TO documentdb_root_role WITH GRANT OPTION';
    END IF;
END $$;
