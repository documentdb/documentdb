/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/customscan/bson_tid_dedup_scan.c
 *
 * CustomScan that de-duplicates its child's output by heap TID while preserving
 * the child's row order. It exists to make a sort-merge (MergeAppend) over a
 * multi-key index correct: when the merged branches are per-value / per-branch
 * ordered scans of the same relation, a single document can satisfy more than
 * one branch and would otherwise be emitted once per branch. A MergeAppend has
 * no cross-child de-duplication, so this scan sits directly on top of it and
 * drops any row whose heap TID it has already seen.
 *
 * Correctness of ordering: every duplicate of a document shares the same value
 * on the merge (sort) key, so all of its copies are adjacent in the merged
 * stream and land at the document's correct sort position; keeping the first
 * occurrence and dropping the rest preserves the requested order. A LIMIT above
 * the scan therefore still short-circuits (it reads only a few extra dropped
 * rows).
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <access/sysattr.h>
#include <catalog/pg_type.h>
#include <nodes/extensible.h>
#include <nodes/makefuncs.h>
#include <nodes/pathnodes.h>
#include <optimizer/optimizer.h>
#include <optimizer/pathnode.h>
#include <optimizer/tlist.h>
#include <executor/executor.h>
#include <commands/explain.h>
#include <storage/itemptr.h>
#include <utils/memutils.h>
#include <miscadmin.h>

#if PG_VERSION_NUM >= 180000
#include <commands/explain_format.h>
#endif

#include "customscan/bson_tid_dedup_scan.h"
#include "customscan/custom_scan_registrations.h"
#include "utils/roaring_bitmap_utils.h"


/* --------------------------------------------------------- */
/* Forward declarations */
/* --------------------------------------------------------- */

static Plan * TidDedupPlanCustomPath(PlannerInfo *root, RelOptInfo *rel,
									 struct CustomPath *best_path, List *tlist,
									 List *clauses, List *custom_plans);
static Node * TidDedupCreateScanState(CustomScan *cscan);
static void TidDedupBeginScan(CustomScanState *node, EState *estate, int eflags);
static TupleTableSlot * TidDedupExecScan(CustomScanState *node);
static TupleTableSlot * TidDedupNext(CustomScanState *node);
static bool TidDedupRecheck(CustomScanState *node, TupleTableSlot *slot);
static void TidDedupEndScan(CustomScanState *node);
static void TidDedupReScan(CustomScanState *node);
static void TidDedupCleanupCallback(void *arg);
static void TidDedupExplain(CustomScanState *node, List *ancestors,
							ExplainState *es);
static void AddCtidToPathTargets(Path *path, Index scanRelId);


/* --------------------------------------------------------- */
/* Types */
/* --------------------------------------------------------- */

typedef struct TidDedupScanState
{
	CustomScanState csstate;

	PlanState *childPlanState;

	RoaringTidDedupState *seenTids;

	AttrNumber ctidAttno;

	/* EXPLAIN ANALYZE: number of duplicate rows dropped. */
	int64 numDuplicatesDropped;

	/*
	 * Frees the roaring bitmap if the scan is torn down without EndScan being
	 * called (e.g. an error/cancellation aborts execution).
	 */
	MemoryContextCallback cleanupCallback;
} TidDedupScanState;


/* --------------------------------------------------------- */
/* Method tables */
/* --------------------------------------------------------- */

static const struct CustomPathMethods TidDedupPathMethods = {
	.CustomName = "DocumentDBApiTidDedup",
	.PlanCustomPath = TidDedupPlanCustomPath,
};

static const struct CustomScanMethods TidDedupScanMethods = {
	.CustomName = "DocumentDBApiTidDedup",
	.CreateCustomScanState = TidDedupCreateScanState,
};

static const struct CustomExecMethods TidDedupExecMethods = {
	.CustomName = "DocumentDBApiTidDedup",
	.BeginCustomScan = TidDedupBeginScan,
	.ExecCustomScan = TidDedupExecScan,
	.EndCustomScan = TidDedupEndScan,
	.ReScanCustomScan = TidDedupReScan,
	.ExplainCustomScan = TidDedupExplain,
};


/* --------------------------------------------------------- */
/* Registration */
/* --------------------------------------------------------- */

void
RegisterTidDedupScanNodes(void)
{
	RegisterCustomScanMethods(&TidDedupScanMethods);
}


static void
AddCtidToPathTargets(Path *path, Index scanRelId)
{
	Var *ctidVar = makeVar(scanRelId, SelfItemPointerAttributeNumber, TIDOID,
						   -1, InvalidOid, 0);

	path->pathtarget = copy_pathtarget(path->pathtarget);
	add_column_to_pathtarget(path->pathtarget, (Expr *) ctidVar, 0);

	if (IsA(path, MergeAppendPath))
	{
		ListCell *cell;
		foreach(cell, ((MergeAppendPath *) path)->subpaths)
		{
			AddCtidToPathTargets((Path *) lfirst(cell), scanRelId);
		}
	}
}


