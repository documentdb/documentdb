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
#include <opclass/bson_gin_index_term.h>


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
#include "utils/documentdb_errors.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "utils/docdb_make_funcs.h"
#include "query/bson_dollar_selectivity.h"

#define InputContinuationNodeName "DynamicCursorScanInputContinuation"

#define ItemPointerToUint64(tuple) ((((uint64_t) ItemPointerGetBlockNumber(tuple)) << \
									 32) | \
									ItemPointerGetOffsetNumber(tuple))

#define Uint64AsItemPointer(ptr, value) ItemPointerSet(ptr, \
													   (BlockNumber) (value >> 32), \
													   (OffsetNumber) (value & \
																	   0xFFFFFFFF))

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

	/* The continuation state for the index scan */
	bytea *indexContinuation;
} DynamicCursorInputContinuation;


typedef struct ParsedContinuationState
{
	/* Extension scan custom fields */
	QueryScanType scanType;

	/* The table name that is being queried */
	Oid tableOid;

	/* The index Oids (if any) being queried */
	List *indexOids;

	/* The continuation state passed in by the user */
	ItemPointerData userContinuationState;

	/* The direction of the index scan */
	ScanDirection indexScanDirection;

	Datum cursorDatums[INDEX_MAX_KEYS];
} ParsedContinuationState;


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

	/* Extension scan custom fields */
	QueryScanType scanType;

	/* The table name that is being queried */
	Oid tableOid;

	/* The continuation state passed in by the user */
	ItemPointerData userContinuationState;

	/* The continuation state for the index scan */
	bytea *indexContinuation;

	/* The core scan method to fetch tuples */
	ExecScanAccessMtd execScanMethod;
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
static TupleTableSlot * ExtensionCursorScanNextWithContinuation(CustomScanState *node);
static TupleTableSlot * ExtensionCursorScanNextWithIndexContinuation(
	CustomScanState *node);
static void ParseContinuationDocument(pgbson *continuation,
									  ParsedContinuationState *state);
static Path * GeneratePathFromContinuation(ParsedContinuationState *tempState,
										   DynamicCursorInputContinuation *
										   inputContinuation,
										   PlannerInfo *root, RelOptInfo *rel,
										   RangeTblEntry *rte,
										   PathTarget *baseRelPathTarget,
										   ReplaceExtensionFunctionContext *indexContext);
static void WriteContinuationBasedOnScanTypeAndState(ScanState *ps, pgbson_writer *writer,
													 QueryScanType scanType);
static void AddOrderByRequiredClausesIfNecessary(IndexPath *indexPath, PlannerInfo *root,
												 RelOptInfo *rel);
static void AddContinuationQualsToIndexPath(PlannerInfo *root, RelOptInfo *rel,
											IndexPath *resumePath,
											ParsedContinuationState *state);
static bool IsGroupByFullyPushableForStreaming(PlannerInfo *root);

PG_FUNCTION_INFO_V1(command_cursor_tracker);

extern bool EnableRumCursorDynamicIndexScans;
extern bool EnableRumDynamicIndexScansSkipToTid;
extern bool EnableOrderByIdOnCostFunction;
extern bool EnableMergeSortForInPrefix;
extern bool EnableDynamicPersistentCursorsWithStats;
extern bool EnableGroupByDynamicStreaming;
extern bool EnableDynamicCursorMultiKeyBitmap;

/* Declaration of extensibility paths for query processing (See extensible.h) */
static const struct CustomPathMethods DynamicExtensionCursorScanMethods = {
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


/*
 * Returns true if the given plan node is a grouping/deduplication node that
 * preserves the streaming (non-blocking) property of its input, i.e. it emits
 * output rows incrementally as it consumes ordered input rather than
 * materializing the whole input first.
 *
 * A sorted GroupAggregate (AGG_SORTED) and a Unique node both stream: they read
 * input in group-key order and emit one row per group as soon as the group
 * boundary is observed. A plain aggregate (AGG_PLAIN) produces a single row and
 * is drained in one batch. A hashed/mixed aggregate (AGG_HASHED / AGG_MIXED)
 * is blocking - it must consume the entire input before emitting any row - so
 * it cannot back a streaming cursor and is rejected here.
 */
static bool
IsStreamableGroupingPlan(Plan *plan)
{
	if (IsA(plan, Agg))
	{
		Agg *agg = (Agg *) plan;
		return agg->aggstrategy == AGG_SORTED || agg->aggstrategy == AGG_PLAIN;
	}

	return IsA(plan, Unique);
}


bool
IsDynamicCustomScanPath(Plan *plan)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();
	if (IsA(plan, CustomScan))
	{
		CustomScan *scan = (CustomScan *) plan;
		return strcmp(scan->methods->CustomName,
					  DynamicExtensionCursorScanMethods.CustomName) == 0 &&
			   scan->methods == &ExtensionCursorScanMethods;
	}

	if (IsA(plan, SubqueryScan))
	{
		SubqueryScan *subqueryScan = (SubqueryScan *) plan;
		return IsDynamicCustomScanPath(subqueryScan->subplan);
	}

	/*
	 * A streaming grouping node (sorted GroupAggregate / Unique) directly over
	 * the dynamic cursor scan keeps the cursor streamable: it consumes ordered
	 * rows from the custom scan and emits one row per group. Descend through it
	 * to locate the custom scan. Blocking grouping strategies (hash aggregate)
	 * are rejected by IsStreamableGroupingPlan, falling back to a persistent
	 * cursor.
	 */
	if (IsStreamableGroupingPlan(plan))
	{
		return outerPlan(plan) != NULL && IsDynamicCustomScanPath(outerPlan(plan));
	}

	return false;
}


/*
 * Locates the dynamic cursor custom scan state within the plan tree rooted at
 * planState, descending through SubqueryScan wrappers and a single streaming
 * grouping node (sorted GroupAggregate / Unique) that may sit above it. Returns
 * NULL if no dynamic cursor custom scan is found.
 *
 * When isGroupReadAhead is non-NULL it is set to true iff the descent passed
 * through a sorted GroupAggregate (AGG_SORTED). Such a node reads one input row
 * *past* each group it emits in order to detect the group boundary, so the
 * underlying scan is already positioned at the first row of the next group when
 * a group is handed downstream. This "read-ahead" changes how a continuation
 * must be captured on a batch boundary: the streaming DestReceiver snapshots it
 * after each emitted group rather than at reject time (which would be one group
 * too far ahead and would skip a group on the next page). Other streamable
 * shapes (plain aggregate, Unique) do not read ahead and leave the flag unset.
 * The caller must initialize *isGroupReadAhead before calling.
 */
CustomScanState *
GetDynamicStreamingCustomScanState(PlanState *planState, bool *isGroupReadAhead)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();
	if (IsA(planState, CustomScanState))
	{
		CustomScanState *scanState = (CustomScanState *) planState;
		if (strcmp(scanState->methods->CustomName,
				   DynamicExtensionCursorScanMethods.CustomName) == 0)
		{
			return scanState;
		}

		return NULL;
	}

	if (IsA(planState, SubqueryScanState))
	{
		SubqueryScanState *subqueryScan = (SubqueryScanState *) planState;
		return GetDynamicStreamingCustomScanState(subqueryScan->subplan,
												  isGroupReadAhead);
	}

	/* Descend through a streaming grouping node (see IsDynamicCustomScanPath). */
	if (IsStreamableGroupingPlan(planState->plan) &&
		outerPlanState(planState) != NULL)
	{
		if (isGroupReadAhead != NULL &&
			IsA(planState->plan, Agg) &&
			((Agg *) planState->plan)->aggstrategy == AGG_SORTED)
		{
			*isGroupReadAhead = true;
		}

		return GetDynamicStreamingCustomScanState(outerPlanState(planState),
												  isGroupReadAhead);
	}

	return NULL;
}


pgbson *
GetContinuationFromCustomScan(CustomScanState *scan)
{
	if (strcmp(scan->methods->CustomName, DynamicExtensionCursorScanMethods.CustomName) !=
		0)
	{
		ereport(ERROR, (errmsg("Invalid custom scan provided. Expected %s but found %s",
							   DynamicExtensionCursorScanMethods.CustomName,
							   scan->methods->CustomName)));
	}

	/* Serialize necessary information to continue the scan */
	ExtensionCursorScanState *cursorScanState = (ExtensionCursorScanState *) scan;

	ScanState *ps = cursorScanState->innerScanState;

	/*
	 * A streaming sorted GroupAggregate detects the final group's boundary by
	 * reading one row past it and hitting end-of-scan, which leaves the inner
	 * scan's tuple slot empty. There is no next row to resume from in that case,
	 * so the cursor is complete and there is no continuation to serialize.
	 * Returning NULL here avoids reading attributes off an empty slot; the drain
	 * loop then terminates as a natural cursor completion (which ignores the
	 * continuation anyway).
	 */
	if (ps->ss_ScanTupleSlot == NULL || TTS_EMPTY(ps->ss_ScanTupleSlot))
	{
		return NULL;
	}

	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt32(&writer, "type", 4, cursorScanState->scanType);

	const char *tableName = get_rel_name(cursorScanState->tableOid);
	PgbsonWriterAppendUtf8(&writer, "tbl", 3, tableName);


	WriteContinuationBasedOnScanTypeAndState(ps, &writer, cursorScanState->scanType);
	return PgbsonWriterGetPgbson(&writer);
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
	customPath->methods = &DynamicExtensionCursorScanMethods;

	Path *path = &customPath->path;
	path->pathtype = T_CustomScan;

	/* copy the parameters from the inner path */
	Assert(inputPath->parent == rel);
	path->parent = rel;

	path->param_info = NULL;

	/* Copy scalar values in from the inner path */
	path->rows = inputPath->rows;
	path->startup_cost = inputPath->startup_cost;
	path->total_cost = inputPath->total_cost;

	/* For now the custom path is not parallel safe */
	path->parallel_safe = false;
	customPath->custom_paths = list_make1(inputPath);
	switch (inputContinuation->scanType)
	{
		case QueryScanType_PrimaryKeyScan:
		{
			/* Projection of all base table columns to extract shard_key_value & object_id.
			 * Move projection to the top level pathTarget.
			 *
			 * Copy the outer pathtarget instead of aliasing inputPath->pathtarget:
			 * the shared baseRelPathTarget is reused as the inner projection of
			 * every custom path for this relation, and aliasing here could make
			 * that wide pathtarget the top-level target of a rel->pathlist path.
			 * apply_scanjoin_target_to_paths() would then relabel it in place with
			 * the narrower final-target sortgrouprefs, leaving the inner
			 * projection with a sortgrouprefs array shorter than its exprs list
			 * and causing build_path_tlist() to read past its end. An independent
			 * copy keeps baseRelPathTarget off rel->pathlist.
			 */
			path->pathtarget = copy_pathtarget(inputPath->pathtarget);
			inputPath->pathtarget = baseRelPathTarget;
			break;
		}

		default:
		{
			/* Just project out the sub projection document.
			 * Note this is transformed later when there's an actual projection to be had.
			 */
			path->pathtarget = copy_pathtarget(inputPath->pathtarget);
			break;
		}
	}

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
	customPath->path.pathkeys = inputPath->pathkeys;

	return customPath;
}


