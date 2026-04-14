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

/* Added in v108, Pending stabilization */
#define DEFAULT_ENABLE_SCHEMA_VALIDATION false
bool EnableSchemaValidation =
	DEFAULT_ENABLE_SCHEMA_VALIDATION;

/* Added in v108, Pending stabilization */
#define DEFAULT_ENABLE_BYPASSDOCUMENTVALIDATION false
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

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_COMPOSITE_INDEX_PLANNER false
bool EnableCompositeIndexPlanner = DEFAULT_ENABLE_COMPOSITE_INDEX_PLANNER;

/* Added in v110, enabled in v110, remove after v112 */
#define DEFAULT_ENABLE_ORDERED_COST_ESTIMATOR true
bool EnableOrderedCostEstimator = DEFAULT_ENABLE_ORDERED_COST_ESTIMATOR;

/* We can enable by default once we stabilize by moving it's creation to the cost estimate. */
/* Added in v107, enabled in v111, remove after v113. */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN true
bool EnableIndexOnlyScan = DEFAULT_ENABLE_INDEX_ONLY_SCAN;

/* Added in v111, enabled in v111, remove after v113 */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN_ON_COST true
bool EnableIndexOnlyScanOnCostFunction = DEFAULT_ENABLE_INDEX_ONLY_SCAN_ON_COST;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_ID_INDEX_CUSTOM_COST_FUNCTION true
bool EnableIdIndexCustomCostFunction = DEFAULT_ENABLE_ID_INDEX_CUSTOM_COST_FUNCTION;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_ORDER_BY_ID_ON_COST false
bool EnableOrderByIdOnCostFunction = DEFAULT_ENABLE_ORDER_BY_ID_ON_COST;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_COMPOSITE_PARALLEL_INDEX_SCAN false
bool EnableCompositeParallelIndexScan = DEFAULT_ENABLE_COMPOSITE_PARALLEL_INDEX_SCAN;

/* Note: this is a long term feature flag since we need to validate compatiblity
 * in mixed mode for older indexes - once this is
 * enabled by default - please move this to testing_configs.
 * Added in v109, enabled in v109, remove after v999
 */
#define DEFAULT_ENABLE_VALUE_ONLY_INDEX_TERMS true
bool EnableValueOnlyIndexTerms = DEFAULT_ENABLE_VALUE_ONLY_INDEX_TERMS;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_USE_NEW_UNIQUE_HASH_EQUALITY_FUNCTION true
bool UseNewUniqueHashEqualityFunction = DEFAULT_USE_NEW_UNIQUE_HASH_EQUALITY_FUNCTION;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_COMPOSITE_UNIQUE_HASH true
bool EnableCompositeUniqueHash = DEFAULT_ENABLE_COMPOSITE_UNIQUE_HASH;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_RUM_USE_NEW_COMPOSITE_TERM_GENERATION true
bool RumUseNewCompositeTermGeneration = DEFAULT_RUM_USE_NEW_COMPOSITE_TERM_GENERATION;

/* Added in v109, enabled in v110, remove after v113 */
#define DEFAULT_ENABLE_COMPOSITE_WILDCARD_INDEX true
bool EnableCompositeWildcardIndex = DEFAULT_ENABLE_COMPOSITE_WILDCARD_INDEX;

/* Added in v110, enabled in v110, remove after v113 */
#define DEFAULT_CREATE_TTL_INDEX_AS_COMPOSITE true
bool CreateTTLIndexAsCompositeByDefault = DEFAULT_CREATE_TTL_INDEX_AS_COMPOSITE;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS false
bool EnableCompositeReducedCorrelatedTerms = DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_UNIQUE_REDUCED_CORRELATED_TERMS false
bool EnableUniqueCompositeReducedCorrelatedTerms =
	DEFAULT_ENABLE_UNIQUE_REDUCED_CORRELATED_TERMS;

