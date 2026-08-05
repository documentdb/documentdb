/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/customscan/custom_rum_index_only_scan.c
 *
 * Base Implementation and Definitions for a custom scan that wraps a RUM
 * index-only scan. This is a pass-through scan node that sits directly on top
 * of a bson (RUM) index-only scan so that additional per-scan processing can be
 * layered on the RUM index-only path in the future.
 *
 * The wrapper is gated behind a feature flag and is injected in the
 * set_rel_pathlist hook. It mirrors the structure of the Explain custom scan:
 * it wraps a single inner path, propagates its cost / pathkeys / projection,
 * and streams the inner tuples through unchanged.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <fmgr.h>
#include <utils/lsyscache.h>
#include <nodes/extensible.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <optimizer/pathnode.h>
#include <optimizer/optimizer.h>
#include <parser/parse_relation.h>
#include <utils/rel.h>
#include <access/detoast.h>
#include <miscadmin.h>
#include <optimizer/paths.h>
#include <access/relscan.h>
#include <optimizer/tlist.h>
#include <customscan/bson_custom_scan_private.h>

#if PG_VERSION_NUM >= 180000
#include <commands/explain_format.h>
#endif

#include "io/bson_core.h"
#include "planner/documentdb_planner.h"
#include "customscan/custom_scan_registrations.h"
#include "customscan/bson_custom_query_scan.h"
#include "index_am/index_am_utils.h"
#include "metadata/metadata_cache.h"
#include "metadata/collection.h"
#include "utils/docdb_make_funcs.h"
#include "opclass/bson_gin_index_mgmt.h"
#include <parser/parsetree.h>


/* --------------------------------------------------------- */
/* Data-types */
/* --------------------------------------------------------- */


/*
 * The input state stored on the custom path / custom scan. Anything stored here
 * must be an ExtensibleNode registered with RegisterRumIndexOnlyScanNodes.
 */
typedef struct RumIndexOnlyInputState
{
	/* Must be the first field */
	ExtensibleNode extensible;

	/* Oid of the base relation being scanned. */
	Oid relOid;

	/* Oid of the RUM index that the wrapped index-only scan reads. */
	Oid indexOid;
} RumIndexOnlyInputState;


/*
 * The custom Scan State for the RUM index-only scan wrapper.
 */
typedef struct RumIndexOnlyScanState
{
	/* must be first field */
	CustomScanState custom_scanstate;

	/* The execution state of the inner path */
	ScanState *innerScanState;

	/* The planning state of the inner path */
	Plan *innerPlan;

	RumIndexOnlyInputState *inputState;
} RumIndexOnlyScanState;

/* Name needed for Postgres to register the extensible input node */
#define RumIndexOnlyInputNodeName "DocumentsRumIndexOnlyScanInput"

/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */
static Plan * RumIndexOnlyScanPlanCustomPath(PlannerInfo *root,
											 RelOptInfo *rel,
											 struct CustomPath *best_path,
											 List *tlist,
											 List *clauses,
											 List *custom_plans);
static Node * RumIndexOnlyScanCreateCustomScanState(CustomScan *cscan);
static void RumIndexOnlyScanBeginCustomScan(CustomScanState *node, EState *estate,
											int eflags);
static TupleTableSlot * RumIndexOnlyScanExecCustomScan(CustomScanState *node);
static void RumIndexOnlyScanEndCustomScan(CustomScanState *node);
static void RumIndexOnlyScanReScanCustomScan(CustomScanState *node);
static void RumIndexOnlyScanExplainCustomScan(CustomScanState *node, List *ancestors,
											  ExplainState *es);

static void CopyNodeRumIndexOnlyInputState(ExtensibleNode *target_node, const
										   ExtensibleNode *source_node);
static void OutRumIndexOnlyInputNode(StringInfo str, const struct
									 ExtensibleNode *raw_node);
static void ReadUnsupportedRumIndexOnlyInputNode(struct ExtensibleNode *node);
static bool EqualUnsupportedRumIndexOnlyInputNode(const struct ExtensibleNode *a,
												  const struct ExtensibleNode *b);
static TupleTableSlot * RumIndexOnlyScanNext(CustomScanState *node);
static bool RumIndexOnlyScanNextRecheck(ScanState *state, TupleTableSlot *slot);
static List * AddRumIndexOnlyCustomPathCore(List *pathList, Oid relOid);

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

/* Declaration of extensibility paths for query processing (See extensible.h) */
static const struct CustomPathMethods RumIndexOnlyScanPathMethods = {
	.CustomName = "DocumentDBApiRumIndexOnlyScan",
	.PlanCustomPath = RumIndexOnlyScanPlanCustomPath,
};