static bool
GetIndexSupportsGetIndexKey(Oid relam, Oid opfamily)
{
	bool pathKeySummarizedIgnore = false;
	return EnableRumCursorDynamicIndexScans &&
		   GetIndexKeyCurrentKeyFunc(relam, opfamily, &pathKeySummarizedIgnore) != NULL;
}


/*
 * Returns true when an ordered streaming index scan on the given index would be
 * unsafe and the dynamic cursor must fall back to a bitmap scan instead.
 *
 * An ordered index scan yields one row per matching index entry, in index
 * order, and does not de-duplicate row pointers. A multikey index has several
 * entries per document (one per array element or per matched field on a wildcard
 * index), and those entries can fall at different positions in the index
 * ordering. An ordered scan therefore emits a document more than once whenever
 * two or more of its entries qualify at different positions - for example an
 * unbounded or range predicate over a multikey path, a leading-column equality
 * with a multikey trailing column, or any predicate on a multikey wildcard
 * index. The streaming continuation only remembers a single (key, row pointer)
 * position, so it cannot suppress a document already returned at an earlier key.
 * A bitmap scan collects distinct row pointers and is therefore correct.
 *
 * The ordered scan is only allowed when the index is provably non-multikey. The
 * multikey status is read either from the fully tracked opclass metadata (the
 * "mkp" reloption) or from the term-based multikey status the index records by
 * default; both reliably report whether the index is multikey. When the index is
 * multikey (or its multikey state cannot be read at all), the cursor must use a
 * bitmap scan. Only indexes that support ordered operator scans (the composite
 * opclass) reach this check, so a non-composite index is never forced to bitmap
 * here.
 *
 * This safeguard can be disabled with the
 * enable_dynamic_cursor_multikey_bitmap GUC, in which case ordered scans are
 * allowed on multikey indexes (and may return duplicate documents).
 */
static bool
MultiKeyIndexRequiresBitmapScan(IndexOptInfo *indexInfo)
{
	if (!EnableDynamicCursorMultiKeyBitmap)
	{
		return false;
	}

	CompositeOpClassMetadataInfo metadataInfo = { 0 };
	CompositeOpClassMetadataReadResult readResult =
		TryGetCompositeOpClassMetadataInfo(indexInfo->indexoid, AccessShareLock,
										   &metadataInfo);

	bool orderedScanIsSafe =
		readResult != CompositeOpClassMetadataReadResult_None &&
		!metadataInfo.isMultiKey;

	return !orderedScanIsSafe;
}


static Path *
UpdateAndClassifyPath(Path *inputPath, PlannerInfo *root, RelOptInfo *rel,
					  uint64 collectionId, QueryScanType *scanType)
{
	*scanType = QueryScanType_Unknown;
	switch (inputPath->pathtype)
	{
		case T_IndexScan:
		{
			IndexPath *indexPath = (IndexPath *) inputPath;

			bool isPrimaryKeyPath = IsBtreePrimaryKeyIndex(
				indexPath->indexinfo);
			if (isPrimaryKeyPath)
			{
				*scanType = QueryScanType_PrimaryKeyScan;
			}
			else if (GetIndexSupportsGetIndexKey(indexPath->indexinfo->relam,
												 indexPath->indexinfo->opfamily[0]) &&
					 !MultiKeyIndexRequiresBitmapScan(indexPath->indexinfo))
			{
				/* Mark as supported indexscan */
				*scanType = QueryScanType_SecondaryIndexScan;
				AddOrderByRequiredClausesIfNecessary(indexPath, root, rel);
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

				*scanType = QueryScanType_SecondaryIndexBitmapScan;
			}

			return inputPath;
		}

		case T_IndexOnlyScan:
		{
			IndexPath *indexPath = (IndexPath *) inputPath;
			if (IsBtreePrimaryKeyIndex(indexPath->indexinfo))
			{
				/* Convert back to index scan to get cursors */
				inputPath->pathtype = T_IndexScan;
				*scanType = QueryScanType_PrimaryKeyScan;
			}
			else if (GetIndexSupportsGetIndexKey(indexPath->indexinfo->relam,
												 indexPath->indexinfo->opfamily[0]) &&
					 !MultiKeyIndexRequiresBitmapScan(indexPath->indexinfo))
			{
				/* IndexOnlyScan is always an ordered scan - nothing to do here */
				*scanType = QueryScanType_SecondaryIndexOnlyScan;
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

				*scanType = QueryScanType_SecondaryIndexBitmapScan;
			}

			return inputPath;
		}

		case T_BitmapHeapScan:
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

					*scanType = QueryScanType_PrimaryKeyScan;
				}
				else if (bitmapQualPath->pathtype == T_IndexOnlyScan)
				{
					if (GetIndexSupportsGetIndexKey(indexPath->indexinfo->relam,
													indexPath->indexinfo->opfamily[0]) &&
						!MultiKeyIndexRequiresBitmapScan(indexPath->indexinfo))
					{
						/* IndexOnlyScan is always an ordered scan - nothing to do here */
						*scanType = QueryScanType_SecondaryIndexOnlyScan;
						inputPath = (Path *) indexPath;
					}
					else
					{
						*scanType = QueryScanType_SecondaryIndexBitmapScan;
					}
				}
				else
				{
					Assert(bitmapQualPath->pathtype == T_IndexScan);
					if (GetIndexSupportsGetIndexKey(indexPath->indexinfo->relam,
													indexPath->indexinfo->opfamily[0]) &&
						!MultiKeyIndexRequiresBitmapScan(indexPath->indexinfo))
					{
						*scanType = QueryScanType_SecondaryIndexScan;
						AddOrderByRequiredClausesIfNecessary(indexPath, root, rel);
						inputPath = (Path *) indexPath;
					}
					else
					{
						*scanType = QueryScanType_SecondaryIndexBitmapScan;
					}
				}
			}
			else if (bitmapQualPath->pathtype == T_BitmapAnd)
			{
				/* In this path, we have a special case, we can get a bitmapAnd where there's
				 * one branch that is just shard_key_value = <value> - see
				 * OptimizeBitmapQualsForBitmapAnd in index_support.
				 */
				BitmapAndPath *bitmapAndPath = (BitmapAndPath *) bitmapQualPath;
				if (collectionId != 0)
				{
					Path *newPath = OptimizeAndTrimBitmapQualsForBitmapAnd(bitmapAndPath,
																		   collectionId);
					if (newPath != NULL && newPath != (Path *) bitmapAndPath)
					{
						/* the bitmapAnd path got optimized and replaced - reclassify the new path */
						return UpdateAndClassifyPath(newPath, root, rel, collectionId,
													 scanType);
					}
				}

				*scanType = QueryScanType_SecondaryIndexBitmapAnd;
			}
			else if (bitmapQualPath->pathtype == T_BitmapOr)
			{
				*scanType = QueryScanType_SecondaryIndexBitmapOr;
			}

			return inputPath;
		}

		case T_SeqScan:
		{
			/* See if we can convert to primary key scan */
			IndexOptInfo *info = GetPrimaryKeyIndexOptCore(rel);
			if (info != NULL)
			{
				inputPath = (Path *) create_index_path(
					root, info, NIL, NIL, NIL, NIL, ForwardScanDirection, false,
					rel->lateral_relids,
					1, false);
				*scanType = QueryScanType_PrimaryKeyScan;
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
				*scanType = QueryScanType_TidRangeScan;
			}

			return inputPath;
		}

		default:
		{
			*scanType = QueryScanType_Unknown;
			return inputPath;
		}
	}
}


