/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/customscan/custom_distinct_scan.c
 *
 * Custom query scan that handles processing of DISTINCT with secondary indexes
 * that support TID skipping for index entries.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <catalog/pg_type.h>
#include <fmgr.h>
#include <nodes/extensible.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <optimizer/pathnode.h>
#include <optimizer/optimizer.h>
#include <parser/parse_relation.h>
#include <rewrite/rewriteManip.h>
#include <utils/rel.h>
#include <miscadmin.h>
#include <optimizer/paths.h>
#include <access/relscan.h>
#include <optimizer/tlist.h>
#include <customscan/bson_custom_scan_private.h>

#include "io/bson_core.h"
#include "planner/documentdb_planner.h"
#include "customscan/custom_scan_registrations.h"
#include "metadata/metadata_cache.h"
#include "query/query_operator.h"
#include "catalog/pg_am.h"
#include "commands/cursor_common.h"
#include "utils/documentdb_errors.h"
#include "customscan/bson_custom_query_scan.h"
#include "index_am/index_am_utils.h"
#include "index_am/documentdb_rum.h"
#include "utils/query_utils.h"
#include "commands/commands_common.h"
#include "api_hooks_def.h"


/* --------------------------------------------------------- */
/* Data-types */
/* --------------------------------------------------------- */


typedef struct DistinctInputQueryState
{
	/* Must be the first field */
	ExtensibleNode extensible;
} DistinctInputQueryState;


/*
 * The custom Scan State for the DocumentDBApiQueryScan.
 */
typedef struct DistinctQueryScanState
{
	/* must be first field */
	CustomScanState custom_scanstate;

	/* The execution state of the inner path */
	ScanState *innerScanState;

	/* The planning state of the inner path */
	Plan *innerPlan;

	/* Function to skip TIDs for the current entry */
	PGFunction skipTidsFunc;

	/* Whether path summarization is forced */
	bool isPathSummarizationForced;

	/* IndexScanDesc for the current scan */
	IndexScanDesc scanDesc;

	/* The input state */
	DistinctInputQueryState *inputQueryState;
} DistinctQueryScanState;

/* Name needed for Postgres to register a custom scan */
#define InputContinuationNodeName "DocumentsDistinctQueryScanInput"

/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */
static Plan * DistinctQueryScanPlanCustomPath(PlannerInfo *root,
											  RelOptInfo *rel,
											  struct CustomPath *best_path,
											  List *tlist,
											  List *clauses,
											  List *custom_plans);
static Node * DistinctQueryScanCreateCustomScanState(CustomScan *cscan);
static void DistinctQueryScanBeginCustomScan(CustomScanState *node, EState *estate,
											 int eflags);
static TupleTableSlot * DistinctQueryScanExecCustomScan(CustomScanState *node);
static void DistinctQueryScanEndCustomScan(CustomScanState *node);
static void DistinctQueryScanReScanCustomScan(CustomScanState *node);
static void DistinctQueryScanExplainCustomScan(CustomScanState *node, List *ancestors,
											   ExplainState *es);

static void CopyNodeInputQueryState(ExtensibleNode *target_node, const
									ExtensibleNode *source_node);
static void OutInputQueryScanNode(StringInfo str, const struct ExtensibleNode *raw_node);
static void ReadDistinctExtensionQueryScanNode(struct ExtensibleNode *node);
static bool EqualUnsupportedExtensionQueryScanNode(const struct ExtensibleNode *a,
												   const struct ExtensibleNode *b);
static TupleTableSlot * DistinctQueryScanNext(CustomScanState *node);
static bool DistinctQueryScanNextRecheck(ScanState *state, TupleTableSlot *slot);
static List * AddDistinctCustomPathCore(PlannerInfo *root, List *pathList);
static bool ContainsDisqualifyingAggref(Node *node, void *context);
static bool IsSafeFirstAggregateFunctionOid(Oid aggregateFunctionOid);
static bool HasOnlySafeGroupFirstAggrefs(PlannerInfo *root);

extern bool EnableDistinctCustomScan;
extern bool EnableDistinctScanForGroupFirst;
extern bool EnableGroupByDistinctScan;

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

/* Declaration of extensibility paths for query processing (See extensible.h) */
static const struct CustomPathMethods DistinctQueryScanPathMethods = {
	.CustomName = "DocumentDBApiDistinctQueryScan",
	.PlanCustomPath = DistinctQueryScanPlanCustomPath,
};

