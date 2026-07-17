/*-------------------------------------------------------------------------
 *
 * rumconfig.c
 *	  utilities routines for the configuration management for RUM indexes.
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "utils/guc.h"
#include "access/reloptions.h"

#include "pg_documentdb_rum_exports.h"

PGDLLEXPORT void InitializeCommonDocumentDBGUCs(const char *rumGucPrefix, const
												char *documentDBRumGucPrefix);
extern PGDLLEXPORT void DocumentDBSetRumUnredactedLogEmitHook(rum_format_log_hook hook);

PGDLLEXPORT bool DocumentDBRumLoadCommonGUCs = true;

/* TestingConfig */
#define RUM_DEFAULT_THROW_ERROR_ON_INVALID_DATA_PAGE false
PGDLLEXPORT bool RumThrowErrorOnInvalidDataPage =
	RUM_DEFAULT_THROW_ERROR_ON_INVALID_DATA_PAGE;

/* rumbtree.c */
/* FeatureFlag: Added in v108, enabled in v108, remove after v121 */
#define RUM_DEFAULT_TRACK_INCOMPLETE_SPLIT true
PGDLLEXPORT bool RumTrackIncompleteSplit = RUM_DEFAULT_TRACK_INCOMPLETE_SPLIT;

/* FeatureFlag: Added in v114, enabled in v114, remove after v125 */
#define RUM_DEFAULT_ALLOW_REPLACE_ON_INSERT_TUPLE true
PGDLLEXPORT bool RumAllowReplaceOnInsertTuple = RUM_DEFAULT_ALLOW_REPLACE_ON_INSERT_TUPLE;

/* TestingConfig: This is not ready for real consumption */
#define RUM_DEFAULT_ENABLE_XLOG_INSERT_ENTRY false
PGDLLEXPORT bool RumEnableXlogInsertEntry = RUM_DEFAULT_ENABLE_XLOG_INSERT_ENTRY;

/* TestingConfig: This is not ready for real consumption */
#define RUM_DEFAULT_ENABLE_CUSTOM_XLOG_RMRG false
PGDLLEXPORT bool EnableCustomXlogRmgr = RUM_DEFAULT_ENABLE_CUSTOM_XLOG_RMRG;

/* FeatureFlag: Added in v114, enabled in v114, remove after v118 */
#define RUM_DEFAULT_ENABLE_COMPARE_FUNCTION_FMGR true
PGDLLEXPORT bool EnableRumCompareFunctionFmgr = RUM_DEFAULT_ENABLE_COMPARE_FUNCTION_FMGR;

/* FeatureFlag: Added in v108, enabled in v108, remove after v121 */
#define RUM_DEFAULT_FIX_INCOMPLETE_SPLIT true
PGDLLEXPORT bool RumFixIncompleteSplit = RUM_DEFAULT_FIX_INCOMPLETE_SPLIT;

/* TestingConfig */
#define RUM_DEFAULT_ENABLE_INJECT_PAGE_SPLIT_INCOMPLETE false
PGDLLEXPORT bool RumInjectPageSplitIncomplete =
	RUM_DEFAULT_ENABLE_INJECT_PAGE_SPLIT_INCOMPLETE;

/* TestingConfig */
#define RUM_DEFAULT_INJECT_SPLIT_ENTRY_INTERNAL_ONLY false
PGDLLEXPORT bool RumInjectSplitEntryInternalOnly =
	RUM_DEFAULT_INJECT_SPLIT_ENTRY_INTERNAL_ONLY;

/* TestingConfig: Controls whether the leader participates as a worker during a
 * parallel index build. Defaults to true (matching the normal build behavior);
 * tests set this to false to force all heap scanning onto parallel workers.
 */
#define RUM_DEFAULT_PARALLEL_INDEX_BUILD_LEADER_PARTICIPATES true
PGDLLEXPORT bool RumParallelIndexBuildLeaderParticipates =
	RUM_DEFAULT_PARALLEL_INDEX_BUILD_LEADER_PARTICIPATES;

/* rumentrypage.c */
/* SystemConfig */
PGDLLEXPORT int RumDefaultPageFillFactor = RUM_DEFAULT_FILL_FACTOR;

/* rumdatapage.c */
/* TestingConfig */
#define DEFAULT_RUM_DATA_PAGE_INTERMEDIATE_SPLIT_SIZE -1
PGDLLEXPORT int RumDataPageIntermediateSplitSize =
	DEFAULT_RUM_DATA_PAGE_INTERMEDIATE_SPLIT_SIZE;

