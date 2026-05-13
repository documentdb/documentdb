/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/authorization/authorization.h
 *
 * Authorization structures and privilege management for MongoDB compatibility
 *
 *-------------------------------------------------------------------------
 */

#ifndef AUTHORIZATION_H
#define AUTHORIZATION_H

#include "postgres.h"
#include "io/bson_core.h"

/*
 * PrivilegeAction Enum
 *
 * Lists all MongoDB privilege actions as defined in:
 * https://www.mongodb.com/docs/manual/reference/privilege-actions/
 */
typedef enum PrivilegeAction
{
	/* Query and Write Actions */
	PRIV_FIND = 0,
	PRIV_INSERT,
	PRIV_UPDATE,
	PRIV_REMOVE,

	/* Database Management Actions */
	PRIV_CREATE_COLLECTION,
	PRIV_CREATE_INDEX,
	PRIV_DROP_COLLECTION,
	PRIV_DROP_INDEX,

	/* Deployment Management Actions */
	PRIV_LIST_DATABASES,
	PRIV_LIST_COLLECTIONS,
	PRIV_LIST_INDEXES,

	/* Replication Actions */
	PRIV_APPEND_OPLOG_NOTE,

	/* Sharding Actions */
	PRIV_ENABLE_SHARDING,
	PRIV_FLUSH_ROUTER_CONFIG,
	PRIV_ADD_SHARD,
	PRIV_REMOVE_SHARD,

	/* Server Administration Actions */
	PRIV_APPLICATION_MESSAGE,
	PRIV_CLOSE_ALL_DATABASES,
	PRIV_COMPACT,
	PRIV_CONN_POOL_SYNC,
	PRIV_DROP_DATABASE,
	PRIV_FS_SYNC,
	PRIV_GET_PARAMETER,
	PRIV_HOST_INFO,
	PRIV_LOG_ROTATE,
	PRIV_REINDEX,
	PRIV_RENAME_COLLECTION_SAME_DB,
	PRIV_SET_PARAMETER,
	PRIV_SHUTDOWN,
	PRIV_TOUCH,

	/* Diagnostic Actions */
	PRIV_COLL_STATS,
	PRIV_CONN_POOL_STATS,
	PRIV_CURSOR_INFO,
	PRIV_DB_HASH,
	PRIV_DB_STATS,
	PRIV_GET_CMD_LINE_OPTS,
	PRIV_GET_LOG,
	PRIV_INDEX_STATS,
	PRIV_LIST_SHARDS,
	PRIV_NET_STAT,
	PRIV_SERVER_STATUS,
	PRIV_TOP,
	PRIV_VALIDATE,

	/* Internal Actions */
	PRIV_ANY_ACTION,
	PRIV_INTERNAL,

	/* User and Role Management Actions */
	PRIV_CHANGE_CUSTOM_DATA,
	PRIV_CHANGE_PASSWORD,
	PRIV_CREATE_ROLE,
	PRIV_CREATE_USER,
	PRIV_DROP_ROLE,
	PRIV_DROP_USER,
	PRIV_GRANT_ROLE,
	PRIV_REVOKE_ROLE,
	PRIV_VIEW_ROLE,
	PRIV_VIEW_USER,

	/* Keep this last for bitmap sizing */
	PRIV_MAX
} PrivilegeAction;


/*
 * Privileges (Bitmap)
 *
 * Bitmap for storing and comparing privileges on any action.
 * Each bit represents a PrivilegeAction.
 */
#define PRIVILEGE_SET_SIZE ((PRIV_MAX + 31) / 32)

typedef struct Privileges
{
	uint32 bits[PRIVILEGE_SET_SIZE];
} PrivilegeSet;


/*
 * Role
 *
 * Represents a role within a specific database.
 */
#define MAX_DATABASE_NAME_LEN 64
#define MAX_ROLE_NAME_LEN 64

typedef struct Role
{
	char database[MAX_DATABASE_NAME_LEN];
	char role[MAX_ROLE_NAME_LEN];
} Role;


/*
 * Resource
 *
 * Represents a database resource (database and/or collection).
 */
#define MAX_COLLECTION_NAME_LEN 255

typedef struct Resource
{
	char database[MAX_DATABASE_NAME_LEN];
	char collection[MAX_COLLECTION_NAME_LEN];
} Resource;


/*
 * ResourcePrivileges
 *
 * Associates a set of privileges with a specific resource.
 */
typedef struct ResourcePrivileges
{
	Resource resource;
	PrivilegeSet privileges;
} ResourcePrivileges;


/*
 * ResourcePrivilegesSet
 *
 * Dynamic array of resource privileges.
 */
typedef struct ResourcePrivilegesSet
{
	ResourcePrivileges **items;
	int count;
	int capacity;
} ResourcePrivilegesSet;


/* Function declarations */

/*
 * Convert a string to a PrivilegeAction enum value.
 * Returns PRIV_MAX if the string is not recognized.
 */
extern PrivilegeAction privilege_action_from_string(const char *str);

/*
 * Convert a PrivilegeAction enum value to its string representation.
 * Returns NULL if the action is invalid.
 */
extern const char *privilege_action_to_string(PrivilegeAction action);

/* PrivilegeSet manipulation functions */

/*
 * Initialize an empty privilege set (all bits cleared).
 */
extern void privilege_set_init(PrivilegeSet *set);

/*
 * Add a privilege to the set.
 */
extern void privilege_set_add(PrivilegeSet *set, PrivilegeAction action);

/*
 * Check if a privilege is in the set.
 */
extern bool privilege_set_has(const PrivilegeSet *set, PrivilegeAction action);

/* ResourcePrivilegesSet manipulation functions */

/*
 * Create and initialize a new ResourcePrivilegesSet with initial capacity.
 */
extern ResourcePrivilegesSet *resource_privileges_set_create(int initial_capacity);

/*
 * Add a resource with privileges to the set.
 */
extern void resource_privileges_set_add(ResourcePrivilegesSet *set,
										const char *database,
										const char *collection,
										const PrivilegeSet *privileges);

/*
 * Free a ResourcePrivilegesSet and all its contents.
 */
extern void resource_privileges_set_free(ResourcePrivilegesSet *set);

/* Command privilege extraction */

/*
 * Extract required resource privileges from a BSON command.
 *
 * Returns a ResourcePrivilegesSet containing all resources and privileges
 * needed to execute the command, or NULL if privileges cannot be determined
 * statically (e.g., killOp where privileges depend on runtime context).
 *
 * The caller is responsible for freeing the returned set using
 * resource_privileges_set_free().
 *
 * On error (invalid command format), throws an ereport ERROR.
 */
extern ResourcePrivilegesSet *get_required_resource_privileges_for_cmd(pgbson *bson_spec);

#endif   /* AUTHORIZATION_H */
