/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/configs/feature_flag_configs.c
 *
 * Initialization of GUCs that control feature flags that will eventually
 * become defaulted and simply toggle behavior.
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <utils/guc.h>
#include <limits.h>
#include "configs/config_initialization.h"


/*
 * SECTION: Schema validation flags
 */

/* Added in v108, enabled in v114, remove after v116 */
#define DEFAULT_ENABLE_SCHEMA_VALIDATION true
bool EnableSchemaValidation =
	DEFAULT_ENABLE_SCHEMA_VALIDATION;

/* Added in v108, enabled in v114, remove after v116 */
#define DEFAULT_ENABLE_BYPASSDOCUMENTVALIDATION true
bool EnableBypassDocumentValidation =
	DEFAULT_ENABLE_BYPASSDOCUMENTVALIDATION;

/*
 * SECTION: Authentication & Authorization user flags
 */

/* Added in v108, enabled in v108, unknown stabilization time */
#define DEFAULT_ENABLE_USERNAME_PASSWORD_CONSTRAINTS true
bool EnableUsernamePasswordConstraints = DEFAULT_ENABLE_USERNAME_PASSWORD_CONSTRAINTS;

/* Added in v108, enabled in v108, Unknown stabilization time */
#define DEFAULT_ENABLE_USERS_INFO_PRIVILEGES true
bool EnableUsersInfoPrivileges = DEFAULT_ENABLE_USERS_INFO_PRIVILEGES;

/* Added in v108, enabled in v108, Why is this a feature flag */
#define DEFAULT_ENABLE_NATIVE_AUTHENTICATION true
bool IsNativeAuthEnabled = DEFAULT_ENABLE_NATIVE_AUTHENTICATION;

/* Added in v108, Pending stabilization */
#define DEFAULT_ENABLE_ROLE_CRUD false
bool EnableRoleCrud = DEFAULT_ENABLE_ROLE_CRUD;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_USERS_ADMIN_DB_CHECK false
bool EnableUsersAdminDBCheck = DEFAULT_ENABLE_USERS_ADMIN_DB_CHECK;

/* Added in v109, enabled in v109, Unknown stabilization time */
#define DEFAULT_ENABLE_ROLES_ADMIN_DB_CHECK true
bool EnableRolesAdminDBCheck = DEFAULT_ENABLE_ROLES_ADMIN_DB_CHECK;

/*
 * SECTION: Vector Search flags
 */

/* GUC to enable HNSW index type and query for vector search. */
/* Added in v108, enabled in v108, Unknown stabilization time */
#define DEFAULT_ENABLE_VECTOR_HNSW_INDEX true
bool EnableVectorHNSWIndex = DEFAULT_ENABLE_VECTOR_HNSW_INDEX;

/* GUC to enable vector pre-filtering feature for vector search. */
/* Added in v108, enabled in v108, Unknown stabilization time */
#define DEFAULT_ENABLE_VECTOR_PRE_FILTER true
bool EnableVectorPreFilter = DEFAULT_ENABLE_VECTOR_PRE_FILTER;

/* Added in v108, Pending stabilization */
#define DEFAULT_ENABLE_VECTOR_PRE_FILTER_V2 false
bool EnableVectorPreFilterV2 = DEFAULT_ENABLE_VECTOR_PRE_FILTER_V2;

/* Added in v108, Pending stabilization */
#define DEFAULT_ENABLE_VECTOR_FORCE_INDEX_PUSHDOWN false
bool EnableVectorForceIndexPushdown = DEFAULT_ENABLE_VECTOR_FORCE_INDEX_PUSHDOWN;

/* GUC to enable vector compression for vector search. */
/* Added in v108, enabled in v108, Unknown stabilization time */
#define DEFAULT_ENABLE_VECTOR_COMPRESSION_HALF true
bool EnableVectorCompressionHalf = DEFAULT_ENABLE_VECTOR_COMPRESSION_HALF;

/* Added in v108, enabled in v108, Unknown stabilization time */
#define DEFAULT_ENABLE_VECTOR_COMPRESSION_PQ true
bool EnableVectorCompressionPQ = DEFAULT_ENABLE_VECTOR_COMPRESSION_PQ;

/* Added in v108, enabled in v108, Unknown stabilization time */
#define DEFAULT_ENABLE_VECTOR_CALCULATE_DEFAULT_SEARCH_PARAM true
bool EnableVectorCalculateDefaultSearchParameter =
	DEFAULT_ENABLE_VECTOR_CALCULATE_DEFAULT_SEARCH_PARAM;

/*
 * SECTION: Indexing feature flags
 */

/* Long term feature flag - defaulted in 108 - to track older clusters */
/* added in v107, enabled in v108, retire after v999 */
#define DEFAULT_USE_NEW_COMPOSITE_INDEX_OPCLASS true
bool DefaultUseCompositeOpClass = DEFAULT_USE_NEW_COMPOSITE_INDEX_OPCLASS;

/* Added in v109, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_COMPOSITE_INDEX_PLANNER false
bool EnableCompositeIndexPlanner = DEFAULT_ENABLE_COMPOSITE_INDEX_PLANNER;

/* Added in v113, enabled in v113, remove after v115 */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_COVERED_AGGREGATE_TARGETS true
bool EnableIndexOnlyScanForCoveredAggregateTargets =
	DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_COVERED_AGGREGATE_TARGETS;

/* Added in v113, enabled in v113, remove after v115 */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_RANGE_MATCH true
bool EnableIndexOnlyScanForRangeMatch =
	DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_RANGE_MATCH;

/* Added in v109, Pending stabilization, enable in v125 */
#define DEFAULT_ENABLE_ORDER_BY_ID_ON_COST false
bool EnableOrderByIdOnCostFunction = DEFAULT_ENABLE_ORDER_BY_ID_ON_COST;

/* Note: this is a long term feature flag since we need to validate compatiblity
 * in mixed mode for older indexes - once this is
 * enabled by default - please move this to testing_configs.
 * Added in v109, enabled in v109, remove after v999
 */
#define DEFAULT_ENABLE_VALUE_ONLY_INDEX_TERMS true
bool EnableValueOnlyIndexTerms = DEFAULT_ENABLE_VALUE_ONLY_INDEX_TERMS;

/* Added in v109, enabled in v109, remove after v114 */
#define DEFAULT_USE_NEW_UNIQUE_HASH_EQUALITY_FUNCTION true
bool UseNewUniqueHashEqualityFunction = DEFAULT_USE_NEW_UNIQUE_HASH_EQUALITY_FUNCTION;

/* Added in v109, enabled in v109, remove after v114 */
#define DEFAULT_ENABLE_COMPOSITE_UNIQUE_HASH true
bool EnableCompositeUniqueHash = DEFAULT_ENABLE_COMPOSITE_UNIQUE_HASH;

/* Added in v114, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_FAILURE_ON_PARALLEL_INDEX_ARRAYS false
bool EnableFailureOnParallelIndexArrays = DEFAULT_ENABLE_FAILURE_ON_PARALLEL_INDEX_ARRAYS;

/* Added on v116, enabled on v116, remove after v119 */
#define DEFAULT_ENABLE_FAILURE_ON_PARALLEL_INDEX_ARRAYS_FOR_METADATA_TRACKING true
bool EnableFailureOnParallelIndexArraysForMetadataTracking =
	DEFAULT_ENABLE_FAILURE_ON_PARALLEL_INDEX_ARRAYS_FOR_METADATA_TRACKING;

/* Added in v114, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_FIND_PROJECT false
bool EnableIndexOnlyScanForFindProject = DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_FIND_PROJECT;

/* Added in v114, enabled on v113, remove after v116 */
#define DEFAULT_EMIT_ENABLE_ORDERED_INDEX_FALSE_IN_RESPONSE true
bool EmitEnableOrderedIndexFalseInResponse =
	DEFAULT_EMIT_ENABLE_ORDERED_INDEX_FALSE_IN_RESPONSE;

/* Added in v111, enabled in v111, remove after v115 */
#define DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS_ON_COMMON_SUBPATH true
bool EnableCompositeReducedCorrelatedTermsOnCommonSubPath =
	DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS_ON_COMMON_SUBPATH;

/* Added in v113, enabled in v113, remove after v116 */
#define DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_PREFIX_TRIM true
bool EnableCompositeReducedCorrelatedPrefixTrim =
	DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_PREFIX_TRIM;

