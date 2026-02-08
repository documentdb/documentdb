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
 * SECTION: Top level feature flags
 */
#define DEFAULT_ENABLE_SCHEMA_VALIDATION false
bool EnableSchemaValidation =
	DEFAULT_ENABLE_SCHEMA_VALIDATION;

#define DEFAULT_ENABLE_BYPASSDOCUMENTVALIDATION false
bool EnableBypassDocumentValidation =
	DEFAULT_ENABLE_BYPASSDOCUMENTVALIDATION;

#define DEFAULT_ENABLE_USERNAME_PASSWORD_CONSTRAINTS true
bool EnableUsernamePasswordConstraints = DEFAULT_ENABLE_USERNAME_PASSWORD_CONSTRAINTS;

#define DEFAULT_ENABLE_USERS_INFO_PRIVILEGES true
bool EnableUsersInfoPrivileges = DEFAULT_ENABLE_USERS_INFO_PRIVILEGES;

#define DEFAULT_ENABLE_NATIVE_AUTHENTICATION true
bool IsNativeAuthEnabled = DEFAULT_ENABLE_NATIVE_AUTHENTICATION;

#define DEFAULT_ENABLE_ROLE_CRUD false
bool EnableRoleCrud = DEFAULT_ENABLE_ROLE_CRUD;

#define DEFAULT_ENABLE_USERS_ADMIN_DB_CHECK false
bool EnableUsersAdminDBCheck = DEFAULT_ENABLE_USERS_ADMIN_DB_CHECK;

#define DEFAULT_ENABLE_ROLES_ADMIN_DB_CHECK true
bool EnableRolesAdminDBCheck = DEFAULT_ENABLE_ROLES_ADMIN_DB_CHECK;

/*
 * SECTION: Vector Search flags
 */

/* GUC to enable HNSW index type and query for vector search. */
#define DEFAULT_ENABLE_VECTOR_HNSW_INDEX true
bool EnableVectorHNSWIndex = DEFAULT_ENABLE_VECTOR_HNSW_INDEX;

/* GUC to enable vector pre-filtering feature for vector search. */
#define DEFAULT_ENABLE_VECTOR_PRE_FILTER true
bool EnableVectorPreFilter = DEFAULT_ENABLE_VECTOR_PRE_FILTER;

#define DEFAULT_ENABLE_VECTOR_PRE_FILTER_V2 false
bool EnableVectorPreFilterV2 = DEFAULT_ENABLE_VECTOR_PRE_FILTER_V2;

#define DEFAULT_ENABLE_VECTOR_FORCE_INDEX_PUSHDOWN false
bool EnableVectorForceIndexPushdown = DEFAULT_ENABLE_VECTOR_FORCE_INDEX_PUSHDOWN;

/* GUC to enable vector compression for vector search. */
#define DEFAULT_ENABLE_VECTOR_COMPRESSION_HALF true
bool EnableVectorCompressionHalf = DEFAULT_ENABLE_VECTOR_COMPRESSION_HALF;

#define DEFAULT_ENABLE_VECTOR_COMPRESSION_PQ true
bool EnableVectorCompressionPQ = DEFAULT_ENABLE_VECTOR_COMPRESSION_PQ;

#define DEFAULT_ENABLE_VECTOR_CALCULATE_DEFAULT_SEARCH_PARAM true
bool EnableVectorCalculateDefaultSearchParameter =
	DEFAULT_ENABLE_VECTOR_CALCULATE_DEFAULT_SEARCH_PARAM;

/*
 * SECTION: Indexing feature flags
 */

#define DEFAULT_USE_NEW_COMPOSITE_INDEX_OPCLASS true
bool DefaultUseCompositeOpClass = DEFAULT_USE_NEW_COMPOSITE_INDEX_OPCLASS;

#define DEFAULT_ENABLE_COMPOSITE_INDEX_PLANNER false
bool EnableCompositeIndexPlanner = DEFAULT_ENABLE_COMPOSITE_INDEX_PLANNER;

/* Ready to remove */
#define DEFAULT_ENABLE_INDEX_ORDERBY_PUSHDOWN true
bool EnableIndexOrderbyPushdown = DEFAULT_ENABLE_INDEX_ORDERBY_PUSHDOWN;

