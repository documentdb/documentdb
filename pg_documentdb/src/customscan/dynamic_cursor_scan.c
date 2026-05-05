/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/customscan/dynamic_cursor_scan.c
 *
 * Implementation and Definitions for a custom scan for extension that handles cursors dynamically.
 *
 *-------------------------------------------------------------------------
 */


#include <postgres.h>
#include <fmgr.h>
#include <utils/lsyscache.h>
#include <nodes/extensible.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <nodes/tidbitmap.h>
#include <access/htup_details.h>
#include <access/heapam.h>
#include <optimizer/pathnode.h>
#include <optimizer/optimizer.h>
#include <parser/parse_relation.h>
#include <utils/rel.h>
#include <access/detoast.h>
#include <miscadmin.h>
#include <catalog/pg_operator.h>
#include <optimizer/restrictinfo.h>
#include <optimizer/paths.h>
#include <optimizer/tlist.h>


#if PG_VERSION_NUM >= 180000
#include <commands/explain_format.h>
#include <executor/executor.h>
#endif

#include "io/bson_core.h"
#include "customscan/bson_custom_scan.h"
#include "customscan/custom_scan_registrations.h"
#include "metadata/metadata_cache.h"
#include "query/query_operator.h"
#include "catalog/pg_am.h"
#include "commands/cursor_common.h"
#include "customscan/bson_custom_scan_private.h"
#include "api_hooks.h"
#include "opclass/bson_index_support.h"
#include "index_am/index_am_utils.h"
#include "opclass/bson_gin_composite_scan.h"
#include "index_am/documentdb_rum.h"
#include "utils/version_utils.h"

#define InputContinuationNodeName "DynamicCursorScanInputContinuation"


/* --------------------------------------------------------- */
/* Data-types */
/* --------------------------------------------------------- */

typedef enum QueryScanType
{
	QueryScanType_Unknown = 0,

	QueryScanType_TidRangeScan = 1,

	QueryScanType_PrimaryKeyScan = 2,

	QueryScanType_SecondaryIndexScan = 3,

	QueryScanType_SecondaryIndexBitmapScan = 4,

	QueryScanType_SecondaryIndexBitmapAnd = 5,

	QueryScanType_SecondaryIndexBitmapOr = 6,

	QueryScanType_SecondaryIndexOnlyScan = 7,
} QueryScanType;

/*
 * The input continuation data parsed out during query planning.
 */
typedef struct DynamicCursorInputContinuation
{
	/* Must be the first field */
	ExtensibleNode extensible;

	/* The query specified table ID determined at plan time */
	Oid queryTableId;

	/* The type of scan that this query will perform */
	QueryScanType scanType;

	/* The continuation item pointer as a uint64 value */
	uint64_t itemPointerAsUint64;
} DynamicCursorInputContinuation;


/*
 * The custom Scan State for the DocumentDBApiScan.
 */
typedef struct ExtensionCursorScanState
{
	/* must be first field */
	CustomScanState custom_scanstate;

	/* The execution state of the inner path */
	ScanState *innerScanState;

	/* The planning state of the inner path */
	Plan *innerPlan;
} ExtensionCursorScanState;

/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */
static Plan * ExtensionCursorScanPlanCustomPath(PlannerInfo *root,
												RelOptInfo *rel,
												struct CustomPath *best_path,
												List *tlist,
												List *clauses,
												List *custom_plans);
static Node * ExtensionCursorScanCreateCustomScanState(CustomScan *cscan);
static void ExtensionCursorScanBeginCustomScan(CustomScanState *node, EState *estate,
											   int eflags);
static TupleTableSlot * ExtensionCursorScanExecCustomScan(CustomScanState *node);
static void ExtensionCursorScanEndCustomScan(CustomScanState *node);
static void ExtensionCursorScanReScanCustomScan(CustomScanState *node);
static void ExtensionCursorScanExplainCustomScan(CustomScanState *node, List *ancestors,
												 ExplainState *es);
