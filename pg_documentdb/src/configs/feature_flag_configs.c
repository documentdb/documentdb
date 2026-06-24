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

/* We can enable by default once we stabilize by moving it's creation to the cost estimate. */
/* Added in v107, enabled in v111, remove after v113. */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN true
bool EnableIndexOnlyScan = DEFAULT_ENABLE_INDEX_ONLY_SCAN;

/* Added in v111, enabled in v111, remove after v113 */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN_ON_COST true
bool EnableIndexOnlyScanOnCostFunction = DEFAULT_ENABLE_INDEX_ONLY_SCAN_ON_COST;

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

/* Added in v114, Pending stabilization, enable in v120 */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_FIND_PROJECT false
bool EnableIndexOnlyScanForFindProject = DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_FIND_PROJECT;

/* Added in v114, enabled on v113, remove after v116 */
#define DEFAULT_EMIT_ENABLE_ORDERED_INDEX_FALSE_IN_RESPONSE true
bool EmitEnableOrderedIndexFalseInResponse =
	DEFAULT_EMIT_ENABLE_ORDERED_INDEX_FALSE_IN_RESPONSE;

/* Added in v109, Pending stabilization, enable in v120 */
/* Remove if EnableCompositeReducedCorrelatedTermsOnCommonSubPath becomes stabilized */
#define DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS false
bool EnableCompositeReducedCorrelatedTerms = DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS;

/* Added in v109, Pending stabilization, enable in v120 */
/* Remove if EnableCompositeReducedCorrelatedTermsOnCommonSubPath becomes stabilized */
#define DEFAULT_ENABLE_UNIQUE_REDUCED_CORRELATED_TERMS false
bool EnableUniqueCompositeReducedCorrelatedTerms =
	DEFAULT_ENABLE_UNIQUE_REDUCED_CORRELATED_TERMS;

/* Added in v111, enabled in v111, remove after v115 */
#define DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS_ON_COMMON_SUBPATH true
bool EnableCompositeReducedCorrelatedTermsOnCommonSubPath =
	DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS_ON_COMMON_SUBPATH;

/* Added in v113, enabled in v113, remove after v116 */
#define DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_PREFIX_TRIM true
bool EnableCompositeReducedCorrelatedPrefixTrim =
	DEFAULT_ENABLE_COMPOSITE_REDUCED_CORRELATED_PREFIX_TRIM;

/* Longer term feature flag to track older cluster data: Move to testing_configs when convenient */
/* Added in v109, enabled in v109, remove after v999 */
#define DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS true
bool EnableCompositeShardDocumentTerms = DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS;

/* Added in v111, Pending stabilization, enable in v115 */
#define DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS false
bool EnablePerCollectionPlannerStatistics =
	DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS;

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

/* Added in v111, Pending stabilization, enable in v116 */
#define DEFAULT_ENABLE_COMPARABLE_TERMS false
bool EnableComparableTerms = DEFAULT_ENABLE_COMPARABLE_TERMS;

/* Added in v111, Pending stabilization, enable in v115 */
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

/* Added in v114, enabled in v114, remove after v116 */
#define DEFAULT_ENABLE_DOTTED_VALUE_TEXT_INDEX_TERMS true
bool EnableDottedValueTextIndexTerms = DEFAULT_ENABLE_DOTTED_VALUE_TEXT_INDEX_TERMS;

/* Added in v114, enabled in v114, remove after v118 */
#define DEFAULT_ENABLE_DISTINCT_INDEX_PUSHDOWN true
bool EnableDistinctIndexPushdown = DEFAULT_ENABLE_DISTINCT_INDEX_PUSHDOWN;

/*
 * SECTION: Planner feature flags
 */

/* Added in v110, Pending stabilization. Superseded by EnableNewWithExprAccumulators in v111, enable in v114 */
#define DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS false
bool EnableNewMinMaxAccumulators = DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS;

