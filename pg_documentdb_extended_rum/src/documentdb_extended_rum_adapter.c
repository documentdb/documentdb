/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/documentdb_extended_rum_adapter.c
 *
 * Initialize rum at the initialization of the index.
 * This has overrides for the documentdb_rum index that is an
 * extensibility access method for documentdb's query engine.
 *
 * This provides an alternate index_am that can be enabled in documentbd
 * using the AlternateIndexHandler before creating indexes.
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/htup_details.h"
#include <miscadmin.h>
#include "pg_documentdb_rum.h"
#include <catalog/pg_am.h>
#include "utils/lsyscache.h"
#include "utils/syscache.h"
#include "commands/defrem.h"
#include "utils/guc.h"

#include "index_am/index_am_exports.h"
#include "index_am/documentdb_rum.h"
#include "query/bson_dollar_selectivity.h"
#include "index_am/documentdb_rum_impl.h"

#include "documentdb_extended_rum_function_catalog.h"


PG_MODULE_MAGIC;

void _PG_init(void);

/* Data Type declarations */
typedef struct DocumentDBRumOidCacheData
{
	Oid DocumentDBRumAmOid;
	Oid BsonDocumentDBRumSinglePathOperatorFamilyId;
	Oid BsonDocumentDBRumCompositePathOperatorFamilyId;
	Oid BsonDocumentDBRumHashedPathOperatorFamilyId;
	Oid DocumentDbExtendedRumUniquePathOperatorFamilyId;
} DocumentDBRumOidCacheData;


/* Method Declarations */
static Oid DocumentDBExtendedRumIndexAmId(void);
static Oid DocumentDBExtendedRumSinglePathOpFamilyOid(void);
static Oid DocumentDBExtendedRumCompositePathOpFamilyOid(void);
static Oid DocumentdbExtendedRumHashedPathOpsFamilyOid(void);
static Oid DocumentDbExtendedRumUniquePathOperatorFamilyOid(void);
static const char * GetDocumentDBCatalogSchema(void);
static void LoadBaseIndexAmRoutine(void);
static bool documentdb_rum_get_truncation_status(Relation indexRelation);
static bool documentdb_rum_is_path_key_summarization_scan(void);
static bool documentdb_rum_get_reduced_terms_status(Relation indexRelation);

static Datum documentdb_rum_get_stats(PG_FUNCTION_ARGS);


/* Static Globals */
static DocumentDBRumOidCacheData Cache = { 0 };
static bool has_custom_routine = false;
static IndexAmRoutine core_rum_routine = { 0 };
static CoreFunctionCatalog core_function_catalog = { 0 };
static void InitializeDocumentDBRum(void);
static void InitializeDocumentDBAdapterGUCs(void);


/* Configs */

/* SystemConfig */
#define DEFAULT_RUM_USE_BUILTIN_RMGR_MODULES false
bool RumUseBuiltinRmgrModules = DEFAULT_RUM_USE_BUILTIN_RMGR_MODULES;

/* Top level method exports */
PG_FUNCTION_INFO_V1(documentdb_extended_rumhandler);
PG_FUNCTION_INFO_V1(documentdb_extended_rum_get_meta_page_info);
PG_FUNCTION_INFO_V1(documentdb_extended_rum_prune_empty_entries_on_index);
PG_FUNCTION_INFO_V1(documentdb_extended_rum_page_get_stats);
PG_FUNCTION_INFO_V1(documentdb_extended_rum_page_get_entries);
PG_FUNCTION_INFO_V1(documentdb_extended_rum_page_get_data_items);
PG_FUNCTION_INFO_V1(documentdb_extended_rum_repair_revive_all_pages_and_tuples);
PG_FUNCTION_INFO_V1(documentdb_extended_rum_test_set_incomplete_split_on_page);

PGDLLEXPORT void
_PG_init(void)
{
	InitializeDocumentDBRum();
}