static List *
WalkRelPathsAndCreateCustomPathsForFirstPage(PlannerInfo *root, RelOptInfo *rel,
											 DynamicCursorInputContinuation *
											 inputContinuation,
											 PathTarget *baseRelPathTarget,
											 uint64_t optCollectionId)
{
	List *customPlanPaths = NIL;
	ListCell *cell;

	/*
	 * When non-streaming paths are allowed ( i.e., per-collection
	 * statistics give the planner reliable cost estimates), skip the sort-based
	 * pruning below so every scan type stays a candidate. The custom path then
	 * advertises the pathkeys its inner path truly provides letting the planner
	 * add a runtime Sort where needed and pick the cheapest plan; the cursor type
	 * check in PlanDynamicQueryAndDetermineCursorType() falls back to a persistent
	 * cursor (file-based on remote shard) when the chosen plan needs a top-level sort.
	 */
	bool isOperatorSelectivityEnabled =
		EnablePlannerCostSelectivityFromRelOptInfo(root, rel);


	/* Walk the existing paths and wrap them in a custom scan */
	List *alternativePaths = NIL;
	foreach(cell, rel->pathlist)
	{
		Path *inputPath = lfirst(cell);

		inputContinuation->scanType = QueryScanType_Unknown;
		QueryScanType scanType = QueryScanType_Unknown;
		Path *originalPath = inputPath;
		inputPath = UpdateAndClassifyPath(inputPath, root, rel, optCollectionId,
										  &scanType);

		/*
		 * The scan feeding a streaming cursor must provide a deterministic
		 * ordering. For ORDER BY that ordering is sort_pathkeys; for a fully
		 * pushable $group (no ORDER BY) the GroupAggregate needs the index to
		 * provide the grouping order, i.e. group_pathkeys.
		 */
		List *orderingPathKeys = root->sort_pathkeys;
		if (orderingPathKeys == NIL && IsGroupByFullyPushableForStreaming(root))
		{
			orderingPathKeys = root->group_pathkeys;
		}

		if (orderingPathKeys != NIL)
		{
			bool isSupportedPath = scanType != QueryScanType_Unknown;
			switch (scanType)
			{
				case QueryScanType_SecondaryIndexScan:
				case QueryScanType_SecondaryIndexOnlyScan:
				{
					IndexPath *ipath = (IndexPath *) inputPath;
					if (list_length(ipath->indexorderbys) != list_length(
							orderingPathKeys))
					{
						/* The pathkeys required by the query are not provided by the index order by - we can't use this path for streaming */
						isSupportedPath = false;
					}
					break;
				}

				case QueryScanType_PrimaryKeyScan:
				{
					IndexPath *ipath = (IndexPath *) inputPath;

					/* By default we don't add orderby for _id indexes until after the query is fully optimized.
					 * We need to attempt that here before deciding to bail on the _id index.
					 */
					if (!EnableOrderByIdOnCostFunction &&
						list_length(root->query_pathkeys) == 1)
					{
						ConsiderBtreeOrderByPushdown(root, ipath);
					}

					if (list_length(ipath->path.pathkeys) != list_length(
							orderingPathKeys))
					{
						/* The pathkeys required by the query are not provided by the index order by - we can't use this path for streaming */
						isSupportedPath = false;
					}
					break;
				}

				default:
				{
					/* For other scan types, there is no pre-determined ordering - we can't stream these paths */
					isSupportedPath = false;
					break;
				}
			}

			if (!isSupportedPath)
			{
				if (isOperatorSelectivityEnabled)
				{
					/* If operator selectivity is enabled - then we can potentially still consider the original path for planning
					 * since it may be a better fit from a cost perspective.
					 */
					alternativePaths = lappend(alternativePaths, originalPath);
				}

				/* If operator selectivity is not enabled, only consider streaming plans */
				continue;
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

	if (list_length(customPlanPaths) > 0 && EnableDynamicPersistentCursorsWithStats)
	{
		/* If we created at least 1 streaming path and we have alternative paths to consider
		 * add them to the global paths (see comment above about operator selectivity).
		 * If no paths were added, return NIL still so that we return false back to the planner.
		 */
		customPlanPaths = list_concat(customPlanPaths, alternativePaths);
	}

	list_free(alternativePaths);
	return customPlanPaths;
}


/*
 * Returns true when the query's $group can be satisfied entirely from an
 * ordered index scan and is therefore eligible for a streaming dynamic cursor.
 * This mirrors the "order by keys are fully pushed down" reasoning: the
 * grouping keys must line up one-for-one with the query pathkeys so the index
 * ordering alone provides the grouping order. This holds whether or not the
 * $group carries accumulators ($sum/$max/...), because a sorted GroupAggregate
 * over ordered input emits only complete groups - the read-ahead never spans
 * more than the immediately following group.
 */
static bool
IsGroupByFullyPushableForStreaming(PlannerInfo *root)
{
	return EnableGroupByDynamicStreaming &&
		   root->group_pathkeys != NIL &&
		   root->query_pathkeys != NIL &&
		   list_length(root->group_pathkeys) == list_length(root->query_pathkeys);
}


static bool
IsPlannerInfoValidForDynamicCursorPlans(PlannerInfo *root)
{
	check_stack_depth();
	CHECK_FOR_INTERRUPTS();

	/*
	 * A GROUP BY whose group keys can be provided in order by an index can be
	 * streamed: the planner produces a sorted GroupAggregate (or Unique for a
	 * distinct-style group) over an ordered index scan, which emits one row per
	 * group without materializing the whole input. Allow such queries through
	 * (including those with accumulators) when the grouping order is fully
	 * pushable; the final plan shape is still validated at execution time by
	 * IsDynamicCustomScanPath(), which rejects blocking (hash) aggregates and
	 * top-level Sort nodes and falls back to a persistent cursor.
	 */
	bool allowGroupByPushdown = IsGroupByFullyPushableForStreaming(root);

	if (root->hasJoinRTEs || root->hasRecursion || root->hasLateralRTEs ||
		(root->group_pathkeys != NIL && !allowGroupByPushdown) ||
		root->distinct_pathkeys != NIL ||
		(root->agginfos != NIL && !allowGroupByPushdown) ||
		root->hasAlternativeSubPlans ||
		root->window_pathkeys != NIL || root->parse->hasTargetSRFs)
	{
		/* Use persisted cursors for these scenarios */
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

	if (root->parent_root != NULL &&
		!IsPlannerInfoValidForDynamicCursorPlans(root->parent_root))
	{
		/* In an unsupported subquery - use persisted cursors */
		return false;
	}

	return true;
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

	if (!IsClusterVersionAtleast(DocDB_V0, 112, 1))
	{
		ereport(ERROR, (errmsg(
							"Dynamic streaming cursors require cluster version at least 0.113.0")));
	}

	/* first look for a continuation function in the base quals */
	bool hasContinuation = false;
	pgbson *continuation = NULL;
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
										"Invalid dynamic cursor state provided - must have 2 arguments.")));
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
					secondArg = eval_const_expressions(NULL, secondArg);

					if (!IsA(secondArg, Const) && IsA(secondArg, CoerceViaIO))
					{
						Node *resolved = ResolveCoerceViaIOToConst(secondArg,
																   BsonTypeId());
						if (resolved != NULL)
						{
							secondArg = resolved;
						}
					}

					if (!IsA(secondArg, Const))
					{
						ereport(ERROR, (errmsg(
											"Invalid dynamic cursor state provided - must be a const value. found: %d",
											secondArg->type)));
					}
				}

				/* constvalue is safe to cast directly: the continuation is always
				 * generated internally by the query parser as an inline Datum,
				 * never as an external/TOAST'd value. */
				Const *constValue = (Const *) secondArg;
				continuation = (pgbson *) constValue->constvalue;
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

	if (!IsPlannerInfoValidForDynamicCursorPlans(root))
	{
		/* The planner info is not valid for dynamic cursor plans - use persisted */
		return false;
	}

	/*
	 * If any path is a merge-sort-in-prefix candidate, fall back to a persistent
	 * cursor. The marker is added during cost estimation and is only rewritten
	 * into a MergeAppend (and stripped) later in the relpathlist hook, after this
	 * runs -- so the marked path here still carries placeholder pathkeys that do
	 * not reflect a real streamable order. Streaming off it would be incorrect.
	 */
	if (EnableMergeSortForInPrefix)
	{
		foreach(cell, rel->pathlist)
		{
			Path *path = lfirst(cell);
			if (IsA(path, BitmapHeapPath))
			{
				BitmapHeapPath *bitmapPath = (BitmapHeapPath *) path;
				if (IsA(bitmapPath->bitmapqual, IndexPath))
				{
					path = (Path *) bitmapPath->bitmapqual;
				}
			}

			if (IsA(path, IndexPath) &&
				IndexPathHasMergeSortInPrefixMarker((IndexPath *) path))
			{
				return false;
			}
		}
	}

	/* Parse the continuation state */
	DynamicCursorInputContinuation inputContinuation = { 0 };
	inputContinuation.extensible.type = T_ExtensibleNode;
	inputContinuation.extensible.extnodename = InputContinuationNodeName;
	inputContinuation.queryTableId = rte->relid;
	inputContinuation.scanType = QueryScanType_Unknown;

	ParsedContinuationState tempState = { 0 };
	ParseContinuationDocument(continuation, &tempState);

	/* Extract the base rel for the query */
	Relation tableRel = RelationIdGetRelation(rte->relid);

	/* Point the nested scan's projection to the base table's projection */
	PathTarget *baseRelPathTarget = BuildBaseRelPathTarget(tableRel, rel->relid);

	/* Ensure you close the rel */
	RelationClose(tableRel);

	List *customPlanPaths = NIL;
	if (tempState.scanType != QueryScanType_Unknown)
	{
		/* Resuming from a prior query, use the continuation to form the scan */
		customPlanPaths = list_make1(GeneratePathFromContinuation(&tempState,
																  &inputContinuation,
																  root, rel, rte,
																  baseRelPathTarget,
																  context));
	}
	else
	{
		/* Walk the existing paths and wrap them in a custom scan */
		customPlanPaths = WalkRelPathsAndCreateCustomPathsForFirstPage(
			root, rel, &inputContinuation, baseRelPathTarget,
			context->inputData.collectionId);
	}

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
 * Builds the custom scan's output target list for the case where the node is a
 * transparent wrapper that passes its inner plan's columns straight through:
 * one Var per entry of sourceTlist, referencing the inner plan output.
 *
 * e.g. if the inner plan emits (document, object_id, shard_key_value), this
 * returns three Vars - Var(1,1)=document, Var(1,2)=object_id,
 * Var(1,3)=shard_key_value - forwarding those columns unchanged to the parent.
 */
static List *
BuildCursorScanPassThroughTargetList(List *sourceTlist)
{
	List *outputTargetEntries = NIL;
	ListCell *cell;
	foreach(cell, sourceTlist)
	{
		TargetEntry *tle = (TargetEntry *) lfirst(cell);
		Var *projVar = makeVar(1, tle->resno, exprType((Node *) tle->expr),
							   exprTypmod((Node *) tle->expr),
							   exprCollation((Node *) tle->expr), 0);
		TargetEntry *outputTle = makeTargetEntry((Expr *) projVar, tle->resno,
												 tle->resname, tle->resjunk);
		outputTargetEntries = lappend(outputTargetEntries, outputTle);
	}

	return outputTargetEntries;
}


/*
 * Given a scan path for the extension path, generates a
 * Custom Plan for the path. Note that the inner path
 * (e.g., Index scan etc. backing the cursor scan )is already
 * planned since it is listed as an inner_path in the custom path above.
 * This is roughly the same as custom_scan_continuation's behavior.
 *
 * Its main responsibility is deciding the node's scan.plan.targetlist
 * (the columns the custom scan outputs to its parent) and custom_scan_tlist
 * (the scan-tuple schema the node exposes).
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
	DynamicCursorInputContinuation *continuation =
		(DynamicCursorInputContinuation *) linitial(
			cscan->custom_private);
	if (tlist != NIL)
	{
		/*
		 * The planner already resolved this level's output columns against
		 * this path and handed them to us as a non-NIL tlist, so we adopt it
		 * verbatim - no projection to push down or pass-through Vars to
		 * synthesize.
		 *
		 * e.g. find({x: 1}) with no projection -> tlist is just the single
		 * `document` column.
		 */
		cscan->scan.plan.targetlist = tlist;
		cscan->custom_scan_tlist = nestedPlan->plan.targetlist;
	}
	else if (root->group_pathkeys != NIL || root->agginfos != NIL)
	{
		/*
		 * A grouping / aggregation node (and possibly a Sort) sits above the
		 * custom scan, so root->processed_tlist describes the *grouped* output
		 * - it references group keys and aggregates that this scan cannot
		 * produce. The custom scan is a transparent wrapper over its inner
		 * plan, so it simply passes through whatever columns the inner plan
		 * emits; the upper grouping node computes processed_tlist from those.
		 * Overwriting the inner plan's target list here (as the projection
		 * pushdown branch below does) would corrupt it and lead to a "variable
		 * not found in subplan target list" planner error.
		 */
		cscan->custom_scan_tlist = nestedPlan->plan.targetlist;
		cscan->scan.plan.targetlist = BuildCursorScanPassThroughTargetList(
			nestedPlan->plan.targetlist);
	}
	else if (continuation->scanType == QueryScanType_PrimaryKeyScan)
	{
		/* Here we need to project the object_id and shard_key_value
		 * from the table, and apply the projection at the custom scan layer.
		 * scanrelid is intentionally left unset (0): the PK scan path uses
		 * a custom_scan_tlist to pull columns from the inner plan, so the
		 * custom scan itself does not directly scan a relation.
		 *
		 * We can hand processed_tlist directly to the scan output (no
		 * pass-through rebuild) because its Vars already reference the inner
		 * plan's columns as it wraps a plain scan of the single base
		 * documents relation.
		 *
		 * Crucially, we do NOT overwrite the inner plan's target list here
		 * (unlike the default branch below). The PK cursor's continuation
		 * token is rebuilt by reading shard_key_value and object_id straight
		 * out of the scan tuple slot by position (tts_values[0]/[1] in
		 * WriteContinuationBasedOnScanTypeAndState). That only works if the
		 * inner plan keeps emitting the natural full base row in that order,
		 * so the projection is applied at the custom scan layer instead.
		 * Secondary/index-only scans don't need this: their continuation comes
		 * from the index scan descriptor (index key + heap TID), independent
		 * of the output tuple layout, so they can push projection down. */
		cscan->scan.plan.targetlist = root->processed_tlist;
		cscan->custom_scan_tlist = nestedPlan->plan.targetlist;
	}
	else
	{
		/*
		 * No grouping/aggregation node sits above this scan, so
		 * root->processed_tlist is exactly the columns this level must output,
		 * and every entry is an expression over the raw document that the scan
		 * itself can evaluate. So we push the projection down into the inner
		 * plan and pass its result straight through - unlike the grouping
		 * branch above, which must leave the inner plan untouched.
		 *
		 * e.g. {$project: {name: "$user.name"}} -> the inner scan computes
		 * name = document->'user'->'name' directly.
		 */
		nestedPlan->plan.targetlist = root->processed_tlist;

		cscan->custom_scan_tlist = root->processed_tlist;
		cscan->scan.plan.targetlist = BuildCursorScanPassThroughTargetList(
			root->processed_tlist);
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

	/* store continuation state */
	DynamicCursorInputContinuation *continuation =
		(DynamicCursorInputContinuation *) linitial(
			cscan->custom_private);

	scanState->scanType = continuation->scanType;
	scanState->tableOid = continuation->queryTableId;
	Uint64AsItemPointer(&scanState->userContinuationState,
						continuation->itemPointerAsUint64);
	scanState->indexContinuation = continuation->indexContinuation;

	/* Set the exec scan method */
	switch (scanState->scanType)
	{
		case QueryScanType_SecondaryIndexBitmapScan:
		case QueryScanType_SecondaryIndexBitmapAnd:
		case QueryScanType_SecondaryIndexBitmapOr:
		{
			/* For bitmap heap scans, we need to skip with continuations if there is one */
			if (ItemPointerIsValid(&scanState->userContinuationState))
			{
				scanState->execScanMethod =
					(ExecScanAccessMtd) ExtensionCursorScanNextWithContinuation;
			}
			else
			{
				scanState->execScanMethod =
					(ExecScanAccessMtd) ExtensionCursorScanNext;
			}

			break;
		}

		case QueryScanType_SecondaryIndexScan:
		case QueryScanType_SecondaryIndexOnlyScan:
		{
			if (ItemPointerIsValid(&scanState->userContinuationState))
			{
				scanState->execScanMethod =
					(ExecScanAccessMtd) ExtensionCursorScanNextWithIndexContinuation;
			}
			else
			{
				scanState->execScanMethod =
					(ExecScanAccessMtd) ExtensionCursorScanNext;
			}

			break;
		}

		default:
		{
			scanState->execScanMethod =
				(ExecScanAccessMtd) ExtensionCursorScanNext;
			break;
		}
	}

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
{
	ExtensionCursorScanState *extensionCursorScanState =
		(ExtensionCursorScanState *) node;

	switch (extensionCursorScanState->scanType)
	{
		case QueryScanType_PrimaryKeyScan:
		{
			ExplainPropertyText("cursorScanType", "Primary Key Scan", es);
			break;
		}

		case QueryScanType_SecondaryIndexScan:
		{
			ExplainPropertyText("cursorScanType", "Secondary Index Scan", es);
			break;
		}

		case QueryScanType_SecondaryIndexOnlyScan:
		{
			ExplainPropertyText("cursorScanType", "Secondary Index Only Scan", es);
			break;
		}

		case QueryScanType_SecondaryIndexBitmapScan:
		{
			ExplainPropertyText("cursorScanType", "Secondary Index Bitmap Scan", es);
			break;
		}

		case QueryScanType_SecondaryIndexBitmapAnd:
		{
			ExplainPropertyText("cursorScanType", "Secondary Index Bitmap AND Scan", es);
			break;
		}

		case QueryScanType_SecondaryIndexBitmapOr:
		{
			ExplainPropertyText("cursorScanType", "Secondary Index Bitmap OR Scan", es);
			break;
		}

		case QueryScanType_TidRangeScan:
		{
			ExplainPropertyText("cursorScanType", "TID Range Scan", es);
			break;
		}

		default:
		{
			break;
		}
	}

	if (node->ss.ps.instrument != NULL && node->ss.ps.instrument->ntuples2 > 0)
	{
		ExplainPropertyFloat("Skipped Tuples", "docs", node->ss.ps.instrument->ntuples2,
							 0, es);
	}

	ExplainOpenGroup("custom_scan", "IndexDetails", false, es);
	WalkAndExplainScanState((PlanState *) extensionCursorScanState->innerScanState, es);
	ExplainCloseGroup("custom_scan", "IndexDetails", false, es);
}


static TupleTableSlot *
ExtensionCursorScanExecCustomScan(CustomScanState *pstate)
{
	ExtensionCursorScanState *node = (ExtensionCursorScanState *) pstate;

	/*
	 * Call ExecScan with the next/recheck methods. This handles
	 * Post-processing for projections, custom filters etc.
	 */
	TupleTableSlot *returnSlot = ExecScan(&node->custom_scanstate.ss,
										  node->execScanMethod,
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


static TupleTableSlot *
ExtensionCursorScanNextWithIndexContinuation(CustomScanState *node)
{
	ExtensionCursorScanState *scanState =
		(ExtensionCursorScanState *) node;

	/* From the next round, just use the vanilla next function */
	scanState->execScanMethod = (ExecScanAccessMtd) ExtensionCursorScanNext;
	if (!ItemPointerIsValid(&scanState->userContinuationState))
	{
		return scanState->execScanMethod((ScanState *) node);
	}

	/* First check continuation state on the index */
	ScanState *ps = scanState->innerScanState;

	TupleTableSlot *slot = NULL;
	IndexScanDesc scanDesc = NULL;
	PGFunction skipTidsFunc = NULL;
	bool pathKeySummarizationForced = false;
	double numSkipped = 0;

	/*
	 * Dynamic cursor scans always use ForwardScanDirection. The comparison
	 * logic below relies on this: cmp > 0 means we've passed the
	 * continuation, cmp < 0 means we're before it.
	 */
	Assert(ScanDirectionIsForward(ps->ps.state->es_direction));

	while (true)
	{
		CHECK_FOR_INTERRUPTS();

		slot = ps->ps.ExecProcNode((PlanState *) ps);

		if (TupIsNull(slot))
		{
			return slot;
		}

		numSkipped++;
		if (scanDesc == NULL)
		{
			if (IsA(ps, IndexOnlyScanState))
			{
				IndexOnlyScanState *ioss = (IndexOnlyScanState *) ps;
				scanDesc = ioss->ioss_ScanDesc;
			}
			else
			{
				IndexScanState *iss = (IndexScanState *) ps;
				scanDesc = iss->iss_ScanDesc;
			}

			skipTidsFunc = GetSkipTidsOnCurrentEntryFunc(
				scanDesc->indexRelation->rd_rel->relam,
				scanDesc->indexRelation->
				rd_opfamily[0], &pathKeySummarizationForced);
		}

		Datum currentKey = DocumentDBRumGetCurrentIndexKey(scanDesc);
		bytea *currentKeyBytes = DatumGetByteaP(currentKey);

		const char *collation = NULL;
		bool isComparisonValidIgnore = false;
		int cmp = CompareSerializedBsonIndexTerms(currentKeyBytes,
												  scanState->indexContinuation,
												  collation, &isComparisonValidIgnore);
		if (cmp > 0)
		{
			/* We passed the continuation (continuation point got deleted) */
			break;
		}
		else if (cmp < 0)
		{
			/* Current entry is before the continuation in index order.
			 * This can happen when the AM's ordered scan starts from a
			 * lower bound that precedes the continuation key. Keep
			 * scanning forward until we reach or pass it. */
			continue;
		}

		/* Still at the same key - skip forward if TID < required TID
		 * We use the indexscan's TID here since we do not have HOT here.
		 * TODO: Revisit with HOT (since the Heap's TID can be disjoint from
		 * the index's TID in the case of HOT).
		 */
		if (ItemPointerCompare(&scanDesc->xs_heaptid,
							   &scanState->userContinuationState) >= 0)
		{
			/* We're at the target TID or after it - return this slot */
			break;
		}
		else if (skipTidsFunc != NULL && EnableRumDynamicIndexScansSkipToTid)
		{
			/* See if the index can push forward until the Block of the TID exclusive */
			DocumentDBRumSkipTidsForCurrentEntry(
				scanDesc, skipTidsFunc, pathKeySummarizationForced,
				&scanState->userContinuationState);
			continue;
		}
		else
		{
			/* Continue enumeration of tuples until we cross the target TID or entry */
			continue;
		}
	}

	if (node->ss.ps.instrument)
	{
		node->ss.ps.instrument->ntuples2 = numSkipped;
	}

	TupleTableSlot *ourSlot = node->ss.ss_ScanTupleSlot;
	return ExecCopySlot(ourSlot, slot);
}


static TupleTableSlot *
ExtensionCursorScanNextWithContinuation(CustomScanState *node)
{
	ExtensionCursorScanState *scanState =
		(ExtensionCursorScanState *) node;
	TupleTableSlot *slot = NULL;

	/* From the next round, just use the vanilla next function */
	scanState->execScanMethod = (ExecScanAccessMtd) ExtensionCursorScanNext;
	if (ItemPointerIsValid(&scanState->userContinuationState))
	{
		bool returnOnEquality = true;
		bool shouldContinue = false;
		double numSkipped = 0;
		slot = SkipWithUserContinuation(
			scanState->innerScanState, &scanState->userContinuationState,
			returnOnEquality, &shouldContinue, &numSkipped);
		if (node->ss.ps.instrument)
		{
			node->ss.ps.instrument->ntuples2 = numSkipped;
		}

		if (slot != NULL)
		{
			TupleTableSlot *ourSlot = node->ss.ss_ScanTupleSlot;
			return ExecCopySlot(ourSlot, slot);
		}
	}

	return ExtensionCursorScanNext(node);
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
	if (newNode->indexContinuation)
	{
		newNode->indexContinuation = DatumGetByteaPCopy(PointerGetDatum(
															newNode->indexContinuation));
	}
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

	char *targetStr;
	if (node->indexContinuation != NULL)
	{
		PG_USED_FOR_ASSERTS_ONLY uint64_t targetLength;
		int dataSize = VARSIZE_ANY_EXHDR(node->indexContinuation);
		int requiredSize = dataSize * 2 + 1; /* each byte is represented by 2 hex chars, plus null terminator */
		targetStr = (char *) palloc(requiredSize);
		targetLength = hex_encode((char *) VARDATA_ANY(node->indexContinuation), dataSize,
								  targetStr);
		Assert(targetLength == (uint64_t) (requiredSize - 1));
	}
	else
	{
		targetStr = pstrdup("");
	}
	WRITE_STRING_FIELD_VALUE(continuation, targetStr);
	pfree(targetStr);
}


/*
 * Function for reading DocumentDBApiScan node inverse of Out
 */
static void
ReadDynamicCursorInputContinuation(struct ExtensibleNode *node)
{
	const char *continuationHex = NULL;
	const char *token;
	int length;
	DynamicCursorInputContinuation *local_node = (DynamicCursorInputContinuation *) node;
	local_node->extensible.type = T_ExtensibleNode;
	local_node->extensible.extnodename = InputContinuationNodeName;

	READ_OID_FIELD(queryTableId);
	READ_INT32_FIELD(scanType);
	READ_UINT64_FIELD(itemPointerAsUint64);
	READ_STRING_FIELD_VALUE(continuationHex);

	if (continuationHex != NULL && strlen(continuationHex) > 0)
	{
		PG_USED_FOR_ASSERTS_ONLY uint64 written;
		length = strlen(continuationHex) / 2;
		bytea *buffer = (bytea *) palloc(length + VARHDRSZ);
		SET_VARSIZE(buffer, length + VARHDRSZ);

		char *writePtr = VARDATA(buffer);
		written = hex_decode(continuationHex, length, writePtr);
		Assert(written == (uint64) length);
		local_node->indexContinuation = buffer;
	}
	else
	{
		local_node->indexContinuation = NULL;
	}
}


static void
RecurseAndWriteBitmapContinuation(pgbson_array_writer *arrayWriter,
								  PlanState *planState)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	int numPlans;
	PlanState **bitmapPlans;

	if (IsA(planState, BitmapOrState))
	{
		BitmapOrState *bitmapOrState = (BitmapOrState *) planState;
		numPlans = bitmapOrState->nplans;
		bitmapPlans = bitmapOrState->bitmapplans;
	}
	else if (IsA(planState, BitmapAndState))
	{
		BitmapAndState *bitmapAndState = (BitmapAndState *) planState;
		numPlans = bitmapAndState->nplans;
		bitmapPlans = bitmapAndState->bitmapplans;
	}
	else if (IsA(planState, BitmapIndexScanState))
	{
		numPlans = 1;
		bitmapPlans = &planState;
	}
	else
	{
		/* MultiExecProcNode only supports IndexScanState, BitmapAndState, BitmapOrState, or HashState */
		/* HashState is not applicable here since that's only for a HashJoin. */
		ereport(ERROR, (errmsg("Unsupported bitmap scan type %d",
							   (int) planState->type)));
	}

	for (int i = 0; i < numPlans; i++)
	{
		if (IsA(bitmapPlans[i], BitmapIndexScanState))
		{
			BitmapIndexScanState *biss = (BitmapIndexScanState *) bitmapPlans[i];
			Oid indexOid = biss->biss_ScanDesc->indexRelation->rd_rel->oid;
			const char *indexName = get_rel_name(indexOid);
			PgbsonArrayWriterWriteUtf8(arrayWriter, indexName);
		}
		else
		{
			/* It's a nested bitmap And or Or state */
			RecurseAndWriteBitmapContinuation(arrayWriter, bitmapPlans[i]);
		}
	}
}


static void
WriteContinuationBasedOnScanTypeAndState(ScanState *ps, pgbson_writer *writer,
										 QueryScanType scanType)
{
	TupleTableSlot *planSlot = ps->ss_ScanTupleSlot;
	bool hasTid = false;
	if (ItemPointerIsValid(&planSlot->tts_tid))
	{
		/* ItemPointer is 6 bytes (4-byte BlockNumber + 2-byte OffsetNumber),
		 * so the uint64 representation always fits within int64 range. */
		ItemPointer tuple = &planSlot->tts_tid;
		uint64_t tupleValue = ItemPointerToUint64(tuple);
		PgbsonWriterAppendInt64(writer, "tid", 3, tupleValue);
		hasTid = true;
	}

	switch (scanType)
	{
		case QueryScanType_PrimaryKeyScan:
		{
			IndexScanState *iss = (IndexScanState *) ps;
			Oid indexOid = iss->iss_ScanDesc->indexRelation->rd_rel->oid;
			const char *indexName = get_rel_name(indexOid);
			PgbsonWriterAppendUtf8(writer, "idx", 3, indexName);
			if (planSlot->tts_nvalid <
				(int) DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER)
			{
				/* Ensure we've got some valid attributes */
				planSlot->tts_ops->getsomeattrs(planSlot,
												DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER);
			}

			int64_t shardKeyValue = DatumGetInt64(planSlot->tts_values[0]);
			pgbson *objectId = DatumGetPgBsonPacked(planSlot->tts_values[1]);

			pgbson_writer pkDoc;
			PgbsonWriterStartDocument(writer, "pk", 2, &pkDoc);
			PgbsonWriterAppendInt64(&pkDoc, "sk", 2, shardKeyValue);
			PgbsonWriterAppendDocument(&pkDoc, "id", 2, objectId);
			PgbsonWriterEndDocument(writer, &pkDoc);

			/* For primary key cursor scan track the direction of the scan */
			PgbsonWriterAppendInt32(writer, "dir", 3,
									((IndexScan *) ps->ps.plan)->indexorderdir);
			break;
		}

		case QueryScanType_SecondaryIndexBitmapScan:
		{
			BitmapHeapScanState *bitmapScanState = (BitmapHeapScanState *) ps;
			BitmapIndexScanState *biss =
				(BitmapIndexScanState *) bitmapScanState->ss.ps.lefttree;
			Oid indexOid = biss->biss_ScanDesc->indexRelation->rd_rel->oid;
			const char *indexName = get_rel_name(indexOid);
			PgbsonWriterAppendUtf8(writer, "idx", 3, indexName);
			break;
		}

		case QueryScanType_SecondaryIndexScan:
		case QueryScanType_SecondaryIndexOnlyScan:
		{
			Oid indexOid;
			IndexScanDesc scanDesc;
			if (IsA(ps, IndexOnlyScanState))
			{
				IndexOnlyScanState *ioss = (IndexOnlyScanState *) ps;
				indexOid = ioss->ioss_ScanDesc->indexRelation->rd_rel->oid;
				scanDesc = ioss->ioss_ScanDesc;
			}
			else
			{
				IndexScanState *iss = (IndexScanState *) ps;
				indexOid = iss->iss_ScanDesc->indexRelation->rd_rel->oid;
				scanDesc = iss->iss_ScanDesc;
			}

			if (!hasTid)
			{
				/* Index only scans may not set it if it loaded from the index,
				 * get it from the scanDesc.
				 */
				ItemPointer tuple = &scanDesc->xs_heaptid;
				uint64_t tupleValue = ItemPointerToUint64(tuple);
				PgbsonWriterAppendInt64(writer, "tid", 3, tupleValue);
			}

			const char *indexName = get_rel_name(indexOid);
			PgbsonWriterAppendUtf8(writer, "idx", 3, indexName);

			Datum currentKey = DocumentDBRumGetCurrentIndexKey(scanDesc);
			bytea *buffer = DatumGetByteaP(currentKey);
			bson_value_t bufferBinary = { 0 };
			bufferBinary.value_type = BSON_TYPE_BINARY;
			bufferBinary.value.v_binary.subtype = 0;
			bufferBinary.value.v_binary.data = (uint8_t *) VARDATA_ANY(buffer);
			bufferBinary.value.v_binary.data_len = VARSIZE_ANY_EXHDR(buffer);
			PgbsonWriterAppendValue(writer, "sik", 3, &bufferBinary);
			break;
		}

		case QueryScanType_SecondaryIndexBitmapOr:
		case QueryScanType_SecondaryIndexBitmapAnd:
		{
			BitmapHeapScanState *bitmapScanState = (BitmapHeapScanState *) ps;

			PlanState *lefttree = bitmapScanState->ss.ps.lefttree;
			pgbson_array_writer arrayWriter;

			/* We just need to write out the index names. Note that deduping
			 * and order don't matter as in the getMore we just ensure these indexes
			 * are picked. The scan order is determined by the fact that we have TID
			 * ordering of the matching tuples.
			 */
			PgbsonWriterStartArray(writer, "idxs", 4, &arrayWriter);
			RecurseAndWriteBitmapContinuation(&arrayWriter, lefttree);
			PgbsonWriterEndArray(writer, &arrayWriter);

			break;
		}

		default:
		{
			break;
		}
	}
}


static void
ParseContinuationDocument(pgbson *continuation, ParsedContinuationState *state)
{
	if (continuation == NULL)
	{
		return;
	}

	bson_iter_t reader;
	bson_value_t pkContinuation = { 0 };
	bson_value_t secondaryIndexContinuation = { 0 };
	state->indexScanDirection = ForwardScanDirection;
	PgbsonInitIterator(continuation, &reader);

	while (bson_iter_next(&reader))
	{
		const char *fieldName = bson_iter_key(&reader);
		switch (fieldName[0])
		{
			case 't':
			{
				switch (fieldName[1])
				{
					case 'i':
					{
						switch (fieldName[2])
						{
							case 'd':
							{
								Assert(fieldName[3] == '\0');
								int64_t tupleValue = bson_iter_int64(&reader);
								Uint64AsItemPointer(&state->userContinuationState,
													tupleValue);
								continue;
							}
						}

						continue;
					}

					case 'y':
					{
						if (strcmp(fieldName, "type") == 0)
						{
							state->scanType = (QueryScanType) bson_iter_int32(&reader);
						}
						continue;
					}

					case 'b':
					{
						if (strcmp(fieldName, "tbl") == 0)
						{
							const char *tableName = bson_iter_utf8(&reader, NULL);
							Oid tableOid = get_relname_relid(tableName,
															 ApiDataNamespaceOid());
							state->tableOid = tableOid;
						}

						continue;
					}

					default:
					{
						continue;
					}
				}
			}

			case 'i':
			{
				switch (fieldName[1])
				{
					case 'd':
					{
						if (strcmp(fieldName, "idx") == 0)
						{
							const char *indexName = bson_iter_utf8(&reader, NULL);
							Oid indexOid = get_relname_relid(indexName,
															 ApiDataNamespaceOid());
							state->indexOids = list_make1_oid(indexOid);
						}
						else if (strcmp(fieldName, "idxs") == 0)
						{
							bson_iter_t arrayReader;
							BsonValueInitIterator(bson_iter_value(&reader), &arrayReader);
							List *indexOids = NIL;
							while (bson_iter_next(&arrayReader))
							{
								const char *indexName = bson_iter_utf8(&arrayReader,
																	   NULL);
								Oid indexOid = get_relname_relid(indexName,
																 ApiDataNamespaceOid());
								indexOids = lappend_oid(indexOids, indexOid);
							}
							list_sort(indexOids, list_oid_cmp);

							state->indexOids = indexOids;
						}

						continue;
					}
				}

				continue;
			}

			case 'p':
			{
				if (strcmp(fieldName, "pk") == 0)
				{
					pkContinuation = *bson_iter_value(&reader);
				}

				continue;
			}

			case 's':
			{
				if (strcmp(fieldName, "sik") == 0)
				{
					secondaryIndexContinuation = *bson_iter_value(&reader);
				}

				continue;
			}

			case 'd':
			{
				if (strcmp(fieldName, "dir") == 0)
				{
					state->indexScanDirection = (ScanDirection) bson_iter_int32(&reader);

					if (!ScanDirectionIsValid(state->indexScanDirection))
					{
						ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR),
										errmsg(
											"Invalid scan direction in continuation document")));
					}
				}

				continue;
			}

			default:
			{
				continue;
			}
		}
	}

	switch (state->scanType)
	{
		case QueryScanType_PrimaryKeyScan:
		{
			if (pkContinuation.value_type != BSON_TYPE_DOCUMENT)
			{
				ereport(ERROR, (errmsg(
									"Invalid continuation provided - primary key continuation must be a document")));
			}

			bson_iter_t pkReader;
			BsonValueInitIterator(&pkContinuation, &pkReader);
			while (bson_iter_next(&pkReader))
			{
				const char *pkFieldName = bson_iter_key(&pkReader);
				if (strcmp(pkFieldName, "sk") == 0)
				{
					Datum shardKeyDatum = Int64GetDatum(bson_iter_int64(&pkReader));
					state->cursorDatums[0] = shardKeyDatum;
				}
				else if (strcmp(pkFieldName, "id") == 0)
				{
					pgbson *objectId = PgbsonInitFromDocumentBsonValue(bson_iter_value(
																		   &pkReader));
					Datum objectIdDatum = PointerGetDatum(objectId);
					state->cursorDatums[1] = objectIdDatum;
				}
			}

			break;
		}

		case QueryScanType_SecondaryIndexScan:
		case QueryScanType_SecondaryIndexOnlyScan:
		{
			if (secondaryIndexContinuation.value_type != BSON_TYPE_BINARY)
			{
				ereport(ERROR, (errmsg(
									"Invalid continuation provided - secondary index continuation must be binary")));
			}

			bytea *buffer = palloc(secondaryIndexContinuation.value.v_binary.data_len +
								   VARHDRSZ);
			SET_VARSIZE(buffer, secondaryIndexContinuation.value.v_binary.data_len +
						VARHDRSZ);
			memcpy(VARDATA(buffer), secondaryIndexContinuation.value.v_binary.data,
				   secondaryIndexContinuation.value.v_binary.data_len);
			Datum currentKey = PointerGetDatum(buffer);
			state->cursorDatums[0] = currentKey;
			break;
		}

		default:
		{
			break;
		}
	}
}