static const struct CustomScanMethods DistinctQueryScanMethods = {
	.CustomName = "DocumentDBApiDistinctQueryScan",
	.CreateCustomScanState = DistinctQueryScanCreateCustomScanState
};

static const struct CustomExecMethods DistinctQueryScanExecuteMethods = {
	.CustomName = "DocumentDBApiDistinctQueryScan",
	.BeginCustomScan = DistinctQueryScanBeginCustomScan,
	.ExecCustomScan = DistinctQueryScanExecCustomScan,
	.EndCustomScan = DistinctQueryScanEndCustomScan,
	.ReScanCustomScan = DistinctQueryScanReScanCustomScan,
	.ExplainCustomScan = DistinctQueryScanExplainCustomScan,
};


static const ExtensibleNodeMethods InputQueryStateMethods =
{
	InputContinuationNodeName,
	sizeof(DistinctInputQueryState),
	CopyNodeInputQueryState,
	EqualUnsupportedExtensionQueryScanNode,
	OutInputQueryScanNode,
	ReadDistinctExtensionQueryScanNode
};


/*
 * Registers any custom nodes that the extension Scan produces.
 * This is for any items present in the custom_private field.
 */
void
RegisterDistinctScanNodes(void)
{
	RegisterExtensibleNodeMethods(&InputQueryStateMethods);
	RegisterCustomScanMethods(&DistinctQueryScanMethods);
}


void
AddDistinctCustomScanWrapper(PlannerInfo *root, RelOptInfo *rel, RangeTblEntry *rte)
{
	/*
	 * Currently we only support scenarios where it's all DISTINCT or GROUP BY
	 * with either no actual aggregate accumulators or exclusively safe $first
	 * accumulators in the target list.
	 *
	 * Note: we cannot rely on root->parse->hasAggs here because the aggregation
	 * pipeline rewrite for $group sets hasAggs = true even when only an _id
	 * grouping expression is present (no accumulators). We instead walk the
	 * top-level target list for Aggref nodes.
	 */
	bool distinctScenario = EnableDistinctCustomScan &&
							root->distinct_pathkeys != NIL &&
							list_length(root->distinct_pathkeys) == list_length(
		root->query_pathkeys);
	bool groupScenario = EnableGroupByDistinctScan &&
						 root->group_pathkeys != NIL && root->query_pathkeys != NIL &&
						 list_length(root->group_pathkeys) == list_length(
		root->query_pathkeys) &&
						 !contain_aggs_of_level((Node *) root->parse->targetList, 0);
	bool groupFirstScenario = EnableDistinctScanForGroupFirst &&
							  root->group_pathkeys != NIL &&
							  root->parse->havingQual == NULL &&
							  HasOnlySafeGroupFirstAggrefs(root);

	if (distinctScenario || groupScenario || groupFirstScenario)
	{
		rel->pathlist = AddDistinctCustomPathCore(root, rel->pathlist);
		rel->partial_pathlist = AddDistinctCustomPathCore(root, rel->partial_pathlist);
	}
}


/* --------------------------------------------------------- */
/* Helper methods exports */
/* --------------------------------------------------------- */


/*
 * Helper method that walks all paths in the rel's pathlist
 * and adds a custom path wrapper that contains the queryState.
 */
