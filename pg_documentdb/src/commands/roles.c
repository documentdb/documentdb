/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/roles.c
 *
 * Implementation of role CRUD functions.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "access/transam.h"
#include "utils/documentdb_errors.h"
#include "utils/query_utils.h"
#include "commands/commands_common.h"
#include "commands/parse_error.h"
#include "utils/feature_counter.h"
#include "metadata/metadata_cache.h"
#include "api_hooks_def.h"
#include "api_hooks.h"
#include "utils/list_utils.h"
#include "roles.h"
#include "utils/elog.h"
#include "utils/array.h"
#include "utils/hashset_utils.h"
#include "utils/role_utils.h"

#define IS_NATIVE_BUILTIN_ROLE(roleName) \
	(strcmp((roleName), "readAnyDatabase") == 0 || \
	 strcmp((roleName), "readWriteAnyDatabase") == 0 || \
	 strcmp((roleName), "clusterAdmin") == 0 || \
	 strcmp((roleName), "root") == 0)

/*
 * IS_INHERITABLE_ROLE checks if a role is allowed to be inherited by custom roles.
 */
#define IS_INHERITABLE_ROLE(roleName) \
	(strcmp(roleName, ApiReadOnlyRole) == 0 || \
	 strcmp(roleName, ApiAdminRoleV2) == 0)

/* GUC to enable user crud operations */
extern bool EnableRoleCrud;

/* GUC that controls whether the DB admin check is enabled */
extern bool EnableRolesAdminDBCheck;

/* Supported privilege actions for collection-level custom role */
static const char *const SupportedActions[] = {
	"find",
	"insert",
	"update",
	"remove"
};
static const int NumSupportedActions = sizeof(SupportedActions) /
									   sizeof(SupportedActions[0]);

PG_FUNCTION_INFO_V1(command_create_role);
PG_FUNCTION_INFO_V1(command_drop_role);
PG_FUNCTION_INFO_V1(command_roles_info);
PG_FUNCTION_INFO_V1(command_update_role);

/*
 * Represents a single collection privilege entry.
 * Contains the database name, collection name, and a hash set of action strings.
 */
typedef struct CustomPrivilege
{
	StringView dbName;
	StringView collectionName;
	HTAB *actions;
} CustomPrivilege;

/*
 * Struct to hold createRole parameters
 */
typedef struct
{
	const char *roleName;
	HTAB *parentRoles;
	List *customPrivileges;
} CreateRoleSpec;

/*
 * Struct to hold rolesInfo parameters
 */
typedef struct
{
	List *roleNames;
	bool showAllRoles;
	bool showBuiltInRoles;
	bool showPrivileges;
} RolesInfoSpec;

/*
 * Struct to hold dropRole parameters
 */
typedef struct
{
	const char *roleName;
} DropRoleSpec;

/*
 * Hash table entry for role inheritance. Maps an internal role name
 * to its native name and list of internal parent role names.
 */
typedef struct RoleParentEntry
{
	char internalRoleName[NAMEDATALEN];
	char nativeRoleName[NAMEDATALEN];
	List *parentRoles;
} RoleParentEntry;

static void ParseCreateRoleSpec(pgbson *createRoleBson, CreateRoleSpec *createRoleSpec);
static void ParseRolesArray(bson_iter_t *rolesIter, CreateRoleSpec *createRoleSpec);
static void ParsePrivilegesArray(bson_iter_t *privilegesIter,
								 CreateRoleSpec *createRoleSpec);
static void ParseResourceDocument(bson_iter_t *privilegeDocIter, StringView *dbName,
								  StringView *collectionName);
static HTAB * ParseActionsArray(bson_iter_t *privilegeDocIter);
static void ParseDropRoleSpec(pgbson *dropRoleBson, DropRoleSpec *dropRoleSpec);
static void ParseRolesInfoSpec(pgbson *rolesInfoBson, RolesInfoSpec *rolesInfoSpec);
static void ParseRoleDefinition(bson_iter_t *iter, RolesInfoSpec *rolesInfoSpec);
static void ParseRoleDocument(bson_iter_t *rolesArrayIter, RolesInfoSpec *rolesInfoSpec);
static void ProcessAllRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter,
										RolesInfoSpec
										rolesInfoSpec, HTAB *roleInheritanceTable);
static void ProcessSpecificRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter,
											 RolesInfoSpec
											 rolesInfoSpec, HTAB *roleInheritanceTable);
static void WriteRoleResponse(const char *roleName,
							  pgbson_array_writer *rolesArrayWriter,
							  RolesInfoSpec rolesInfoSpec,
							  HTAB *roleInheritanceTable);
static HTAB * BuildRoleInheritanceTable(void);
static const char * GetInternalRoleName(const char *nativeRoleName);
static const char * GetNativeRoleName(const char *internalRoleName);
static void ParseRoleInheritanceResult(pgbson *rowBson, const char **childRole,
									   List **parentRoles);
static void FreeRoleInheritanceTable(HTAB *roleInheritanceTable);
static void CollectInheritedRolesRecursive(const char *roleName,
										   HTAB *roleInheritanceTable,
										   HTAB *resultSet);
static List * LookupAllInheritedRoles(const char *roleName, HTAB *roleInheritanceTable);
static void GrantRoleInheritance(const char *parentRole, const char *targetRole);
static void ValidateAndGrantInheritedRoles(const CreateRoleSpec *createRoleSpec);
static HTAB * CreateParentRolesHashSet(void);
static bool IsActionSupported(const char *action);
static void WriteRoles(List *parentRoles, pgbson_array_writer *rolesArrayWriter,
					   HTAB *roleInheritanceTable, const char *childRoleName);

/*
 * Parses a createRole spec, executes the createRole command, and returns the result.
 */
Datum
command_create_role(PG_FUNCTION_ARGS)
{
	pgbson *createRoleSpec = PG_GETARG_PGBSON(0);

	Datum response = create_role(createRoleSpec);

	PG_RETURN_DATUM(response);
}


/*
 * Implements dropRole command.
 */
Datum
command_drop_role(PG_FUNCTION_ARGS)
{
	pgbson *dropRoleSpec = PG_GETARG_PGBSON(0);

	Datum response = drop_role(dropRoleSpec);

	PG_RETURN_DATUM(response);
}


/*
 * Implements rolesInfo command, which will be implemented in the future.
 */
Datum
command_roles_info(PG_FUNCTION_ARGS)
{
	pgbson *rolesInfoSpec = PG_GETARG_PGBSON(0);

	Datum response = roles_info(rolesInfoSpec);

	PG_RETURN_DATUM(response);
}


/*
 * Implements updateRole command, which will be implemented in the future.
 */
Datum
command_update_role(PG_FUNCTION_ARGS)
{
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
					errmsg("UpdateRole command is not supported in preview."),
					errdetail_log("UpdateRole command is not supported in preview.")));
}


/*
 * create_role implements the core logic for createRole command
 */