/* We can enable by default once we stabilize by moving it's creation to the cost estimate. */
#define DEFAULT_ENABLE_INDEX_ONLY_SCAN false
bool EnableIndexOnlyScan = DEFAULT_ENABLE_INDEX_ONLY_SCAN;

#define DEFAULT_ENABLE_ID_INDEX_CUSTOM_COST_FUNCTION true
bool EnableIdIndexCustomCostFunction = DEFAULT_ENABLE_ID_INDEX_CUSTOM_COST_FUNCTION;

#define DEFAULT_ENABLE_ORDER_BY_ID_ON_COST false
bool EnableOrderByIdOnCostFunction = DEFAULT_ENABLE_ORDER_BY_ID_ON_COST;

#define DEFAULT_ENABLE_COMPOSITE_PARALLEL_INDEX_SCAN false
bool EnableCompositeParallelIndexScan = DEFAULT_ENABLE_COMPOSITE_PARALLEL_INDEX_SCAN;

/* Note: this is a long term feature flag since we need to validate compatiblity
 * in mixed mode for older indexes - once this is
 * enabled by default - please move this to testing_configs.
 */
#define DEFAULT_ENABLE_VALUE_ONLY_INDEX_TERMS true
bool EnableValueOnlyIndexTerms = DEFAULT_ENABLE_VALUE_ONLY_INDEX_TERMS;

/* Remove after v111 */
#define DEFAULT_USE_NEW_UNIQUE_HASH_EQUALITY_FUNCTION true
bool UseNewUniqueHashEqualityFunction = DEFAULT_USE_NEW_UNIQUE_HASH_EQUALITY_FUNCTION;

/* Remove after v111 */
#define DEFAULT_ENABLE_COMPOSITE_UNIQUE_HASH true
bool EnableCompositeUniqueHash = DEFAULT_ENABLE_COMPOSITE_UNIQUE_HASH;

/* Remove after v111 */
#define DEFAULT_RUM_USE_NEW_COMPOSITE_TERM_GENERATION true
bool RumUseNewCompositeTermGeneration = DEFAULT_RUM_USE_NEW_COMPOSITE_TERM_GENERATION;

/* Remove after v111 */
#define DEFAULT_ENABLE_COMPOSITE_WILDCARD_INDEX true
bool EnableCompositeWildcardIndex = DEFAULT_ENABLE_COMPOSITE_WILDCARD_INDEX;

#define DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS false
bool EnableCompositeReducedCorrelatedTerms = DEFAULT_ENABLE_REDUCED_CORRELATED_TERMS;

#define DEFAULT_ENABLE_UNIQUE_REDUCED_CORRELATED_TERMS false
bool EnableUniqueCompositeReducedCorrelatedTerms =
	DEFAULT_ENABLE_UNIQUE_REDUCED_CORRELATED_TERMS;

/* Longer term feature flag to track older cluster data: Move to testing_configs when convenient */
#define DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS true
bool EnableCompositeShardDocumentTerms = DEFAULT_ENABLE_COMPOSITE_SHARD_DOCUMENT_TERMS;

#define DEFAULT_ENABLE_COMPOSITE_WILDCARD_SKIP_EMPTY_ENTRIES true
bool EnableCompositeWildcardSkipEmptyEntries =
	DEFAULT_ENABLE_COMPOSITE_WILDCARD_SKIP_EMPTY_ENTRIES;

/*
 * SECTION: Planner feature flags
 */
#define DEFAULT_ENABLE_NEW_OPERATOR_SELECTIVITY false
bool EnableNewOperatorSelectivityMode = DEFAULT_ENABLE_NEW_OPERATOR_SELECTIVITY;

/* Remove after v109 */
#define DEFAULT_LOOKUP_ENABLE_INNER_JOIN true
bool EnableLookupInnerJoin = DEFAULT_LOOKUP_ENABLE_INNER_JOIN;

#define DEFAULT_FORCE_BITMAP_SCAN_FOR_LOOKUP false
bool ForceBitmapScanForLookup = DEFAULT_FORCE_BITMAP_SCAN_FOR_LOOKUP;

/* Remove after v110 */
#define DEFAULT_LOW_SELECTIVITY_FOR_LOOKUP true
bool LowSelectivityForLookup = DEFAULT_LOW_SELECTIVITY_FOR_LOOKUP;

/* Remove after v111 */
#define DEFAULT_ENABLE_EXPR_LOOKUP_INDEX_PUSHDOWN true
bool EnableExprLookupIndexPushdown = DEFAULT_ENABLE_EXPR_LOOKUP_INDEX_PUSHDOWN;