/* Added in v111, Pending stabilization, enable in v114 */
#define DEFAULT_ENABLE_NEW_WITH_EXPR_ACCUMULATORS false
bool EnableNewWithExprAccumulators = DEFAULT_ENABLE_NEW_WITH_EXPR_ACCUMULATORS;

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

/* Added in v110, Pending stabilization, enable in v114 */
#define DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP false
bool EnableContinuationFastBitmapLookup = DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP;

/* Added in v108, Pending stabilization, enable in v121 */
#define DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS false
bool UseFileBasedPersistedCursors = DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS;

/* Added in v114, Enabled in v114, remove after v117 */
#define DEFAULT_CLEANUP_CURSOR_FILES true
bool CleanupCursorFiles = DEFAULT_CLEANUP_CURSOR_FILES;

/* Added in v111, Pending stabilization, enable in v115 */
#define DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE false
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

/* Added in v110, enabled in v110, remove after v113 */
#define DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION true
bool EnableDollarInToScalarArrayOpExprConversion =
	DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION;

/* Added in v111, enabled in v111, remove after v114 */
#define DEFAULT_USE_FOREIGN_KEY_LOOKUP_INLINE true
bool EnableUseForeignKeyLookupInline = DEFAULT_USE_FOREIGN_KEY_LOOKUP_INLINE;

/* Added in v110, enabled in v110, remove after v113 */
#define DEFAULT_ENABLE_ADD_TO_SET_AGGREGATION_REWRITE true
bool EnableAddToSetAggregationRewrite = DEFAULT_ENABLE_ADD_TO_SET_AGGREGATION_REWRITE;

/* Added in v110, enabled in v110, unknown stabilization removal time */
#define DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS true
bool RemoveMatchNamespaceFilters = DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS;

/* Added in v111, enabled in v111, Remove after v113 */
#define DEFAULT_MULTIPLE_POSITIONAL_OPERATORS_NOT_ALLOWED true
bool MultiplePositionalNotAllowed = DEFAULT_MULTIPLE_POSITIONAL_OPERATORS_NOT_ALLOWED;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_GROUP_SUBQUERY_ELIMINATION true
bool EnableGroupSubqueryElimination = DEFAULT_ENABLE_GROUP_SUBQUERY_ELIMINATION;

/* Added in v111, Pending stabilization, enable in v114 */
#define DEFAULT_FAIL_ON_NON_EMPTY_GROUP_COUNT_ARG false
bool FailOnNonEmptyGroupCountArg = DEFAULT_FAIL_ON_NON_EMPTY_GROUP_COUNT_ARG;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_SORT_GROUP_STAGE true
bool EnableSortGroupStage = DEFAULT_ENABLE_SORT_GROUP_STAGE;

/* Added in v113, Pending stabilization, enable in v115 */
#define DEFAULT_ENABLE_SORT_PUSH_TO_ACCUMULATOR_WITH_PREFIX false
bool EnableSortPushToAccumulatorWithPrefix =
	DEFAULT_ENABLE_SORT_PUSH_TO_ACCUMULATOR_WITH_PREFIX;

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

/* Added in v115, Pending stabilization, enable in v118 */
#define DEFAULT_ENABLE_ADD_SHARD_KEY_ONLY_ON_PRIMARY_KEY_FILTERS false
bool EnableAddShardKeyOnlyOnPrimaryKeyFilters =
	DEFAULT_ENABLE_ADD_SHARD_KEY_ONLY_ON_PRIMARY_KEY_FILTERS;

/* Added in v115, enabled in v115, remove after v117 */
#define DEFAULT_ENABLE_SUBQUERY_PUSHDOWN_FOR_MATCH true
bool EnableSubqueryPushdownForMatch = DEFAULT_ENABLE_SUBQUERY_PUSHDOWN_FOR_MATCH;

/* Added in v114, enabled in v114, remove after v117 */
#define DEFAULT_ENABLE_DOLLAR_SAMPLE_RESERVOIR_SCAN true
bool EnableDollarSampleReservoirScan = DEFAULT_ENABLE_DOLLAR_SAMPLE_RESERVOIR_SCAN;

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

