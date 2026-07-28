/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/documentdb_extended_rum_function_catalog.c
 *
 * Initialize the documentdb extended rum function catalog.
 * This has overrides for the documentdb_rum index that is an
 * extensibility access method for documentdb's query engine.
 *
 * This provides an alternate index_am that can be enabled in documentbd
 * using the AlternateIndexHandler before creating indexes.
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include <miscadmin.h>

#include "documentdb_extended_rum_function_catalog.h"

/* Standard rmgr function catalog */
extern PGDLLIMPORT Datum try_explain_documentdb_rum_index(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rumhandler(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_get_multi_key_status(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_get_opclass_metadata(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_update_multi_key_status(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_get_current_index_key(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_skip_tids_on_current_entry(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum DocumentDBRumOrderedCostEstimate(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_get_meta_page_info(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_prune_empty_entries_on_index(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_page_get_stats(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_page_get_entries(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_page_get_data_items(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_repair_revive_all_pages_and_tuples(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum documentdb_rum_test_set_incomplete_split_on_page(
	PG_FUNCTION_ARGS);

/* Built-in rmgr function catalog */
extern PGDLLIMPORT Datum builtin_rmgr_try_explain_documentdb_rum_index(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rumhandler(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_get_multi_key_status(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_get_opclass_metadata(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_update_multi_key_status(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_get_current_index_key(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_skip_tids_on_current_entry(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_DocumentDBRumOrderedCostEstimate(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_get_meta_page_info(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_prune_empty_entries_on_index(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_page_get_stats(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_page_get_entries(PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_page_get_data_items(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_repair_revive_all_pages_and_tuples(
	PG_FUNCTION_ARGS);
extern PGDLLIMPORT Datum builtin_rmgr_documentdb_rum_test_set_incomplete_split_on_page(
	PG_FUNCTION_ARGS);

CoreFunctionCatalog
GetCoreFunctionCatalog(void)
{
	return (CoreFunctionCatalog) {
			   .try_explain_documentdb_rum_index = try_explain_documentdb_rum_index,
			   .documentdb_rumhandler = documentdb_rumhandler,
			   .documentdb_rum_get_multi_key_status = documentdb_rum_get_multi_key_status,
			   .documentdb_rum_get_opclass_metadata = documentdb_rum_get_opclass_metadata,
			   .documentdb_rum_update_multi_key_status =
				   documentdb_rum_update_multi_key_status,
			   .documentdb_rum_get_current_index_key =
				   documentdb_rum_get_current_index_key,
			   .documentdb_rum_skip_tids_on_current_entry =
				   documentdb_rum_skip_tids_on_current_entry,
			   .DocumentDBRumOrderedCostEstimate = DocumentDBRumOrderedCostEstimate,
			   .documentdb_rum_get_meta_page_info = documentdb_rum_get_meta_page_info,
			   .documentdb_rum_prune_empty_entries_on_index =
				   documentdb_rum_prune_empty_entries_on_index,
			   .documentdb_rum_page_get_stats = documentdb_rum_page_get_stats,
			   .documentdb_rum_page_get_entries = documentdb_rum_page_get_entries,
			   .documentdb_rum_page_get_data_items = documentdb_rum_page_get_data_items,
			   .documentdb_rum_repair_revive_all_pages_and_tuples =
				   documentdb_rum_repair_revive_all_pages_and_tuples,
			   .documentdb_rum_test_set_incomplete_split_on_page =
				   documentdb_rum_test_set_incomplete_split_on_page
	};
}


CoreFunctionCatalog
GetBuiltInRmgrFunctionCatalog(void)
{
	return (CoreFunctionCatalog) {
			   .try_explain_documentdb_rum_index =
				   builtin_rmgr_try_explain_documentdb_rum_index,
			   .documentdb_rumhandler = builtin_rmgr_documentdb_rumhandler,
			   .documentdb_rum_get_multi_key_status =
				   builtin_rmgr_documentdb_rum_get_multi_key_status,
			   .documentdb_rum_get_opclass_metadata =
				   builtin_rmgr_documentdb_rum_get_opclass_metadata,
			   .documentdb_rum_update_multi_key_status =
				   builtin_rmgr_documentdb_rum_update_multi_key_status,
			   .documentdb_rum_get_current_index_key =
				   builtin_rmgr_documentdb_rum_get_current_index_key,
			   .documentdb_rum_skip_tids_on_current_entry =
				   builtin_rmgr_documentdb_rum_skip_tids_on_current_entry,
			   .DocumentDBRumOrderedCostEstimate =
				   builtin_rmgr_DocumentDBRumOrderedCostEstimate,
			   .documentdb_rum_get_meta_page_info =
				   builtin_rmgr_documentdb_rum_get_meta_page_info,
			   .documentdb_rum_prune_empty_entries_on_index =
				   builtin_rmgr_documentdb_rum_prune_empty_entries_on_index,
			   .documentdb_rum_page_get_stats =
				   builtin_rmgr_documentdb_rum_page_get_stats,
			   .documentdb_rum_page_get_entries =
				   builtin_rmgr_documentdb_rum_page_get_entries,
			   .documentdb_rum_page_get_data_items =
				   builtin_rmgr_documentdb_rum_page_get_data_items,
			   .documentdb_rum_repair_revive_all_pages_and_tuples =
				   builtin_rmgr_documentdb_rum_repair_revive_all_pages_and_tuples,
			   .documentdb_rum_test_set_incomplete_split_on_page =
				   builtin_rmgr_documentdb_rum_test_set_incomplete_split_on_page
	};
}
