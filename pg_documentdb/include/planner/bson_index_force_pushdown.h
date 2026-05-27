/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/planner/bson_index_force_pushdown.h
 *
 * Common declarations for Index force pushdown support functions.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_INDEX_FORCE_PUSHDOWN_H
#define BSON_INDEX_FORCE_PUSHDOWN_H

#include "planner/bson_index_force_pushdown_types.h"

typedef struct ReplaceExtensionFunctionContext ReplaceExtensionFunctionContext;
typedef List *(*UpdateIndexList)(List *indexes,
								 ReplaceExtensionFunctionContext *context);
typedef bool (*MatchIndexPath)(IndexPath *path, void *state);
typedef bool (*ModifyTreeToUseAlternatePath)(PlannerInfo *root, RelOptInfo *rel,
											 ReplaceExtensionFunctionContext *context,
											 MatchIndexPath matchIndexPath);
typedef void (*NoIndexFoundHandler)(void);
typedef bool (*EnableForceIndexPushdown)(PlannerInfo *root,
										 ReplaceExtensionFunctionContext *context);

/*
 * Force index pushdown operator support functions
 */
typedef struct ForceIndexSupportFuncs
{
	/*
	 * Mongo query operator type
	 */
	ForceIndexOpType operator;

	/*
	 * Update the index list to filter out non-applicable
	 * indexes and then try creating index paths against to
	 * push down to the now available index.
	 */
	UpdateIndexList updateIndexes;

	/*
	 * After a new set of paths are generated this function would
	 * be called to match if the path is what the operator expects it
	 * to be, usually the path is checked to be an index path and the operator
	 * specific quals are pushed to the index
	 */
	MatchIndexPath matchIndexPath;

	/*
	 * If updating index list doesn't help in creating any interesting index
	 * paths, then just ask the operator to do any necessary updates to the
	 * query tree and try any alternate path, this can be any path based on
	 * the query operator and should return true to notify that a valid
	 * path exist.
	 */
	ModifyTreeToUseAlternatePath alternatePath;

	/*
	 * Control switch to enable/disable the force index pushdown
	 */
	EnableForceIndexPushdown enableForceIndexPushdown;

	/*
	 * Handler when no applicable index was found
	 */
	NoIndexFoundHandler noIndexHandler;
} ForceIndexSupportFuncs;

Path * ForceIndexForQueryOperators(PlannerInfo *root, RelOptInfo *rel,
								   ReplaceExtensionFunctionContext *context);

#endif