Datum
create_role(pgbson *createRoleBson)
{
	if (!EnableRoleCrud)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg("The CreateRole command is currently unsupported."),
						errdetail_log(
							"The CreateRole command is currently unsupported.")));
	}

	ReportFeatureUsage(FEATURE_ROLE_CREATE);

	if (!IsMetadataCoordinator())
	{
		StringInfo createRoleQuery = makeStringInfo();
		appendStringInfo(createRoleQuery,
						 "SELECT %s.create_role(%s::%s.bson)",
						 ApiSchemaNameV2,
						 quote_literal_cstr(PgbsonToHexadecimalString(createRoleBson)),
						 CoreSchemaNameV2);
		DistributedRunCommandResult result = RunCommandOnMetadataCoordinator(
			createRoleQuery->data);

		if (!result.success)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Create role operation failed: %s",
								text_to_cstring(result.response)),
							errdetail_log(
								"Create role operation failed: %s",
								text_to_cstring(result.response))));
		}

		pgbson_writer finalWriter;
		PgbsonWriterInit(&finalWriter);
		PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
		return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
	}

	CreateRoleSpec createRoleSpec = {
		.roleName = NULL,
		.parentRoles = CreateParentRolesHashSet(),
		.customPrivileges = NIL
	};
	ParseCreateRoleSpec(createRoleBson, &createRoleSpec);

	/* Create the specified role in the database */
	StringInfo createRoleInfo = makeStringInfo();
	appendStringInfo(createRoleInfo, "CREATE ROLE %s", quote_identifier(
						 createRoleSpec.roleName));

	bool readOnly = false;
	bool isNull = false;
	ExtensionExecuteQueryViaSPI(createRoleInfo->data, readOnly, SPI_OK_UTILITY, &isNull);

	/* Validate and grant inherited roles to the new role */
	ValidateAndGrantInheritedRoles(&createRoleSpec);

	/* Cleanup */
	hash_destroy(createRoleSpec.parentRoles);

	ListCell *cell;
	foreach(cell, createRoleSpec.customPrivileges)
	{
		CustomPrivilege *privilege = (CustomPrivilege *) lfirst(cell);
		hash_destroy(privilege->actions);
	}
	list_free_deep(createRoleSpec.customPrivileges);

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);
	PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
	return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
}


/*
 * ParseCreateRoleSpec parses the createRole command parameters
 */
static void
ParseCreateRoleSpec(pgbson *createRoleBson, CreateRoleSpec *createRoleSpec)
{
	bson_iter_t createRoleIter;
	PgbsonInitIterator(createRoleBson, &createRoleIter);
	bool dbFound = false;
	bool rolesFound = false;
	bool privilegesFound = false;
	while (bson_iter_next(&createRoleIter))
	{
		const char *key = bson_iter_key(&createRoleIter);

		if (strcmp(key, "createRole") == 0)
		{
			EnsureTopLevelFieldType(key, &createRoleIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			createRoleSpec->roleName = bson_iter_utf8(&createRoleIter, &strLength);

			if (strLength == 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"The 'createRole' field must not be left empty.")));
			}

			if (ContainsReservedPgRoleNamePrefix(createRoleSpec->roleName))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Role name '%s' is reserved and can't be used as a custom role name.",
									createRoleSpec->roleName)));
			}

			if (IS_NATIVE_BUILTIN_ROLE(createRoleSpec->roleName))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Role name '%s' is a built-in role and can't be used as a custom role name.",
									createRoleSpec->roleName)));
			}
		}
		else if (strcmp(key, "roles") == 0)
		{
			rolesFound = true;
			ParseRolesArray(&createRoleIter, createRoleSpec);
		}
		else if (strcmp(key, "privileges") == 0)
		{
			privilegesFound = true;
			ParsePrivilegesArray(&createRoleIter, createRoleSpec);
		}
		else if (strcmp(key, "$db") == 0 && EnableRolesAdminDBCheck)
		{
			EnsureTopLevelFieldType(key, &createRoleIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			const char *dbName = bson_iter_utf8(&createRoleIter, &strLength);

			dbFound = true;
			if (strcmp(dbName, "admin") != 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"CreateRole must be called from 'admin' database.")));
			}
		}
		else if (IsCommonSpecIgnoredField(key))
		{
			continue;
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("The specified field '%s' is not supported.", key)));
		}
	}

	if (!dbFound && EnableRolesAdminDBCheck)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("The required $db property is missing.")));
	}

	if (createRoleSpec->roleName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'createRole' is a required field.")));
	}

	if (!rolesFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'roles' is a required field.")));
	}

	if (!privilegesFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'privileges' is a required field.")));
	}
}


/*
 * ParseRolesArray parses the "roles" array from the createRole command.
 * Extracts inherited built-in role names.
 */
static void
ParseRolesArray(bson_iter_t *rolesIter, CreateRoleSpec *createRoleSpec)
{
	if (bson_iter_type(rolesIter) != BSON_TYPE_ARRAY)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Expected 'array' type for 'roles' parameter but found '%s' type",
							BsonTypeName(bson_iter_type(rolesIter)))));
	}

	bson_iter_t rolesArrayIter;
	bson_iter_recurse(rolesIter, &rolesArrayIter);

	while (bson_iter_next(&rolesArrayIter))
	{
		if (bson_iter_type(&rolesArrayIter) != BSON_TYPE_UTF8)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Invalid inherited from role name provided.")));
		}

		uint32_t roleNameLength = 0;
		const char *inheritedBuiltInRole = bson_iter_utf8(&rolesArrayIter,
														  &roleNameLength);

		if (roleNameLength > 0 && roleNameLength < NAMEDATALEN)
		{
			hash_search(createRoleSpec->parentRoles, inheritedBuiltInRole, HASH_ENTER,
						NULL);
		}
	}
}


/*
 * ParsePrivilegesArray parses the privileges array from the createRole command.
 */