static const struct CustomScanMethods RumIndexOnlyScanMethods = {
	.CustomName = "DocumentDBApiRumIndexOnlyScan",
	.CreateCustomScanState = RumIndexOnlyScanCreateCustomScanState
};

static const struct CustomExecMethods RumIndexOnlyScanExecuteMethods = {
	.CustomName = "DocumentDBApiRumIndexOnlyScan",
	.BeginCustomScan = RumIndexOnlyScanBeginCustomScan,
	.ExecCustomScan = RumIndexOnlyScanExecCustomScan,
	.EndCustomScan = RumIndexOnlyScanEndCustomScan,
	.ReScanCustomScan = RumIndexOnlyScanReScanCustomScan,
	.ExplainCustomScan = RumIndexOnlyScanExplainCustomScan,
};


static const ExtensibleNodeMethods RumIndexOnlyInputStateMethods =
{
	RumIndexOnlyInputNodeName,
	sizeof(RumIndexOnlyInputState),
	CopyNodeRumIndexOnlyInputState,
	EqualUnsupportedRumIndexOnlyInputNode,
	OutRumIndexOnlyInputNode,
	ReadUnsupportedRumIndexOnlyInputNode
};


/*
 * Registers any custom nodes that the RUM index-only scan produces.
 * This is for any items present in the custom_private field.
 */
void
RegisterRumIndexOnlyScanNodes(void)
{
	RegisterExtensibleNodeMethods(&RumIndexOnlyInputStateMethods);
	RegisterCustomScanMethods(&RumIndexOnlyScanMethods);
}


/*
 * Wraps any eligible RUM index-only scan path on the relation with the custom
 * scan wrapper. Gated by EnableRumIndexOnlyScanProjectionWrapper at the call
 * site.
 */
void
AddRumIndexOnlyScanCustomScanWrapper(PlannerInfo *root, RelOptInfo *rel,
									 RangeTblEntry *rte)
{
	rel->pathlist = AddRumIndexOnlyCustomPathCore(rel->pathlist, rte->relid);
	rel->partial_pathlist = AddRumIndexOnlyCustomPathCore(rel->partial_pathlist,
														  rte->relid);
}


/* --------------------------------------------------------- */
/* Helper methods */
/* --------------------------------------------------------- */


/*
 * Returns the index Oid if inputPath is a RUM (bson regular) index-only scan
 * that this wrapper can wrap; otherwise returns InvalidOid.
 */
static Oid
GetWrappableRumIndexOnlyScan(Path *inputPath)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	if (inputPath->param_info != NULL)
	{
		return InvalidOid;
	}

	/* Only wrap index-only scans, and only over a bson (RUM) index AM. */
	if (inputPath->pathtype != T_IndexOnlyScan || !IsA(inputPath, IndexPath))
	{
		return InvalidOid;
	}

	IndexPath *indexPath = (IndexPath *) inputPath;
	if (indexPath->indexinfo == NULL ||
		!IsBsonRegularIndexAm(indexPath->indexinfo->relam))
	{
		return InvalidOid;
	}

	return indexPath->indexinfo->indexoid;
}


/*
 * Helper method that walks all paths in the rel's pathlist and adds a custom
 * path wrapper around every eligible RUM index-only scan path.
 */
static List *
AddRumIndexOnlyCustomPathCore(List *pathList, Oid relOid)
{
	List *customPlanPaths = NIL;
	ListCell *cell;

	foreach(cell, pathList)
	{
		Path *inputPath = lfirst(cell);
		Oid indexOid = GetWrappableRumIndexOnlyScan(inputPath);
		if (!OidIsValid(indexOid))
		{
			customPlanPaths = lappend(customPlanPaths, inputPath);
			continue;
		}

		/* wrap the path in a custom path */
		CustomPath *customPath = makeNode(CustomPath);
		customPath->methods = &RumIndexOnlyScanPathMethods;

		RumIndexOnlyInputState *inputState = palloc0(sizeof(RumIndexOnlyInputState));

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
		path->parallel_aware = inputPath->parallel_aware;
		path->parallel_workers = inputPath->parallel_workers;

		/* move the 'projection' from the path to the custom path. */
		path->pathtarget = inputPath->pathtarget;

		/* Copy the param paths */
		path->param_info = inputPath->param_info;

		customPath->custom_paths = list_make1(inputPath);
		customPath->path.pathkeys = inputPath->pathkeys;

#if (PG_VERSION_NUM >= 150000)

		/* necessary to avoid extra Result node in PG15 */
		customPath->flags = CUSTOMPATH_SUPPORT_PROJECTION;
#endif

		/* Save the input state into storage */
		inputState->extensible.type = T_ExtensibleNode;
		inputState->extensible.extnodename = RumIndexOnlyInputNodeName;
		inputState->relOid = relOid;
		inputState->indexOid = indexOid;

		/* Store the input state to be used later.
		 * NOTE: Anything added here must be of type ExtensibleNode and must be
		 * registered with the RegisterRumIndexOnlyScanNodes method above.
		 */
		customPath->custom_private = list_make1(inputState);
		customPlanPaths = lappend(customPlanPaths, customPath);
	}

	return customPlanPaths;
}


