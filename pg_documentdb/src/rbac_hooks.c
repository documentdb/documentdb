/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/rbac_hooks.c
 *
 * Default implementations of the resource-scoped role privilege hooks.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <utils/lsyscache.h>
#include <catalog/pg_proc.h>

#include "utils/documentdb_errors.h"

#include "rbac_hooks.h"
#include "rbac_hooks_def.h"
#include "utils/query_utils.h"
#include "metadata/metadata_cache.h"

GrantCollectionPrivilegesToRole_HookType
	grant_collection_privileges_to_role_hook = NULL;
RemoveCollectionPrivileges_HookType
	remove_collection_privileges_hook = NULL;
PostCreateCollection_HookType post_create_collection_hook = NULL;
ApplyCollectionAccessIdentityToPlan_HookType
	apply_collection_access_identity_to_plan_hook = NULL;
RequireBaseCollectionRteInMetadataQueries_HookType
	require_base_collection_rte_in_metadata_queries_hook = NULL;
UpdateJoinTreeForCollectionsQuery_HookType
	update_join_tree_for_collections_query_hook = NULL;

GetCollectionsStringFilter_HookType
	get_collections_string_filter_hook = NULL;

RunCollectionLevelFunctionWithPrivilegeChecks_HookType
	run_collection_level_function_with_privilege_checks_hook = NULL;

#define MAX_ALLOWED_PRIVILEGED_FUNCTIONS 20

typedef struct FunctionNameInfo
{
	char functionName[NAMEDATALEN];
	char functionNamespaceName[NAMEDATALEN];
	bool isValid;
} FunctionNameInfo;

typedef struct PrivilegedFunctionData
{
	PrivilegedFunctionIdentityFunc functionIdentityFunc;
	FunctionNameInfo functionNameInfo;
} PrivilegedFunctionData;

/*
 * The functions a collection-level privilege check is allowed to run. The
 * identity is resolved lazily, because the catalog it reads is not available
 * while the library is being loaded.
 *
 * Creating a namespace is the only one this layer defines. Anything else has
 * to be registered while the library is loading, which is what keeps the list
 * fixed for the life of the backend.
 */
static PrivilegedFunctionData PrivilegedFunctions[MAX_ALLOWED_PRIVILEGED_FUNCTIONS] = {
	{
		.functionIdentityFunc = ApiCreateCollectionFunctionId,
		.functionNameInfo = { },
	},
};

static int NumPrivilegedFunctions = 1;


void
RegisterPrivilegedFunction(PrivilegedFunctionIdentityFunc func)
{
	if (NumPrivilegedFunctions >= MAX_ALLOWED_PRIVILEGED_FUNCTIONS)
	{
		ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						errmsg(
							"Maximum number of allowed privileged functions exceeded.")));
	}

	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"Privileged functions can only be registered during shared preload library initialization.")));
	}

	memset(&PrivilegedFunctions[NumPrivilegedFunctions], 0,
		   sizeof(PrivilegedFunctionData));
	PrivilegedFunctions[NumPrivilegedFunctions].functionIdentityFunc = func;

	NumPrivilegedFunctions++;
}


/*
 * Persists collection-scoped privileges for a newly created role.
 *
 * createRole reaches this after parent-role validation for both empty and
 * nonempty privilege lists. Without an implementation, only the empty case is
 * safe to accept because it grants no resource privileges to lose.
 */
void
GrantCollectionPrivilegesToRole(const char *roleName, List *collectionPrivileges)
{
	if (grant_collection_privileges_to_role_hook == NULL)
	{
		if (collectionPrivileges == NIL)
		{
			return;
		}

		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg(
							"Privileges on a collection are currently unsupported."),
						errdetail_log(
							"Privileges on a collection are currently unsupported.")));
	}

	grant_collection_privileges_to_role_hook(roleName, collectionPrivileges);
}


/*
 * Removes every collection-scoped privilege entry recorded for a role.
 *
 * dropRole reaches this unconditionally, so it stays a no-op without an
 * implementation: nothing recorded it, and failing would break dropRole in a
 * build that never had the feature.
 */
void
RemoveCollectionPrivileges(const char *roleName)
{
	if (remove_collection_privileges_hook != NULL)
	{
		remove_collection_privileges_hook(roleName);
	}
}


/* Runs optional work after a collection is created. */
void
PostCreateCollection(uint64 collectionId)
{
	if (post_create_collection_hook != NULL)
	{
		post_create_collection_hook(collectionId);
	}
}


/*
 * Records, on a plan built without the planner, the identity a relation's
 * permission record should be checked against.
 */
void
ApplyCollectionAccessIdentityToPlan(RangeTblEntry *rte, PlannedStmt *stmt)
{
	if (apply_collection_access_identity_to_plan_hook != NULL)
	{
		apply_collection_access_identity_to_plan_hook(rte, stmt);
	}
}


bool
RequireBaseCollectionRteInMetadataQueries(void)
{
	return require_base_collection_rte_in_metadata_queries_hook != NULL &&
		   require_base_collection_rte_in_metadata_queries_hook();
}


