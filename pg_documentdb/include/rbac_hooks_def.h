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

typedef void (*NotifyCollectionMetadataInvalidated_HookType)(void);
extern NotifyCollectionMetadataInvalidated_HookType
	notify_collection_metadata_invalidated_hook;

typedef bool (*RequireBaseCollectionRteInMetadataQueries_HookType)(void);
extern RequireBaseCollectionRteInMetadataQueries_HookType
	require_base_collection_rte_in_metadata_queries_hook;

typedef void (*UpdateJoinTreeForCollectionsQuery_HookType)(struct FromExpr *fromExpr,
														   List *rtes);
extern UpdateJoinTreeForCollectionsQuery_HookType
	update_join_tree_for_collections_query_hook;

typedef const char *(*GetCollectionsStringFilter_HookType)(void);
extern GetCollectionsStringFilter_HookType get_collections_string_filter_hook;

typedef void (*PostCreateCollection_HookType)(uint64 collectionId);
extern PostCreateCollection_HookType post_create_collection_hook;

#endif
