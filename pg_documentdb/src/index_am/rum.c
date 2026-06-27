/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/index_am/rum.c
 *
 * Rum access method implementations for documentdb_api.
 * See also: https://www.postgresql.org/docs/current/gin-extensibility.html
 * See also: https://github.com/postgrespro/rum
 *
 *-------------------------------------------------------------------------
 */


#include <postgres.h>
#include <fmgr.h>
#include <utils/index_selfuncs.h>
#include <utils/selfuncs.h>
#include <utils/lsyscache.h>
#include <access/relscan.h>
#include <utils/rel.h>
#include "math.h"
#include <commands/explain.h>
#include <access/gin.h>
#include <parser/parsetree.h>
#include <optimizer/pathnode.h>

#if PG_VERSION_NUM >= 180000
#include <commands/explain_state.h>
#include <commands/explain_format.h>
#endif

#include "api_hooks.h"
#include "planner/mongo_query_operator.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "index_am/documentdb_rum.h"
#include "metadata/metadata_cache.h"
#include "opclass/bson_gin_composite_scan.h"
#include "index_am/index_am_utils.h"
#include "opclass/bson_gin_index_term.h"
#include "opclass/bson_gin_private.h"
#include "utils/documentdb_errors.h"
#include "planner/documentdb_planner.h"
#include "utils/error_utils.h"
#include "query/bson_dollar_selectivity.h"

extern bool ForceUseIndexIfAvailable;
extern bool DisableExtendedRumExplainPlans;
extern bool EnableExtendedExplainPlans;
extern bool EnableExplainScanIndexCosts;
extern bool EnableOrderByIndexTerm;
extern bool EnableIndexPathKeySummarization;

bool RumHasMultiKeyPaths = false;


/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */
extern BsonIndexAmEntry RumIndexAmEntry;
static bool loaded_rum_routine = false;
static bool loaded_documentdb_rum_routine = false;
static IndexAmRoutine rum_index_routine = { 0 };

static PGFunction rum_index_multi_key_update_func = NULL;

typedef enum IndexMultiKeyStatus
{
	IndexMultiKeyStatus_Unknown = 0,

	IndexMultiKeyStatus_HasArrays = 1,

	IndexMultiKeyStatus_HasNoArrays = 2
} IndexMultiKeyStatus;

typedef struct DocumentDBRumIndexState
{
	IndexScanDesc innerScan;

	ScanKeyData compositeKey;

	IndexMultiKeyStatus multiKeyStatus;

	bool hasCorrelatedReducedTerms;
} DocumentDBRumIndexState;


/* Collected data for index stats */
typedef struct IndexCostsData
{
	Oid indexOid;
	Oid relOid;
	Cost indexStartupCost;
	Cost indexTotalCost;
	Selectivity indexSelectivity;
	double indexCorrelation;
	double indexPages;
	double totalIndexPages;
	double totalIndexEntries;
	Selectivity boundarySelectivity;
	int numBoundaryQuals;
	double dataPagesProportionFetched;
} IndexCostsData;

extern Datum gin_bson_composite_path_extract_query(PG_FUNCTION_ARGS);

static bool IsIndexIsValidForQuery(IndexPath *path);
static bool MatchClauseWithIndexForFuncExpr(IndexPath *path, int32_t indexcol,
											Oid funcId, List *args);
static bool ValidateMatchForOrderbyQuals(IndexPath *path);

static bool IsTextIndexMatch(IndexPath *path);

static bool CheckIndexHasReducedTerms(Relation indexRelation,
									  IndexAmRoutine *coreRoutine);
static IndexMultiKeyStatus CheckIndexHasArrays(Relation indexRelation,
											   IndexAmRoutine *coreRoutine);

static IndexScanDesc extension_rumbeginscan(Relation rel, int nkeys, int norderbys);
static IndexScanDesc extension_documentdb_rumbeginscan(Relation rel, int nkeys, int
													   norderbys);
static void extension_rumendscan(IndexScanDesc scan);
static void extension_rumrescan(IndexScanDesc scan, ScanKey scankey, int nscankeys,
								ScanKey orderbys, int norderbys);
static void extension_documentdb_rumrescan(IndexScanDesc scan, ScanKey scankey, int
										   nscankeys,
										   ScanKey orderbys, int norderbys);
static int64 extension_amgetbitmap(IndexScanDesc scan,
								   TIDBitmap *tbm);
static bool extension_amgettuple(IndexScanDesc scan,
								 ScanDirection direction);
static IndexBuildResult * extension_rumbuild(Relation heapRelation,
											 Relation indexRelation,
											 struct IndexInfo *indexInfo);
static bool extension_ruminsert(Relation indexRelation,
								Datum *values,
								bool *isnull,
								ItemPointer heap_tid,
								Relation heapRelation,
								IndexUniqueCheck checkUnique,
								bool indexUnchanged,
								struct IndexInfo *indexInfo);

static void extension_rumcostestimate(PlannerInfo *root, IndexPath *path,
									  double loop_count,
									  Cost *indexStartupCost, Cost *indexTotalCost,
									  Selectivity *indexSelectivity,
									  double *indexCorrelation,
									  double *indexPages);
static IndexAmRoutine * GetRumIndexHandler(PG_FUNCTION_ARGS);

static Datum RumGetMultiKeyStatusSlow(PG_FUNCTION_ARGS);

static Datum (*rum_extract_tsquery_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsquery_consistent_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsvector_config_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsquery_pre_consistent_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsquery_distance_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_ts_join_pos_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_extract_tsvector_func)(PG_FUNCTION_ARGS) = NULL;


#define MAX_EXPLAIN_COSTS_SIZE 100
#define MAX_LOGGED_PLANS 8
static IndexCostsData IndexExplainCosts[MAX_EXPLAIN_COSTS_SIZE] = { 0 };
static int IndexExplainCostsIndex = 0;
const char *DocumentdbRumCorePath = "$libdir/pg_documentdb_extended_rum_core";

inline static void
EnsureRumLibLoaded(void)
{
	if (!loaded_rum_routine)
	{
		ereport(ERROR, (errmsg(
							"The rum library should be loaded as part of shared_preload_libraries - this is a bug")));
	}
}


typedef enum RumFunctionCatalog
{
	RumFunction_AmHandler = 0,
	RumFunction_ExtractTsQuery,
	RumFunction_TsQueryConsistent,
	RumFunction_Tsvector_Config,
	RumFunction_Tsquery_PreConsistent,
	RumFunction_Tsquery_Distance,
	RumFunction_Ts_Join_Pos,
	RumFunction_Extract_Tsvector,
	RumFunction_TryExplainRumIndex,
	RumFunction_RumGetMultiKeyStatus,
	RumFunction_RumGetOpClassMetadata,
	RumFunction_RumUpdateMultiKeyStatus,
	RumFunction_SetUnredactedLogHook,
	RumFunction_RumOrderedCostEstimate,
	RumFunction_GetCurrentIndexKey,
	RumFunction_SkipTidsForCurrentEntry,
	RumFunction_Max,
} RumFunctionCatalog;


static const char *RumFunctionArray[RumFunction_Max] =
{
	[RumFunction_AmHandler] = "rumhandler",
	[RumFunction_ExtractTsQuery] = "rum_extract_tsquery",
	[RumFunction_TsQueryConsistent] = "rum_tsquery_consistent",
	[RumFunction_Tsvector_Config] = "rum_tsvector_config",
	[RumFunction_Tsquery_PreConsistent] = "rum_tsquery_pre_consistent",
	[RumFunction_Tsquery_Distance] = "rum_tsquery_distance",
	[RumFunction_Ts_Join_Pos] = "rum_ts_join_pos",
	[RumFunction_Extract_Tsvector] = "rum_extract_tsvector",
	[RumFunction_TryExplainRumIndex] = "try_explain_rum_index",
	[RumFunction_RumGetMultiKeyStatus] = "rum_get_multi_key_status",
	[RumFunction_RumGetOpClassMetadata] = "rum_get_opclass_metadata",
	[RumFunction_RumUpdateMultiKeyStatus] = "rum_update_multi_key_status",
	[RumFunction_SetUnredactedLogHook] = "SetRumUnredactedLogEmitHook",
	[RumFunction_RumOrderedCostEstimate] = "RumOrderedCostEstimate",
	[RumFunction_GetCurrentIndexKey] = "documentdb_rum_get_current_index_key",
	[RumFunction_SkipTidsForCurrentEntry] = "documentdb_rum_skip_tids_on_current_entry",
};


static const char *DocumentDBRumFunctionArray[RumFunction_Max] =
{
	[RumFunction_AmHandler] = "documentdb_rumhandler",
	[RumFunction_ExtractTsQuery] = "documentdb_extended_rum_extract_tsquery",
	[RumFunction_TsQueryConsistent] = "documentdb_extended_rum_tsquery_consistent",
	[RumFunction_Tsvector_Config] = "documentdb_extended_rum_tsvector_config",
	[RumFunction_Tsquery_PreConsistent] =
		"documentdb_extended_rum_tsquery_pre_consistent",
	[RumFunction_Tsquery_Distance] = "documentdb_extended_rum_tsquery_distance",
	[RumFunction_Ts_Join_Pos] = "documentdb_extended_rum_ts_join_pos",
	[RumFunction_Extract_Tsvector] = "documentdb_extended_rum_extract_tsvector",
	[RumFunction_TryExplainRumIndex] = "try_explain_documentdb_rum_index",
	[RumFunction_RumGetMultiKeyStatus] = "documentdb_rum_get_multi_key_status",
	[RumFunction_RumGetOpClassMetadata] = "documentdb_rum_get_opclass_metadata",
	[RumFunction_RumUpdateMultiKeyStatus] = "documentdb_rum_update_multi_key_status",
	[RumFunction_SetUnredactedLogHook] = "DocumentDBSetRumUnredactedLogEmitHook",
	[RumFunction_RumOrderedCostEstimate] = "DocumentDBRumOrderedCostEstimate",
	[RumFunction_GetCurrentIndexKey] = "documentdb_rum_get_current_index_key",
	[RumFunction_SkipTidsForCurrentEntry] = "documentdb_rum_skip_tids_on_current_entry",
};


/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */
PG_FUNCTION_INFO_V1(extensionrumhandler);
PG_FUNCTION_INFO_V1(documentdb_rum_extract_tsquery);
PG_FUNCTION_INFO_V1(documentdb_rum_tsquery_consistent);
PG_FUNCTION_INFO_V1(documentdb_rum_tsvector_config);
PG_FUNCTION_INFO_V1(documentdb_rum_tsquery_pre_consistent);
PG_FUNCTION_INFO_V1(documentdb_rum_tsquery_distance);
PG_FUNCTION_INFO_V1(documentdb_rum_ts_join_pos);
PG_FUNCTION_INFO_V1(documentdb_rum_extract_tsvector);


extern void SetDocumentDBFunctionNames(const char *explainRumIndexFunc,
									   const char *getMultiKeyStatus,
									   const char *updateMultiKeyStatus,
									   const char *orderedCostEstimateFunc,
									   const char *getOpClassMetadataFunc);

static PGFunction RumOrderedCostEstimate = NULL;


