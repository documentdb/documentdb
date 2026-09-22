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
#include "executor/spi.h"
#include "miscadmin.h"
#include "utils/acl.h"
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
#include "metadata/collection.h"
#include "utils/version_utils.h"
#include "rbac_hooks.h"
#include "infrastructure/documentdb_plan_cache.h"

/*
 * IS_INHERITABLE_ROLE checks if a role is allowed to be inherited by custom roles.
 */
#define IS_INHERITABLE_ROLE(roleName) \
	(strcmp(roleName, ApiReadOnlyRole) == 0 || \
	 strcmp(roleName, API_RBAC_READWRITE_ANYDB_ROLE) == 0 || \
	 strcmp(roleName, ApiAdminRoleV2) == 0)

/* GUC to enable user crud operations */
extern bool EnableRoleCrud;

/* GUC that controls whether the DB admin check is enabled */
extern bool EnableRolesAdminDBCheck;

PG_FUNCTION_INFO_V1(command_create_role);
PG_FUNCTION_INFO_V1(command_drop_role);
PG_FUNCTION_INFO_V1(command_roles_info);
PG_FUNCTION_INFO_V1(command_update_role);
PG_FUNCTION_INFO_V1(command_grant_roles_to_role);
PG_FUNCTION_INFO_V1(command_grant_privileges_to_role);
PG_FUNCTION_INFO_V1(command_revoke_roles_from_role);
PG_FUNCTION_INFO_V1(command_revoke_privileges_from_role);
PG_FUNCTION_INFO_V1(documentdb_is_reserved_user);
PG_FUNCTION_INFO_V1(documentdb_is_custom_role);

/*
 * Struct to hold createRole parameters
 */
typedef struct
{
	const char *roleName;
	HTAB *parentRoles;
	List *collectionPrivileges;
} CreateRoleSpec;

/*
 * Struct to hold grantRolesToRole parameters
 */
typedef struct
{
	const char *roleName;
	HTAB *grantedRoles;
} GrantRolesToRoleSpec;

/*
 * Struct to hold revokeRolesFromRole parameters
 */
typedef struct
{
	const char *roleName;
	HTAB *revokedRoles;
} RevokeRolesFromRoleSpec;

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

static void ParseCreateRoleSpec(pgbson *createRoleBson, CreateRoleSpec *createRoleSpec,
								bool validateCommandContext);
static void ParseRoleEntryDocument(bson_iter_t *roleEntryIter, const char **roleName,
								   uint32_t *roleNameLength);
static void ParsePrivilegesArray(bson_iter_t *privilegesIter,
								 List **collectionPrivileges);
static void ParseResourceDocument(bson_iter_t *privilegeDocIter, StringView *dbName,
								  StringView *collectionName);
static CustomPrivilegeAction ExtractUniqueActionsForResource(
	bson_iter_t *privilegeDocIter);
static void ParseDropRoleSpec(pgbson *dropRoleBson, DropRoleSpec *dropRoleSpec);
static void ParseRolesInfoSpec(pgbson *rolesInfoBson, RolesInfoSpec *rolesInfoSpec);
static void ParseRoleDefinition(bson_iter_t *iter, RolesInfoSpec *rolesInfoSpec);
static void ParseRoleDocument(bson_iter_t *rolesArrayIter, RolesInfoSpec *rolesInfoSpec);
static void ProcessAllRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter,
										RolesInfoSpec rolesInfoSpec);
static void ProcessSpecificRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter,
											 RolesInfoSpec rolesInfoSpec);
static pgbson * RolesTableQuerySpec(const char *roleName);
static void ExecuteRolesTableQuery(pgbson *rolesTableQuerySpec,
								   pgbson_array_writer *rolesArrayWriter,
								   RolesInfoSpec rolesInfoSpec);
static void WriteRoles(pgbson_array_writer *rolesArrayWriter,
					   RolesInfoSpec rolesInfoSpec, const char *roleName);
static void WriteRoleResponse(const pgbson *roleDocument,
							  pgbson_array_writer *rolesArrayWriter,
							  RolesInfoSpec rolesInfoSpec);
static bool RolesInfoCallerCanViewAllRoles(Oid callerRoleId);
static const char * GetInternalRoleName(const char *nativeRoleName);
static const char * GetNativeRoleName(const char *internalRoleName);
static void GrantRoleInheritance(const char *parentRole, const char *targetRole,
								 bool allowCustomRoles);
static void ParseGrantRolesToRoleSpec(pgbson *grantRolesBson,
									  GrantRolesToRoleSpec *grantRolesSpec);
static void ParseRevokeRolesFromRoleSpec(pgbson *revokeRolesBson,
										 RevokeRolesFromRoleSpec *revokeRolesSpec);
static void RevokeRoleInheritance(const char *parentRole, const char *targetRole);
static void EnsureCustomRoleExists(const char *roleName);
static void StoreCustomRoleToRoleCatalog(const char *roleName,
										 pgbson *createRoleBson);
static void DeleteCustomRoleFromRoleCatalog(const char *roleName);
static CustomPrivilegeAction GetPrivilegeAction(const char *action);
static pgbson * NormalizeRoleSpecForStorage(pgbson *createRoleBson, HTAB *rolesHash);
static void UpdateCustomRoleInRoleCatalog(const char *roleName, HTAB *roles, bool
										  isGrantRoles);

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
 * Returns whether a login role is reserved for internal use.
 */
Datum
documentdb_is_reserved_user(PG_FUNCTION_ARGS)
{
	char *roleName = text_to_cstring(PG_GETARG_TEXT_PP(0));

	PG_RETURN_BOOL(
		strcmp(roleName, ApiBgWorkerRole) == 0 ||
		strcmp(roleName, ApiRootRole) == 0 ||
		strcmp(roleName, ApiReplicationRole) == 0 ||
		strncmp(roleName, "documentdb_api", strlen("documentdb_api")) == 0 ||
		strncmp(roleName, "documentdb_rbac", strlen("documentdb_rbac")) == 0);
}


/*
 * Returns whether the named role has a custom-role catalog entry.
 */
