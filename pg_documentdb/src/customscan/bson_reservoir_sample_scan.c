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
#include <optimizer/paths.h>
#include <parser/parsetree.h>
#include <executor/executor.h>
#include <access/genam.h>
#include <access/relscan.h>
#include <access/visibilitymap.h>
#include <catalog/pg_am.h>
#include <storage/bufmgr.h>
#include <storage/predicate.h>
#include <utils/sampling.h>
#include <utils/snapmgr.h>
#include <miscadmin.h>

#if PG_VERSION_NUM >= 180000
#include <commands/explain_format.h>
#endif

#include "io/bson_core.h"
#include "customscan/bson_custom_query_scan.h"
#include "customscan/bson_custom_scan_private.h"
#include "customscan/custom_scan_registrations.h"
#include "aggregation/bson_query_common.h"
#include "index_am/index_am_utils.h"
#include "metadata/metadata_cache.h"
#include "utils/feature_counter.h"

extern bool EnableDollarSampleHeapSkipReservoirScan;


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
static bool IsHeapSkipEligible(Plan *childPlan, Path *childPath);
static Path * TryConvertBitmapToIndexPath(Path *inputPath);
static void CopyReservoirSampleInputState(ExtensibleNode *target_node,
										  const ExtensibleNode *source_node);
static bool EqualReservoirSampleInputState(const ExtensibleNode *a,
										   const ExtensibleNode *b);
static void OutReservoirSampleInputState(StringInfo str,
										 const ExtensibleNode *raw_node);
static void ReadReservoirSampleInputState(ExtensibleNode *node);


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

	/*
	 * When true, skipped rows are passed over by advancing the index directly.
	 * Only sampled rows read the full heap tuple; skipped rows touch the heap
	 * only for a visibility check, and not at all on all-visible pages.
	 */
	bool heapSkipMode;

	/* Reservoir of sampled tuples */
	HeapTuple *tupleReservoir;

	/* Visibility map buffer pinned during heap skip; released in EndScan. */
	Buffer vmBuffer;

	/*
	 * EXPLAIN ANALYZE skip counts: total rows skipped, and how many of those
	 * needed a heap read. The rest were served from the visibility map.
	 */
	int64 sampleRowsSkipped;
	int64 sampleHeapSkips;

	int numCollected;
	int returnIndex;
	bool scanStarted;
} ReservoirSampleState;

static bool TrySkipHeapEntry(ReservoirSampleState *state, Snapshot snapshot,
							 bool *isVisible);

/* Node name used to register the input state with PostgreSQL. */
#define ReservoirSampleInputStateName "DocumentDBApiReservoirSampleInput"

/*
 * Immutable parameters resolved at planning time for a single query, carried to
 * the executor as the single custom_private element. Modeled on the
 * ExtensibleNode input state used by the DocumentDBApiQueryScan custom scan
 */
typedef struct ReservoirSampleInputState
{
	/* Must be the first field */
	ExtensibleNode extensible;

	/* Sample size K */
	int64 sampleSize;

	/* Resolved heap skip mode (see ReservoirSampleState.heapSkipMode) */
	bool heapSkipMode;
} ReservoirSampleInputState;


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


static const ExtensibleNodeMethods ReservoirSampleInputStateMethods = {
	ReservoirSampleInputStateName,
	sizeof(ReservoirSampleInputState),
	CopyReservoirSampleInputState,
	EqualReservoirSampleInputState,
	OutReservoirSampleInputState,
	ReadReservoirSampleInputState
};


/* --------------------------------------------------------- */
/* Registration */
/* --------------------------------------------------------- */

void
RegisterReservoirSampleScanNodes(void)
{
	RegisterCustomScanMethods(&ReservoirSampleScanMethods);
	RegisterExtensibleNodeMethods(&ReservoirSampleInputStateMethods);
}


/* --------------------------------------------------------- */
/* CustomPath → CustomScan conversion (used if path-based) */
/* --------------------------------------------------------- */

/*
 * Returns true when relam is safe for heap skip mode. btree never returns lossy
 * matches, so every TID is an exact sample candidate. A regular bson (RUM) index
 * is accepted too: it may be lossy, but TrySkipHeapEntry rechecks the index qual
 * against the heap tuple when xs_recheck is set.
 */
static bool
IsHeapSkipCapableAm(Oid relam)
{
	return relam == BTREE_AM_OID || IsBsonRegularIndexAm(relam);
}