/* Added in v108, Pending stabilization, enable in v115 */
#define DEFAULT_SKIP_FAIL_ON_COLLATION false
bool SkipFailOnCollation = DEFAULT_SKIP_FAIL_ON_COLLATION;

/* Added in v109, Pending stabilization, enable in v115 */
#define DEFAULT_ENABLE_LOOKUP_ID_JOIN_OPTIMIZATION_ON_COLLATION false
bool EnableLookupIdJoinOptimizationOnCollation =
	DEFAULT_ENABLE_LOOKUP_ID_JOIN_OPTIMIZATION_ON_COLLATION;

/* Added in v110, Pending stabilization, enable in v115 */
#define DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES false
bool EnableCollationWithNonUniqueOrderedIndexes =
	DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES;

/* Added in v110, Pending stabilization, enable in v115 */
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

/* Added in v108, enabled in v108, remove after v113 */
#define DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT true
bool UsePgStatsLiveTuplesForCount = DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT;

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

/* Added in v110, enabled in v110, remove after v113 */
#define DEFAULT_ENABLE_DROP_INDEXES_ON_READ_ONLY true
bool EnableDropInvalidIndexesOnReadOnly = DEFAULT_ENABLE_DROP_INDEXES_ON_READ_ONLY;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_ONLY_COLLECTION_CACHE_INVALIDATE_ON_COLLECTION_CHANGES true
bool EnableOnlyCollectionCacheInvalidateOnCollectionChanges =
	DEFAULT_ENABLE_ONLY_COLLECTION_CACHE_INVALIDATE_ON_COLLECTION_CHANGES;