Datum
documentdb_is_custom_role(PG_FUNCTION_ARGS)
{
	text *roleName = PG_GETARG_TEXT_PP(0);
	bool isCustomRole = IsCustomRoleCore(roleName);
	PG_FREE_IF_COPY(roleName, 0);

	PG_RETURN_BOOL(isCustomRole);
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
 * Parses a grantRolesToRole spec, executes it, and returns the result.
 */
Datum
command_grant_roles_to_role(PG_FUNCTION_ARGS)
{
	pgbson *grantRolesSpec = PG_GETARG_PGBSON(0);

	Datum response = grant_roles_to_role(grantRolesSpec);

	PG_RETURN_DATUM(response);
}


/*
 * Parses a grantPrivilegesToRole spec, executes it, and returns the result.
 */
Datum
command_grant_privileges_to_role(PG_FUNCTION_ARGS)
{
	pgbson *grantPrivilegesSpec = PG_GETARG_PGBSON(0);

	Datum response = grant_privileges_to_role(grantPrivilegesSpec);

	PG_RETURN_DATUM(response);
}


/*
 * Parses a revokeRolesFromRole spec, executes it, and returns the result.
 */
Datum
command_revoke_roles_from_role(PG_FUNCTION_ARGS)
{
	pgbson *revokeRolesSpec = PG_GETARG_PGBSON(0);

	Datum response = revoke_roles_from_role(revokeRolesSpec);

	PG_RETURN_DATUM(response);
}


/*
 * Parses a revokePrivilegesFromRole spec, executes it, and returns the result.
 */
Datum
command_revoke_privileges_from_role(PG_FUNCTION_ARGS)
{
	pgbson *revokePrivilegesSpec = PG_GETARG_PGBSON(0);

	Datum response = revoke_privileges_from_role(revokePrivilegesSpec);

	PG_RETURN_DATUM(response);
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

	if (!IsClusterVersionAtleast(DocDB_V0, 116, 0))
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
		.parentRoles = CreateStringViewHashSet(),
		.collectionPrivileges = NIL
	};
	bool validateCommandContext = true;
	ParseCreateRoleSpec(createRoleBson, &createRoleSpec, validateCommandContext);

	EnsureRoleMembershipLimits(createRoleSpec.roleName, hash_get_num_entries(
								   createRoleSpec.parentRoles));

	/* Create the specified role in the database */
	StringInfo createRoleInfo = makeStringInfo();
	appendStringInfo(createRoleInfo, "CREATE ROLE %s", quote_identifier(
						 createRoleSpec.roleName));

	bool readOnly = false;
	bool isNull = false;
	ExtensionExecuteQueryViaSPI(createRoleInfo->data, readOnly, SPI_OK_UTILITY, &isNull);

	/* Validate and grant the parent roles to the new role */
	bool allowCustomRoles = false;
	ValidateAndGrantParentRoles(createRoleSpec.roleName, createRoleSpec.parentRoles,
								allowCustomRoles);

	GrantCollectionPrivilegesToRole(createRoleSpec.roleName,
									createRoleSpec.collectionPrivileges);

	createRoleBson = NormalizeRoleSpecForStorage(createRoleBson,
												 createRoleSpec.parentRoles);

	StoreCustomRoleToRoleCatalog(createRoleSpec.roleName, createRoleBson);

	/* Cleanup */
	hash_destroy(createRoleSpec.parentRoles);
	list_free_deep(createRoleSpec.collectionPrivileges);

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);
	PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
	return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
}


/*
 * ParseCreateRoleSpec parses the createRole command parameters
 */
static void
ParseCreateRoleSpec(pgbson *createRoleBson, CreateRoleSpec *createRoleSpec,
					bool validateCommandContext)
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

			if (strlen(createRoleSpec->roleName) != strLength)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"'createRole' field contains invalid UTF-8 characters.")));
			}

			/*
			 * Since PostgreSQL silently truncates long role name upon
			 * creation, we explicitly reject it to avoid confusion.
			 */
			if (strLength >= NAMEDATALEN)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"The role name is too long. Try a role name shorter than %d characters.",
									NAMEDATALEN)));
			}

			if (ContainsReservedPgRoleNamePrefix(createRoleSpec->roleName) ||
				IsReservedInternalRoleName(createRoleSpec->roleName))
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
			ParseParentRolesArray(&createRoleIter, createRoleSpec->parentRoles);
		}
		else if (strcmp(key, "privileges") == 0)
		{
			privilegesFound = true;
			ParsePrivilegesArray(&createRoleIter,
								 &createRoleSpec->collectionPrivileges);
		}
		else if (strcmp(key, "$db") == 0 && EnableRolesAdminDBCheck &&
				 validateCommandContext)
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

	if (!dbFound && EnableRolesAdminDBCheck && validateCommandContext)
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
 * ParseParentRolesArray parses a "roles" array and collects the role names it
 * names into parentRoles.
 *
 * Each entry may be either a plain string or a document of the documented
 * { role, db } shape. The document form is what drivers send, and the string
 * form is accepted so that a spec written by hand stays valid.
 */
void
ParseParentRolesArray(bson_iter_t *rolesIter, HTAB *parentRoles)
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
		uint32_t parentRoleNameLength = 0;
		const char *parentRoleName = NULL;

		if (bson_iter_type(&rolesArrayIter) == BSON_TYPE_UTF8)
		{
			parentRoleName = bson_iter_utf8(&rolesArrayIter, &parentRoleNameLength);
		}
		else if (bson_iter_type(&rolesArrayIter) == BSON_TYPE_DOCUMENT)
		{
			ParseRoleEntryDocument(&rolesArrayIter, &parentRoleName,
								   &parentRoleNameLength);
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"The role name in 'roles' must be a string.")));
		}

		if (parentRoleNameLength == 0 || parentRoleNameLength >= NAMEDATALEN)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_ROLENOTFOUND),
							errmsg(
								"The specified parent role '%s' does not exist.",
								parentRoleName)));
		}

		/*
		 * Only the documented role names and custom roles may be named here.
		 * The names the extension provisions for its own use are rejected so
		 * that naming one directly cannot stand in for the documented name it
		 * backs, which would bypass the validation that name carries.
		 */
		if (ContainsReservedPgRoleNamePrefix(parentRoleName) ||
			IsReservedInternalRoleName(parentRoleName))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_ROLENOTFOUND),
							errmsg(
								"The specified value for the role is invalid: '%s'.",
								parentRoleName),
							errdetail_log(
								"The specified value for the role is invalid: '%s'.",
								parentRoleName)));
		}

		/*
		 * The key references the name in place rather than copying it. The
		 * command document outlives this hash, so the referenced bytes stay
		 * valid for as long as the set is used.
		 */
		StringView parentRole = CreateStringViewFromStringWithLength(
			parentRoleName, parentRoleNameLength);
		hash_search(parentRoles, &parentRole, HASH_ENTER, NULL);
	}
}


/*
 * ParseRoleEntryDocument reads a { role, db } entry from a roles array and
 * returns the role name it holds.
 *
 * The returned name points into the command document, which outlives every
 * caller here, so it is not copied.
 */