/*
 * Register the access method for RUM as a custom index handler.
 * This allows us to create a 'custom' RUM index in the extension.
 * Today, this is temporary: This is needed until the RUM index supports
 * a custom configuration function proc for index operator classes.
 * By registering it here we maintain compatibility with existing GIN implementations.
 * Once we merge the RUM config changes into the mainline repo, this can be removed.
 */
Datum
extensionrumhandler(PG_FUNCTION_ARGS)
{
	IndexAmRoutine *indexRoutine = GetRumIndexHandler(fcinfo);
	PG_RETURN_POINTER(indexRoutine);
}


Datum
documentdb_rum_extract_tsquery(PG_FUNCTION_ARGS)
{
	EnsureRumLibLoaded();
	return rum_extract_tsquery_func(fcinfo);
}


Datum
documentdb_rum_tsquery_consistent(PG_FUNCTION_ARGS)
{
	EnsureRumLibLoaded();
	return rum_tsquery_consistent_func(fcinfo);
}


Datum
documentdb_rum_tsvector_config(PG_FUNCTION_ARGS)
{
	EnsureRumLibLoaded();
	return rum_tsvector_config_func(fcinfo);
}


Datum
documentdb_rum_tsquery_pre_consistent(PG_FUNCTION_ARGS)
{
	EnsureRumLibLoaded();
	return rum_tsquery_pre_consistent_func(fcinfo);
}


Datum
documentdb_rum_tsquery_distance(PG_FUNCTION_ARGS)
{
	EnsureRumLibLoaded();
	return rum_tsquery_distance_func(fcinfo);
}


Datum
documentdb_rum_ts_join_pos(PG_FUNCTION_ARGS)
{
	EnsureRumLibLoaded();
	return rum_ts_join_pos_func(fcinfo);
}


Datum
documentdb_rum_extract_tsvector(PG_FUNCTION_ARGS)
{
	EnsureRumLibLoaded();
	return rum_extract_tsvector_func(fcinfo);
}


void
SetDocumentDBFunctionNames(const char *explainRumIndexFunc,
						   const char *getMultiKeyStatus,
						   const char *updateMultiKeyStatus,
						   const char *orderedCostEstimateFunc,
						   const char *getOpClassMetadataFunc)
{
	RumFunctionArray[RumFunction_TryExplainRumIndex] = explainRumIndexFunc;
	RumFunctionArray[RumFunction_RumGetMultiKeyStatus] = getMultiKeyStatus;
	RumFunctionArray[RumFunction_RumUpdateMultiKeyStatus] = updateMultiKeyStatus;
	RumFunctionArray[RumFunction_RumOrderedCostEstimate] = orderedCostEstimateFunc;
	RumFunctionArray[RumFunction_RumGetOpClassMetadata] = getOpClassMetadataFunc;
}


static IndexAmRoutine *
GetRumIndexHandler(PG_FUNCTION_ARGS)
{
	IndexAmRoutine *indexRoutine = palloc0(sizeof(IndexAmRoutine));

	EnsureRumLibLoaded();
	*indexRoutine = rum_index_routine;

	/* add a new proc as a config prog. */
	/* Based on https://github.com/postgrespro/rum/blob/master/src/rumutil.c#L117 */
	/* AMsupport is the index of the largest support function. We point to the options proc */
	uint16 RUMNProcs = indexRoutine->amsupport;
	if (RUMNProcs < 11)
	{
		indexRoutine->amsupport = RUMNProcs + 1;

		/* register the user config proc number. */
		/* based on https://github.com/postgrespro/rum/blob/master/src/rum.h#L837 */
		/* RUMNprocs is the count, and the highest function supported */
		/* We set our config proc to be one above that */
		indexRoutine->amoptsprocnum = RUMNProcs + 1;
	}

	if (EnableIndexPathKeySummarization &&
		loaded_documentdb_rum_routine)
	{
		indexRoutine->ambeginscan = extension_documentdb_rumbeginscan;
		indexRoutine->amrescan = extension_documentdb_rumrescan;
	}
	else
	{
		indexRoutine->ambeginscan = extension_rumbeginscan;
		indexRoutine->amrescan = extension_rumrescan;
		indexRoutine->amgetbitmap = extension_amgetbitmap;
		indexRoutine->amgettuple = extension_amgettuple;
		indexRoutine->amendscan = extension_rumendscan;
	}

	indexRoutine->amcostestimate = extension_rumcostestimate;
	indexRoutine->ambuild = extension_rumbuild;
	indexRoutine->aminsert = extension_ruminsert;
	indexRoutine->amcanreturn = NULL;

	return indexRoutine;
}


void
LoadRumRoutine(void)
{
	bool missingOk = false;
	void **ignoreLibFileHandle = NULL;

	/* Load the rum handler function from the shared library
	 * Allow overrides via the documentdb_rum extension
	 */

	Datum (*rumhandler) (FunctionCallInfo);
	const char *rumLibPath;

	ereport(LOG, (errmsg("Loading RUM handler with DocumentDBRumLibraryLoadOption: %d",
						 DocumentDBRumLibraryLoadOption)));

	StaticAssertExpr(RumFunction_Max == sizeof(RumFunctionArray) /
					 sizeof(RumFunctionArray[0]),
					 "Mismatch between RumFunctionCatalog enum and RumFunctionArray size");
	StaticAssertExpr(RumFunction_Max == sizeof(DocumentDBRumFunctionArray) /
					 sizeof(DocumentDBRumFunctionArray[0]),
					 "Mismatch between RumFunctionCatalog enum and DocumentDBRumFunctionArray size");
	for (int i = 0; i < RumFunction_Max; i++)
	{
		if (DocumentDBRumFunctionArray[i] == NULL ||
			strlen(DocumentDBRumFunctionArray[i]) == 0)
		{
			ereport(PANIC, (errmsg(
								"DocumentDBRum Function must be defined for for index %d",
								i)));
		}

		if (RumFunctionArray[i] == NULL ||
			strlen(RumFunctionArray[i]) == 0)
		{
			ereport(PANIC, (errmsg("Rum Function must be defined for for index %d", i)));
		}
	}

	const char **functionCatalog;
	bool loadedDocumentDbRum = false;
	switch (DocumentDBRumLibraryLoadOption)
	{
		case RumLibraryLoadOption_RequireDocumentDBRum:
		{
			rumLibPath = DocumentdbRumCorePath;
			functionCatalog = DocumentDBRumFunctionArray;
			rumhandler = load_external_function(rumLibPath,
												functionCatalog[RumFunction_AmHandler],
												!missingOk,
												ignoreLibFileHandle);
			loadedDocumentDbRum = true;
			ereport(LOG, (errmsg(
							  "Loaded documentdb_rumhandler successfully via pg_documentdb_extended_rum")));
			break;
		}

		case RumLibraryLoadOption_PreferDocumentDBRum:
		{
			rumLibPath = DocumentdbRumCorePath;
			functionCatalog = DocumentDBRumFunctionArray;
			rumhandler = load_external_function(rumLibPath,
												functionCatalog[RumFunction_AmHandler],
												missingOk,
												ignoreLibFileHandle);
			if (rumhandler == NULL)
			{
				rumLibPath = "$libdir/rum";
				functionCatalog = RumFunctionArray;
				rumhandler = load_external_function(rumLibPath,
													functionCatalog[RumFunction_AmHandler],
													!missingOk,
													ignoreLibFileHandle);
				loadedDocumentDbRum = false;
				ereport(LOG,
						(errmsg(
							 "Loaded documentdb_rum handler successfully via rum as a fallback")));
			}
			else
			{
				loadedDocumentDbRum = true;
				ereport(LOG,
						(errmsg(
							 "Loaded documentdb_rumhandler successfully via pg_documentdb_extended_rum")));
			}

			break;
		}

		case RumLibraryLoadOption_None:
		{
			rumLibPath = "$libdir/rum";
			functionCatalog = RumFunctionArray;
			rumhandler = load_external_function(rumLibPath,
												functionCatalog[RumFunction_AmHandler],
												!missingOk,
												ignoreLibFileHandle);
			loadedDocumentDbRum = false;
			ereport(LOG, (errmsg("Loaded documentdb_rum handler successfully via rum")));
			break;
		}

		default:
		{
			ereport(ERROR, (errmsg("Unknown RUM library load option: %d",
								   DocumentDBRumLibraryLoadOption)));
		}
	}

	LOCAL_FCINFO(fcinfo, 0);

	InitFunctionCallInfoData(*fcinfo, NULL, 1, InvalidOid, NULL, NULL);
	Datum rumHandlerDatum = rumhandler(fcinfo);
	IndexAmRoutine *indexRoutine = (IndexAmRoutine *) DatumGetPointer(rumHandlerDatum);
	rum_index_routine = *indexRoutine;
	loaded_documentdb_rum_routine = loadedDocumentDbRum;

	/* Load required C functions */
	rum_extract_tsquery_func =
		load_external_function(rumLibPath, functionCatalog[RumFunction_ExtractTsQuery],
							   !missingOk,
							   ignoreLibFileHandle);
	rum_tsquery_consistent_func =
		load_external_function(rumLibPath, functionCatalog[RumFunction_TsQueryConsistent],
							   !missingOk,
							   ignoreLibFileHandle);
	rum_tsvector_config_func =
		load_external_function(rumLibPath, functionCatalog[RumFunction_Tsvector_Config],
							   !missingOk,
							   ignoreLibFileHandle);
	rum_tsquery_pre_consistent_func =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_Tsquery_PreConsistent],
							   !missingOk,
							   ignoreLibFileHandle);
	rum_tsquery_distance_func =
		load_external_function(rumLibPath, functionCatalog[RumFunction_Tsquery_Distance],
							   !missingOk,
							   ignoreLibFileHandle);
	rum_ts_join_pos_func =
		load_external_function(rumLibPath, functionCatalog[RumFunction_Ts_Join_Pos],
							   !missingOk,
							   ignoreLibFileHandle);
	rum_extract_tsvector_func =
		load_external_function(rumLibPath, functionCatalog[RumFunction_Extract_Tsvector],
							   !missingOk,
							   ignoreLibFileHandle);

	/* Load optional explain function */
	missingOk = true;
	PGFunction explain_index_func =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_TryExplainRumIndex],
							   !missingOk,
							   ignoreLibFileHandle);

	if (explain_index_func != NULL && !DisableExtendedRumExplainPlans)
	{
		RumIndexAmEntry.add_explain_output = explain_index_func;
	}

	PGFunction costEstimateFunc =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_RumOrderedCostEstimate],
							   !missingOk,
							   ignoreLibFileHandle);
	if (costEstimateFunc != NULL)
	{
		RumOrderedCostEstimate = costEstimateFunc;
	}

	void (*setRumUnredactedLogEmitHookFunc)(format_log_hook hook) = NULL;
	setRumUnredactedLogEmitHookFunc =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_SetUnredactedLogHook],
							   !missingOk,
							   ignoreLibFileHandle);

	if (setRumUnredactedLogEmitHookFunc != NULL)
	{
		setRumUnredactedLogEmitHookFunc(unredacted_log_emit_hook);
	}

	PGFunction rum_index_multi_key_get_func =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_RumGetMultiKeyStatus],
							   !missingOk,
							   ignoreLibFileHandle);
	if (rum_index_multi_key_get_func != NULL)
	{
		RumIndexAmEntry.get_multikey_status = rum_index_multi_key_get_func;
	}
	else
	{
		/* For backwards compatibility with public RUM, here we use the slow
		 * path and query the multi-key status
		 */
		RumIndexAmEntry.get_multikey_status = RumGetMultiKeyStatusSlow;
	}

	PGFunction rum_get_opclass_metadata_func =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_RumGetOpClassMetadata],
							   !missingOk,
							   ignoreLibFileHandle);
	if (rum_get_opclass_metadata_func != NULL)
	{
		RumIndexAmEntry.get_opclass_metadata = rum_get_opclass_metadata_func;
	}

	rum_index_multi_key_update_func =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_RumUpdateMultiKeyStatus],
							   !missingOk,
							   ignoreLibFileHandle);

	PGFunction getCurrentIndexKeyFunc =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_GetCurrentIndexKey],
							   !missingOk,
							   ignoreLibFileHandle);
	if (getCurrentIndexKeyFunc != NULL)
	{
		RumIndexAmEntry.get_current_index_key = getCurrentIndexKeyFunc;
	}

	PGFunction skipTidsFunc =
		load_external_function(rumLibPath,
							   functionCatalog[RumFunction_SkipTidsForCurrentEntry],
							   !missingOk,
							   ignoreLibFileHandle);
	if (skipTidsFunc != NULL)
	{
		RumIndexAmEntry.skip_tids_on_current_entry = skipTidsFunc;
	}

	ereport(LOG, (errmsg(
					  "rum library has update func %d, get func %d, cost estimate func %d",
					  rum_index_multi_key_update_func != NULL,
					  rum_index_multi_key_get_func != NULL,
					  RumOrderedCostEstimate != NULL)));
	loaded_rum_routine = true;
	pfree(indexRoutine);
}


