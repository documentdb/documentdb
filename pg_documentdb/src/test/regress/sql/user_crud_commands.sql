SET documentdb.next_collection_id TO 1972800;
SET documentdb.next_collection_index_id TO 1972800;

SET documentdb.maxUserLimit TO 10;
\set VERBOSITY TERSE

show documentdb.blockedRolePrefixList;

SET documentdb.blockedRolePrefixList TO '';
SELECT documentdb_api.create_user('{"createUser":"documentdb_unblocked", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_unblocked", "$db":"admin"}');
SET documentdb.blockedRolePrefixList TO 'documentdb';
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_unblocked", "$db":"admin"}');

SET documentdb.blockedRolePrefixList TO 'newBlock, newBlock2';
SELECT documentdb_api.create_user('{"createUser":"newBlock_user", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"newBlock2_user", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

RESET documentdb.blockedRolePrefixList;

--Enable DB admin requirement feature flag
SET documentdb.enableUsersAdminDBCheck TO ON;

-- Test user APIs with non-admin database - all should fail
-- Test create_user with non-admin database
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"nonAdminDatabase"}');

-- Test users_info with non-admin database
SELECT documentdb_api.users_info('{"usersInfo":"test_user", "$db":"nonAdminDatabase"}');

-- Test update_user with non-admin database
SELECT documentdb_api.update_user('{"updateUser":"test_user", "pwd":"new_password", "$db":"nonAdminDatabase"}');

-- Test drop_user with non-admin database
SELECT documentdb_api.drop_user('{"dropUser":"test_user", "$db":"nonAdminDatabase"}');

-- Test user APIs with no database parameter - all should fail
-- Test create_user with no database parameter
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}]}');

-- Test users_info with no database parameter
SELECT documentdb_api.users_info('{"usersInfo":"test_user"}');

-- Test update_user with no database parameter
SELECT documentdb_api.update_user('{"updateUser":"test_user", "pwd":"new_password"}');

-- Test drop_user with no database parameter
SELECT documentdb_api.drop_user('{"dropUser":"test_user"}');

-- Test user APIs with admin check disabled - all should succeed
SET documentdb.enableUsersAdminDBCheck TO OFF;

-- Test create_user with non-admin database
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"nonAdminDatabase"}');

-- Verify that the user is created
SELECT documentdb_api.users_info('{"usersInfo":"test_user", "$db":"admin"}');

-- Test update_user with non-admin database
SELECT documentdb_api.update_user('{"updateUser":"test_user", "pwd":"new_password", "$db":"nonAdminDatabase"}');

-- Test drop_user with non-admin database
SELECT documentdb_api.drop_user('{"dropUser":"test_user", "$db":"nonAdminDatabase"}');

-- Verify that the user is dropped
SELECT documentdb_api.users_info('{"usersInfo":"test_user", "$db":"admin"}');

-- Test user APIs with no $db parameter when admin check is disabled - all should succeed
-- Test create_user with no database parameter
SELECT documentdb_api.create_user('{"createUser":"test_user_no_db", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}]}');

-- Test users_info with no database parameter
SELECT documentdb_api.users_info('{"usersInfo":"test_user_no_db"}');

-- Test update_user with no database parameter
SELECT documentdb_api.update_user('{"updateUser":"test_user_no_db", "pwd":"Updated$123Pass"}');

-- Test drop_user with no database parameter
SELECT documentdb_api.drop_user('{"dropUser":"test_user_no_db"}');

-- Verify that the user is dropped
SELECT documentdb_api.users_info('{"usersInfo":"test_user_no_db", "$db":"admin"}');

-- Re-enable admin DB check
SET documentdb.enableUsersAdminDBCheck TO ON;      

--Create a readOnly user
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

--Verify that the user is created
SELECT documentdb_api.users_info('{"usersInfo":"test_user", "$db":"admin"}');

--Create an admin user
SELECT documentdb_api.create_user('{"createUser":"test_user2", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

--Verify that the user is created
SELECT documentdb_api.users_info('{"usersInfo":"test_user2", "$db":"admin"}');

--Try to create a readOnly user without passing in the role as  part of an array
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"Valid$123Pass", "roles":{"role":"readAnyDatabase","db":"admin"}, "$db":"admin"}');