static void
ParseRoleEntryDocument(bson_iter_t *roleEntryIter, const char **roleName,
					   uint32_t *roleNameLength)
{
	bson_iter_t roleDocIter;
	bson_iter_recurse(roleEntryIter, &roleDocIter);

	bool roleFound = false;

	while (bson_iter_next(&roleDocIter))
	{
		const char *key = bson_iter_key(&roleDocIter);

		if (strcmp(key, "role") == 0)
		{
			if (bson_iter_type(&roleDocIter) != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"The role name in 'roles' must be a string.")));
			}

			*roleName = bson_iter_utf8(&roleDocIter, roleNameLength);
			roleFound = true;
		}
		else if (strcmp(key, "db") == 0 || strcmp(key, "$db") == 0)
		{
			if (bson_iter_type(&roleDocIter) != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("'db' in a role entry must be a string.")));
			}

			uint32_t dbNameLength = 0;
			const char *dbName = bson_iter_utf8(&roleDocIter, &dbNameLength);
			ValidateNamespaceStringForEmbeddedNull(dbName, dbNameLength);
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
							errmsg(
								"The specified field '%s' is not supported in a role entry.",
								key)));
		}
	}

	if (!roleFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'role' is required in a role entry.")));
	}
}


/*
 * ParsePrivilegesArray parses a privileges array and appends each entry to
 * collectionPrivileges.
 */
static void
ParsePrivilegesArray(bson_iter_t *privilegesIter, List **collectionPrivileges)
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
		CustomPrivilegeAction actions = CustomPrivilegeAction_None;
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
				actions = ExtractUniqueActionsForResource(&privilegeDocIter);
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

		if (dbName.string == NULL || collectionName.string == NULL ||
			actions == CustomPrivilegeAction_None)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Internal error: privilege parsing produced an invalid resource or actions.")));
		}

		CustomCollectionPrivilege *collectionPrivilege = palloc(
			sizeof(CustomCollectionPrivilege));
		collectionPrivilege->databaseName = dbName;
		collectionPrivilege->collectionName = collectionName;
		collectionPrivilege->actions = actions;

		*collectionPrivileges = lappend(*collectionPrivileges, collectionPrivilege);
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

			ValidateNamespaceStringForEmbeddedNull(strValue, strLength);
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
			if (strValue == NULL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"'collection' in resource must be a string.")));
			}

			ValidateNamespaceStringForEmbeddedNull(strValue, strLength);
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

	/*
	 * Privileges may target collections created later, so validate only the
	 * namespace syntax here.
	 */
	if (collectionName->length == 0)
	{
		ValidateDatabaseName(StringViewGetTextDatum(dbName));
	}
	else
	{
		ValidateDatabaseCollection(StringViewGetTextDatum(dbName),
								   StringViewGetTextDatum(collectionName));
	}
}


/*
 * ExtractUniqueActionsForResource parses the "actions" field from a privilege
 * entry. Returns a bitmask of CustomPrivilegeAction, so repeating an action is
 * inherently tolerated: setting a bit twice is the same as setting it once.
 */
static CustomPrivilegeAction
ExtractUniqueActionsForResource(bson_iter_t *privilegeDocIter)
{
	if (bson_iter_type(privilegeDocIter) != BSON_TYPE_ARRAY)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'actions' must be an array.")));
	}

	bson_iter_t actionsIter;
	bson_iter_recurse(privilegeDocIter, &actionsIter);

	CustomPrivilegeAction actions = CustomPrivilegeAction_None;
	while (bson_iter_next(&actionsIter))
	{
		if (bson_iter_type(&actionsIter) != BSON_TYPE_UTF8)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Each action must be a string.")));
		}

		uint32_t actionLength = 0;
		const char *action = bson_iter_utf8(&actionsIter, &actionLength);

		if (actionLength == 0)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Action name cannot be empty.")));
		}

		actions |= GetPrivilegeAction(action);
	}

	if (actions == CustomPrivilegeAction_None)
	{
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
 * grant_roles_to_role implements the core logic for the grantRolesToRole
 * command, which adds parent roles to an existing custom role.
 */
Datum
grant_roles_to_role(pgbson *grantRolesBson)
{
	if (!EnableRoleCrud || !IsClusterVersionAtleast(DocDB_V0, 116, 0))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg("The GrantRolesToRole command is currently unsupported."),
						errdetail_log(
							"The GrantRolesToRole command is currently unsupported.")));
	}

	ReportFeatureUsage(FEATURE_ROLE_GRANT_ROLES_TO_ROLE);

	if (!IsMetadataCoordinator())
	{
		if (!IsClusterVersionAtleast(DocDB_V1, 1, 0))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
							errmsg(
								"The GrantRolesToRole command is currently unsupported."),
							errdetail_log(
								"The GrantRolesToRole command is currently unsupported.")));
		}

		StringInfo grantRolesQuery = makeStringInfo();
		appendStringInfo(grantRolesQuery,
						 "SELECT %s.grant_roles_to_role(%s::%s.bson)",
						 ApiSchemaNameV2,
						 quote_literal_cstr(PgbsonToHexadecimalString(grantRolesBson)),
						 CoreSchemaNameV2);
		DistributedRunCommandResult result = RunCommandOnMetadataCoordinator(
			grantRolesQuery->data);

		if (!result.success)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Grant roles to role operation failed: %s",
								text_to_cstring(result.response)),
							errdetail_log(
								"Grant roles to role operation failed: %s",
								text_to_cstring(result.response))));
		}

		pgbson_writer finalWriter;
		PgbsonWriterInit(&finalWriter);
		PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
		return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
	}

	GrantRolesToRoleSpec grantRolesSpec = {
		.roleName = NULL,
		.grantedRoles = CreateStringViewHashSet()
	};
	ParseGrantRolesToRoleSpec(grantRolesBson, &grantRolesSpec);

	/*
	 * Only a custom role may be modified. Built-in roles carry fixed
	 * capabilities that the rest of the system relies on.
	 */
	EnsureCustomRoleExists(grantRolesSpec.roleName);

	EnsureRoleMembershipLimits(grantRolesSpec.roleName, hash_get_num_entries(
								   grantRolesSpec.grantedRoles));

	bool allowCustomRoles = true;
	ValidateAndGrantParentRoles(grantRolesSpec.roleName, grantRolesSpec.grantedRoles,
								allowCustomRoles);

	bool isGrantRoles = true;
	UpdateCustomRoleInRoleCatalog(grantRolesSpec.roleName, grantRolesSpec.grantedRoles,
								  isGrantRoles);

	hash_destroy(grantRolesSpec.grantedRoles);

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);
	PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
	return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
}


/*
 * ParseGrantRolesToRoleSpec parses the grantRolesToRole command parameters.
 */
