/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/authorization/authorization.c
 *
 * Implementation of authorization structures and privilege management
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "fmgr.h"
#include "authorization.h"
#include "io/bson_core.h"
#include "utils/documentdb_errors.h"

#include <string.h>

/* Exported functions */
PG_FUNCTION_INFO_V1(command_get_required_privileges);

/*
 * Mapping table for PrivilegeAction to string conversion
 */
typedef struct PrivilegeActionMapping
{
	PrivilegeAction action;
	const char *name;
} PrivilegeActionMapping;

static const PrivilegeActionMapping PrivilegeActionMappings[] = {
	/* Query and Write Actions */
	{ PRIV_FIND, "find" },
	{ PRIV_INSERT, "insert" },
	{ PRIV_UPDATE, "update" },
	{ PRIV_REMOVE, "remove" },

	/* Database Management Actions */
	{ PRIV_CREATE_COLLECTION, "createCollection" },
	{ PRIV_CREATE_INDEX, "createIndex" },
	{ PRIV_DROP_COLLECTION, "dropCollection" },
	{ PRIV_DROP_INDEX, "dropIndex" },

	/* Deployment Management Actions */
	{ PRIV_LIST_DATABASES, "listDatabases" },
	{ PRIV_LIST_COLLECTIONS, "listCollections" },
	{ PRIV_LIST_INDEXES, "listIndexes" },

	/* Replication Actions */
	{ PRIV_APPEND_OPLOG_NOTE, "appendOplogNote" },

	/* Sharding Actions */
	{ PRIV_ENABLE_SHARDING, "enableSharding" },
	{ PRIV_FLUSH_ROUTER_CONFIG, "flushRouterConfig" },
	{ PRIV_ADD_SHARD, "addShard" },
	{ PRIV_REMOVE_SHARD, "removeShard" },

	/* Server Administration Actions */
	{ PRIV_APPLICATION_MESSAGE, "applicationMessage" },
	{ PRIV_CLOSE_ALL_DATABASES, "closeAllDatabases" },
	{ PRIV_COMPACT, "compact" },
	{ PRIV_CONN_POOL_SYNC, "connPoolSync" },
	{ PRIV_DROP_DATABASE, "dropDatabase" },
	{ PRIV_FS_SYNC, "fsync" },
	{ PRIV_GET_PARAMETER, "getParameter" },
	{ PRIV_HOST_INFO, "hostInfo" },
	{ PRIV_LOG_ROTATE, "logRotate" },
	{ PRIV_REINDEX, "reIndex" },
	{ PRIV_RENAME_COLLECTION_SAME_DB, "renameCollectionSameDB" },
	{ PRIV_SET_PARAMETER, "setParameter" },
	{ PRIV_SHUTDOWN, "shutdown" },
	{ PRIV_TOUCH, "touch" },

	/* Diagnostic Actions */
	{ PRIV_COLL_STATS, "collStats" },
	{ PRIV_CONN_POOL_STATS, "connPoolStats" },
	{ PRIV_CURSOR_INFO, "cursorInfo" },
	{ PRIV_DB_HASH, "dbHash" },
	{ PRIV_DB_STATS, "dbStats" },
	{ PRIV_GET_CMD_LINE_OPTS, "getCmdLineOpts" },
	{ PRIV_GET_LOG, "getLog" },
	{ PRIV_INDEX_STATS, "indexStats" },
	{ PRIV_LIST_SHARDS, "listShards" },
	{ PRIV_NET_STAT, "netstat" },
	{ PRIV_SERVER_STATUS, "serverStatus" },
	{ PRIV_TOP, "top" },
	{ PRIV_VALIDATE, "validate" },

	/* Internal Actions */
	{ PRIV_ANY_ACTION, "anyAction" },
	{ PRIV_INTERNAL, "internal" },

	/* User and Role Management Actions */
	{ PRIV_CHANGE_CUSTOM_DATA, "changeCustomData" },
	{ PRIV_CHANGE_PASSWORD, "changePassword" },
	{ PRIV_CREATE_ROLE, "createRole" },
	{ PRIV_CREATE_USER, "createUser" },
	{ PRIV_DROP_ROLE, "dropRole" },
	{ PRIV_DROP_USER, "dropUser" },
	{ PRIV_GRANT_ROLE, "grantRole" },
	{ PRIV_REVOKE_ROLE, "revokeRole" },
	{ PRIV_VIEW_ROLE, "viewRole" },
	{ PRIV_VIEW_USER, "viewUser" }
};