static TupleTableSlot * ExtensionCursorScanNext(CustomScanState *node);
static bool ExtensionCursorScanNextRecheck(ScanState *state, TupleTableSlot *slot);
static void CopyNodeDynamicCursorContinuation(ExtensibleNode *target_node, const
											  ExtensibleNode *source_node);
static void OutDynamicCursorInputContinuation(StringInfo str, const struct
											  ExtensibleNode *raw_node);
static void ReadDynamicCursorInputContinuation(struct ExtensibleNode *node);
static bool EqualUnsupportedExtensionCursorScanNode(const struct ExtensibleNode *a,
													const struct ExtensibleNode *b);

PG_FUNCTION_INFO_V1(command_cursor_tracker);

/* Declaration of extensibility paths for query processing (See extensible.h) */
static const struct CustomPathMethods ExtensionCursorScanPathMethods = {
	.CustomName = "DocumentDBApiCursorScan",
	.PlanCustomPath = ExtensionCursorScanPlanCustomPath,
};

static const struct CustomScanMethods ExtensionCursorScanMethods = {
	.CustomName = "DocumentDBApiCursorScan",
	.CreateCustomScanState = ExtensionCursorScanCreateCustomScanState
};

static const struct CustomExecMethods ExtensionCursorScanExecuteMethods = {
	.CustomName = "DocumentDBApiCursorScan",
	.BeginCustomScan = ExtensionCursorScanBeginCustomScan,
	.ExecCustomScan = ExtensionCursorScanExecCustomScan,
	.EndCustomScan = ExtensionCursorScanEndCustomScan,
	.ReScanCustomScan = ExtensionCursorScanReScanCustomScan,
	.ExplainCustomScan = ExtensionCursorScanExplainCustomScan,
};

static const ExtensibleNodeMethods InputContinuationMethods =
{
	InputContinuationNodeName,
	sizeof(DynamicCursorInputContinuation),
	CopyNodeDynamicCursorContinuation,
	EqualUnsupportedExtensionCursorScanNode,
	OutDynamicCursorInputContinuation,
	ReadDynamicCursorInputContinuation
};


/*
 * Dummy function used to send cursor state to the planner.
 */
Datum
command_cursor_tracker(PG_FUNCTION_ARGS)
{
	ereport(ERROR, (errmsg("command_cursor_tracker() must never be invoked directly")));
}


/*
 * Registers any custom nodes that the Extension Scan produces.
 * This is for any items present in the custom_private field.
 */
void
RegisterDynamicCursorScanNodes(void)
{
	RegisterExtensibleNodeMethods(&InputContinuationMethods);
}


/* --------------------------------------------------------- */
/* Helper methods for the dynamic cursor scan planning */
/* --------------------------------------------------------- */


static CustomPath *
CreateCustomScanPathForStreaming(PlannerInfo *root, RelOptInfo *rel, Path *inputPath,
								 DynamicCursorInputContinuation *inputContinuation,
								 PathTarget *baseRelPathTarget)
{
	/* wrap the path in a custom path */
	CustomPath *customPath = makeNode(CustomPath);
	customPath->methods = &ExtensionCursorScanPathMethods;

	Path *path = &customPath->path;
	path->pathtype = T_CustomScan;

	/* copy the parameters from the inner path */
	Assert(inputPath->parent == rel);
	path->parent = rel;

	path->param_info = NULL;

	/* Copy scalar values in from the inner path */
	path->rows = rel->rows;
	path->startup_cost = inputPath->startup_cost;
	path->total_cost = inputPath->total_cost;

	/* For now the custom path is not parallel safe */
	path->parallel_safe = false;

	/* Just project out the sub projection document.
	 * Note this is transformed later when there's an actual projection to be had.
	 */
	path->pathtarget = copy_pathtarget(inputPath->pathtarget);
	customPath->custom_paths = list_make1(inputPath);

#if (PG_VERSION_NUM >= 150000)

	/* necessary to avoid extra Result node in PG15 */
	customPath->flags = CUSTOMPATH_SUPPORT_PROJECTION;
#endif

	/* Store the input continuation to be used later, as well as the inner projection
	 * target List
	 * NOTE: Anything added here must be of type ExtensibleNode and must be registered
	 * with the RegisterNodes method below.
	 */
	DynamicCursorInputContinuation *inputContinuationCopy = palloc(
		sizeof(DynamicCursorInputContinuation));
	memcpy(inputContinuationCopy, inputContinuation,
		   sizeof(DynamicCursorInputContinuation));
	customPath->custom_private = list_make1(inputContinuationCopy);

	return customPath;
}


