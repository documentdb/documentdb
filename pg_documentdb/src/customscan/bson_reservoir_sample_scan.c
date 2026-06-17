/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/customscan/bson_reservoir_sample_scan.c
 *
 * CustomScan implementation for reservoir sampling ($sample optimization).
 * Instead of ORDER BY random() LIMIT K (O(N log K) via top-K heap sort),
 * this scan iterates all tuples from the child plan in O(N) using
 * PostgreSQL's built-in reservoir sampling to select K samples with
 * uniform probability.
 *
 * The child plan is executed directly through the executor and sampled
 * tuples are materialized in a HeapTuple array for return.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <fmgr.h>
#include <nodes/extensible.h>
#include <nodes/makefuncs.h>
#include <nodes/pathnodes.h>
#include <optimizer/pathnode.h>
#include <parser/parsetree.h>
#include <executor/executor.h>
#include <utils/sampling.h>
#include <miscadmin.h>

#if PG_VERSION_NUM >= 180000
#include <commands/explain_format.h>
#endif

#include "io/bson_core.h"
#include "customscan/bson_custom_query_scan.h"
#include "customscan/custom_scan_registrations.h"
#include "aggregation/bson_query_common.h"
#include "metadata/metadata_cache.h"


/* --------------------------------------------------------- */
/* Forward declarations */
/* --------------------------------------------------------- */

static Plan * ReservoirSamplePlanCustomPath(PlannerInfo *root,
											RelOptInfo *rel,
											struct CustomPath *best_path,
											List *tlist,
											List *clauses,
											List *custom_plans);
static Node * ReservoirSampleCreateScanState(CustomScan *cscan);
static void ReservoirSampleBeginScan(CustomScanState *node, EState *estate,
									 int eflags);
static TupleTableSlot * ReservoirSampleExecScan(CustomScanState *node);
static TupleTableSlot * ReservoirSampleNext(CustomScanState *node);
static bool ReservoirSampleRecheck(CustomScanState *node, TupleTableSlot *slot);
static void ReservoirSampleEndScan(CustomScanState *node);
static void ReservoirSampleReScan(CustomScanState *node);
static void ReservoirSampleExplain(CustomScanState *node, List *ancestors,
								   ExplainState *es);


/* --------------------------------------------------------- */
/* Types */
/* --------------------------------------------------------- */

/*
 * Runtime state for the reservoir sample scan.
 * Stores full HeapTuple copies in the reservoir array.
 */
typedef struct ReservoirSampleState
{
	CustomScanState csstate;

	/* The child plan state (the filtered scan) */
	PlanState *childPlanState;

	/* Sample size K */
	int64 sampleSize;

	/* Reservoir of sampled tuples */
	HeapTuple *tupleReservoir;

	int numCollected;
	int returnIndex;
	bool scanStarted;
} ReservoirSampleState;


/* --------------------------------------------------------- */
/* CustomScan method tables */
/* --------------------------------------------------------- */

static const struct CustomPathMethods ReservoirSamplePathMethods = {
	.CustomName = "DocumentDBApiReservoirSample",
	.PlanCustomPath = ReservoirSamplePlanCustomPath,
};

static const struct CustomScanMethods ReservoirSampleScanMethods = {
	.CustomName = "DocumentDBApiReservoirSample",
	.CreateCustomScanState = ReservoirSampleCreateScanState,
};

static const struct CustomExecMethods ReservoirSampleExecMethods = {
	.CustomName = "DocumentDBApiReservoirSample",
	.BeginCustomScan = ReservoirSampleBeginScan,
	.ExecCustomScan = ReservoirSampleExecScan,
	.EndCustomScan = ReservoirSampleEndScan,
	.ReScanCustomScan = ReservoirSampleReScan,
	.ExplainCustomScan = ReservoirSampleExplain,
};


/* --------------------------------------------------------- */
/* Registration */
/* --------------------------------------------------------- */

void
RegisterReservoirSampleScanNodes(void)
{
	RegisterCustomScanMethods(&ReservoirSampleScanMethods);
}


/* --------------------------------------------------------- */
/* CustomPath → CustomScan conversion (used if path-based) */
/* --------------------------------------------------------- */