/* Added in v112, Pending stabilization, enable in v114 */
#define DEFAULT_ENABLE_NEW_NAMESPACE_VALIDATION false
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
		psprintf("%s.enableLookupIdJoinOptimizationOnCollation", newGucPrefix),
		gettext_noop(
			"Determines whether we can perform _id join opetimization on collation. It would be a customer input confiriming that _id does not contain collation aware data types (i.e., UTF8 and DOCUMENT)."),
		NULL, &EnableLookupIdJoinOptimizationOnCollation,
		DEFAULT_ENABLE_LOOKUP_ID_JOIN_OPTIMIZATION_ON_COLLATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCollationWithNonUniqueOrderedIndexes", newGucPrefix),
		gettext_noop(
			"Determines whether collation is supported for non-unique ordered/composite indexes."),
		NULL, &EnableCollationWithNonUniqueOrderedIndexes,
		DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES,
		PGC_USERSET, GUC_NO_SHOW_ALL | GUC_NOT_IN_SAMPLE, NULL, NULL, NULL);

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
		psprintf("%s.enableIndexOnlyScan", newGucPrefix),
		gettext_noop(
			"Whether to enable index only scan for queries that can be satisfied by an index without accessing the table."),
		NULL, &EnableIndexOnlyScan, DEFAULT_ENABLE_INDEX_ONLY_SCAN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableIndexOnlyScanOnCost", newGucPrefix),
		gettext_noop(
			"Whether to enable index only scan on cost function or planner."),
		NULL, &EnableIndexOnlyScanOnCostFunction, DEFAULT_ENABLE_INDEX_ONLY_SCAN_ON_COST,
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
		psprintf("%s.usePgStatsLiveTuplesForCount", newGucPrefix),
		gettext_noop(
			"Whether to use pg_stat_all_tables live tuples for count in collStats."),
		NULL, &UsePgStatsLiveTuplesForCount,
		DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDelayedHoldPortal", newGucPrefix),
		gettext_noop(
			"Whether to delay holding the portal until we know there is more data to be fetched."),
		NULL, &EnableDelayedHoldPortal, DEFAULT_ENABLE_DELAYED_HOLD_PORTAL,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDollarInToScalarArrayOpExprConversion", newGucPrefix),
		gettext_noop(
			"Whether to enable conversion of $in with scalar array to OpExpr."),
		NULL, &EnableDollarInToScalarArrayOpExprConversion,
		DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION,
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
		psprintf("%s.enableSortPushToAccumulatorWithPrefix", newGucPrefix),
		gettext_noop(
			"Whether to push suffix sort keys into accumulator when group keys are a prefix of sort keys in $sortGroup."),
		NULL, &EnableSortPushToAccumulatorWithPrefix,
		DEFAULT_ENABLE_SORT_PUSH_TO_ACCUMULATOR_WITH_PREFIX,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.failOnGroupIdDuplicate", newGucPrefix),
		gettext_noop(
			"Whether to fail when $group stage has duplicate _id."),
		NULL, &FailOnGroupIdDuplicate,
		DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableGroupSubqueryElimination", newGucPrefix),
		gettext_noop(
			"Whether to eliminate the subquery migration in $group by inlining bson_repath_and_build."),
		NULL, &EnableGroupSubqueryElimination,
		DEFAULT_ENABLE_GROUP_SUBQUERY_ELIMINATION,
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
		psprintf("%s.enableIndexOnlyScanForFindProject", newGucPrefix),
		gettext_noop(
			"Whether or not to enable index only scan for find with project operations."),
		NULL, &EnableIndexOnlyScanForFindProject,
		DEFAULT_ENABLE_INDEX_ONLY_SCAN_FOR_FIND_PROJECT,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeReducedCorrelatedTerms", newGucPrefix),
		gettext_noop(
			"Whether to enable reduced term generation for correlated composite paths."),
		NULL, &EnableCompositeReducedCorrelatedTerms,
		DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableUniqueCompositeReducedCorrelatedTerms", newGucPrefix),
		gettext_noop(
			"Whether to enable reduced term generation for correlated composite paths for unique indexes."),
		NULL, &EnableUniqueCompositeReducedCorrelatedTerms,
		DEFAULT_ENABLE_UNIQUE_REDUCED_CORRELATED_TERMS,
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
		psprintf("%s.enableUseForeignKeyLookupInline", newGucPrefix),
		gettext_noop(
			"Whether to use foreign key for lookup inline method."),
		NULL, &EnableUseForeignKeyLookupInline,
		DEFAULT_USE_FOREIGN_KEY_LOOKUP_INLINE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.indexBuildsScheduledOnBgWorker", newGucPrefix),
		gettext_noop(
			"Whether to schedule index builds via background worker jobs."),
		NULL, &IndexBuildsScheduledOnBgWorker,
		DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableAddToSetAggregationRewrite", newGucPrefix),
		gettext_noop(
			"Whether to enable the new addToSet aggregation implementation that prevents crashes with the new delayed portal feature."),
		NULL, &EnableAddToSetAggregationRewrite,
		DEFAULT_ENABLE_ADD_TO_SET_AGGREGATION_REWRITE,
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
		psprintf("%s.multipleDollarPositionalNotAllowed", newGucPrefix),
		gettext_noop(
			"Determines whether to throw error when multiple $ positional operators are provided in the same path e.g. 'a.b.$.c.$'"),
		NULL, &MultiplePositionalNotAllowed,
		DEFAULT_MULTIPLE_POSITIONAL_OPERATORS_NOT_ALLOWED,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableNewMinMaxAccumulators", newGucPrefix),
		gettext_noop(
			"Whether to enable new min and max aggregate optimizations."),
		NULL, &EnableNewMinMaxAccumulators,
		DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS,
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
		psprintf("%s.enablePlannerStatisticsNewCollections", newGucPrefix),
		gettext_noop(
			"Whether to enable custom planner statistics for any new collections."),
		NULL, &EnablePlannerStatisticsNewCollections,
		DEFAULT_ENABLE_PLANNER_STATISTICS_NEW_COLLECTIONS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDropInvalidIndexesOnReadOnly", newGucPrefix),
		gettext_noop(
			"Whether to enable dropping invalid indexes on read only database state."),
		NULL, &EnableDropInvalidIndexesOnReadOnly,
		DEFAULT_ENABLE_DROP_INDEXES_ON_READ_ONLY,
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
}