static void
ParseGrantRolesToRoleSpec(pgbson *grantRolesBson, GrantRolesToRoleSpec *grantRolesSpec)
{
	bson_iter_t grantRolesIter;
	PgbsonInitIterator(grantRolesBson, &grantRolesIter);

	bool dbFound = false;
	bool rolesFound = false;

	while (bson_iter_next(&grantRolesIter))
	{
		const char *key = bson_iter_key(&grantRolesIter);

		if (strcmp(key, "grantRolesToRole") == 0)
		{
			EnsureTopLevelFieldType(key, &grantRolesIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			grantRolesSpec->roleName = bson_iter_utf8(&grantRolesIter, &strLength);

			if (strLength == 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"The 'grantRolesToRole' field must not be left empty.")));
			}

			/*
			 * PostgreSQL truncates identifiers, so a name that cannot be
			 * stored is rejected rather than being allowed to resolve to a
			 * different role that shares its prefix.
			 */
			if (strLength >= NAMEDATALEN)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_ROLENOTFOUND),
								errmsg("The specified role '%s' does not exist.",
									   grantRolesSpec->roleName)));
			}
		}
		else if (strcmp(key, "roles") == 0)
		{
			rolesFound = true;
			ParseParentRolesArray(&grantRolesIter, grantRolesSpec->grantedRoles);
		}
		else if (strcmp(key, "$db") == 0 && EnableRolesAdminDBCheck)
		{
			EnsureTopLevelFieldType(key, &grantRolesIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			const char *dbName = bson_iter_utf8(&grantRolesIter, &strLength);
			ValidateNamespaceStringForEmbeddedNull(dbName, strLength);

			dbFound = true;
			if (strcmp(dbName, "admin") != 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"GrantRolesToRole must be called from 'admin' database.")));
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

	if (grantRolesSpec->roleName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'grantRolesToRole' is a required field.")));
	}

	if (!rolesFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'roles' is a required field.")));
	}

	if (hash_get_num_entries(grantRolesSpec->grantedRoles) == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'roles' must not be empty.")));
	}
}


/*
 * revoke_roles_from_role implements the core logic for the revokeRolesFromRole
 * command, which removes parent roles from an existing custom role.
 */
Datum
revoke_roles_from_role(pgbson *revokeRolesBson)
{
	if (!EnableRoleCrud || !IsClusterVersionAtleast(DocDB_V0, 116, 0))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg(
							"The RevokeRolesFromRole command is currently unsupported."),
						errdetail_log(
							"The RevokeRolesFromRole command is currently unsupported.")));
	}

	ReportFeatureUsage(FEATURE_ROLE_REVOKE_ROLES_FROM_ROLE);

	if (!IsMetadataCoordinator())
	{
		if (!IsClusterVersionAtleast(DocDB_V1, 1, 0))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
							errmsg(
								"The RevokeRolesFromRole command is currently unsupported."),
							errdetail_log(
								"The RevokeRolesFromRole command is currently unsupported.")));
		}

		StringInfo revokeRolesQuery = makeStringInfo();
		appendStringInfo(revokeRolesQuery,
						 "SELECT %s.revoke_roles_from_role(%s::%s.bson)",
						 ApiSchemaNameV2,
						 quote_literal_cstr(PgbsonToHexadecimalString(revokeRolesBson)),
						 CoreSchemaNameV2);
		DistributedRunCommandResult result = RunCommandOnMetadataCoordinator(
			revokeRolesQuery->data);

		if (!result.success)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Revoke roles from role operation failed: %s",
								text_to_cstring(result.response)),
							errdetail_log(
								"Revoke roles from role operation failed: %s",
								text_to_cstring(result.response))));
		}

		pgbson_writer finalWriter;
		PgbsonWriterInit(&finalWriter);
		PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
		return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
	}

	RevokeRolesFromRoleSpec revokeRolesSpec = {
		.roleName = NULL,
		.revokedRoles = CreateStringViewHashSet()
	};
	ParseRevokeRolesFromRoleSpec(revokeRolesBson, &revokeRolesSpec);

	/*
	 * Only a custom role may be modified. Built-in roles carry fixed
	 * capabilities that the rest of the system relies on.
	 */
	EnsureCustomRoleExists(revokeRolesSpec.roleName);

	ValidateAndRevokeParentRoles(revokeRolesSpec.roleName,
								 revokeRolesSpec.revokedRoles);

	bool isGrantRoles = false;
	UpdateCustomRoleInRoleCatalog(revokeRolesSpec.roleName, revokeRolesSpec.revokedRoles,
								  isGrantRoles);
	hash_destroy(revokeRolesSpec.revokedRoles);

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);
	PgbsonWriterAppendInt32(&finalWriter, "ok", 2, 1);
	return PointerGetDatum(PgbsonWriterGetPgbson(&finalWriter));
}


/*
 * ParseRevokeRolesFromRoleSpec parses the revokeRolesFromRole command
 * parameters.
 */
static void
ParseRevokeRolesFromRoleSpec(pgbson *revokeRolesBson,
							 RevokeRolesFromRoleSpec *revokeRolesSpec)
{
	bson_iter_t revokeRolesIter;
	PgbsonInitIterator(revokeRolesBson, &revokeRolesIter);

	bool dbFound = false;
	bool rolesFound = false;

	while (bson_iter_next(&revokeRolesIter))
	{
		const char *key = bson_iter_key(&revokeRolesIter);

		if (strcmp(key, "revokeRolesFromRole") == 0)
		{
			EnsureTopLevelFieldType(key, &revokeRolesIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			revokeRolesSpec->roleName = bson_iter_utf8(&revokeRolesIter, &strLength);

			if (strLength == 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"The 'revokeRolesFromRole' field must not be left empty.")));
			}

			/*
			 * PostgreSQL truncates identifiers, so a name that cannot be
			 * stored is rejected rather than being allowed to resolve to a
			 * different role that shares its prefix.
			 */
			if (strLength >= NAMEDATALEN)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_ROLENOTFOUND),
								errmsg("The specified role '%s' does not exist.",
									   revokeRolesSpec->roleName)));
			}
		}
		else if (strcmp(key, "roles") == 0)
		{
			rolesFound = true;
			ParseParentRolesArray(&revokeRolesIter, revokeRolesSpec->revokedRoles);
		}
		else if (strcmp(key, "$db") == 0)
		{
			EnsureTopLevelFieldType(key, &revokeRolesIter, BSON_TYPE_UTF8);
			uint32_t strLength = 0;
			const char *dbName = bson_iter_utf8(&revokeRolesIter, &strLength);
			ValidateNamespaceStringForEmbeddedNull(dbName, strLength);

			dbFound = true;
			if (strcmp(dbName, "admin") != 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"RevokeRolesFromRole must be called from 'admin' database.")));
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

	if (!dbFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("The required $db property is missing.")));
	}

	if (revokeRolesSpec->roleName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'revokeRolesFromRole' is a required field.")));
	}

	if (!rolesFound)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'roles' is a required field.")));
	}

	if (hash_get_num_entries(revokeRolesSpec->revokedRoles) == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("'roles' must not be empty.")));
	}
}


/*
 * revoke_privileges_from_role is the entry point for the
 * revokePrivilegesFromRole command. Removing resource-scoped privileges from a
 * role is not implemented yet, so the command is always rejected.
 */