static bool
GetIndexSupportsGetIndexKey(Oid relam, Oid opfamily)
{
	return false;
}


static List *
WalkRelPathsAndCreateCustomPathsForFirstPage(PlannerInfo *root, RelOptInfo *rel,
											 DynamicCursorInputContinuation *
											 inputContinuation,
											 PathTarget *baseRelPathTarget)
{
	List *customPlanPaths = NIL;
	ListCell *cell;

	/* Walk the existing paths and wrap them in a custom scan */
	foreach(cell, rel->pathlist)
	{
		Path *inputPath = lfirst(cell);

		inputContinuation->scanType = QueryScanType_Unknown;
		QueryScanType scanType = QueryScanType_Unknown;
		if (inputPath->pathtype == T_IndexScan)
		{
			IndexPath *indexPath = (IndexPath *) inputPath;

			bool isPrimaryKeyPath = IsBtreePrimaryKeyIndex(
				indexPath->indexinfo);
			if (isPrimaryKeyPath)
			{
				scanType = QueryScanType_PrimaryKeyScan;
			}
			else if (GetIndexSupportsGetIndexKey(indexPath->indexinfo->relam,
												 indexPath->indexinfo->opfamily[0]))
			{
				scanType = QueryScanType_SecondaryIndexScan;
			}
			else if (indexPath->indexinfo->amhasgetbitmap)
			{
				inputPath = (Path *) create_bitmap_heap_path(root, rel,
															 inputPath,
															 rel->lateral_relids, 1.0,
															 0);
				if (inputPath->total_cost == 0)
				{
					/* Force the output path to also be cost 0
					 * Since the base was cost 0 (see documentdb api's planner.c)
					 */
					inputPath->total_cost = 0;
					inputPath->startup_cost = 0;
				}

				scanType = QueryScanType_SecondaryIndexBitmapScan;
			}
		}
		else if (inputPath->pathtype == T_IndexOnlyScan)
		{
			IndexPath *indexPath = (IndexPath *) inputPath;
			if (IsBtreePrimaryKeyIndex(indexPath->indexinfo))
			{
				/* Convert back to index scan to get cursors */
				inputPath->pathtype = T_IndexScan;
				scanType = QueryScanType_PrimaryKeyScan;
			}
			else if (GetIndexSupportsGetIndexKey(indexPath->indexinfo->relam,
												 indexPath->indexinfo->opfamily[0]))
			{
				scanType = QueryScanType_SecondaryIndexOnlyScan;
			}
			else if (indexPath->indexinfo->amhasgetbitmap)
			{
				inputPath = (Path *) create_bitmap_heap_path(root, rel,
															 inputPath,
															 rel->lateral_relids, 1.0,
															 0);
				if (inputPath->total_cost == 0)
				{
					/* Force the output path to also be cost 0
					 * Since the base was cost 0 (see documentdb api's planner.c)
					 */
					inputPath->total_cost = 0;
					inputPath->startup_cost = 0;
				}

				scanType = QueryScanType_SecondaryIndexBitmapScan;
			}
		}
		else if (inputPath->pathtype == T_BitmapHeapScan)
		{
			BitmapHeapPath *bitmapHeapPath = (BitmapHeapPath *) inputPath;
			Path *bitmapQualPath = bitmapHeapPath->bitmapqual;

			if (bitmapQualPath->pathtype == T_IndexScan ||
				bitmapQualPath->pathtype == T_IndexOnlyScan)
			{
				IndexPath *indexPath = (IndexPath *) bitmapQualPath;
				if (IsBtreePrimaryKeyIndex(indexPath->indexinfo))
				{
					inputPath = (Path *) indexPath;
					if (inputPath->pathtype == T_IndexOnlyScan)
					{
						inputPath->pathtype = T_IndexScan;
					}

					scanType = QueryScanType_PrimaryKeyScan;
				}
				else if (bitmapQualPath->pathtype == T_IndexOnlyScan)
				{
					scanType = QueryScanType_SecondaryIndexBitmapScan;
				}
				else
				{
					Assert(bitmapQualPath->pathtype == T_IndexScan);
					scanType = QueryScanType_SecondaryIndexBitmapScan;
				}
			}
			else if (bitmapQualPath->pathtype == T_BitmapAnd)
			{
				scanType = QueryScanType_SecondaryIndexBitmapAnd;
			}
			else if (bitmapQualPath->pathtype == T_BitmapOr)
			{
				scanType = QueryScanType_SecondaryIndexBitmapOr;
			}
		}

		if (inputPath->pathtype == T_SeqScan)
		{
			/* See if we can convert to primary key scan */
			IndexOptInfo *info = GetPrimaryKeyIndexOptCore(rel);
			if (info != NULL)
			{
				inputPath = (Path *) create_index_path(
					root, info, NIL, NIL, NIL, NIL, ForwardScanDirection, false,
					rel->lateral_relids,
					1, false);
				scanType = QueryScanType_PrimaryKeyScan;
			}
			else if ((rel->amflags & AMFLAG_HAS_TID_RANGE) != 0)
			{
				/* Convert a seqscan to a TidScan */
				ItemPointer tidLowerPointPointer = palloc0(sizeof(ItemPointerData));
				Const *tidLowerBoundConst = makeConst(TIDOID, -1, InvalidOid,
													  sizeof(ItemPointerData),
													  PointerGetDatum(
														  tidLowerPointPointer),
													  false,
													  false);
				OpExpr *tidLowerBoundScan = (OpExpr *) make_opclause(
					TIDGreaterEqOperator, BOOLOID, false,
					(Expr *) makeVar(rel->relid, SelfItemPointerAttributeNumber,
									 TIDOID,
									 -1, InvalidOid, 0),
					(Expr *) tidLowerBoundConst, InvalidOid, InvalidOid);
				RestrictInfo *rinfo = make_simple_restrictinfo(root,
															   (Expr *)
															   tidLowerBoundScan);
				inputPath = (Path *) create_tidrangescan_path(root, rel, list_make1(
																  rinfo),
															  rel->lateral_relids);
				scanType = QueryScanType_TidRangeScan;
			}
		}

		if (scanType == QueryScanType_Unknown)
		{
			continue;
		}

		inputContinuation->scanType = scanType;
		CustomPath *customPath = CreateCustomScanPathForStreaming(
			root, rel, inputPath, inputContinuation,
			baseRelPathTarget);
		customPlanPaths = lappend(customPlanPaths, customPath);
	}

	return customPlanPaths;
}