/* Added in v111, enabled in v111, remove after v115 */
#define DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS_ON_COMMON_SUBPATH true
bool EnableCompositeReducedCorrelatedTermsOnCommonSubPath =
	DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS_ON_COMMON_SUBPATH;

/* Longer term feature flag to track older cluster data: Move to testing_configs when convenient */
/* Added in v109, enabled in v109, remove after v999 */
#define DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS true
bool EnableCompositeShardDocumentTerms = DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS;

/* Added in v110, enabled in v110, remove after v113 */
#define DEFAULT_ENABLE_COMPOSITE_WILDCARD_SKIP_EMPTY_ENTRIES true
bool EnableCompositeWildcardSkipEmptyEntries =
	DEFAULT_ENABLE_COMPOSITE_WILDCARD_SKIP_EMPTY_ENTRIES;

/* Added in v111, Pending stabilization */
#define DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS false
bool EnablePerCollectionPlannerStatistics =
	DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS;

/* Added in v111, enabled in v111, remove after v114 */
#define DEFAULT_ENABLE_ORDERED_COMPOSITE_OPERATOR_SCAN true
bool EnableOrderedCompositeOperatorScan = DEFAULT_ENABLE_ORDERED_COMPOSITE_OPERATOR_SCAN;

/* Added in v111, enabled in v111, remove after v114 */
#define DEFAULT_ENABLE_REGEX_PREFIX_INDEX_BOUNDS true
bool EnableRegexPrefixIndexBounds = DEFAULT_ENABLE_REGEX_PREFIX_INDEX_BOUNDS;

/* Added in v111, Pending stabilization */
#define DEFAULT_ENABLE_EXTENDED_INDEXES false
bool EnableExtendedIndexes = DEFAULT_ENABLE_EXTENDED_INDEXES;

/* Added in v111, Pending stabilization */
#define DEFAULT_ENABLE_COMPARABLE_TERMS false
bool EnableComparableTerms = DEFAULT_ENABLE_COMPARABLE_TERMS;

/* Added in v111, Pending stabilization */
#define DEFAULT_ENABLE_ORDER_BY_INDEX_TERM false
bool EnableOrderByIndexTerm = DEFAULT_ENABLE_ORDER_BY_INDEX_TERM;

/* Added in v112, enabled in v112, remove after v116 */
#define DEFAULT_ENABLE_PARTIAL_MATCH_HAS_RECHECK true
bool EnablePartialMatchHasRecheck = DEFAULT_ENABLE_PARTIAL_MATCH_HAS_RECHECK;

/*
 * SECTION: Planner feature flags
 */

/* Added in v108, enabled in v108, remove after v110 */
#define DEFAULT_LOW_SELECTIVITY_FOR_LOOKUP true
bool LowSelectivityForLookup = DEFAULT_LOW_SELECTIVITY_FOR_LOOKUP;

/* Added in v109, enabled in v109, remove after v112 */
#define DEFAULT_ENABLE_EXPR_LOOKUP_INDEX_PUSHDOWN true
bool EnableExprLookupIndexPushdown = DEFAULT_ENABLE_EXPR_LOOKUP_INDEX_PUSHDOWN;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_UNIFY_PFE_ON_INDEXINFO true
bool EnableUnifyPfeOnIndexInfo = DEFAULT_ENABLE_UNIFY_PFE_ON_INDEXINFO;

/* Added in v108, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_NEW_COUNT_AGGREGATES true
bool EnableNewCountAggregates = DEFAULT_ENABLE_NEW_COUNT_AGGREGATES;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_EXTENDED_EXPLAIN_ON_ANALYZEOFF true
bool EnableExtendedExplainOnAnalyzeOff = DEFAULT_ENABLE_EXTENDED_EXPLAIN_ON_ANALYZEOFF;

/* Left here temporarily for stabilization. Move to test config and remove once all test output is updated */
/* Added in v110, enabled in v110, remove after v112 */
#define DEFAULT_ENABLE_EXPLAIN_SCAN_INDEX_COSTS true
bool EnableExplainScanIndexCosts = DEFAULT_ENABLE_EXPLAIN_SCAN_INDEX_COSTS;