/*
 * Walker context for detecting whether a target list references the
 * reconstructed document column, either directly (a base-relation Var on the
 * document attribute) or indirectly through an index-only scan's index target
 * list (an INDEX_VAR that maps back to the document expression).
 */
typedef struct DocumentReferenceContext
{
	/* Index target list of the wrapped index-only scan (indextlist). */
	List *indexTargetList;

	/* Set when a document reference is found. */
	bool referencesDocument;
} DocumentReferenceContext;


/*
 * Returns true (stopping the walk) when node references the document column.
 * INDEX_VAR references are resolved through the index target list so that an
 * index-only scan projecting the reconstructed document is detected.
 */
static bool
DocumentReferenceWalker(Node *node, DocumentReferenceContext *context)
{
	if (node == NULL)
	{
		return false;
	}

	if (IsA(node, Var))
	{
		Var *var = (Var *) node;
		if (var->varno == INDEX_VAR)
		{
			TargetEntry *entry = get_tle_by_resno(context->indexTargetList,
												  var->varattno);
			if (entry != NULL)
			{
				return DocumentReferenceWalker((Node *) entry->expr, context);
			}

			return false;
		}

		if (var->varattno == DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER)
		{
			context->referencesDocument = true;
			return true;
		}

		return false;
	}

	return expression_tree_walker(node, DocumentReferenceWalker, context);
}


/*
 * Returns true when targetList references the reconstructed document column.
 */
static bool
TargetListReferencesDocument(List *targetList, List *indexTargetList)
{
	DocumentReferenceContext context = {
		.indexTargetList = indexTargetList,
		.referencesDocument = false,
	};

	expression_tree_walker((Node *) targetList, DocumentReferenceWalker, &context);
	return context.referencesDocument;
}


/*
 * When the wrapped plan is a bson (RUM) index-only scan that needs no residual
 * scan quals and whose projection never references the reconstructed document,
 * the index does not have to rebuild the document for each row. We convey this
 * to the composite index by injecting an index clause carrying index projection
 * metadata: a $range marker whose int64 payload of -1 requests raw index-tuple
 * projection. The clause is skipped as a scan bound and only toggles the index's
 * projection behavior.
 */