static Path *
PlanWithIndexAndGetPath(PlannerInfo *root, RelOptInfo *rel,
						ParsedContinuationState *state)
{
	List *indexList = NIL;
	ListCell *indexCell;
	foreach(indexCell, rel->indexlist)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, indexCell);
		if (list_member_oid(state->indexOids, index->indexoid))
		{
			indexList = lappend(indexList, index);
		}
	}

	if (indexList == NIL)
	{
		if (state->indexOids == NIL)
		{
			ereport(ERROR, (errmsg(
								"Continuation document is missing index information for bitmap scan")));
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
							errmsg("Cannot find indexes for continuation with index")));
		}
	}

	List *origIndexList = rel->indexlist;
	List *origPathList = rel->pathlist;
	rel->indexlist = indexList;
	rel->pathlist = NIL;

	create_index_paths(root, rel);

	if (rel->pathlist == NIL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
						errmsg(
							"Cannot find path for index for continuation with index OID")));
	}

	/* Save the newly generated paths before restoring the original lists,
	 * otherwise we'd read from the restored origPathList instead of the
	 * paths created by create_index_paths. */
	Path *finalPath = (Path *) linitial(rel->pathlist);

	rel->indexlist = origIndexList;
	rel->pathlist = origPathList;
	return finalPath;
}