/* Added in v116, Pending stabilization, enable in v121 */
#define DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_BOUNDS_PLANNING false
bool EnableCompositeReducedCorrelatedBoundsPlanning =
	DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_BOUNDS_PLANNING;

/* Added in v115, Pending stabilization, enable in v121 */
#define DEFAULT_ENABLE_INDEX_METADATA_GLOBAL_TRACKING false
bool EnableIndexMetadataGlobalTracking = DEFAULT_ENABLE_INDEX_METADATA_GLOBAL_TRACKING;

/* Added on v115, enabled on v115, remove after v118 */
#define DEFAULT_ENABLE_PER_PATH_MULTI_KEY_SORT_PUSHDOWN true
bool EnablePerPathMultiKeySortPushdown =
	DEFAULT_ENABLE_PER_PATH_MULTI_KEY_SORT_PUSHDOWN;

/* Added in v115, enabled in v115, remove after v118 */
#define DEFAULT_ENABLE_INDEX_CORRELATION_FROM_STATISTICS true
bool EnableIndexCorrelationFromStatistics =
	DEFAULT_ENABLE_INDEX_CORRELATION_FROM_STATISTICS;

/* Added in v116, Pending stabilization, enable in v122 */
#define DEFAULT_ENABLE_DISTINCT_UNWIND_ROWS_FROM_STATISTICS false
bool EnableDistinctUnwindRowsFromStatistics =
	DEFAULT_ENABLE_DISTINCT_UNWIND_ROWS_FROM_STATISTICS;

/* Longer term feature flag to track older cluster data: Move to testing_configs when convenient */
/* Added in v109, enabled in v109, remove after v999 */
#define DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS true
bool EnableCompositeShardDocumentTerms = DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS;

/* Added in v111, enabled in v115, remove after v118 */
#define DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS true
bool EnablePerCollectionPlannerStatistics =
	DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS;

/* Added in v116, enabled in v116, remove after v119 */
#define DEFAULT_SKIP_LEGACY_ID_INDEX_STATS_CHECK true
bool SkipLegacyIdIndexStatsCheck = DEFAULT_SKIP_LEGACY_ID_INDEX_STATS_CHECK;

/* Added in v113, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_PLANNER_STATISTICS_NEW_COLLECTIONS false
bool EnablePlannerStatisticsNewCollections =
	DEFAULT_ENABLE_PLANNER_STATISTICS_NEW_COLLECTIONS;

/* Added in v111, enabled in v111, remove after v114 */
#define DEFAULT_ENABLE_ORDERED_COMPOSITE_OPERATOR_SCAN true
bool EnableOrderedCompositeOperatorScan = DEFAULT_ENABLE_ORDERED_COMPOSITE_OPERATOR_SCAN;

/* Added in v111, enabled in v111, remove after v114 */
#define DEFAULT_ENABLE_REGEX_PREFIX_INDEX_BOUNDS true
bool EnableRegexPrefixIndexBounds = DEFAULT_ENABLE_REGEX_PREFIX_INDEX_BOUNDS;

/* Added in v111, Pending stabilization */
#define DEFAULT_ENABLE_EXTENDED_INDEXES false
bool EnableExtendedIndexes = DEFAULT_ENABLE_EXTENDED_INDEXES;

/* Added in v111, Pending stabilization, enable in v118 */
#define DEFAULT_ENABLE_COMPARABLE_TERMS false
bool EnableComparableTerms = DEFAULT_ENABLE_COMPARABLE_TERMS;

/* Added in v111, Pending stabilization, enable in v118 */
#define DEFAULT_ENABLE_ORDER_BY_INDEX_TERM false
bool EnableOrderByIndexTerm = DEFAULT_ENABLE_ORDER_BY_INDEX_TERM;

/* Added in v112, Pending stabilization, enable in v116 */
#define DEFAULT_ENABLE_GROUP_BY_COMPOUND_ID_INDEX_PUSHDOWN false
bool EnableGroupByCompoundIdIndexPushdown =
	DEFAULT_ENABLE_GROUP_BY_COMPOUND_ID_INDEX_PUSHDOWN;

/* Added in v112, enabled in v112, remove after v116 */
#define DEFAULT_ENABLE_PARTIAL_MATCH_HAS_RECHECK true
bool EnablePartialMatchHasRecheck = DEFAULT_ENABLE_PARTIAL_MATCH_HAS_RECHECK;

/* Added in v113, enabled in v113, remove after v116 */
#define DEFAULT_ENABLE_SKIP_DOTTED_FIELD_INDEX_TERMS true
bool EnableSkipDottedFieldIndexTerms = DEFAULT_ENABLE_SKIP_DOTTED_FIELD_INDEX_TERMS;

/* Added in v115, enabled in v115, remove after v118 */
#define DEFAULT_ENABLE_PARTIAL_FILTER_EVAL_ON_PLANNER true
bool EnablePartialFilterEvalOnPlanner = DEFAULT_ENABLE_PARTIAL_FILTER_EVAL_ON_PLANNER;

/* Added in v114, enabled in v114, remove after v116 */
#define DEFAULT_ENABLE_DOTTED_VALUE_TEXT_INDEX_TERMS true
bool EnableDottedValueTextIndexTerms = DEFAULT_ENABLE_DOTTED_VALUE_TEXT_INDEX_TERMS;

/* Added in v114, enabled in v114, remove after v118 */
#define DEFAULT_ENABLE_DISTINCT_INDEX_PUSHDOWN true
bool EnableDistinctIndexPushdown = DEFAULT_ENABLE_DISTINCT_INDEX_PUSHDOWN;

/* Added in v116, Pending stabilization, enable in v122 */
#define DEFAULT_ENABLE_DISTINCT_EXISTS_FILTER_PUSHDOWN false
bool EnableDistinctExistsFilterPushdown =
	DEFAULT_ENABLE_DISTINCT_EXISTS_FILTER_PUSHDOWN;

/*
 * SECTION: Planner feature flags
 */

/* Added in v110, enable in v114, remove after v116 */
#define DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS true
bool EnableNewMinMaxAccumulators = DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS;

/* Added in v111, enable in v114, remove after v116 */
#define DEFAULT_ENABLE_NEW_WITH_EXPR_ACCUMULATORS true
bool EnableNewWithExprAccumulators = DEFAULT_ENABLE_NEW_WITH_EXPR_ACCUMULATORS;

/* Added on v115, enabled on v115, remove after v118 */
#define DEFAULT_ENABLE_MIN_MAX_SKIP_NULL_VALUES true
bool EnableMinMaxSkipNullValues = DEFAULT_ENABLE_MIN_MAX_SKIP_NULL_VALUES;

/* Added in v114, enabled on v114, remove after v116 */
#define DEFAULT_ENABLE_DELETE_ONE_PLAN_CACHE_OPTIMIZATION true
bool EnableDeleteOnePlanCacheOptimization =
	DEFAULT_ENABLE_DELETE_ONE_PLAN_CACHE_OPTIMIZATION;

/* Added in v113, pending stabilization, enable in v116 */
#define DEFAULT_ENABLE_DYNAMIC_CURSORS false
bool EnableDynamicCursors = DEFAULT_ENABLE_DYNAMIC_CURSORS;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_DYNAMIC_PERSISTENT_CURSORS_WITH_STATS true
bool EnableDynamicPersistentCursorsWithStats =
	DEFAULT_ENABLE_DYNAMIC_PERSISTENT_CURSORS_WITH_STATS;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_DYNAMIC_CURSOR_FAST_STARTUP_SCAN true
bool EnableDynamicCursorFastStartupScan = DEFAULT_ENABLE_DYNAMIC_CURSOR_FAST_STARTUP_SCAN;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_DYNAMIC_CURSOR_PARALLEL_PLANS true
bool EnableDynamicCursorParallelPlans = DEFAULT_ENABLE_DYNAMIC_CURSOR_PARALLEL_PLANS;

/* Added in v116, enabled in v116, remove after v122 */
#define DEFAULT_ENABLE_DYNAMIC_CURSOR_MULTIKEY_BITMAP true
bool EnableDynamicCursorMultiKeyBitmap = DEFAULT_ENABLE_DYNAMIC_CURSOR_MULTIKEY_BITMAP;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_SINGLE_RESULT_QUERY_PARALLEL_PLANS true
bool EnableSingleResultQueryParallelPlans =
	DEFAULT_ENABLE_SINGLE_RESULT_QUERY_PARALLEL_PLANS;

