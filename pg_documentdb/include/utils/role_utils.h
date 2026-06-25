/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/utils/role_utils.h
 *
 * Headers of role utility functions.
 *
 *-------------------------------------------------------------------------
 */
#ifndef ROLE_UTILS_H
#define ROLE_UTILS_H

#include "postgres.h"
#include "fmgr.h"

/* Macro to check if a role is a system role */
#define IS_SYSTEM_LOGIN_ROLE(roleName) \
	(strcmp((roleName), ApiBgWorkerRole) == 0 || \
	 strcmp((roleName), ApiSettingsManagerRole) == 0 || \
	 strcmp((roleName), ApiReplicationRole) == 0)

/* Macro to check if a role is a customer facing built-in role */
#define IS_BUILTIN_ROLE(roleName) \
	(strcmp((roleName), ApiAdminRole) == 0 || \
	 strcmp((roleName), ApiAdminRoleV2) == 0 || \
	 strcmp((roleName), ApiClusterAdminRole) == 0 || \
	 strcmp((roleName), ApiReadOnlyRole) == 0 || \
	 strcmp((roleName), ApiReadWriteRole) == 0 || \
	 strcmp((roleName), ApiRootInternalRole) == 0 || \
	 strcmp((roleName), ApiRootRole) == 0 || \
	 strcmp((roleName), ApiUserAdminRole) == 0)

/* Macro to check if a role is an internal custom rbac role */
#define IS_CUSTOM_RBAC_ROLE(roleName) \
	(strcmp((roleName), ApiCollectionFindRole) == 0 || \
	 strcmp((roleName), ApiCollectionInsertRole) == 0 || \
	 strcmp((roleName), ApiCollectionUpdateRole) == 0 || \
	 strcmp((roleName), ApiCollectionRemoveRole) == 0)

/* Macro to check if a role name matches a native built-in role */
#define IS_NATIVE_BUILTIN_ROLE(roleName) \
	(strcmp((roleName), "__system") == 0 || \
	 strcmp((roleName), "autoCompact") == 0 || \
	 strcmp((roleName), "backup") == 0 || \
	 strcmp((roleName), "backupAndRestore") == 0 || \
	 strcmp((roleName), "clusterAdmin") == 0 || \
	 strcmp((roleName), "clusterManager") == 0 || \
	 strcmp((roleName), "clusterMonitor") == 0 || \
	 strcmp((roleName), "dbAdmin") == 0 || \
	 strcmp((roleName), "dbAdminAnyDatabase") == 0 || \
	 strcmp((roleName), "dbOwner") == 0 || \
	 strcmp((roleName), "directShardOperations") == 0 || \
	 strcmp((roleName), "enableSharding") == 0 || \
	 strcmp((roleName), "killOpSession") == 0 || \
	 strcmp((roleName), "manageShardBalancer") == 0 || \
	 strcmp((roleName), "MongodbAutomationAgentUserRole") == 0 || \
	 strcmp((roleName), "read") == 0 || \
	 strcmp((roleName), "readAnyDatabase") == 0 || \
	 strcmp((roleName), "readWrite") == 0 || \
	 strcmp((roleName), "readWriteAnyDatabase") == 0 || \
	 strcmp((roleName), "restore") == 0 || \
	 strcmp((roleName), "root") == 0 || \
	 strcmp((roleName), "searchCoordinator") == 0 || \
	 strcmp((roleName), "userAdmin") == 0 || \
	 strcmp((roleName), "userAdminAnyDatabase") == 0)

/*
 * Privilege stores a privilege and its actions.
 */
typedef struct
{
	const char *db;
	const char *collection;
	bool isCluster;
	size_t numActions;
	const StringView *actions;
} Privilege;

/*
 * ConsolidatedPrivilege contains the db, collection, isCluster, and actions of a privilege.
 */
typedef struct
{
	const char *db;
	const char *collection;
	bool isCluster;
	HTAB *actions;
} ConsolidatedPrivilege;

/* Function to write a single role's privileges to a BSON array writer */
void WritePrivileges(const char *internalRoleName,
					 pgbson_array_writer *privilegesArrayWriter);

/* Function to write multiple roles' privileges from an HTAB to a BSON array writer*/
void WriteMultipleRolePrivileges(HTAB *rolesTable,
								 pgbson_array_writer *privilegesArrayWriter);

/* Function to check if a given role name contains any reserved pg role name prefixes. */
bool ContainsReservedPgRoleNamePrefix(const char *name);

/* Function to check if a given name matches a reserved internal role name
* (system login role, builtin role, or custom RBAC role).
* Note: this function does not check against native built-in role names */
bool IsReservedInternalRoleName(const char *name);

/* Function to build a List of parent role names from an array of Datums */
List * ConvertUserOrRoleNamesDatumToList(Datum *parentRolesDatums, int parentRolesCount);

#endif