static Plan *
ReservoirSamplePlanCustomPath(PlannerInfo *root,
							  RelOptInfo *rel,
							  struct CustomPath *best_path,
							  List *tlist,
							  List *clauses,
							  List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);
	cscan->methods = &ReservoirSampleScanMethods;
	cscan->custom_plans = custom_plans;

	Assert(list_length(custom_plans) == 1);
	Plan *childPlan = linitial(custom_plans);
	cscan->custom_scan_tlist = childPlan->targetlist;

	/* Extract sample size for cost estimates */
	Const *sizeConst = (Const *) linitial(best_path->custom_private);
	Assert(IsA(sizeConst, Const) && !sizeConst->constisnull);
	int64 sampleSize = DatumGetInt64(sizeConst->constvalue);
	cscan->scan.plan.plan_rows = Min(sampleSize, childPlan->plan_rows);
	cscan->scan.plan.plan_width = childPlan->plan_width;
	cscan->scan.plan.startup_cost = childPlan->total_cost;
	cscan->scan.plan.total_cost = childPlan->total_cost;

	cscan->custom_private = list_make1(sizeConst);

	cscan->flags = CUSTOMPATH_SUPPORT_PROJECTION;

	/*
	 * Use the planner-provided tlist. ExecScan evaluates these expressions
	 * from ss_ScanTupleSlot (which holds raw child tuples matching
	 * custom_scan_tlist). This lets projections like bson_dollar_project
	 * be applied by PG's executor without us handling them explicitly.
	 */
	cscan->scan.plan.targetlist = tlist;

	return (Plan *) cscan;
}


/* --------------------------------------------------------- */
/* Plan → State (executor initialization) */
/* --------------------------------------------------------- */

static Node *
ReservoirSampleCreateScanState(CustomScan *cscan)
{
	ReservoirSampleState *state = (ReservoirSampleState *)
								  newNode(sizeof(ReservoirSampleState),
										  T_CustomScanState);

	state->csstate.methods = &ReservoirSampleExecMethods;

	/* Extract sample size from custom_private (first element: INT8 Const) */
	Const *sizeConst = (Const *) linitial(cscan->custom_private);
	Assert(IsA(sizeConst, Const) && !sizeConst->constisnull);
	state->sampleSize = DatumGetInt64(sizeConst->constvalue);
	Assert(state->sampleSize >= 0);
	state->tupleReservoir = NULL;
	state->numCollected = 0;
	state->returnIndex = 0;
	state->scanStarted = false;

	return (Node *) state;
}


/* --------------------------------------------------------- */
/* Executor callbacks */
/* --------------------------------------------------------- */

static void
ReservoirSampleBeginScan(CustomScanState *node, EState *estate, int eflags)
{
	ReservoirSampleState *state = (ReservoirSampleState *) node;
	CustomScan *cscan = (CustomScan *) node->ss.ps.plan;

	/* Initialize the child plan */
	Plan *childPlan = linitial(cscan->custom_plans);
	state->childPlanState = ExecInitNode(childPlan, estate, eflags);

	/* Store child in custom_ps for EXPLAIN */
	node->custom_ps = list_make1(state->childPlanState);

	state->tupleReservoir = NULL;
	state->numCollected = 0;
	state->returnIndex = 0;
}


/*
 * Execute the reservoir sampling scan.
 * On first call: pull ALL tuples from child, apply reservoir sampling, materialize
 * the K selected tuples in a tuplestore.
 * On subsequent calls: return tuples from the tuplestore.
 */
static TupleTableSlot *
ReservoirSampleExecScan(CustomScanState *node)
{
	/*
	 * Use ExecScan which handles projection (ps_ProjInfo) automatically.
	 * It calls our access method to get raw tuples into ss_ScanTupleSlot,
	 * then applies the targetlist projection.
	 */
	return ExecScan(&node->ss,
					(ExecScanAccessMtd) ReservoirSampleNext,
					(ExecScanRecheckMtd) ReservoirSampleRecheck);
}


/*
 * Access method: returns the next tuple from the reservoir.
 * On first call: scans all child tuples and applies reservoir sampling.
 * On subsequent calls: returns materialized tuples one at a time.
 */