/* TestingConfig */
#define RUM_DEFAULT_SKIP_RESET_ON_DEAD_ENTRY_PAGE false
PGDLLEXPORT bool RumSkipResetOnDeadEntryPage = RUM_DEFAULT_SKIP_RESET_ON_DEAD_ENTRY_PAGE;

/* rumget.c */
/* SystemConfig */
#define RUM_DEFAULT_FUZZY_SEARCH_LIMIT 0
PGDLLEXPORT int RumFuzzySearchLimit = RUM_DEFAULT_FUZZY_SEARCH_LIMIT;

/* SystemConfig */
#define RUM_DEFAULT_DISABLE_FAST_SCAN false
PGDLLEXPORT bool RumDisableFastScan = RUM_DEFAULT_DISABLE_FAST_SCAN;

/* TestingConfig */
#define RUM_DEFAULT_FORCE_RUM_ORDERED_INDEX_SCAN false
PGDLLEXPORT bool RumForceOrderedIndexScan = RUM_DEFAULT_FORCE_RUM_ORDERED_INDEX_SCAN;

/* FeatureFlag: Added in v108, enabled in v108, remove after v121 */
#define RUM_DEFAULT_ENABLE_SKIP_INTERMEDIATE_ENTRY true
PGDLLEXPORT bool RumEnableSkipIntermediateEntry =
	RUM_DEFAULT_ENABLE_SKIP_INTERMEDIATE_ENTRY;

/* TestingConfig */
#define RUM_DEFAULT_PARALLEL_INDEX_WORKERS_OVERRIDE -1
PGDLLEXPORT int RumParallelIndexWorkersOverride =
	RUM_DEFAULT_PARALLEL_INDEX_WORKERS_OVERRIDE;

/* FeatureFlag: Added in v110, enabled in v112, remove after v125  */
#define RUM_DEFAULT_ENABLE_PARALLEL_INDEX_BUILD true
PGDLLEXPORT bool RumEnableParallelIndexBuild = RUM_DEFAULT_ENABLE_PARALLEL_INDEX_BUILD;

/* rumvacuum.c */
/* FeatureFlag: Added in v108, enabled in v108, remove after v120 */
#define RUM_DEFAULT_SKIP_RETRY_ON_DELETE_PAGE true
PGDLLEXPORT bool RumSkipRetryOnDeletePage = RUM_DEFAULT_SKIP_RETRY_ON_DELETE_PAGE;

/* FeatureFlag: Added in v108, Pending stabilization, enable on v116  */
#define RUM_DEFAULT_PRUNE_EMPTY_PAGES false
PGDLLEXPORT bool RumPruneEmptyPages = RUM_DEFAULT_PRUNE_EMPTY_PAGES;

/* FeatureFlag: Added on v108, enabled in v113, remove after v125 */
#define RUM_DEFAULT_ENABLE_NEW_BULK_DELETE true
PGDLLEXPORT bool RumEnableNewBulkDelete = RUM_DEFAULT_ENABLE_NEW_BULK_DELETE;

/* FeatureFlag: Added in v108, Pending stabilization, enable on v116 */
#define RUM_DEFAULT_ENABLE_NEW_BULK_DELETE_INLINE_DATA_PAGES false
PGDLLEXPORT bool RumNewBulkDeleteInlineDataPages =
	RUM_DEFAULT_ENABLE_NEW_BULK_DELETE_INLINE_DATA_PAGES;

/* FeatureFlag: Added in v115, enabled in v115, remove after v125 */
#define RUM_DEFAULT_ENABLE_ENTRY_PAGE_STEP true
PGDLLEXPORT bool RumEnableEntryPageStep = RUM_DEFAULT_ENABLE_ENTRY_PAGE_STEP;

/* SystemConfig */
#define RUM_DEFAULT_SKIP_PRUNE_POSTING_TREE_PAGES false
PGDLLEXPORT bool RumVacuumSkipPrunePostingTreePages =
	RUM_DEFAULT_SKIP_PRUNE_POSTING_TREE_PAGES;

/* TestingConfig */
#define RUM_DEFAULT_VACUUM_CYCLE_ID_OVERRIDE -1
int32_t RumVacuumCycleIdOverride = RUM_DEFAULT_VACUUM_CYCLE_ID_OVERRIDE;