bool
UpdatePathsWithDynamicStreamingCursorPlans(PlannerInfo *root, RelOptInfo *rel,
										   RangeTblEntry *rte,
										   ReplaceExtensionFunctionContext *context)
{
	/*
	 *  Check for various cases that can't handle streaming cursors
	 */
	if (rte->tablesample != NULL ||
		list_length(rel->baserestrictinfo) < 1)
	{
		return false;
	}

	if (!IsClusterVersionAtleast(DocDB_V0, 113, 0))
	{
		ereport(ERROR, (errmsg(
							"Dynamic streaming cursors require cluster version at least 0.113.0")));
	}

	/* first look for a continuation function in the base quals */
	bool hasContinuation = false;
	ListCell *cell;

	foreach(cell, rel->baserestrictinfo)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, cell);

		if (IsA(rinfo->clause, FuncExpr))
		{
			FuncExpr *expr = (FuncExpr *) rinfo->clause;
			if (expr->funcid == ApiCursorTrackerFunctionId())
			{
				if (hasContinuation)
				{
					ereport(ERROR, (errmsg(
										"More than one continuation provided. this is unsupported")));
				}

				if (list_length(expr->args) != 2)
				{
					ereport(ERROR, (errmsg(
										"Invalid cursor state provided - must have 2 arguments.")));
				}

				Node *secondArg = lsecond(expr->args);
				if (IsA(secondArg, Param))
				{
					/*
					 * The only reason why parameters would not be resolved at this stage
					 * is if we are dealing with a generic plan.
					 *
					 * Instead of throwing an error, stop and give the planner another
					 * chance to generate a plan with bound parameters.
					 */
					return false;
				}

				if (!IsA(secondArg, Const))
				{
					ereport(ERROR, (errmsg(
										"Invalid cursor state provided - must be a const value. found: %d",
										secondArg->type)));
				}

				hasContinuation = true;
			}
			else if (expr->funcid == ApiCursorStateFunctionId())
			{
				ereport(ERROR, (errmsg(
									"Cannot have both cursorTracker and cursorState funcs")));
			}
		}
	}

	/* No continuation found. We can skip. */
	if (!hasContinuation)
	{
		return false;
	}

	if (rte->rtekind != RTE_RELATION)
	{
		/* Dynamic streaming cursors not supported for non-relation RTEs. */
		return false;
	}

	/*
	 *  If a continuation is provided, ensure that the plan paths are valid.
	 */
	if (root->hasJoinRTEs || root->hasRecursion || root->hasLateralRTEs ||
		root->group_pathkeys != NIL || root->sort_pathkeys != NIL ||
		root->agginfos != NIL || root->hasAlternativeSubPlans ||
		root->window_pathkeys != NIL || root->parse->hasTargetSRFs)
	{
		/* Use persisted cursors for these scenarios */
		return false;
	}

	if (root->parent_root != NULL)
	{
		/* In a subquery - use persisted cursors */
		return false;
	}

	if (root->parse->commandType == CMD_MERGE)
	{
		/* $merge and $out do not support dynamic cursors */
		return false;
	}

	if (root->parse->limitCount != NULL)
	{
		/* Dynamic streaming requires limit 1 */
		if (IsA(root->parse->limitCount, Const))
		{
			Const *limitConst = (Const *) root->parse->limitCount;
			if (DatumGetInt64(limitConst->constvalue) != 1)
			{
				/* Dynamic streaming cursors only support limit 1 */
				return false;
			}
		}
		else
		{
			/* Non-constant limit - can't handle dynamically */
			return false;
		}
	}

	if (root->parse->limitOffset != NULL)
	{
		/* Dynamic streaming requires offset 0 */
		if (IsA(root->parse->limitOffset, Const))
		{
			Const *offsetConst = (Const *) root->parse->limitOffset;
			if (DatumGetInt64(offsetConst->constvalue) != 0)
			{
				/* Dynamic streaming cursors only support offset 0 */
				return false;
			}
		}
		else
		{
			/* Non-constant offset - can't handle dynamically */
			return false;
		}
	}

	/* Parse the continuation state */
	DynamicCursorInputContinuation inputContinuation = { 0 };
	inputContinuation.extensible.type = T_ExtensibleNode;
	inputContinuation.extensible.extnodename = InputContinuationNodeName;
	inputContinuation.queryTableId = rte->relid;
	inputContinuation.scanType = QueryScanType_Unknown;

	/* Extract the base rel for the query */
	Relation tableRel = RelationIdGetRelation(rte->relid);

	/* Point the nested scan's projection to the base table's projection */
	PathTarget *baseRelPathTarget = BuildBaseRelPathTarget(tableRel, rel->relid);

	/* Ensure you close the rel */
	RelationClose(tableRel);

	List *customPlanPaths = WalkRelPathsAndCreateCustomPathsForFirstPage(
		root, rel, &inputContinuation, baseRelPathTarget);

	if (customPlanPaths == NIL)
	{
		/* No streamable paths - default to persistent */
		return false;
	}

	/* Don't need to handle parallel paths since custom_scan function is not parallel safe */
	rel->pathlist = customPlanPaths;

	/* If we got here, we need ordering on CTID, disable parallel scan
	 * This is because streaming cursors need monotonically increasing order for
	 * tuples and we can't allow parallel scan to reorder tuples.
	 */
	rel->partial_pathlist = NIL;

	return true;
}