static void
ParsePrivilegesArray(bson_iter_t *privilegesIter, CreateRoleSpec *createRoleSpec)
{
	if (bson_iter_type(privilegesIter) != BSON_TYPE_ARRAY)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"'privileges' must be an array.")));
	}

	bson_iter_t privilegesArrayIter;
	bson_iter_recurse(privilegesIter, &privilegesArrayIter);

	while (bson_iter_next(&privilegesArrayIter))
	{
		if (bson_iter_type(&privilegesArrayIter) != BSON_TYPE_DOCUMENT)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Each privilege entry must be a document.")));
		}

		bson_iter_t privilegeDocIter;
		bson_iter_recurse(&privilegesArrayIter, &privilegeDocIter);

		StringView dbName = { 0 };
		StringView collectionName = { 0 };
		HTAB *actions = NULL;
		bool resourceFound = false;
		bool actionsFound = false;

		while (bson_iter_next(&privilegeDocIter))
		{
			const char *privilegeKey = bson_iter_key(&privilegeDocIter);

			if (strcmp(privilegeKey, "resource") == 0)
			{
				resourceFound = true;
				ParseResourceDocument(&privilegeDocIter, &dbName, &collectionName);
			}
			else if (strcmp(privilegeKey, "actions") == 0)
			{
				actionsFound = true;
				actions = ParseActionsArray(&privilegeDocIter);
			}
			else
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"The specified field '%s' is not supported in privilege.",
									privilegeKey)));
			}
		}

		if (!resourceFound)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"'resource' is required in privilege.")));
		}

		if (!actionsFound)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"'actions' is required in privilege.")));
		}

		if (dbName.string == NULL || collectionName.string == NULL || actions == NULL)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Internal error: privilege parsing produced NULL values for dbName, collectionName, or actions.")));
		}

		CustomPrivilege *customPrivilege = palloc(sizeof(CustomPrivilege));
		customPrivilege->dbName = dbName;
		customPrivilege->collectionName = collectionName;
		customPrivilege->actions = actions;

		createRoleSpec->customPrivileges = lappend(
			createRoleSpec->customPrivileges, customPrivilege);
	}
}


/*
 * ParseResourceDocument parses the "resource" field from a privilege entry.
 * Extracts the database and collection names as StringViews.
 * Both 'db' and 'collection' are required fields.
 */
static void
ParseResourceDocument(bson_iter_t *privilegeDocIter,
					  StringView *dbName,
					  StringView *collectionName)
{
	if (bson_iter_type(privilegeDocIter) != BSON_TYPE_DOCUMENT)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'resource' must be a document.")));
	}

	bson_iter_t resourceIter;
	bson_iter_recurse(privilegeDocIter, &resourceIter);

	bool dbFound = false;
	bool collectionFound = false;

	while (bson_iter_next(&resourceIter))
	{
		const char *resourceKey = bson_iter_key(&resourceIter);

		if (strcmp(resourceKey, "db") == 0)
		{
			if (bson_iter_type(&resourceIter) != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("'db' in resource must be a string.")));
			}

			uint32_t strLength = 0;
			const char *strValue = bson_iter_utf8(&resourceIter, &strLength);
			if (strValue == NULL || strLength == 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("'db' in resource must not be empty.")));
			}

			*dbName = CreateStringViewFromStringWithLength(strValue, strLength);
			dbFound = true;
		}
		else if (strcmp(resourceKey, "collection") == 0)
		{
			if (bson_iter_type(&resourceIter) != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"'collection' in resource must be a string.")));
			}

			uint32_t strLength = 0;
			const char *strValue = bson_iter_utf8(&resourceIter, &strLength);
			if (strValue == NULL || strLength == 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("'collection' in resource must not be empty.")));
			}

			*collectionName = CreateStringViewFromStringWithLength(strValue, strLength);
			collectionFound = true;
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"The specified field '%s' is not supported in resource.",
								resourceKey)));
		}
	}

	if (!dbFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'db' is required in resource.")));
	}

	if (!collectionFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'collection' is required in resource.")));
	}
}


/*
 * ParseActionsArray parses the "actions" field from a privilege entry.
 * Returns a hash set of action strings for automatic deduplication.
 */
static HTAB *
ParseActionsArray(bson_iter_t *privilegeDocIter)
{
	if (bson_iter_type(privilegeDocIter) != BSON_TYPE_ARRAY)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'actions' must be an array.")));
	}

	/* Create a hash set for deduplication */
	HASHCTL hashCtl;
	MemSet(&hashCtl, 0, sizeof(hashCtl));
	hashCtl.keysize = NAMEDATALEN;
	hashCtl.entrysize = NAMEDATALEN;
	HTAB *actions = hash_create("ActionsSet", 8, &hashCtl, HASH_ELEM | HASH_STRINGS);

	bson_iter_t actionsIter;
	bson_iter_recurse(privilegeDocIter, &actionsIter);

	while (bson_iter_next(&actionsIter))
	{
		if (bson_iter_type(&actionsIter) != BSON_TYPE_UTF8)
		{
			hash_destroy(actions);
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Each action must be a string.")));
		}

		uint32_t actionLength = 0;
		const char *action = bson_iter_utf8(&actionsIter, &actionLength);

		if (actionLength > 0 && actionLength < NAMEDATALEN)
		{
			if (!IsActionSupported(action))
			{
				hash_destroy(actions);
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("Unsupported action '%s'.",
									   action)));
			}

			hash_search(actions, action, HASH_ENTER, NULL);
		}
	}

	if (hash_get_num_entries(actions) == 0)
	{
		hash_destroy(actions);
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("At least one valid action must be specified.")));
	}

	return actions;
}


/*
 * update_role implements the core logic for updateRole command
 * Currently not supported.
 */
Datum
update_role(pgbson *updateRoleBson)
{
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
					errmsg("UpdateRole command is not supported in preview."),
					errdetail_log("UpdateRole command is not supported in preview.")));
}


/*
 * drop_role implements the core logic for dropRole command
 */
Datum
drop_role(pgbson *dropRoleBson)
{
	if (!EnableRoleCrud)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg("DropRole command is not supported."),
						errdetail_log("DropRole command is not supported.")));
	}

	if (!IsMetadataCoordinator())
	{
		StringInfo dropRoleQuery = makeStringInfo();
		appendStringInfo(dropRoleQuery,
						 "SELECT %s.drop_role(%s::%s.bson)",
						 ApiSchemaNameV2,
						 quote_literal_cstr(PgbsonToHexadecimalString(dropRoleBson)),
						 CoreSchemaNameV2);
		DistributedRunCommandResult result = RunCommandOnMetadataCoordinator(
			dropRoleQuery->data);

		if (!result.success)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Drop role operation failed: %s",
								text_to_cstring(result.response)),
							errdetail_log(
								"Drop role operation failed: %s",
								text_to_cstring(result.response))));
		}

		pgbson_writer finalWriter;
		PgbsonWriterInit(&finalWriter);
		PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
		return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
	}

	DropRoleSpec dropRoleSpec = { NULL };
	ParseDropRoleSpec(dropRoleBson, &dropRoleSpec);

	StringInfo dropUserInfo = makeStringInfo();
	appendStringInfo(dropUserInfo, "DROP ROLE %s;", quote_identifier(
						 dropRoleSpec.roleName));

	bool readOnly = false;
	bool isNull = false;
	ExtensionExecuteQueryViaSPI(dropUserInfo->data, readOnly, SPI_OK_UTILITY,
								&isNull);

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);
	PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
	return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
}


/*
 * ParseDropRoleSpec parses the dropRole command parameters
 */
