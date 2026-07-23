/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/index_am/documentdb_rum.h
 *
 * Common declarations for RUM specific helper functions.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_RUM_H
#define DOCUMENTDB_RUM_H

#include <fmgr.h>
#include <access/amapi.h>
#include <nodes/pathnodes.h>
#include "index_am/index_am_exports.h"


/* How to load the RUM library into the process */
typedef enum RumLibraryLoadOptions
{
	/* Apply no customizations - load the default RUM lib */
	RumLibraryLoadOption_None = 0,

	/* Prefer to load the custom documentdb_rum if available and fall back */
	RumLibraryLoadOption_PreferDocumentDBRum = 1,

	/* Require hte custom documentdb_rum */
	RumLibraryLoadOption_RequireDocumentDBRum = 2,
} RumLibraryLoadOptions;

extern RumLibraryLoadOptions DocumentDBRumLibraryLoadOption;
void LoadRumRoutine(void);

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

typedef List *(*BoundaryQualsSelectorFunc)(IndexPath *indexPath, int32_t *num_sa_scans);

void extension_rumcostestimate_core(PlannerInfo *root, IndexPath *path, double
									loop_count,
									Cost *indexStartupCost, Cost *indexTotalCost,
									Selectivity *indexSelectivity,
									double *indexCorrelation,
									double *indexPages, IndexAmRoutine *coreRoutine,
									bool forceIndexPushdownCostToZero,
									bool enableCompositePlannerCosts,
									PGFunction orderedCostEstimateCoreFunc);

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

bool RumGetTruncationStatus(Relation indexRelation);

struct ExplainState;
typedef struct pgbson_writer pgbson_writer;
void ExplainCompositeScan(IndexScanDesc scan, struct ExplainState *es);
void ExplainCompositeScanToWriter(IndexScanDesc scan, pgbson_writer *writer);
void ExplainRawCompositeScan(Relation index_rel, List *indexQuals, List *indexOrderBy,
							 ScanDirection indexScanDir, struct ExplainState *es);
void ExplainRawCompositeScanToWriter(Relation index_rel, List *indexQuals,
									 List *indexOrderBy,
									 ScanDirection indexScanDir, pgbson_writer *writer);

void ExplainRegularIndexScan(IndexScanDesc scan, struct ExplainState *es);
void ExplainRegularIndexScanToWriter(IndexScanDesc scan, pgbson_writer *writer);

void LogReportedIndexCosts(Oid relOid, struct ExplainState *es);
void ResetReportedIndexCosts(void);
void RecordCostEstimateForIndex(Oid indexOid, Oid relOid, Cost indexStartupCost,
								Cost indexTotalCost, Selectivity indexSelectivity,
								double indexCorrelation, double indexPages, double
								totalIndexPages, double totalIndexTuples,
								double boundarySelectivity,
								int numBoundaryQuals, double
								dataPagesProportionFetched);

Datum DocumentDBRumGetCurrentIndexKey(IndexScanDesc scan, bytea **dedupState);

void DocumentDBRumSkipTidsForCurrentEntry(IndexScanDesc scan, PGFunction
										  skipTidsFunc, bool pathKeySummarizationForced,
										  ItemPointer userContinuationState);
#endif