/* --------------------------------------------------------- */
/* Helper methods exports */
/* --------------------------------------------------------- */

/*
 * Given a scan path for the extension path, generates a
 * Custom Plan for the path. Note that the inner path
 * is already planned since it is listed as an inner_path
 * in the custom path above.
 * This is roughly the same as custom_scan_continuation's behavior.
 */
static Plan *
ExtensionCursorScanPlanCustomPath(PlannerInfo *root,
								  RelOptInfo *rel,
								  struct CustomPath *best_path,
								  List *tlist,
								  List *clauses,
								  List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);

	/* Initialize and copy necessary data */
	cscan->methods = &ExtensionCursorScanMethods;

	/* The first item is the continuation - we propagate it forward */
	cscan->custom_private = best_path->custom_private;
	cscan->custom_plans = custom_plans;

	Scan *nestedPlan = linitial(custom_plans);

	if (tlist != NIL)
	{
		/* This is available when there's no projections */
		cscan->scan.plan.targetlist = tlist;
		cscan->scan.scanrelid = nestedPlan->scanrelid;
	}
	else
	{
		/* We're responsible for doing projections here
		 * Push the projection to the nestedPlan.
		 */
		nestedPlan->plan.targetlist = root->processed_tlist;

		ListCell *cell;
		List *outputTargetEntries = NIL;
		foreach(cell, root->processed_tlist)
		{
			TargetEntry *tle = (TargetEntry *) lfirst(cell);

			/* Do something with each target entry */
			Oid resultType = exprType((Node *) tle->expr);
			Var *projVar = makeVar(1, tle->resno, resultType, -1, InvalidOid, 0);
			TargetEntry *outputTle = makeTargetEntry((Expr *) projVar, tle->resno,
													 tle->resname, tle->resjunk);
			outputTargetEntries = lappend(outputTargetEntries, outputTle);
		}

		cscan->custom_scan_tlist = root->processed_tlist;
		cscan->scan.plan.targetlist = outputTargetEntries;
	}