Path *
WrapPathWithTidDedup(Path *subpath)
{
	PathTarget *outputTarget = subpath->pathtarget;
	AddCtidToPathTargets(subpath, subpath->parent->relid);

	CustomPath *cpath = makeNode(CustomPath);
	cpath->methods = &TidDedupPathMethods;
	cpath->path.pathtype = T_CustomScan;
	cpath->path.parent = subpath->parent;
	cpath->path.param_info = subpath->param_info;
	cpath->path.rows = subpath->rows;
	cpath->path.startup_cost = subpath->startup_cost;

	/*
	 * Charge one operator cost per row for the heap-TID bitmap probe.
	 * Rows are left at the child's estimate (an upper bound: at most every row
	 * survives) because the cross-child duplicate rate is not known here.
	 */
	cpath->path.total_cost = subpath->total_cost +
							 cpu_operator_cost * subpath->rows;
	cpath->path.parallel_safe = false;
	cpath->path.pathtarget = outputTarget;
	cpath->path.pathkeys = subpath->pathkeys;
	cpath->custom_paths = list_make1(subpath);
	cpath->custom_private = NIL;
	cpath->flags = CUSTOMPATH_SUPPORT_PROJECTION;

	return (Path *) cpath;
}


static Plan *
TidDedupPlanCustomPath(PlannerInfo *root, RelOptInfo *rel,
					   struct CustomPath *best_path, List *tlist, List *clauses,
					   List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);
	cscan->methods = &TidDedupScanMethods;

	cscan->flags = CUSTOMPATH_SUPPORT_PROJECTION;
	cscan->custom_plans = custom_plans;

	Assert(list_length(custom_plans) == 1);
	Plan *childPlan = linitial(custom_plans);

	/*
	 * custom_scan_tlist is the input tuple shape (the child's output, which
	 * includes the surfaced ctid we de-dup on); scan.plan.targetlist is our
	 * output to the parent (the original columns, with ctid projected away).
	 */
	cscan->custom_scan_tlist = childPlan->targetlist;
	cscan->scan.plan.targetlist = tlist;
	cscan->scan.plan.qual = NIL;

	return (Plan *) cscan;
}


static Node *
TidDedupCreateScanState(CustomScan *cscan)
{
	TidDedupScanState *state = (TidDedupScanState *)
							   newNode(sizeof(TidDedupScanState), T_CustomScanState);

	state->csstate.methods = &TidDedupExecMethods;
	state->childPlanState = NULL;
	state->seenTids = NULL;
	state->ctidAttno = 0;
	state->numDuplicatesDropped = 0;

	return (Node *) state;
}


static void
TidDedupBeginScan(CustomScanState *node, EState *estate, int eflags)
{
	TidDedupScanState *state = (TidDedupScanState *) node;
	CustomScan *cscan = (CustomScan *) node->ss.ps.plan;

	Plan *childPlan = linitial(cscan->custom_plans);
	state->childPlanState = ExecInitNode(childPlan, estate, eflags);

	/* Expose the child for EXPLAIN. */
	node->custom_ps = list_make1(state->childPlanState);

	/*
	 * Locate the ctid column surfaced onto the child target (see
	 * AddCtidToPathTargets). It is the only TID-typed column in the child tuple.
	 * setrefs.c rewrites the Var's varno/varattno to reference the child, so we
	 * match on the (stable) TID type rather than the attribute number.
	 */
	state->ctidAttno = 0;
	ListCell *cell;
	foreach(cell, cscan->custom_scan_tlist)
	{
		TargetEntry *tle = (TargetEntry *) lfirst(cell);
		if (IsA(tle->expr, Var) && ((Var *) tle->expr)->vartype == TIDOID)
		{
			state->ctidAttno = tle->resno;
			break;
		}
	}

	if (state->ctidAttno == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR),
						errmsg(
							"TID de-dup scan could not locate the ctid column in its input")));
	}

	/*
	 * Allocate the de-dup set in the per-query context (a stable, executor-lived
	 * context) rather than whatever context happens to be current, and register
	 * a reset callback so the roaring bitmap -- which lives outside PostgreSQL's
	 * memory contexts -- is freed even if execution is aborted before EndScan.
	 */
	MemoryContext oldContext = MemoryContextSwitchTo(estate->es_query_cxt);
	state->seenTids = CreateRoaringTidDedup();
	MemoryContextSwitchTo(oldContext);

	state->numDuplicatesDropped = 0;

	state->cleanupCallback.func = TidDedupCleanupCallback;
	state->cleanupCallback.arg = state;
	MemoryContextRegisterResetCallback(estate->es_query_cxt,
									   &state->cleanupCallback);
}