/*
 * Custom cost estimation function for RUM.
 * While Function support handles matching against specific indexes
 * and ensuring pushdowns happen properly (see dollar_support),
 * There is one case that is not yet handled.
 * If an index has a predicate (partial index), and the *only* clauses
 * in the query are ones that match the predicate, indxpath.create_index_paths
 * creates quals that exclude the predicate. Consequently we're left with no clauses.
 * Because RUM also sets amoptionalkey to true (the first key in the index is not required
 * to be specified), we will still continue to consider the index (per useful_predicate in
 * build_index_paths). In this case, we need to check that at least one predicate matches the
 * index for the index to be considered.
 */
static void
extension_rumcostestimate(PlannerInfo *root, IndexPath *path, double loop_count,
						  Cost *indexStartupCost, Cost *indexTotalCost,
						  Selectivity *indexSelectivity, double *indexCorrelation,
						  double *indexPages)
{
	bool enableCompositePlannerCosts = EnablePlannerCostSelectivityFromRelOptInfo(root,
																				  path->
																				  indexinfo
																				  ->rel);
	bool forceIndexPushdownCostToZero = !enableCompositePlannerCosts &&
										ForceUseIndexIfAvailable;
	extension_rumcostestimate_core(root, path, loop_count, indexStartupCost,
								   indexTotalCost,
								   indexSelectivity, indexCorrelation, indexPages,
								   &rum_index_routine, forceIndexPushdownCostToZero,
								   enableCompositePlannerCosts, RumOrderedCostEstimate);
}


void
extension_rumcostestimate_core(PlannerInfo *root, IndexPath *path, double loop_count,
							   Cost *indexStartupCost, Cost *indexTotalCost,
							   Selectivity *indexSelectivity, double *indexCorrelation,
							   double *indexPages, IndexAmRoutine *coreRoutine,
							   bool forceIndexPushdownCostToZero, bool
							   enableCompositePlannerCosts,
							   PGFunction orderedCostEstimateCoreFunc)
{
	if (!IsIndexIsValidForQuery(path))
	{
		/* This index is not a match for the given query paths */
		/* In this code path, we set the total cost to infinity */
		/* As the planner walks through all other plans, one will be less */
		/* than infinity (the SeqScan) which will be picked in the worst case */
		*indexStartupCost = 0;
		*indexTotalCost = INFINITY;
		*indexSelectivity = 0;
		*indexCorrelation = 0;
		*indexPages = 0;
		return;
	}

	double totalNumTuples = 0;
	Selectivity boundarySelectivity = 0;
	int numBoundaryQuals = 0;
	double dataPagesProportionFetched = 0;
	bool convertedToIndexOnlyScan = false;

	bool isCompositeOpFamily = IsCompositeOpFamilyOid(path->indexinfo->relam,
													  path->indexinfo->opfamily[0]);
	if (isCompositeOpFamily)
	{
		bool canSupportIndexOnlyScan = false;
		bool firstColumnSpecified = TraverseIndexPathForCompositeIndex(path, root,
																	   &
																	   canSupportIndexOnlyScan);

		/* Even if the first column was not specified and the index covers the query entirely we should consider doing
		 * an index-only scan even though the cost will be set to INFINITY. This way we support index only scan when hinting is used and the first column is not part of the filters. */
		if (canSupportIndexOnlyScan && path->path.pathtype != T_IndexOnlyScan)
		{
			/* We copy the index opt info to a new allocated memory as we can't modify
			 * memory we don't own, we should let PG handle that memory. */
			IndexOptInfo *oldIndexInfo = path->indexinfo;
			path->indexinfo = (IndexOptInfo *) palloc(sizeof(IndexOptInfo));
			memcpy(path->indexinfo, oldIndexInfo, sizeof(IndexOptInfo));

			path->indexinfo->canreturn = palloc0(sizeof(bool) *
												 path->indexinfo->
												 ncolumns);
			path->indexinfo->canreturn[0] = true;

			path->path.pathtype = T_IndexOnlyScan;
			convertedToIndexOnlyScan = true;
		}

		/* If this is a composite index, then we need to ensure that
		 * the first column of the index matches the query path.
		 * This is because using the composite index would require specifying
		 * the first column.
		 */
		if (!firstColumnSpecified)
		{
			*indexStartupCost = 0;
			*indexTotalCost = INFINITY;
			*indexSelectivity = 0;
			*indexCorrelation = 0;
			*indexPages = 0;
			return;
		}
	}

	if (enableCompositePlannerCosts &&
		orderedCostEstimateCoreFunc != NULL && isCompositeOpFamily)
	{
		LOCAL_FCINFO(fcinfo, 13);
		memset(fcinfo->args, 0, sizeof(NullableDatum) * 13);
		fcinfo->args[0].value = PointerGetDatum(root);
		fcinfo->args[1].value = PointerGetDatum(path);
		fcinfo->args[2].value = Float8GetDatum(loop_count);
		fcinfo->args[3].value = PointerGetDatum(indexStartupCost);
		fcinfo->args[4].value = PointerGetDatum(indexTotalCost);
		fcinfo->args[5].value = PointerGetDatum(indexSelectivity);
		fcinfo->args[6].value = PointerGetDatum(indexCorrelation);
		fcinfo->args[7].value = PointerGetDatum(indexPages);
		fcinfo->args[8].value = PointerGetDatum(&totalNumTuples);
		fcinfo->args[9].value = PointerGetDatum(&boundarySelectivity);
		fcinfo->args[10].value = PointerGetDatum(&numBoundaryQuals);
		fcinfo->args[11].value = PointerGetDatum(&dataPagesProportionFetched);
		fcinfo->args[12].value = PointerGetDatum(ExtractBoundaryQualsForOrderedIndexPath);

		InitFunctionCallInfoData(*fcinfo, NULL, 13, InvalidOid, NULL, NULL);
		orderedCostEstimateCoreFunc(fcinfo);
	}
	else
	{
		totalNumTuples = path->indexinfo->tuples;
		coreRoutine->amcostestimate(
			root, path, loop_count, indexStartupCost, indexTotalCost,
			indexSelectivity, indexCorrelation, indexPages);
		boundarySelectivity = *indexSelectivity;
	}

	/* Do a pass to check for text indexes (We force push down with cost == 0) */
	if (IsTextIndexMatch(path))
	{
		*indexTotalCost = 0;
		*indexStartupCost = 0;
	}
	else if (forceIndexPushdownCostToZero)
	{
		*indexTotalCost = 0;
		*indexStartupCost = 0;
	}

	if (convertedToIndexOnlyScan)
	{
		/*
		 * We convert this path to T_IndexOnlyScan inside the AM cost callback.
		 * At that point, PostgreSQL's cost_index() has already taken the is-index-only
		 * decision for this costing pass, so cost_index() does not apply its usual allvisfrac
		 * adjustment here. We apply the same visibility-fraction adjustment in this
		 * callback to approximate index-only scan costing for this pass.
		 */
		*indexSelectivity = *indexSelectivity * (1.0 - path->indexinfo->rel->allvisfrac);
	}

	if (EnableExplainScanIndexCosts && EnableExtendedExplainPlans &&
		enableCompositePlannerCosts)
	{
		RangeTblEntry *rte = planner_rt_fetch(path->indexinfo->rel->relid, root);
		RecordCostEstimateForIndex(path->indexinfo->indexoid,
								   rte->relid,
								   *indexStartupCost,
								   *indexTotalCost,
								   *indexSelectivity, *indexCorrelation, *indexPages,
								   path->indexinfo->pages, totalNumTuples,
								   boundarySelectivity, numBoundaryQuals,
								   dataPagesProportionFetched);
	}
}


/* Check if the index supports index-only scans based on the index rel am. */
bool
CompositeIndexSupportsIndexOnlyScan(const IndexPath *indexPath)
{
	PGFunction getMultiKeyStatusFunc = NULL;
	GetTruncationStatusFunc getTruncationStatusFunc = NULL;
	PGFunction getOpclassMetadataFunc = NULL;

	bool supports = GetIndexAmSupportsIndexOnlyScan(indexPath->indexinfo->relam,
													indexPath->indexinfo->opfamily[0],
													&getMultiKeyStatusFunc,
													&getTruncationStatusFunc,
													&getOpclassMetadataFunc);

	if (!supports || getMultiKeyStatusFunc == NULL || getTruncationStatusFunc == NULL)
	{
		/* If the index does not support index only scan, return false */
		return false;
	}

	if (indexPath->indexinfo->opclassoptions == NULL)
	{
		return false;
	}

	BsonGinIndexOptionsBase *options =
		(BsonGinIndexOptionsBase *) indexPath->indexinfo->opclassoptions[0];
	if (options->type != IndexOptionsType_Composite)
	{
		return false;
	}

	BsonGinCompositePathOptions *compositeOptions =
		(BsonGinCompositePathOptions *) options;
	if (compositeOptions->wildcardPathIndex >= 0)
	{
		/* Wildcard indexes don't support index only scans for now.
		 * This is because wildcard indexes don't index documents and so we don't have full
		 * fidelity recreation of index terms.
		 * We can technically do better if the filter ranges don't overlap with nulls, arrays
		 * and documents but that needs to be considered as part of the cost function +
		 * order by integration.
		 */
		return false;
	}

	bool multiKeyStatus = false;
	bool hasTruncatedTerms = false;
	Relation indexRelation = index_open(indexPath->indexinfo->indexoid, NoLock);

	if (compositeOptions->enableMetadataBasedTracking && getOpclassMetadataFunc != NULL)
	{
		uint32_t multiKeyPerPathStatus = 0;
		bool hasReducedCorrelatedTerms = false;
		uint64_t opclassMetadata = DatumGetUInt64(DirectFunctionCall1(
													  getOpclassMetadataFunc,
													  PointerGetDatum(indexRelation)));
		DecodeCompositeOpClassQueryMetadata(options, opclassMetadata, &multiKeyStatus,
											&multiKeyPerPathStatus,
											&hasReducedCorrelatedTerms,
											&hasTruncatedTerms);
	}
	else
	{
		multiKeyStatus = DatumGetBool(DirectFunctionCall1(getMultiKeyStatusFunc,
														  PointerGetDatum(
															  indexRelation)));
		hasTruncatedTerms = getTruncationStatusFunc(indexRelation);
	}

	index_close(indexRelation, NoLock);

	/* can only support index only scan if the index is not multikey and there are no truncated terms. */
	return !multiKeyStatus && !hasTruncatedTerms;
}


