/*-------------------------------------------------------------------------
 *
 * pg_documentdb_extended_rum_function_catalog.h
 *	  Exported definitions for the documentdb extended rum function catalog.
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 2006-2022, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */

#ifndef __PG_DOCUMENTDB_EXTENDED_RUM_FUNCTION_CATALOG_H__
#define __PG_DOCUMENTDB_EXTENDED_RUM_FUNCTION_CATALOG_H__

#include <postgres.h>
#include <fmgr.h>

typedef struct CoreFunctionCatalog
{
	PGFunction try_explain_documentdb_rum_index;
	PGFunction documentdb_rumhandler;
	PGFunction documentdb_rum_get_multi_key_status;
	PGFunction documentdb_rum_get_opclass_metadata;
	PGFunction documentdb_rum_update_multi_key_status;
	PGFunction documentdb_rum_get_current_index_key;
	PGFunction documentdb_rum_skip_tids_on_current_entry;
	PGFunction DocumentDBRumOrderedCostEstimate;
	PGFunction documentdb_rum_get_meta_page_info;
	PGFunction documentdb_rum_prune_empty_entries_on_index;
	PGFunction documentdb_rum_page_get_stats;
	PGFunction documentdb_rum_page_get_entries;
	PGFunction documentdb_rum_page_get_data_items;
	PGFunction documentdb_rum_repair_revive_all_pages_and_tuples;
	PGFunction documentdb_rum_test_set_incomplete_split_on_page;
	PGFunction documentdb_rum_get_stats;
} CoreFunctionCatalog;


CoreFunctionCatalog GetCoreFunctionCatalog(void);
CoreFunctionCatalog GetBuiltInRmgrFunctionCatalog(void);

#endif /* __PG_DOCUMENTDB_EXTENDED_RUM_FUNCTION_CATALOG_H__ */