/*
 * Returns true when the child can use heap skip mode, where skipped rows are
 * passed over by advancing the index TID stream instead of materializing every
 * match. Every counted TID must be a valid sample candidate, so all must hold:
 *
 *   - plain Index Scan: we advance its iss_ScanDesc directly;
 *   - qual == NIL: no residual filter that skipping would bypass;
 *   - a heap skip capable AM: btree is never lossy, and RUM lossiness is
 *     handled per row by the xs_recheck guard in TrySkipHeapEntry.
 *
 */
static bool
IsHeapSkipEligible(Plan *childPlan, Path *childPath)
{
	if (!IsA(childPlan, IndexScan) || !IsA(childPath, IndexPath))
	{
		/* Index Only Scan needs no heap skip; it already avoids heap fetches. */
		return false;
	}

	IndexScan *indexScan = (IndexScan *) childPlan;
	IndexPath *indexPath = (IndexPath *) childPath;

	return indexScan->scan.plan.qual == NIL &&
		   IsHeapSkipCapableAm(indexPath->indexinfo->relam);
}


/*
 * If inputPath is a Bitmap Heap Scan over a single Bitmap Index Scan whose index
 * is heap skip capable and covers every restriction, returns an equivalent plain
 * Index Scan path so heap skip can engage. Returns inputPath unchanged otherwise.
 */
static Path *
TryConvertBitmapToIndexPath(Path *inputPath)
{
	if (!IsA(inputPath, BitmapHeapPath))
	{
		return inputPath;
	}

	Path *bitmapqual = ((BitmapHeapPath *) inputPath)->bitmapqual;

	/* Only a single index bitmap qual converts; BitmapAnd/BitmapOr do not. */
	if (bitmapqual == NULL || !IsA(bitmapqual, IndexPath))
	{
		return inputPath;
	}

	IndexPath *bitmapIndexPath = (IndexPath *) bitmapqual;

	/*
	 * Only convert for AMs we can heap skip on. Other AMs would fall back to
	 * Materialize anyway, so converting them changes the plan for no benefit.
	 */
	if (!IsHeapSkipCapableAm(bitmapIndexPath->indexinfo->relam))
	{
		return inputPath;
	}

	/*
	 * Only convert when the index covers every restriction that would become a
	 * residual Filter, so the Index Scan can heap skip. Otherwise leave the
	 * bitmap: a residual filter forces Materialize, where a Bitmap Heap Scan
	 * can win.
	 *
	 * We check indrestrictinfo, the exact set core's create_indexscan_plan
	 * turns into the residual qpqual. It is baserestrictinfo minus clauses the
	 * index predicate already implies, so a partial index whose predicate
	 * subsumes part of the match still converts.
	 */
	ListCell *restrictCell;
	foreach(restrictCell, bitmapIndexPath->indexinfo->indrestrictinfo)
	{
		RestrictInfo *rinfo = lfirst(restrictCell);
		if (!is_redundant_with_indexclauses(rinfo, bitmapIndexPath->indexclauses))
		{
			return inputPath;
		}
	}

	/*
	 * Reuse bitmapqual: it is already a plain Index Scan path over the same index
	 * and clauses, only left as NoMovementScanDirection for unordered AMs. Force
	 * a forward scan so the skip loop can advance the TID stream.
	 */
	bitmapIndexPath->indexscandir = ForwardScanDirection;

	return (Path *) bitmapIndexPath;
}


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
	ReservoirSampleInputState *inputState =
		(ReservoirSampleInputState *) linitial(best_path->custom_private);
	int64 sampleSize = inputState->sampleSize;
	cscan->scan.plan.plan_rows = Min(sampleSize, childPlan->plan_rows);
	cscan->scan.plan.plan_width = childPlan->plan_width;
	cscan->scan.plan.startup_cost = childPlan->total_cost;
	cscan->scan.plan.total_cost = childPlan->total_cost;

	/*
	 * Resolve heap skip eligibility from the child plan/path, gated by the
	 * feature flag. Sampled rows still flow through the child's ExecProcNode, so
	 * the scan slot and target list match the materialize path regardless.
	 *
	 * Resolving it here means EXPLAIN without ANALYZE
	 * can still report the chosen method.
	 *
	 * Report the feature counters at the same point so they share a phase: when
	 * the plan is heap skip capable but the flag is off, count it as an eligible
	 * candidate for turning the flag on; otherwise count actual heap skip usage.
	 */
	Path *childPath = linitial(best_path->custom_paths);
	bool heapSkipEligible = IsHeapSkipEligible(childPlan, childPath);
	inputState->heapSkipMode = EnableDollarSampleHeapSkipReservoirScan &&
							   heapSkipEligible;

	if (inputState->heapSkipMode)
	{
		ReportFeatureUsage(FEATURE_STAGE_SAMPLE_HEAP_SKIP);
	}
	else if (heapSkipEligible)
	{
		ReportFeatureUsage(FEATURE_STAGE_SAMPLE_HEAP_SKIP_ELIGIBLE);
	}

	/* Pass the resolved input state through to the executor. */
	cscan->custom_private = list_make1(inputState);

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

	/* Read the immutable input state (single custom_private element). */
	ReservoirSampleInputState *inputState =
		(ReservoirSampleInputState *) linitial(cscan->custom_private);
	state->sampleSize = inputState->sampleSize;
	Assert(state->sampleSize >= 0);
	state->heapSkipMode = inputState->heapSkipMode;

	state->tupleReservoir = NULL;
	state->vmBuffer = InvalidBuffer;
	state->sampleRowsSkipped = 0;
	state->sampleHeapSkips = 0;
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
 * Advances the index by one entry without materializing it, using the
 * visibility map to skip the heap. *isVisible tells whether the entry counts
 * toward the skip: dead entries, and lossy entries (RUM) that fail the qual
 * recheck, must not count so both modes skip the same population. Returns false
 * when the scan is exhausted. The child is always an Index Scan.
 *
 * This is modeled on two PostgreSQL executor nodes:
 *  - IndexNext (nodeIndexscan.c): how the effective scan direction is derived
 *    and how a lossy index match is rechecked against the heap tuple.
 *    https://github.com/postgres/postgres/blob/3854f4afca68c57df1289f0852a9e4481e153100/src/backend/executor/nodeIndexscan.c#L81
 *  - IndexOnlyNext (nodeIndexonlyscan.c): how an all visible page is served
 *    from the visibility map without a heap fetch, under a page predicate lock.
 *    https://github.com/postgres/postgres/blob/3854f4afca68c57df1289f0852a9e4481e153100/src/backend/executor/nodeIndexonlyscan.c#L62
 */