static const int NumPrivilegeActionMappings =
	sizeof(PrivilegeActionMappings) / sizeof(PrivilegeActionMapping);


/*
 * privilege_action_from_string
 *
 * Converts a string to a PrivilegeAction enum value.
 * Returns PRIV_MAX if the string is not recognized.
 */
PrivilegeAction
privilege_action_from_string(const char *str)
{
	int i;

	if (str == NULL)
	{
		return PRIV_MAX;
	}

	for (i = 0; i < NumPrivilegeActionMappings; i++)
	{
		if (strcmp(str, PrivilegeActionMappings[i].name) == 0)
		{
			return PrivilegeActionMappings[i].action;
		}
	}

	return PRIV_MAX;
}


/*
 * privilege_action_to_string
 *
 * Converts a PrivilegeAction enum value to its string representation.
 * Returns NULL if the action is invalid.
 */
const char *
privilege_action_to_string(PrivilegeAction action)
{
	int i;

	if (action < 0 || action >= PRIV_MAX)
	{
		return NULL;
	}

	for (i = 0; i < NumPrivilegeActionMappings; i++)
	{
		if (PrivilegeActionMappings[i].action == action)
		{
			return PrivilegeActionMappings[i].name;
		}
	}

	return NULL;
}


/*
 * privilege_set_init
 *
 * Initialize an empty privilege set (all bits cleared).
 */
void
privilege_set_init(PrivilegeSet *set)
{
	int i;

	if (set == NULL)
	{
		return;
	}

	for (i = 0; i < PRIVILEGE_SET_SIZE; i++)
	{
		set->bits[i] = 0;
	}
}


/*
 * privilege_set_add
 *
 * Add a privilege to the set.
 */
void
privilege_set_add(PrivilegeSet *set, PrivilegeAction action)
{
	int index;
	int bit;

	if (set == NULL || action < 0 || action >= PRIV_MAX)
	{
		return;
	}

	index = action / 32;
	bit = action % 32;
	set->bits[index] |= (1U << bit);
}


/*
 * privilege_set_has
 *
 * Check if a privilege is in the set.
 */
bool
privilege_set_has(const PrivilegeSet *set, PrivilegeAction action)
{
	int index;
	int bit;

	if (set == NULL || action < 0 || action >= PRIV_MAX)
	{
		return false;
	}

	index = action / 32;
	bit = action % 32;
	return (set->bits[index] & (1U << bit)) != 0;
}


/*
 * resource_privileges_set_create
 *
 * Create and initialize a new ResourcePrivilegesSet with initial capacity.
 */
ResourcePrivilegesSet *
resource_privileges_set_create(int initial_capacity)
{
	ResourcePrivilegesSet *set;

	if (initial_capacity <= 0)
	{
		initial_capacity = 8;
	}

	set = (ResourcePrivilegesSet *) palloc(sizeof(ResourcePrivilegesSet));
	set->items = (ResourcePrivileges **) palloc(sizeof(ResourcePrivileges *) *
												initial_capacity);
	set->count = 0;
	set->capacity = initial_capacity;

	return set;
}


/*
 * resource_privileges_set_add
 *
 * Add a resource with privileges to the set.
 */