static List *
AddDistinctCustomPathCore(PlannerInfo *root, List *pathList)
{
	List *customPlanPaths = NIL;
	ListCell *cell;

	foreach(cell, pathList)
	{
		Path *inputPath = lfirst(cell);
		if (inputPath->pathtype != T_IndexScan &&
			inputPath->pathtype != T_IndexOnlyScan)
		{
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
		}

		IndexPath *indexPath = (IndexPath *) inputPath;

		/*
		 * The number of index ORDER BYs must match the number of pathkeys we
		 * intend to deduplicate on. For DISTINCT that's distinct_pathkeys; for
		 * GROUP BY (with no aggregates) that's group_pathkeys.
		 */
		int targetPathKeyLength = root->distinct_pathkeys != NIL ?
								  list_length(root->distinct_pathkeys) :
								  list_length(root->group_pathkeys);

		if (list_length(indexPath->indexorderbys) != targetPathKeyLength)
		{
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
		}

		bool isPathSummarizationForced = false;
		PGFunction skipTidsFunc = GetSkipTidsOnCurrentEntryFunc(
			indexPath->indexinfo->relam, indexPath->indexinfo->opfamily[0],
			&isPathSummarizationForced);

		if (skipTidsFunc == NULL)
		{
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
		}

		/* wrap the path in a custom path */
		CustomPath *customPath = makeNode(CustomPath);
		customPath->methods = &DistinctQueryScanPathMethods;

		DistinctInputQueryState *queryState = palloc0(sizeof(DistinctInputQueryState));

		Path *path = &customPath->path;
		path->pathtype = T_CustomScan;

		/* copy the parameters from the inner path */
		path->parent = inputPath->parent;

		/* we don't support lateral joins here so required outer is 0 */
		path->param_info = NULL;

		/* Copy scalar values in from the inner path */
		path->rows = inputPath->rows;
		path->startup_cost = inputPath->startup_cost;
		path->total_cost = inputPath->total_cost;

		/* For now the custom path is as parallel safe as its inner path */
		path->parallel_safe = inputPath->parallel_safe;
		path->parallel_workers = inputPath->parallel_workers;
		path->parallel_aware = inputPath->parallel_aware;

		/* move the 'projection' from the path to the custom path. */
		path->pathtarget = inputPath->pathtarget;

		/* Copy the param paths */
		path->param_info = inputPath->param_info;
		customPath->custom_paths = list_make1(inputPath);
		customPath->path.pathkeys = inputPath->pathkeys;

		/* necessary to avoid extra Result node in PG15 */
		customPath->flags = CUSTOMPATH_SUPPORT_PROJECTION;

		/* Save the continuation data into storage */
		queryState->extensible.type = T_ExtensibleNode;
		queryState->extensible.extnodename = InputContinuationNodeName;

		/* Store the input state to be used later.
		 * NOTE: Anything added here must be of type ExtensibleNode and must be registered
		 * with the RegisterNodes method below.
		 */
		customPath->custom_private = list_make1(queryState);

		customPlanPaths = lappend(customPlanPaths, customPath);
	}

	return customPlanPaths;
}


/*
 * expression_tree_walker callback that returns true (aborting the walk) as
 * soon as it encounters an Aggref that is NOT safe to combine with
 * distinct-scan key skipping. An Aggref is considered safe when:
 *
 *   - aggfnoid is a $first variant that picks the first input row for the
 *     group without consulting an explicit sort spec, AND
 *   - it has no explicit aggorder / aggdistinct / aggfilter (which would
 *     change semantics).
 */
static bool
ContainsDisqualifyingAggref(Node *node, void *context)
{
	if (node == NULL)
	{
		return false;
	}

	if (IsA(node, Aggref))
	{
		Aggref *aggref = (Aggref *) node;
		Oid aggregateFunctionOid = aggref->aggfnoid;

		/*
		 * Allow an extension-provided hook to resolve the Aggref to its
		 * effective aggregate function oid (Example: unwrapping an aggregate
		 * wrapper introduced by a query rewrite on a distributed-execution
		 * layer that injects a partial aggregation down to shards). When no hook
		 * is registered, we classify aggref->aggfnoid as-is.
		 */
		if (get_effective_aggregate_function_oid_hook != NULL)
		{
			get_effective_aggregate_function_oid_hook(aggref, &aggregateFunctionOid);
		}

		if (!IsSafeFirstAggregateFunctionOid(aggregateFunctionOid))
		{
			/* any other accumulator (including sort-aware bsonfirst) disqualifies */
			return true;
		}

		if (aggref->aggorder != NIL || aggref->aggdistinct != NIL ||
			aggref->aggfilter != NULL)
		{
			/*
			 * Explicit ORDER BY / DISTINCT / FILTER inside the accumulator
			 * changes semantics.
			 */
			return true;
		}

		/* Aggref is OK; do not recurse into its sub-expressions */
		return false;
	}

	return expression_tree_walker(node, ContainsDisqualifyingAggref, context);
}


static bool
IsSafeFirstAggregateFunctionOid(Oid aggregateFunctionOid)
{
	return aggregateFunctionOid == BsonFirstOnSortedAggregateFunctionOid() ||
		   aggregateFunctionOid == BsonFirstWithExprAggregateFunctionOid();
}