static bool
TrySkipHeapEntry(ReservoirSampleState *state, Snapshot snapshot, bool *isVisible)
{
	IndexScanState *indexState = (IndexScanState *) state->childPlanState;
	IndexScanDesc scanDesc = indexState->iss_ScanDesc;
	Assert(scanDesc != NULL);

	/*
	 * A single index_fetch_heap is only definitive under an MVCC snapshot: it
	 * scans the whole HOT chain in one pass, so we never follow
	 * xs_heap_continue. Index Only Scan relies on the same restriction.
	 */
	Assert(IsMVCCSnapshot(snapshot));

	/*
	 * Walk the index in the child's effective direction, exactly as IndexNext
	 * does in nodeIndexscan.c, so the skip and keeper phases stay consistent on
	 * the shared scan descriptor. The derivation differs by PG version (see each
	 * branch below); both rely on the child path carrying a real forward (or
	 * backward) indexorderdir, since an unordered path's NoMovementScanDirection
	 * would collapse the derived direction to NoMovement, which cannot advance
	 * the TID stream. TryConvertBitmapToIndexPath forces ForwardScanDirection
	 * for exactly this reason.
	 */
	IndexScan *indexPlan = (IndexScan *) indexState->ss.ps.plan;
#if PG_VERSION_NUM >= 160000

	/*
	 * Mirrors PG16+ IndexNext (nodeIndexscan.c), which combines the executor
	 * direction with the plan's index order direction via ScanDirectionCombine.
	 */
	ScanDirection direction = ScanDirectionCombine(
		indexState->ss.ps.state->es_direction,
		indexPlan->indexorderdir);
#else

	/*
	 * Copied verbatim from PG15's IndexNext (nodeIndexscan.c); the three-way
	 * branch is deliberate so a NoMovement direction is left untouched.
	 */
	ScanDirection direction = indexState->ss.ps.state->es_direction;
	if (ScanDirectionIsBackward(indexPlan->indexorderdir))
	{
		if (ScanDirectionIsForward(direction))
		{
			direction = BackwardScanDirection;
		}
		else if (ScanDirectionIsBackward(direction))
		{
			direction = ForwardScanDirection;
		}
	}
#endif

	ItemPointer tid = index_getnext_tid(scanDesc, direction);
	if (tid == NULL)
	{
		return false;
	}

	/* We have a TID to skip; count it once here. */
	state->sampleRowsSkipped++;

	/*
	 * Fast path: a non-lossy match on an all-visible page is counted via the
	 * visibility map with no heap read, taking the page predicate lock instead.
	 * A lossy match (RUM) can't use it; it falls through to recheck the qual.
	 */
	BlockNumber block = ItemPointerGetBlockNumber(tid);
	if (!scanDesc->xs_recheck &&
		VM_ALL_VISIBLE(scanDesc->heapRelation, block, &state->vmBuffer))
	{
		PredicateLockPage(scanDesc->heapRelation, block, snapshot);
		*isVisible = true;
		return true;
	}

	/*
	 * Otherwise fetch the heap tuple, which both reports visibility and fills
	 * the slot. A plain Index Scan has no index tuple to recheck against (only
	 * an Index Only Scan returns one), so the document must come from the heap.
	 * On a lossy match we then recheck the qual against it; a false positive
	 * must not count. btree never sets xs_recheck. We're on the skip path, so
	 * this skip required a heap read.
	 */
	state->sampleHeapSkips++;

	/* ss_ScanTupleSlot is always allocated by ExecInitIndexScan when the child
	 * index scan is initialized, and index_fetch_heap fills it only when it
	 * returns true, so the slot is read below solely on the visible branch. */
	bool visible = index_fetch_heap(scanDesc, indexState->ss.ss_ScanTupleSlot);
	if (visible && scanDesc->xs_recheck)
	{
		Assert(!TupIsNull(indexState->ss.ss_ScanTupleSlot));
		ExprContext *econtext = indexState->ss.ps.ps_ExprContext;
		econtext->ecxt_scantuple = indexState->ss.ss_ScanTupleSlot;
		visible = ExecQualAndReset(indexState->indexqualorig, econtext);
	}

	*isVisible = visible;
	return true;
}


