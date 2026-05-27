/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/index_am/index_am_extend_query.h
 *
 * Declarations for extending index query for an index access method
 *
 *-------------------------------------------------------------------------
 */

#ifndef INDEX_AM_EXTEND_QUERY_H
#define INDEX_AM_EXTEND_QUERY_H

#include <postgres.h>
#include <utils/rel.h>

#include "index_am/index_am_exports.h"
#include "planner/bson_index_force_pushdown.h"

/*
 * Match callbacks return AM-specific query state (void *), or NULL if no match.
 */
typedef void *(*MatchExtendedIndexExprFunc)(Expr *expr,
											ReplaceExtensionFunctionContext
											*context);
typedef Expr *(*RewriteExtendedIndexFuncExprFunc)(FuncExpr *funcExpr,
												  ReplaceExtensionFunctionContext *context,
												  bool trimClauses);

typedef struct QueryExtendedIndexContext QueryExtendedIndexContext;
typedef void (*AddExtendedQueryScanFunc)(PlannerInfo *root,
										 RelOptInfo *rel,
										 Index rti,
										 RangeTblEntry *rte,
										 QueryExtendedIndexContext *
										 amContext);
typedef struct QueryExtendedIndexContext
{
	/* The index AM entry if the query is for an extended index AM */
	const BsonIndexAmEntry *indexAmEntry;

	/* The state shared across the functions for the extended index query. */
	void *indexAmQueryState;
} QueryExtendedIndexContext;

typedef struct QueryIndexPathSupportFuncs
{
	/*
	 * Support functions for force index pushdown for a specific index AM.
	 */
	ForceIndexSupportFuncs *forceIndexSupportFuncs;

	/*
	 * Match the expr in Pathlist hook for registered index AM
	 */
	MatchExtendedIndexExprFunc matchExprFunc;

	/*
	 * Rewrite an extended index marker FuncExpr
	 * in restriction quals during ProcessRestrictionInfoAndRewriteFuncExpr.
	 * Returns the rewritten Expr, or NULL to trim the clause.
	 * If the callback returns the original clause unchanged, no rewrite occurred.
	 */
	RewriteExtendedIndexFuncExprFunc rewriteFuncExprFunc;

	/*
	 * Add a custom scan path for extended index queries.
	 */
	AddExtendedQueryScanFunc addExtendedQueryScanFunc;
} QueryIndexPathSupportFuncs;

/*
 * Match the expr to an extended index AM when processing restriction paths in the Pathlist hook.
 * If a match is found, a QueryExtendedIndexContext is returned
 * if no match is found, NULL is returned
 */
QueryExtendedIndexContext * MatchRestrictionPathExprByExtendedIndex(Expr *expr,
																	ReplaceExtensionFunctionContext
																	*context);

#endif
