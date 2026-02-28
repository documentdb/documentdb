-- 003_copy_role_grants.sql
-- Copy existing role grants from PostgreSQL's pg_auth_members
-- Populates user_roles table with existing role assignments
-- NOTE: This script runs during both fresh installs and upgrades, but is idempotent

-- This script is designed to be idempotent and safe to run multiple times

DO $$
DECLARE
    existing_grants_count INTEGER := 0;
BEGIN
    -- Check if copy has already been performed
    SELECT COUNT(*) INTO existing_grants_count
    FROM documentdb_api_catalog.user_roles;
    
    IF existing_grants_count > 0 THEN
        RAISE NOTICE 'Role grants already exist in user_roles (% found). Skipping copy.', existing_grants_count;
    ELSE
        RAISE NOTICE 'Starting role grants copy from pg_auth_members...';
        
        -- Copy existing role assignments from pg_auth_members to user_roles
        -- Maps DocumentDB PG role names to DocumentDB role names
        -- Defaults to 'admin' database scope for backward compatibility
        INSERT INTO documentdb_api_catalog.user_roles (username, role_name, database_name)
        SELECT 
            u.rolname AS username,
            CASE 
                WHEN r.rolname = 'documentdb_readwrite_role' THEN 'readWrite'
                WHEN r.rolname = 'documentdb_readonly_role' THEN 'read'
                WHEN r.rolname = 'documentdb_admin_role' THEN 'dbAdmin'
                WHEN r.rolname = 'documentdb_user_admin_role' THEN 'userAdmin'
                WHEN r.rolname = 'documentdb_root_role' THEN 'root'
            END AS role_name,
            'admin' AS database_name  -- Default to admin database for existing grants
        FROM pg_auth_members am
        JOIN pg_roles r ON r.oid = am.roleid
        JOIN pg_roles u ON u.oid = am.member  -- Join to get username from member OID
        WHERE r.rolname IN (
            'documentdb_readwrite_role',
            'documentdb_readonly_role', 
            'documentdb_admin_role',
            'documentdb_user_admin_role',
            'documentdb_root_role'
        )
        ON CONFLICT (username, role_name, database_name) DO NOTHING;
        
        -- Get count of migrated grants
        GET DIAGNOSTICS existing_grants_count = ROW_COUNT;
        
        IF existing_grants_count > 0 THEN
            RAISE NOTICE 'Successfully copied % existing role grants to RBAC metadata', existing_grants_count;
        ELSE
            RAISE NOTICE 'No existing role grants found to copy';
        END IF;
    END IF;
END $$;

-- Complete message
DO $$
BEGIN
    RAISE NOTICE 'Role grants copy completed successfully';
    RAISE NOTICE 'Existing role grants from pg_auth_members copied to user_roles table';
    RAISE NOTICE 'PostgreSQL role memberships remain unchanged for backward compatibility';
END $$;