/* Left here temporarily for stabilization. Move to test config and remove once all test output is updated */
/* Added in v110, enabled in v110, remove after v112 */
#define DEFAULT_ENABLE_EXPLAIN_SCAN_NAMESPACE_NAME true
bool EnableExplainScanNamespaceName = DEFAULT_ENABLE_EXPLAIN_SCAN_NAMESPACE_NAME;

/* Added in v110, Pending stabilization. Superseded by EnableNewWithExprAccumulators in v111 */
#define DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS false
bool EnableNewMinMaxAccumulators = DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS;

/* Added in v111, Pending stabilization */
#define DEFAULT_ENABLE_NEW_WITH_EXPR_ACCUMULATORS false
bool EnableNewWithExprAccumulators = DEFAULT_ENABLE_NEW_WITH_EXPR_ACCUMULATORS;

/* Added in v111, enabled in v111, remove after v112 */
#define DEFAULT_ENABLE_CURSOR_PLAN_BEFORE_RESTRICTION_PATH_UPDATE true
bool EnableCursorPlanBeforeRestrictionPathUpdate =
	DEFAULT_ENABLE_CURSOR_PLAN_BEFORE_RESTRICTION_PATH_UPDATE;

/*
 * SECTION: Aggregation & Query feature flags
 */

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_PRIMARY_KEY_CURSOR_SCAN false
bool EnablePrimaryKeyCursorScan = DEFAULT_ENABLE_PRIMARY_KEY_CURSOR_SCAN;

/* Added in v110, Pending stabilization */
#define DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP false
bool EnableContinuationFastBitmapLookup = DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP;

/* Added in v108, Pending stabilization */
#define DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS false
bool UseFileBasedPersistedCursors = DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS;

/* Added in v111, Pending stabilization */
#define DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE false
bool FailOnGroupIdDuplicate =
	DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_CONVERSION_STREAMABLE_SINGLE_BATCH true
bool EnableConversionStreamableToSingleBatch =
	DEFAULT_ENABLE_CONVERSION_STREAMABLE_SINGLE_BATCH;

/* Added in v109, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_FIND_PROJECTION_AFTER_OFFSET true
bool EnableFindProjectionAfterOffset = DEFAULT_ENABLE_FIND_PROJECTION_AFTER_OFFSET;

/* Added in v108, enabled in v109, remove after v111 */
#define DEFAULT_ENABLE_DELAYED_HOLD_PORTAL true
bool EnableDelayedHoldPortal = DEFAULT_ENABLE_DELAYED_HOLD_PORTAL;

/* Added in v108, enabled in v108, remove after v110 */
#define DEFAULT_ENABLE_ID_INDEX_PUSHDOWN true
bool EnableIdIndexPushdown = DEFAULT_ENABLE_ID_INDEX_PUSHDOWN;

/* Added in v110, enabled in 110, remove after v113 */
#define DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION true
bool EnableDollarInToScalarArrayOpExprConversion =
	DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION;

/* Added in v111, enabled in v111, remove after v114 */
#define DEFAULT_USE_FOREIGN_KEY_LOOKUP_INLINE true
bool EnableUseForeignKeyLookupInline = DEFAULT_USE_FOREIGN_KEY_LOOKUP_INLINE;

/* Added in v110, enabled in v110, remove after v113 */
#define DEFAULT_ENABLE_ADD_TO_SET_AGGREGATION_REWRITE true
bool EnableAddToSetAggregationRewrite = DEFAULT_ENABLE_ADD_TO_SET_AGGREGATION_REWRITE;

/* Added in v109, enabled in v109, Remove after 112*/
#define DEFAULT_ENABLE_ID_INDEX_PUSHDOWN_FOR_QUERY_OP true
bool EnableIdIndexPushdownForQueryOp =
	DEFAULT_ENABLE_ID_INDEX_PUSHDOWN_FOR_QUERY_OP;