static void
InitializeDocumentDBRum(void)
{
	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"pg_documentdb_extended_rum can only be loaded via shared_preload_libraries"),
						errdetail_log(
							"Add pg_documentdb_extended_rum to shared_preload_libraries configuration "
							"variable in postgresql.conf. ")));
	}

	InitializeDocumentDBAdapterGUCs();

	LoadBaseIndexAmRoutine();

	static BsonIndexAmEntry documentDBIndexAmEntry = {
		.is_single_path_index_supported = true,
		.is_wild_card_supported = true,
		.is_wild_card_projection_supported = false,
		.is_order_by_supported = true,
		.is_backwards_scan_supported = true,
		.is_index_only_scan_supported = true,
		.can_support_parallel_scans = true,
		.get_am_oid = DocumentDBExtendedRumIndexAmId,
		.get_single_path_op_family_oid = DocumentDBExtendedRumSinglePathOpFamilyOid,
		.get_composite_path_op_family_oid = DocumentDBExtendedRumCompositePathOpFamilyOid,
		.get_text_path_op_family_oid = NULL,
		.get_unique_path_op_family_oid = DocumentDbExtendedRumUniquePathOperatorFamilyOid,
		.get_hashed_path_op_family_oid = DocumentdbExtendedRumHashedPathOpsFamilyOid,
		.add_explain_output = NULL, /* added below */
		.get_stats = documentdb_rum_get_stats,
		.am_name = "extended_rum",
		.get_opclass_catalog_schema = GetDocumentDBCatalogSchema,
		.get_opclass_internal_catalog_schema = GetDocumentDBCatalogSchema,
		.get_multikey_status = NULL, /* added below */
		.get_opclass_metadata = NULL, /* added below */
		.get_truncation_status = documentdb_rum_get_truncation_status,
		.supports_ordered_operator_scans = true,
		.create_indexes_support_funcs = NULL,
		.query_index_path_support_funcs = NULL,
		.get_current_index_key = NULL, /* added below */
		.skip_tids_on_current_entry = NULL, /* added below */
		.get_reduced_terms_status = documentdb_rum_get_reduced_terms_status,
		.is_path_key_summarization_scan = documentdb_rum_is_path_key_summarization_scan,
	};
	documentDBIndexAmEntry.add_explain_output =
		core_function_catalog.try_explain_documentdb_rum_index;
	documentDBIndexAmEntry.get_multikey_status =
		core_function_catalog.documentdb_rum_get_multi_key_status;
	documentDBIndexAmEntry.get_opclass_metadata =
		core_function_catalog.documentdb_rum_get_opclass_metadata;
	documentDBIndexAmEntry.get_current_index_key =
		core_function_catalog.documentdb_rum_get_current_index_key;
	documentDBIndexAmEntry.skip_tids_on_current_entry =
		core_function_catalog.documentdb_rum_skip_tids_on_current_entry;
	RegisterIndexAm(documentDBIndexAmEntry);
}


/* Method implementations */

inline static void
EnsureDocumentDBExtendedRumLib(void)
{
	if (unlikely(!has_custom_routine))
	{
		ereport(ERROR, (errmsg(
							"The documentdb_rum library should be loaded as part of shared_preload_libraries")));
	}
}


static IndexScanDesc
extension_documentdb_extended_rumbeginscan(Relation rel, int nkeys, int norderbys)
{
	EnsureDocumentDBExtendedRumLib();
	return extension_documentdb_rumbeginscan_core(rel, nkeys, norderbys,
												  &core_rum_routine);
}


static void
extension_documentdb_extended_rumrescan(IndexScanDesc scan, ScanKey scankey, int
										nscankeys,
										ScanKey orderbys, int norderbys)
{
	EnsureDocumentDBExtendedRumLib();
	extension_documentdb_rumrescan_core(scan, scankey, nscankeys,
										orderbys, norderbys, &core_rum_routine);
}


static IndexBuildResult *
extension_documentdb_extended_rumbuild(Relation heapRelation,
									   Relation indexRelation,
									   struct IndexInfo *indexInfo)
{
	return extension_rumbuild_core(heapRelation, indexRelation,
								   indexInfo, &core_rum_routine,
								   core_function_catalog.
								   documentdb_rum_update_multi_key_status);
}


static bool
extension_documentdb_extended_ruminsert(Relation indexRelation,
										Datum *values,
										bool *isnull,
										ItemPointer heap_tid,
										Relation heapRelation,
										IndexUniqueCheck checkUnique,
										bool indexUnchanged,
										struct IndexInfo *indexInfo)
{
	return extension_ruminsert_core(indexRelation, values, isnull,
									heap_tid, heapRelation, checkUnique,
									indexUnchanged, indexInfo,
									&core_rum_routine,
									core_function_catalog.
									documentdb_rum_update_multi_key_status);
}