void
UpdateJoinTreeForCollectionsQuery(struct FromExpr *fromExpr, List *rtes)
{
	if (update_join_tree_for_collections_query_hook != NULL)
	{
		update_join_tree_for_collections_query_hook(fromExpr, rtes);
	}
}


const char *
GetCollectionsStringFilter(void)
{
	if (get_collections_string_filter_hook != NULL)
	{
		return get_collections_string_filter_hook();
	}
	return NULL;
}


/*
 * Whether the given function is one of those a collection-level privilege
 * check may run.
 *
 * The identity is resolved on first use and kept, so a lookup that cannot yet
 * see the function leaves the entry unresolved and is retried on the next
 * call rather than being remembered as a match.
 */
static bool
IsFunctionValidForExecution(const char *schemaName, const char *functionName)
{
	for (int i = 0; i < NumPrivilegedFunctions; i++)
	{
		if (!PrivilegedFunctions[i].functionNameInfo.isValid)
		{
			Oid functionOid = PrivilegedFunctions[i].functionIdentityFunc();
			if (!OidIsValid(functionOid))
			{
				continue;
			}

			char *funcName = get_func_name(functionOid);
			Oid functionNamespace = get_func_namespace(functionOid);
			char *namespaceName = get_namespace_name(functionNamespace);
			if (funcName == NULL || namespaceName == NULL)
			{
				continue;
			}

			strlcpy(PrivilegedFunctions[i].functionNameInfo.functionName, funcName,
					NAMEDATALEN);
			strlcpy(PrivilegedFunctions[i].functionNameInfo.functionNamespaceName,
					namespaceName,
					NAMEDATALEN);
			pfree(funcName);
			pfree(namespaceName);
			PrivilegedFunctions[i].functionNameInfo.isValid = true;
		}

		if (strcmp(PrivilegedFunctions[i].functionNameInfo.functionName, functionName) ==
			0 &&
			strcmp(PrivilegedFunctions[i].functionNameInfo.functionNamespaceName,
				   schemaName) == 0)
		{
			return true;
		}
	}

	return false;
}


/*
 * Rejects an argument list that does not name a namespace.
 *
 * Every collection level function takes the database and the collection as its
 * first two arguments, and both are needed before the namespace can be
 * authorized or passed on.
 */
void
ValidateNamespaceArguments(Oid *argTypes, char *argNulls, int nargs)
{
	if (nargs < 2)
	{
		ereport(ERROR, (errmsg(
							"Insufficient number of arguments for collection-level function")));
	}

	if (argTypes[0] != TEXTOID || argTypes[1] != TEXTOID)
	{
		ereport(ERROR, (errmsg(
							"The first two arguments for collection-level function must be of type text")));
	}

	/* SPI marks a NULL argument with 'n' and a non-NULL one with ' '. */
	if (argNulls != NULL && (argNulls[0] == 'n' || argNulls[1] == 'n'))
	{
		ereport(ERROR, (errmsg(
							"The first two arguments for collection-level function cannot be NULL")));
	}
}


Datum
RunCollectionLevelFunctionWithPrivilegeChecks(const char *schemaName, const
											  char *functionName,
											  Datum *args, Oid *argTypes, char *argNulls,
											  int nargs,
											  bool readOnly, bool canUseLibPq,
											  bool *isNull)
{
	ValidateNamespaceArguments(argTypes, argNulls, nargs);

	if (!IsFunctionValidForExecution(schemaName, functionName))
	{
		ereport(ERROR, (errmsg(
							"Collection-level privilege checks can only run a function "
							"that was registered for them")));
	}

	if (run_collection_level_function_with_privilege_checks_hook != NULL)
	{
		return run_collection_level_function_with_privilege_checks_hook(schemaName,
																		functionName,
																		args, argTypes,
																		argNulls, nargs,
																		readOnly,
																		canUseLibPq,
																		isNull);
	}

	return RunCollectionLevelFunctionAsCaller(schemaName, functionName, args, argTypes,
											  argNulls, nargs, readOnly, isNull);
}


/*
 * Calls a collection level function as the current role, with no privilege
 * check of its own, so the rights the caller holds decide the outcome.
 *
 * This is what RunCollectionLevelFunctionWithPrivilegeChecks does when no
 * implementation is registered. It is exposed so that an implementation can
 * reach the same behavior for the cases it does not redirect, rather than
 * restating the call.
 */
Datum
RunCollectionLevelFunctionAsCaller(const char *schemaName, const char *functionName,
								   Datum *args, Oid *argTypes, char *argNulls,
								   int nargs, bool readOnly, bool *isNull)
{
	StringInfo query = makeStringInfo();
	appendStringInfo(query, "SELECT %s.%s(", schemaName, functionName);

	for (int i = 0; i < nargs; i++)
	{
		if (i > 0)
		{
			appendStringInfoString(query, ", ");
		}

		appendStringInfo(query, "$%d", i + 1);
	}

	appendStringInfoChar(query, ')');

	return ExtensionExecuteQueryWithArgsViaSPI(query->data, nargs, argTypes, args,
											   argNulls, readOnly, SPI_OK_SELECT,
											   isNull);
}