/*
 * Releases the visibility map buffer pinned during heap skip, if any, and resets
 * the handle. Safe to call when nothing is pinned. Called on the normal path
 * once skipping is done and from EndScan so the pin can never leak if the
 * sampling loop throws.
 */
static void
ReleaseReservoirVmBuffer(ReservoirSampleState *state)
{
	if (state->vmBuffer != InvalidBuffer)
	{
		ReleaseBuffer(state->vmBuffer);
		state->vmBuffer = InvalidBuffer;
	}
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
		 * Start with a small allocation and grow during the fill phase. This
		 * avoids wasting memory when K is large but few rows match. Once the
		 * reservoir is full, no further growth is needed.
		 */
		int allocatedSlots = Min(1024, reservoirCapacity);

		MemoryContext oldContext = MemoryContextSwitchTo(
			node->ss.ps.state->es_query_cxt);
		state->tupleReservoir = (HeapTuple *)
								palloc0(allocatedSlots * sizeof(HeapTuple));
		MemoryContextSwitchTo(oldContext);

		int numCollected = 0;
		double totalRows = 0;

		ReservoirStateData rstate;
		reservoir_init_selection_state(&rstate, reservoirCapacity);

		/*
		 * rowsToSkip counts the rows left to pass over before the next
		 * replacement; -1 means "draw a fresh skip distance S". In heap skip
		 * mode these rows are advanced over via the index (TrySkipHeapEntry), so
		 * state->vmBuffer caches the pinned visibility map page across probes. It
		 * lives in the scan state so EndScan releases it even if the loop throws.
		 */
		double rowsToSkip = -1;

		/*
		 * Pull all tuples from child and apply reservoir sampling.
		 * ExecCopySlotHeapTuple allocates in the per-query ExecutorState context,
		 * so tuples survive across iterations until explicitly freed.
		 */
		for (;;)
		{
			CHECK_FOR_INTERRUPTS();

			/* Once the reservoir is full, draw the next skip distance S. */
			if (numCollected == reservoirCapacity && rowsToSkip < 0)
			{
				rowsToSkip = reservoir_get_next_S(&rstate, totalRows,
												  reservoirCapacity);
			}

			/*
			 * Heap skip fast path: pass over a discarded row by advancing the
			 * index, without materializing it. Dead entries are not counted (the
			 * materialize path never sees them), so both modes skip the same
			 * population. rowsToSkip > 0 implies the reservoir is full.
			 */
			if (state->heapSkipMode && rowsToSkip > 0)
			{
				bool isVisible;
				if (!TrySkipHeapEntry(state, node->ss.ps.state->es_snapshot,
									  &isVisible))
				{
					break;
				}
				if (isVisible)
				{
					rowsToSkip -= 1;
					totalRows += 1;
				}
			}
			else
			{
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
							   (newCapacity - allocatedSlots) *
							   sizeof(HeapTuple));
						allocatedSlots = newCapacity;
					}

					state->tupleReservoir[numCollected] =
						ExecCopySlotHeapTuple(slot);
					numCollected++;
				}
				else if (rowsToSkip <= 0)
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

				totalRows += 1;
			}
		}

		ReleaseReservoirVmBuffer(state);

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

	ReleaseReservoirVmBuffer(state);

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
	ExplainPropertyText("Sample Reservoir Method",
						state->heapSkipMode ? "Heap Skip" : "Materialize", es);

	/*
	 * Under EXPLAIN ANALYZE in heap skip mode, report how many rows were
	 * skipped and how many of those needed a heap read.
	 */
	if (es->analyze && state->heapSkipMode)
	{
		ExplainPropertyInteger("Sample Rows Skipped", NULL,
							   state->sampleRowsSkipped, es);
		ExplainPropertyInteger("Sample Heap Skips", NULL,
							   state->sampleHeapSkips, es);
	}
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
AddReservoirSampleCustomPath(PlannerInfo *root, RelOptInfo *rel, FuncExpr *sampleExpr)
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

		/*
		 * A Bitmap Heap Scan reads every matching heap page, defeating heap
		 * skip. Rewrite a single index bitmap to a plain Index Scan so skipped
		 * rows can be passed over via the index TID stream.
		 */
		if (EnableDollarSampleHeapSkipReservoirScan)
		{
			inputPath = TryConvertBitmapToIndexPath(inputPath);
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

		/*
		 * Carry the sample size as the single custom_private element. The
		 * resolved heap skip mode is filled in later by PlanCustomPath.
		 */
		ReservoirSampleInputState *inputState =
			(ReservoirSampleInputState *) newNode(
				sizeof(ReservoirSampleInputState), T_ExtensibleNode);
		inputState->extensible.extnodename = ReservoirSampleInputStateName;
		inputState->sampleSize = sampleSize;
		cpath->custom_private = list_make1(inputState);

		cpath->flags = CUSTOMPATH_SUPPORT_PROJECTION;

		newPathlist = lappend(newPathlist, cpath);
	}

	rel->pathlist = newPathlist;

	/* Clear partial paths — reservoir sampling is not parallel-safe */
	rel->partial_pathlist = NIL;
}