/* Added in v116, enabled in v116, remove after v118 */
#define DEFAULT_ENABLE_GROUP_BY_DYNAMIC_STREAMING true
bool EnableGroupByDynamicStreaming = DEFAULT_ENABLE_GROUP_BY_DYNAMIC_STREAMING;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_PG_PRNG_CURSOR_ID true
bool EnablePGPrngCursorId = DEFAULT_ENABLE_PG_PRNG_CURSOR_ID;

/* Added in v114, enabled in v114, remove after v120 */
#define DEFAULT_ENABLE_INDEX_PATH_KEY_SUMMARIZATION true
bool EnableIndexPathKeySummarization = DEFAULT_ENABLE_INDEX_PATH_KEY_SUMMARIZATION;

/* Added in v114, pending stabilization, enable in v116 */
#define DEFAULT_ENABLE_DISTINCT_CUSTOM_SCAN false
bool EnableDistinctCustomScan = DEFAULT_ENABLE_DISTINCT_CUSTOM_SCAN;

/* Added in v114, pending stabilization, enable in v116 */
#define DEFAULT_ENABLE_GROUP_BY_DISTINCT_SCAN false
bool EnableGroupByDistinctScan = DEFAULT_ENABLE_GROUP_BY_DISTINCT_SCAN;

/* Added in v114, pending stabilization, enable in v116 */
#define DEFAULT_ENABLE_DISTINCT_SCAN_FOR_GROUP_FIRST false
bool EnableDistinctScanForGroupFirst = DEFAULT_ENABLE_DISTINCT_SCAN_FOR_GROUP_FIRST;

/*
 * SECTION: Aggregation & Query feature flags
 */

/* Added in v109, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_PRIMARY_KEY_CURSOR_SCAN true
bool EnablePrimaryKeyCursorScan = DEFAULT_ENABLE_PRIMARY_KEY_CURSOR_SCAN;

/* Added in v110, Pending stabilization, enable in v117 */
#define DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP false
bool EnableContinuationFastBitmapLookup = DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP;

/* Added in v108, Pending stabilization, enable in v121 */
#define DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS false
bool UseFileBasedPersistedCursors = DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS;

/* Added in v114, Enabled in v114, remove after v117 */
#define DEFAULT_CLEANUP_CURSOR_FILES true
bool CleanupCursorFiles = DEFAULT_CLEANUP_CURSOR_FILES;

/* Added in v111, enabled in v115, remove after v116 */
#define DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE true
bool FailOnGroupIdDuplicate =
	DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE;

/* Added in v114, enabled in v114, remove after v116 */
#define DEFAULT_ENABLE_PULL_NESTED_ARRAY_EQ_FIX true
bool EnablePullNestedArrayEqFix = DEFAULT_ENABLE_PULL_NESTED_ARRAY_EQ_FIX;

/* Added in v108, enabled in v109, remove after v114 */
#define DEFAULT_ENABLE_DELAYED_HOLD_PORTAL true
bool EnableDelayedHoldPortal = DEFAULT_ENABLE_DELAYED_HOLD_PORTAL;

/* Added in v114, enabled in v114, remove after v120 */
#define DEFAULT_ENABLE_RUM_CURSOR_DYNAMIC_INDEX_SCANS true
bool EnableRumCursorDynamicIndexScans = DEFAULT_ENABLE_RUM_CURSOR_DYNAMIC_INDEX_SCANS;

/* Added in v114, enabled in v114, remove after v120 */
#define DEFAULT_ENABLE_RUM_DYNAMIC_INDEX_SCANS_SKIP_TO_TID true
bool EnableRumDynamicIndexScansSkipToTid =
	DEFAULT_ENABLE_RUM_DYNAMIC_INDEX_SCANS_SKIP_TO_TID;

/* Added in v110, enabled in v110, unknown stabilization removal time */
#define DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS true
bool RemoveMatchNamespaceFilters = DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_TAILABLE_CURSOR_MAX_AWAIT_TIME true
bool EnableTailableCursorMaxAwaitTime = DEFAULT_ENABLE_TAILABLE_CURSOR_MAX_AWAIT_TIME;

/* Added in v111, enabled in v115, remove after v117 */
#define DEFAULT_FAIL_ON_NON_EMPTY_GROUP_COUNT_ARG true
bool FailOnNonEmptyGroupCountArg = DEFAULT_FAIL_ON_NON_EMPTY_GROUP_COUNT_ARG;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_SORT_GROUP_STAGE true
bool EnableSortGroupStage = DEFAULT_ENABLE_SORT_GROUP_STAGE;

/* Added in v115, Pending stabilization, enable in v117.*/
#define DEFAULT_ENABLE_PROJECT_PUSHUP_BEFORE_UNWIND_WITH_GROUP false
bool EnableProjectPushUpBeforeUnwindWithGroup =
	DEFAULT_ENABLE_PROJECT_PUSHUP_BEFORE_UNWIND_WITH_GROUP;

/* Added in v113, enabled in v115, remove after v118 */
#define DEFAULT_ENABLE_SORT_PUSH_TO_ACCUMULATOR_WITH_PREFIX true
bool EnableSortPushToAccumulatorWithPrefix =
	DEFAULT_ENABLE_SORT_PUSH_TO_ACCUMULATOR_WITH_PREFIX;

/* Added in v116, Pending stabilization, enable in v121 */
#define DEFAULT_ENABLE_MERGE_SORT_FOR_IN_PREFIX false
bool EnableMergeSortForInPrefix = DEFAULT_ENABLE_MERGE_SORT_FOR_IN_PREFIX;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_DUPLICATE_FIELD_FIX true
bool EnableDuplicateFieldFix = DEFAULT_ENABLE_DUPLICATE_FIELD_FIX;

/* Added in v114, enabled in v114, remove after v117 */
#define DEFAULT_ENABLE_STRICT_ADDTOSET_MODIFIER_VALIDATION true
bool EnableStrictAddToSetModifierValidation =
	DEFAULT_ENABLE_STRICT_ADDTOSET_MODIFIER_VALIDATION;

/* Added in v114, enabled in v114, remove after v117 */
#define DEFAULT_ENABLE_OBJECTID_FUNC_EXPR_CONVERSION true
bool EnableObjectIdFuncExprConversion = DEFAULT_ENABLE_OBJECTID_FUNC_EXPR_CONVERSION;

/* Added in v114, enabled in v114, remove after v117 */
#define DEFAULT_ENABLE_SAMPLE_SCAN_FIX_ON_SHARDED true
bool EnableSampleScanFixOnSharded = DEFAULT_ENABLE_SAMPLE_SCAN_FIX_ON_SHARDED;

/* Added in v115, Pending stabilization, enable in v119 */
#define DEFAULT_ENABLE_ADD_SHARD_KEY_ONLY_ON_PRIMARY_KEY_FILTERS false
bool EnableAddShardKeyOnlyOnPrimaryKeyFilters =
	DEFAULT_ENABLE_ADD_SHARD_KEY_ONLY_ON_PRIMARY_KEY_FILTERS;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_SUBQUERY_PUSHDOWN_FOR_MATCH true
bool EnableSubqueryPushdownForMatch = DEFAULT_ENABLE_SUBQUERY_PUSHDOWN_FOR_MATCH;

/* Added in v114, enabled in v114, remove after v117 */
#define DEFAULT_ENABLE_DOLLAR_SAMPLE_RESERVOIR_SCAN true
bool EnableDollarSampleReservoirScan = DEFAULT_ENABLE_DOLLAR_SAMPLE_RESERVOIR_SCAN;

/* Added in v115, Pending stabilization, enable in v118 */
#define DEFAULT_ENABLE_DOLLAR_SAMPLE_HEAP_SKIP_RESERVOIR_SCAN false
bool EnableDollarSampleHeapSkipReservoirScan =
	DEFAULT_ENABLE_DOLLAR_SAMPLE_HEAP_SKIP_RESERVOIR_SCAN;

/* Added in v114, enabled in v114, remove after v117 */
#define DEFAULT_ENABLE_SKIP_COMMENT_FIELD_ON_UPSERT true
bool EnableSkipCommentFieldOnUpsert = DEFAULT_ENABLE_SKIP_COMMENT_FIELD_ON_UPSERT;

/*
 * SECTION: Let support feature flags
 */

/* Added in v109, enabled in v113, remove after v115 */
#define DEFAULT_ENABLE_OPERATOR_VARIABLES_IN_LOOKUP true
bool EnableOperatorVariablesInLookup =
	DEFAULT_ENABLE_OPERATOR_VARIABLES_IN_LOOKUP;