static void
TryInjectIndexProjectionMetadata(IndexOnlyScan *indexOnlyScan, CustomPath *best_path)
{
	if (indexOnlyScan->scan.plan.qual != NIL)
	{
		/*
		 * A residual filter (scan qual) is evaluated at runtime against the
		 * reconstructed document, so the index must keep rebuilding it. For
		 * example a covered scan whose bounds come from multi-key $in predicates
		 * but that carries a residual $or of composite equalities lands the $or
		 * in the scan's Filter; projecting the raw index tuple would starve that
		 * filter of the document it needs. (The composite index's own lossy
		 * recheck qual is not a disqualifier -- it is present on ordinary covered
		 * scans and is satisfied from index terms.)
		 */
		return;
	}

	if (TargetListReferencesDocument(indexOnlyScan->scan.plan.targetlist,
									 indexOnlyScan->indextlist))
	{
		return;
	}

	/*
	 * The inner index path is retained on the custom path; use it to resolve the
	 * leading indexed path, which names the (otherwise ignored) marker field.
	 */
	IndexPath *innerIndexPath = (IndexPath *) linitial(best_path->custom_paths);

	/*
	 * Anchor the marker on the same index-column operand already used by the
	 * existing index clauses (an INDEX_VAR Var). If there is no such operand we
	 * have nothing to clone and skip the optimization.
	 */
	Var *indexColumnVar = NULL;
	ListCell *cell;
	foreach(cell, indexOnlyScan->indexqual)
	{
		Node *clause = lfirst(cell);
		if (IsA(clause, OpExpr))
		{
			OpExpr *opExpr = (OpExpr *) clause;
			if (list_length(opExpr->args) >= 1 &&
				IsA(linitial(opExpr->args), Var) &&
				((Var *) linitial(opExpr->args))->varno == INDEX_VAR)
			{
				indexColumnVar = (Var *) linitial(opExpr->args);
				break;
			}
		}
	}

	if (indexColumnVar == NULL)
	{
		return;
	}

	if (innerIndexPath->indexinfo == NULL ||
		innerIndexPath->indexinfo->opclassoptions == NULL ||
		innerIndexPath->indexinfo->opclassoptions[0] == NULL)
	{
		return;
	}

	const char *firstPath =
		GetCompositeFirstIndexPath(innerIndexPath->indexinfo->opclassoptions[0]);
	if (firstPath == NULL)
	{
		return;
	}

	pgbson_writer writer;
	pgbson_writer childWriter;
	PgbsonWriterInit(&writer);
	PgbsonWriterStartDocument(&writer, firstPath, strlen(firstPath), &childWriter);

	/*
	 * A negative payload (-1) instructs the composite index to project the raw
	 * index tuple as-is instead of reconstructing the document for each row. The
	 * value is read back on the consume side, which enables raw-tuple projection
	 * when the metadata int64 is negative.
	 */
	PgbsonWriterAppendInt64(&childWriter, "indexProjectionMetadata", 23, -1);
	PgbsonWriterEndDocument(&writer, &childWriter);
	pgbson *metadataSpec = PgbsonWriterGetPgbson(&writer);

	bool opRetSet = false;
	OpExpr *rangeExpr = (OpExpr *) make_opclause(BsonRangeMatchOperatorOid(), BOOLOID,
												 opRetSet,
												 (Expr *) copyObject(indexColumnVar),
												 (Expr *) MakeBsonConst(metadataSpec),
												 InvalidOid, InvalidOid);
	rangeExpr->opfuncid = BsonRangeMatchFunctionId();

	indexOnlyScan->indexqual = lappend(indexOnlyScan->indexqual, rangeExpr);
}


/*
 * Given a scan path for the RUM index-only wrapper, generates a Custom Plan for
 * the path. Note that the inner path is already planned since it is listed as
 * an inner path in the custom path above.
 */
static Plan *
RumIndexOnlyScanPlanCustomPath(PlannerInfo *root,
							   RelOptInfo *rel,
							   struct CustomPath *best_path,
							   List *tlist,
							   List *clauses,
							   List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);

	/* Initialize and copy necessary data */
	cscan->methods = &RumIndexOnlyScanMethods;

	/* The first item is the input state - we propagate it forward */
	cscan->custom_private = best_path->custom_private;
	cscan->custom_plans = custom_plans;

	/* Only one plan is allowed here */
	Assert(list_length(custom_plans) == 1);

	/* The main plan comes in first */
	Plan *nestedPlan = linitial(custom_plans);

	/*
	 * If the wrapped plan is an eligible bson index-only scan, inject index
	 * projection metadata so the index can skip document reconstruction.
	 */
	if (IsA(nestedPlan, IndexOnlyScan))
	{
		TryInjectIndexProjectionMetadata((IndexOnlyScan *) nestedPlan, best_path);
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

#if (PG_VERSION_NUM >= 150000)

	/* necessary to avoid extra Result node in PG15 */
	cscan->flags = CUSTOMPATH_SUPPORT_PROJECTION;
#endif

	return (Plan *) cscan;
}


/*
 * Given a custom scan generated during the plan phase creates a Custom
 * ScanState that is used during the execution of the plan. This is called at
 * the beginning of query execution by the executor.
 */
static Node *
RumIndexOnlyScanCreateCustomScanState(CustomScan *cscan)
{
	RumIndexOnlyScanState *scanState = (RumIndexOnlyScanState *) newNode(
		sizeof(RumIndexOnlyScanState), T_CustomScanState);

	CustomScanState *cscanstate = &scanState->custom_scanstate;
	cscanstate->methods = &RumIndexOnlyScanExecuteMethods;
	cscanstate->custom_ps = NIL;

	/* Here we don't store the custom plan inside the custom_ps of the custom
	 * scan state yet. This is done as part of BeginCustomScan */
	Plan *innerPlan = (Plan *) linitial(cscan->custom_plans);
	scanState->innerPlan = innerPlan;

	scanState->inputState = (RumIndexOnlyInputState *) linitial(
		cscan->custom_private);
	return (Node *) cscanstate;
}