/*
 * Validates whether an index path descriptor
 * can be satisfied by the current index.
 */
static bool
IsIndexIsValidForQuery(IndexPath *path)
{
	if (IsA(path, IndexOnlyScan))
	{
		/* We don't support index only scans in RUM */
		return false;
	}

	if (path->indexorderbys != NIL &&
		!ValidateMatchForOrderbyQuals(path))
	{
		/* Only return valid cost if the order by present
		 * matches the index fully
		 */
		return false;
	}

	if (list_length(path->indexclauses) >= 1)
	{
		/* if there's at least one other index clause,
		 * then this index is already valid
		 */
		return true;
	}

	if (path->indexinfo->indpred == NIL)
	{
		/*
		 * if the index is not a partial index, the useful_predicate
		 * clause does not apply. If there's no filter clauses, we
		 * can't really use this index (don't wanna do a full index scan)
		 */
		return false;
	}

	if (path->indexinfo->indpred != NIL)
	{
		ListCell *cell;
		foreach(cell, path->indexinfo->indpred)
		{
			Node *predQual = (Node *) lfirst(cell);

			/* walk the index predicates and check if they match the index */
			/* TODO: Do we need a query walk here */
			if (IsA(predQual, OpExpr))
			{
				OpExpr *expr = (OpExpr *) predQual;
				for (int32_t indexCol = 0; indexCol < path->indexinfo->nkeycolumns;
					 indexCol++)
				{
					if (MatchClauseWithIndexForFuncExpr(path, indexCol, expr->opfuncid,
														expr->args))
					{
						return true;
					}
				}
			}
			else if (IsA(predQual, FuncExpr))
			{
				FuncExpr *expr = (FuncExpr *) predQual;
				for (int32_t indexCol = 0; indexCol < path->indexinfo->nkeycolumns;
					 indexCol++)
				{
					if (MatchClauseWithIndexForFuncExpr(path, indexCol, expr->funcid,
														expr->args))
					{
						return true;
					}
				}
			}
		}
	}

	return false;
}


/* Given an operator expression and an index column with an index
 * Validates whether that operator + column is supported in this index */
static bool
MatchClauseWithIndexForFuncExpr(IndexPath *path, int32_t indexcol, Oid funcId, List *args)
{
	Node *operand = (Node *) lsecond(args);

	/* not a const - can't evaluate this here */
	if (!IsA(operand, Const))
	{
		return true;
	}

	/* if no options - thunk to default cost estimation */
	bytea *options = path->indexinfo->opclassoptions[indexcol];
	if (options == NULL)
	{
		return true;
	}

	BsonIndexStrategy strategy = GetBsonStrategyForFuncId(funcId);
	if (strategy == BSON_INDEX_STRATEGY_INVALID)
	{
		return false;
	}

	Datum queryValue = ((Const *) operand)->constvalue;
	return ValidateIndexForQualifierValue(options, queryValue, strategy);
}


/*
 * ValidateMatchForOrderbyQuals walks the order by operator
 * clauses and ensures that every clause is valid for the
 * current index.
 */
static bool
ValidateMatchForOrderbyQuals(IndexPath *path)
{
	ListCell *orderbyCell;
	int index = 0;
	foreach(orderbyCell, path->indexorderbys)
	{
		Expr *orderQual = (Expr *) lfirst(orderbyCell);

		/* Order by on RUM only supports OpExpr clauses */
		if (!IsA(orderQual, OpExpr))
		{
			return false;
		}

		/* Validate that it's a supported operator */
		OpExpr *opQual = (OpExpr *) orderQual;
		if (EnableOrderByIndexTerm &&
			opQual->opfuncid != BsonOrderByFunctionOid() &&
			opQual->opfuncid != BsonOrderByIndexFunctionOid() &&
			opQual->opfuncid != BsonOrderByIndexWithCollationFunctionOid() &&
			opQual->opfuncid != BsonOrderByIndexWithCollationReverseFunctionOid() &&
			opQual->opfuncid != BsonOrderByIndexReverseFunctionOid())
		{
			return false;
		}
		else if (opQual->opfuncid != BsonOrderByFunctionOid())
		{
			return false;
		}

		/* OpExpr for order by always has 2 args */
		Assert(list_length(opQual->args) == 2);
		Expr *secondArg = lsecond(opQual->args);
		if (!IsA(secondArg, Const))
		{
			return false;
		}

		Const *secondConst = (Const *) secondArg;
		int indexColInt = list_nth_int(path->indexorderbycols, index);
		bytea *options = path->indexinfo->opclassoptions[indexColInt];
		if (options == NULL)
		{
			return false;
		}

		/* Validate that the path can be pushed to the index. */
		if (!ValidateIndexForQualifierValue(options, secondConst->constvalue,
											BSON_INDEX_STRATEGY_DOLLAR_ORDERBY))
		{
			return false;
		}

		index++;
	}

	return true;
}


/*
 * Returns true if the IndexPath corresponds to a "text"
 * index. This is used to force the index cost to 0 to make sure
 * we use the text index.
 */
static bool
IsTextIndexMatch(IndexPath *path)
{
	ListCell *cell;
	foreach(cell, path->indexclauses)
	{
		IndexClause *clause = lfirst(cell);
		if (IsTextPathOpFamilyOid(
				path->indexinfo->relam,
				path->indexinfo->opfamily[clause->indexcol]))
		{
			return true;
		}
	}

	return false;
}


static IndexScanDesc
extension_rumbeginscan(Relation rel, int nkeys, int norderbys)
{
	EnsureRumLibLoaded();
	return extension_rumbeginscan_core(rel, nkeys, norderbys,
									   &rum_index_routine);
}


IndexScanDesc
extension_rumbeginscan_core(Relation rel, int nkeys, int norderbys,
							IndexAmRoutine *coreRoutine)
{
	if (IsCompositeOpClass(rel))
	{
		IndexScanDesc scan = RelationGetIndexScan(rel, nkeys, norderbys);

		DocumentDBRumIndexState *outerScanState = palloc0(
			sizeof(DocumentDBRumIndexState));
		scan->opaque = outerScanState;

		/* Don't yet start inner scan here - instead wait until rescan to begin */
		return scan;
	}
	else
	{
		return coreRoutine->ambeginscan(rel, nkeys, norderbys);
	}
}


static IndexScanDesc
extension_documentdb_rumbeginscan(Relation rel, int nkeys, int norderbys)
{
	EnsureRumLibLoaded();
	return extension_documentdb_rumbeginscan_core(rel, nkeys, norderbys,
												  &rum_index_routine);
}


IndexScanDesc
extension_documentdb_rumbeginscan_core(Relation rel, int nkeys, int norderbys,
									   IndexAmRoutine *coreRoutine)
{
	if (IsCompositeOpClass(rel))
	{
		/* Ask for 1 more key (storage for summarization key) */
		IndexScanDesc scan = coreRoutine->ambeginscan(rel, nkeys + 1, norderbys);
		scan->numberOfKeys = nkeys;
		return scan;
	}
	else
	{
		return coreRoutine->ambeginscan(rel, nkeys, norderbys);
	}
}


static void
extension_rumendscan(IndexScanDesc scan)
{
	EnsureRumLibLoaded();
	extension_rumendscan_core(scan, &rum_index_routine);
}


void
extension_rumendscan_core(IndexScanDesc scan, IndexAmRoutine *coreRoutine)
{
	if (IsCompositeOpClass(scan->indexRelation))
	{
		DocumentDBRumIndexState *outerScanState =
			(DocumentDBRumIndexState *) scan->opaque;

		if (outerScanState->innerScan)
		{
			coreRoutine->amendscan(outerScanState->innerScan);
			IndexScanEnd(outerScanState->innerScan);
			outerScanState->innerScan = NULL;
		}

		pfree(outerScanState);
	}
	else
	{
		coreRoutine->amendscan(scan);
	}
}


static void
extension_rumrescan(IndexScanDesc scan, ScanKey scankey, int nscankeys,
					ScanKey orderbys, int norderbys)
{
	EnsureRumLibLoaded();
	extension_rumrescan_core(scan, scankey, nscankeys,
							 orderbys, norderbys, &rum_index_routine);
}