#if (PG_VERSION_NUM >= 150000)

	/* necessary to avoid extra Result node in PG15 */
	cscan->flags = CUSTOMPATH_SUPPORT_PROJECTION;
#endif

	return (Plan *) cscan;
}


/*
 * Given a custom scan generated during the plan phase
 * Creates a Custom ScanState that is used during the
 * execution of the plan.
 * This is called at the beginning of query execution
 * by the executor.
 */
static Node *
ExtensionCursorScanCreateCustomScanState(CustomScan *cscan)
{
	ExtensionCursorScanState *scanState =
		(ExtensionCursorScanState *) newNode(
			sizeof(ExtensionCursorScanState), T_CustomScanState);

	CustomScanState *cscanstate = &scanState->custom_scanstate;
	cscanstate->methods = &ExtensionCursorScanExecuteMethods;

	/* Here we don't store the custom plan inside the custom_ps of the custom scan state yet
	 * This is done as part of BeginCustomScan */
	Plan *innerPlan = (Plan *) linitial(cscan->custom_plans);
	scanState->innerPlan = innerPlan;

	return (Node *) cscanstate;
}


static void
ExtensionCursorScanBeginCustomScan(CustomScanState *node, EState *estate,
								   int eflags)
{
	/* Initialize the current state of the plan */
	ExtensionCursorScanState *scanState =
		(ExtensionCursorScanState *) node;
	scanState->innerScanState = (ScanState *) ExecInitNode(
		scanState->innerPlan, estate, eflags);

	/* Store the inner state here so that EXPLAIN works */
	scanState->custom_scanstate.custom_ps = list_make1(
		scanState->innerScanState);
}


static void
ExtensionCursorScanEndCustomScan(CustomScanState *node)
{
	ExtensionCursorScanState *extensionCursorScanState =
		(ExtensionCursorScanState *) node;
	ExecEndNode((PlanState *) extensionCursorScanState->innerScanState);
}


