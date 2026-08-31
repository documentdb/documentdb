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
#include "utils/feature_counter.h"
#include "utils/documentdb_errors.h"
#include "customscan/bson_custom_query_scan.h"
#include "index_am/index_am_utils.h"
#include "index_am/documentdb_rum.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "utils/query_utils.h"
#include "commands/commands_common.h"
#include "api_hooks_def.h"


/* --------------------------------------------------------- */
/* Data-types */
/* --------------------------------------------------------- */


typedef enum IndexSkipScanOnEntryStatus
{
	IndexSkipScanOnEntryStatus_Unknown = 0,
	IndexSkipScanOnEntryStatus_NoSkipScan = 1,
	IndexSkipScanOnEntryStatus_SkipScan = 2
} IndexSkipScanOnEntryStatus;


typedef struct GroupFirstAggrefContext
{
	List *orderBy;
} GroupFirstAggrefContext;


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

	/* IndexScanDesc for the current scan */
	IndexScanDesc scanDesc;

	IndexSkipScanOnEntryStatus skipScanOnEntryStatus;
} DistinctQueryScanState;

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

static TupleTableSlot * DistinctQueryScanNext(CustomScanState *node);
static bool DistinctQueryScanNextRecheck(ScanState *state, TupleTableSlot *slot);
static List * AddDistinctCustomPathCore(PlannerInfo *root, List *pathList,
										bool hasOrderedGroupFirst);
static OpExpr * CreateGroupKeyPathCountClause(IndexPath *indexPath,
											  int32_t numGroupByPathKeys);
static void InjectGroupKeyPathCountClause(Plan *nestedPlan, OpExpr *metadataExpr);
static bool ContainsDisqualifyingAggref(Node *node, void *context);
static bool IsSafeFirstAggregateFunctionOid(Oid aggregateFunctionOid);
static bool HasOnlySafeGroupFirstAggrefs(PlannerInfo *root,
										 bool *hasOrderBy);

extern bool EnableDistinctCustomScan;
extern bool EnableDistinctScanForGroupFirst;
extern bool EnableDistinctScanForOrderedGroupFirst;
extern bool EnableGroupByDistinctScan;
extern bool EnableDistinctSkipScanOnKey;

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


/*
 * Registers any custom nodes that the extension Scan produces.
 * This is for any items present in the custom_private field.
 */