/* TestingConfig */
#define RUM_DEFAULT_TRAVERSE_PAGE_ONLY_ON_BACKTRACK false
PGDLLEXPORT bool RumTraversePageOnlyOnBackTrack =
	RUM_DEFAULT_TRAVERSE_PAGE_ONLY_ON_BACKTRACK;

/* TestingConfig */
#define RUM_DEFAULT_SKIP_GLOBAL_VISIBILITY_CHECK_ON_PRUNE false
PGDLLEXPORT bool RumSkipGlobalVisibilityCheckOnPrune =
	RUM_DEFAULT_SKIP_GLOBAL_VISIBILITY_CHECK_ON_PRUNE;

/* FeatureFlag: Added in v113, enabled in v113, remove after v120 */
#define RUM_DEFAULT_ENABLE_OVERWRITE_ENTRY_TUPLE_ON_VACUUM true
PGDLLEXPORT bool RumEnableOverwriteEntryTupleOnVacuum =
	RUM_DEFAULT_ENABLE_OVERWRITE_ENTRY_TUPLE_ON_VACUUM;

/* FeatureFlag: Added in v114, Pending stabilization, enable on v117 */
#define RUM_DEFAULT_ENABLE_TARGETED_POSTING_TREE_PRUNING false
PGDLLEXPORT bool RumEnableTargetedPostingTreePruning =
	RUM_DEFAULT_ENABLE_TARGETED_POSTING_TREE_PRUNING;

/* FeatureFlag: Added in v115, Pending stabilization, enable on v118 */
#define RUM_DEFAULT_ENABLE_SINGLE_PASS_POSTING_TREE_VACUUM false
PGDLLEXPORT bool RumEnableSinglePassPostingTreeVacuum =
	RUM_DEFAULT_ENABLE_SINGLE_PASS_POSTING_TREE_VACUUM;

/* rumget.c */
/* FeatureFlag: Added in v109, Pending stabilization, enable on v116 */
#define RUM_DEFAULT_ENABLE_SUPPORT_DEAD_INDEX_ITEMS false
PGDLLEXPORT bool RumEnableSupportDeadIndexItems =
	RUM_DEFAULT_ENABLE_SUPPORT_DEAD_INDEX_ITEMS;

/* rumutil.c */
/* TestingConfig: This is not ready for real consumption */
#define RUM_DEFAULT_ENABLE_EMIT_REUSE_PAGE_ON_RECYCLE false
PGDLLEXPORT bool RumEnableEmitReusePageOnRecycle =
	RUM_DEFAULT_ENABLE_EMIT_REUSE_PAGE_ON_RECYCLE;

/* FeatureFlag: Added on v108, Enabled in v108, remove after v116 */
#define RUM_DEFAULT_ENABLE_ORDERED_OPERATOR_SCANS true
PGDLLEXPORT bool RumEnableOrderedOperatorScans =
	RUM_DEFAULT_ENABLE_ORDERED_OPERATOR_SCANS;

/* FeatureFlag: Added in v113, Enabled in v113, remove after v125 */
#define RUM_DEFAULT_ENABLE_PAGE_FILL_FACTOR true
PGDLLEXPORT bool RumEnablePageFillFactor =
	RUM_DEFAULT_ENABLE_PAGE_FILL_FACTOR;

/* FeatureFlag: Added in v113, Enabled in v113, remove after v125 */
#define RUM_DEFAULT_ENABLE_BTREE_LOCK_ORDER true
PGDLLEXPORT bool RumEnableBtreeLockOrder = RUM_DEFAULT_ENABLE_BTREE_LOCK_ORDER;

/* roaring_bitmap_adapter.c
 * Minimum serialized size (in bytes) of the dedup bitmap before
 * run-optimize/shrink-to-fit are applied prior to serialization. These
 * optimizations cost O(cardinality) per serialize, so for small bitmaps the
 * cost outweighs the space savings; only pay it once the bitmap is large. */

/* SystemConfig */
#define RUM_DEFAULT_DEDUP_SERIALIZE_OPTIMIZE_THRESHOLD_BYTES (1024 * 1024)
PGDLLEXPORT int RumDedupSerializeOptimizeThresholdBytes =
	RUM_DEFAULT_DEDUP_SERIALIZE_OPTIMIZE_THRESHOLD_BYTES;