static Path *
GeneratePathFromContinuation(ParsedContinuationState *state,
							 DynamicCursorInputContinuation *inputContinuation,
							 PlannerInfo *root, RelOptInfo *rel, RangeTblEntry *rte,
							 PathTarget *baseRelPathTarget,
							 ReplaceExtensionFunctionContext *indexContext)
{
	inputContinuation->scanType = state->scanType;
	inputContinuation->queryTableId = state->tableOid;
	switch (state->scanType)
	{
		case QueryScanType_PrimaryKeyScan:
		{
			/*
			 * Check if there's already a PK btree IndexPath in rel->pathlist.
			 * If so, reuse it and add the RowCompareExpr continuation clause,
			 * preserving any existing index conditions on the path.
			 * Otherwise, build a fresh PK path from scratch.
			 */
			IndexPath *existingPkPath = NULL;
			ListCell *cell;
			foreach(cell, rel->pathlist)
			{
				Path *currentPath = lfirst(cell);
				if (currentPath->pathtype == T_IndexScan)
				{
					IndexPath *indexPath = (IndexPath *) currentPath;
					if (IsBtreePrimaryKeyIndex(indexPath->indexinfo))
					{
						existingPkPath = indexPath;
						break;
					}
				}
				else if (currentPath->pathtype == T_BitmapHeapScan)
				{
					BitmapHeapPath *bitmapHeapPath = (BitmapHeapPath *) currentPath;
					if (IsA(bitmapHeapPath->bitmapqual, IndexPath) &&
						IsBtreePrimaryKeyIndex(
							((IndexPath *) bitmapHeapPath->bitmapqual)->indexinfo))
					{
						existingPkPath = (IndexPath *) bitmapHeapPath->bitmapqual;
						break;
					}
				}
			}

			IndexPath *inputPath = NULL;
			bool rowCompareInclusive = true;

			/*
			 * The resumed primary-key scan must maintain the same ordering the
			 * first page used. For ORDER BY that ordering comes from sort_pathkeys;
			 * for a fully pushable $group (no ORDER BY) it comes from group_pathkeys -
			 * sort_pathkeys is NULL in that case, so we must also push the index
			 * order-by when the grouping is streamable (mirrors the first-page logic in
			 * WalkRelPathsAndCreateCustomPathsForFirstPage).
			 */
			bool needsOrderingPushdown =
				root->sort_pathkeys != NIL ||
				IsGroupByFullyPushableForStreaming(root);
			if (existingPkPath != NULL)
			{
				if (needsOrderingPushdown && existingPkPath->path.pathkeys == NIL)
				{
					ConsiderBtreeOrderByPushdown(root, existingPkPath);
				}

				inputPath = AddRowCompareToExistingPrimaryKeyPath(root, rel,
																  existingPkPath,
																  state->cursorDatums,
																  rowCompareInclusive);
			}
			else
			{
				inputPath = GetPrimaryKeyContinuationIndexPath(root, rel,
															   state->cursorDatums,
															   state->indexScanDirection,
															   rowCompareInclusive);

				if (needsOrderingPushdown && inputPath->path.pathkeys == NIL)
				{
					ConsiderBtreeOrderByPushdown(root, inputPath);

					if (inputPath->indexscandir != state->indexScanDirection)
					{
						ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR),
										errmsg(
											"Index scan direction mismatch between prior pages and current plan")));
					}
				}
			}

			/* Trim restrict info clauses already satisfied by the index path */
			bool hasOtherClausesIgnore = false;
			inputPath = TrimIndexRestrictInfoForBtreePath(root, inputPath,
														  &hasOtherClausesIgnore);

			/* Since we've copied the indexrestrictinfo, we need to retrim the expressions here */
			if (inputPath->indexinfo->indrestrictinfo != rel->baserestrictinfo)
			{
				inputPath->indexinfo->indrestrictinfo =
					ReplaceExtensionFunctionOperatorsInRestrictionPaths(
						inputPath->indexinfo->indrestrictinfo, indexContext);
			}

			return (Path *) CreateCustomScanPathForStreaming(root, rel,
															 (Path *) inputPath,
															 inputContinuation,
															 baseRelPathTarget);
		}

		case QueryScanType_TidRangeScan:
		{
			/* Create a TIDRange scan against the relation resuming at the said TID
			 * Note: We can't resume if the table's OID changed.
			 */
			if (state->tableOid != inputContinuation->queryTableId)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
								errmsg(
									"Cannot resume a TID range scan since the table ID has changed.")));
			}

			ItemPointer tidLowerPointPointer = palloc0(sizeof(ItemPointerData));
			Const *tidLowerBoundConst = makeConst(TIDOID, -1, InvalidOid,
												  sizeof(ItemPointerData),
												  PointerGetDatum(
													  tidLowerPointPointer),
												  false,
												  false);
			*tidLowerPointPointer = state->userContinuationState;
			OpExpr *tidLowerBoundScan = (OpExpr *) make_opclause(
				TIDGreaterEqOperator, BOOLOID, false,
				(Expr *) makeVar(rel->relid, SelfItemPointerAttributeNumber,
								 TIDOID,
								 -1, InvalidOid, 0),
				(Expr *) tidLowerBoundConst, InvalidOid, InvalidOid);
			RestrictInfo *rinfo = make_simple_restrictinfo(root,
														   (Expr *)
														   tidLowerBoundScan);
			Path *inputPath = (Path *) create_tidrangescan_path(root, rel, list_make1(
																	rinfo),
																rel->lateral_relids);
			return (Path *) CreateCustomScanPathForStreaming(root, rel, inputPath,
															 inputContinuation,
															 baseRelPathTarget);
		}

		case QueryScanType_SecondaryIndexOnlyScan:
		case QueryScanType_SecondaryIndexScan:
		{
			/* Similar to index hints, here we set the index list to just the one with
			 * the index specified, and then build a bitmap heap path. We also set the TID
			 * in the continuation so that we can skip to the right page in the bitmap heap scan.
			 */
			inputContinuation->itemPointerAsUint64 = ItemPointerToUint64(
				&state->userContinuationState);
			inputContinuation->indexContinuation = DatumGetByteaP(state->cursorDatums[0]);
			if (state->tableOid != inputContinuation->queryTableId)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
								errmsg(
									"Cannot resume a secondary index scan since the table ID has changed.")));
			}

			ListCell *cell;
			IndexPath *resumePath = NULL;
			foreach(cell, rel->pathlist)
			{
				Path *currentPath = lfirst(cell);
				if (currentPath->pathtype == T_IndexScan ||
					currentPath->pathtype == T_IndexOnlyScan)
				{
					IndexPath *indexPath = (IndexPath *) currentPath;
					if (list_member_oid(state->indexOids, indexPath->indexinfo->indexoid))
					{
						resumePath = indexPath;
						break;
					}
				}
				else if (currentPath->pathtype == T_BitmapHeapScan)
				{
					BitmapHeapPath *bitmapHeapPath = (BitmapHeapPath *) currentPath;
					if (IsA(bitmapHeapPath->bitmapqual, IndexPath) &&
						list_member_oid(state->indexOids,
										((IndexPath *) bitmapHeapPath->bitmapqual)->
										indexinfo->indexoid))
					{
						resumePath = (IndexPath *) bitmapHeapPath->bitmapqual;
						break;
					}
				}
			}

			if (resumePath == NULL)
			{
				/* Here we need to plan a path that uses this index with that continuation */
				Path *finalPath = PlanWithIndexAndGetPath(root, rel, state);
				if (finalPath == NULL)
				{
					ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
									errmsg(
										"Cannot find path for index for continuation with index")));
				}

				if (IsA(finalPath, BitmapHeapPath))
				{
					BitmapHeapPath *bitmapHeapPath = (BitmapHeapPath *) finalPath;
					if (!IsA(bitmapHeapPath->bitmapqual, IndexPath))
					{
						ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
										errmsg(
											"Expected bitmap heap path to be qualified by an index path for continuation with index")));
					}

					resumePath = (IndexPath *) bitmapHeapPath->bitmapqual;
				}
				else if (IsA(finalPath, IndexPath))
				{
					resumePath = (IndexPath *) finalPath;
				}
				else
				{
					ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED), errmsg(
										"Expected path to be either an index path or a bitmap heap path for continuation with index")));
				}
			}

			/* An index that has become multikey (or whose multikey state is no
			 * longer tracked) since the first page cannot be resumed as an
			 * ordered stream: the ordered scan does not de-duplicate row
			 * pointers, so a document with several matching entries would be
			 * emitted more than once. The ordered and bitmap resume strategies
			 * consume rows in different orders, so the cursor cannot switch
			 * mid-stream. Kill the plan so the client restarts and re-classifies
			 * this index as a bitmap scan.
			 */
			if (MultiKeyIndexRequiresBitmapScan(resumePath->indexinfo))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
								errmsg(
									"Cannot resume an ordered scan on an index that is no longer eligible for an ordered scan.")));
			}

			/* Here we need to add the operators to skip based on continuation */
			AddContinuationQualsToIndexPath(root, rel, resumePath, state);

			/* Note: The query can change state across continuations (what started as an indexonlyscan
			 * can become indexscans and vice versa. Allow this to happen as writes happen since
			 * truncation state or addition of multikeys can change viability of indexonlyscan.
			 * Similarly, if the index loses arrays, it can become eligible for IXOS after a vacuum.
			 */
			if (resumePath->path.pathtype == T_IndexOnlyScan)
			{
				state->scanType = QueryScanType_SecondaryIndexOnlyScan;
			}
			else
			{
				state->scanType = QueryScanType_SecondaryIndexScan;
				AddOrderByRequiredClausesIfNecessary(resumePath, root, rel);
			}

			inputContinuation->scanType = state->scanType;
			return (Path *) CreateCustomScanPathForStreaming(root, rel,
															 (Path *) resumePath,
															 inputContinuation,
															 baseRelPathTarget);
		}

		case QueryScanType_SecondaryIndexBitmapScan:
		case QueryScanType_SecondaryIndexBitmapAnd:
		case QueryScanType_SecondaryIndexBitmapOr:
		{
			/* Similar to index hints, here we set the index list to just the one with
			 * the index specified, and then build a bitmap heap path. We also set the TID
			 * in the continuation so that we can skip to the right page in the bitmap heap scan.
			 */
			inputContinuation->itemPointerAsUint64 = ItemPointerToUint64(
				&state->userContinuationState);
			if (state->tableOid != inputContinuation->queryTableId)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
								errmsg(
									"Cannot resume a secondary index bitmap scan since the table ID has changed.")));
			}

			/* First check if any of the existing paths match the bitmap path */
			ListCell *indexCell;
			foreach(indexCell, rel->pathlist)
			{
				Path *currentPath = lfirst(indexCell);
				if (currentPath->pathtype == T_BitmapHeapScan)
				{
					BitmapHeapPath *bitmapHeapPath = (BitmapHeapPath *) currentPath;
					Path *bitmapQualPath = bitmapHeapPath->bitmapqual;

					if (bitmapQualPath->pathtype == T_IndexScan &&
						state->scanType == QueryScanType_SecondaryIndexBitmapScan)
					{
						IndexPath *indexPath = (IndexPath *) bitmapQualPath;
						if (list_member_oid(state->indexOids,
											indexPath->indexinfo->indexoid))
						{
							return (Path *) CreateCustomScanPathForStreaming(root, rel,
																			 (Path *)
																			 currentPath,
																			 inputContinuation,
																			 baseRelPathTarget);
						}
					}
					else if (bitmapQualPath->pathtype == T_BitmapAnd &&
							 state->scanType == QueryScanType_SecondaryIndexBitmapAnd)
					{
						return (Path *) CreateCustomScanPathForStreaming(root, rel,
																		 (Path *)
																		 currentPath,
																		 inputContinuation,
																		 baseRelPathTarget);
					}
					else if (bitmapQualPath->pathtype == T_BitmapOr &&
							 state->scanType == QueryScanType_SecondaryIndexBitmapOr)
					{
						return (Path *) CreateCustomScanPathForStreaming(root, rel,
																		 (Path *)
																		 currentPath,
																		 inputContinuation,
																		 baseRelPathTarget);
					}
				}
				else if ((currentPath->pathtype == T_IndexScan ||
						  currentPath->pathtype == T_IndexOnlyScan) &&
						 state->scanType == QueryScanType_SecondaryIndexBitmapScan)
				{
					IndexPath *indexPath = (IndexPath *) currentPath;
					if (list_member_oid(state->indexOids, indexPath->indexinfo->indexoid))
					{
						Path *bitmapHeapPath = (Path *) create_bitmap_heap_path(root, rel,
																				(Path *)
																				indexPath,
																				rel->
																				lateral_relids,
																				1.0,
																				0);
						return (Path *) CreateCustomScanPathForStreaming(root, rel,
																		 bitmapHeapPath,
																		 inputContinuation,
																		 baseRelPathTarget);
					}
				}
			}

			/* If we got here, we didn't find a bitmap or index path already created */
			Path *finalPath = PlanWithIndexAndGetPath(root, rel, state);
			if (IsA(finalPath, BitmapHeapPath))
			{
				return (Path *) CreateCustomScanPathForStreaming(root, rel,
																 (Path *) finalPath,
																 inputContinuation,
																 baseRelPathTarget);
			}
			else if (IsA(finalPath, IndexPath))
			{
				Path *bitmapHeapPath = (Path *) create_bitmap_heap_path(root, rel,
																		(Path *) finalPath,
																		rel->
																		lateral_relids,
																		1.0,
																		0);
				return (Path *) CreateCustomScanPathForStreaming(root, rel,
																 bitmapHeapPath,
																 inputContinuation,
																 baseRelPathTarget);
			}

			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED), errmsg(
								"Cannot create valid bitmap path for index for continuation with index")));
		}

		default:
		{
			ereport(ERROR, (errmsg("Unknown scantype for continuation %d",
								   state->scanType)));
		}
	}
}