void
extension_rumrescan_core(IndexScanDesc scan, ScanKey scankey, int nscankeys,
						 ScanKey orderbys, int norderbys,
						 IndexAmRoutine *coreRoutine)
{
	bool supportsOrderedOperatorScans = false;
	PGFunction multiKeyStatusFunc = NULL;
	PGFunction getopclassMetadataFunc = NULL;
	if (GetCompositeOpClassWithProps(scan->indexRelation,
									 &supportsOrderedOperatorScans, &multiKeyStatusFunc,
									 &getopclassMetadataFunc))
	{
		/* Copy the scan keys to our scan */
		if (scankey && scan->numberOfKeys > 0)
		{
			memmove(scan->keyData, scankey,
					scan->numberOfKeys * sizeof(ScanKeyData));
		}
		if (orderbys && scan->numberOfOrderBys > 0)
		{
			memmove(scan->orderByData, orderbys,
					scan->numberOfOrderBys * sizeof(ScanKeyData));
		}

		/* get the opaque scans */
		DocumentDBRumIndexState *outerScanState =
			(DocumentDBRumIndexState *) scan->opaque;

		int numColumns = GetCompositeOpClassPathCount(
			scan->indexRelation->rd_opcoptions[0]);
		if (outerScanState->multiKeyStatus == IndexMultiKeyStatus_Unknown)
		{
			/* Check if we are producing reduced index terms in this index */
			BsonGinCompositePathOptions *options =
				(BsonGinCompositePathOptions *) scan->indexRelation->rd_opcoptions[0];

			if (options->enableMetadataBasedTracking &&
				getopclassMetadataFunc != NULL)
			{
				uint32_t multiKeyPerPathStatus = 0;
				bool hasReducedCorrelatedTerms = false;
				bool indexHasArrays = false;
				bool indexHasTruncation = false;
				uint64_t opclassMetadata = DatumGetUInt64(DirectFunctionCall1(
															  getopclassMetadataFunc,
															  PointerGetDatum(
																  scan->indexRelation)));
				DecodeCompositeOpClassQueryMetadata(options, opclassMetadata,
													&indexHasArrays,
													&multiKeyPerPathStatus,
													&hasReducedCorrelatedTerms,
													&indexHasTruncation);
				outerScanState->multiKeyStatus = indexHasArrays ?
												 IndexMultiKeyStatus_HasArrays :
												 IndexMultiKeyStatus_HasNoArrays;
				outerScanState->hasCorrelatedReducedTerms = hasReducedCorrelatedTerms;
			}
			else
			{
				if (multiKeyStatusFunc != NULL)
				{
					bool indexHasArrays =
						DatumGetBool(DirectFunctionCall1(multiKeyStatusFunc,
														 PointerGetDatum(
															 scan->indexRelation)));
					outerScanState->multiKeyStatus = indexHasArrays ?
													 IndexMultiKeyStatus_HasArrays :
													 IndexMultiKeyStatus_HasNoArrays;
				}
				else
				{
					outerScanState->multiKeyStatus =
						CheckIndexHasArrays(scan->indexRelation, coreRoutine);
				}

				if (options->enableCompositeReducedCorrelatedTerms &&
					outerScanState->multiKeyStatus == IndexMultiKeyStatus_HasArrays &&
					numColumns > 1)
				{
					/* Check if we have correlated reduced terms */
					outerScanState->hasCorrelatedReducedTerms = CheckIndexHasReducedTerms(
						scan->indexRelation, coreRoutine);
				}
			}
		}

		ScanKey innerOrderBy = orderbys;
		int32_t nInnerorderbys = norderbys;
		ScanKey innerScanKey = scankey;
		int32_t nInnerScanKeys = nscankeys;

		/* There are 2 paths here, regular queries, or unique order by
		 * If this is a unique order by, we need to modify the scan keys
		 * for both paths.
		 */
		if (ModifyScanKeysForCompositeScan(scankey, nscankeys,
										   &outerScanState->compositeKey,
										   outerScanState->multiKeyStatus ==
										   IndexMultiKeyStatus_HasArrays,
										   outerScanState->hasCorrelatedReducedTerms,
										   supportsOrderedOperatorScans))
		{
			innerScanKey = &outerScanState->compositeKey;
			nInnerScanKeys = 1;
		}

		if (outerScanState->innerScan == NULL)
		{
			/* Initialize the inner scan if not initialized using the order by and keys */
			outerScanState->innerScan = coreRoutine->ambeginscan(scan->indexRelation,
																 nInnerScanKeys,
																 nInnerorderbys);

			outerScanState->innerScan->xs_want_itup = scan->xs_want_itup;
			outerScanState->innerScan->parallel_scan = scan->parallel_scan;
		}

		outerScanState->innerScan->ignore_killed_tuples = scan->ignore_killed_tuples;
		outerScanState->innerScan->kill_prior_tuple = scan->kill_prior_tuple;
		coreRoutine->amrescan(outerScanState->innerScan,
							  innerScanKey, nInnerScanKeys,
							  innerOrderBy,
							  nInnerorderbys);
	}
	else
	{
		coreRoutine->amrescan(scan, scankey, nscankeys, orderbys, norderbys);
	}
}


static void
extension_documentdb_rumrescan(IndexScanDesc scan, ScanKey scankey, int nscankeys,
							   ScanKey orderbys, int norderbys)
{
	EnsureRumLibLoaded();
	extension_documentdb_rumrescan_core(scan, scankey, nscankeys,
										orderbys, norderbys, &rum_index_routine);
}


static bool
IsCompositeScanEligible(ScanKey scanKey, int nscankeys)
{
	if (nscankeys == 0)
	{
		return true;
	}

	/* the runtime will order scan keys by attnum
	 * If the first and last scan keys are not the same att - skip.
	 */
	if (scanKey[0].sk_attno != 1 ||
		scanKey[0].sk_attno != scanKey[nscankeys - 1].sk_attno)
	{
		return false;
	}

	if (scanKey[0].sk_strategy == BSON_INDEX_STRATEGY_UNIQUE_EQUAL)
	{
		return false;
	}

	return true;
}


void
extension_documentdb_rumrescan_core(IndexScanDesc scan, ScanKey scankey, int nscankeys,
									ScanKey orderbys, int norderbys,
									IndexAmRoutine *coreRoutine)
{
	bool supportsOrderedOperatorScans = false;
	PGFunction multiKeyStatusFunc = NULL;
	PGFunction getopclassMetadataFunc = NULL;
	if (IsCompositeScanEligible(scankey, nscankeys) &&
		GetCompositeOpClassWithProps(scan->indexRelation,
									 &supportsOrderedOperatorScans, &multiKeyStatusFunc,
									 &getopclassMetadataFunc))
	{
		BsonGinCompositePathOptions *options =
			(BsonGinCompositePathOptions *) scan->indexRelation->rd_opcoptions[0];
		IndexMultiKeyStatus indexHasArrays = IndexMultiKeyStatus_Unknown;
		bool hasCorrelatedReducedTerms = false;
		if (options->enableMetadataBasedTracking)
		{
			uint32_t multiKeyPerPathStatus = 0;
			bool indexHasArraysBool = false;
			bool indexHasTruncation = false;
			uint64_t opclassMetadata = DatumGetUInt64(DirectFunctionCall1(
														  getopclassMetadataFunc,
														  PointerGetDatum(
															  scan->indexRelation)));
			DecodeCompositeOpClassQueryMetadata(options, opclassMetadata,
												&indexHasArraysBool,
												&multiKeyPerPathStatus,
												&hasCorrelatedReducedTerms,
												&indexHasTruncation);
			indexHasArrays = indexHasArraysBool ? IndexMultiKeyStatus_HasArrays :
							 IndexMultiKeyStatus_HasNoArrays;
		}
		else
		{
			if (multiKeyStatusFunc != NULL)
			{
				indexHasArrays = DatumGetBool(DirectFunctionCall1(multiKeyStatusFunc,
																  PointerGetDatum(
																	  scan->indexRelation)));
			}
			else
			{
				indexHasArrays = CheckIndexHasArrays(scan->indexRelation, coreRoutine);
			}

			/* Check if we are producing reduced index terms in this index */

			int numColumns = GetCompositeOpClassPathCount(
				scan->indexRelation->rd_opcoptions[0]);
			if (options->enableCompositeReducedCorrelatedTerms &&
				indexHasArrays == IndexMultiKeyStatus_HasArrays && numColumns > 1)
			{
				/* Check if we have correlated reduced terms */
				hasCorrelatedReducedTerms = CheckIndexHasReducedTerms(
					scan->indexRelation, coreRoutine);
			}
		}

		/* There are 2 paths here, regular queries, or unique order by
		 * If this is a unique order by, we need to modify the scan keys
		 * for both paths.
		 */
		ScanKeyData compositeKey = { 0 };
		if (ModifyScanKeysForCompositeScan(scankey, nscankeys,
										   &compositeKey,
										   indexHasArrays ==
										   IndexMultiKeyStatus_HasArrays,
										   hasCorrelatedReducedTerms,
										   supportsOrderedOperatorScans))
		{
			int numscankeys = 1;
			coreRoutine->amrescan(scan, &compositeKey, numscankeys, orderbys, norderbys);

			/* scan->scanKeyData[0] will now be the composite keys - copy the remaining from 1-> N
			 * This is fine since we requested 1 extra key on beginscan
			 */
			if (nscankeys > 0)
			{
				memmove(&scan->keyData[1], scankey,
						nscankeys * sizeof(ScanKeyData));
			}
		}
		else
		{
			coreRoutine->amrescan(scan, scankey, nscankeys, orderbys, norderbys);
		}
	}
	else
	{
		coreRoutine->amrescan(scan, scankey, nscankeys, orderbys, norderbys);
	}
}


static int64
extension_amgetbitmap(IndexScanDesc scan, TIDBitmap *tbm)
{
	EnsureRumLibLoaded();
	return extension_rumgetbitmap_core(scan, tbm, &rum_index_routine);
}


int64
extension_rumgetbitmap_core(IndexScanDesc scan, TIDBitmap *tbm,
							IndexAmRoutine *coreRoutine)
{
	if (IsCompositeOpClass(scan->indexRelation))
	{
		DocumentDBRumIndexState *outerScanState =
			(DocumentDBRumIndexState *) scan->opaque;
		return coreRoutine->amgetbitmap(outerScanState->innerScan, tbm);
	}
	else
	{
		return coreRoutine->amgetbitmap(scan, tbm);
	}
}


static bool
extension_amgettuple(IndexScanDesc scan, ScanDirection direction)
{
	EnsureRumLibLoaded();
	return extension_rumgettuple_core(scan, direction, &rum_index_routine);
}


static bool
GetOneTupleCore(DocumentDBRumIndexState *outerScanState,
				IndexScanDesc scan, ScanDirection direction,
				IndexAmRoutine *coreRoutine)
{
	bool result = coreRoutine->amgettuple(outerScanState->innerScan, direction);
	if (result)
	{
		ItemPointerCopy(&outerScanState->innerScan->xs_heaptid, &scan->xs_heaptid);
		scan->xs_recheck = outerScanState->innerScan->xs_recheck;
		scan->xs_recheckorderby = outerScanState->innerScan->xs_recheckorderby;

		/* Set the pointers to handle order by values */
		scan->xs_orderbyvals = outerScanState->innerScan->xs_orderbyvals;
		scan->xs_orderbynulls = outerScanState->innerScan->xs_orderbynulls;

		scan->xs_itup = outerScanState->innerScan->xs_itup;
		scan->xs_itupdesc = outerScanState->innerScan->xs_itupdesc;
	}

	return result;
}


bool
extension_rumgettuple_core(IndexScanDesc scan, ScanDirection direction,
						   IndexAmRoutine *coreRoutine)
{
	if (IsCompositeOpClass(scan->indexRelation))
	{
		DocumentDBRumIndexState *outerScanState =
			(DocumentDBRumIndexState *) scan->opaque;

		/* The caller will always pass ForwardScanDirection
		 * since PG always uses ForwardScanDirection in cases where we do
		 * amcanorderbyop. For the inner scan, we would need to pass the
		 * scanDirection as determined in amrescan from the index state.
		 */
		if (unlikely(direction != ForwardScanDirection))
		{
			ereport(ERROR, (errmsg("rumgettuple only supports forward scans")));
		}

		/* Push this to the inner scan */
		outerScanState->innerScan->kill_prior_tuple = scan->kill_prior_tuple;

		/* No arrays, or we don't support dedup - just return the basics */
		return GetOneTupleCore(outerScanState, scan, direction,
							   coreRoutine);
	}
	else
	{
		return coreRoutine->amgettuple(scan, direction);
	}
}


static IndexBuildResult *
extension_rumbuild(Relation heapRelation,
				   Relation indexRelation,
				   struct IndexInfo *indexInfo)
{
	EnsureRumLibLoaded();

