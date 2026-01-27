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
	List *parentRoles;
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
 * Struct to a role and its parent roles
 */
typedef struct RoleParentEntry
{
	char roleName[NAMEDATALEN];
	List *parentRoles;
} RoleParentEntry;

static void ParseCreateRoleSpec(pgbson *createRoleBson, CreateRoleSpec *createRoleSpec);
static void ParseRolesArray(bson_iter_t *rolesIter, CreateRoleSpec *createRoleSpec);
static void ParsePrivilegesArray(bson_iter_t *privilegesIter,
								 CreateRoleSpec *createRoleSpec);
static void ParseResourceDocument(bson_iter_t *privilegeDocIter, StringView *dbName,
								  StringView *collectionName);
static HTAB * ParseActionsArray(bson_iter_t *privilegeDocIter);
static void GrantInheritedRoles(const CreateRoleSpec *createRoleSpec);
static void ParseDropRoleSpec(pgbson *dropRoleBson, DropRoleSpec *dropRoleSpec);
static void ParseRolesInfoSpec(pgbson *rolesInfoBson, RolesInfoSpec *rolesInfoSpec);
static void ParseRoleDefinition(bson_iter_t *iter, RolesInfoSpec *rolesInfoSpec);
static void ParseRoleDocument(bson_iter_t *rolesArrayIter, RolesInfoSpec *rolesInfoSpec);
static void ProcessAllRoles(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec
							rolesInfoSpec, HTAB *roleInheritanceTable);
static void ProcessSpecificRoles(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec
								 rolesInfoSpec, HTAB *roleInheritanceTable);
static void WriteRoleResponse(const char *roleName,
							  pgbson_array_writer *rolesArrayWriter,
							  RolesInfoSpec rolesInfoSpec,
							  HTAB *roleInheritanceTable);
static HTAB * BuildRoleInheritanceTable(void);
static void ParseRoleInheritanceResult(pgbson *rowBson, const char **childRole,
									   List **parentRoles);
static void FreeRoleInheritanceTable(HTAB *roleInheritanceTable);
static void CollectInheritedRolesRecursive(const char *roleName,
										   HTAB *roleInheritanceTable,
										   HTAB *resultSet);
static List * LookupAllInheritedRoles(const char *roleName, HTAB *roleInheritanceTable);
static bool IsActionSupported(const char *action);

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

	CreateRoleSpec createRoleSpec = { NULL, NIL, NIL };
	ParseCreateRoleSpec(createRoleBson, &createRoleSpec);

	/* Create the specified role in the database */
	StringInfo createRoleInfo = makeStringInfo();
	appendStringInfo(createRoleInfo, "CREATE ROLE %s", quote_identifier(
						 createRoleSpec.roleName));

	bool readOnly = false;
	bool isNull = false;
	ExtensionExecuteQueryViaSPI(createRoleInfo->data, readOnly, SPI_OK_UTILITY, &isNull);

	/* Grant inherited roles to the new role */
	GrantInheritedRoles(&createRoleSpec);

	ListCell *cell;
	foreach(cell, createRoleSpec.customPrivileges)
	{
		CustomPrivilege *privilege = (CustomPrivilege *) lfirst(cell);
		hash_destroy(privilege->actions);
	}
	list_free_deep(createRoleSpec.customPrivileges);

	list_free_deep(createRoleSpec.parentRoles);

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

		if (roleNameLength > 0)
		{
			createRoleSpec->parentRoles = lappend(
				createRoleSpec->parentRoles,
				pstrdup(inheritedBuiltInRole));
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
 * GrantInheritedRoles grants the inherited built-in roles to the new role.
 * Validates that each role is a supported built-in role before granting.
 */
static void
GrantInheritedRoles(const CreateRoleSpec *createRoleSpec)
{
	bool readOnly = false;
	bool isNull = false;

	ListCell *currentRole;
	foreach(currentRole, createRoleSpec->parentRoles)
	{
		const char *inheritedRole = (const char *) lfirst(currentRole);

		if (!IS_BUILTIN_ROLE(inheritedRole))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_ROLENOTFOUND),
							errmsg("Role '%s' not supported.",
								   inheritedRole)));
		}

		StringInfo grantRoleInfo = makeStringInfo();
		appendStringInfo(grantRoleInfo, "GRANT %s TO %s",
						 quote_identifier(inheritedRole),
						 quote_identifier(createRoleSpec->roleName));

		ExtensionExecuteQueryViaSPI(grantRoleInfo->data, readOnly, SPI_OK_UTILITY,
									&isNull);
	}
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
		ProcessAllRoles(&rolesArrayWriter, rolesInfoSpec, roleInheritanceTable);
	}
	else
	{
		ProcessSpecificRoles(&rolesArrayWriter, rolesInfoSpec, roleInheritanceTable);
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
 * ProcessAllRoles handles the case when showAllRoles is true
 * Iterate over all roles in the pre-built inheritance table.
 */
static void
ProcessAllRoles(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec rolesInfoSpec,
				HTAB *roleInheritanceTable)
{
	HASH_SEQ_STATUS status;
	RoleParentEntry *entry;

	hash_seq_init(&status, roleInheritanceTable);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		const char *roleName = entry->roleName;

		/* Exclude system login roles and built-in roles if not requested */
		if (IS_SYSTEM_LOGIN_ROLE(roleName) ||
			(IS_BUILTIN_ROLE(roleName) && !rolesInfoSpec.showBuiltInRoles))
		{
			continue;
		}

		WriteRoleResponse(roleName, rolesArrayWriter,
						  rolesInfoSpec, roleInheritanceTable);
	}
}