inline static IndexClause *
MakeSimpleIndexClause(PlannerInfo *root, OpExpr *expr)
{
	RestrictInfo *rinfo = make_simple_restrictinfo(root, (Expr *) expr);

	IndexClause *iclause = makeNode(IndexClause);
	iclause->rinfo = rinfo;
	iclause->indexquals = list_make1(rinfo);
	iclause->lossy = false;
	iclause->indexcol = 0;
	iclause->indexcols = NIL;
	return iclause;
}


/*
 * For index scans with an order by, we need to add the order by expressions
 * as indexqual clauses on the path so that we enforce that the index does
 * an ordered scan. Otherwise, the index layer may choose a fast/regular scan
 * which may violate the assumptions made for ordered scans.
 */
static void
AddOrderByRequiredClausesIfNecessary(IndexPath *indexPath, PlannerInfo *root,
									 RelOptInfo *rel)
{
	if (indexPath->indexorderbys != NIL ||
		indexPath->path.pathtype == T_IndexOnlyScan)
	{
		/* Already going to be an ordered scan */
		return;
	}

	int8_t sortOrder = 0;
	const char *firstPath = GetCompositeFirstIndexPathAndSortOrder(
		indexPath->indexinfo->opclassoptions[0], &sortOrder);

	int varlevelsup = 0;
	Var *documentVar = makeVar(rel->relid, DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER,
							   BsonTypeId(), DOCUMENT_DATA_TABLE_DOCUMENT_VAR_TYPMOD,
							   DOCUMENT_DATA_TABLE_DOCUMENT_VAR_COLLATION, varlevelsup);
	OpExpr *expr = CreateFullScanOpExpr((Expr *) documentVar, firstPath, strlen(
											firstPath), sortOrder);

	IndexClause *iclause = MakeSimpleIndexClause(root, expr);
	indexPath->indexclauses = lappend(indexPath->indexclauses, iclause);
}