/* Added in v110, enabled in v110, remove after v112 */
#define DEFAULT_ENABLE_BINARY_SEARCH_FOR_ORDERED_MOVE true
bool EnableBinarySearchForOrderedMove = DEFAULT_ENABLE_BINARY_SEARCH_FOR_ORDERED_MOVE;

/* Added in v110, enabled in v110, remove after v112 */
#define DEFAULT_INLINE_CHANGESTREAM_MATCH_STAGES true
bool InlineChangeStreamMatchStage = DEFAULT_INLINE_CHANGESTREAM_MATCH_STAGES;

/* Added in v110, enabled in v110, unknown stabilization removal time */
#define DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS true
bool RemoveMatchNamespaceFilters = DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS;

/* Added in v111, enabled in v111, Remove after v113 */
#define DEFAULT_MULTIPLE_POSITONAL_OPERATORS_NOT_ALLOWED true
bool MultiplePositionalNotAllowed = DEFAULT_MULTIPLE_POSITONAL_OPERATORS_NOT_ALLOWED;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_GROUP_SUBQUERY_ELIMINATION true
bool EnableGroupSubqueryElimination = DEFAULT_ENABLE_GROUP_SUBQUERY_ELIMINATION;

/* Added in v111, Pending stabilization */
#define DEFAULT_FAIL_ON_NON_EMPTY_GROUP_COUNT_ARG false
bool FailOnNonEmptyGroupCountArg = DEFAULT_FAIL_ON_NON_EMPTY_GROUP_COUNT_ARG;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_SORT_GROUP_STAGE true
bool EnableSortGroupStage = DEFAULT_ENABLE_SORT_GROUP_STAGE;

/*
 * SECTION: Let support feature flags
 */

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_OPERATOR_VARIABLES_IN_LOOKUP false
bool EnableOperatorVariablesInLookup =
	DEFAULT_ENABLE_OPERATOR_VARIABLES_IN_LOOKUP;

/*
 * SECTION: Collation feature flags
 */

/* Added in v108, Pending stabilization */
#define DEFAULT_SKIP_FAIL_ON_COLLATION false
bool SkipFailOnCollation = DEFAULT_SKIP_FAIL_ON_COLLATION;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_LOOKUP_ID_JOIN_OPTIMIZATION_ON_COLLATION false
bool EnableLookupIdJoinOptimizationOnCollation =
	DEFAULT_ENABLE_LOOKUP_ID_JOIN_OPTIMIZATION_ON_COLLATION;

/* Added in v110, Pending stabilization */
#define DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES false
bool EnableCollationWithNonUniqueOrderedIndexes =
	DEFAULT_ENABLE_COLLATION_WITH_NON_UNIQUE_ORDERED_INDEXES;

/* Added in v110, Pending stabilization */
#define DEFAULT_ENABLE_COLLATION_WITH_NEW_GROUP_ACCUMULATORS false
bool EnableCollationWithNewGroupAccumulators =
	DEFAULT_ENABLE_COLLATION_WITH_NEW_GROUP_ACCUMULATORS;


/*
 * SECTION: DML & Write path feature flags
 */

/* Added in v109, enabled in v109, remove after v112 */
#define DEFAULT_ENABLE_UPDATE_BSON_DOCUMENT true
bool EnableUpdateBsonDocument = DEFAULT_ENABLE_UPDATE_BSON_DOCUMENT;


/*
 * SECTION: Cluster administration & DDL feature flags
 */

/* Added in v108, Pending stabilization */
#define DEFAULT_RECREATE_RETRY_TABLE_ON_SHARDING false
bool RecreateRetryTableOnSharding = DEFAULT_RECREATE_RETRY_TABLE_ON_SHARDING;