void
resource_privileges_set_add(ResourcePrivilegesSet *set,
							const char *database,
							const char *collection,
							const PrivilegeSet *privileges)
{
	ResourcePrivileges *item;

	if (set == NULL || database == NULL || privileges == NULL)
	{
		return;
	}

	/* Expand capacity if needed */
	if (set->count >= set->capacity)
	{
		int new_capacity = set->capacity * 2;
		set->items = (ResourcePrivileges **) repalloc(set->items,
													  sizeof(ResourcePrivileges *) *
													  new_capacity);
		set->capacity = new_capacity;
	}

	/* Allocate and initialize the new item */
	item = (ResourcePrivileges *) palloc(sizeof(ResourcePrivileges));

	/* Copy database name */
	strncpy(item->resource.database, database, MAX_DATABASE_NAME_LEN - 1);
	item->resource.database[MAX_DATABASE_NAME_LEN - 1] = '\0';

	/* Copy collection name if provided */
	if (collection != NULL)
	{
		strncpy(item->resource.collection, collection, MAX_COLLECTION_NAME_LEN - 1);
		item->resource.collection[MAX_COLLECTION_NAME_LEN - 1] = '\0';
	}
	else
	{
		item->resource.collection[0] = '\0';
	}

	/* Copy privileges */
	memcpy(&item->privileges, privileges, sizeof(PrivilegeSet));

	/* Add to set */
	set->items[set->count++] = item;
}


/*
 * resource_privileges_set_free
 *
 * Free a ResourcePrivilegesSet and all its contents.
 */
void
resource_privileges_set_free(ResourcePrivilegesSet *set)
{
	int i;

	if (set == NULL)
	{
		return;
	}

	/* Free all items */
	for (i = 0; i < set->count; i++)
	{
		if (set->items[i] != NULL)
		{
			pfree(set->items[i]);
		}
	}

	/* Free the array */
	if (set->items != NULL)
	{
		pfree(set->items);
	}

	/* Free the set itself */
	pfree(set);
}


/*
 * extract_privileges_for_find_command
 *
 * Extract privileges for a "find" command.
 * Returns true on success, false if the command cannot be parsed.
 */
static bool
extract_privileges_for_find_command(pgbson *command_spec,
									const char *database_name,
									ResourcePrivilegesSet *result_set)
{
	bson_iter_t iter;
	const char *collection_name = NULL;
	PrivilegeSet privileges;

	/* Find the "find" field which contains the collection name */
	if (!PgbsonInitIteratorAtPath(command_spec, "find", &iter))
	{
		/* Not a find command */
		return false;
	}

	/* The value should be a string (collection name) */
	if (bson_iter_type(&iter) != BSON_TYPE_UTF8)
	{
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_TYPEMISMATCH),
				 errmsg("'find' field must be a string")));
	}

	collection_name = bson_iter_utf8(&iter, NULL);

	/* Create privilege set with PRIV_FIND */
	privilege_set_init(&privileges);
	privilege_set_add(&privileges, PRIV_FIND);

	/* Add to result set */
	resource_privileges_set_add(result_set, database_name, collection_name,
								&privileges);

	return true;
}


/*
 * get_required_resource_privileges_for_cmd
 *
 * Extract required resource privileges from a BSON command.
 *
 * Returns a ResourcePrivilegesSet containing all resources and privileges
 * needed to execute the command, or NULL if privileges cannot be determined
 * statically.
 */
ResourcePrivilegesSet *
get_required_resource_privileges_for_cmd(pgbson *bson_spec)
{
	ResourcePrivilegesSet *result_set;
	bson_iter_t iter;
	const char *database_name = NULL;

	if (bson_spec == NULL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_BADVALUE),
				 errmsg("command specification cannot be NULL")));
	}

	/* Extract database name from $db field */
	if (PgbsonInitIteratorAtPath(bson_spec, "$db", &iter))
	{
		if (bson_iter_type(&iter) == BSON_TYPE_UTF8)
		{
			database_name = bson_iter_utf8(&iter, NULL);
		}
	}

	if (database_name == NULL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_BADVALUE),
				 errmsg("command specification must include '$db' field")));
	}

	/* Create result set */
	result_set = resource_privileges_set_create(4);

	/* Try to extract privileges for known commands */
	if (extract_privileges_for_find_command(bson_spec, database_name, result_set))
	{
		return result_set;
	}

	/* Add more command handlers here as they are implemented */

	/*
	 * If we reach here, the command is not supported for static privilege
	 * extraction. Free the result set and return NULL.
	 */
	resource_privileges_set_free(result_set);
	return NULL;
}