static void
AddContinuationQualsToIndexPath(PlannerInfo *root, RelOptInfo *rel, IndexPath *resumePath,
								ParsedContinuationState *state)
{
	if (state->cursorDatums[0] == (Datum) 0)
	{
		ereport(ERROR, (errmsg("Invalid continuation provided - missing cursor state")));
	}

	bytea *continuationBuffer = DatumGetByteaPP(state->cursorDatums[0]);

	/* We add this as a min operator on this index */
	const char *firstPath = GetCompositeFirstIndexPath(
		resumePath->indexinfo->opclassoptions[0]);
	pgbson_writer writer, childWriter;
	PgbsonWriterInit(&writer);
	PgbsonWriterStartDocument(&writer, firstPath, strlen(firstPath), &childWriter);

	bson_value_t bufferValue = { 0 };
	bufferValue.value_type = BSON_TYPE_BINARY;
	bufferValue.value.v_binary.subtype = 0;
	bufferValue.value.v_binary.data = (uint8_t *) continuationBuffer;
	bufferValue.value.v_binary.data_len = VARSIZE_ANY(continuationBuffer);
	PgbsonWriterAppendValue(&childWriter, "minIndexOp", 10, &bufferValue);
	PgbsonWriterEndDocument(&writer, &childWriter);
	pgbson *minIndexKeySpec = PgbsonWriterGetPgbson(&writer);

	int varlevelsup = 0;
	Var *documentVar = makeVar(rel->relid, DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER,
							   BsonTypeId(), DOCUMENT_DATA_TABLE_DOCUMENT_VAR_TYPMOD,
							   DOCUMENT_DATA_TABLE_DOCUMENT_VAR_COLLATION, varlevelsup);
	OpExpr *rangeExpr = (OpExpr *) make_opclause(BsonRangeMatchOperatorOid(), BOOLOID,
												 false,
												 (Expr *) documentVar,
												 (Expr *) MakeBsonConst(minIndexKeySpec),
												 InvalidOid, InvalidOid);
	rangeExpr->opfuncid = BsonRangeMatchFunctionId();

	IndexClause *iclause = MakeSimpleIndexClause(root, rangeExpr);
	resumePath->indexclauses = lappend(resumePath->indexclauses, iclause);
}