/* Remove after v111 */
#define DEFAULT_ENABLE_UNIFY_PFE_ON_INDEXINFO true
bool EnableUnifyPfeOnIndexInfo = DEFAULT_ENABLE_UNIFY_PFE_ON_INDEXINFO;

/* Remove after v111 */
#define DEFAULT_ENABLE_UPDATE_BSON_DOCUMENT true
bool EnableUpdateBsonDocument = DEFAULT_ENABLE_UPDATE_BSON_DOCUMENT;

/* Remove after v111 */
#define DEFAULT_ENABLE_NEW_COUNT_AGGREGATES true
bool EnableNewCountAggregates = DEFAULT_ENABLE_NEW_COUNT_AGGREGATES;

/* Remove after v111 */
#define DEFAULT_ENABLE_EXTENDED_EXPLAIN_ON_ANALYZEOFF true
bool EnableExtendedExplainOnAnalyzeOff = DEFAULT_ENABLE_EXTENDED_EXPLAIN_ON_ANALYZEOFF;


/*
 * SECTION: Aggregation & Query feature flags
 */
#define DEFAULT_ENABLE_NOW_SYSTEM_VARIABLE true
bool EnableNowSystemVariable = DEFAULT_ENABLE_NOW_SYSTEM_VARIABLE;

#define DEFAULT_ENABLE_PRIMARY_KEY_CURSOR_SCAN false
bool EnablePrimaryKeyCursorScan = DEFAULT_ENABLE_PRIMARY_KEY_CURSOR_SCAN;

#define DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP false
bool EnableContinuationFastBitmapLookup = DEFAULT_ENABLE_CONTINUATION_FAST_BITMAP_LOOKUP;

#define DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS false
bool UseFileBasedPersistedCursors = DEFAULT_USE_FILE_BASED_PERSISTED_CURSORS;

/* Remove after v111 */
#define DEFAULT_ENABLE_CONVERSION_STREAMABLE_SINGLE_BATCH true
bool EnableConversionStreamableToSingleBatch =
	DEFAULT_ENABLE_CONVERSION_STREAMABLE_SINGLE_BATCH;

/* Remove after v111 */
#define DEFAULT_ENABLE_FIND_PROJECTION_AFTER_OFFSET true
bool EnableFindProjectionAfterOffset = DEFAULT_ENABLE_FIND_PROJECTION_AFTER_OFFSET;

/* Remove after v109 */
#define DEFAULT_ENABLE_DELAYED_HOLD_PORTAL true
bool EnableDelayedHoldPortal = DEFAULT_ENABLE_DELAYED_HOLD_PORTAL;

/* Remove after v109 */
#define DEFAULT_FORCE_COLL_STATS_DATA_COLLECTION false
bool ForceCollStatsDataCollection = DEFAULT_FORCE_COLL_STATS_DATA_COLLECTION;

/* Remove after 110 */
#define DEFAULT_ENABLE_ID_INDEX_PUSHDOWN true
bool EnableIdIndexPushdown = DEFAULT_ENABLE_ID_INDEX_PUSHDOWN;

#define DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION true
bool EnableDollarInToScalarArrayOpExprConversion =
	DEFAULT_ENABLE_DOLLAR_IN_TO_SCALAR_ARRAY_OP_EXPR_CONVERSION;

/* Remove after 111*/
#define DEFAULT_USE_LOOKUP_NEW_PROJECT_INLINE_METHOD true
bool EnableUseLookupNewProjectInlineMethod = DEFAULT_USE_LOOKUP_NEW_PROJECT_INLINE_METHOD;
#define DEFAULT_USE_FOREIGN_KEY_LOOKUP_INLINE true
bool EnableUseForeignKeyLookupInline = DEFAULT_USE_FOREIGN_KEY_LOOKUP_INLINE;

/* Remove after 111 */
#define DEFAULT_ENABLE_ADD_TO_SET_AGGREGATION_REWRITE true
bool EnableAddToSetAggregationRewrite = DEFAULT_ENABLE_ADD_TO_SET_AGGREGATION_REWRITE;

/*
 * SECTION: Let support feature flags
 */
#define DEFAULT_ENABLE_LET_AND_COLLATION_FOR_QUERY_MATCH true
bool EnableLetAndCollationForQueryMatch =
	DEFAULT_ENABLE_LET_AND_COLLATION_FOR_QUERY_MATCH;