/* --------------------------------------------------------- */
/* ReservoirSampleInputState node methods (custom_private) */
/* --------------------------------------------------------- */

/*
 * Deep copy of the input state. The struct holds only scalars, so copying the
 * fields is sufficient.
 */
static void
CopyReservoirSampleInputState(struct ExtensibleNode *target_node,
							  const struct ExtensibleNode *source_node)
{
	ReservoirSampleInputState *from = (ReservoirSampleInputState *) source_node;
	ReservoirSampleInputState *newNode = (ReservoirSampleInputState *) target_node;

	newNode->extensible.type = T_ExtensibleNode;
	newNode->extensible.extnodename = ReservoirSampleInputStateName;
	newNode->sampleSize = from->sampleSize;
	newNode->heapSkipMode = from->heapSkipMode;
}


/* Comparing two input states is not required. */
static bool
EqualReservoirSampleInputState(const struct ExtensibleNode *a,
							   const struct ExtensibleNode *b)
{
	ereport(ERROR, (errmsg(
						"Equal for node type ReservoirSampleInput not implemented")));
}


/* Serializes the input state for plan shipping. */
static void
OutReservoirSampleInputState(StringInfo str, const struct ExtensibleNode *raw_node)
{
	ReservoirSampleInputState *node = (ReservoirSampleInputState *) raw_node;

	WRITE_UINT64_FIELD(sampleSize);
	WRITE_BOOL_FIELD(heapSkipMode);
}


/* Deserializes the input state written by OutReservoirSampleInputState. */
static void
ReadReservoirSampleInputState(struct ExtensibleNode *node)
{
	/* token and length are referenced by the READ_*_FIELD macros below */
	const char *token;
	int length;
	ReservoirSampleInputState *local_node = (ReservoirSampleInputState *) node;

	local_node->extensible.type = T_ExtensibleNode;
	local_node->extensible.extnodename = ReservoirSampleInputStateName;

	READ_UINT64_FIELD(sampleSize);
	READ_BOOL_FIELD(heapSkipMode);
}
