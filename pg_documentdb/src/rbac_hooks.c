/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/rbac_hooks.c
 *
 * Default implementations of the collection-scoped role privilege hooks.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>

#include "utils/documentdb_errors.h"

#include "rbac_hooks.h"

GrantCollectionPrivilegesToRole_HookType
	grant_collection_privileges_to_role_hook = NULL;
RemoveCollectionPrivileges_HookType
	remove_collection_privileges_hook = NULL;
GrantCollectionPrivilegesToBaselineRoles_HookType
	grant_collection_privileges_to_baseline_roles_hook = NULL;


/*
 * Persists collection-scoped privileges for a newly created role.
 *
 * createRole reaches this only when its payload has privileges on a
 * resource, so without an implementation the request cannot be honoured and
 * is rejected rather than reporting success for privileges never granted.
 */
void
GrantCollectionPrivilegesToRole(const char *roleName, List *collectionPrivileges)
{
	if (grant_collection_privileges_to_role_hook == NULL)
	{
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


/*
 * Grants baseline privileges on a collection's tables.
 *
 * Collection creation and sharding reach this unconditionally, so it stays a
 * no-op without an implementation: there are no baseline privileges to grant,
 * and failing would break collection creation in a build that never had the
 * feature.
 */
void
GrantCollectionPrivilegesToBaselineRoles(uint64 collectionId, bool includeRetryTable)
{
	if (grant_collection_privileges_to_baseline_roles_hook != NULL)
	{
		grant_collection_privileges_to_baseline_roles_hook(collectionId,
														   includeRetryTable);
	}
}