static void
RumIndexOnlyScanBeginCustomScan(CustomScanState *node, EState *estate,
								int eflags)
{
	/* Initialize the current state of the plan */
	RumIndexOnlyScanState *scanState = (RumIndexOnlyScanState *) node;

	scanState->innerScanState = (ScanState *) ExecInitNode(
		scanState->innerPlan, estate, eflags);

	/* Store the inner state here so that EXPLAIN works */
	scanState->custom_scanstate.custom_ps = list_make1(
		scanState->innerScanState);
}


static TupleTableSlot *
RumIndexOnlyScanExecCustomScan(CustomScanState *pstate)
{
	RumIndexOnlyScanState *node = (RumIndexOnlyScanState *) pstate;

	/*
	 * Call ExecScan with the next/recheck methods. This handles
	 * post-processing for projections, custom filters etc.
	 */
	TupleTableSlot *returnSlot = ExecScan(&node->custom_scanstate.ss,
										  (ExecScanAccessMtd) RumIndexOnlyScanNext,
										  (ExecScanRecheckMtd)
										  RumIndexOnlyScanNextRecheck);

	return returnSlot;
}


static TupleTableSlot *
RumIndexOnlyScanNext(CustomScanState *node)
{
	RumIndexOnlyScanState *scanState = (RumIndexOnlyScanState *) node;

	/* Fetch a tuple from the underlying scan */
	TupleTableSlot *slot = scanState->innerScanState->ps.ExecProcNode(
		(PlanState *) scanState->innerScanState);

	/* We're done scanning, so return NULL */
	if (TupIsNull(slot))
	{
		return slot;
	}

	/* Copy the slot onto our own scan state for projection */
	TupleTableSlot *ourSlot = node->ss.ss_ScanTupleSlot;
	return ExecCopySlot(ourSlot, slot);
}


static bool
RumIndexOnlyScanNextRecheck(ScanState *state, TupleTableSlot *slot)
{
	ereport(ERROR, (errmsg("Recheck is unexpected on RUM index-only Custom Scan")));
}


static void
RumIndexOnlyScanEndCustomScan(CustomScanState *node)
{
	RumIndexOnlyScanState *scanState = (RumIndexOnlyScanState *) node;
	ExecEndNode((PlanState *) scanState->innerScanState);
}


static void
RumIndexOnlyScanReScanCustomScan(CustomScanState *node)
{
	RumIndexOnlyScanState *scanState = (RumIndexOnlyScanState *) node;

	/* reset any scanstate state here */
	ExecReScan((PlanState *) scanState->innerScanState);
}


static void
RumIndexOnlyScanExplainCustomScan(CustomScanState *node, List *ancestors,
								  ExplainState *es)
{
	/* Add any scan related information here. The inner index-only scan is
	 * exposed via custom_ps so PostgreSQL explains it as the child node. */
}


/*
 * Support for comparing two input extensible nodes. Currently unsupported.
 */
static bool
EqualUnsupportedRumIndexOnlyInputNode(const struct ExtensibleNode *a,
									  const struct ExtensibleNode *b)
{
	ereport(ERROR, (errmsg(
						"Equal for node type RumIndexOnlyScan not implemented")));
}


/*
 * Support for Copying the RumIndexOnlyInputState node
 */
static void
CopyNodeRumIndexOnlyInputState(struct ExtensibleNode *target_node, const struct
							   ExtensibleNode *source_node)
{
	RumIndexOnlyInputState *newNode = (RumIndexOnlyInputState *) target_node;
	RumIndexOnlyInputState *from = (RumIndexOnlyInputState *) source_node;
	newNode->extensible.type = T_ExtensibleNode;
	newNode->extensible.extnodename = RumIndexOnlyInputNodeName;
	newNode->relOid = from->relOid;
	newNode->indexOid = from->indexOid;
}


/*
 * Support for Outputting the RumIndexOnlyInputState node
 */
static void
OutRumIndexOnlyInputNode(StringInfo str, const struct ExtensibleNode *raw_node)
{
	RumIndexOnlyInputState *node = (RumIndexOnlyInputState *) raw_node;
	WRITE_OID_FIELD(relOid);
	WRITE_OID_FIELD(indexOid);
}


/*
 * Function for reading the RumIndexOnlyInputState node.
 */
static void
ReadUnsupportedRumIndexOnlyInputNode(struct ExtensibleNode *node)
{
	const char *token;
	int length;
	RumIndexOnlyInputState *local_node = (RumIndexOnlyInputState *) node;
	local_node->extensible.type = T_ExtensibleNode;
	local_node->extensible.extnodename = RumIndexOnlyInputNodeName;
	READ_OID_FIELD(relOid);
	READ_OID_FIELD(indexOid);
}