	return extension_rumbuild_core(heapRelation, indexRelation,
								   indexInfo, &rum_index_routine,
								   rum_index_multi_key_update_func);
}


IndexBuildResult *
extension_rumbuild_core(Relation heapRelation, Relation indexRelation,
						struct IndexInfo *indexInfo, IndexAmRoutine *coreRoutine,
						PGFunction updateMultikeyStatus)
{
	RumHasMultiKeyPaths = false;
	IndexBuildResult *result = coreRoutine->ambuild(heapRelation, indexRelation,
													indexInfo);

	/* Update statistics to track that we're a multi-key index:
	 * Note: We don't use HasMultiKeyPaths here as we want to handle the parallel build
	 * scenario where we may have multiple workers building the index.
	 */
	if (IsCompositeOpClass(indexRelation))
	{
		BsonGinCompositePathOptions *options =
			(BsonGinCompositePathOptions *) indexRelation->rd_opcoptions[0];

		/* In metadata based tracking mode the multi-key (and per-path) status is
		 * written directly into the opclass metadata blob during the build itself,
		 * so the post-build term scan is unnecessary. It is also unsupported in this
		 * mode (the IS_MULTIKEY term strategy errors), so skip it.
		 */
		if (options != NULL && options->enableMetadataBasedTracking)
		{
			/* nothing to do - metadata was written during the build */
		}
		else if (updateMultikeyStatus != NULL)
		{
			IndexMultiKeyStatus status = CheckIndexHasArrays(indexRelation, coreRoutine);
			if (status == IndexMultiKeyStatus_HasArrays)
			{
				DirectFunctionCall1(updateMultikeyStatus, PointerGetDatum(indexRelation));
			}
		}
	}
	else if (RumHasMultiKeyPaths && updateMultikeyStatus != NULL)
	{
		DirectFunctionCall1(updateMultikeyStatus, PointerGetDatum(indexRelation));
	}

	return result;
}


static bool
extension_ruminsert(Relation indexRelation,
					Datum *values,
					bool *isnull,
					ItemPointer heap_tid,
					Relation heapRelation,
					IndexUniqueCheck checkUnique,
					bool indexUnchanged,
					struct IndexInfo *indexInfo)
{
	EnsureRumLibLoaded();

	return extension_ruminsert_core(indexRelation, values, isnull,
									heap_tid, heapRelation, checkUnique,
									indexUnchanged, indexInfo,
									&rum_index_routine, rum_index_multi_key_update_func);
}


bool
extension_ruminsert_core(Relation indexRelation,
						 Datum *values,
						 bool *isnull,
						 ItemPointer heap_tid,
						 Relation heapRelation,
						 IndexUniqueCheck checkUnique,
						 bool indexUnchanged,
						 struct IndexInfo *indexInfo,
						 IndexAmRoutine *coreRoutine,
						 PGFunction updateMultikeyStatus)
{
	RumHasMultiKeyPaths = false;
	bool result = coreRoutine->aminsert(indexRelation, values, isnull,
										heap_tid, heapRelation, checkUnique,
										indexUnchanged, indexInfo);

	if (RumHasMultiKeyPaths && updateMultikeyStatus != NULL)
	{
		DirectFunctionCall1(updateMultikeyStatus, PointerGetDatum(indexRelation));
	}

	return result;
}


static Datum
RumGetMultiKeyStatusSlow(PG_FUNCTION_ARGS)
{
	Relation indexRelation = (Relation) PG_GETARG_POINTER(0);
	EnsureRumLibLoaded();
	IndexMultiKeyStatus multiKeyStatus = CheckIndexHasArrays(indexRelation,
															 &rum_index_routine);
	PG_RETURN_BOOL(multiKeyStatus == IndexMultiKeyStatus_HasArrays);
}


static bool
CheckIndexHasReducedTerms(Relation indexRelation, IndexAmRoutine *coreRoutine)
{
	/* Start a nested query lookup */
	IndexScanDesc innerDesc = coreRoutine->ambeginscan(indexRelation, 1, 0);

	ScanKeyData arrayKey = { 0 };
	arrayKey.sk_attno = 1;
	arrayKey.sk_collation = InvalidOid;
	arrayKey.sk_strategy = BSON_INDEX_STRATEGY_HAS_CORRELATED_REDUCED_TERMS;
	arrayKey.sk_argument = PointerGetDatum(PgbsonInitEmpty());

	innerDesc->parallel_scan = NULL;
	coreRoutine->amrescan(innerDesc, &arrayKey, 1, NULL, 0);
	bool hasReducedArrayTerms = coreRoutine->amgettuple(innerDesc, ForwardScanDirection);
	coreRoutine->amendscan(innerDesc);
	return hasReducedArrayTerms;
}


static IndexMultiKeyStatus
CheckIndexHasArrays(Relation indexRelation, IndexAmRoutine *coreRoutine)
{
	/* Start a nested query lookup */
	IndexScanDesc innerDesc = coreRoutine->ambeginscan(indexRelation, 1, 0);

	ScanKeyData arrayKey = { 0 };
	arrayKey.sk_attno = 1;
	arrayKey.sk_collation = InvalidOid;
	arrayKey.sk_strategy = BSON_INDEX_STRATEGY_IS_MULTIKEY;
	arrayKey.sk_argument = PointerGetDatum(PgbsonInitEmpty());

	innerDesc->parallel_scan = NULL;
	coreRoutine->amrescan(innerDesc, &arrayKey, 1, NULL, 0);
	bool hasArrays = coreRoutine->amgettuple(innerDesc, ForwardScanDirection);
	coreRoutine->amendscan(innerDesc);
	return hasArrays ? IndexMultiKeyStatus_HasArrays : IndexMultiKeyStatus_HasNoArrays;
}


bool
RumGetTruncationStatus(Relation indexRelation)
{
	EnsureRumLibLoaded();

	if (!IsCompositeOpClass(indexRelation))
	{
		return false;
	}

	/* Start a nested query lookup */
	IndexScanDesc innerDesc = rum_index_routine.ambeginscan(indexRelation, 1, 0);

	ScanKeyData truncatedKey = { 0 };
	truncatedKey.sk_attno = 1;
	truncatedKey.sk_collation = InvalidOid;
	truncatedKey.sk_strategy = BSON_INDEX_STRATEGY_HAS_TRUNCATED_TERMS;
	truncatedKey.sk_argument = PointerGetDatum(PgbsonInitEmpty());
	innerDesc->parallel_scan = NULL;

	rum_index_routine.amrescan(innerDesc, &truncatedKey, 1, NULL, 0);
	bool hasTruncation = rum_index_routine.amgettuple(innerDesc, ForwardScanDirection);
	rum_index_routine.amendscan(innerDesc);
	return hasTruncation;
}


static List *
GetIndexBoundsForExplain(Relation index_rel, Datum compositeArgDatum,
						 ScanDirection scanDirection,
						 List **rawPerPathBounds, const char **minBounds)
{
	uint32_t nentries = 0;
	bool *partialMatch = NULL;
	Pointer *extraData = NULL;

	/* From the composite keys, get the lower bounds of the scans */
	/* Call extract_query to get the index details */
	int32_t ginScanType = GetScanTypeForScanDirection(scanDirection);
	LOCAL_FCINFO(fcinfo, 7);
	fcinfo->flinfo = palloc(sizeof(FmgrInfo));
	fmgr_info_copy(fcinfo->flinfo,
				   index_getprocinfo(index_rel, 1,
									 GIN_EXTRACTQUERY_PROC),
				   CurrentMemoryContext);

	fcinfo->args[0].value = compositeArgDatum;
	fcinfo->args[1].value = PointerGetDatum(&nentries);
	fcinfo->args[2].value = Int16GetDatum(BSON_INDEX_STRATEGY_COMPOSITE_QUERY);
	fcinfo->args[3].value = PointerGetDatum(&partialMatch);
	fcinfo->args[4].value = PointerGetDatum(&extraData);
	fcinfo->args[6].value = PointerGetDatum(&ginScanType);

	Datum *entryRes = (Datum *) gin_bson_composite_path_extract_query(fcinfo);

	/* Now write out the result for explain */
	List *boundsList = NIL;
	for (uint32_t i = 0; i < nentries; i++)
	{
		bytea *entry = DatumGetByteaPP(entryRes[i]);

		if (IsSerializedRootTruncationTerm(entry))
		{
			continue;
		}

		List *rawPathBoundsInner = NIL;
		char *serializedBound = SerializeBoundsStringForExplain(entry,
																extraData[i],
																fcinfo,
																&rawPathBoundsInner,
																minBounds);
		boundsList = lappend(boundsList, serializedBound);
		if (rawPathBoundsInner != NIL)
		{
			*rawPerPathBounds = list_concat(*rawPerPathBounds, rawPathBoundsInner);
		}
	}

	return boundsList;
}


static void
ExplainCompositeProperties(void *state, PGFunction multiKeyStatusFunc,
						   Relation index_rel, BsonGinCompositePathOptions *options,
						   List *indexQuals, List *indexOrderBy,
						   bool supportsOrderedOperatorScans,
						   PGFunction getOpclassMetadataFunc,
						   void (*writeBoolFunc)(const char *, bool, void *),
						   void (*writeStringListFunc)(const char *, List *, void *),
						   void (*writeStringFunc)(const char *, const char *, void *))
{
	bool isMultiKey;
	List *multiKeyPerPathList = NIL;
	bool hasCorrelatedTerms = false;
	bool isTruncated = false;
	List *truncatedPerPathList = NIL;
	if (getOpclassMetadataFunc != NULL && options != NULL &&
		options->enableMetadataBasedTracking)
	{
		uint64_t opclassMetadata = DatumGetUInt64(DirectFunctionCall1(
													  getOpclassMetadataFunc,
													  PointerGetDatum(
														  index_rel)));
		DecodeCompositeOpClassMetadata(options, opclassMetadata, &isMultiKey,
									   &multiKeyPerPathList,
									   &hasCorrelatedTerms, &isTruncated,
									   &truncatedPerPathList);
	}
	else
	{
		if (!multiKeyStatusFunc)
		{
			multiKeyStatusFunc = RumGetMultiKeyStatusSlow;
		}

		isMultiKey = DatumGetBool(DirectFunctionCall1(multiKeyStatusFunc,
													  PointerGetDatum(index_rel)));

		if (options != NULL && options->enableCompositeReducedCorrelatedTerms &&
			isMultiKey)
		{
			/* Check if we have correlated reduced terms */
			EnsureRumLibLoaded();
			hasCorrelatedTerms = CheckIndexHasReducedTerms(index_rel, &rum_index_routine);
		}

		isTruncated = RumGetTruncationStatus(index_rel);
	}


	writeBoolFunc("isMultiKey", isMultiKey, state);
	if (multiKeyPerPathList != NIL)
	{
		writeStringListFunc("multiKeyPaths", multiKeyPerPathList, state);
	}

	if (hasCorrelatedTerms)
	{
		writeBoolFunc("hasCorrelatedTerms", true, state);
	}

	if (isTruncated)
	{
		writeBoolFunc("hasTruncation", true, state);
	}

	if (truncatedPerPathList != NIL)
	{
		writeStringListFunc("truncatedPaths", truncatedPerPathList, state);
	}

	Datum compositeDatum = FormCompositeDatumFromQuals(indexQuals,
													   isMultiKey, hasCorrelatedTerms,
													   supportsOrderedOperatorScans);
	if (compositeDatum != 0)
	{
		ScanDirection scanDir = NoMovementScanDirection;
		if (list_length(indexOrderBy) > 0)
		{
			scanDir = ForwardScanDirection;
			OpExpr *orderByExpr = (OpExpr *) linitial(indexOrderBy);
			Expr *expr = lsecond(orderByExpr->args);
			if (IsA(expr, Const))
			{
				Datum orderByConstDatum = ((Const *) expr)->constvalue;
				scanDir = GetOrderByScanDirectionFromDatum(index_rel->rd_opcoptions[0],
														   orderByConstDatum);
			}
		}

		List *rawPerPathBounds = NIL;
		const char *minBounds = NULL;
		List *boundsList = GetIndexBoundsForExplain(index_rel, compositeDatum,
													scanDir, &rawPerPathBounds,
													&minBounds);
		if (rawPerPathBounds != NIL)
		{
			writeStringListFunc("startBounds", boundsList, state);
			writeStringListFunc("rawBounds", rawPerPathBounds, state);
		}
		else
		{
			writeStringListFunc("indexBounds", boundsList, state);
		}

		if (minBounds != NULL)
		{
			writeStringFunc("minKey", minBounds, state);
		}
	}
}


