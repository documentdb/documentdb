SET documentdb.next_collection_id TO 1985100;
SET documentdb.next_collection_index_id TO 1985100;

\set VERBOSITY TERSE

SET documentdb.enableRoleCrud TO ON;
SET documentdb.enableUserCrud TO ON;
SET documentdb.enableRolesAdminDBCheck TO ON;
SET documentdb.enableUsersAdminDBCheck TO ON;

-- A custom role and a custom user act as the counterparts in the checks below.
SELECT documentdb_api.create_role('{"createRole":"systemProtectRole", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"systemProtectUser", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- The full set of roles the extension provisions and manages internally. None
-- of them may be dropped or have their memberships changed through the
-- role and user commands.
CREATE TEMP TABLE system_roles(role_name text);
INSERT INTO system_roles VALUES
    -- system login roles
    ('documentdb_bg_worker_role'),
    -- customer facing built-in roles
    ('documentdb_admin_role'),
    ('documentdb_cluster_admin_role'),
    ('documentdb_readonly_role'),
    ('documentdb_readwrite_role'),
    ('documentdb_root_role'),
    ('documentdb_user_admin_role'),
    -- internal roles backing the collection level access checks
    ('documentdb_api_find_role'),
    ('documentdb_api_insert_role'),
    ('documentdb_api_update_role'),
    ('documentdb_api_remove_role'),
    ('documentdb_rbac_api_access_role'),
    ('documentdb_rbac_baseline_read_role'),
    ('documentdb_rbac_baseline_write_role'),
    ('documentdb_rbac_readwrite_anydb_role');

-- Report which of them exist here. Rejection is by name and does not depend on
-- the role being provisioned, but recording this makes it clear which checks
-- below run against a role that is actually present.
SELECT role_name, EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) AS role_exists
FROM system_roles
ORDER BY 1;

-- Each management command must reject a system role used as its target.
DO $$
DECLARE
    systemRole text;
    commandName text;
    commandSpec text;
    errorMessage text;
    accepted boolean;
BEGIN
    FOR systemRole IN SELECT role_name FROM system_roles ORDER BY 1
    LOOP
        FOREACH commandName IN ARRAY ARRAY['dropRole', 'grantRolesToRole',
                                           'revokeRolesFromRole', 'grantRolesToUser',
                                           'revokeRolesFromUser']
        LOOP
            commandSpec := CASE commandName
                WHEN 'dropRole' THEN
                    format('{"dropRole":"%s", "$db":"admin"}', systemRole)
                ELSE
                    format('{"%s":"%s", "roles":["readAnyDatabase"], "$db":"admin"}',
                           commandName, systemRole)
            END;

            accepted := false;

            BEGIN
                CASE commandName
                    WHEN 'dropRole' THEN
                        PERFORM documentdb_api.drop_role(commandSpec::documentdb_core.bson);
                    WHEN 'grantRolesToRole' THEN
                        PERFORM documentdb_api.grant_roles_to_role(commandSpec::documentdb_core.bson);
                    WHEN 'revokeRolesFromRole' THEN
                        PERFORM documentdb_api.revoke_roles_from_role(commandSpec::documentdb_core.bson);
                    WHEN 'grantRolesToUser' THEN
                        PERFORM documentdb_api.grant_roles_to_user(commandSpec::documentdb_core.bson);
                    ELSE
                        PERFORM documentdb_api.revoke_roles_from_user(commandSpec::documentdb_core.bson);
                END CASE;

                accepted := true;
            EXCEPTION WHEN OTHERS THEN
                errorMessage := SQLERRM;
            END;

            IF accepted THEN
                RAISE WARNING '% on % was accepted', commandName, systemRole;
            ELSE
                RAISE NOTICE '% on %: %', commandName, systemRole, errorMessage;
            END IF;
        END LOOP;
    END LOOP;
END
$$;

-- A system role must also be rejected when it is named as the role being
-- granted or revoked, so it can never be handed to a custom role or user.
DO $$
DECLARE
    systemRole text;
    commandName text;
    targetName text;
    commandSpec text;
    errorMessage text;
    accepted boolean;