void
RegisterDistinctScanNodes(void)
{
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
	bool hasOrderedGroupFirst = false;
	bool groupFirstScenario = EnableDistinctScanForGroupFirst &&
							  root->group_pathkeys != NIL &&
							  root->parse->havingQual == NULL &&
							  HasOnlySafeGroupFirstAggrefs(root,
														   &hasOrderedGroupFirst);
	if (groupFirstScenario && hasOrderedGroupFirst &&
		!EnableDistinctScanForOrderedGroupFirst)
	{
		ReportFeatureUsage(
			FEATURE_AGGREGATE_GROUP_ORDERED_FIRST_DISTINCT_SCAN_CANDIDATE);
		groupFirstScenario = false;
	}

	if (distinctScenario || groupScenario || groupFirstScenario)
	{
		rel->pathlist = AddDistinctCustomPathCore(root, rel->pathlist,
												  hasOrderedGroupFirst);
		rel->partial_pathlist = AddDistinctCustomPathCore(root,
														  rel->partial_pathlist,
														  hasOrderedGroupFirst);
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
AddDistinctCustomPathCore(PlannerInfo *root, List *pathList,
						  bool hasOrderedGroupFirst)
{
	List *customPlanPaths = NIL;
	ListCell *cell;

	foreach(cell, pathList)
	{
		Path *inputPath = lfirst(cell);
		if (inputPath->pathtype != T_IndexScan &&
			inputPath->pathtype != T_IndexOnlyScan)
		{
			/*
			 * TODO: Support MergeAppend and custom wrapper paths after distinct
			 * execution can safely identify and advance the active index child.
			 */
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
		}

		IndexPath *indexPath = (IndexPath *) inputPath;

		/*
		 * The number of index ORDER BYs must match the number of pathkeys we
		 * intend to deduplicate on. For DISTINCT that's distinct_pathkeys; for
		 * GROUP BY (with no aggregates) that's group_pathkeys.
		 */
		int targetPathKeyLength;
		if (hasOrderedGroupFirst)
		{
#if PG_VERSION_NUM >= 160000
			targetPathKeyLength = root->num_groupby_pathkeys;
#else
			targetPathKeyLength = list_length(root->group_pathkeys);
#endif
		}
		else
		{
			targetPathKeyLength = root->distinct_pathkeys != NIL ?
								  list_length(root->distinct_pathkeys) :
								  list_length(root->group_pathkeys);
		}

		if (hasOrderedGroupFirst)
		{
			/*
			 * Ordered $first is safe only when this path supplies the complete
			 * group-plus-accumulator ordering. PG15 does not expose the
			 * accumulator ordering through the index path.
			 */
#if PG_VERSION_NUM < 160000
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
#else
			if (root->query_pathkeys == NIL ||
				list_length(indexPath->indexorderbys) != list_length(
					root->query_pathkeys) ||
				!pathkeys_contained_in(root->query_pathkeys,
									   indexPath->path.pathkeys))
			{
				customPlanPaths = lappend(customPlanPaths, inputPath);
				continue;
			}
#endif
		}
		else if (list_length(indexPath->indexorderbys) != targetPathKeyLength)
		{
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
		}

		PGFunction skipTidsFunc = GetSkipTidsOnCurrentEntryFunc(
			indexPath->indexinfo->relam, indexPath->indexinfo->opfamily[0]);

		if (skipTidsFunc == NULL)
		{
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
		}

		/* wrap the path in a custom path */
		CustomPath *customPath = makeNode(CustomPath);
		customPath->methods = &DistinctQueryScanPathMethods;
		if (hasOrderedGroupFirst && EnableDistinctSkipScanOnKey)
		{
			OpExpr *metadataExpr = CreateGroupKeyPathCountClause(
				indexPath, targetPathKeyLength);
			if (metadataExpr != NULL)
			{
				customPath->custom_private = list_make1(metadataExpr);
			}
		}

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

		customPlanPaths = lappend(customPlanPaths, customPath);
	}

	return customPlanPaths;
}


static void
InjectGroupKeyPathCountClause(Plan *nestedPlan, OpExpr *metadataExpr)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	OpExpr *indexExpr = NULL;
	if (IsA(nestedPlan, IndexScan) || IsA(nestedPlan, IndexOnlyScan))
	{
		indexExpr = copyObject(metadataExpr);
		Var *indexVar = (Var *) linitial(indexExpr->args);
		indexVar->varno = INDEX_VAR;
		indexVar->varnosyn = INDEX_VAR;
		indexVar->varattno = 1;
		indexVar->varattnosyn = 1;
	}

	if (IsA(nestedPlan, IndexScan))
	{
		IndexScan *indexScan = (IndexScan *) nestedPlan;
		indexScan->indexqual = lcons(indexExpr, indexScan->indexqual);
		indexScan->indexqualorig = lcons(copyObject(metadataExpr),
										 indexScan->indexqualorig);
	}
	else if (IsA(nestedPlan, IndexOnlyScan))
	{
		IndexOnlyScan *indexOnlyScan = (IndexOnlyScan *) nestedPlan;
		indexOnlyScan->indexqual = lcons(indexExpr, indexOnlyScan->indexqual);
		indexOnlyScan->recheckqual = lcons(copyObject(metadataExpr),
										   indexOnlyScan->recheckqual);
	}
	else if (IsA(nestedPlan, CustomScan))
	{
		CustomScan *customScan = (CustomScan *) nestedPlan;
		if (customScan->custom_plans == NIL)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("distinct custom scan requires an index scan")));
		}

		ListCell *childCell;
		foreach(childCell, customScan->custom_plans)
		{
			Plan *childPlan = lfirst(childCell);
			InjectGroupKeyPathCountClause(childPlan, metadataExpr);
		}
	}
	else
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("distinct custom scan requires an index scan")));
	}
}


static OpExpr *
CreateGroupKeyPathCountClause(IndexPath *indexPath, int32_t numGroupByPathKeys)
{
	/*
	 * The logical group-key count is not necessarily the number of physical
	 * index paths to preserve. Equality-constrained paths may precede or sit
	 * between group keys, so resolve the last group key to its index position.
	 */
	if (numGroupByPathKeys <= 0 ||
		list_length(indexPath->indexorderbys) < numGroupByPathKeys)
	{
		return NULL;
	}

	OpExpr *lastGroupOrderBy = list_nth(indexPath->indexorderbys,
										numGroupByPathKeys - 1);
	if (!IsA(lastGroupOrderBy, OpExpr) ||
		list_length(lastGroupOrderBy->args) != 2 ||
		!IsA(lsecond(lastGroupOrderBy->args), Const))
	{
		return NULL;
	}

	Const *orderByConst = (Const *) lsecond(lastGroupOrderBy->args);
	if (orderByConst->constisnull)
	{
		return NULL;
	}

	pgbsonelement orderByElement;
	if (!TryGetSinglePgbsonElementFromPgbson(
			DatumGetPgBson(orderByConst->constvalue), &orderByElement))
	{
		return NULL;
	}

	int8_t sortDirectionIgnored = 0;
	int32_t lastGroupIndexPath = GetCompositeOpClassColumnNumber(
		orderByElement.path, indexPath->indexinfo->opclassoptions[0],
		&sortDirectionIgnored);
	if (lastGroupIndexPath < 0)
	{
		return NULL;
	}

	const char *firstPath = GetCompositeFirstIndexPath(
		indexPath->indexinfo->opclassoptions[0]);
	int varlevelsup = 0;
	Var *documentVar = makeVar(indexPath->path.parent->relid,
							   DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER,
							   BsonTypeId(), DOCUMENT_DATA_TABLE_DOCUMENT_VAR_TYPMOD,
							   DOCUMENT_DATA_TABLE_DOCUMENT_VAR_COLLATION, varlevelsup);
	return CreateGroupKeyPathCountOpExpr(
		(Expr *) documentVar, firstPath, strlen(firstPath),
		lastGroupIndexPath + 1);
}