static TupleTableSlot *
TidDedupExecScan(CustomScanState *node)
{
	/* ExecScan handles the projection (ps_ProjInfo) from ss_ScanTupleSlot. */
	return ExecScan(&node->ss,
					(ExecScanAccessMtd) TidDedupNext,
					(ExecScanRecheckMtd) TidDedupRecheck);
}


/*
 * Pull rows from the child until one with a not-yet-seen heap TID is found (or
 * the child is exhausted). Duplicates -- rows whose TID was already emitted --
 * are dropped.
 */
static TupleTableSlot *
TidDedupNext(CustomScanState *node)
{
	TidDedupScanState *state = (TidDedupScanState *) node;

	for (;;)
	{
		CHECK_FOR_INTERRUPTS();

		TupleTableSlot *slot = ExecProcNode(state->childPlanState);
		if (TupIsNull(slot))
		{
			return slot;
		}

		/*
		 * Read the heap ctid surfaced as a real column on the child target (see
		 * AddCtidToPathTargets). It uniquely identifies the document; the same
		 * document reached through two branches shares one ctid and is
		 * de-duplicated here. A NULL ctid (should not happen for a heap scan) is
		 * passed through rather than dropping data.
		 */
		bool isNull = false;
		Datum ctidDatum = slot_getattr(slot, state->ctidAttno, &isNull);
		if (!isNull)
		{
			ItemPointer tid = (ItemPointer) DatumGetPointer(ctidDatum);
			if (ItemPointerIsValid(tid) &&
				!RoaringTidDedupAddChecked(state->seenTids, tid))
			{
				state->numDuplicatesDropped++;
				continue;
			}
		}

		TupleTableSlot *scanSlot = node->ss.ss_ScanTupleSlot;
		return ExecCopySlot(scanSlot, slot);
	}
}


static bool
TidDedupRecheck(CustomScanState *node, TupleTableSlot *slot)
{
	/* No lossy access method here; the child already applied all quals. */
	return true;
}


static void
TidDedupEndScan(CustomScanState *node)
{
	TidDedupScanState *state = (TidDedupScanState *) node;

	FreeRoaringTidDedup(state->seenTids);
	state->seenTids = NULL;

	if (state->childPlanState != NULL)
	{
		ExecEndNode(state->childPlanState);
		state->childPlanState = NULL;
	}
}


static void
TidDedupReScan(CustomScanState *node)
{
	TidDedupScanState *state = (TidDedupScanState *) node;

	/*
	 * Restart de-duplication from an empty set for the new scan, keeping the set
	 * in the per-query context so the reset callback (registered in BeginScan)
	 * continues to reference a stable, executor-lived allocation. NULL the
	 * pointer between the free and the re-create so that if CreateRoaringTidDedup
	 * throws (e.g. OOM), the reset callback sees NULL and does not free the
	 * already-freed set.
	 */
	FreeRoaringTidDedup(state->seenTids);
	state->seenTids = NULL;
	MemoryContext oldContext =
		MemoryContextSwitchTo(node->ss.ps.state->es_query_cxt);
	state->seenTids = CreateRoaringTidDedup();
	MemoryContextSwitchTo(oldContext);

	/*
	 * numDuplicatesDropped is intentionally NOT reset here: it accumulates
	 * across rescans and is reported as a per-loop average in TidDedupExplain,
	 * matching core PostgreSQL's per-node counter convention.
	 */

	if (state->childPlanState != NULL)
	{
		ExecReScan(state->childPlanState);
	}
}


/*
 * Reset callback registered on the per-query context. Frees the roaring bitmap
 * if it is still live -- i.e. when execution was aborted before EndScan ran.
 * On the normal path EndScan (or ReScan) has already freed it and NULLed the
 * pointer, so this is a no-op then.
 */
static void
TidDedupCleanupCallback(void *arg)
{
	TidDedupScanState *state = (TidDedupScanState *) arg;

	if (state->seenTids != NULL)
	{
		FreeRoaringTidDedup(state->seenTids);
		state->seenTids = NULL;
	}
}


static void
TidDedupExplain(CustomScanState *node, List *ancestors, ExplainState *es)
{
	TidDedupScanState *state = (TidDedupScanState *) node;

	if (!es->analyze || node->ss.ps.instrument == NULL)
	{
		return;
	}

	/*
	 * Report the per-loop average, matching core PostgreSQL's convention for
	 * per-node tuple counters (see show_instrumentation_count): the running
	 * total accumulated across every rescan is divided by nloops here.
	 */
	double nloops = node->ss.ps.instrument->nloops;
	double avgDuplicatesDropped = (nloops > 0) ?
								  (double) state->numDuplicatesDropped / nloops : 0.0;
	ExplainPropertyFloat("Duplicate Rows Removed", NULL, avgDuplicatesDropped, 0, es);
}