BEGIN
    FOR systemRole IN SELECT role_name FROM system_roles ORDER BY 1
    LOOP
        FOREACH commandName IN ARRAY ARRAY['grantRolesToRole', 'revokeRolesFromRole',
                                           'grantRolesToUser', 'revokeRolesFromUser']
        LOOP
            targetName := CASE
                WHEN commandName IN ('grantRolesToRole', 'revokeRolesFromRole')
                THEN 'systemProtectRole'
                ELSE 'systemProtectUser'
            END;

            commandSpec := format('{"%s":"%s", "roles":["%s"], "$db":"admin"}',
                                  commandName, targetName, systemRole);

            accepted := false;

            BEGIN
                CASE commandName
                    WHEN 'grantRolesToRole' THEN
                        PERFORM documentdb_api.grant_roles_to_role(commandSpec::documentdb_core.bson);
                    WHEN 'revokeRolesFromRole' THEN
                        PERFORM documentdb_api.revoke_roles_from_role(commandSpec::documentdb_core.bson);
                    WHEN 'grantRolesToUser' THEN
                        PERFORM documentdb_api.grant_roles_to_user(commandSpec::documentdb_core.bson);
                    ELSE
                        PERFORM documentdb_api.revoke_roles_from_user(commandSpec::documentdb_core.bson);
                END CASE;

                accepted := true;
            EXCEPTION WHEN OTHERS THEN
                errorMessage := SQLERRM;
            END;

            IF accepted THEN
                RAISE WARNING '% of % was accepted', commandName, systemRole;
            ELSE
                RAISE NOTICE '% of %: %', commandName, systemRole, errorMessage;
            END IF;
        END LOOP;
    END LOOP;
END
$$;

-- No membership may have been handed to or taken from the custom role or user.
SELECT child.rolname AS grantee, parent.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles parent ON m.roleid = parent.oid
JOIN pg_roles child ON m.member = child.oid
WHERE child.rolname IN ('systemProtectRole', 'systemProtectUser')
ORDER BY 1, 2;

-- Every system role must still exist.
SELECT role_name, EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) AS role_exists
FROM system_roles
ORDER BY 1;

-- The prefixes the extension reserves for the roles it provisions are blocked
-- unconditionally, so clearing the configured prefix list cannot expose them.
SET documentdb.blockedRolePrefixList TO '';

SELECT documentdb_api.create_role('{"createRole":"documentdb_api_custom_role", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_role('{"createRole":"documentdb_rbac_custom_role", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_api_custom_role", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_rbac_custom_role", "$db":"admin"}');

SELECT documentdb_api.create_user('{"createUser":"documentdb_api_custom_user", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"documentdb_rbac_custom_user", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_api_custom_user", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_rbac_custom_user", "$db":"admin"}');
SELECT documentdb_api.update_user('{"updateUser":"documentdb_api_custom_user", "pwd":"Valid$456Pass", "$db":"admin"}');
SELECT documentdb_api.update_user('{"updateUser":"documentdb_rbac_custom_user", "pwd":"Valid$456Pass", "$db":"admin"}');

SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"documentdb_api_custom_role", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"documentdb_rbac_custom_role", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"documentdb_api_custom_user", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"documentdb_rbac_custom_user", "roles":["readAnyDatabase"], "$db":"admin"}');

-- A blocked prefix is also rejected when it names the role being granted.
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"systemProtectRole", "roles":["documentdb_api_custom_role"], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"systemProtectUser", "roles":["documentdb_rbac_custom_role"], "$db":"admin"}');

RESET documentdb.blockedRolePrefixList;

-- PostgreSQL keeps roles and users in one namespace, so a built-in role name
-- may not be taken by a user either.
SELECT documentdb_api.create_user('{"createUser":"readAnyDatabase", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"root", "pwd":"Valid$123Pass", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.update_user('{"updateUser":"clusterAdmin", "pwd":"Valid$456Pass", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"dbOwner", "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_user('{"grantRolesToUser":"userAdmin", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_user('{"revokeRolesFromUser":"backup", "roles":["readAnyDatabase"], "$db":"admin"}');

SELECT documentdb_api.drop_role('{"dropRole":"systemProtectRole", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"systemProtectUser", "$db":"admin"}');

-- The unconditional prefix rejection is behind a feature flag. With the flag
-- off and the configured prefix list cleared, the reserved prefixes are no
-- longer rejected.
SET documentdb.blockedRolePrefixList TO '';
SET documentdb.enable_failure_on_always_blocked_role_prefixes TO OFF;

SELECT documentdb_api.create_role('{"createRole":"documentdb_api_flag_off_role", "roles":[], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.grant_roles_to_role('{"grantRolesToRole":"documentdb_api_flag_off_role", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.revoke_roles_from_role('{"revokeRolesFromRole":"documentdb_api_flag_off_role", "roles":["readAnyDatabase"], "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"documentdb_api_flag_off_role", "$db":"admin"}');

RESET documentdb.enable_failure_on_always_blocked_role_prefixes;
RESET documentdb.blockedRolePrefixList;

-- With the flag back on the reserved prefixes are rejected again.
SELECT documentdb_api.create_role('{"createRole":"documentdb_api_flag_off_role", "roles":[], "privileges":[], "$db":"admin"}');