/* Added in v108, enabled in v108, unknown retirement schedule */
#define DEFAULT_ENABLE_SCHEMA_ENFORCEMENT_FOR_CSFLE true
bool EnableSchemaEnforcementForCSFLE = DEFAULT_ENABLE_SCHEMA_ENFORCEMENT_FOR_CSFLE;

/* Added in v108, enabled in v108, remove after v113 */
#define DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT true
bool UsePgStatsLiveTuplesForCount = DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_PREPARE_UNIQUE false
bool EnablePrepareUnique = DEFAULT_ENABLE_PREPARE_UNIQUE;

/* Added in v109, Pending stabilization */
#define DEFAULT_ENABLE_COLLMOD_UNIQUE false
bool EnableCollModUnique = DEFAULT_ENABLE_COLLMOD_UNIQUE;

/* Added in v110, enabled in v110, remove after v113 */
#define DEFAULT_ENABLE_DROP_INDEXES_ON_READ_ONLY true
bool EnableDropInvalidIndexesOnReadOnly = DEFAULT_ENABLE_DROP_INDEXES_ON_READ_ONLY;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_ONLY_COLLECTION_CACHE_INVALIDATE_ON_COLLECTION_CHANGES true
bool EnableOnlyCollectionCacheInvalidateOnCollectionChanges =
	DEFAULT_ENABLE_ONLY_COLLECTION_CACHE_INVALIDATE_ON_COLLECTION_CHANGES;

/* Added in v112, enabled in v112, remove after v114 */
#define DEFAULT_ENABLE_STREAMING_CURSOR_DRAIN_VIA_DESTRECEIVER true
bool EnableStreamingCursorDrainViaDestReceiver =
	DEFAULT_ENABLE_STREAMING_CURSOR_DRAIN_VIA_DESTRECEIVER;

/*
 * SECTION: Schedule jobs via background worker.
 */