static bool
HasOnlySafeGroupFirstAggrefs(PlannerInfo *root)
{
	ListCell *aggInfoCell;

	/*
	 * We rely exclusively on root->agginfos to enumerate the query's
	 * aggregates. The core planner populates agginfos via preprocess_aggrefs()
	 * before query_planner() runs, which is where this path-injection hook fires;
	 * so whenever the query has any aggregate (as a $first group always does)
	 * agginfos is already populated.
	 *
	 * If agginfos is empty we deliberately decline the optimization and return
	 * false rather than re-deriving the aggregate set from the target list.
	 * Returning false is always safe: the query simply runs with the normal
	 * GroupAggregate plan. This keeps us on a single, well-tested code path and
	 * avoids ever firing the distinct-scan rewrite based on an unvalidated
	 * planner state.
	 */
	if (root->agginfos == NIL)
	{
		return false;
	}

	bool foundSafeAggref = false;

	foreach(aggInfoCell, root->agginfos)
	{
		AggInfo *aggInfo = (AggInfo *) lfirst(aggInfoCell);

#if PG_VERSION_NUM >= 160000
		ListCell *aggrefCell;

		foreach(aggrefCell, aggInfo->aggrefs)
		{
			Aggref *aggref = (Aggref *) lfirst(aggrefCell);
			if (ContainsDisqualifyingAggref((Node *) aggref, NULL))
			{
				return false;
			}

			foundSafeAggref = true;
		}
#else
		Aggref *aggref = aggInfo->representative_aggref;
		if (aggref == NULL || ContainsDisqualifyingAggref((Node *) aggref, NULL))
		{
			return false;
		}

		foundSafeAggref = true;
#endif
	}

	return foundSafeAggref;
}


/*
 * Given a scan path for the extension path, generates a
 * Custom Plan for the path. Note that the inner path
 * is already planned since it is listed as an inner_path
 * in the custom path above.
 */
static Plan *
DistinctQueryScanPlanCustomPath(PlannerInfo *root,
								RelOptInfo *rel,
								struct CustomPath *best_path,
								List *tlist,
								List *clauses,
								List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);

	/* Initialize and copy necessary data */
	cscan->methods = &DistinctQueryScanMethods;

	/* The first item is the continuation - we propagate it forward */
	cscan->custom_private = best_path->custom_private;
	cscan->custom_plans = custom_plans;

	/* Only one plan is allowed here */
	Assert(list_length(custom_plans) == 1);

	/* The main plan comes in first */
	Plan *nestedPlan = linitial(custom_plans);

	/* Push the projection down to the inner plan */
	if (tlist != NIL)
	{
		cscan->scan.plan.targetlist = tlist;
	}
	else
	{
		/* Just project stuff from the inner scan */
		List *outerList = NIL;
		ListCell *cell;
		foreach(cell, nestedPlan->targetlist)
		{
			TargetEntry *entry = lfirst(cell);
			Var *var = makeVarFromTargetEntry(1, entry);
			outerList = lappend(outerList, makeTargetEntry((Expr *) var, entry->resno,
														   entry->resname,
														   entry->resjunk));
		}

		cscan->scan.plan.targetlist = outerList;
	}

	/* This is the input to the custom scan */
	cscan->custom_scan_tlist = nestedPlan->targetlist;
	cscan->flags = CUSTOMPATH_SUPPORT_PROJECTION;

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
DistinctQueryScanCreateCustomScanState(CustomScan *cscan)
{
	DistinctQueryScanState *queryScanState = (DistinctQueryScanState *) newNode(
		sizeof(DistinctQueryScanState), T_CustomScanState);

	CustomScanState *cscanstate = &queryScanState->custom_scanstate;
	cscanstate->methods = &DistinctQueryScanExecuteMethods;
	cscanstate->custom_ps = NIL;

	/* Here we don't store the custom plan inside the custom_ps of the custom scan state yet
	 * This is done as part of BeginCustomScan */
	Plan *innerPlan = (Plan *) linitial(cscan->custom_plans);
	queryScanState->innerPlan = innerPlan;

	queryScanState->inputQueryState = (DistinctInputQueryState *) linitial(
		cscan->custom_private);
	return (Node *) cscanstate;
}


static void
DistinctQueryScanBeginCustomScan(CustomScanState *node, EState *estate,
								 int eflags)
{
	/* Initialize the current state of the plan */
	DistinctQueryScanState *queryScanState = (DistinctQueryScanState *) node;

	queryScanState->innerScanState = (ScanState *) ExecInitNode(
		queryScanState->innerPlan, estate, eflags);

	/* Store the inner state here so that EXPLAIN works */
	queryScanState->custom_scanstate.custom_ps = list_make1(
		queryScanState->innerScanState);
}


static TupleTableSlot *
DistinctQueryScanExecCustomScan(CustomScanState *pstate)
{
	DistinctQueryScanState *node = (DistinctQueryScanState *) pstate;

	/*
	 * Call ExecScan with the next/recheck methods. This handles
	 * Post-processing for projections, custom filters etc.
	 */
	TupleTableSlot *returnSlot = ExecScan(&node->custom_scanstate.ss,
										  (ExecScanAccessMtd) DistinctQueryScanNext,
										  (ExecScanRecheckMtd)
										  DistinctQueryScanNextRecheck);

	return returnSlot;
}


