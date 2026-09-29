/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/customscan/bson_custom_scan.h
 *
 *  Implementation of a custom scan plan.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_CUSTOM_SCAN_H
#define BSON_CUSTOM_SCAN_H

#include <optimizer/plancat.h>

struct ReplaceExtensionFunctionContext;
bool UpdatePathsWithExtensionStreamingCursorPlans(PlannerInfo *root, RelOptInfo *rel,
												  RangeTblEntry *rte, struct
												  ReplaceExtensionFunctionContext *context);

bool UpdatePathsWithDynamicStreamingCursorPlans(PlannerInfo *root, RelOptInfo *rel,
												RangeTblEntry *rte, struct
												ReplaceExtensionFunctionContext *context);

void UpdatePathsToForceRumIndexScanToBitmapHeapScan(PlannerInfo *root, RelOptInfo *rel);

Query * ReplaceCursorParamValues(Query *query, ParamListInfo boundParams);

void ValidateCursorCustomScanPlan(Plan *plan);

PathTarget * BuildBaseRelPathTarget(Relation tableRel, Index relIdIndex);

/* Dynamic scan methods */
bool IsDynamicCursorCustomPath(CustomPath *path);
bool IsDynamicCustomScanPath(Plan *plan, bool allowOffsetLimitNode);
bool IsCustomDistinctScanPath(CustomScan *plan);
Plan * GetCustomDistinctScanChildPlan(CustomScan *plan);
PlanState * GetCustomDistinctScanChildState(CustomScanState *scanState);
CustomScanState * GetDynamicStreamingCustomScanState(PlanState *planState,
													 bool *isGroupReadAhead);
pgbson * GetContinuationFromCustomScan(CustomScanState *scan);
#endif