/* Added in v109, Pending stabilization */
#define DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER false
bool IndexBuildsScheduledOnBgWorker = DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER;

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
		psprintf("%s.recreate_retry_table_on_shard", prefix),
		gettext_noop(
			"Gets whether or not to recreate a retry table to match the main table"),
		NULL, &RecreateRetryTableOnSharding, DEFAULT_RECREATE_RETRY_TABLE_ON_SHARDING,
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
		psprintf("%s.enableCursorPlanBeforeRestrictionPathUpdate", newGucPrefix),
		gettext_noop(
			"Whether to enable running the streaming cursor plan rewrite before path replacement."),
		NULL, &EnableCursorPlanBeforeRestrictionPathUpdate,
		DEFAULT_ENABLE_CURSOR_PLAN_BEFORE_RESTRICTION_PATH_UPDATE,
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
		psprintf("%s.lowSelectivityForLookup", newGucPrefix),
		gettext_noop(
			"Whether or not to use low selectivity for lookup."),
		NULL, &LowSelectivityForLookup,
		DEFAULT_LOW_SELECTIVITY_FOR_LOOKUP,
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
		psprintf("%s.enableOrderedCostEstimator", newGucPrefix),
		gettext_noop(
			"Whether to enable the new ordered cost estimator for composite indexes. Requires enableCompositeIndexPlanner"),
		NULL, &EnableOrderedCostEstimator, DEFAULT_ENABLE_ORDERED_COST_ESTIMATOR,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableConversionStreamableToSingleBatch", newGucPrefix),
		gettext_noop(
			"Whether to enable conversion streamable to single batch queries."),
		NULL, &EnableConversionStreamableToSingleBatch,
		DEFAULT_ENABLE_CONVERSION_STREAMABLE_SINGLE_BATCH,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableFindProjectionAfterOffset", newGucPrefix),
		gettext_noop(
			"Whether to enable pushing projection as a subquery after offset."),
		NULL, &EnableFindProjectionAfterOffset,
		DEFAULT_ENABLE_FIND_PROJECTION_AFTER_OFFSET,
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
		psprintf("%s.enablePartialMatchHasRecheck", newGucPrefix),
		gettext_noop(
			"Whether to enable partial match has recheck for queries that have partial index matches."),
		NULL, &EnablePartialMatchHasRecheck, DEFAULT_ENABLE_PARTIAL_MATCH_HAS_RECHECK,
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
		psprintf("%s.enableIdIndexPushdown", newGucPrefix),
		gettext_noop(
			"Whether to enable extended id index pushdown optimizations."),
		NULL, &EnableIdIndexPushdown, DEFAULT_ENABLE_ID_INDEX_PUSHDOWN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDollarInToScalarArrayOpExprConversion", newGucPrefix),
		gettext_noop(
			"Whether to enable conversion of $in with scalar array to OpExpr."),
		NULL, &EnableDollarInToScalarArrayOpExprConversion,
		DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION,
		PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable(
		psprintf("%s.enableExprLookupIndexPushdown", newGucPrefix),
		gettext_noop(
			"Whether to expr and lookup pushdown to the index."),
		NULL, &EnableExprLookupIndexPushdown, DEFAULT_ENABLE_EXPR_LOOKUP_INDEX_PUSHDOWN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.unifyPfeOnIndexInfo", newGucPrefix),
		gettext_noop(
			"Whether to unify partial filter expressions on index expressions."),
		NULL, &EnableUnifyPfeOnIndexInfo, DEFAULT_ENABLE_UNIFY_PFE_ON_INDEXINFO,
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
		psprintf("%s.enableUpdateBsonDocument", newGucPrefix),
		gettext_noop(
			"Whether to enable the update_bson_document command."),
		NULL, &EnableUpdateBsonDocument, DEFAULT_ENABLE_UPDATE_BSON_DOCUMENT,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableIdIndexCustomCostFunction", newGucPrefix),
		gettext_noop(
			"Whether to enable index terms that are value only."),
		NULL, &EnableIdIndexCustomCostFunction,
		DEFAULT_ENABLE_ID_INDEX_CUSTOM_COST_FUNCTION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableOrderByIdOnCostFunction", newGucPrefix),
		gettext_noop(
			"Whether to enable index terms that are value only."),
		NULL, &EnableOrderByIdOnCostFunction, DEFAULT_ENABLE_ORDER_BY_ID_ON_COST,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeParallelIndexScan", newGucPrefix),
		gettext_noop(
			"Whether to enable parallel index scans for composite indexes."),
		NULL, &EnableCompositeParallelIndexScan,
		DEFAULT_ENABLE_COMPOSITE_PARALLEL_INDEX_SCAN,
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
		psprintf("%s.enableNewCountAggregates", newGucPrefix),
		gettext_noop(
			"Whether to enable new count aggregate optimizations."),
		NULL, &EnableNewCountAggregates, DEFAULT_ENABLE_NEW_COUNT_AGGREGATES,
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
		psprintf("%s.failOnGroupIdDuplicate", newGucPrefix),
		gettext_noop(
			"Whether to fail when $group stage has duplicate _id."),
		NULL, &FailOnGroupIdDuplicate,
		DEFAULT_FAIL_ON_GROUP_ID_DUPLICATE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableExtendedExplainOnAnalyzeOff", newGucPrefix),
		gettext_noop(
			"Whether to enable logging extended explain on explain with analyze off."),
		NULL, &EnableExtendedExplainOnAnalyzeOff,
		DEFAULT_ENABLE_EXTENDED_EXPLAIN_ON_ANALYZEOFF,
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
		psprintf("%s.enableRumNewCompositeTermGeneration", newGucPrefix),
		gettext_noop(
			"Whether to enable the new term generation for composite terms."),
		NULL, &RumUseNewCompositeTermGeneration,
		DEFAULT_RUM_USE_NEW_COMPOSITE_TERM_GENERATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeWildcardIndex", newGucPrefix),
		gettext_noop(
			"Whether to enable composite wildcard index support"),
		NULL, &EnableCompositeWildcardIndex, DEFAULT_ENABLE_COMPOSITE_WILDCARD_INDEX,
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
		psprintf("%s.enableCompositeShardDocumentTerms", newGucPrefix),
		gettext_noop(
			"Whether to enable shard hash term generation for composite indexes (specially for null handling)."),
		NULL, &EnableCompositeShardDocumentTerms,
		DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS,
		PGC_USERSET, 0, NULL, NULL, NULL);


	DefineCustomBoolVariable(
		psprintf("%s.enableCompositeWildcardSkipEmptyEntries", newGucPrefix),
		gettext_noop(
			"Whether to enable skipping empty entries for composite wildcard indexes."),
		NULL, &EnableCompositeWildcardSkipEmptyEntries,
		DEFAULT_ENABLE_COMPOSITE_WILDCARD_SKIP_EMPTY_ENTRIES,
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
		psprintf("%s.enableIdIndexPushdownForQueryOp", newGucPrefix),
		gettext_noop(
			"Whether to enable index push down for _id index."),
		NULL, &EnableIdIndexPushdownForQueryOp,
		DEFAULT_ENABLE_ID_INDEX_PUSHDOWN_FOR_QUERY_OP,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableBinarySearchForOrderedMove", newGucPrefix),
		gettext_noop(
			"Whether to enable binary search for ordered move."),
		NULL, &EnableBinarySearchForOrderedMove,
		DEFAULT_ENABLE_BINARY_SEARCH_FOR_ORDERED_MOVE,
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
		psprintf("%s.inlineChangeStreamMatchStage", newGucPrefix),
		gettext_noop(
			"Determines whether to inline $match aggregation stage with  $changestreams"),
		NULL, &InlineChangeStreamMatchStage,
		DEFAULT_INLINE_CHANGESTREAM_MATCH_STAGES,
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
		psprintf("%s.enableExplainScanIndexCosts", newGucPrefix),
		gettext_noop(
			"Whether to include index costs in explain output for index scans. requires enableextendedexplainplans"),
		NULL, &EnableExplainScanIndexCosts,
		DEFAULT_ENABLE_EXPLAIN_SCAN_INDEX_COSTS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableExplainScanNamespaceName", newGucPrefix),
		gettext_noop(
			"Whether to include namespace name in explain output for index scans. requires enableextendedexplainplans"),
		NULL, &EnableExplainScanNamespaceName,
		DEFAULT_ENABLE_EXPLAIN_SCAN_NAMESPACE_NAME,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.multipleDollarPositionalNotAllowed", newGucPrefix),
		gettext_noop(
			"Determines whether to throw error when multiple $ positional operators are provided in the same path e.g. 'a.b.$.c.$'"),
		NULL, &MultiplePositionalNotAllowed,
		DEFAULT_MULTIPLE_POSITONAL_OPERATORS_NOT_ALLOWED,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableNewMinMaxAccumulators", newGucPrefix),
		gettext_noop(
			"Whether to enable new min and max aggregate optimizations."),
		NULL, &EnableNewMinMaxAccumulators,
		DEFAULT_ENABLE_NEW_MIN_MAX_ACCUMULATORS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enablePerCollectionPlannerStatistics", newGucPrefix),
		gettext_noop(
			"Whether to enable per-collection planner statistics."),
		NULL, &EnablePerCollectionPlannerStatistics,
		DEFAULT_ENABLE_PER_COLLECTION_PLANNER_STATISTICS,
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
		psprintf("%s.enableStreamingCursorDrainViaDestReceiver", newGucPrefix),
		gettext_noop(
			"Whether to use direct executor DestReceiver for streaming cursor drainage instead of SPI."),
		NULL, &EnableStreamingCursorDrainViaDestReceiver,
		DEFAULT_ENABLE_STREAMING_CURSOR_DRAIN_VIA_DESTRECEIVER,
		PGC_USERSET, 0, NULL, NULL, NULL);
}