static void
ParseDropRoleSpec(pgbson *dropRoleBson, DropRoleSpec *dropRoleSpec)
{
	bson_iter_t dropRoleIter;
	PgbsonInitIterator(dropRoleBson, &dropRoleIter);
	bool dbFound = false;
	while (bson_iter_next(&dropRoleIter))
	{
		const char *key = bson_iter_key(&dropRoleIter);

		if (strcmp(key, "dropRole") == 0)
		{
			EnsureTopLevelFieldType(key, &dropRoleIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			const char *roleNameValue = bson_iter_utf8(&dropRoleIter, &strLength);

			if (strLength == 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("'dropRole' cannot be empty.")));
			}

			if (IS_BUILTIN_ROLE(roleNameValue) || IS_SYSTEM_LOGIN_ROLE(roleNameValue))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Cannot drop built-in role '%s'.",
									roleNameValue)));
			}

			dropRoleSpec->roleName = pstrdup(roleNameValue);
		}
		else if (strcmp(key, "$db") == 0 && EnableRolesAdminDBCheck)
		{
			EnsureTopLevelFieldType(key, &dropRoleIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			const char *dbName = bson_iter_utf8(&dropRoleIter, &strLength);

			dbFound = true;
			if (strcmp(dbName, "admin") != 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"DropRole must be called from 'admin' database.")));
			}
		}
		else if (IsCommonSpecIgnoredField(key))
		{
			continue;
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Unsupported field specified: '%s'.", key)));
		}
	}

	if (!dbFound && EnableRolesAdminDBCheck)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("The required $db property is missing.")));
	}

	if (dropRoleSpec->roleName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'dropRole' is a required field.")));
	}
}


/*
 * roles_info implements the core logic for rolesInfo command
 */
Datum
roles_info(pgbson *rolesInfoBson)
{
	if (!EnableRoleCrud)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg("RolesInfo command is not supported."),
						errdetail_log("RolesInfo command is not supported.")));
	}

	if (!IsMetadataCoordinator())
	{
		StringInfo rolesInfoQuery = makeStringInfo();
		appendStringInfo(rolesInfoQuery,
						 "SELECT %s.roles_info(%s::%s.bson)",
						 ApiSchemaNameV2,
						 quote_literal_cstr(PgbsonToHexadecimalString(rolesInfoBson)),
						 CoreSchemaNameV2);
		DistributedRunCommandResult result = RunCommandOnMetadataCoordinator(
			rolesInfoQuery->data);

		if (!result.success)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Roles info operation failed: %s",
								text_to_cstring(result.response)),
							errdetail_log(
								"Roles info operation failed: %s",
								text_to_cstring(result.response))));
		}

		pgbson_writer finalWriter;
		PgbsonWriterInit(&finalWriter);
		PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
		return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
	}

	RolesInfoSpec rolesInfoSpec = {
		.roleNames = NIL,
		.showAllRoles = false,
		.showBuiltInRoles = false,
		.showPrivileges = false
	};
	ParseRolesInfoSpec(rolesInfoBson, &rolesInfoSpec);

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);

	pgbson_array_writer rolesArrayWriter;
	PgbsonWriterStartArray(&finalWriter, "roles", 5, &rolesArrayWriter);

	/*
	 * Build the role inheritance table once with a single query.
	 * This allows looking up parent/inherited roles in memory.
	 */
	HTAB *roleInheritanceTable = BuildRoleInheritanceTable();

	if (rolesInfoSpec.showAllRoles)
	{
		ProcessAllRolesForRolesInfo(&rolesArrayWriter, rolesInfoSpec,
									roleInheritanceTable);
	}
	else
	{
		ProcessSpecificRolesForRolesInfo(&rolesArrayWriter, rolesInfoSpec,
										 roleInheritanceTable);
	}

	FreeRoleInheritanceTable(roleInheritanceTable);

	if (rolesInfoSpec.roleNames != NIL)
	{
		list_free_deep(rolesInfoSpec.roleNames);
	}

	PgbsonWriterEndArray(&finalWriter, &rolesArrayWriter);
	PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);

	return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
}


/*
 * ParseRolesInfoSpec parses the rolesInfo command parameters
 */
static void
ParseRolesInfoSpec(pgbson *rolesInfoBson, RolesInfoSpec *rolesInfoSpec)
{
	bson_iter_t rolesInfoIter;
	PgbsonInitIterator(rolesInfoBson, &rolesInfoIter);

	rolesInfoSpec->roleNames = NIL;
	rolesInfoSpec->showAllRoles = false;
	rolesInfoSpec->showBuiltInRoles = false;
	rolesInfoSpec->showPrivileges = false;
	bool rolesInfoFound = false;
	bool dbFound = false;
	while (bson_iter_next(&rolesInfoIter))
	{
		const char *key = bson_iter_key(&rolesInfoIter);

		if (strcmp(key, "rolesInfo") == 0)
		{
			rolesInfoFound = true;
			if (bson_iter_type(&rolesInfoIter) == BSON_TYPE_INT32)
			{
				int32_t value = bson_iter_int32(&rolesInfoIter);
				if (value == 1)
				{
					rolesInfoSpec->showAllRoles = true;
				}
				else
				{
					ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
									errmsg(
										"'rolesInfo' must be 1, a string, a document, or an array.")));
				}
			}
			else if (bson_iter_type(&rolesInfoIter) == BSON_TYPE_ARRAY)
			{
				bson_iter_t rolesArrayIter;
				bson_iter_recurse(&rolesInfoIter, &rolesArrayIter);

				while (bson_iter_next(&rolesArrayIter))
				{
					ParseRoleDefinition(&rolesArrayIter, rolesInfoSpec);
				}
			}
			else
			{
				ParseRoleDefinition(&rolesInfoIter, rolesInfoSpec);
			}
		}
		else if (strcmp(key, "showBuiltInRoles") == 0)
		{
			if (BSON_ITER_HOLDS_BOOL(&rolesInfoIter))
			{
				rolesInfoSpec->showBuiltInRoles = bson_iter_as_bool(&rolesInfoIter);
			}
			else
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"'showBuiltInRoles' must be a boolean value")));
			}
		}
		else if (strcmp(key, "showPrivileges") == 0)
		{
			if (BSON_ITER_HOLDS_BOOL(&rolesInfoIter))
			{
				rolesInfoSpec->showPrivileges = bson_iter_as_bool(&rolesInfoIter);
			}
			else
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"'showPrivileges' must be a boolean value")));
			}
		}
		else if (strcmp(key, "$db") == 0 && EnableRolesAdminDBCheck)
		{
			EnsureTopLevelFieldType(key, &rolesInfoIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			const char *dbName = bson_iter_utf8(&rolesInfoIter, &strLength);

			dbFound = true;
			if (strcmp(dbName, "admin") != 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"RolesInfo must be called from 'admin' database.")));
			}
		}
		else if (IsCommonSpecIgnoredField(key))
		{
			continue;
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Unsupported field specified: '%s'.", key)));
		}
	}

	if (!dbFound && EnableRolesAdminDBCheck)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("The required $db property is missing.")));
	}

	if (!rolesInfoFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'rolesInfo' is a required field.")));
	}
}


