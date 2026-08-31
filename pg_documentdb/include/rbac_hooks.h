/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/rbac_hooks.h
 *
 * Hook definitions for collection-scoped role privileges. These hooks let the
 * hosting extension layer persist the privileges a role is granted on a
 * resource, and hold the native relation privileges that reaching the
 * authorization path requires.
 *
 *-------------------------------------------------------------------------
 */

#ifndef EXTENSION_RBAC_HOOKS_H
#define EXTENSION_RBAC_HOOKS_H

#include <nodes/pg_list.h>
#include <nodes/parsenodes.h>
#include <nodes/plannodes.h>
#include <utils/acl.h>

#include "utils/string_view.h"

/*
 * Actions a role can be granted on a resource. These name what the caller asked
 * for and carry no storage semantics: the layer that persists a grant maps them
 * onto whatever privilege model its storage uses.
 */
typedef enum CustomPrivilegeAction
{
	CustomPrivilegeAction_None = 0,
	CustomPrivilegeAction_Find = 1 << 0,
	CustomPrivilegeAction_Insert = 1 << 1,
	CustomPrivilegeAction_Update = 1 << 2,
	CustomPrivilegeAction_Remove = 1 << 3,
} CustomPrivilegeAction;

/*
 * A collection-scoped privilege, pairing a resource with the actions the role
 * was granted on it. actions is a bitmask of CustomPrivilegeAction values.
 */
typedef struct CustomCollectionPrivilege
{
	StringView databaseName;
	StringView collectionName;
	CustomPrivilegeAction actions;
} CustomCollectionPrivilege;

typedef void (*GrantCollectionPrivilegesToRole_HookType)(const char *roleName,
														 List *collectionPrivileges);
extern GrantCollectionPrivilegesToRole_HookType
	grant_collection_privileges_to_role_hook;

typedef void (*RemoveCollectionPrivileges_HookType)(const char *roleName);
extern RemoveCollectionPrivileges_HookType
	remove_collection_privileges_hook;

typedef void (*GrantCollectionPrivilegesToBaselineRoles_HookType)(uint64 collectionId,
																  bool
																  includeRetryTable);
extern GrantCollectionPrivilegesToBaselineRoles_HookType
	grant_collection_privileges_to_baseline_roles_hook;

/*
 * Persists collection-scoped privileges for a newly created role.
 * Errors when no implementation is registered.
 */
void GrantCollectionPrivilegesToRole(const char *roleName, List *collectionPrivileges);

/*
 * Removes every collection-scoped privilege recorded for a role.
 * Must run while the role still resolves, since entries are matched by name.
 * No-op when no implementation is registered.
 */
void RemoveCollectionPrivileges(const char *roleName);

/*
 * Grants baseline privileges on a collection's tables.
 *
 * The collection is identified by id rather than by table name so that the
 * names are derived here and a caller cannot supply one, keeping externally
 * supplied text out of the resulting GRANT statements.
 *
 * includeRetryTable is false when the collection has no dedicated retry table.
 * No-op when no implementation is registered.
 */
void GrantCollectionPrivilegesToBaselineRoles(uint64 collectionId,
											  bool includeRetryTable);

/*
 * Records, on a plan built without the planner, the identity a relation's
 * permission record should be checked against, and marks the plan role
 * dependent.
 *
 * A plan returned without running the planner carries a permission record that
 * nothing has had the chance to evaluate. Every other statement has that record
 * settled while planning, so this hands the ones that skip the planner to
 * whichever layer settles it.
 *
 * The record is read from the plan's own permission list, so a caller does not
 * need a Query. No-op when no implementation is registered, which leaves the
 * record checked against the invoking role.
 */
void ApplyCollectionAccessIdentityToPlan(RangeTblEntry *rte, PlannedStmt *stmt);

/*
 * Invoked after the collections catalog is invalidated so a hosting layer can
 * refresh any state it derives from collection metadata. No-op when no
 * implementation is registered.
 */
void NotifyCollectionMetadataInvalidated(void);

#endif