PGDLLEXPORT rum_format_log_hook rum_unredacted_log_emit_hook = NULL;


PGDLLEXPORT void
DocumentDBSetRumUnredactedLogEmitHook(rum_format_log_hook hook)
{
	rum_unredacted_log_emit_hook = hook;
}


PGDLLEXPORT void
InitializeCommonDocumentDBGUCs(const char *rumGucPrefix, const
							   char *documentDBRumGucPrefix)
{
	DefineCustomIntVariable(psprintf("%s.rum_fuzzy_search_limit", rumGucPrefix),
							"Sets the maximum allowed result for exact search by RUM.",
							NULL,
							&RumFuzzySearchLimit,
							0, 0, INT_MAX,
							PGC_USERSET, 0,
							NULL, NULL, NULL);

	DefineCustomIntVariable(psprintf("%s.data_page_posting_tree_size", rumGucPrefix),
							"Test GUC that sets the data page size before splits.",
							NULL,
							&RumDataPageIntermediateSplitSize,
							-1, -1, INT_MAX,
							PGC_USERSET, 0,
							NULL, NULL, NULL);

	DefineCustomBoolVariable(psprintf("%s.rum_skip_retry_on_delete_page",
									  documentDBRumGucPrefix),
							 "Sets whether or not to skip retrying on delete pages during vacuuming",
							 NULL,
							 &RumSkipRetryOnDeletePage,
							 RUM_DEFAULT_SKIP_RETRY_ON_DELETE_PAGE,
							 PGC_USERSET, 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.rum_throw_error_on_invalid_data_page", documentDBRumGucPrefix),
		"Sets whether or not to throw an error on invalid data page",
		NULL,
		&RumThrowErrorOnInvalidDataPage,
		RUM_DEFAULT_THROW_ERROR_ON_INVALID_DATA_PAGE,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.rum_disable_fast_scan", documentDBRumGucPrefix),
		"Sets whether or not to disable fast scan",
		NULL,
		&RumDisableFastScan,
		RUM_DEFAULT_DISABLE_FAST_SCAN,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomIntVariable(
		psprintf("%s.parallel_index_workers_override", documentDBRumGucPrefix),
		"Sets the number of parallel index workers to use (default: -1, meaning no override)",
		NULL,
		&RumParallelIndexWorkersOverride,
		RUM_DEFAULT_PARALLEL_INDEX_WORKERS_OVERRIDE, -1, INT_MAX,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_parallel_index_build", documentDBRumGucPrefix),
		"Sets whether or not to enable parallel index build",
		NULL,
		&RumEnableParallelIndexBuild,
		RUM_DEFAULT_ENABLE_PARALLEL_INDEX_BUILD,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.forceRumOrderedIndexScan", documentDBRumGucPrefix),
		"Sets whether or not to force a run ordered index scan",
		NULL,
		&RumForceOrderedIndexScan,
		RUM_DEFAULT_FORCE_RUM_ORDERED_INDEX_SCAN,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSkipIntermediateEntry", documentDBRumGucPrefix),
		"Sets whether or not to skip intermediate entries during scan",
		NULL,
		&RumEnableSkipIntermediateEntry,
		RUM_DEFAULT_ENABLE_SKIP_INTERMEDIATE_ENTRY,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_inject_page_split_incomplete", documentDBRumGucPrefix),
		"Test GUC - sets whether or not to enable injecting a failure in the middle of a page split",
		NULL,
		&RumInjectPageSplitIncomplete,
		RUM_DEFAULT_ENABLE_INJECT_PAGE_SPLIT_INCOMPLETE,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.inject_split_entry_internal_only", documentDBRumGucPrefix),
		"Test GUC - only inject split failure on entry internal page splits (when childbuf is valid)",
		NULL,
		&RumInjectSplitEntryInternalOnly,
		RUM_DEFAULT_INJECT_SPLIT_ENTRY_INTERNAL_ONLY,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.parallel_index_build_leader_participates", documentDBRumGucPrefix),
		"Test GUC - controls whether the leader participates as a worker during a parallel index build",
		NULL,
		&RumParallelIndexBuildLeaderParticipates,
		RUM_DEFAULT_PARALLEL_INDEX_BUILD_LEADER_PARTICIPATES,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.prune_rum_empty_pages", documentDBRumGucPrefix),
		"Sets whether or not to prune empty pages during vacuuming",
		NULL,
		&RumPruneEmptyPages,
		RUM_DEFAULT_PRUNE_EMPTY_PAGES,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_new_bulk_delete", documentDBRumGucPrefix),
		"Sets whether or not to the new bulk delete vacuum framework",
		NULL,
		&RumEnableNewBulkDelete,
		RUM_DEFAULT_ENABLE_NEW_BULK_DELETE,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_new_bulk_delete_inline_data_pages", documentDBRumGucPrefix),
		"Sets whether or not to delete data pages inline in the new bulkdel framework",
		NULL,
		&RumNewBulkDeleteInlineDataPages,
		RUM_DEFAULT_ENABLE_NEW_BULK_DELETE_INLINE_DATA_PAGES,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_entry_page_step", documentDBRumGucPrefix),
		"Sets whether or not to enable entry page stepping",
		NULL,
		&RumEnableEntryPageStep,
		RUM_DEFAULT_ENABLE_ENTRY_PAGE_STEP,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.vacuum_skip_prune_posting_tree_pages", documentDBRumGucPrefix),
		"Sets whether or not to delete data pages inline in the new bulkdel framework",
		NULL,
		&RumVacuumSkipPrunePostingTreePages,
		RUM_DEFAULT_SKIP_PRUNE_POSTING_TREE_PAGES,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_support_dead_index_items", documentDBRumGucPrefix),
		"Sets whether or not to enable support for handling LP_DEAD items",
		NULL,
		&RumEnableSupportDeadIndexItems,
		RUM_DEFAULT_ENABLE_SUPPORT_DEAD_INDEX_ITEMS,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_emit_reuse_page_on_recycle", documentDBRumGucPrefix),
		"Test GUC - emit a btree REUSE_PAGE WAL marker before reusing a vacuum-deleted RUM page from the FSM, so streaming standbys resolve recovery conflicts before the page contents are overwritten. Not ready for real consumption.",
		NULL,
		&RumEnableEmitReusePageOnRecycle,
		RUM_DEFAULT_ENABLE_EMIT_REUSE_PAGE_ON_RECYCLE,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.skip_reset_dead_page_flag", documentDBRumGucPrefix),
		"Sets whether or not to enable support for handling LP_DEAD items",
		NULL,
		&RumSkipResetOnDeadEntryPage,
		RUM_DEFAULT_SKIP_RESET_ON_DEAD_ENTRY_PAGE,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomIntVariable(
		psprintf("%s.vacuum_cycle_id_override", documentDBRumGucPrefix),
		"test only override for setting the vacuum cycle id",
		NULL,
		&RumVacuumCycleIdOverride,
		RUM_DEFAULT_VACUUM_CYCLE_ID_OVERRIDE, -1, UINT16_MAX,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.default_traverse_rum_page_only_on_backtrack",
				 documentDBRumGucPrefix),
		"test only guc to only traverse vacuum pages on the backtrack path",
		NULL,
		&RumTraversePageOnlyOnBackTrack,
		RUM_DEFAULT_TRAVERSE_PAGE_ONLY_ON_BACKTRACK,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.skip_global_visibility_check_on_prune",
				 documentDBRumGucPrefix),
		"test only guc to skip checking visibility on pruning pages",
		NULL,
		&RumSkipGlobalVisibilityCheckOnPrune,
		RUM_DEFAULT_TRAVERSE_PAGE_ONLY_ON_BACKTRACK,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_overwrite_entry_tuple_on_vacuum", documentDBRumGucPrefix),
		"Sets whether or not to overwrite entry tuples during vacuum, as opposed to deleting and readding them",
		NULL,
		&RumEnableOverwriteEntryTupleOnVacuum,
		RUM_DEFAULT_ENABLE_OVERWRITE_ENTRY_TUPLE_ON_VACUUM,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_targeted_posting_tree_pruning", documentDBRumGucPrefix),
		"Enables targeted pruning of empty posting tree pages during vacuum",
		NULL,
		&RumEnableTargetedPostingTreePruning,
		RUM_DEFAULT_ENABLE_TARGETED_POSTING_TREE_PRUNING,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_single_pass_posting_tree_vacuum", documentDBRumGucPrefix),
		"Prunes empty posting tree leaf pages in a single pass during bulk-delete instead of a separate pruning pass",
		"Only applies when posting-tree data pages are not vacuumed inline "
		"(enable_new_bulk_delete_inline_data_pages = off). When inline data-page "
		"vacuum is on, structural pruning is deferred to vacuumcleanup and this "
		"setting has no effect.",
		&RumEnableSinglePassPostingTreeVacuum,
		RUM_DEFAULT_ENABLE_SINGLE_PASS_POSTING_TREE_VACUUM,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.track_incomplete_split", documentDBRumGucPrefix),
		"Sets whether or not to track incomplete splits",
		NULL,
		&RumTrackIncompleteSplit,
		RUM_DEFAULT_TRACK_INCOMPLETE_SPLIT,
		PGC_USERSET, 0,
		NULL, NULL, NULL);
	DefineCustomBoolVariable(
		psprintf("%s.allow_replace_on_insert_tuple", documentDBRumGucPrefix),
		"Sets whether or not to allow replacing an existing tuple on insert",
		NULL,
		&RumAllowReplaceOnInsertTuple,
		RUM_DEFAULT_ALLOW_REPLACE_ON_INSERT_TUPLE,
		PGC_USERSET, 0,
		NULL, NULL, NULL);
	DefineCustomBoolVariable(
		psprintf("%s.enable_xlog_insert_entry", documentDBRumGucPrefix),
		"Sets whether or not to enable XLOG insert entry",
		NULL,
		&RumEnableXlogInsertEntry,
		RUM_DEFAULT_ENABLE_XLOG_INSERT_ENTRY,
		PGC_USERSET, 0,
		NULL, NULL, NULL);
	DefineCustomBoolVariable(
		psprintf("%s.enable_custom_xlog_rmgr", documentDBRumGucPrefix),
		"Sets whether or not to enable the custom XLOG resource manager",
		NULL,
		&EnableCustomXlogRmgr,
		RUM_DEFAULT_ENABLE_CUSTOM_XLOG_RMRG,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_compare_function_fmgr", documentDBRumGucPrefix),
		"Sets whether or not to enable the use of the compare function in the fmgr",
		NULL,
		&EnableRumCompareFunctionFmgr,
		RUM_DEFAULT_ENABLE_COMPARE_FUNCTION_FMGR,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.fix_incomplete_split", documentDBRumGucPrefix),
		"Sets whether or not to fix incomplete splits",
		NULL,
		&RumFixIncompleteSplit,
		RUM_DEFAULT_FIX_INCOMPLETE_SPLIT,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_ordered_operator_scans", documentDBRumGucPrefix),
		"Sets whether or not to enable ordered operator scans",
		NULL,
		&RumEnableOrderedOperatorScans,
		RUM_DEFAULT_ENABLE_ORDERED_OPERATOR_SCANS,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_page_fill_factor", documentDBRumGucPrefix),
		"Sets whether or not to enable honoring the page fill factor ",
		NULL,
		&RumEnablePageFillFactor,
		RUM_DEFAULT_ENABLE_PAGE_FILL_FACTOR,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_btree_lock_order", documentDBRumGucPrefix),
		"Sets whether or not to enable using the btree lock order in rum index operations",
		NULL,
		&RumEnableBtreeLockOrder,
		RUM_DEFAULT_ENABLE_BTREE_LOCK_ORDER,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomIntVariable(
		psprintf("%s.rum_default_page_fill_factor", documentDBRumGucPrefix),
		"Sets the default page fill factor for RUM indexes",
		NULL,
		&RumDefaultPageFillFactor,
		RUM_DEFAULT_FILL_FACTOR, 10, 100,
		PGC_USERSET, 0,
		NULL, NULL, NULL);

	DefineCustomIntVariable(
		psprintf("%s.dedup_serialize_optimize_threshold_bytes", documentDBRumGucPrefix),
		"Minimum serialized size (in bytes) of the array-dedup bitmap before "
		"run-optimize/shrink-to-fit are applied prior to serialization.",
		"These optimizations cost time proportional to the bitmap cardinality on "
		"every page of an ordered dedup scan, so they are skipped until the "
		"serialized bitmap exceeds this threshold. Set to 0 to always optimize.",
		&RumDedupSerializeOptimizeThresholdBytes,
		RUM_DEFAULT_DEDUP_SERIALIZE_OPTIMIZE_THRESHOLD_BYTES, 0, INT_MAX,
		PGC_USERSET, 0,
		NULL, NULL, NULL);
}