/*
 * Helper function to parse a role document from an array element or single document
 */
static void
ParseRoleDocument(bson_iter_t *rolesArrayIter, RolesInfoSpec *rolesInfoSpec)
{
	bson_iter_t roleDocIter;
	bson_iter_recurse(rolesArrayIter, &roleDocIter);

	const char *roleName = NULL;
	uint32_t roleNameLength = 0;
	const char *dbName = NULL;
	uint32_t dbNameLength = 0;

	while (bson_iter_next(&roleDocIter))
	{
		const char *roleKey = bson_iter_key(&roleDocIter);

		if (strcmp(roleKey, "role") == 0)
		{
			if (bson_iter_type(&roleDocIter) != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("'role' field must be a string.")));
			}

			roleName = bson_iter_utf8(&roleDocIter, &roleNameLength);
		}

		/* db is required as part of every role document. */
		else if (strcmp(roleKey, "db") == 0)
		{
			if (bson_iter_type(&roleDocIter) != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("'db' field must be a string.")));
			}

			dbName = bson_iter_utf8(&roleDocIter, &dbNameLength);

			if (strcmp(dbName, "admin") != 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Unsupported value specified for db. Only 'admin' is allowed.")));
			}
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Unknown property '%s' in role document.", roleKey)));
		}
	}

	if (roleName == NULL || dbName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'role' and 'db' are required fields.")));
	}

	/* Only add role to the list if both role name and db name have valid lengths */
	if (roleNameLength > 0 && dbNameLength > 0)
	{
		rolesInfoSpec->roleNames = lappend(rolesInfoSpec->roleNames, pstrdup(roleName));
	}
}


/*
 * Helper function to parse a role definition (string or document)
 */
static void
ParseRoleDefinition(bson_iter_t *iter, RolesInfoSpec *rolesInfoSpec)
{
	if (bson_iter_type(iter) == BSON_TYPE_UTF8)
	{
		uint32_t roleNameLength = 0;
		const char *roleName = bson_iter_utf8(iter, &roleNameLength);

		/* If the string is empty, we will not add it to the list of roles to fetched */
		if (roleNameLength > 0)
		{
			rolesInfoSpec->roleNames = lappend(rolesInfoSpec->roleNames, pstrdup(
												   roleName));
		}
	}
	else if (bson_iter_type(iter) == BSON_TYPE_DOCUMENT)
	{
		ParseRoleDocument(iter, rolesInfoSpec);
	}
	else
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"'rolesInfo' must be 1, a string, a document, or an array.")));
	}
}


/*
 * ProcessAllRolesForRolesInfo handles the case when showAllRoles is true
 * Iterate over all roles in the pre-built inheritance table.
 */
static void
ProcessAllRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec
							rolesInfoSpec,
							HTAB *roleInheritanceTable)
{
	HASH_SEQ_STATUS status;
	RoleParentEntry *entry;

	hash_seq_init(&status, roleInheritanceTable);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		const char *internalRoleName = entry->internalRoleName;
		const char *nativeRoleName = entry->nativeRoleName;

		/* Exclude built-in roles if not requested */
		if (!rolesInfoSpec.showBuiltInRoles &&
			IS_NATIVE_BUILTIN_ROLE(nativeRoleName))
		{
			continue;
		}

		WriteRoleResponse(internalRoleName, rolesArrayWriter,
						  rolesInfoSpec, roleInheritanceTable);
	}
}


/*
 * ProcessSpecificRolesForRolesInfo handles the case when specific role names are requested
 */
static void
ProcessSpecificRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec
								 rolesInfoSpec,
								 HTAB *roleInheritanceTable)
{
	ListCell *currentRoleName;
	foreach(currentRoleName, rolesInfoSpec.roleNames)
	{
		const char *nativeRoleName = (const char *) lfirst(currentRoleName);

		/* Convert native role name to internal for HTAB lookup */
		const char *internalRoleName = GetInternalRoleName(nativeRoleName);

		/* Check if the role exists in the inheritance table */
		bool found = false;
		hash_search(roleInheritanceTable, internalRoleName, HASH_FIND, &found);

		/* If the role is not found, do not fail the request */
		if (found)
		{
			WriteRoleResponse(internalRoleName, rolesArrayWriter,
							  rolesInfoSpec, roleInheritanceTable);
		}
	}
}


/*
 * Recursively collect all inherited roles into the result hash set.
 * The hash set serves for both deduplication and collecting results.
 */
static void
CollectInheritedRolesRecursive(const char *internalRoleName, HTAB *roleInheritanceTable,
							   HTAB *resultSet)
{
	bool found = false;
	RoleParentEntry *entry = (RoleParentEntry *) hash_search(
		roleInheritanceTable, internalRoleName, HASH_FIND, &found);

	/*
	 * Role may not be found if it's a system role (oid < FirstNormalObjectId)
	 * that was referenced as a parent but not included in our inheritance table query.
	 * This is expected behavior - silently skip such roles.
	 */
	if (!found)
	{
		ereport(WARNING, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						  errmsg(
							  "Role '%s' not found.",
							  internalRoleName)));
	}

	if (entry->parentRoles == NIL)
	{
		return;
	}

	ListCell *cell;
	foreach(cell, entry->parentRoles)
	{
		char *parentName = (char *) lfirst(cell);

		/* Insert into resultSet; skip if already present */
		bool alreadyExists = false;
		hash_search(resultSet, parentName, HASH_ENTER, &alreadyExists);
		if (alreadyExists)
		{
			continue;
		}

		CollectInheritedRolesRecursive(parentName, roleInheritanceTable, resultSet);
	}
}


/*
 * Look up all inherited roles (transitive closure) from the pre-built role
 * inheritance table using recursive traversal.
 *
 * Handles diamond inheritance (e.g., role A inherits B and C, both B and C
 * inherit D) by using a hash set that serves for both deduplication and
 * collecting results.
 */
static List *
LookupAllInheritedRoles(const char *internalRoleName, HTAB *roleInheritanceTable)
{
	HASHCTL resultCtl;
	MemSet(&resultCtl, 0, sizeof(resultCtl));
	resultCtl.keysize = NAMEDATALEN;
	resultCtl.entrysize = NAMEDATALEN;
	HTAB *resultSet = hash_create("InheritedRolesSet", 32, &resultCtl,
								  HASH_ELEM | HASH_STRINGS);

	CollectInheritedRolesRecursive(internalRoleName, roleInheritanceTable, resultSet);

	/* Convert hash set to list */
	List *result = NIL;
	HASH_SEQ_STATUS status;
	char *entry;
	hash_seq_init(&status, resultSet);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		result = lappend(result, pstrdup(entry));
	}

	hash_destroy(resultSet);
	return result;
}


/*
 * WriteRoles writes the parent roles to the roles array.
 * Each internal role name is looked up in the inheritance table to get
 * its native name for output.
 */