/*
 * command_get_required_privileges
 *
 * PostgreSQL function that wraps get_required_resource_privileges_for_cmd
 * and returns the result as a BSON document.
 *
 * Input: pgbson command specification
 * Output: pgbson with the following format:
 * {
 *   "ok": 1.0,
 *   "canDeterminePrivileges": true/false,
 *   "privileges": [
 *     {
 *       "resource": { "db": "database", "collection": "collection" },
 *       "actions": ["find", "insert", ...]
 *     }
 *   ]
 * }
 */
Datum
command_get_required_privileges(PG_FUNCTION_ARGS)
{
	pgbson *command_spec;
	ResourcePrivilegesSet *privilege_set;
	pgbson_writer result_writer;
	int i;

	if (PG_ARGISNULL(0))
	{
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_BADVALUE),
				 errmsg("command specification cannot be NULL")));
	}

	command_spec = PG_GETARG_PGBSON(0);

	/* Try to extract privileges */
	privilege_set = get_required_resource_privileges_for_cmd(command_spec);

	/* Build result BSON */
	PgbsonWriterInit(&result_writer);
	PgbsonWriterAppendDouble(&result_writer, "ok", 2, 1.0);

	if (privilege_set == NULL)
	{
		/* Cannot determine privileges statically */
		PgbsonWriterAppendBool(&result_writer, "canDeterminePrivileges", -1, false);
	}
	else
	{
		pgbson_writer privileges_array_writer;
		pgbson_array_writer array_writer;

		PgbsonWriterAppendBool(&result_writer, "canDeterminePrivileges", -1, true);

		/* Start privileges array */
		PgbsonWriterStartArray(&result_writer, "privileges", -1, &array_writer);

		for (i = 0; i < privilege_set->count; i++)
		{
			ResourcePrivileges *item = privilege_set->items[i];
			pgbson_writer resource_writer;
			pgbson_array_writer actions_array_writer;
			int j;

			/* Start privilege object */
			PgbsonArrayWriterStartDocument(&array_writer, &privileges_array_writer);

			/* Write resource */
			PgbsonWriterStartDocument(&privileges_array_writer, "resource", -1,
									  &resource_writer);
			PgbsonWriterAppendUtf8(&resource_writer, "db", 2,
								   item->resource.database);

			if (item->resource.collection[0] != '\0')
			{
				PgbsonWriterAppendUtf8(&resource_writer, "collection", -1,
									   item->resource.collection);
			}
			else
			{
				/* Empty collection means all collections in the database */
				PgbsonWriterAppendUtf8(&resource_writer, "collection", -1, "");
			}

			PgbsonWriterEndDocument(&privileges_array_writer, &resource_writer);

			/* Write actions array */
			PgbsonWriterStartArray(&privileges_array_writer, "actions", -1,
								   &actions_array_writer);

			for (j = 0; j < PRIV_MAX; j++)
			{
				if (privilege_set_has(&item->privileges, j))
				{
					const char *priv_name = privilege_action_to_string(j);
					if (priv_name != NULL)
					{
						PgbsonArrayWriterWriteUtf8(&actions_array_writer, priv_name);
					}
				}
			}

			PgbsonWriterEndArray(&privileges_array_writer, &actions_array_writer);

			/* End privilege object */
			PgbsonArrayWriterEndDocument(&array_writer, &privileges_array_writer);
		}

		PgbsonWriterEndArray(&result_writer, &array_writer);

		/* Clean up */
		resource_privileges_set_free(privilege_set);
	}

	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&result_writer));
}