Datum
revoke_privileges_from_role(pgbson *revokePrivilegesBson)
{
	ReportFeatureUsage(FEATURE_ROLE_REVOKE_PRIVILEGES_FROM_ROLE);

	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
					errmsg(
						"The RevokePrivilegesFromRole command is currently unsupported."),
					errdetail_log(
						"The RevokePrivilegesFromRole command is currently unsupported.")));
}


/*
 * grant_privileges_to_role is the entry point for the grantPrivilegesToRole
 * command. Granting resource-scoped privileges to an existing role is not
 * implemented yet, so the command is always rejected.
 */
Datum
grant_privileges_to_role(pgbson *grantPrivilegesBson)
{
	ReportFeatureUsage(FEATURE_ROLE_GRANT_PRIVILEGES_TO_ROLE);

	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
					errmsg(
						"The GrantPrivilegesToRole command is currently unsupported."),
					errdetail_log(
						"The GrantPrivilegesToRole command is currently unsupported.")));
}


/*
 * EnsureCustomRoleExists reports an error unless roleName names an existing
 * custom role. Built-in roles are rejected because their capabilities are
 * fixed.
 */
static void
EnsureCustomRoleExists(const char *roleName)
{
	if (IS_NATIVE_BUILTIN_ROLE(roleName))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("Cannot modify built-in role '%s'.", roleName)));
	}

	if (ContainsReservedPgRoleNamePrefix(roleName) ||
		IsReservedInternalRoleName(roleName))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("Role '%s' is reserved and cannot be modified.",
							   roleName)));
	}

	if (!IsCustomRole(roleName))
	{
		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT),
						errmsg("The specified role '%s' does not exist.", roleName)));
	}
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

	if (!IsClusterVersionAtleast(DocDB_V0, 116, 0))
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

	if (IS_NATIVE_BUILTIN_ROLE(dropRoleSpec.roleName))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Cannot drop built-in role '%s'.",
							dropRoleSpec.roleName)));
	}

	if (!IsCustomRole(dropRoleSpec.roleName))
	{
		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT),
						errmsg(
							"The specified role '%s' does not exist.",
							dropRoleSpec.roleName)));
	}

	/*
	 * Stored privileges are matched by resolving the role name, so they must
	 * be removed while the role still resolves. Every statement here runs in
	 * this transaction, so the cleanup and the drop commit or roll back
	 * together.
	 */
	RemoveCollectionPrivileges(dropRoleSpec.roleName);

	DeleteCustomRoleFromRoleCatalog(dropRoleSpec.roleName);

	StringInfo dropRoleQuery = makeStringInfo();
	appendStringInfo(dropRoleQuery, "DROP ROLE %s",
					 quote_identifier(dropRoleSpec.roleName));

	bool readOnly = false;
	bool isNull = false;
	ExtensionExecuteQueryViaSPI(dropRoleQuery->data, readOnly, SPI_OK_UTILITY,
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

			/*
			 * PostgreSQL truncates identifiers to NAMEDATALEN - 1 bytes.
			 * Reject longer names before DROP ROLE can target an existing
			 * role with the same prefix.
			 */
			if (strLength >= NAMEDATALEN)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_ROLENOTFOUND),
								errmsg("Role '%s' not found.", roleNameValue)));
			}

			if (ContainsReservedPgRoleNamePrefix(roleNameValue) ||
				IsReservedInternalRoleName(roleNameValue))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Role '%s' is reserved and cannot be dropped.",
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

	if (!IsClusterVersionAtleast(DocDB_V0, 116, 0))
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

	if (rolesInfoSpec.showAllRoles &&
		!RolesInfoCallerCanViewAllRoles(GetUserId()))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNAUTHORIZED),
						errmsg(
							"not authorized on admin to execute command { rolesInfo: 1 }")));
	}

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);

	pgbson_array_writer rolesArrayWriter;
	PgbsonWriterStartArray(&finalWriter, "roles", 5, &rolesArrayWriter);

	if (rolesInfoSpec.showAllRoles)
	{
		ProcessAllRolesForRolesInfo(&rolesArrayWriter, rolesInfoSpec);
	}
	else
	{
		ProcessSpecificRolesForRolesInfo(&rolesArrayWriter, rolesInfoSpec);
	}

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
 * ProcessAllRolesForRolesInfo writes visible system.roles entries in role order.
 */
static void
ProcessAllRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec
							rolesInfoSpec)
{
	const char *roleName = NULL;
	WriteRoles(rolesArrayWriter, rolesInfoSpec, roleName);
}


/*
 * ProcessSpecificRolesForRolesInfo preserves request order and skips role
 * names that are not reportable.
 */
static void
ProcessSpecificRolesForRolesInfo(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec
								 rolesInfoSpec)
{
	ListCell *currentRoleName;
	foreach(currentRoleName, rolesInfoSpec.roleNames)
	{
		const char *roleName = (const char *) lfirst(currentRoleName);

		if (IsReservedInternalRoleName(roleName))
		{
			continue;
		}

		if (IS_NATIVE_BUILTIN_ROLE(roleName))
		{
			continue;
		}

		WriteRoles(rolesArrayWriter, rolesInfoSpec, roleName);
	}
}


static bool
RolesInfoCallerCanViewAllRoles(Oid callerRoleId)
{
	bool missingOk = true;
	Oid adminRoleId = ApiAdminV2RoleOid();
	Oid rootRoleId = get_role_oid(ApiRootRole, missingOk);
	return has_privs_of_role(callerRoleId, adminRoleId) ||
		   (OidIsValid(rootRoleId) &&
			is_member_of_role(callerRoleId, rootRoleId));
}


static pgbson *
RolesTableQuerySpec(const char *roleName)
{
	pgbson_writer findSpecWriter;
	PgbsonWriterInit(&findSpecWriter);
	PgbsonWriterAppendUtf8(&findSpecWriter, "find", 4, "system.roles");

	pgbson_writer filterWriter;
	PgbsonWriterStartDocument(&findSpecWriter, "filter", 6, &filterWriter);
	if (roleName != NULL)
	{
		PgbsonWriterAppendUtf8(&filterWriter, "role", 4, roleName);
	}
	PgbsonWriterEndDocument(&findSpecWriter, &filterWriter);

	if (roleName == NULL)
	{
		pgbson_writer sortWriter;
		PgbsonWriterStartDocument(&findSpecWriter, "sort", 4, &sortWriter);
		PgbsonWriterAppendInt32(&sortWriter, "role", 4, 1);
		PgbsonWriterEndDocument(&findSpecWriter, &sortWriter);
	}

	return PgbsonWriterGetPgbson(&findSpecWriter);
}


/*
 * WriteRoles queries the virtual system.roles collection and writes each
 * returned custom role in rolesInfo response format.
 */