static TupleTableSlot *
DistinctQueryScanNext(CustomScanState *node)
{
	DistinctQueryScanState *extensionScanState = (DistinctQueryScanState *) node;

	/* Fetch a tuple from the underlying scan */
	TupleTableSlot *slot = extensionScanState->innerScanState->ps.ExecProcNode(
		(PlanState *) extensionScanState->innerScanState);

	/* We're done scanning, so return NULL */
	if (TupIsNull(slot))
	{
		return slot;
	}

	/* we got a valid alive TID - skip all the other entries on this index entry */
	if (extensionScanState->scanDesc == NULL)
	{
		if (IsA(extensionScanState->innerScanState, IndexScanState))
		{
			IndexScanState *indexScanState =
				(IndexScanState *) extensionScanState->innerScanState;
			extensionScanState->scanDesc = indexScanState->iss_ScanDesc;
		}
		else if (IsA(extensionScanState->innerScanState, IndexOnlyScanState))
		{
			IndexOnlyScanState *indexOnlyScanState =
				(IndexOnlyScanState *) extensionScanState->innerScanState;
			extensionScanState->scanDesc = indexOnlyScanState->ioss_ScanDesc;
		}

		Relation indexRel = extensionScanState->scanDesc->indexRelation;
		extensionScanState->skipTidsFunc = GetSkipTidsOnCurrentEntryFunc(
			indexRel->rd_rel->relam, indexRel->rd_opfamily[0],
			&extensionScanState->isPathSummarizationForced);
	}

	ItemPointerData tid;
	BlockIdSet(&tid.ip_blkid, InvalidBlockNumber);
	tid.ip_posid = 0;
	DocumentDBRumSkipTidsForCurrentEntry(extensionScanState->scanDesc,
										 extensionScanState->skipTidsFunc,
										 extensionScanState->isPathSummarizationForced,
										 &tid);

	/* Copy the slot onto our own query state for projection */
	TupleTableSlot *ourSlot = node->ss.ss_ScanTupleSlot;
	return ExecCopySlot(ourSlot, slot);
}


static bool
DistinctQueryScanNextRecheck(ScanState *state, TupleTableSlot *slot)
{
	ereport(ERROR, (errmsg("Recheck is unexpected on Custom Scan")));
}


static void
DistinctQueryScanEndCustomScan(CustomScanState *node)
{
	DistinctQueryScanState *queryScanState = (DistinctQueryScanState *) node;
	ExecEndNode((PlanState *) queryScanState->innerScanState);
	ResetReportedIndexCosts();
}


static void
DistinctQueryScanReScanCustomScan(CustomScanState *node)
{
	DistinctQueryScanState *queryScanState = (DistinctQueryScanState *) node;

	/* reset any scanstate state here */
	ExecReScan((PlanState *) queryScanState->innerScanState);
}


static void
DistinctQueryScanExplainCustomScan(CustomScanState *node, List *ancestors,
								   ExplainState *es)
{ }


/*
 * Support for comparing two Scan extensible nodes
 * Currently insupported.
 */
static bool
EqualUnsupportedExtensionQueryScanNode(const struct ExtensibleNode *a,
									   const struct ExtensibleNode *b)
{
	ereport(ERROR, (errmsg("Equal for node type CustomQueryScan not implemented")));
}


/*
 * Support for Copying the InputQueryState node
 */
static void
CopyNodeInputQueryState(struct ExtensibleNode *target_node, const struct
						ExtensibleNode *source_node)
{
	DistinctInputQueryState *newNode = (DistinctInputQueryState *) target_node;
	newNode->extensible.type = T_ExtensibleNode;
	newNode->extensible.extnodename = InputContinuationNodeName;
}


/*
 * Support for Outputing the InputContinuation node
 */
static void
OutInputQueryScanNode(StringInfo str, const struct ExtensibleNode *raw_node)
{ }


/*
 * Function for reading DocumentDBApiQueryScan node
 */
static void
ReadDistinctExtensionQueryScanNode(struct ExtensibleNode *node)
{
	DistinctInputQueryState *local_node = (DistinctInputQueryState *) node;
	local_node->extensible.type = T_ExtensibleNode;
	local_node->extensible.extnodename = InputContinuationNodeName;
}
