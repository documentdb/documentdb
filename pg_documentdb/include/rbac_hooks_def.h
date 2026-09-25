/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/rbac_hooks_def.h
 *
 * Definitions of the collection RBAC hooks a hosting layer registers. A layer
 * that implements a hook registers itself here; a caller that only invokes one
 * includes rbac_hooks.h instead.
 *
 *-------------------------------------------------------------------------
 */

#ifndef EXTENSION_RBAC_HOOKS_DEF_H
#define EXTENSION_RBAC_HOOKS_DEF_H

#include <nodes/parsenodes.h>
#include <nodes/plannodes.h>

typedef void (*ApplyCollectionAccessIdentityToPlan_HookType)(RangeTblEntry *rte,
															 PlannedStmt *stmt);
extern ApplyCollectionAccessIdentityToPlan_HookType
	apply_collection_access_identity_to_plan_hook;

typedef bool (*RequireBaseCollectionRteInMetadataQueries_HookType)(void);
extern RequireBaseCollectionRteInMetadataQueries_HookType
	require_base_collection_rte_in_metadata_queries_hook;

typedef void (*UpdateJoinTreeForCollectionsQuery_HookType)(struct FromExpr *fromExpr,
														   List *rtes);
extern UpdateJoinTreeForCollectionsQuery_HookType
	update_join_tree_for_collections_query_hook;

typedef const char *(*GetCollectionsStringFilter_HookType)(void);
extern GetCollectionsStringFilter_HookType get_collections_string_filter_hook;

typedef Datum (*RunCollectionLevelFunctionWithPrivilegeChecks_HookType)(const
																		char *schemaName,
																		const char *
																		functionName,
																		Datum *args,
																		Oid *argTypes,
																		char *argNulls,
																		int nargs,
																		bool readOnly,
																		bool canUseLibPq,
																		bool *isNull);
extern RunCollectionLevelFunctionWithPrivilegeChecks_HookType
	run_collection_level_function_with_privilege_checks_hook;

/*
 * Calls a collection level function as the current role, with no privilege
 * check of its own. This is the behavior an unregistered hook falls back to,
 * and an implementation can call it for the cases it does not redirect.
 */
Datum RunCollectionLevelFunctionAsCaller(const char *schemaName,
										 const char *functionName,
										 Datum *args, Oid *argTypes, char *argNulls,
										 int nargs, bool readOnly, bool *isNull);

/*
 * Rejects an argument list that does not name a namespace.
 *
 * Every collection level function takes the database and the collection as its
 * first two arguments, and both are needed before the namespace can be
 * authorized or passed on. An implementation that reaches the namespace for
 * itself calls this before doing so.
 */
void ValidateNamespaceArguments(Oid *argTypes, char *argNulls, int nargs);

typedef void (*PostCreateCollection_HookType)(uint64 collectionId);
extern PostCreateCollection_HookType post_create_collection_hook;


typedef Oid (*PrivilegedFunctionIdentityFunc)(void);

void RegisterPrivilegedFunction(PrivilegedFunctionIdentityFunc func);

#endif