static void
WriteRoles(List *parentRoles, pgbson_array_writer *rolesArrayWriter,
		   HTAB *roleInheritanceTable, const char *childRoleName)
{
	ListCell *roleCell;
	foreach(roleCell, parentRoles)
	{
		const char *internalParentRole = (const char *) lfirst(roleCell);

		/* Look up parent role in HTAB to get its native name */
		bool parentFound = false;
		RoleParentEntry *parentEntry = (RoleParentEntry *) hash_search(
			roleInheritanceTable, internalParentRole, HASH_FIND, &parentFound);
		if (!parentFound)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Parent role '%s' of '%s' not found.",
								   internalParentRole, childRoleName)));
		}

		pgbson_writer parentRoleWriter;
		PgbsonArrayWriterStartDocument(rolesArrayWriter, &parentRoleWriter);
		PgbsonWriterAppendUtf8(&parentRoleWriter, "role", 4,
							   parentEntry->nativeRoleName);
		PgbsonWriterAppendUtf8(&parentRoleWriter, "db", 2, "admin");
		PgbsonArrayWriterEndDocument(rolesArrayWriter, &parentRoleWriter);
	}
}


/*
 * Primitive type properties include _id, role, db, isBuiltin.
 * privileges: supported privilege actions of this role if defined.
 * roles: 1st level directly inherited roles if defined.
 * allInheritedRoles: all recursively inherited roles if defined.
 * inheritedPrivileges: consolidated privileges of current role and all recursively inherited roles if defined.
 */
static void
WriteRoleResponse(const char *internalRoleName,
				  pgbson_array_writer *rolesArrayWriter,
				  RolesInfoSpec rolesInfoSpec,
				  HTAB *roleInheritanceTable)
{
	bool foundEntry = false;
	RoleParentEntry *entry = (RoleParentEntry *) hash_search(
		roleInheritanceTable, internalRoleName, HASH_FIND, &foundEntry);
	if (!foundEntry)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Role '%s' not found.",
							   internalRoleName)));
	}

	pgbson_writer roleDocumentWriter;
	PgbsonArrayWriterStartDocument(rolesArrayWriter, &roleDocumentWriter);

	const char *nativeRoleName = entry->nativeRoleName;
	char *roleId = psprintf("admin.%s", nativeRoleName);
	PgbsonWriterAppendUtf8(&roleDocumentWriter, "_id", 3, roleId);
	pfree(roleId);

	PgbsonWriterAppendUtf8(&roleDocumentWriter, "role", 4, nativeRoleName);
	PgbsonWriterAppendUtf8(&roleDocumentWriter, "db", 2, "admin");
	PgbsonWriterAppendBool(&roleDocumentWriter, "isBuiltIn", 9,
						   IS_NATIVE_BUILTIN_ROLE(nativeRoleName));

	if (rolesInfoSpec.showPrivileges)
	{
		pgbson_array_writer privilegesArrayWriter;
		PgbsonWriterStartArray(&roleDocumentWriter, "privileges", 10,
							   &privilegesArrayWriter);
		WritePrivileges(entry->internalRoleName, &privilegesArrayWriter);
		PgbsonWriterEndArray(&roleDocumentWriter, &privilegesArrayWriter);
	}

	/* Write direct roles - parent roles are stored as internal names, convert to native names */
	pgbson_array_writer parentRolesArrayWriter;
	PgbsonWriterStartArray(&roleDocumentWriter, "roles", 5, &parentRolesArrayWriter);
	WriteRoles(entry->parentRoles, &parentRolesArrayWriter, roleInheritanceTable,
			   internalRoleName);
	PgbsonWriterEndArray(&roleDocumentWriter, &parentRolesArrayWriter);

	List *allInheritedRoles = LookupAllInheritedRoles(internalRoleName,
													  roleInheritanceTable);
	pgbson_array_writer inheritedRolesArrayWriter;
	PgbsonWriterStartArray(&roleDocumentWriter, "allInheritedRoles", 17,
						   &inheritedRolesArrayWriter);
	ListCell *roleCell;
	foreach(roleCell, allInheritedRoles)
	{
		const char *inheritedInternalName = (const char *) lfirst(roleCell);

		/* Look up inherited role in HTAB to get its native name */
		bool inheritedFound = false;
		RoleParentEntry *inheritedEntry = (RoleParentEntry *) hash_search(
			roleInheritanceTable, inheritedInternalName, HASH_FIND, &inheritedFound);
		if (!inheritedFound)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Inherited role '%s' of '%s' not found.",
								inheritedInternalName, internalRoleName)));
		}

		pgbson_writer inheritedRoleWriter;
		PgbsonArrayWriterStartDocument(&inheritedRolesArrayWriter, &inheritedRoleWriter);
		PgbsonWriterAppendUtf8(&inheritedRoleWriter, "role", 4,
							   inheritedEntry->nativeRoleName);
		PgbsonWriterAppendUtf8(&inheritedRoleWriter, "db", 2, "admin");
		PgbsonArrayWriterEndDocument(&inheritedRolesArrayWriter, &inheritedRoleWriter);
	}
	PgbsonWriterEndArray(&roleDocumentWriter, &inheritedRolesArrayWriter);

	/* Write inherited privileges (privileges from all inherited roles) */
	if (rolesInfoSpec.showPrivileges)
	{
		pgbson_array_writer inheritedPrivilegesArrayWriter;
		PgbsonWriterStartArray(&roleDocumentWriter, "inheritedPrivileges", 19,
							   &inheritedPrivilegesArrayWriter);

		HTAB *privilegeLookupRoleNames = CreateStringViewHashSet();

		StringView selfRoleView = {
			.string = entry->internalRoleName,
			.length = strlen(entry->internalRoleName)
		};
		hash_search(privilegeLookupRoleNames, &selfRoleView, HASH_ENTER, NULL);

		foreach(roleCell, allInheritedRoles)
		{
			const char *inheritedInternalName = (const char *) lfirst(roleCell);
			StringView inheritedRoleView = {
				.string = inheritedInternalName,
				.length = strlen(inheritedInternalName)
			};
			hash_search(privilegeLookupRoleNames, &inheritedRoleView, HASH_ENTER, NULL);
		}

		WriteMultipleRolePrivileges(privilegeLookupRoleNames,
									&inheritedPrivilegesArrayWriter);
		hash_destroy(privilegeLookupRoleNames);

		PgbsonWriterEndArray(&roleDocumentWriter, &inheritedPrivilegesArrayWriter);
	}

	PgbsonArrayWriterEndDocument(rolesArrayWriter, &roleDocumentWriter);

	if (allInheritedRoles != NIL)
	{
		list_free_deep(allInheritedRoles);
	}
}


