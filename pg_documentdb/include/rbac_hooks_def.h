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

#endif
