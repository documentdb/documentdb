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
#include <utils/builtins.h>
#include <access/relscan.h>
#include <access/genam.h>
#include <utils/rel.h>
#include "math.h"
#include <optimizer/optimizer.h>
#include <commands/explain.h>
#include <access/gin.h>
#include <parser/parsetree.h>
#include <optimizer/pathnode.h>

#if PG_VERSION_NUM >= 180000
#include <commands/explain_state.h>
#include <commands/explain_format.h>
#endif

#include "api_hooks.h"
#include "opclass/bson_index_support.h"
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
#include "collation/collation.h"
#include "query/bson_dollar_selectivity.h"
#include "index_am/documentdb_rum_impl.h"

extern bool ForceUseIndexIfAvailable;
extern bool DisableExtendedRumExplainPlans;
extern bool EnableIndexPathKeySummarization;


/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */

static bool loaded_rum_routine = false;
static bool loaded_documentdb_rum_routine = false;
static IndexAmRoutine rum_index_routine = { 0 };

static PGFunction rum_index_multi_key_update_func = NULL;

typedef struct DocumentDBRumIndexState
{
	IndexScanDesc innerScan;

	ScanKeyData compositeKey;

	IndexMultiKeyStatus multiKeyStatus;

	bool hasCorrelatedReducedTerms;

	uint32_t multiKeyPerPathStatus;
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
static bool RumGetTruncationStatus(Relation indexRelation);
static bool RumGetReducedTermsStatus(Relation indexRelation);
static bool RumIsPathKeySummarizationScan(void);
static const char * GetRumCatalogSchema(void);
static const char * GetRumInternalSchemaV2(void);

static Datum (*rum_extract_tsquery_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsquery_consistent_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsvector_config_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsquery_pre_consistent_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_tsquery_distance_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_ts_join_pos_func)(PG_FUNCTION_ARGS) = NULL;
static Datum (*rum_extract_tsvector_func)(PG_FUNCTION_ARGS) = NULL;


const char *DocumentdbRumCorePath = "$libdir/pg_documentdb_extended_rum_core";


/* Left non-static for internal use */
BsonIndexAmEntry RumIndexAmEntry = {
	.is_single_path_index_supported = true,
	.is_wild_card_supported = true,
	.is_wild_card_projection_supported = true,
	.is_order_by_supported = false,
	.is_backwards_scan_supported = false,
	.is_index_only_scan_supported = false,
	.can_support_parallel_scans = false,
	.get_am_oid = RumIndexAmId,
	.get_single_path_op_family_oid = BsonRumSinglePathOperatorFamily,
	.get_composite_path_op_family_oid = BsonRumCompositeIndexOperatorFamily,
	.get_text_path_op_family_oid = BsonRumTextPathOperatorFamily,
	.get_unique_path_op_family_oid = BsonRumUniquePathOperatorFamily,
	.get_hashed_path_op_family_oid = BsonRumHashPathOperatorFamily,
	.add_explain_output = NULL, /* No explain output for RUM */
	.am_name = "rum",
	.get_opclass_catalog_schema = GetRumCatalogSchema,
	.get_opclass_internal_catalog_schema = GetRumInternalSchemaV2,
	.get_multikey_status = NULL,
	.get_opclass_metadata = NULL,
	.get_truncation_status = RumGetTruncationStatus,
	.get_reduced_terms_status = RumGetReducedTermsStatus,
	.is_path_key_summarization_scan = RumIsPathKeySummarizationScan,
	.supports_ordered_operator_scans = false,
	.create_indexes_support_funcs = NULL,
	.query_index_path_support_funcs = NULL,
	.get_current_index_key = NULL,
	.skip_tids_on_current_entry = NULL,
};

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

	if (RumIsPathKeySummarizationScan())
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


static IndexScanDesc
extension_rumbeginscan(Relation rel, int nkeys, int norderbys)
{
	EnsureRumLibLoaded();
	return extension_rumbeginscan_core(rel, nkeys, norderbys,
									   &rum_index_routine);
}


static IndexScanDesc
extension_documentdb_rumbeginscan(Relation rel, int nkeys, int norderbys)
{
	EnsureRumLibLoaded();
	return extension_documentdb_rumbeginscan_core(rel, nkeys, norderbys,
												  &rum_index_routine);
}


static void
extension_rumendscan(IndexScanDesc scan)
{
	EnsureRumLibLoaded();
	extension_rumendscan_core(scan, &rum_index_routine);
}


static void
extension_rumrescan(IndexScanDesc scan, ScanKey scankey, int nscankeys,
					ScanKey orderbys, int norderbys)
{
	EnsureRumLibLoaded();
	extension_rumrescan_core(scan, scankey, nscankeys,
							 orderbys, norderbys, &rum_index_routine);
}


static void
extension_documentdb_rumrescan(IndexScanDesc scan, ScanKey scankey, int nscankeys,
							   ScanKey orderbys, int norderbys)
{
	EnsureRumLibLoaded();
	extension_documentdb_rumrescan_core(scan, scankey, nscankeys,
										orderbys, norderbys, &rum_index_routine);
}


static int64
extension_amgetbitmap(IndexScanDesc scan, TIDBitmap *tbm)
{
	EnsureRumLibLoaded();
	return extension_rumgetbitmap_core(scan, tbm, &rum_index_routine);
}


static bool
extension_amgettuple(IndexScanDesc scan, ScanDirection direction)
{
	EnsureRumLibLoaded();
	return extension_rumgettuple_core(scan, direction, &rum_index_routine);
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


static Datum
RumGetMultiKeyStatusSlow(PG_FUNCTION_ARGS)
{
	Relation indexRelation = (Relation) PG_GETARG_POINTER(0);
	EnsureRumLibLoaded();
	PG_RETURN_BOOL(CheckIndexHasArrays(indexRelation, &rum_index_routine));
}


static bool
RumGetTruncationStatus(Relation indexRelation)
{
	EnsureRumLibLoaded();
	return RumGetTruncationStatusCore(indexRelation, &rum_index_routine);
}


static bool
RumGetReducedTermsStatus(Relation indexRelation)
{
	EnsureRumLibLoaded();
	return CheckIndexHasReducedTerms(indexRelation, &rum_index_routine);
}


static bool
RumIsPathKeySummarizationScan(void)
{
	return EnableIndexPathKeySummarization &&
		   loaded_documentdb_rum_routine;
}


static const char *
GetRumCatalogSchema(void)
{
	return ApiCatalogSchemaName;
}


static const char *
GetRumInternalSchemaV2(void)
{
	return ApiInternalSchemaNameV2;
}