/*
 * SECTION: Collation feature flags
 */

/* Added in v108, Pending stabilization, enable in v124 */
#define DEFAULT_SKIP_FAIL_ON_COLLATION false
bool SkipFailOnCollation = DEFAULT_SKIP_FAIL_ON_COLLATION;

/* Added in v110, Pending stabilization, enable in v118 */
#define DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES false
bool EnableCollationWithNonUniqueOrderedIndexes =
	DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES;

/* Added in v110, Pending stabilization, enable in v118 */
#define DEFAULT_ENABLE_COLLATION_WITH_NEW_GROUP_ACCUMULATORS false
bool EnableCollationWithNewGroupAccumulators =
	DEFAULT_ENABLE_COLLATION_WITH_NEW_GROUP_ACCUMULATORS;

/*
 * SECTION: Cluster administration & DDL feature flags
 */

/* Added in v113, enabled in v113, remove after v116 */
#define DEFAULT_ENABLE_LOCAL_RETRY_TABLE true
bool EnableLocalRetryTable = DEFAULT_ENABLE_LOCAL_RETRY_TABLE;

/* Added in v108, enabled in v108, unknown retirement schedule */
#define DEFAULT_ENABLE_SCHEMA_ENFORCEMENT_FOR_CSFLE true
bool EnableSchemaEnforcementForCSFLE = DEFAULT_ENABLE_SCHEMA_ENFORCEMENT_FOR_CSFLE;

/* Added in v109, enabled in v114, remove after v118 */
#define DEFAULT_ENABLE_PREPARE_UNIQUE true
bool EnablePrepareUnique = DEFAULT_ENABLE_PREPARE_UNIQUE;

/* Added in v109, enabled in v114, remove after v118 */
#define DEFAULT_ENABLE_COLLMOD_UNIQUE true
bool EnableCollModUnique = DEFAULT_ENABLE_COLLMOD_UNIQUE;

/* Added in v113, enabled in v113, remove after v120 */
#define DEFAULT_ENABLE_UNIQUE_REINDEX true
bool EnableUniqueReindex = DEFAULT_ENABLE_UNIQUE_REINDEX;

/* Added in v114, enabled in v114, remove after v120 */
#define DEFAULT_ENABLE_NON_BLOCKING_UNIQUE_INDEX_BUILD true
bool EnableNonBlockingUniqueIndexBuild =
	DEFAULT_ENABLE_NON_BLOCKING_UNIQUE_INDEX_BUILD;

/* Added in v114, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_COMPACT_VACUUM_FULL false
bool EnableCompactVacuumFull = DEFAULT_ENABLE_COMPACT_VACUUM_FULL;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_ONLY_COLLECTION_CACHE_INVALIDATE_ON_COLLECTION_CHANGES true
bool EnableOnlyCollectionCacheInvalidateOnCollectionChanges =
	DEFAULT_ENABLE_ONLY_COLLECTION_CACHE_INVALIDATE_ON_COLLECTION_CHANGES;

/* Added on v112, enabled on v115, remove after v118 */
#define DEFAULT_ENABLE_NEW_NAMESPACE_VALIDATION true
bool EnableNewNamespaceValidation =
	DEFAULT_ENABLE_NEW_NAMESPACE_VALIDATION;

/* Added in v114, enabled in v114, remove after v116 */
#define DEFAULT_ENABLE_INSERT_DUPLICATE_INLINE_HANDLING true
bool EnableInsertDuplicateInlineHandling =
	DEFAULT_ENABLE_INSERT_DUPLICATE_INLINE_HANDLING;

/* Improves updateMany performance but can lead to deadlocks when concurrent writes update the same document */
/* To enable this default we need to handle deadlock scenarios gracefully */

/* Added in v114, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_COMMUTATIVE_UPDATE_MANY false
bool EnableCommutativeUpdateMany =
	DEFAULT_ENABLE_COMMUTATIVE_UPDATE_MANY;

/* Added in v115, Pending stabilization, enable in v121 */
#define DEFAULT_ENABLE_COMMUTATIVE_DELETE_MANY false
bool EnableCommutativeDeleteMany =
	DEFAULT_ENABLE_COMMUTATIVE_DELETE_MANY;

/* Added in v114, enabled in v114, remove after v116 */
#define DEFAULT_ENABLE_ARRAY_FILTER_LOGICAL_OPERATORS true
bool EnableArrayFilterLogicalOperators =
	DEFAULT_ENABLE_ARRAY_FILTER_LOGICAL_OPERATORS;

/*
 * SECTION: Changestream feature flags
 */

/* Added in v112, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_PREIMAGES false
bool EnablePreImages = DEFAULT_ENABLE_PREIMAGES;

/*
 * SECTION: Schedule jobs via background worker.
 */

/* Added in v109, Pending stabilization, enable in v120 */
#define DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER false
bool IndexBuildsScheduledOnBgWorker = DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER;

/*
 * SECTION: TTL feature flags
 */

/* Added in v110, enabled in v110, remove after v115 */
#define DEFAULT_CREATE_TTL_INDEX_AS_COMPOSITE true
bool CreateTTLIndexAsCompositeByDefault = DEFAULT_CREATE_TTL_INDEX_AS_COMPOSITE;


/* Added in v113, Pending stabilization, enable in v116 */
#define DEFAULT_ENABLE_DEAD_INDEX_ENTRY_MARKING_BY_TTL_TASK false
bool EnableDeadIndexEntryMarkingByTTLTask =
	DEFAULT_ENABLE_DEAD_INDEX_ENTRY_MARKING_BY_TTL_TASK;

/* Added in v111, enabled in v111, remove after v115 */
#define DEFAULT_SKIP_CAUGHT_UP_TTL_INDEXES true
bool TTLSkipCaughtUpIndexes = DEFAULT_SKIP_CAUGHT_UP_TTL_INDEXES;

/* Added in v116, enabled in v116, remove after v119 */
#define DEFAULT_ENABLE_EXISTENTIAL_NULL_ARRAY_MATCH true
bool EnableExistentialNullArrayMatch = DEFAULT_ENABLE_EXISTENTIAL_NULL_ARRAY_MATCH;

/* FEATURE FLAGS END */

