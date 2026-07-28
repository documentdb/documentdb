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
										  skipTidsFunc, ItemPointer
										  userContinuationState);
#endif