static void
ExtensionCursorScanReScanCustomScan(CustomScanState *node)
{
	ExtensionCursorScanState *extensionCursorScanState =
		(ExtensionCursorScanState *) node;

	ExecReScan((PlanState *) extensionCursorScanState->innerScanState);
}


static void
ExtensionCursorScanExplainCustomScan(CustomScanState *node, List *ancestors,
									 ExplainState *es)
{ }


static TupleTableSlot *
ExtensionCursorScanExecCustomScan(CustomScanState *pstate)
{
	ExtensionCursorScanState *node = (ExtensionCursorScanState *) pstate;

	/*
	 * Call ExecScan with the next/recheck methods. This handles
	 * Post-processing for projections, custom filters etc.
	 */
	TupleTableSlot *returnSlot = ExecScan(&node->custom_scanstate.ss,
										  (ExecScanAccessMtd) ExtensionCursorScanNext,
										  ExtensionCursorScanNextRecheck);

	return returnSlot;
}


/*
 * Executes the inner scan and gets the next available Tuple for the query.
 */
static TupleTableSlot *
ExtensionCursorScanNext(CustomScanState *node)
{
	ExtensionCursorScanState *extensionCursorScanState =
		(ExtensionCursorScanState *) node;

	/* Fetch a tuple from the underlying scan */
	TupleTableSlot *slot = extensionCursorScanState->innerScanState->ps.ExecProcNode(
		(PlanState *) extensionCursorScanState->innerScanState);

	/* We're done scanning, so return NULL */
	if (TupIsNull(slot))
	{
		return slot;
	}

	/* Copy the slot onto our own query state for projection */
	TupleTableSlot *ourSlot = node->ss.ss_ScanTupleSlot;
	return ExecCopySlot(ourSlot, slot);
}


/*
 * Runs the "recheck" flow for any tuples marked for recheck.
 * This is noop for the extension scan since the recheck is done by the inner scan
 * at this point.
 */
static bool
ExtensionCursorScanNextRecheck(ScanState *state, TupleTableSlot *slot)
{
	/* The underlying scan takes care of recheck since we call ExecProcNode directly. We shouldn't need recheck */
	ereport(ERROR, (errmsg("Recheck is unexpected on Custom Scan")));
}


/*
 * Support for comparing two Scan extensible nodes
 * Currently unsupported.
 */
static bool
EqualUnsupportedExtensionCursorScanNode(const struct ExtensibleNode *a,
										const struct ExtensibleNode *b)
{
	ereport(ERROR, (errmsg("Equal for node type not implemented")));
}


/*
 * Support for Copying the InputContinuation node
 */
static void
CopyNodeDynamicCursorContinuation(struct ExtensibleNode *target_node, const struct
								  ExtensibleNode *source_node)
{
	DynamicCursorInputContinuation *from = (DynamicCursorInputContinuation *) source_node;

	DynamicCursorInputContinuation *newNode =
		(DynamicCursorInputContinuation *) target_node;

	/* Note: Any pointer fields need to be updated post the memcpy */
	memcpy(newNode, from, sizeof(DynamicCursorInputContinuation));
}


/*
 * Support for Outputing the InputContinuation node
 */
static void
OutDynamicCursorInputContinuation(StringInfo str, const struct ExtensibleNode *raw_node)
{
	DynamicCursorInputContinuation *node = (DynamicCursorInputContinuation *) raw_node;
	WRITE_OID_FIELD(queryTableId);
	WRITE_INT32_FIELD(scanType);
	WRITE_UINT64_FIELD(itemPointerAsUint64);
}


/*
 * Function for reading DocumentDBApiScan node inverse of Out
 */
static void
ReadDynamicCursorInputContinuation(struct ExtensibleNode *node)
{
	const char *token;
	int length;
	DynamicCursorInputContinuation *local_node = (DynamicCursorInputContinuation *) node;
	local_node->extensible.type = T_ExtensibleNode;
	local_node->extensible.extnodename = InputContinuationNodeName;

	READ_OID_FIELD(queryTableId);
	READ_INT32_FIELD(scanType);
	READ_UINT64_FIELD(itemPointerAsUint64);
}