--Create a user with a blocked prefix
SELECT documentdb_api.create_user('{"createUser":"documentdb_user2", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

--Create an already existing user
SELECT documentdb_api.create_user('{"createUser":"test_user2", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

--Create a user with no role
SELECT documentdb_api.create_user('{"createUser":"test_user4", "pwd":"test_password", "roles":[], "$db":"admin"}');

--Create a user without specifying role parameter
SELECT documentdb_api.create_user('{"createUser":"test_user4", "pwd":"test_password", "$db":"admin"}');

--Create a user with a disallowed parameter
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "testParam":"This is a test", "$db":"admin"}');

--Create a user with a disallowed DB
SELECT documentdb_api.create_user('{"createUser":"test_user4", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"Test"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

--Create a user with a disallowed role
SELECT documentdb_api.create_user('{"createUser":"test_user4", "pwd":"test_password", "roles":[{"role":"read","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

--Create a user with no DB
SELECT documentdb_api.create_user('{"createUser":"test_user4", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase"}, {"role":"clusterAdmin"}], "$db":"admin"}');

--Create a user with clusterAdmin but no readWriteAnyDatabase should fail
SELECT documentdb_api.create_user('{"createUser":"test_user4", "pwd":"test_password", "roles":[{"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

-- Create a user with an empty password should fail
SELECT documentdb_api.create_user('{"createUser":"test_user_empty_pwd", "pwd":"", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Create a user with password less than 8 characters and drop it
SELECT documentdb_api.create_user('{"createUser":"test_user_short_pwd", "pwd":"Short1!", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"test_user_short_pwd", "$db":"admin"}');

-- Create a user with password more than 256 characters and drop it
SELECT documentdb_api.create_user('{"createUser":"test_user_long_pwd", "pwd":"ThisIsAVeryLongPasswordThatExceedsTheTwoHundredFiftySixCharacterLimitAndThereforeShouldFailValidation1!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"test_user_long_pwd", "$db":"admin"}');

--Verify that the user is created
SELECT documentdb_api.users_info('{"usersInfo":"test_user4", "$db":"admin"}');

--Create a user with no DB in just one role
SELECT documentdb_api.create_user('{"createUser":"test_user5", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

--Verify that the user is created
SELECT documentdb_api.users_info('{"usersInfo":"test_user5", "$db":"admin"}');

--Create a user with no parameters at all
SELECT documentdb_api.create_user('{"$db":"admin"}');

--Get all users
SELECT documentdb_api.users_info('{"usersInfo":1, "$db":"admin"}');

--Test SQL injection attack
SELECT documentdb_api.create_user('{"createUser":"test_user_injection_attack", "pwd":"; DROP TABLE users; --", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

--Verify that the user is created
SELECT documentdb_api.users_info('{"usersInfo":"test_user_injection_attack", "$db":"admin"}');

--Get all users
SELECT documentdb_api.users_info('{"usersInfo":1, "$db":"admin"}');

--Drop a user
SELECT documentdb_api.drop_user('{"dropUser":"test_user5", "$db":"admin"}');

--Verify successful drop
SELECT documentdb_api.users_info('{"usersInfo":"test_user5", "$db":"admin"}');

--Drop a reserved user, should fail
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_user", "$db":"admin"}');

--Drop non-existent user
SELECT documentdb_api.drop_user('{"dropUser":"nonexistent_user", "$db":"admin"}');

--Drop a system user
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_bg_worker_role", "$db":"admin"}');

--Drop a built-in user
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_admin_role", "$db":"admin"}');

--Drop with disallowed parameter
SELECT documentdb_api.drop_user('{"user":"test_user", "$db":"admin"}');

--Update a user
SELECT documentdb_api.update_user('{"updateUser":"test_user", "pwd":"new_password", "$db":"admin"}');

--Update non existent user
SELECT documentdb_api.update_user('{"updateUser":"nonexistent_user", "pwd":"new_password", "$db":"admin"}');

--Update with disllowed parameter
SELECT documentdb_api.update_user('{"updateUser":"test_user", "pwd":"new_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

--Get non existent user
SELECT documentdb_api.users_info('{"usersInfo":"nonexistent_user", "$db":"admin"}');

--Create a readOnly user
SELECT documentdb_api.create_user('{"createUser":"readOnlyUser", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

--Create an admin user
SELECT documentdb_api.create_user('{"createUser":"adminUser", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

--Verify that we error out for external identity provider
SELECT documentdb_api.create_user('{"createUser":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}, {"role":"clusterAdmin","db":"admin"}], "customData":{"IdentityProvider" : {"type" : "ExternalProvider", "properties": {"principalType": "servicePrincipal"}}}, "$db":"admin"}');

SELECT current_user as original_user \gset

-- Call usersInfo with showPrivileges set to true
SELECT documentdb_api.users_info('{"usersInfo":"test_user", "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.users_info('{"usersInfo":"test_user", "showPrivileges":false, "$db":"admin"}');
SELECT documentdb_api.users_info('{"usersInfo":"adminUser", "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.users_info('{"usersInfo":"adminUser", "showPrivileges":false, "$db":"admin"}');

-- Test usersInfo command with usersInfo set to 1 and showPrivileges set to true, should fail
SELECT documentdb_api.users_info('{"usersInfo":1, "showPrivileges":true, "$db":"admin"}');

-- Test usersInfo command with enableUserInfoPrivileges set to false
SET documentdb.enableUsersInfoPrivileges TO OFF;
SELECT documentdb_api.users_info('{"usersInfo":"test_user", "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.users_info('{"usersInfo":"adminUser", "showPrivileges":true, "$db":"admin"}');
RESET documentdb.enableUsersInfoPrivileges;

-- switch to read only user
\c - readOnlyUser

--Create without privileges
SELECT documentdb_api.create_user('{"createUser":"newUser", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

--Drop without privileges
SELECT documentdb_api.drop_user('{"dropUser":"test_user", "$db":"admin"}');

-- switch to admin user
\c - adminUser

-- Test connectionStatus command without showPrivileges parameter
SELECT documentdb_api.connection_status('{"connectionStatus": 1, "$db":"admin"}');

-- Test connectionStatus command with showPrivileges set to true/false
SELECT documentdb_api.connection_status('{"connectionStatus": 1, "showPrivileges":true, "$db":"admin"}');
SELECT documentdb_api.connection_status('{"connectionStatus": 1, "showPrivileges":false, "$db":"admin"}');

-- Test connectionStatus command with no parameters, should fail
SELECT documentdb_api.connection_status();

-- Test connectionStatus command with non-int value
SELECT documentdb_api.connection_status('{"connectionStatus": "1", "$db":"admin"}');

-- Test connectionStatus command with non-1 value
SELECT documentdb_api.connection_status('{"connectionStatus": 0, "$db":"admin"}');

-- Test connectionStatus command with no $db parameter, should fail
SELECT documentdb_api.connection_status('{"connectionStatus": 1}');

SET documentdb.enableUsersAdminDBCheck TO OFF;

-- Test connectionStatus command with no $db parameter, should succeed
SELECT documentdb_api.connection_status('{"connectionStatus": 1}');

SET documentdb.enableUsersAdminDBCheck TO ON;

--Create without privileges
SELECT documentdb_api.create_user('{"createUser":"newUser", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

--Drop without privileges
SELECT documentdb_api.drop_user('{"dropUser":"test_user", "$db":"admin"}');

--set Feature flag for user crud OFF
SET documentdb.enableUserCrud TO OFF;

--All user crud commnads should fail
SELECT documentdb_api.create_user('{"createUser":"test_user", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.users_info('{"usersInfo":1, "$db":"admin"}');
SELECT documentdb_api.update_user('{"updateUser":"test_user", "pwd":"new_password", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"test_user5", "$db":"admin"}');

-- switch back to original user
\c - :original_user

--set Feature flag for user crud
SET documentdb.enableUserCrud TO ON;
\set VERBOSITY TERSE
 
 --set max user limit to 11
SET documentdb.maxUserLimit TO 11;

-- Keep creating users till we have 11 users
SELECT documentdb_api.create_user('{"createUser":"newUser7", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"newUser8", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"newUser9", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"newUser10", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"newUser11", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- This call should fail since we're only allowed to create 11 users
SELECT documentdb_api.create_user('{"createUser":"newUser12", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Increase allowed users to 12
SET documentdb.maxUserLimit TO 12;

-- This should now succeed
SELECT documentdb_api.create_user('{"createUser":"newUser12", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- This should fail
SELECT documentdb_api.create_user('{"createUser":"newUser13", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Delete a user and try to create again, this should succeed
SELECT documentdb_api.drop_user('{"dropUser":"newUser7", "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"newUser13", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Delete all users created so we don't break other tests that also create users
SELECT documentdb_api.drop_user('{"dropUser":"newUser8", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"newUser9", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"newUser10", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"newUser11", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"newUser12", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"newUser13", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"test_user", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"test_user2", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"test_user4", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"test_user_injection_attack", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"readOnlyUser", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"adminUser", "$db":"admin"}');

-- Reset the max user limit to 500
SET documentdb.maxUserLimit TO 500;

-- ***** Regression: readWriteAnyDatabase-only users must count toward the user limit *****
-- The user count previously only considered members of the admin and read-only
-- roles, so a user granted only readWriteAnyDatabase was never counted and could
-- bypass maxUserLimit. All users created above have been dropped, so the
-- starting user count here is zero.

-- Allow exactly two users.
SET documentdb.maxUserLimit TO 2;

-- These users are granted readWriteAnyDatabase on its own, which requires the flag.
SET documentdb.enable_readwrite_any_database_role_enforcement TO ON;

-- Two users granted only readWriteAnyDatabase succeed.
SELECT documentdb_api.create_user('{"createUser":"rwLimitUser1", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"rwLimitUser2", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');

-- A third read-write user is rejected: read-write users count toward the limit.
SELECT documentdb_api.create_user('{"createUser":"rwLimitUser3", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');

-- A read-only user is likewise rejected once the limit is reached.
SELECT documentdb_api.create_user('{"createUser":"rwLimitUser4", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Dropping a read-write user frees a slot, confirming it was counted.
SELECT documentdb_api.drop_user('{"dropUser":"rwLimitUser1", "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"rwLimitUser3", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Cleanup
SELECT documentdb_api.drop_user('{"dropUser":"rwLimitUser2", "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"rwLimitUser3", "$db":"admin"}');
SET documentdb.maxUserLimit TO 500;
RESET documentdb.enable_readwrite_any_database_role_enforcement;

-- ***** Role-combination gating for createUser *****
-- Only the exact accepted built-in role combinations map to a PG role. Any
-- other combination is rejected rather than silently reduced to one role.

-- Case 1: specifying all three built-in roles is not an accepted combination and is rejected.
SELECT documentdb_api.create_user('{"createUser":"gatingUserAllBuiltin", "pwd":"test_password", "roles":[{"role":"clusterAdmin","db":"admin"},{"role":"readWriteAnyDatabase","db":"admin"},{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Case 2: readWriteAnyDatabase + readAnyDatabase is not an accepted combination and is rejected.
SELECT documentdb_api.create_user('{"createUser":"gatingUserRwRo", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"},{"role":"readAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Case 3: the accepted clusterAdmin + readWriteAnyDatabase combination still succeeds.
SELECT documentdb_api.create_user('{"createUser":"gatingUserAdmin", "pwd":"test_password", "roles":[{"role":"clusterAdmin","db":"admin"},{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Case 4: readWriteAnyDatabase on its own is rejected while the flag is off, with a
-- message that points at the required pairing rather than listing it as allowed.
SELECT documentdb_api.create_user('{"createUser":"gatingUserRwOnly", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');

-- Case 5: clusterAdmin on its own stays rejected regardless of the flag.
SELECT documentdb_api.create_user('{"createUser":"gatingUserClusterOnly", "pwd":"test_password", "roles":[{"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');

-- Case 6: turning the flag on accepts readWriteAnyDatabase on its own, which is how
-- a read-write-only user is provisioned, and widens the message for other cases.
SET documentdb.enable_readwrite_any_database_role_enforcement TO ON;
SELECT documentdb_api.create_user('{"createUser":"gatingUserRwOnly", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"gatingUserClusterOnly", "pwd":"test_password", "roles":[{"role":"clusterAdmin","db":"admin"}], "$db":"admin"}');
SELECT documentdb_api.drop_user('{"dropUser":"gatingUserRwOnly", "$db":"admin"}');
RESET documentdb.enable_readwrite_any_database_role_enforcement;

-- Cleanup the user created by the accepted case.
SELECT documentdb_api.drop_user('{"dropUser":"gatingUserAdmin", "$db":"admin"}');

-- ***** Granting a custom role via createUser *****
-- A custom role created through createRole can be granted to a user, provided
-- the role name is not reserved and the role is not a login role.
SET documentdb.enableRoleCrud TO ON;

-- Create the custom role, which succeeds.
SELECT documentdb_api.create_role('{"createRole":"customUserRole", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');

-- Granting the custom role to a new user succeeds.
SELECT documentdb_api.create_user('{"createUser":"customRoleUser", "pwd":"test_password", "roles":[{"role":"customUserRole","db":"admin"}], "$db":"admin"}');

-- Combining the custom role with a built-in role is rejected: a user resolves
-- to exactly one role.
SELECT documentdb_api.create_user('{"createUser":"customRoleUser2", "pwd":"test_password", "roles":[{"role":"readAnyDatabase","db":"admin"},{"role":"customUserRole","db":"admin"}], "$db":"admin"}');

-- Same input with readWriteAnyDatabase, whose standalone support is gated.
-- With the flag off the gate is reported first; with it on, standalone
-- readWriteAnyDatabase is allowed and the custom-role conflict is reported.
-- Either way the request is rejected.
SELECT documentdb_api.create_user('{"createUser":"customRoleUser2", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"},{"role":"customUserRole","db":"admin"}], "$db":"admin"}');
SET documentdb.enable_readwrite_any_database_role_enforcement TO ON;
SELECT documentdb_api.create_user('{"createUser":"customRoleUser2", "pwd":"test_password", "roles":[{"role":"readWriteAnyDatabase","db":"admin"},{"role":"customUserRole","db":"admin"}], "$db":"admin"}');
RESET documentdb.enable_readwrite_any_database_role_enforcement;

-- Specifying more than one custom role is rejected.
SELECT documentdb_api.create_role('{"createRole":"customUserRole2", "roles":["readAnyDatabase"], "privileges":[], "$db":"admin"}');
SELECT documentdb_api.create_user('{"createUser":"customRoleUser2", "pwd":"test_password", "roles":[{"role":"customUserRole","db":"admin"},{"role":"customUserRole2","db":"admin"}], "$db":"admin"}');

-- A role that does not exist is still rejected.
SELECT documentdb_api.create_user('{"createUser":"customRoleUser2", "pwd":"test_password", "roles":[{"role":"noSuchRole","db":"admin"}], "$db":"admin"}');

-- Another user may not be granted as if it were a role, since users are login
-- roles. This prevents one user from inheriting another user's privileges.
SELECT documentdb_api.create_user('{"createUser":"customRoleUser3", "pwd":"test_password", "roles":[{"role":"customRoleUser","db":"admin"}], "$db":"admin"}');

-- Reserved role names are rejected even though they exist.
SELECT documentdb_api.create_user('{"createUser":"customRoleUser3", "pwd":"test_password", "roles":[{"role":"documentdb_readonly_role","db":"admin"}], "$db":"admin"}');

-- PostgreSQL predefined roles are not custom roles even though they cannot log
-- in, so they may not be granted through createUser.
SELECT documentdb_api.create_user('{"createUser":"customRoleUser3", "pwd":"test_password", "roles":[{"role":"pg_read_all_data","db":"admin"}], "$db":"admin"}');

-- Verify the membership was actually created. usersInfo only reports built-in
-- roles, so the custom role does not appear there.
SELECT pg_has_role('customRoleUser', 'customUserRole', 'MEMBER');

-- Cleanup
SELECT documentdb_api.drop_user('{"dropUser":"customRoleUser", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"customUserRole", "$db":"admin"}');
SELECT documentdb_api.drop_role('{"dropRole":"customUserRole2", "$db":"admin"}');
RESET documentdb.enableRoleCrud;

-- Reset the feature flag for db admin requirement
RESET documentdb.enableUsersAdminDBCheck;

-- Unit test for IS_BUILTIN_ROLE, IS_CUSTOM_RBAC_ROLE, IS_SYSTEM_LOGIN_ROLE, and IS_NATIVE_BUILTIN_ROLE macros
CREATE OR REPLACE FUNCTION documentdb_test_helpers.test_is_reserved_role_name(text)
RETURNS bool
LANGUAGE C AS 'pg_documentdb', $$test_is_reserved_internal_role_name$$;

-- IS_BUILTIN_ROLE: all builtin roles should be reserved
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_admin_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_cluster_admin_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_readonly_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_readwrite_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_root_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_user_admin_role');

-- IS_CUSTOM_RBAC_ROLE: all custom RBAC roles should be reserved
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_api_find_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_api_insert_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_api_remove_role');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_api_update_role');

-- IS_SYSTEM_LOGIN_ROLE: system login roles should be reserved
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_bg_worker_role');

-- Negative cases: normal usernames should NOT be reserved
SELECT documentdb_test_helpers.test_is_reserved_role_name('normal_user');
SELECT documentdb_test_helpers.test_is_reserved_role_name('admin');
SELECT documentdb_test_helpers.test_is_reserved_role_name('documentdb_some_other_thing');

-- dropUser with IS_BUILTIN_ROLE name
SELECT documentdb_api.drop_user('{"dropUser":"documentdb_readonly_role", "$db":"admin"}');
-- updateUser with IS_BUILTIN_ROLE name
SELECT documentdb_api.update_user('{"updateUser":"documentdb_readonly_role", "pwd":"New$123Pass", "$db":"admin"}');
-- usersInfo with a reserved name should still work (read-only, no blocking)
SELECT documentdb_api.users_info('{"usersInfo":"documentdb_readonly_role", "$db":"admin"}');

DROP FUNCTION documentdb_test_helpers.test_is_reserved_role_name(text);