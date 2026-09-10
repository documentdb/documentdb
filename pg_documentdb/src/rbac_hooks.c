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

#include "utils/documentdb_errors.h"

#include "rbac_hooks.h"
#include "rbac_hooks_def.h"

GrantCollectionPrivilegesToRole_HookType
	grant_collection_privileges_to_role_hook = NULL;
RemoveCollectionPrivileges_HookType
	remove_collection_privileges_hook = NULL;
GrantCollectionPrivilegesToBaselineRoles_HookType
	grant_collection_privileges_to_baseline_roles_hook = NULL;
PostCreateCollection_HookType post_create_collection_hook = NULL;
ApplyCollectionAccessIdentityToPlan_HookType
	apply_collection_access_identity_to_plan_hook = NULL;
RequireBaseCollectionRteInMetadataQueries_HookType
	require_base_collection_rte_in_metadata_queries_hook = NULL;
UpdateJoinTreeForCollectionsQuery_HookType
	update_join_tree_for_collections_query_hook = NULL;

GetCollectionsStringFilter_HookType
	get_collections_string_filter_hook = NULL;


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