static void
WriteRoles(pgbson_array_writer *rolesArrayWriter, RolesInfoSpec rolesInfoSpec,
		   const char *roleName)
{
	pgbson *rolesTableQuerySpec = RolesTableQuerySpec(roleName);
	ExecuteRolesTableQuery(rolesTableQuerySpec, rolesArrayWriter, rolesInfoSpec);
}


static void
ExecuteRolesTableQuery(pgbson *rolesTableQuerySpec,
					   pgbson_array_writer *rolesArrayWriter,
					   RolesInfoSpec rolesInfoSpec)
{
	const char *query = FormatSqlQuery(
		"SELECT document FROM %s.bson_aggregation_find($1, $2)",
		ApiCatalogSchemaName);
	int nargs = 2;
	Oid argTypes[2] = { TEXTOID, BsonTypeId() };
	Datum argValues[2] = {
		CStringGetTextDatum("admin"),
		PointerGetDatum(rolesTableQuerySpec)
	};
	bool readOnly = true;

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		ereport(ERROR, (errmsg("could not connect to SPI manager")));
	}

	int tupleCountLimit = 0;
	if (SPI_execute_with_args(query, nargs, argTypes, argValues, NULL, readOnly,
							  tupleCountLimit) != SPI_OK_SELECT)
	{
		ereport(ERROR, (errmsg("could not query system.roles")));
	}

	for (uint64 tupleNumber = 0; tupleNumber < SPI_processed; tupleNumber++)
	{
		CHECK_FOR_INTERRUPTS();
		bool isNull = false;
		Datum roleDocumentDatum = SPI_getbinval(
			SPI_tuptable->vals[tupleNumber], SPI_tuptable->tupdesc, 1, &isNull);
		if (isNull)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Unexpected NULL system.roles result.")));
		}

		WriteRoleResponse(DatumGetPgBson(roleDocumentDatum),
						  rolesArrayWriter, rolesInfoSpec);
	}

	if (SPI_finish() != SPI_OK_FINISH)
	{
		ereport(ERROR, (errmsg("could not finish SPI connection")));
	}
}


static void
WriteRoleResponse(const pgbson *roleDocument,
				  pgbson_array_writer *rolesArrayWriter,
				  RolesInfoSpec rolesInfoSpec)
{
	bson_value_t idValue = { 0 };
	bson_value_t roleValue = { 0 };
	bson_value_t dbValue = { 0 };
	bson_value_t privilegesValue = { 0 };
	bson_value_t rolesValue = { 0 };
	bool hasId = false;
	bool hasRole = false;
	bool hasDb = false;
	bool hasPrivileges = false;
	bool hasRoles = false;
	bson_iter_t iter;
	PgbsonInitIterator(roleDocument, &iter);

	while (bson_iter_next(&iter))
	{
		const char *key = bson_iter_key(&iter);
		const bson_value_t *value = bson_iter_value(&iter);
		if (strcmp(key, "_id") == 0)
		{
			if (hasId || value->value_type != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg("Invalid _id field in system.roles result.")));
			}
			idValue = *value;
			hasId = true;
		}
		else if (strcmp(key, "role") == 0)
		{
			if (hasRole || value->value_type != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg("Invalid role field in system.roles result.")));
			}
			roleValue = *value;
			hasRole = true;
		}
		else if (strcmp(key, "db") == 0)
		{
			if (hasDb || value->value_type != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg("Invalid db field in system.roles result.")));
			}
			dbValue = *value;
			hasDb = true;
		}
		else if (strcmp(key, "privileges") == 0)
		{
			if (hasPrivileges || value->value_type != BSON_TYPE_ARRAY)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg(
									"Invalid privileges field in system.roles result.")));
			}
			privilegesValue = *value;
			hasPrivileges = true;
		}
		else if (strcmp(key, "roles") == 0)
		{
			if (hasRoles || value->value_type != BSON_TYPE_ARRAY)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg("Invalid roles field in system.roles result.")));
			}
			rolesValue = *value;
			hasRoles = true;
		}
	}

	if (!hasId || !hasRole || !hasDb || !hasPrivileges || !hasRoles)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Incomplete system.roles result.")));
	}

	const char *roleName = roleValue.value.v_utf8.str;
	if (IsReservedInternalRoleName(roleName) ||
		IS_NATIVE_BUILTIN_ROLE(roleName))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Unexpected role \"%s\" in system.roles result.",
							   roleName)));
	}

	pgbson_writer roleDocumentWriter;
	PgbsonArrayWriterStartDocument(rolesArrayWriter, &roleDocumentWriter);

	PgbsonWriterAppendValue(&roleDocumentWriter, "_id", 3, &idValue);
	PgbsonWriterAppendValue(&roleDocumentWriter, "role", 4, &roleValue);
	PgbsonWriterAppendValue(&roleDocumentWriter, "db", 2, &dbValue);
	PgbsonWriterAppendBool(&roleDocumentWriter, "isBuiltIn", 9, false);

	if (rolesInfoSpec.showPrivileges)
	{
		PgbsonWriterAppendValue(&roleDocumentWriter, "privileges", 10,
								&privilegesValue);
	}

	PgbsonWriterAppendValue(&roleDocumentWriter, "roles", 5, &rolesValue);

	PgbsonArrayWriterEndDocument(rolesArrayWriter, &roleDocumentWriter);
}


/*
 * ValidateAndGrantParentRoles validates all parent roles and grants them to
 * targetRoleName. Standalone readWriteAnyDatabase is allowed only when its
 * backing role is available.
 *
 * allowCustomRoles widens what may be granted to include custom roles. Role
 * creation keeps it false so that a new role's parents stay limited to the
 * built-in roles, while the grant commands set it so an existing principal can
 * be given a custom role.
 */