/*
 * ProcessSpecificRoles handles the case when specific role names are requested
 */
static void
ProcessSpecificRoles(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec rolesInfoSpec,
					 HTAB *roleInheritanceTable)
{
	ListCell *currentRoleName;
	foreach(currentRoleName, rolesInfoSpec.roleNames)
	{
		const char *requestedRoleName = (const char *) lfirst(currentRoleName);

		/* Translate public role name to internal name for lookup */
		const char *lookupName = requestedRoleName;
		if (strcmp(requestedRoleName, ApiRootRole) == 0)
		{
			lookupName = ApiRootInternalRole;
		}

		/* Check if the role exists in the inheritance table */
		bool found = false;
		hash_search(roleInheritanceTable, lookupName, HASH_FIND, &found);

		/* If the role is not found, do not fail the request */
		if (found)
		{
			WriteRoleResponse(lookupName, rolesArrayWriter,
							  rolesInfoSpec, roleInheritanceTable);
		}
	}
}


/*
 * Recursively collect all inherited roles into the result hash set.
 * The hash set serves for both deduplication and collecting results.
 */
static void
CollectInheritedRolesRecursive(const char *roleName, HTAB *roleInheritanceTable,
							   HTAB *resultSet)
{
	bool found = false;
	RoleParentEntry *entry = (RoleParentEntry *) hash_search(
		roleInheritanceTable, roleName, HASH_FIND, &found);

	/*
	 * Role may not be found if it's a PostgreSQL system role (oid < FirstNormalObjectId)
	 * that was referenced as a parent but not included in our inheritance table query.
	 * This is expected behavior - silently skip such roles.
	 */
	if (!found)
	{
		return;
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
 * Returns a List of role name strings (caller must free with list_free_deep).
 *
 * Handles diamond inheritance (e.g., role A inherits B and C, both B and C
 * inherit D) by using a hash set that serves for both deduplication and
 * collecting results.
 */
static List *
LookupAllInheritedRoles(const char *roleName, HTAB *roleInheritanceTable)
{
	/* Create a hash set to collect unique inherited roles */
	HASHCTL resultCtl;
	MemSet(&resultCtl, 0, sizeof(resultCtl));
	resultCtl.keysize = NAMEDATALEN;
	resultCtl.entrysize = NAMEDATALEN;
	HTAB *resultSet = hash_create("InheritedRolesSet", 32, &resultCtl,
								  HASH_ELEM | HASH_STRINGS);

	CollectInheritedRolesRecursive(roleName, roleInheritanceTable, resultSet);

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
 * Primitive type properties include _id, role, db, isBuiltin.
 * privileges: supported privilege actions of this role if defined.
 * roles property: 1st level directly inherited roles if defined.
 * allInheritedRoles: all recursively inherited roles if defined.
 * inheritedPrivileges: consolidated privileges of current role and all recursively inherited roles if defined.
 * roleInheritanceTable: pre-built hash table of role inheritance for efficient lookups.
 */
static void
WriteRoleResponse(const char *roleName,
				  pgbson_array_writer *rolesArrayWriter,
				  RolesInfoSpec rolesInfoSpec,
				  HTAB *roleInheritanceTable)
{
	pgbson_writer roleDocumentWriter;
	PgbsonArrayWriterStartDocument(rolesArrayWriter, &roleDocumentWriter);

	char *roleId = psprintf("admin.%s", roleName);
	PgbsonWriterAppendUtf8(&roleDocumentWriter, "_id", 3, roleId);
	pfree(roleId);

	PgbsonWriterAppendUtf8(&roleDocumentWriter, "role", 4, roleName);
	PgbsonWriterAppendUtf8(&roleDocumentWriter, "db", 2, "admin");
	PgbsonWriterAppendBool(&roleDocumentWriter, "isBuiltIn", 9,
						   IS_BUILTIN_ROLE(roleName));

	/* Write direct privileges */
	if (rolesInfoSpec.showPrivileges)
	{
		pgbson_array_writer privilegesArrayWriter;
		PgbsonWriterStartArray(&roleDocumentWriter, "privileges", 10,
							   &privilegesArrayWriter);
		WriteSingleRolePrivileges(roleName, &privilegesArrayWriter);
		PgbsonWriterEndArray(&roleDocumentWriter, &privilegesArrayWriter);
	}

	/* Write direct roles - lookup from role inheritance table */
	bool foundEntry = false;
	RoleParentEntry *entry = (RoleParentEntry *) hash_search(
		roleInheritanceTable, roleName, HASH_FIND, &foundEntry);

	/*
	 * foundEntry should always be true since callers (ProcessAllRoles and
	 * ProcessSpecificRoles) verify role existence before calling this function.
	 * This is a defensive check - if triggered, it indicates a bug in the calling code.
	 */
	if (!foundEntry)
	{
		ereport(DEBUG1, errmsg("Role '%s' not found in inheritance table", roleName));
	}

	List *parentRoles = (foundEntry && entry->parentRoles != NIL) ?
						entry->parentRoles : NIL;

	pgbson_array_writer parentRolesArrayWriter;
	PgbsonWriterStartArray(&roleDocumentWriter, "roles", 5, &parentRolesArrayWriter);
	ListCell *roleCell;
	foreach(roleCell, parentRoles)
	{
		const char *parentRoleName = (const char *) lfirst(roleCell);
		pgbson_writer parentRoleDocWriter;
		PgbsonArrayWriterStartDocument(&parentRolesArrayWriter,
									   &parentRoleDocWriter);
		PgbsonWriterAppendUtf8(&parentRoleDocWriter, "role", 4, parentRoleName);
		PgbsonWriterAppendUtf8(&parentRoleDocWriter, "db", 2, "admin");
		PgbsonArrayWriterEndDocument(&parentRolesArrayWriter, &parentRoleDocWriter);
	}
	PgbsonWriterEndArray(&roleDocumentWriter, &parentRolesArrayWriter);

	/* Write inherited roles */
	List *allInheritedRoles = LookupAllInheritedRoles(roleName, roleInheritanceTable);
	pgbson_array_writer inheritedRolesArrayWriter;
	PgbsonWriterStartArray(&roleDocumentWriter, "allInheritedRoles", 17,
						   &inheritedRolesArrayWriter);
	foreach(roleCell, allInheritedRoles)
	{
		const char *inheritedRoleName = (const char *) lfirst(roleCell);
		pgbson_writer inheritedRoleDocWriter;
		PgbsonArrayWriterStartDocument(&inheritedRolesArrayWriter,
									   &inheritedRoleDocWriter);
		PgbsonWriterAppendUtf8(&inheritedRoleDocWriter, "role", 4, inheritedRoleName);
		PgbsonWriterAppendUtf8(&inheritedRoleDocWriter, "db", 2, "admin");
		PgbsonArrayWriterEndDocument(&inheritedRolesArrayWriter, &inheritedRoleDocWriter);
	}
	PgbsonWriterEndArray(&roleDocumentWriter, &inheritedRolesArrayWriter);

	/* Write inherited privileges (privileges from all inherited roles) */
	if (rolesInfoSpec.showPrivileges)
	{
		pgbson_array_writer inheritedPrivilegesArrayWriter;
		PgbsonWriterStartArray(&roleDocumentWriter, "inheritedPrivileges", 19,
							   &inheritedPrivilegesArrayWriter);

		WriteSingleRolePrivileges(roleName, &inheritedPrivilegesArrayWriter);

		foreach(roleCell, allInheritedRoles)
		{
			const char *inheritedRoleName = (const char *) lfirst(roleCell);
			WriteSingleRolePrivileges(inheritedRoleName, &inheritedPrivilegesArrayWriter);
		}

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
 * PostgreSQL Role System Overview:
 * - pg_roles contains information about both user roles and groups.
 * - pg_auth_members tracks role membership: which roles are members of which
 *   parent roles. Note that parent roles can themselves have parents
 *
 * Query Logic:
 * This query finds, for each custom role (excluding PostgreSQL internal roles
 * which have oid < FirstNormalObjectId), what parent roles it inherits from.
 * We filter both child and parent roles by oid >= FirstNormalObjectId to exclude
 * Postgres system roles.
 *
 * Hash Table Structure:
 * - Key: child role name (char[NAMEDATALEN])
 * - Value: RoleParentEntry struct containing:
 *   - roleName: the child role name (same as key)
 *   - parentRoles: List of direct parent role names (char*) this role inherits from
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

	const char *inheritanceQuery = FormatSqlQuery(
		"SELECT ARRAY_AGG(%s.row_get_bson(r)) FROM ("
		"  SELECT "
		"    CASE WHEN child.rolname = '%s' THEN '%s' ELSE child.rolname::text END AS child_role, "
		"    ARRAY_AGG(parent.rolname::text) FILTER (WHERE parent.rolname IS NOT NULL AND parent.oid >= %d) AS parent_roles "
		"  FROM pg_roles child "
		"  LEFT JOIN pg_auth_members am ON am.member = child.oid "
		"  LEFT JOIN pg_roles parent ON parent.oid = am.roleid "
		"  WHERE child.oid >= %d "
		"    AND (NOT child.rolcanlogin OR child.rolname = '%s') "
		"  GROUP BY child.rolname"
		") r;",
		CoreSchemaName,
		ApiRootInternalRole, ApiRootRole,
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
			strlcpy(entry->roleName, childRole, NAMEDATALEN);
			entry->parentRoles = NIL;
		}

		if (parentRoles != NIL)
		{
			ListCell *cell;
			foreach(cell, parentRoles)
			{
				entry->parentRoles = lappend(entry->parentRoles, lfirst(cell));
			}
			list_free(parentRoles);
		}
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