void
InitializeFeatureFlagConfigurations(const char *prefix, const char *newGucPrefix)
{
	DefineCustomBoolVariable(
		psprintf("%s.enableVectorHNSWIndex", prefix),
		gettext_noop(
			"Enables support for HNSW index type and query for vector search in bson documents index."),
		NULL, &EnableVectorHNSWIndex, DEFAULT_ENABLE_VECTOR_HNSW_INDEX,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableVectorPreFilter", prefix),
		gettext_noop(
			"Enables support for vector pre-filtering feature for vector search in bson documents index."),
		NULL, &EnableVectorPreFilter, DEFAULT_ENABLE_VECTOR_PRE_FILTER,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableVectorPreFilterV2", prefix),
		gettext_noop(
			"Enables support for vector pre-filtering v2 feature for vector search in bson documents index."),
		NULL, &EnableVectorPreFilterV2, DEFAULT_ENABLE_VECTOR_PRE_FILTER_V2,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_force_push_vector_index", prefix),
		gettext_noop(
			"Enables ensuring that vector index queries are always pushed to the vector index."),
		NULL, &EnableVectorForceIndexPushdown, DEFAULT_ENABLE_VECTOR_FORCE_INDEX_PUSHDOWN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableVectorCompressionHalf", newGucPrefix),
		gettext_noop(
			"Enables support for vector index compression half"),
		NULL, &EnableVectorCompressionHalf, DEFAULT_ENABLE_VECTOR_COMPRESSION_HALF,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableVectorCompressionPQ", newGucPrefix),
		gettext_noop(
			"Enables support for vector index compression product quantization"),
		NULL, &EnableVectorCompressionPQ, DEFAULT_ENABLE_VECTOR_COMPRESSION_PQ,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableVectorCalculateDefaultSearchParam", newGucPrefix),
		gettext_noop(
			"Enables support for vector index default search parameter calculation"),
		NULL, &EnableVectorCalculateDefaultSearchParameter,
		DEFAULT_ENABLE_VECTOR_CALCULATE_DEFAULT_SEARCH_PARAM,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSchemaValidation", prefix),
		gettext_noop(
			"Whether or not to support schema validation."),
		NULL,
		&EnableSchemaValidation,
		DEFAULT_ENABLE_SCHEMA_VALIDATION,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableBypassDocumentValidation", prefix),
		gettext_noop(
			"Whether or not to support 'bypassDocumentValidation'."),
		NULL,
		&EnableBypassDocumentValidation,
		DEFAULT_ENABLE_BYPASSDOCUMENTVALIDATION,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableLocalRetryTable", newGucPrefix),
		gettext_noop(
			"Whether to use a single local retry table instead of per-collection distributed retry tables (After retirement move it to testing configs)"),
		NULL, &EnableLocalRetryTable, DEFAULT_ENABLE_LOCAL_RETRY_TABLE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.skipFailOnCollation", newGucPrefix),
		gettext_noop(
			"Determines whether we can skip failing when collation is specified but collation is not supported"),
		NULL, &SkipFailOnCollation, DEFAULT_SKIP_FAIL_ON_COLLATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCollationWithNonUniqueOrderedIndexes", newGucPrefix),
		gettext_noop(
			"Determines whether collation is supported for non-unique ordered/composite indexes."),
		NULL, &EnableCollationWithNonUniqueOrderedIndexes,
		DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCollationWithNewGroupAccumulators", newGucPrefix),
		gettext_noop(
			"Determines whether collation is enabled with the new group accumulators."),
		NULL, &EnableCollationWithNewGroupAccumulators,
		DEFAULT_ENABLE_COLLATION_WITH_NEW_GROUP_ACCUMULATORS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.EnableOperatorVariablesInLookup", newGucPrefix),
		gettext_noop(
			"Whether or not to enable operator variables($map.as alias) support in let variables spec."),
		NULL, &EnableOperatorVariablesInLookup,
		DEFAULT_ENABLE_OPERATOR_VARIABLES_IN_LOOKUP,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePrimaryKeyCursorScan", newGucPrefix),
		gettext_noop(
			"Whether or not to enable primary key cursor scan for streaming cursors."),
		NULL, &EnablePrimaryKeyCursorScan,
		DEFAULT_ENABLE_PRIMARY_KEY_CURSOR_SCAN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePullNestedArrayEqFix", newGucPrefix),
		gettext_noop(
			"Enables fix for $pull with $eq to correctly remove matching nested array elements."),
		NULL, &EnablePullNestedArrayEqFix,
		DEFAULT_ENABLE_PULL_NESTED_ARRAY_EQ_FIX,
		PGC_USERSET, GUC_NO_SHOW_ALL | GUC_NOT_IN_SAMPLE, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDeleteOnePlanCacheOptimization", newGucPrefix),
		gettext_noop(
			"Whether to enable optimized plan caching for delete-one operations."),
		NULL, &EnableDeleteOnePlanCacheOptimization,
		DEFAULT_ENABLE_DELETE_ONE_PLAN_CACHE_OPTIMIZATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDynamicCursors", newGucPrefix),
		gettext_noop(
			"Whether or not to enable dynamic cursors for aggregation query rewrites."),
		NULL, &EnableDynamicCursors,
		DEFAULT_ENABLE_DYNAMIC_CURSORS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDynamicPersistentCursorsWithStats", newGucPrefix),
		gettext_noop(
			"Whether or not to enable dynamic persistent cursors with statistics."),
		NULL, &EnableDynamicPersistentCursorsWithStats,
		DEFAULT_ENABLE_DYNAMIC_PERSISTENT_CURSORS_WITH_STATS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDynamicCursorFastStartupScan", newGucPrefix),
		gettext_noop(
			"Whether or not to enable fast startup scan for dynamic cursors."),
		NULL, &EnableDynamicCursorFastStartupScan,
		DEFAULT_ENABLE_DYNAMIC_CURSOR_FAST_STARTUP_SCAN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_dynamic_cursor_parallel_plans", newGucPrefix),
		gettext_noop(
			"Whether or not to allow parallel plans for dynamic cursors."),
		NULL, &EnableDynamicCursorParallelPlans,
		DEFAULT_ENABLE_DYNAMIC_CURSOR_PARALLEL_PLANS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_dynamic_cursor_multikey_bitmap", newGucPrefix),
		gettext_noop(
			"Whether or not dynamic cursors force a bitmap scan for multikey "
			"indexes. Ordered index scans on multikey indexes can re-emit a "
			"document across cursor batches, so a bitmap scan is used to "
			"deduplicate by heap tuple."),
		NULL, &EnableDynamicCursorMultiKeyBitmap,
		DEFAULT_ENABLE_DYNAMIC_CURSOR_MULTIKEY_BITMAP,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_single_result_query_parallel_plans", newGucPrefix),
		gettext_noop(
			"Whether or not to allow parallel plans for single-result queries "
			"(e.g. count/distinct)."),
		NULL, &EnableSingleResultQueryParallelPlans,
		DEFAULT_ENABLE_SINGLE_RESULT_QUERY_PARALLEL_PLANS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_group_by_dynamic_streaming", newGucPrefix),
		gettext_noop(
			"Whether or not to allow a fully pushable $group (with or without "
			"accumulators) whose group keys can be provided in order by an index "
			"to use a dynamic streaming cursor instead of a persisted cursor."),
		NULL, &EnableGroupByDynamicStreaming,
		DEFAULT_ENABLE_GROUP_BY_DYNAMIC_STREAMING,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePGPrngCursorId", newGucPrefix),
		gettext_noop(
			"Whether cursor ids use the fast non-cryptographic PRNG (true) or "
			"the strong CSPRNG (false)."),
		NULL, &EnablePGPrngCursorId,
		DEFAULT_ENABLE_PG_PRNG_CURSOR_ID,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableIndexPathKeySummarization", newGucPrefix),
		gettext_noop(
			"Whether or not to enable summarization of index path keys."),
		NULL, &EnableIndexPathKeySummarization,
		DEFAULT_ENABLE_INDEX_PATH_KEY_SUMMARIZATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDistinctCustomScan", newGucPrefix),
		gettext_noop(
			"Whether or not to enable distinct custom scan."),
		NULL, &EnableDistinctCustomScan,
		DEFAULT_ENABLE_DISTINCT_CUSTOM_SCAN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableGroupByDistinctScan", newGucPrefix),
		gettext_noop(
			"Whether or not to enable the distinct custom scan wrapper for "
			"$group pipelines that have no aggregate accumulators."),
		NULL, &EnableGroupByDistinctScan,
		DEFAULT_ENABLE_GROUP_BY_DISTINCT_SCAN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDistinctScanForGroupFirst", newGucPrefix),
		gettext_noop(
			"Whether or not to enable the distinct custom scan wrapper for "
			"$group pipelines whose accumulators are exclusively $first."),
		NULL, &EnableDistinctScanForGroupFirst,
		DEFAULT_ENABLE_DISTINCT_SCAN_FOR_GROUP_FIRST,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableUsernamePasswordConstraints", newGucPrefix),
		gettext_noop(
			"Determines whether username and password constraints are enabled."),
		NULL, &EnableUsernamePasswordConstraints,
		DEFAULT_ENABLE_USERNAME_PASSWORD_CONSTRAINTS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.useFileBasedPersistedCursors", newGucPrefix),
		gettext_noop(
			"Whether or not to use file based persisted cursors."),
		NULL, &UseFileBasedPersistedCursors,
		DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.cleanupCursorFiles", newGucPrefix),
		gettext_noop(
			"Whether or not to clean up cursor files via cleanup worker."),
		NULL, &CleanupCursorFiles,
		DEFAULT_CLEANUP_CURSOR_FILES,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableUsersInfoPrivileges", newGucPrefix),
		gettext_noop(
			"Determines whether the usersInfo command returns privileges."),
		NULL, &EnableUsersInfoPrivileges,
		DEFAULT_ENABLE_USERS_INFO_PRIVILEGES,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.isNativeAuthEnabled", newGucPrefix),
		gettext_noop(
			"Determines whether native authentication is enabled."),
		NULL, &IsNativeAuthEnabled,
		DEFAULT_ENABLE_NATIVE_AUTHENTICATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.defaultUseCompositeOpClass", newGucPrefix),
		gettext_noop(
			"Whether to enable the new ordered index opclass for default index creates"),
		NULL, &DefaultUseCompositeOpClass, DEFAULT_USE_NEW_COMPOSITE_INDEX_OPCLASS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeIndexPlanner", newGucPrefix),
		gettext_noop(
			"Whether to enable the new ordered index opclass planner improvements"),
		NULL, &EnableCompositeIndexPlanner, DEFAULT_ENABLE_COMPOSITE_INDEX_PLANNER,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableRoleCrud", newGucPrefix),
		gettext_noop(
			"Enables role crud through the data plane."),
		NULL, &EnableRoleCrud, DEFAULT_ENABLE_ROLE_CRUD,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSchemaEnforcementForCSFLE", newGucPrefix),
		gettext_noop(
			"Whether or not to enable schema enforcement for CSFLE."),
		NULL, &EnableSchemaEnforcementForCSFLE,
		DEFAULT_ENABLE_SCHEMA_ENFORCEMENT_FOR_CSFLE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableIndexOnlyScanForCoveredAggregateTargets",
				 newGucPrefix),
		gettext_noop(
			"Whether to enable index only scan for aggregate target-list"
			" expressions that reference covered document paths."),
		NULL, &EnableIndexOnlyScanForCoveredAggregateTargets,
		DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_COVERED_AGGREGATE_TARGETS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableIndexOnlyScanForRangeMatch", newGucPrefix),
		gettext_noop(
			"Whether to enable index only scan for range-match qualifiers on"
			" covered index paths."),
		NULL, &EnableIndexOnlyScanForRangeMatch,
		DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_RANGE_MATCH,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePartialMatchHasRecheck", newGucPrefix),
		gettext_noop(
			"Whether to enable partial match has recheck for queries that have partial index matches."),
		NULL, &EnablePartialMatchHasRecheck, DEFAULT_ENABLE_PARTIAL_MATCH_HAS_RECHECK,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSkipDottedFieldIndexTerms", newGucPrefix),
		gettext_noop(
			"Whether to skip generating index terms for fields with dotted names (e.g. literal \"a.b\" field)."),
		NULL, &EnableSkipDottedFieldIndexTerms,
		DEFAULT_ENABLE_SKIP_DOTTED_FIELD_INDEX_TERMS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	/* Added in v115, enabled in v115, remove after v118 */
	DefineCustomBoolVariable(
		psprintf("%s.enable_partial_filter_eval_on_planner", newGucPrefix),
		gettext_noop(
			"Whether to enable partial filter evaluation on the planner."),
		NULL, &EnablePartialFilterEvalOnPlanner,
		DEFAULT_ENABLE_PARTIAL_FILTER_EVAL_ON_PLANNER,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDottedValueTextIndexTerms", newGucPrefix),
		gettext_noop(
			"Whether to enable generating index terms for dotted values (e.g. \"foo.bar\")."),
		NULL, &EnableDottedValueTextIndexTerms,
		DEFAULT_ENABLE_DOTTED_VALUE_TEXT_INDEX_TERMS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDistinctIndexPushdown", newGucPrefix),
		gettext_noop(
			"Whether to enable pushing down distinct operations to the index."),
		NULL, &EnableDistinctIndexPushdown,
		DEFAULT_ENABLE_DISTINCT_INDEX_PUSHDOWN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_distinct_exists_filter_pushdown", newGucPrefix),
		gettext_noop(
			"Whether to append a distinct-exists filter during distinct planning "
			"that converts to a path >= MinKey index condition on ordered indexes."),
		NULL, &EnableDistinctExistsFilterPushdown,
		DEFAULT_ENABLE_DISTINCT_EXISTS_FILTER_PUSHDOWN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDelayedHoldPortal", newGucPrefix),
		gettext_noop(
			"Whether to delay holding the portal until we know there is more data to be fetched."),
		NULL, &EnableDelayedHoldPortal, DEFAULT_ENABLE_DELAYED_HOLD_PORTAL,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableUsersAdminDBCheck", newGucPrefix),
		gettext_noop(
			"Enables db admin requirement for user CRUD APIs through the data plane."),
		NULL, &EnableUsersAdminDBCheck, DEFAULT_ENABLE_USERS_ADMIN_DB_CHECK,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableRolesAdminDBCheck", newGucPrefix),
		gettext_noop(
			"Enables db admin requirement for role CRUD APIs through the data plane."),
		NULL, &EnableRolesAdminDBCheck, DEFAULT_ENABLE_ROLES_ADMIN_DB_CHECK,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableOrderByIdOnCostFunction", newGucPrefix),
		gettext_noop(
			"Whether to enable index terms that are value only."),
		NULL, &EnableOrderByIdOnCostFunction, DEFAULT_ENABLE_ORDER_BY_ID_ON_COST,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableValueOnlyIndexTerms", newGucPrefix),
		gettext_noop(
			"Whether to enable index terms that are value only."),
		NULL, &EnableValueOnlyIndexTerms, DEFAULT_ENABLE_VALUE_ONLY_INDEX_TERMS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePrepareUnique", newGucPrefix),
		gettext_noop(
			"Whether to enable prepareUnique for coll mod."),
		NULL, &EnablePrepareUnique, DEFAULT_ENABLE_PREPARE_UNIQUE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCollModUnique", newGucPrefix),
		gettext_noop(
			"Whether to enable unique for coll mod."),
		NULL, &EnableCollModUnique, DEFAULT_ENABLE_COLLMOD_UNIQUE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableUniqueReindex", newGucPrefix),
		gettext_noop(
			"Whether to enable unique reindex."),
		NULL, &EnableUniqueReindex, DEFAULT_ENABLE_UNIQUE_REINDEX,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableNonBlockingUniqueIndexBuild", newGucPrefix),
		gettext_noop(
			"Whether to enable non-blocking background builds of unique indexes."),
		NULL, &EnableNonBlockingUniqueIndexBuild,
		DEFAULT_ENABLE_NON_BLOCKING_UNIQUE_INDEX_BUILD,
		PGC_USERSET, 0, NULL, NULL, NULL);


	DefineCustomBoolVariable(
		psprintf("%s.failOnNonEmptyGroupCountArg", newGucPrefix),
		gettext_noop(
			"Whether to fail when $count accumulator in $group has non-empty arguments."),
		NULL, &FailOnNonEmptyGroupCountArg,
		DEFAULT_FAIL_ON_NON_EMPTY_GROUP_COUNT_ARG,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSortGroupStage", newGucPrefix),
		gettext_noop(
			"Whether to enable the $sortGroup stage."),
		NULL, &EnableSortGroupStage, DEFAULT_ENABLE_SORT_GROUP_STAGE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableProjectPushUpBeforeUnwindWithGroup", newGucPrefix),
		gettext_noop(
			"Whether to inject a synthetic $project before $unwind when the "
			"pipeline ends with a $group, keeping only the top-level fields "
			"that are referenced downstream so the unwound rows are smaller."),
		NULL, &EnableProjectPushUpBeforeUnwindWithGroup,
		DEFAULT_ENABLE_PROJECT_PUSHUP_BEFORE_UNWIND_WITH_GROUP,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSortPushToAccumulatorWithPrefix", newGucPrefix),
		gettext_noop(
			"Whether to push suffix sort keys into accumulator when group keys are a prefix of sort keys in $sortGroup."),
		NULL, &EnableSortPushToAccumulatorWithPrefix,
		DEFAULT_ENABLE_SORT_PUSH_TO_ACCUMULATOR_WITH_PREFIX,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_merge_sort_for_in_prefix", newGucPrefix),
		gettext_noop(
			"Whether to push a composite index sort to a merge of per-value ordered index scans when an $in filter is an equality prefix of the sort key."),
		NULL, &EnableMergeSortForInPrefix,
		DEFAULT_ENABLE_MERGE_SORT_FOR_IN_PREFIX,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.failOnGroupIdDuplicate", newGucPrefix),
		gettext_noop(
			"Whether to fail when $group stage has duplicate _id."),
		NULL, &FailOnGroupIdDuplicate,
		DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.useNewUniqueHashEqualityFunction", newGucPrefix),
		gettext_noop(
			"Whether to enable new unique hash equality implementation."),
		NULL, &UseNewUniqueHashEqualityFunction,
		DEFAULT_USE_NEW_UNIQUE_HASH_EQUALITY_FUNCTION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeUniqueHash", newGucPrefix),
		gettext_noop(
			"Whether to enable new unique hash equality implementation."),
		NULL, &EnableCompositeUniqueHash,
		DEFAULT_ENABLE_COMPOSITE_UNIQUE_HASH,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableFailureOnParallelIndexArrays", newGucPrefix),
		gettext_noop(
			"Whether to fail when parallel arrays are indexed in composite indexes."),
		NULL, &EnableFailureOnParallelIndexArrays,
		DEFAULT_ENABLE_FAILURE_ON_PARALLEL_INDEX_ARRAYS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf(
			"%s.enable_failure_on_parallel_index_arrays_for_metadata_tracking",
			newGucPrefix),
		gettext_noop(
			"Whether metadata-backed composite indexes reject parallel arrays."),
		NULL, &EnableFailureOnParallelIndexArraysForMetadataTracking,
		DEFAULT_ENABLE_FAILURE_ON_PARALLEL_INDEX_ARRAYS_FOR_METADATA_TRACKING,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableIndexOnlyScanForFindProject", newGucPrefix),
		gettext_noop(
			"Whether or not to enable index only scan for find with project operations."),
		NULL, &EnableIndexOnlyScanForFindProject,
		DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_FIND_PROJECT,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeReducedCorrelatedTermsOnCommonSubPath", newGucPrefix),
		gettext_noop(
			"Whether to enable reduced term generation for correlated composite paths on common sub-paths."),
		NULL, &EnableCompositeReducedCorrelatedTermsOnCommonSubPath,
		DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS_ON_COMMON_SUBPATH,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeReducedCorrelatedPrefixTrim", newGucPrefix),
		gettext_noop(
			"Whether to enable prefix-group-aware trimming of secondary variable bounds for reduced correlated composite indexes."),
		NULL, &EnableCompositeReducedCorrelatedPrefixTrim,
		DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_PREFIX_TRIM,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_composite_reduced_correlated_bounds_planning", newGucPrefix),
		gettext_noop(
			"Whether to prune reduced-correlated composite index quals during planning when per-path multi-key metadata is available."),
		NULL, &EnableCompositeReducedCorrelatedBoundsPlanning,
		DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_BOUNDS_PLANNING,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableIndexMetadataGlobalTracking", newGucPrefix),
		gettext_noop(
			"Whether to enable tracking of index metadata in the index global metadata."),
		NULL, &EnableIndexMetadataGlobalTracking,
		DEFAULT_ENABLE_INDEX_METADATA_GLOBAL_TRACKING,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePerPathMultiKeySortPushdown", newGucPrefix),
		gettext_noop(
			"Whether to respect the per-path multi-key bitmask when deciding order-by pushdown for composite ordered indexes. When off, a multi-key index blocks order-by pushdown on any filtered sort column regardless of that column's per-path multi-key state."),
		NULL, &EnablePerPathMultiKeySortPushdown,
		DEFAULT_ENABLE_PER_PATH_MULTI_KEY_SORT_PUSHDOWN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_index_correlation_from_statistics", newGucPrefix),
		gettext_noop(
			"Whether to source the physical-order correlation of a composite index's leading path from extended statistics during cost estimation. When off, the correlation defaults to the base access method estimate."),
		NULL, &EnableIndexCorrelationFromStatistics,
		DEFAULT_ENABLE_INDEX_CORRELATION_FROM_STATISTICS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_distinct_unwind_rows_from_statistics", newGucPrefix),
		gettext_noop(
			"Whether the distinct-unwind planner support function should derive its returned row estimate from column statistics of the unwound path. When off, the estimate defaults to the function's declared prorows."),
		NULL, &EnableDistinctUnwindRowsFromStatistics,
		DEFAULT_ENABLE_DISTINCT_UNWIND_ROWS_FROM_STATISTICS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeShardDocumentTerms", newGucPrefix),
		gettext_noop(
			"Whether to enable shard hash term generation for composite indexes (specially for null handling)."),
		NULL, &EnableCompositeShardDocumentTerms,
		DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS,
		PGC_USERSET, 0, NULL, NULL, NULL);


	DefineCustomBoolVariable(
		psprintf("%s.enableOrderedCompositeOperatorScan", newGucPrefix),
		gettext_noop(
			"Whether to enable using the single ordered scalar array operator scan for ordered indexes"
			" which has skip-scan support enabled inherently."),
		NULL, &EnableOrderedCompositeOperatorScan,
		DEFAULT_ENABLE_ORDERED_COMPOSITE_OPERATOR_SCAN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableRegexPrefixIndexBounds", newGucPrefix),
		gettext_noop(
			"Whether to enable the optimized regex prefix index bounds."),
		NULL, &EnableRegexPrefixIndexBounds,
		DEFAULT_ENABLE_REGEX_PREFIX_INDEX_BOUNDS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableExtendedIndexes", newGucPrefix),
		gettext_noop(
			"Whether to enable extended indexes feature."),
		NULL, &EnableExtendedIndexes,
		DEFAULT_ENABLE_EXTENDED_INDEXES,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableComparableTerms", newGucPrefix),
		gettext_noop(
			"Whether to enable comparable terms feature."),
		NULL, &EnableComparableTerms,
		DEFAULT_ENABLE_COMPARABLE_TERMS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableOrderByIndexTerm", newGucPrefix),
		gettext_noop(
			"Whether to enable order by index term feature."),
		NULL, &EnableOrderByIndexTerm,
		DEFAULT_ENABLE_ORDER_BY_INDEX_TERM,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableGroupByCompoundIdIndexPushdown", newGucPrefix),
		gettext_noop(
			"Whether to enable compound document _id group-by decomposition for index pushdown."),
		NULL, &EnableGroupByCompoundIdIndexPushdown,
		DEFAULT_ENABLE_GROUP_BY_COMPOUND_ID_INDEX_PUSHDOWN,
		PGC_USERSET, 0, NULL, NULL, NULL);


	DefineCustomBoolVariable(
		psprintf("%s.indexBuildsScheduledOnBgWorker", newGucPrefix),
		gettext_noop(
			"Whether to schedule index builds via background worker jobs."),
		NULL, &IndexBuildsScheduledOnBgWorker,
		DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableTailableCursorMaxAwaitTime", newGucPrefix),
		gettext_noop(
			"Kill switch for tailable cursor maxAwaitTimeMS support. When off, the backend ignores the maxAwaitTimeMS getMore field, treats maxTimeMS as a statement timeout for all cursor kinds, and never returns a polling hint to the gateway."),
		NULL, &EnableTailableCursorMaxAwaitTime,
		DEFAULT_ENABLE_TAILABLE_CURSOR_MAX_AWAIT_TIME,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.removeMatchNamespaceFilters", newGucPrefix),
		gettext_noop(
			"Determines whether to remove $match aggregation stage filters on namespace when inlined with $changestreams"),
		NULL, &RemoveMatchNamespaceFilters,
		DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableContinuationFastBitmapLookup", newGucPrefix),
		gettext_noop(
			"Whether to enable skipping bitmap records by tid without loading the heap to find the continuation point."),
		NULL, &EnableContinuationFastBitmapLookup,
		DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.createTTLIndexAsCompositeByDefault", newGucPrefix),
		gettext_noop(
			"Whether to always create TTL indexes as composite indexes by default."),
		NULL, &CreateTTLIndexAsCompositeByDefault,
		DEFAULT_CREATE_TTL_INDEX_AS_COMPOSITE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.emitEnableOrderedIndexFalseInResponse", newGucPrefix),
		gettext_noop(
			"When enabled, list index responses include \"enableOrderedIndex\": false "
			"for indexes whose enableCompositeTerm was explicitly set to false (-1). "
			"When disabled, the field is omitted for those indexes."),
		NULL, &EmitEnableOrderedIndexFalseInResponse,
		DEFAULT_EMIT_ENABLE_ORDERED_INDEX_FALSE_IN_RESPONSE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableNewMinMaxAccumulators", newGucPrefix),
		gettext_noop(
			"Whether to enable new min and max aggregate optimizations."),
		NULL, &EnableNewMinMaxAccumulators,
		DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_min_max_skip_null_values", newGucPrefix),
		gettext_noop(
			"Whether $min and $max accumulators skip null values, matching the documented wire-protocol semantics of only considering non-null, non-missing values."),
		NULL, &EnableMinMaxSkipNullValues,
		DEFAULT_ENABLE_MIN_MAX_SKIP_NULL_VALUES,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePreImages", newGucPrefix),
		gettext_noop(
			"Whether to enable changestream preimages with the entire row logged in the WAL messages."),
		NULL, &EnablePreImages,
		DEFAULT_ENABLE_PREIMAGES,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePerCollectionPlannerStatistics", newGucPrefix),
		gettext_noop(
			"Whether to enable per-collection planner statistics."),
		NULL, &EnablePerCollectionPlannerStatistics,
		DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.skip_legacy_id_index_stats_check", newGucPrefix),
		gettext_noop(
			"Whether to skip the legacy _id_ index-options fallback when "
			"checking if a collection has planner statistics enabled. Skipped "
			"by default; retained for backward compatibility and will be retired."),
		NULL, &SkipLegacyIdIndexStatsCheck,
		DEFAULT_SKIP_LEGACY_ID_INDEX_STATS_CHECK,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePlannerStatisticsNewCollections", newGucPrefix),
		gettext_noop(
			"Whether to enable custom planner statistics for any new collections."),
		NULL, &EnablePlannerStatisticsNewCollections,
		DEFAULT_ENABLE_PLANNER_STATISTICS_NEW_COLLECTIONS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableNewWithExprAccumulators", newGucPrefix),
		gettext_noop(
			"Whether to enable new WithExpr aggregate optimizations for min, max, sum, avg, first, and last accumulators."),
		NULL, &EnableNewWithExprAccumulators,
		DEFAULT_ENABLE_NEW_WITH_EXPR_ACCUMULATORS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableOnlyCollectionCacheInvalidateOnCollectionChanges",
				 newGucPrefix),
		gettext_noop(
			"Whether to only invalidate collection cache on collection changes instead of invalidating entire database cache."),
		NULL, &EnableOnlyCollectionCacheInvalidateOnCollectionChanges,
		DEFAULT_ENABLE_ONLY_COLLECTION_CACHE_INVALIDATE_ON_COLLECTION_CHANGES,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableRumCursorDynamicIndexScans", newGucPrefix),
		gettext_noop(
			"Whether to enable dynamic index scans for RUM cursors."),
		NULL, &EnableRumCursorDynamicIndexScans,
		DEFAULT_ENABLE_RUM_CURSOR_DYNAMIC_INDEX_SCANS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableRumDynamicIndexScansSkipToTid", newGucPrefix),
		gettext_noop(
			"Whether to enable skipping to TID for dynamic index scans for RUM cursors."),
		NULL, &EnableRumDynamicIndexScansSkipToTid,
		DEFAULT_ENABLE_RUM_DYNAMIC_INDEX_SCANS_SKIP_TO_TID,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDuplicateFieldFix", newGucPrefix),
		gettext_noop(
			"Whether to enable fix for duplicate fields in addToSet."),
		NULL, &EnableDuplicateFieldFix,
		DEFAULT_ENABLE_DUPLICATE_FIELD_FIX,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableStrictAddToSetModifierValidation", newGucPrefix),
		gettext_noop(
			"Reject $position/$slice/$sort (or any non-$each sibling) inside $addToSet, matching MongoDB behavior."),
		NULL, &EnableStrictAddToSetModifierValidation,
		DEFAULT_ENABLE_STRICT_ADDTOSET_MODIFIER_VALIDATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableNewNamespaceValidation", newGucPrefix),
		gettext_noop(
			"Whether to enable new namespace validation."),
		NULL, &EnableNewNamespaceValidation,
		DEFAULT_ENABLE_NEW_NAMESPACE_VALIDATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableInsertDuplicateInlineHandling", newGucPrefix),
		gettext_noop(
			"Whether to enable inline handling of duplicate inserts."),
		NULL, &EnableInsertDuplicateInlineHandling,
		DEFAULT_ENABLE_INSERT_DUPLICATE_INLINE_HANDLING,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableObjectIdFuncExprConversion", newGucPrefix),
		gettext_noop(
			"Whether to enable conversion of ObjectId function expressions."),
		NULL, &EnableObjectIdFuncExprConversion,
		DEFAULT_ENABLE_OBJECTID_FUNC_EXPR_CONVERSION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSampleScanFixOnSharded", newGucPrefix),
		gettext_noop(
			"Enables fix for $sample TABLESAMPLE on sharded collections."),
		NULL,
		&EnableSampleScanFixOnSharded,
		DEFAULT_ENABLE_SAMPLE_SCAN_FIX_ON_SHARDED,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableAddShardKeyOnlyOnPrimaryKeyFilters", newGucPrefix),
		gettext_noop(
			"Whether to enable adding shard key only on primary key filters."),
		NULL,
		&EnableAddShardKeyOnlyOnPrimaryKeyFilters,
		DEFAULT_ENABLE_ADD_SHARD_KEY_ONLY_ON_PRIMARY_KEY_FILTERS,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);


	DefineCustomBoolVariable(
		psprintf("%s.enableSubqueryPushdownForMatch", newGucPrefix),
		gettext_noop(
			"Whether to enable pushdown of subqueries for match operations."),
		NULL,
		&EnableSubqueryPushdownForMatch,
		DEFAULT_ENABLE_SUBQUERY_PUSHDOWN_FOR_MATCH,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableSkipCommentFieldOnUpsert", newGucPrefix),
		gettext_noop(
			"Whether to skip persisting the $comment query metadata field onto the document generated during an upsert."),
		NULL,
		&EnableSkipCommentFieldOnUpsert,
		DEFAULT_ENABLE_SKIP_COMMENT_FIELD_ON_UPSERT,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDeadIndexEntryMarkingByTTLTask", newGucPrefix),
		gettext_noop(
			"Whether to enable marking dead index entries during TTL task scans to avoid redundant heap fetches."),
		NULL,
		&EnableDeadIndexEntryMarkingByTTLTask,
		DEFAULT_ENABLE_DEAD_INDEX_ENTRY_MARKING_BY_TTL_TASK,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.TTLSkipCaughtUpIndexes", newGucPrefix),
		gettext_noop(
			"Whether to skip checking a TTL index further, once they are caught up during a TTL task invocation cycle."),
		NULL,
		&TTLSkipCaughtUpIndexes,
		DEFAULT_SKIP_CAUGHT_UP_TTL_INDEXES,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompactVacuumFull", newGucPrefix),
		gettext_noop(
			"Whether to enable VACUUM FULL execution during compact command. When off, compact is a no-op."),
		NULL,
		&EnableCompactVacuumFull,
		DEFAULT_ENABLE_COMPACT_VACUUM_FULL,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCommutativeUpdateMany", newGucPrefix),
		gettext_noop(
			"Whether to enable commutative writes for updateMany to improve performance. Can lead to deadlocks when concurrent writes update the same document."),
		NULL,
		&EnableCommutativeUpdateMany,
		DEFAULT_ENABLE_COMMUTATIVE_UPDATE_MANY,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCommutativeDeleteMany", newGucPrefix),
		gettext_noop(
			"Whether to enable commutative writes for deleteMany to improve performance. Can lead to deadlocks when concurrent writes update the same document."),
		NULL,
		&EnableCommutativeDeleteMany,
		DEFAULT_ENABLE_COMMUTATIVE_DELETE_MANY,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableArrayFilterLogicalOperators", newGucPrefix),
		gettext_noop(
			"Whether to enable $or/$and/$nor logical operators at the top level of arrayFilter elements."),
		NULL,
		&EnableArrayFilterLogicalOperators,
		DEFAULT_ENABLE_ARRAY_FILTER_LOGICAL_OPERATORS,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDollarSampleReservoirScan", newGucPrefix),
		gettext_noop(
			"Whether to use reservoir sampling for $sample instead of ORDER BY random()."),
		NULL,
		&EnableDollarSampleReservoirScan,
		DEFAULT_ENABLE_DOLLAR_SAMPLE_RESERVOIR_SCAN,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDollarSampleHeapSkipReservoirScan", newGucPrefix),
		gettext_noop(
			"Whether the DocumentDBApiReservoirSample custom scan over an Index "
			"Scan may read the heap only for sampled rows, skipping unsampled "
			"rows via the index."),
		NULL,
		&EnableDollarSampleHeapSkipReservoirScan,
		DEFAULT_ENABLE_DOLLAR_SAMPLE_HEAP_SKIP_RESERVOIR_SCAN,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_existential_null_array_match", newGucPrefix),
		gettext_noop(
			"Whether equality-to-null on a dotted path uses existential semantics "
			"across an implicitly traversed array."),
		NULL,
		&EnableExistentialNullArrayMatch,
		DEFAULT_ENABLE_EXISTENTIAL_NULL_ARRAY_MATCH,
		PGC_USERSET,
		0,
		NULL, NULL, NULL);
}