static void
LoadBaseIndexAmRoutine(void)
{
	LOCAL_FCINFO(fcinfo, 0);

	/* Load the core documentdb_rum functions */
	if (RumUseBuiltinRmgrModules)
	{
		core_function_catalog = GetBuiltInRmgrFunctionCatalog();
	}
	else
	{
		core_function_catalog = GetCoreFunctionCatalog();
	}

	InitFunctionCallInfoData(*fcinfo, NULL, 1, InvalidOid, NULL, NULL);
	IndexAmRoutine *amroutine = (IndexAmRoutine *) DatumGetPointer(
		core_function_catalog.documentdb_rumhandler(fcinfo));

	/* Store the base routine */
	core_rum_routine = *amroutine;
	has_custom_routine = true;
}


static const char *
GetDocumentDBCatalogSchema(void)
{
	return "documentdb_extended_rum_catalog";
}


static Oid
DocumentDBExtendedRumIndexAmId(void)
{
	if (Cache.DocumentDBRumAmOid == InvalidOid)
	{
		HeapTuple tuple = SearchSysCache1(AMNAME, CStringGetDatum(
											  "documentdb_extended_rum"));
		if (!HeapTupleIsValid(tuple))
		{
			return InvalidOid;
		}

		Form_pg_am accessMethodForm = (Form_pg_am) GETSTRUCT(tuple);
		Cache.DocumentDBRumAmOid = accessMethodForm->oid;
		ReleaseSysCache(tuple);
	}

	return Cache.DocumentDBRumAmOid;
}


static Oid
DocumentDBExtendedRumSinglePathOpFamilyOid(void)
{
	if (Cache.BsonDocumentDBRumSinglePathOperatorFamilyId == InvalidOid)
	{
		bool missingOk = false;
		Cache.BsonDocumentDBRumSinglePathOperatorFamilyId = get_opfamily_oid(
			DocumentDBExtendedRumIndexAmId(),
			list_make2(makeString((char *) GetDocumentDBCatalogSchema()), makeString(
						   "bson_extended_rum_single_path_ops")),
			missingOk);
	}

	return Cache.BsonDocumentDBRumSinglePathOperatorFamilyId;
}


static Oid
DocumentdbExtendedRumHashedPathOpsFamilyOid(void)
{
	if (Cache.BsonDocumentDBRumHashedPathOperatorFamilyId == InvalidOid)
	{
		bool missingOk = false;
		Cache.BsonDocumentDBRumHashedPathOperatorFamilyId = get_opfamily_oid(
			DocumentDBExtendedRumIndexAmId(),
			list_make2(makeString((char *) GetDocumentDBCatalogSchema()), makeString(
						   "documentdb_extended_rum_hashed_ops")),
			missingOk);
	}

	return Cache.BsonDocumentDBRumHashedPathOperatorFamilyId;
}


static Oid
DocumentDbExtendedRumUniquePathOperatorFamilyOid(void)
{
	if (Cache.DocumentDbExtendedRumUniquePathOperatorFamilyId == InvalidOid)
	{
		bool missingOk = false;
		Cache.DocumentDbExtendedRumUniquePathOperatorFamilyId = get_opfamily_oid(
			DocumentDBExtendedRumIndexAmId(),
			list_make2(makeString((char *) GetDocumentDBCatalogSchema()), makeString(
						   "bson_extended_rum_unique_shard_path_ops")),
			missingOk);
	}

	return Cache.DocumentDbExtendedRumUniquePathOperatorFamilyId;
}


static Oid
DocumentDBExtendedRumCompositePathOpFamilyOid(void)
{
	if (Cache.BsonDocumentDBRumCompositePathOperatorFamilyId == InvalidOid)
	{
		bool missingOk = false;
		Cache.BsonDocumentDBRumCompositePathOperatorFamilyId = get_opfamily_oid(
			DocumentDBExtendedRumIndexAmId(),
			list_make2(makeString((char *) GetDocumentDBCatalogSchema()), makeString(
						   "bson_extended_rum_composite_path_ops")),
			missingOk);
	}

	return Cache.BsonDocumentDBRumCompositePathOperatorFamilyId;
}