#define DEFAULT_ENABLE_VARIABLES_SUPPORT_FOR_WRITE_COMMANDS true
bool EnableVariablesSupportForWriteCommands =
	DEFAULT_ENABLE_VARIABLES_SUPPORT_FOR_WRITE_COMMANDS;

#define DEFAULT_ENABLE_OPERATOR_VARIABLES_IN_LOOKUP false
bool EnableOperatorVariablesInLookup =
	DEFAULT_ENABLE_OPERATOR_VARIABLES_IN_LOOKUP;

/*
 * SECTION: Collation feature flags
 */
#define DEFAULT_SKIP_FAIL_ON_COLLATION false
bool SkipFailOnCollation = DEFAULT_SKIP_FAIL_ON_COLLATION;

#define DEFAULT_ENABLE_LOOKUP_ID_JOIN_OPTIMIZATION_ON_COLLATION false
bool EnableLookupIdJoinOptimizationOnCollation =
	DEFAULT_ENABLE_LOOKUP_ID_JOIN_OPTIMIZATION_ON_COLLATION;

#define DEFAULT_ENABLE_COLLATION_WITH_INDEXES false
bool EnableCollationWithIndexes = DEFAULT_ENABLE_COLLATION_WITH_INDEXES;


/*
 * SECTION: DML Write Path feature flags
 */

#define DEFAULT_RUM_FAIL_ON_LOST_PATH false
bool RumFailOnLostPath = DEFAULT_RUM_FAIL_ON_LOST_PATH;


/*
 * SECTION: Cluster administration & DDL feature flags
 */
#define DEFAULT_RECREATE_RETRY_TABLE_ON_SHARDING false
bool RecreateRetryTableOnSharding = DEFAULT_RECREATE_RETRY_TABLE_ON_SHARDING;

#define DEFAULT_ENABLE_DATA_TABLES_WITHOUT_CREATION_TIME true
bool EnableDataTableWithoutCreationTime =
	DEFAULT_ENABLE_DATA_TABLES_WITHOUT_CREATION_TIME;

#define DEFAULT_ENABLE_SCHEMA_ENFORCEMENT_FOR_CSFLE true
bool EnableSchemaEnforcementForCSFLE = DEFAULT_ENABLE_SCHEMA_ENFORCEMENT_FOR_CSFLE;

#define DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT true
bool UsePgStatsLiveTuplesForCount = DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT;

#define DEFAULT_ENABLE_PREPARE_UNIQUE false
bool EnablePrepareUnique = DEFAULT_ENABLE_PREPARE_UNIQUE;

#define DEFAULT_ENABLE_COLLMOD_UNIQUE false
bool EnableCollModUnique = DEFAULT_ENABLE_COLLMOD_UNIQUE;

#define DEFAULT_ENABLE_DROP_INDEXES_ON_READ_ONLY true
bool EnableDropInvalidIndexesOnReadOnly = DEFAULT_ENABLE_DROP_INDEXES_ON_READ_ONLY;

/*
 * SECTION: Schedule jobs via background worker.
 */

/* Remove after v111*/
#define DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER false
bool IndexBuildsScheduledOnBgWorker = DEFAULT_INDEX_BUILDS_SCHEDULED_ON_BGWORKER;

/* Remove it after 112 */
#define DEFAULT_INLINE_CHANGESTREAM_MATCH_STAGES true
bool InlineChangeStreamMatchStage = DEFAULT_INLINE_CHANGESTREAM_MATCH_STAGES;