void
ValidateAndGrantParentRoles(const char *targetRoleName, HTAB *parentRoles,
							bool allowCustomRoles)
{
	StringView readWriteRoleView = CreateStringViewFromString("readWriteAnyDatabase");
	StringView clusterAdminRoleView = CreateStringViewFromString("clusterAdmin");
	bool hasReadWrite = hash_search(parentRoles, &readWriteRoleView,
									HASH_FIND, NULL) != NULL;
	bool hasClusterAdmin = hash_search(parentRoles,
									   &clusterAdminRoleView, HASH_FIND, NULL) != NULL;

	if (hasClusterAdmin && !hasReadWrite)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Roles specified are invalid. 'clusterAdmin' must be specified with 'readWriteAnyDatabase'."),
						errdetail_log(
							"Roles specified are invalid. 'clusterAdmin' must be specified with 'readWriteAnyDatabase'.")));
	}

	if (hasReadWrite && !hasClusterAdmin)
	{
		if (!IsReadWriteAnyDatabaseRoleAvailable())
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together."),
							errdetail_log(
								"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together.")));
		}
	}

	/*
	 * If both readWriteAnyDatabase and clusterAdmin are specified, grant
	 * ApiAdminRoleV2 once (which provides both capabilities).
	 */
	bool grantedApiAdminRole = false;
	if (hasReadWrite && hasClusterAdmin)
	{
		grantedApiAdminRole = true;
		GrantRoleInheritance(ApiAdminRoleV2, targetRoleName, allowCustomRoles);
	}

	HASH_SEQ_STATUS status;
	StringView *entry;
	hash_seq_init(&status, parentRoles);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		const char *nativeRoleName = CreateStringFromStringView(entry);
		const char *internalRoleName = GetInternalRoleName(nativeRoleName);

		/*
		 * Skip readWriteAnyDatabase and clusterAdmin if we already granted
		 * ApiAdminRoleV2, which provides both capabilities.
		 */
		if (grantedApiAdminRole &&
			(strcmp(internalRoleName, API_RBAC_READWRITE_ANYDB_ROLE) == 0 ||
			 strcmp(internalRoleName, ApiClusterAdminRole) == 0))
		{
			continue;
		}

		GrantRoleInheritance(internalRoleName, targetRoleName, allowCustomRoles);
	}
}


/*
 * ValidateAndRevokeParentRoles validates all parent roles and revokes them
 * from targetRoleName, mirroring how they are granted.
 */
void
ValidateAndRevokeParentRoles(const char *targetRoleName, HTAB *parentRoles)
{
	StringView readWriteRoleView = CreateStringViewFromString("readWriteAnyDatabase");
	StringView clusterAdminRoleView = CreateStringViewFromString("clusterAdmin");
	Oid targetRoleOid = get_role_oid(targetRoleName, false);
	bool hasReadWrite = hash_search(parentRoles, &readWriteRoleView,
									HASH_FIND, NULL) != NULL;
	bool hasClusterAdmin = hash_search(parentRoles,
									   &clusterAdminRoleView, HASH_FIND, NULL) != NULL;

	if (hasClusterAdmin && !hasReadWrite)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together."),
						errdetail_log(
							"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together.")));
	}

	if (hasReadWrite && !hasClusterAdmin)
	{
		if (!IsReadWriteAnyDatabaseRoleAvailable())
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together."),
							errdetail_log(
								"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together.")));
		}

		if (is_member_of_role(targetRoleOid, get_role_oid(ApiAdminRoleV2, false)))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together."),
							errdetail_log(
								"Roles specified are invalid. 'readWriteAnyDatabase' and 'clusterAdmin' must be specified together.")));
		}
	}

	/*
	 * The pair is granted as a single ApiAdminRoleV2 membership, so revoking
	 * it once removes both capabilities.
	 */
	bool revokedApiAdminRole = false;
	bool revokedReadWriteRole = false;
	if (hasClusterAdmin && hasReadWrite)
	{
		revokedApiAdminRole = true;
		RevokeRoleInheritance(ApiAdminRoleV2, targetRoleName);
	}

	if (hasReadWrite)
	{
		Oid readWriteAnyDatabaseRoleOid =
			CollectionRbacReadWriteAnyDatabaseRoleOid();
		if (OidIsValid(readWriteAnyDatabaseRoleOid) &&
			is_member_of_role(targetRoleOid, readWriteAnyDatabaseRoleOid))
		{
			RevokeRoleInheritance(API_RBAC_READWRITE_ANYDB_ROLE, targetRoleName);
			revokedReadWriteRole = true;
		}
	}

	HASH_SEQ_STATUS status;
	StringView *entry;
	hash_seq_init(&status, parentRoles);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		const char *nativeRoleName = CreateStringFromStringView(entry);
		const char *internalRoleName = GetInternalRoleName(nativeRoleName);

		/* Even though we don't grant both roles for admin + readwrite pairing,
		 * we still will see the readwrite any database role in the parent roles response.
		 */
		if (revokedApiAdminRole &&
			strcmp(internalRoleName, ApiClusterAdminRole) == 0)
		{
			continue;
		}

		if ((revokedReadWriteRole || revokedApiAdminRole) &&
			strcmp(internalRoleName, API_RBAC_READWRITE_ANYDB_ROLE) == 0)
		{
			continue;
		}

		RevokeRoleInheritance(internalRoleName, targetRoleName);
	}
}


/*
 * Maps user facing native role name to internal role name stored in pg_roles
 * table.
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
		return API_RBAC_READWRITE_ANYDB_ROLE;
	}
	else if (strcmp(nativeRoleName, "root") == 0)
	{
		return ApiRootInternalRole;
	}

	/* Customer facing native role name is the same as the role name stored in pg_roles table */
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
	else if (strcmp(internalRoleName, ApiReadWriteRole) == 0 ||
			 strcmp(internalRoleName, API_RBAC_READWRITE_ANYDB_ROLE) == 0)
	{
		return "readWriteAnyDatabase";
	}
	else if (strcmp(internalRoleName, ApiRootInternalRole) == 0)
	{
		return "root";
	}

	/* Customer facing native role name is the same as the role name stored in pg_roles table */
	return internalRoleName;
}


/*
 * GrantRoleInheritance grants a parent role to the target role.
 * Only allows inheriting from roles in IS_INHERITABLE_ROLE whitelist.
 */
static void
GrantRoleInheritance(const char *parentRole, const char *targetRole,
					 bool allowCustomRoles)
{
	/*
	 * A custom role is only reachable once the roles catalog exists, so the
	 * membership lookup is gated on the version that introduces it.
	 */
	bool isGrantableCustomRole = allowCustomRoles &&
								 IsClusterVersionAtleast(DocDB_V0, 116, 0) &&
								 IsCustomRole(parentRole);

	if (!IS_INHERITABLE_ROLE(parentRole) && !isGrantableCustomRole)
	{
		if (allowCustomRoles)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Granting the role '%s' is not supported.",
								GetNativeRoleName(parentRole))));
		}

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
 * RevokeRoleInheritance removes a parent role from the target role. Only the
 * roles that may be granted are accepted, so a membership the API never grants
 * cannot be named here.
 */
static void
RevokeRoleInheritance(const char *parentRole, const char *targetRole)
{
	bool isRevokableCustomRole = IsClusterVersionAtleast(DocDB_V0, 116, 0) &&
								 IsCustomRole(parentRole);

	if (!IS_INHERITABLE_ROLE(parentRole) && !isRevokableCustomRole)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Revoking the role '%s' is not supported.",
							GetNativeRoleName(parentRole))));
	}

	bool readOnly = false;
	bool isNull = false;

	StringInfo revokeRoleInfo = makeStringInfo();
	appendStringInfo(revokeRoleInfo, "REVOKE %s FROM %s",
					 quote_identifier(parentRole),
					 quote_identifier(targetRole));

	ExtensionExecuteQueryViaSPI(revokeRoleInfo->data, readOnly, SPI_OK_UTILITY,
								&isNull);
}