/*
 * BuildRoleInheritanceTable fetches all roles and their parent relationships
 * and builds an in-memory hash table for efficient lookups.
 *
 * Role System Overview:
 * - pg_roles contains information about both user roles and groups.
 * - pg_auth_members tracks role membership: which roles are members of which
 *   parent roles. Note that parent roles can themselves have parents
 *
 * Query Logic:
 * This query finds, for each custom role (excluding internal roles
 * which have oid < FirstNormalObjectId), what parent roles it inherits from.
 * We filter both child and parent roles by oid >= FirstNormalObjectId to exclude
 * system roles.
 *
 * Hash Table Structure:
 * - Key: internal role name (char[NAMEDATALEN])
 * - Value: RoleParentEntry struct containing:
 *   - internalRoleName: the internal role name stored in pg_roles table
 *   - nativeRoleName: the native role name displayed to user
 *   - parentRoles: List of internal parent role names this role inherits from
 */
static HTAB *
BuildRoleInheritanceTable(void)
{
	HASHCTL hashCtl;
	memset(&hashCtl, 0, sizeof(hashCtl));
	hashCtl.keysize = NAMEDATALEN;
	hashCtl.entrysize = sizeof(RoleParentEntry);
	hashCtl.hcxt = CurrentMemoryContext;

	HTAB *roleInheritanceTable = hash_create("RoleInheritanceTable",
											 64,
											 &hashCtl,
											 HASH_ELEM | HASH_STRINGS | HASH_CONTEXT);

	/*
	 * Query returns all built-in and custom roles with their direct parent roles, all in internal role names.
	 */
	const char *inheritanceQuery = FormatSqlQuery(
		"SELECT ARRAY_AGG(%s.row_get_bson(r)) FROM ("
		"  SELECT "
		"    child.rolname::text AS child_role, "
		"    ARRAY_AGG(parent.rolname::text) "
		"      FILTER (WHERE parent.rolname IS NOT NULL AND parent.oid >= %d) AS parent_roles "
		"  FROM pg_roles child "
		"  LEFT JOIN pg_auth_members am ON am.member = child.oid "
		"  LEFT JOIN pg_roles parent ON parent.oid = am.roleid "
		"  WHERE child.oid >= %d "
		"    AND (NOT child.rolcanlogin OR child.rolname = '%s') "
		"  GROUP BY child.rolname"
		") r;",
		CoreSchemaName,
		FirstNormalObjectId,
		FirstNormalObjectId,
		ApiRootInternalRole);

	bool readOnly = true;
	bool isNull = false;

	Datum resultDatum = ExtensionExecuteQueryViaSPI(inheritanceQuery, readOnly,
													SPI_OK_SELECT, &isNull);

	/*
	 * If result is NULL, no roles matched the query, which should never happen.
	 */
	if (isNull)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Role inheritance query returned NULL result.")));
	}

	ArrayType *resultArray = DatumGetArrayTypeP(resultDatum);

	Datum *rowDatums;
	bool *rowNulls;
	int rowCount;
	deconstruct_array(resultArray, BsonTypeId(), -1, false, TYPALIGN_INT,
					  &rowDatums, &rowNulls, &rowCount);

	for (int i = 0; i < rowCount; i++)
	{
		/*
		 * A NULL array element would mean row_get_bson() returned NULL for a valid row, which should never happen.
		 */
		if (rowNulls[i])
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Unexpected NULL element at index %d in role inheritance query result.",
								i)));
		}

		pgbson *rowBson = DatumGetPgBson(rowDatums[i]);
		const char *childRole = NULL;
		List *parentRoles = NIL;

		ParseRoleInheritanceResult(rowBson, &childRole, &parentRoles);

		if (childRole == NULL)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Missing 'child_role' field in role inheritance query result at index %d.",
								i)));
		}

		/*
		 * Skip roles that should not appear in the role inheritance table:
		 * - System login roles
		 * - ApiAdminRoleV2: internal role that maps to both readWriteAnyDatabase
		 *   and clusterAdmin; we add separate entries for these at the end
		 * - ApiAdminRole: legacy admin role
		 */
		if (IS_SYSTEM_LOGIN_ROLE(childRole) ||
			strcmp(childRole, ApiAdminRoleV2) == 0 ||
			strcmp(childRole, ApiAdminRole) == 0)
		{
			if (parentRoles != NIL)
			{
				list_free_deep(parentRoles);
			}
			continue;
		}

		bool found;
		RoleParentEntry *entry = hash_search(roleInheritanceTable, childRole,
											 HASH_ENTER, &found);

		if (found)
		{
			/*
			 * Duplicate child_role in the result set should never happen due to GROUP BY in the query.
			 */
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Duplicate 'child_role' '%s' found in role inheritance query result.",
								childRole)));
		}
		else
		{
			strlcpy(entry->internalRoleName, childRole, NAMEDATALEN);
			strlcpy(entry->nativeRoleName, GetNativeRoleName(childRole), NAMEDATALEN);
			entry->parentRoles = NIL;
		}

		if (parentRoles != NIL)
		{
			ListCell *cell;
			foreach(cell, parentRoles)
			{
				const char *parentRole = (const char *) lfirst(cell);

				/*
				 * ApiAdminRoleV2 represents both readWriteAnyDatabase and clusterAdmin.
				 * When we encounter it as a parent, add both ApiReadWriteRole and
				 * ApiClusterAdminRole instead to properly represent the inheritance.
				 */
				if (strcmp(parentRole, ApiAdminRoleV2) == 0)
				{
					entry->parentRoles = lappend(entry->parentRoles,
												 pstrdup(ApiReadWriteRole));
					entry->parentRoles = lappend(entry->parentRoles,
												 pstrdup(ApiClusterAdminRole));
					pfree(lfirst(cell));
				}
				else
				{
					entry->parentRoles = lappend(entry->parentRoles, lfirst(cell));
				}
			}
			list_free(parentRoles);
		}
	}

	bool found;

	RoleParentEntry *rwEntry = hash_search(roleInheritanceTable, ApiReadWriteRole,
										   HASH_ENTER, &found);
	if (!found)
	{
		strlcpy(rwEntry->internalRoleName, ApiReadWriteRole, NAMEDATALEN);
		strlcpy(rwEntry->nativeRoleName, "readWriteAnyDatabase", NAMEDATALEN);
		rwEntry->parentRoles = NIL;
	}

	RoleParentEntry *caEntry = hash_search(roleInheritanceTable, ApiClusterAdminRole,
										   HASH_ENTER, &found);
	if (!found)
	{
		strlcpy(caEntry->internalRoleName, ApiClusterAdminRole, NAMEDATALEN);
		strlcpy(caEntry->nativeRoleName, "clusterAdmin", NAMEDATALEN);
		caEntry->parentRoles = NIL;
	}

	return roleInheritanceTable;
}


/*
 * ParseRoleInheritanceResult parses a BSON document from the role inheritance query.
 * Extracts the child_role and parent_roles fields.
 */