static void
extension_documentdb_extended_rumcostestimate(PlannerInfo *root, IndexPath *path,
											  double loop_count,
											  Cost *indexStartupCost,
											  Cost *indexTotalCost,
											  Selectivity *indexSelectivity,
											  double *indexCorrelation,
											  double *indexPages)
{
	/* Do not force index cost to zero unless explicitly requested */
	bool enableCompositePlannerCosts = EnablePlannerCostSelectivityFromRelOptInfo(root,
																				  path->
																				  indexinfo
																				  ->rel);
	bool forceIndexCostToZero = !enableCompositePlannerCosts;
	extension_rumcostestimate_core(root, path, loop_count, indexStartupCost,
								   indexTotalCost, indexSelectivity, indexCorrelation,
								   indexPages, &core_rum_routine,
								   forceIndexCostToZero, enableCompositePlannerCosts,
								   core_function_catalog.DocumentDBRumOrderedCostEstimate);
}


PGDLLEXPORT Datum
documentdb_extended_rumhandler(PG_FUNCTION_ARGS)
{
	/* Ensure that the base rum handler is loaded */
	if (!has_custom_routine)
	{
		LoadBaseIndexAmRoutine();
	}

	IndexAmRoutine *amroutine = (IndexAmRoutine *) palloc0(sizeof(IndexAmRoutine));
	*amroutine = core_rum_routine;

	amroutine->ambeginscan = extension_documentdb_extended_rumbeginscan;
	amroutine->amrescan = extension_documentdb_extended_rumrescan;
	amroutine->ambuild = extension_documentdb_extended_rumbuild;
	amroutine->aminsert = extension_documentdb_extended_ruminsert;
	amroutine->amcostestimate = extension_documentdb_extended_rumcostestimate;
	PG_RETURN_POINTER(amroutine);
}


PGDLLEXPORT Datum
documentdb_extended_rum_get_meta_page_info(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_get_meta_page_info(fcinfo);
}


PGDLLEXPORT Datum
documentdb_extended_rum_prune_empty_entries_on_index(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_prune_empty_entries_on_index(fcinfo);
}


PGDLLEXPORT Datum
documentdb_extended_rum_page_get_stats(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_page_get_stats(fcinfo);
}


PGDLLEXPORT Datum
documentdb_extended_rum_page_get_entries(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_page_get_entries(fcinfo);
}


PGDLLEXPORT Datum
documentdb_extended_rum_page_get_data_items(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_page_get_data_items(fcinfo);
}


PGDLLEXPORT Datum
documentdb_extended_rum_repair_revive_all_pages_and_tuples(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_repair_revive_all_pages_and_tuples(
		fcinfo);
}


PGDLLEXPORT Datum
documentdb_extended_rum_test_set_incomplete_split_on_page(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_test_set_incomplete_split_on_page(fcinfo);
}


static bool
documentdb_rum_get_truncation_status(Relation indexRelation)
{
	EnsureDocumentDBExtendedRumLib();
	return RumGetTruncationStatusCore(indexRelation, &core_rum_routine);
}


static bool
documentdb_rum_is_path_key_summarization_scan(void)
{
	return true;
}


static bool
documentdb_rum_get_reduced_terms_status(Relation indexRelation)
{
	EnsureDocumentDBExtendedRumLib();
	return CheckIndexHasReducedTerms(indexRelation, &core_rum_routine);
}


static void
InitializeDocumentDBAdapterGUCs(void)
{
	DefineCustomBoolVariable(
		"documentdb_extended_rum.rum_use_builtin_rmgr_modules",
		"Sets whether or not to use built-in rmgr modules",
		NULL,
		&RumUseBuiltinRmgrModules,
		DEFAULT_RUM_USE_BUILTIN_RMGR_MODULES,
		PGC_POSTMASTER, 0,
		NULL, NULL, NULL);
}


static Datum
documentdb_rum_get_stats(PG_FUNCTION_ARGS)
{
	EnsureDocumentDBExtendedRumLib();
	return core_function_catalog.documentdb_rum_get_stats(fcinfo);
}