static TupleTableSlot *
ReservoirSampleNext(CustomScanState *node)
{
	ReservoirSampleState *state = (ReservoirSampleState *) node;
	TupleTableSlot *scanSlot = node->ss.ss_ScanTupleSlot;

	if (!state->scanStarted)
	{
		state->scanStarted = true;

		int64 sampleSize = state->sampleSize;

		/* Guard against zero sample size reaching this code path */
		if (sampleSize <= 0)
		{
			state->numCollected = 0;
			state->returnIndex = 0;
			return ExecClearTuple(scanSlot);
		}

		/*
		 * Reject sample sizes that exceed INT32_MAX (2 billion) since the
		 * reservoir array is indexed by int. Also reject sizes that would
		 * exceed palloc limits: this is a safety cap.
		 */
		if (sampleSize > PG_INT32_MAX)
		{
			ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
							errmsg("$sample size " INT64_FORMAT
								   " exceeds maximum supported value",
								   sampleSize)));
		}

		int64 maxReservoirCapacity = (int64) (MaxAllocSize / sizeof(HeapTuple));
		if (sampleSize > maxReservoirCapacity)
		{
			ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
							errmsg("$sample size " INT64_FORMAT
								   " exceeds maximum reservoir capacity",
								   sampleSize)));
		}

		int reservoirCapacity = (int) sampleSize;

		/*
		 * We use a HeapTuple array instead of a tuplestore because the algorithm
		 * requires O(1) random index replacement (reservoir[k] = newTuple).
		 * Tuplestore is append only and doesn't support overwriting at an
		 * arbitrary position.
		 *
		 * Start with a small allocation and grow during the fill phase.
		 * This avoids wasting memory when K is large but few rows match.
		 * Once the reservoir is full, no further growth is needed.
		 */
		int initialCapacity = Min(1024, reservoirCapacity);
		int allocatedSlots = initialCapacity;

		MemoryContext oldContext = MemoryContextSwitchTo(
			node->ss.ps.state->es_query_cxt);
		state->tupleReservoir = (HeapTuple *)
								palloc0(allocatedSlots * sizeof(HeapTuple));
		MemoryContextSwitchTo(oldContext);

		int numCollected = 0;
		double totalRows = 0;
		double rowsToSkip = -1;

		ReservoirStateData rstate;
		reservoir_init_selection_state(&rstate, reservoirCapacity);

		/*
		 * Pull all tuples from child and apply reservoir sampling.
		 * ExecCopySlotHeapTuple allocates in the per-query ExecutorState context,
		 * so tuples survive across iterations until explicitly freed.
		 */
		for (;;)
		{
			CHECK_FOR_INTERRUPTS();

			TupleTableSlot *slot = ExecProcNode(state->childPlanState);
			if (TupIsNull(slot))
			{
				break;
			}

			if (numCollected < reservoirCapacity)
			{
				/* Grow the reservoir array if needed during fill phase */
				if (numCollected >= allocatedSlots)
				{
					int newCapacity = Min(allocatedSlots * 2,
										  reservoirCapacity);
					state->tupleReservoir = (HeapTuple *)
											repalloc(state->tupleReservoir,
													 newCapacity *
													 sizeof(HeapTuple));
					memset(state->tupleReservoir + allocatedSlots, 0,
						   (newCapacity - allocatedSlots) * sizeof(HeapTuple));
					allocatedSlots = newCapacity;
				}

				state->tupleReservoir[numCollected] =
					ExecCopySlotHeapTuple(slot);
				numCollected++;
			}
			else
			{
				if (rowsToSkip < 0)
				{
					rowsToSkip = reservoir_get_next_S(&rstate, totalRows,
													  reservoirCapacity);
				}

				if (rowsToSkip <= 0)
				{
					int k = (int) (reservoirCapacity *
								   sampler_random_fract(&rstate.randstate));
					if (k >= reservoirCapacity)
					{
						k = reservoirCapacity - 1;
					}
					heap_freetuple(state->tupleReservoir[k]);
					state->tupleReservoir[k] =
						ExecCopySlotHeapTuple(slot);
					rowsToSkip = -1;
				}
				else
				{
					rowsToSkip -= 1;
				}
			}

			totalRows += 1;
		}

		state->numCollected = numCollected;
		state->returnIndex = 0;
	}

	/* Return phase: emit materialized tuples one at a time */
	if (state->returnIndex < state->numCollected)
	{
		Assert(scanSlot->tts_tupleDescriptor->natts <= 1);
		if (scanSlot->tts_tupleDescriptor->natts == 0)
		{
			ExecClearTuple(scanSlot);
			ExecStoreVirtualTuple(scanSlot);
		}
		else
		{
			ExecForceStoreHeapTuple(
				state->tupleReservoir[state->returnIndex],
				scanSlot, false);
		}
		state->returnIndex++;
		return scanSlot;
	}

	return ExecClearTuple(scanSlot);
}


