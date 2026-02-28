-- documentdb_core--0.110-0--0.111-0.sql
-- Upgrade script from version 0.110-0 to 0.111-0
-- Adds RBAC (Role-Based Access Control) metadata infrastructure for RFC-006

-- Execute RBAC metadata table creation
\i rbac/001_metadata_tables.sql

-- Populate built-in role definitions
\i rbac/002_builtin_roles.sql

-- Copy existing role grants from pg_auth_members
\i rbac/003_copy_role_grants.sql