static void
ParseRoleInheritanceResult(pgbson *rowBson, const char **childRole, List **parentRoles)
{
	bson_iter_t iter;
	PgbsonInitIterator(rowBson, &iter);

	*childRole = NULL;
	*parentRoles = NIL;

	while (bson_iter_next(&iter))
	{
		const char *key = bson_iter_key(&iter);

		if (strcmp(key, "child_role") == 0)
		{
			if (bson_iter_type(&iter) != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg(
									"Invalid type for 'child_role' in role inheritance query result.")));
			}

			*childRole = bson_iter_utf8(&iter, NULL);
		}
		else if (strcmp(key, "parent_roles") == 0)
		{
			if (bson_iter_type(&iter) != BSON_TYPE_ARRAY)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg(
									"Invalid type for 'parent_roles' in role inheritance query result.")));
			}

			bson_iter_t arrayIter;
			bson_iter_recurse(&iter, &arrayIter);
			while (bson_iter_next(&arrayIter))
			{
				if (bson_iter_type(&arrayIter) != BSON_TYPE_UTF8)
				{
					ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
									errmsg(
										"Invalid type for element in 'parent_roles' array in role inheritance query result.")));
				}

				const char *parentRole = bson_iter_utf8(&arrayIter, NULL);
				*parentRoles = lappend(*parentRoles, pstrdup(parentRole));
			}
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Unknown field '%s' in role inheritance query result.",
								key)));
		}
	}
}


/*
 * FreeRoleInheritanceTable releases all memory associated with the table.
 */
static void
FreeRoleInheritanceTable(HTAB *roleInheritanceTable)
{
	if (roleInheritanceTable == NULL)
	{
		return;
	}

	HASH_SEQ_STATUS status;
	RoleParentEntry *entry;
	hash_seq_init(&status, roleInheritanceTable);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		if (entry->parentRoles != NIL)
		{
			list_free_deep(entry->parentRoles);
		}
	}

	hash_destroy(roleInheritanceTable);
}


/*
 * ValidateAndGrantInheritedRoles validates all parent roles and grants them.
 * Enforces that readWriteAnyDatabase and clusterAdmin must be specified together.
 */
static void
ValidateAndGrantInheritedRoles(const CreateRoleSpec *createRoleSpec)
{
	HASH_SEQ_STATUS status;
	char *entry;
	bool hasReadWrite = false;
	bool hasClusterAdmin = false;

	hash_seq_init(&status, createRoleSpec->parentRoles);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		const char *roleName = entry;

		if (strcmp(roleName, "readWriteAnyDatabase") == 0)
		{
			hasReadWrite = true;
		}
		else if (strcmp(roleName, "clusterAdmin") == 0)
		{
			hasClusterAdmin = true;
		}
	}

	if (hasReadWrite != hasClusterAdmin)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together."),
						errdetail_log(
							"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together.")));
	}

	/*
	 * If both readWriteAnyDatabase and clusterAdmin are specified, grant
	 * ApiAdminRoleV2 once (which provides both capabilities).
	 */
	bool grantedApiAdminRole = false;
	if (hasReadWrite && hasClusterAdmin)
	{
		grantedApiAdminRole = true;
		GrantRoleInheritance(ApiAdminRoleV2, createRoleSpec->roleName);
	}

	hash_seq_init(&status, createRoleSpec->parentRoles);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		const char *nativeRoleName = entry;
		const char *internalRoleName = GetInternalRoleName(nativeRoleName);

		/*
		 * Skip readWriteAnyDatabase and clusterAdmin if we already granted
		 * ApiAdminRoleV2, which provides both capabilities.
		 */
		if (grantedApiAdminRole &&
			(strcmp(internalRoleName, ApiReadWriteRole) == 0 ||
			 strcmp(internalRoleName, ApiClusterAdminRole) == 0))
		{
			continue;
		}

		GrantRoleInheritance(internalRoleName, createRoleSpec->roleName);
	}
}


/*
 * CreateParentRolesHashSet creates a hash set for storing parent role names.
 */
static HTAB *
CreateParentRolesHashSet(void)
{
	HASHCTL hashCtl;
	memset(&hashCtl, 0, sizeof(hashCtl));
	hashCtl.keysize = NAMEDATALEN;
	hashCtl.entrysize = NAMEDATALEN;  /* Key-only hash set */
	hashCtl.hcxt = CurrentMemoryContext;

	return hash_create("ParentRolesSet", 16, &hashCtl,
					   HASH_ELEM | HASH_STRINGS | HASH_CONTEXT);
}


/*
 * GetInternalRoleName maps native role names to internal role names.
 */
static const char *
GetInternalRoleName(const char *nativeRoleName)
{
	if (strcmp(nativeRoleName, "clusterAdmin") == 0)
	{
		return ApiClusterAdminRole;
	}
	else if (strcmp(nativeRoleName, "readAnyDatabase") == 0)
	{
		return ApiReadOnlyRole;
	}
	else if (strcmp(nativeRoleName, "readWriteAnyDatabase") == 0)
	{
		return ApiReadWriteRole;
	}
	else if (strcmp(nativeRoleName, "root") == 0)
	{
		return ApiRootInternalRole;
	}

	return nativeRoleName;
}


/*
 * GetNativeRoleName maps internal role names to native
 * role names. This is the inverse of GetInternalRoleName.
 */
static const char *
GetNativeRoleName(const char *internalRoleName)
{
	if (strcmp(internalRoleName, ApiClusterAdminRole) == 0)
	{
		return "clusterAdmin";
	}
	else if (strcmp(internalRoleName, ApiReadOnlyRole) == 0)
	{
		return "readAnyDatabase";
	}
	else if (strcmp(internalRoleName, ApiReadWriteRole) == 0)
	{
		return "readWriteAnyDatabase";
	}
	else if (strcmp(internalRoleName, ApiRootInternalRole) == 0)
	{
		return "root";
	}

	return internalRoleName;
}


/*
 * GrantRoleInheritance grants a parent role to the target role.
 * Only allows inheriting from roles in IS_INHERITABLE_ROLE whitelist.
 */
static void
GrantRoleInheritance(const char *parentRole, const char *targetRole)
{
	if (!IS_INHERITABLE_ROLE(parentRole))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Creating custom roles that inherit from '%s' is not supported.",
							GetNativeRoleName(parentRole))));
	}

	bool readOnly = false;
	bool isNull = false;

	StringInfo grantRoleInfo = makeStringInfo();
	appendStringInfo(grantRoleInfo, "GRANT %s TO %s",
					 quote_identifier(parentRole),
					 quote_identifier(targetRole));

	ExtensionExecuteQueryViaSPI(grantRoleInfo->data, readOnly, SPI_OK_UTILITY,
								&isNull);
}


/*
 * Check if an action string is in the SupportedActions list.
 */
static bool
IsActionSupported(const char *action)
{
	for (int i = 0; i < NumSupportedActions; i++)
	{
		if (strcmp(action, SupportedActions[i]) == 0)
		{
			return true;
		}
	}
	return false;
}