static void
PgbsonExplainWriterWriteBool(const char *name, bool value, void *writer)
{
	PgbsonWriterAppendBool((pgbson_writer *) writer, name, -1, value);
}


static void
PgbsonExplainWriterWriteStringList(const char *name, List *list, void *writer)
{
	/* In bson_writer mode, we skip the key for the explain bounds inside rum
	 * Ideally, we should remove this for composite opclass since we already have
	 * scanBounds covering very similar information, but this is left behind for
	 * compatibility for now.
	 * TODO: Figure out if we really want this going forward and how to present this.
	 */
	if (strcmp(name, "scanKeyDetails") == 0)
	{
		return;
	}


	pgbson_array_writer arrayWriter;
	PgbsonWriterStartArray((pgbson_writer *) writer, name, -1, &arrayWriter);
	ListCell *cell;
	foreach(cell, list)
	{
		const char *value = (const char *) lfirst(cell);
		PgbsonArrayWriterWriteUtf8(&arrayWriter, value);
	}
	PgbsonWriterEndArray((pgbson_writer *) writer, &arrayWriter);
}


static void
PgbsonExplainWriterWriteInteger(const char *name, const char *label, int32_t value,
								void *writer)
{
	PgbsonWriterAppendInt32((pgbson_writer *) writer, name, -1, value);
}


static void
PgbsonExplainWriterWriteString(const char *name, const char *value, void *writer)
{
	PgbsonWriterAppendUtf8((pgbson_writer *) writer, name, -1, value);
}


static void
ExplainWriterWriteBool(const char *name, bool value, void *writer)
{
	ExplainPropertyBool(name, (bool) value, (struct ExplainState *) writer);
}


static void
ExplainWriterWriteStringList(const char *name, List *list, void *writer)
{
	ExplainPropertyList(name, list, (struct ExplainState *) writer);
}


static void
ExplainWriterWriteInteger(const char *name, const char *label, int32_t value,
						  void *writer)
{
	ExplainPropertyInteger(name, label, value, (struct ExplainState *) writer);
}


static void
ExplainWriterWriteString(const char *name, const char *value, void *writer)
{
	ExplainPropertyText(name, value, (struct ExplainState *) writer);
}


void
ExplainRawCompositeScanToWriter(Relation index_rel, List *indexQuals, List *indexOrderBy,
								ScanDirection indexScanDir, pgbson_writer *writer)
{
	bool supportsOrderedOperatorScans = false;
	PGFunction multiKeyStatusFunc = NULL;
	PGFunction getopclassMetadataFunc = NULL;
	if (!GetCompositeOpClassWithProps(index_rel, &supportsOrderedOperatorScans,
									  &multiKeyStatusFunc, &getopclassMetadataFunc))
	{
		return;
	}

	BsonGinCompositePathOptions *options = NULL;
	if (index_rel->rd_opcoptions != NULL)
	{
		options = (BsonGinCompositePathOptions *) index_rel->rd_opcoptions[0];
		pgbson_writer keyWriter;
		PgbsonWriterStartDocument(writer, "keyPattern", -1, &keyWriter);
		SerializeCompositeIndexKeyForExplainToWriter(
			index_rel->rd_opcoptions[0], &keyWriter);
		PgbsonWriterEndDocument(writer, &keyWriter);
	}

	ExplainCompositeProperties(writer, multiKeyStatusFunc, index_rel,
							   options, indexQuals,
							   indexOrderBy,
							   supportsOrderedOperatorScans,
							   getopclassMetadataFunc,
							   PgbsonExplainWriterWriteBool,
							   PgbsonExplainWriterWriteStringList,
							   PgbsonExplainWriterWriteString);
}


void
ExplainRawCompositeScan(Relation index_rel, List *indexQuals, List *indexOrderBy,
						ScanDirection indexScanDir, struct ExplainState *es)
{
	bool supportsOrderedOperatorScans = false;
	PGFunction multiKeyStatusFunc = NULL;
	PGFunction getopclassMetadataFunc = NULL;
	if (!GetCompositeOpClassWithProps(index_rel, &supportsOrderedOperatorScans,
									  &multiKeyStatusFunc, &getopclassMetadataFunc))
	{
		return;
	}

	BsonGinCompositePathOptions *options = NULL;
	if (index_rel->rd_opcoptions != NULL)
	{
		options = (BsonGinCompositePathOptions *) index_rel->rd_opcoptions[0];
		const char *keyString = SerializeCompositeIndexKeyForExplain(
			index_rel->rd_opcoptions[0]);
		ExplainPropertyText("indexKey", keyString, es);
	}

	ExplainCompositeProperties(es, multiKeyStatusFunc, index_rel,
							   options, indexQuals,
							   indexOrderBy,
							   supportsOrderedOperatorScans,
							   getopclassMetadataFunc,
							   ExplainWriterWriteBool, ExplainWriterWriteStringList,
							   ExplainWriterWriteString);
}


static void
ExplainCompositeScanCore(IndexScanDesc scan, void *state,
						 ExplainWriterFuncs *writerFuncs)
{
	BsonGinCompositePathOptions *options =
		(BsonGinCompositePathOptions *) scan->indexRelation->rd_opcoptions[0];

	bool hasMultiKey = false;
	List *multiKeyPerPathList = NIL;
	bool hasCorrelatedReducedTerms = false;
	bool hasTruncation = false;
	List *truncatedPerPathList = NIL;

	bool supportsOrderedOperatorScans = false;
	PGFunction multiKeyStatusFunc = NULL;
	PGFunction getopclassMetadataFunc = NULL;
	GetCompositeOpClassWithProps(scan->indexRelation, &supportsOrderedOperatorScans,
								 &multiKeyStatusFunc, &getopclassMetadataFunc);

	if (getopclassMetadataFunc != NULL && options != NULL &&
		options->enableMetadataBasedTracking)
	{
		uint64_t opclassMetadata = DatumGetUInt64(DirectFunctionCall1(
													  getopclassMetadataFunc,
													  PointerGetDatum(
														  scan->indexRelation)));

		DecodeCompositeOpClassMetadata(options, opclassMetadata, &hasMultiKey,
									   &multiKeyPerPathList,
									   &hasCorrelatedReducedTerms, &hasTruncation,
									   &truncatedPerPathList);
	}
	else
	{
		hasMultiKey = DatumGetBool(DirectFunctionCall1(RumGetMultiKeyStatusSlow,
													   PointerGetDatum(
														   scan->indexRelation)));
		if (options->enableCompositeReducedCorrelatedTerms && hasMultiKey)
		{
			/* Check if we have correlated reduced terms */
			hasCorrelatedReducedTerms = CheckIndexHasReducedTerms(
				scan->indexRelation, &rum_index_routine);
		}

		hasTruncation = RumGetTruncationStatus(scan->indexRelation);
	}

	writerFuncs->writeBool("isMultiKey", hasMultiKey, state);
	if (multiKeyPerPathList != NIL)
	{
		writerFuncs->writeStringList("multiKeyPaths", multiKeyPerPathList, state);
	}

	if (hasCorrelatedReducedTerms)
	{
		writerFuncs->writeBool("hasCorrelatedTerms", true, state);
	}

	if (hasTruncation)
	{
		writerFuncs->writeBool("hasTruncation", true, state);
	}

	if (truncatedPerPathList != NIL)
	{
		writerFuncs->writeStringList("truncatedPaths", truncatedPerPathList, state);
	}

	Datum compositeKey = (Datum) 0;
	IndexScanDesc innerScan = scan;
	if (scan->keyData[0].sk_argument != (Datum) 0 &&
		scan->keyData[0].sk_strategy == BSON_INDEX_STRATEGY_COMPOSITE_QUERY)
	{
		innerScan = scan;
		compositeKey = scan->keyData[0].sk_argument;
	}
	else
	{
		DocumentDBRumIndexState *outerScanState =
			(DocumentDBRumIndexState *) scan->opaque;
		compositeKey = outerScanState->compositeKey.sk_argument;
		innerScan = outerScanState->innerScan;
	}

	if (compositeKey != (Datum) 0)
	{
		ScanDirection scanDir = NoMovementScanDirection;
		if (scan->numberOfOrderBys > 0)
		{
			scanDir = ForwardScanDirection;
			scanDir = GetOrderByScanDirectionFromDatum(
				scan->indexRelation->rd_opcoptions[0],
				scan->orderByData[0].sk_argument);
		}

		List *rawPerPathBounds = NIL;
		const char *minBounds = NULL;
		List *boundsList = GetIndexBoundsForExplain(
			scan->indexRelation,
			compositeKey,
			scanDir, &rawPerPathBounds, &minBounds);

		if (rawPerPathBounds != NIL)
		{
			writerFuncs->writeStringList("startBounds", boundsList, state);
			writerFuncs->writeStringList("rawBounds", rawPerPathBounds, state);
		}
		else
		{
			writerFuncs->writeStringList("indexBounds", boundsList, state);
		}

		if (minBounds != NULL)
		{
			writerFuncs->writeString("minKey", minBounds, state);
		}
	}

	/* Explain the inner scan using underlying am */
	TryExplainByIndexAm(innerScan, writerFuncs, state);
}


static ExplainWriterFuncs
GetForExplain(void)
{
	ExplainWriterFuncs writerFuncs =
	{
		.writeBool = ExplainWriterWriteBool,
		.writeStringList = ExplainWriterWriteStringList,
		.writeInteger = ExplainWriterWriteInteger,
		.writeString = ExplainWriterWriteString
	};
	return writerFuncs;
}


static ExplainWriterFuncs
GetForBsonWriter(void)
{
	ExplainWriterFuncs writerFuncs =
	{
		.writeBool = PgbsonExplainWriterWriteBool,
		.writeStringList = PgbsonExplainWriterWriteStringList,
		.writeInteger = PgbsonExplainWriterWriteInteger,
		.writeString = PgbsonExplainWriterWriteString
	};
	return writerFuncs;
}


