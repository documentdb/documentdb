-- 001_metadata_tables.sql
-- RBAC Metadata Tables for RFC-006 Implementation
-- Creates the core metadata infrastructure for RBAC

-- Table to track database-scoped role grants
-- DocumentDB grants roles per-database: grantRolesToUser("alice", [{role: "readWrite", db: "sales"}])
CREATE TABLE IF NOT EXISTS documentdb_api_catalog.user_roles (
    username TEXT NOT NULL,           -- DocumentDB username (PostgreSQL role with LOGIN)
    role_name TEXT NOT NULL,          -- DocumentDB role name: "readWrite", "read", "dbAdmin", etc.
    database_name TEXT NOT NULL,      -- Database scope: "sales", "marketing", "admin"
    granted_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (username, role_name, database_name)
);

COMMENT ON TABLE documentdb_api_catalog.user_roles IS 
'Tracks database-scoped role grants. Maps users to roles with specific database scope.';

COMMENT ON COLUMN documentdb_api_catalog.user_roles.username IS
'DocumentDB username that has been granted this role.';

COMMENT ON COLUMN documentdb_api_catalog.user_roles.role_name IS 
'DocumentDB role name (e.g., readWrite, read, dbAdmin). Can be built-in or custom role.';

COMMENT ON COLUMN documentdb_api_catalog.user_roles.database_name IS 
'Database scope for this role grant. User has this role only on this specific database.';

-- Create index for database-level queries
-- Note: username lookups use the PRIMARY KEY (username is leftmost column)
CREATE INDEX IF NOT EXISTS idx_user_roles_database 
    ON documentdb_api_catalog.user_roles(database_name);

-- Metadata versioning table for cache invalidation
-- Stale cache can be detected by comparing cached version with current version
CREATE TABLE IF NOT EXISTS documentdb_api_catalog.metadata_version (
    version_number BIGINT NOT NULL DEFAULT 1,
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    CHECK (version_number > 0)
);

COMMENT ON TABLE documentdb_api_catalog.metadata_version IS 
'Tracks metadata version for cache invalidation. Incremented on any privilege/role change.';

-- Initialize with version 1 if table is empty
INSERT INTO documentdb_api_catalog.metadata_version (version_number, last_updated)
SELECT 1, NOW()
WHERE NOT EXISTS (SELECT 1 FROM documentdb_api_catalog.metadata_version);

-- Roles table with pgbson document storage
-- Stores complete role definitions as BSON documents
CREATE TABLE IF NOT EXISTS documentdb_api_catalog.roles (
    document documentdb_core.bson NOT NULL
);

COMMENT ON TABLE documentdb_api_catalog.roles IS 
'Stores role definitions as BSON documents. Includes privileges, inherited roles, and metadata.';

-- Create index on role name for efficient lookups
-- Uses BSON arrow operator to extract 'role' field from document
CREATE INDEX IF NOT EXISTS idx_roles_name 
    ON documentdb_api_catalog.roles((document->>'role'));


-- Grant access to user_roles table
-- userAdmin and root can manage user role assignments
GRANT SELECT, INSERT, UPDATE, DELETE ON documentdb_api_catalog.user_roles 
    TO documentdb_user_admin_role, documentdb_root_role;
-- Other roles can only read
GRANT SELECT ON documentdb_api_catalog.user_roles 
    TO documentdb_readonly_role, documentdb_readwrite_role, documentdb_admin_role;

-- Grant access to metadata_version table
-- userAdmin and root can update version (they modify RBAC metadata)
GRANT SELECT, UPDATE ON documentdb_api_catalog.metadata_version 
    TO documentdb_user_admin_role, documentdb_root_role;
-- Other roles can only read
GRANT SELECT ON documentdb_api_catalog.metadata_version 
    TO documentdb_readonly_role, documentdb_readwrite_role, documentdb_admin_role;

-- Grant access to roles table
-- userAdmin and root can manage role definitions
GRANT SELECT, INSERT, UPDATE, DELETE ON documentdb_api_catalog.roles 
    TO documentdb_user_admin_role, documentdb_root_role;
-- Other roles can only read
GRANT SELECT ON documentdb_api_catalog.roles 
    TO documentdb_readonly_role, documentdb_readwrite_role, documentdb_admin_role;

-- Create helper function to increment metadata version
-- This function should be called after any RBAC metadata changes
-- Note: BIGINT overflow is not handled as it would take 292,000+ years at 1000 increments/second
CREATE OR REPLACE FUNCTION documentdb_api_catalog.increment_metadata_version()
RETURNS BIGINT
LANGUAGE plpgsql
AS $func$
DECLARE
    new_version BIGINT;
BEGIN
    UPDATE documentdb_api_catalog.metadata_version
    SET version_number = version_number + 1,
        last_updated = NOW()
    RETURNING version_number INTO new_version;
    
    RETURN new_version;
END;
$func$;

COMMENT ON FUNCTION documentdb_api_catalog.increment_metadata_version() IS
'Increments the metadata version number and updates timestamp. Call after any RBAC metadata changes.';

-- Create helper function to get current metadata version
CREATE OR REPLACE FUNCTION documentdb_api_catalog.get_metadata_version()
RETURNS BIGINT
LANGUAGE sql STABLE
AS $func$
    SELECT version_number FROM documentdb_api_catalog.metadata_version;
$func$;

COMMENT ON FUNCTION documentdb_api_catalog.get_metadata_version() IS
'Returns the current metadata version number for cache validation.';