/*
 * Maps a documented action name onto its CustomPrivilegeAction bit.
 * An action the API does not support is rejected here.
 */
static CustomPrivilegeAction
GetPrivilegeAction(const char *action)
{
	if (strcmp(action, "find") == 0)
	{
		return CustomPrivilegeAction_Find;
	}
	else if (strcmp(action, "insert") == 0)
	{
		return CustomPrivilegeAction_Insert;
	}
	else if (strcmp(action, "update") == 0)
	{
		return CustomPrivilegeAction_Update;
	}
	else if (strcmp(action, "remove") == 0)
	{
		return CustomPrivilegeAction_Remove;
	}

	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
					errmsg("Unsupported action '%s'.", action)));
}


/*
 * StoreCustomRoleToRoleCatalog stores the original createRole BSON document in the
 * documentdb_api_catalog.roles table, which records the role as a custom role.
 */
static void
StoreCustomRoleToRoleCatalog(const char *roleName, pgbson *createRoleBson)
{
	const char *query = FormatSqlQuery(
		"INSERT INTO %s.roles (role_name, role_bson) "
		"VALUES ($1, $2)",
		ApiCatalogSchemaName);

	int nargs = 2;
	Oid argTypes[2] = { TEXTOID, BsonTypeId() };
	Datum argValues[2] = {
		CStringGetTextDatum(roleName),
		PointerGetDatum(createRoleBson)
	};

	bool readOnly = false;
	bool isNull = false;
	ExtensionExecuteQueryWithArgsViaSPI(query, nargs, argTypes, argValues, NULL,
										readOnly, SPI_OK_INSERT, &isNull);
}


static void
UpdateCustomRoleInRoleCatalog(const char *roleName, HTAB *roles, bool isGrantRoles)
{
	Oid argTypes[2] = { TEXTOID, BsonTypeId() };
	Datum argValues[2] = { CStringGetTextDatum(roleName), (Datum) 0 };
	const char *query = FormatSqlQuery(
		"SELECT role_bson FROM %s.roles WHERE role_name = $1",
		ApiCatalogSchemaName);
	bool isNull = false;
	Datum result = ExtensionExecuteQueryWithArgsViaSPI(
		query, 1, argTypes, argValues, NULL, false, SPI_OK_SELECT, &isNull);
	if (isNull)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Role '%s' not found in role catalog.", roleName)));
	}

	pgbson *roleBson = DatumGetPgBson(result);
	CreateRoleSpec createRoleSpec = {
		.roleName = NULL,
		.parentRoles = CreateStringViewHashSet(),
		.collectionPrivileges = NIL
	};

	/*
	 * The stored document is historical data that was already validated when the
	 * role was created. Re-running the command-time '$db' checks here would make
	 * grant and revoke fail for roles created while those checks were disabled.
	 */
	bool validateCommandContext = false;
	ParseCreateRoleSpec(roleBson, &createRoleSpec, validateCommandContext);

	HASH_SEQ_STATUS status;
	StringView *entry;

	hash_seq_init(&status, roles);
	while ((entry = hash_seq_search(&status)) != NULL)
	{
		if (isGrantRoles)
		{
			hash_search(createRoleSpec.parentRoles, entry, HASH_ENTER, NULL);
		}
		else
		{
			hash_search(createRoleSpec.parentRoles, entry, HASH_REMOVE, NULL);
		}
	}

	pgbson *normalizedBson = NormalizeRoleSpecForStorage(roleBson,
														 createRoleSpec.parentRoles);
	hash_destroy(createRoleSpec.parentRoles);
	pfree(roleBson);

	argValues[1] = PointerGetDatum(normalizedBson);
	const char *updateQuery = FormatSqlQuery(
		"UPDATE %s.roles SET role_bson = $2 WHERE role_name = $1",
		ApiCatalogSchemaName);
	ExtensionExecuteQueryWithArgsViaSPI(
		updateQuery, 2, argTypes, argValues, NULL, false, SPI_OK_UPDATE, &isNull);
}


/*
 * DeleteCustomRoleFromRoleCatalog removes the role's entry from the
 * documentdb_api_catalog.roles table.
 */
static void
DeleteCustomRoleFromRoleCatalog(const char *roleName)
{
	const char *query = FormatSqlQuery(
		"DELETE FROM %s.roles WHERE role_name = $1",
		ApiCatalogSchemaName);

	int nargs = 1;
	Oid argTypes[1] = { TEXTOID };
	Datum argValues[1] = { CStringGetTextDatum(roleName) };

	bool readOnly = false;
	bool isNull = false;
	ExtensionExecuteQueryWithArgsViaSPI(query, nargs, argTypes, argValues, NULL,
										readOnly, SPI_OK_DELETE, &isNull);
}


static int
StringViewListCellCompare(const ListCell *a, const ListCell *b)
{
	StringView *svA = (StringView *) lfirst(a);
	StringView *svB = (StringView *) lfirst(b);

	return CompareStringView(svA, svB);
}


static pgbson *
NormalizeRoleSpecForStorage(pgbson *createRoleBson, HTAB *rolesHash)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	bson_iter_t iter;
	PgbsonInitIterator(createRoleBson, &iter);

	while (bson_iter_next(&iter))
	{
		const char *key = bson_iter_key(&iter);
		if (strcmp(key, "roles") == 0)
		{
			pgbson_array_writer rolesArrayWriter;
			PgbsonWriterStartArray(&writer, key, strlen(key), &rolesArrayWriter);
			HASH_SEQ_STATUS status;
			StringView *entry;

			hash_seq_init(&status, rolesHash);
			List *sortedRoles = NIL;
			while ((entry = hash_seq_search(&status)) != NULL)
			{
				sortedRoles = lappend(sortedRoles, entry);
			}

			list_sort(sortedRoles, StringViewListCellCompare);
			ListCell *lc;
			foreach(lc, sortedRoles)
			{
				StringView *sortedEntry = (StringView *) lfirst(lc);
				pgbson_writer roleDocWriter;
				PgbsonArrayWriterStartDocument(&rolesArrayWriter, &roleDocWriter);
				PgbsonWriterAppendUtf8(&roleDocWriter, "role", 4,
									   sortedEntry->string);
				PgbsonWriterAppendUtf8(&roleDocWriter, "db", 2, "admin");
				PgbsonArrayWriterEndDocument(&rolesArrayWriter, &roleDocWriter);
			}

			list_free(sortedRoles);

			PgbsonWriterEndArray(&writer, &rolesArrayWriter);
		}
		else
		{
			PgbsonWriterAppendValue(&writer, key, strlen(key), bson_iter_value(&iter));
		}
	}

	return PgbsonWriterGetPgbson(&writer);
}