void
ExplainCompositeScanToWriter(IndexScanDesc scan, pgbson_writer *writer)
{
	if (!IsCompositeOpClass(scan->indexRelation))
	{
		return;
	}

	if (scan->indexRelation->rd_opcoptions != NULL)
	{
		pgbson_writer keyWriter;
		PgbsonWriterStartDocument(writer, "keyPattern", -1, &keyWriter);
		SerializeCompositeIndexKeyForExplainToWriter(
			scan->indexRelation->rd_opcoptions[0], &keyWriter);
		PgbsonWriterEndDocument(writer, &keyWriter);
	}

	ExplainWriterFuncs writerFuncs = GetForBsonWriter();
	ExplainCompositeScanCore(scan, writer, &writerFuncs);
}


void
ExplainCompositeScan(IndexScanDesc scan, ExplainState *es)
{
	if (!IsCompositeOpClass(scan->indexRelation))
	{
		return;
	}

	if (scan->indexRelation->rd_opcoptions != NULL)
	{
		const char *keyString = SerializeCompositeIndexKeyForExplain(
			scan->indexRelation->rd_opcoptions[0]);
		ExplainPropertyText("indexKey", keyString, es);
	}

	ExplainWriterFuncs writerFuncs = GetForExplain();
	ExplainCompositeScanCore(scan, es, &writerFuncs);
}


void
ExplainRegularIndexScan(IndexScanDesc scan, struct ExplainState *es)
{
	if (IsBsonRegularIndexAm(scan->indexRelation->rd_rel->relam))
	{
		/* See if there's a hook to explain more in this index */
		ExplainWriterFuncs writerFuncs = GetForExplain();
		TryExplainByIndexAm(scan, &writerFuncs, es);
	}
}


void
ExplainRegularIndexScanToWriter(IndexScanDesc scan, pgbson_writer *writer)
{
	if (IsBsonRegularIndexAm(scan->indexRelation->rd_rel->relam))
	{
		/* See if there's a hook to explain more in this index */
		ExplainWriterFuncs writerFuncs = GetForBsonWriter();
		TryExplainByIndexAm(scan, &writerFuncs, writer);
	}
}


void
RecordCostEstimateForIndex(Oid indexOid, Oid relOid, Cost indexStartupCost,
						   Cost indexTotalCost, Selectivity indexSelectivity,
						   double indexCorrelation, double indexPages, double
						   totalIndexPages, double totalIndexTuples,
						   double boundarySelectivity, int numBoundaryQuals,
						   double dataPagesProportionFetched)
{
	if (!EnableExtendedExplainPlans || !EnableExplainScanIndexCosts)
	{
		return;
	}

	IndexCostsData *costData = NULL;
	for (int i = 0; i < IndexExplainCostsIndex; i++)
	{
		if (IndexExplainCosts[i].indexOid == indexOid)
		{
			/* We already have an entry for this index - update it with the new cost */
			costData = &IndexExplainCosts[i];
			break;
		}
	}

	if (costData == NULL && IndexExplainCostsIndex < MAX_EXPLAIN_COSTS_SIZE)
	{
		costData = &IndexExplainCosts[IndexExplainCostsIndex++];
	}

	if (costData != NULL)
	{
		costData->indexOid = indexOid;
		costData->relOid = relOid;
		costData->indexStartupCost = indexStartupCost;
		costData->indexTotalCost = indexTotalCost;
		costData->indexSelectivity = indexSelectivity;
		costData->indexCorrelation = indexCorrelation;
		costData->indexPages = indexPages;
		costData->totalIndexPages = totalIndexPages;
		costData->totalIndexEntries = totalIndexTuples;
		costData->boundarySelectivity = boundarySelectivity;
		costData->numBoundaryQuals = numBoundaryQuals;
		costData->dataPagesProportionFetched = dataPagesProportionFetched;
	}
}


static int32_t
CompareIndexCostsByTotalCost(const void *left, const void *right)
{
	IndexCostsData *leftData = (IndexCostsData *) left;
	IndexCostsData *rightData = (IndexCostsData *) right;

	/* Sort by cost ascending */
	return leftData->indexTotalCost > rightData->indexTotalCost ? 1 :
		   (leftData->indexTotalCost < rightData->indexTotalCost ? -1 : 0);
}


void
LogReportedIndexCosts(Oid relOid, struct ExplainState *es)
{
	if (!EnableExtendedExplainPlans || !EnableExplainScanIndexCosts)
	{
		return;
	}

	if (IndexExplainCostsIndex >= MAX_EXPLAIN_COSTS_SIZE)
	{
		IndexExplainCostsIndex = MAX_EXPLAIN_COSTS_SIZE;
	}

	/* Sort the costs by total cost ascending so that we report the most relevant plans first */
	qsort(IndexExplainCosts, IndexExplainCostsIndex, sizeof(IndexCostsData),
		  CompareIndexCostsByTotalCost);

	/* Log the costs that we have reported for index scans */
	StringInfoData buf;
	initStringInfo(&buf);
	int numPlansLogged = 0;
	for (int i = 0; i < IndexExplainCostsIndex && i < MAX_EXPLAIN_COSTS_SIZE &&
		 numPlansLogged < MAX_LOGGED_PLANS; i++)
	{
		if (IndexExplainCosts[i].indexOid == InvalidOid)
		{
			continue;
		}

		if (IndexExplainCosts[i].relOid != relOid)
		{
			continue;
		}

		const char *indexName = ExtensionExplainGetIndexName(
			IndexExplainCosts[i].indexOid);
		if (indexName == NULL)
		{
			continue;
		}

		numPlansLogged++;
		if (es->format == EXPLAIN_FORMAT_TEXT)
		{
			resetStringInfo(&buf);
			appendStringInfo(&buf,
							 "(startup cost=%.3f, total cost=%.3f, selectivity=%g, correlation=%.3f, estimated index pages loaded=%.2f%%, estimated total index entries=%.0f, boundary selectivity=%g, num boundaries=%d, estimated data pages loaded=%.2f%%)",
							 IndexExplainCosts[i].indexStartupCost,
							 IndexExplainCosts[i].indexTotalCost,
							 IndexExplainCosts[i].indexSelectivity,
							 IndexExplainCosts[i].indexCorrelation,
							 IndexExplainCosts[i].indexPages /
							 IndexExplainCosts[i].totalIndexPages * 100,
							 IndexExplainCosts[i].totalIndexEntries,
							 IndexExplainCosts[i].boundarySelectivity,
							 IndexExplainCosts[i].numBoundaryQuals,
							 IndexExplainCosts[i].dataPagesProportionFetched * 100);
			ExplainPropertyText(indexName, buf.data, es);
		}
		else
		{
			ExplainOpenGroup("indexScanCost", NULL, true, es);
			ExplainPropertyText("indexName", indexName, es);
			ExplainPropertyFloat("startupCost", "", IndexExplainCosts[i].indexStartupCost,
								 3, es);
			ExplainPropertyFloat("totalCost", "", IndexExplainCosts[i].indexTotalCost, 3,
								 es);
			ExplainPropertyFloat("selectivity", "", IndexExplainCosts[i].indexSelectivity,
								 9, es);
			if (IndexExplainCosts[i].indexCorrelation != 0)
			{
				ExplainPropertyFloat("correlation", "",
									 IndexExplainCosts[i].indexCorrelation, 3, es);
			}

			double percentIndexPagesLoaded = IndexExplainCosts[i].totalIndexPages == 0 ?
											 0 :
											 IndexExplainCosts[i].indexPages /
											 IndexExplainCosts[i].totalIndexPages * 100;
			ExplainPropertyFloat("estimatedPercentIndexPagesLoaded", "",
								 percentIndexPagesLoaded,
								 2, es);
			ExplainPropertyFloat("estimatedTotalIndexEntries", "",
								 IndexExplainCosts[i].totalIndexEntries, 0, es);
			ExplainPropertyFloat("boundarySelectivity", "",
								 IndexExplainCosts[i].boundarySelectivity, 9, es);
			ExplainPropertyInteger("numBoundaries", "",
								   IndexExplainCosts[i].numBoundaryQuals, es);

			if (IndexExplainCosts[i].dataPagesProportionFetched >= 0)
			{
				ExplainPropertyFloat("estimatedDataPagesLoadedPercent", "",
									 IndexExplainCosts[i].dataPagesProportionFetched *
									 100, 2, es);
			}

			ExplainCloseGroup("indexScanCost", NULL, true, es);
		}
	}
}


void
ResetReportedIndexCosts(void)
{
	IndexExplainCostsIndex = 0;
	memset(IndexExplainCosts, 0, sizeof(IndexExplainCosts));
}


Datum
DocumentDBRumGetCurrentIndexKey(IndexScanDesc scan)
{
	if (!IsCompositeOpClass(scan->indexRelation))
	{
		ereport(ERROR, (errmsg(
							"GetCurrentIndexKeyFunc not supported for non ordered indexes")));
	}

	bool pathKeySummarizationForced = false;
	PGFunction getCurrentIndexKey =
		GetIndexKeyCurrentKeyFunc(scan->indexRelation->rd_rel->relam,
								  scan->indexRelation->rd_opfamily[0],
								  &pathKeySummarizationForced);
	if (getCurrentIndexKey == NULL)
	{
		ereport(ERROR, (errmsg(
							"Index AM does not support get_current_index_key for index")));
	}

	bool isPathSummarizationScan =
		scan->indexRelation->rd_indam->ambeginscan == extension_documentdb_rumbeginscan;
	if (isPathSummarizationScan || pathKeySummarizationForced)
	{
		return DirectFunctionCall1(getCurrentIndexKey, PointerGetDatum(scan));
	}
	else
	{
		DocumentDBRumIndexState *state = scan->opaque;
		return DirectFunctionCall1(getCurrentIndexKey, PointerGetDatum(state->innerScan));
	}
}


void
DocumentDBRumSkipTidsForCurrentEntry(IndexScanDesc scan, PGFunction
									 skipTidsFunc, bool pathKeySummarizationForced,
									 ItemPointer userContinuationState)
{
	if (!IsCompositeOpClass(scan->indexRelation))
	{
		ereport(ERROR, (errmsg(
							"GetCurrentIndexKeyFunc not supported for non ordered indexes")));
	}

	if (skipTidsFunc == NULL)
	{
		return;
	}

	bool isPathSummarizationScan =
		scan->indexRelation->rd_indam->ambeginscan == extension_documentdb_rumbeginscan;
	if (isPathSummarizationScan || pathKeySummarizationForced)
	{
		DirectFunctionCall2(skipTidsFunc, PointerGetDatum(scan), UInt32GetDatum(
								BlockIdGetBlockNumber(
									&
									userContinuationState->ip_blkid)));
	}
	else
	{
		DocumentDBRumIndexState *state = scan->opaque;
		DirectFunctionCall2(skipTidsFunc, PointerGetDatum(state->innerScan),
							UInt32GetDatum(BlockIdGetBlockNumber(
											   &userContinuationState->ip_blkid)));
	}
}