#define DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS true
bool RemoveMatchNamespaceFilters = DEFAULT_REMOVE_MATCH_NAMESPACE_FILTERS;

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
		psprintf("%s.enableNewSelectivityMode", newGucPrefix),
		gettext_noop(
			"Determines whether to use the new selectivity logic."),
		NULL, &EnableNewOperatorSelectivityMode,
		DEFAULT_ENABLE_NEW_OPERATOR_SELECTIVITY,
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
		psprintf("%s.enableCollationWithIndexes", newGucPrefix),
		gettext_noop(
			"Determines whether collation is supported for indexes."),
		NULL, &EnableCollationWithIndexes,
		DEFAULT_ENABLE_COLLATION_WITH_INDEXES,
		PGC_USERSET, 0, NULL, NULL, NULL);


	DefineCustomBoolVariable(
		psprintf("%s.enableNowSystemVariable", newGucPrefix),
		gettext_noop(
			"Enables support for the $$NOW time system variable."),
		NULL, &EnableNowSystemVariable,
		DEFAULT_ENABLE_NOW_SYSTEM_VARIABLE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableLetAndCollationForQueryMatch", newGucPrefix),
		gettext_noop(
			"Whether or not to enable collation and let for query match."),
		NULL, &EnableLetAndCollationForQueryMatch,
		DEFAULT_ENABLE_LET_AND_COLLATION_FOR_QUERY_MATCH,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableVariablesSupportForWriteCommands", newGucPrefix),
		gettext_noop(
			"Whether or not to enable let variables and $$NOW support for write (update, delete, findAndModify) commands. Only support for delete is available now."),
		NULL, &EnableVariablesSupportForWriteCommands,
		DEFAULT_ENABLE_VARIABLES_SUPPORT_FOR_WRITE_COMMANDS,
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
		psprintf("%s.enableUsernamePasswordConstraints", newGucPrefix),
		gettext_noop(
			"Determines whether username and password constraints are enabled."),
		NULL, &EnableUsernamePasswordConstraints,
		DEFAULT_ENABLE_USERNAME_PASSWORD_CONSTRAINTS,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDataTableWithoutCreationTime", newGucPrefix),
		gettext_noop(
			"Create data table without creation_time column."),
		NULL, &EnableDataTableWithoutCreationTime,
		DEFAULT_ENABLE_DATA_TABLES_WITHOUT_CREATION_TIME,
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
		psprintf("%s.enableLookupInnerJoin", newGucPrefix),
		gettext_noop(
			"Whether or not to enable lookup inner join."),
		NULL, &EnableLookupInnerJoin,
		DEFAULT_LOOKUP_ENABLE_INNER_JOIN,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.forceBitmapScanForLookup", newGucPrefix),
		gettext_noop(
			"Whether or not to force bitmap scan for lookup."),
		NULL, &ForceBitmapScanForLookup,
		DEFAULT_FORCE_BITMAP_SCAN_FOR_LOOKUP,
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
		psprintf("%s.enableIndexOrderbyPushdown", newGucPrefix),
		gettext_noop(
			"Whether to enable the sort on the new experimental composite index opclass"),
		NULL, &EnableIndexOrderbyPushdown, DEFAULT_ENABLE_INDEX_ORDERBY_PUSHDOWN,
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
		psprintf("%s.usePgStatsLiveTuplesForCount", newGucPrefix),
		gettext_noop(
			"Whether to use pg_stat_all_tables live tuples for count in collStats."),
		NULL, &UsePgStatsLiveTuplesForCount,
		DEFAULT_USE_PG_STATS_LIVE_TUPLES_FOR_COUNT,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.rumFailOnLostPath", newGucPrefix),
		gettext_noop(
			"Whether or not to fail the query when a lost path is detected in RUM"),
		NULL, &RumFailOnLostPath,
		DEFAULT_RUM_FAIL_ON_LOST_PATH,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableDelayedHoldPortal", newGucPrefix),
		gettext_noop(
			"Whether to delay holding the portal until we know there is more data to be fetched."),
		NULL, &EnableDelayedHoldPortal, DEFAULT_ENABLE_DELAYED_HOLD_PORTAL,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.forceCollStatsDataCollection", newGucPrefix),
		gettext_noop(
			"Whether to force fetching metadata during collstats operations."),
		NULL, &ForceCollStatsDataCollection, DEFAULT_FORCE_COLL_STATS_DATA_COLLECTION,
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
		psprintf("%s.enableExtendedExplainOnAnalyzeOff", newGucPrefix),
		gettext_noop(
			"Whether to enable logging extended explain on explain with analyze off."),
		NULL, &EnableExtendedExplainOnAnalyzeOff,
		DEFAULT_ENABLE_EXTENDED_EXPLAIN_ON_ANALYZEOFF,
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
		psprintf("%s.enableUseLookupNewProjectInlineMethod", newGucPrefix),
		gettext_noop(
			"Whether to use new inline method for $project in $lookup."),
		NULL, &EnableUseLookupNewProjectInlineMethod,
		DEFAULT_USE_LOOKUP_NEW_PROJECT_INLINE_METHOD,
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
}