static bool
ReservoirSampleRecheck(CustomScanState *node, TupleTableSlot *slot)
{
	/* No recheck needed — reservoir sampling is deterministic once done */
	return true;
}


static void
ReservoirSampleEndScan(CustomScanState *node)
{
	ReservoirSampleState *state = (ReservoirSampleState *) node;

	if (state->tupleReservoir != NULL)
	{
		for (int i = 0; i < state->numCollected; i++)
		{
			if (state->tupleReservoir[i] != NULL)
			{
				heap_freetuple(state->tupleReservoir[i]);
			}
		}
		pfree(state->tupleReservoir);
		state->tupleReservoir = NULL;
	}

	ExecEndNode(state->childPlanState);
}


static void
ReservoirSampleReScan(CustomScanState *node)
{
	ReservoirSampleState *state = (ReservoirSampleState *) node;

	/* Clear the scan slot before freeing reservoir to avoid dangling pointer */
	ExecClearTuple(node->ss.ss_ScanTupleSlot);

	if (state->tupleReservoir != NULL)
	{
		for (int i = 0; i < state->numCollected; i++)
		{
			if (state->tupleReservoir[i] != NULL)
			{
				heap_freetuple(state->tupleReservoir[i]);
			}
		}
		pfree(state->tupleReservoir);
		state->tupleReservoir = NULL;
	}

	state->numCollected = 0;
	state->returnIndex = 0;
	state->scanStarted = false;

	Assert(state->childPlanState != NULL);
	ExecReScan(state->childPlanState);
}


static void
ReservoirSampleExplain(CustomScanState *node, List *ancestors, ExplainState *es)
{
	ReservoirSampleState *state = (ReservoirSampleState *) node;
	ExplainPropertyInteger("Sample Size", NULL, state->sampleSize, es);
}


/* --------------------------------------------------------- */
/* Public: Wrap paths with ReservoirSample CustomPath        */
/* --------------------------------------------------------- */

/*
 * AddReservoirSampleCustomPath wraps each non-parameterized path in the
 * relation's pathlist with a ReservoirSample CustomPath.
 *
 * We replace the pathlist rather than using add_path() because the reservoir
 * scan eliminates the Sort+Limit node above (which add_path cannot account
 * for at the relation level). The unwrapped path would always appear cheaper
 * locally, but the overall plan with Sort+Limit is more expensive.
 */
void
AddReservoirSampleCustomPath(RelOptInfo *rel, FuncExpr *sampleExpr)
{
	DollarRangeParams rangeParams = { 0 };
	if (!TryGetRangeParamsForRangeArgs(sampleExpr->args, &rangeParams) ||
		!rangeParams.isSample)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("failed to extract sample size from reservoir "
							   "sampling marker")));
	}

	int64_t sampleSize = rangeParams.sampleSize;
	List *newPathlist = NIL;

	/* Store sample size as an INT8 Const to avoid int64 truncation */
	Const *sizeConst = makeConst(INT8OID, -1, InvalidOid, sizeof(int64),
								 Int64GetDatum(sampleSize), false, true);

	ListCell *cell;
	foreach(cell, rel->pathlist)
	{
		Path *inputPath = lfirst(cell);

		/* Skip parameterized paths — reservoir sampling doesn't support lateral */
		if (inputPath->param_info != NULL)
		{
			newPathlist = lappend(newPathlist, inputPath);
			continue;
		}

		CustomPath *cpath = makeNode(CustomPath);
		cpath->methods = &ReservoirSamplePathMethods;
		cpath->path.pathtype = T_CustomScan;
		cpath->path.parent = inputPath->parent;
		cpath->path.param_info = NULL;
		cpath->path.rows = Min((double) sampleSize, inputPath->rows);
		cpath->path.startup_cost = inputPath->total_cost;
		cpath->path.total_cost = inputPath->total_cost;
		cpath->path.parallel_safe = false;
		cpath->path.pathtarget = inputPath->pathtarget;
		cpath->path.pathkeys = NIL;
		cpath->custom_paths = list_make1(inputPath);
		cpath->custom_private = list_make1(sizeConst);

		cpath->flags = CUSTOMPATH_SUPPORT_PROJECTION;

		newPathlist = lappend(newPathlist, cpath);
	}

	rel->pathlist = newPathlist;

	/* Clear partial paths — reservoir sampling is not parallel-safe */
	rel->partial_pathlist = NIL;
}
