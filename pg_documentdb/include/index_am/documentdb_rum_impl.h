/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/index_am/documentdb_rum_impl.h
 *
 * Common declarations for RUM specific implementation AM functions.
 *
 * These definitions should only be used by implementations of indexams
 * based on documentdb rum and should be reduced over time.
 *
 * DO NOT Include this header file otherwise or increase the visibility of these
 * functions to other parts of the codebase.  These are implementation details.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_RUM_IMPL_H
#define DOCUMENTDB_RUM_IMPL_H

#include <postgres.h>
#include <fmgr.h>
#include <access/amapi.h>
#include <nodes/pathnodes.h>

void extension_rumcostestimate_core(PlannerInfo *root, IndexPath *path, double
									loop_count,
									Cost *indexStartupCost, Cost *indexTotalCost,
									Selectivity *indexSelectivity,
									double *indexCorrelation,
									double *indexPages, IndexAmRoutine *coreRoutine,
									bool forceIndexPushdownCostToZero,
									bool enableCompositePlannerCosts,
									PGFunction orderedCostEstimateCoreFunc);


IndexScanDesc extension_rumbeginscan_core(Relation rel, int nkeys, int norderbys,
										  IndexAmRoutine *coreRoutine);
IndexScanDesc extension_documentdb_rumbeginscan_core(Relation rel, int nkeys, int
													 norderbys,
													 IndexAmRoutine *coreRoutine);

void extension_rumendscan_core(IndexScanDesc scan, IndexAmRoutine *coreRoutine);
void extension_rumrescan_core(IndexScanDesc scan, ScanKey scankey, int nscankeys,
							  ScanKey orderbys, int norderbys,
							  IndexAmRoutine *coreRoutine);

void extension_documentdb_rumrescan_core(IndexScanDesc scan, ScanKey scankey, int
										 nscankeys,
										 ScanKey orderbys, int norderbys,
										 IndexAmRoutine *coreRoutine);
int64 extension_rumgetbitmap_core(IndexScanDesc scan, TIDBitmap *tbm,
								  IndexAmRoutine *coreRoutine);
bool extension_rumgettuple_core(IndexScanDesc scan, ScanDirection direction,
								IndexAmRoutine *coreRoutine);


IndexBuildResult * extension_rumbuild_core(Relation heapRelation, Relation indexRelation,
										   struct IndexInfo *indexInfo,
										   IndexAmRoutine *coreRoutine,
										   PGFunction updateMultikeyStatus);


bool extension_ruminsert_core(Relation indexRelation,
							  Datum *values,
							  bool *isnull,
							  ItemPointer heap_tid,
							  Relation heapRelation,
							  IndexUniqueCheck checkUnique,
							  bool indexUnchanged,
							  struct IndexInfo *indexInfo,
							  IndexAmRoutine *coreRoutine,
							  PGFunction updateMultikeyStatus);


/*
 * Performs a lookup on the index to determine whether it currently tracks any
 * multi-key (array) entries, using the provided access-method routine to drive
 * the scan.
 */
bool CheckIndexHasArrays(Relation indexRelation, IndexAmRoutine *coreRoutine);


bool RumGetTruncationStatusCore(Relation indexRelation, IndexAmRoutine *coreRoutine);

/*
 * Performs a lookup on the index to determine whether it currently tracks any
 * correlated reduced terms, using the provided access-method routine to drive
 * the scan.
 */
bool CheckIndexHasReducedTerms(Relation indexRelation, IndexAmRoutine *coreRoutine);
#endif