/*
 * expression_tree_walker callback that returns true (aborting the walk) as
 * soon as it encounters an Aggref that is NOT safe to combine with
 * distinct-scan key skipping. An Aggref is considered safe when:
 *
 *   - aggfnoid is a supported $first variant, AND
 *   - it has no aggdistinct / aggfilter.
 *
 * An explicit aggorder is recorded for path-level validation. It is safe only
 * when the selected index path supplies the complete ordering.
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
		GroupFirstAggrefContext *aggrefContext =
			(GroupFirstAggrefContext *) context;

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

		if (aggref->aggdistinct != NIL || aggref->aggfilter != NULL)
		{
			/* DISTINCT or FILTER inside the accumulator changes semantics. */
			return true;
		}

		if (aggref->aggorder != NIL)
		{
			if (aggrefContext->orderBy == NIL)
			{
				aggrefContext->orderBy = aggref->aggorder;
			}
			else if (!equal(aggrefContext->orderBy, aggref->aggorder))
			{
				return true;
			}
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
		   aggregateFunctionOid == BsonFirstWithExprAggregateFunctionOid() ||
		   aggregateFunctionOid == BsonFirstWithExprInternalAggregateFunctionOid();
}


static bool
HasOnlySafeGroupFirstAggrefs(PlannerInfo *root, bool *hasOrderBy)
{
	ListCell *aggInfoCell;
	GroupFirstAggrefContext aggrefContext = { 0 };

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
			if (ContainsDisqualifyingAggref((Node *) aggref, &aggrefContext))
			{
				return false;
			}

			foundSafeAggref = true;
		}
#else
		Aggref *aggref = aggInfo->representative_aggref;
		if (aggref == NULL ||
			ContainsDisqualifyingAggref((Node *) aggref, &aggrefContext))
		{
			return false;
		}

		foundSafeAggref = true;
#endif
	}

	*hasOrderBy = aggrefContext.orderBy != NIL;
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

	/* Planner-only metadata is consumed when the nested index plan is built. */
	cscan->custom_private = NIL;
	cscan->custom_plans = custom_plans;

	/* Only one plan is allowed here */
	Assert(list_length(custom_plans) == 1);

	/* The main plan comes in first */
	Plan *nestedPlan = linitial(custom_plans);
	if (best_path->custom_private != NIL)
	{
		InjectGroupKeyPathCountClause(
			nestedPlan, (OpExpr *) linitial(best_path->custom_private));
	}

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


static void
TrySkipDistinctScanKey(DistinctQueryScanState *extensionScanState)
{
	/* Try once with skip scan if unknown */

	ItemPointerData tid;
	BlockIdSet(&tid.ip_blkid, InvalidBlockNumber);
	tid.ip_posid = 0;
	switch (extensionScanState->skipScanOnEntryStatus)
	{
		case IndexSkipScanOnEntryStatus_Unknown:
		{
			if (!EnableDistinctSkipScanOnKey)
			{
				/*
				 * Skip-scan-on-key disabled: advance with the per-TID skip and
				 * lock the status so we never re-attempt the skip scan.
				 */
				DocumentDBRumSkipTidsForCurrentEntry(
					extensionScanState->scanDesc,
					extensionScanState->skipTidsFunc, &tid);
				extensionScanState->skipScanOnEntryStatus =
					IndexSkipScanOnEntryStatus_NoSkipScan;
				break;
			}

			bool skipScan = DocumentDBRumSkipTidsForCurrentEntryWithSkipScan(
				extensionScanState->scanDesc, extensionScanState->skipTidsFunc,
				&tid);

			if (skipScan)
			{
				extensionScanState->skipScanOnEntryStatus =
					IndexSkipScanOnEntryStatus_SkipScan;
			}
			else
			{
				extensionScanState->skipScanOnEntryStatus =
					IndexSkipScanOnEntryStatus_NoSkipScan;
			}

			break;
		}

		case IndexSkipScanOnEntryStatus_SkipScan:
		{
			DocumentDBRumSkipTidsForCurrentEntryWithSkipScan(
				extensionScanState->scanDesc, extensionScanState->skipTidsFunc,
				&tid);
			break;
		}

		case IndexSkipScanOnEntryStatus_NoSkipScan:
		default:
		{
			DocumentDBRumSkipTidsForCurrentEntry(extensionScanState->scanDesc,
												 extensionScanState->skipTidsFunc,
												 &tid);
			break;
		}
	}
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
			indexRel->rd_rel->relam, indexRel->rd_opfamily[0]);
	}

	TrySkipDistinctScanKey(extensionScanState);

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
