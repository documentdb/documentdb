-- documentdb GUC snake_case naming convention enforcement.
--
-- All GUCs registered under the 'documentdb.' prefix must be snake_case, i.e. match
-- '^documentdb\.[a-z0-9_]+$' (lowercase letters, digits and underscores; no uppercase,
-- camelCase or nested dots).
--
-- The baseline table below grandfathers GUCs that predate this convention. It is expected
-- to only shrink over time (never grow):
--   * A NEW non-conforming GUC makes 'all_snake_case' false and lists the name(s) in
--     'violations' -- rename the GUC to snake_case.
--   * A baseline entry whose GUC no longer exists makes 'baseline_is_current' false and
--     lists the name(s) in 'stale_baseline_entries' -- remove it from the baseline below.
--
-- When clean, the output is stable ('t' with empty text columns), so the expected file
-- does not need routine updates and merge conflicts are minimized.
CREATE TEMP TABLE documentdb_guc_naming_baseline (name text);
INSERT INTO documentdb_guc_naming_baseline (name) VALUES
    ('documentdb.arrayStatisticsMaxSampleCount'),
    ('documentdb.backgroundWorkerJobTimeoutThresholdSec'),
    ('documentdb.batchUpdateLockTimeoutMs'),
    ('documentdb.batchWriteSubTransactionCount'),
    ('documentdb.blockedRolePrefixList'),
    ('documentdb.cleanupCursorFiles'),
    ('documentdb.createTTLIndexAsCompositeByDefault'),
    ('documentdb.currentOpAddSqlCommand'),
    ('documentdb.defaultCursorExpiryTimeLimitSeconds'),
    ('documentdb.defaultCursorFirstPageBatchSize'),
    ('documentdb.defaultTailableCursorMaxAwaitTimeMs'),
    ('documentdb.defaultUniqueIndexKeyhashOverride'),
    ('documentdb.defaultUseCompositeOpClass'),
    ('documentdb.disableExtendedRumExplainPlans'),
    ('documentdb.emitEnableOrderedIndexFalseInResponse'),
    ('documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters'),
    ('documentdb.enableAddToSetAggregationRewrite'),
    ('documentdb.enableArrayFilterLogicalOperators'),
    ('documentdb.enableBackgroundWorker'),
    ('documentdb.enableBackgroundWorkerInitJobs'),
    ('documentdb.enableBackgroundWorkerJobs'),
    ('documentdb.enableBypassDocumentValidation'),
    ('documentdb.enableCollationWithNewGroupAccumulators'),
    ('documentdb.enableCollationWithNonUniqueOrderedIndexes'),
    ('documentdb.enableCollModUnique'),
    ('documentdb.enableCommutativeDeleteMany'),
    ('documentdb.enableCommutativeUpdateMany'),
    ('documentdb.enableCompactVacuumFull'),
    ('documentdb.enableComparableTerms'),
    ('documentdb.enableCompositeIndexPlanner'),
    ('documentdb.enableCompositeParallelIndexScan'),
    ('documentdb.enableCompositeReducedCorrelatedPrefixTrim'),
    ('documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath'),
    ('documentdb.enableCompositeShardDocumentTerms'),
    ('documentdb.enableCompositeUniqueHash'),
    ('documentdb.enableContinuationFastBitmapLookup'),
    ('documentdb.enableCursorsOnAggregationQueryRewrite'),
    ('documentdb.enableDataTableWithoutCreationTime'),
    ('documentdb.enableDeadIndexEntryMarkingByTTLTask'),
    ('documentdb.enableDebugQueryText'),
    ('documentdb.enableDelayedHoldPortal'),
    ('documentdb.enableDeleteOnePlanCacheOptimization'),
    ('documentdb.enableDistinctCustomScan'),
    ('documentdb.enableDistinctIndexPushdown'),
    ('documentdb.enableDistinctScanForGroupFirst'),
    ('documentdb.enableDollarSampleHeapSkipReservoirScan'),
    ('documentdb.enableDollarSampleReservoirScan'),
    ('documentdb.enableDottedValueTextIndexTerms'),
    ('documentdb.enableDuplicateFieldFix'),
    ('documentdb.enableDynamicCursorFastStartupScan'),
    ('documentdb.enableDynamicCursors'),
    ('documentdb.enableDynamicPersistentCursorsWithStats'),
    ('documentdb.enableExplainScanIndexCosts'),
    ('documentdb.enableExplainScanNamespaceName'),
    ('documentdb.enableExtendedExplainPlans'),
    ('documentdb.enableExtendedIndexes'),
    ('documentdb.enableFailureOnParallelIndexArrays'),
    ('documentdb.enableGenerateNonExistsTerm'),
    ('documentdb.enableGroupByCompoundIdIndexPushdown'),
    ('documentdb.enableGroupByDistinctScan'),
    ('documentdb.enableIndexMetadataGlobalTracking'),
    ('documentdb.enableIndexOnlyScanForCoveredAggregateTargets'),
    ('documentdb.enableIndexOnlyScanForFindProject'),
    ('documentdb.enableIndexOnlyScanForRangeMatch'),
    ('documentdb.enableIndexPathKeySummarization'),
    ('documentdb.enableInsertDuplicateInlineHandling'),
    ('documentdb.enableLocalRetryTable'),
    ('documentdb.enableLookupIdJoinOptimizationOnCollation'),
    ('documentdb.enableMultiIndexRumJoin'),
    ('documentdb.enableNativeColocation'),
    ('documentdb.enableNewMinMaxAccumulators'),
    ('documentdb.enableNewNamespaceValidation'),
    ('documentdb.enableNewWithExprAccumulators'),
    ('documentdb.enableNonBlockingUniqueIndexBuild'),
    ('documentdb.enableObjectIdFuncExprConversion'),
    ('documentdb.enableOnlyCollectionCacheInvalidateOnCollectionChanges'),
    ('documentdb.EnableOperatorVariablesInLookup'),
    ('documentdb.enableOrderByIdOnCostFunction'),
    ('documentdb.enableOrderByIndexTerm'),
    ('documentdb.enableOrderedCompositeOperatorScan'),
    ('documentdb.enablePartialMatchHasRecheck'),
    ('documentdb.enablePerCollectionPlannerStatistics'),
    ('documentdb.enablePerPathMultiKeySortPushdown'),
    ('documentdb.enablePGPrngCursorId'),
    ('documentdb.enablePlannerStatisticsNewCollections'),
    ('documentdb.enablePreImages'),
    ('documentdb.enablePrepareUnique'),
    ('documentdb.enablePrimaryKeyCursorScan'),
    ('documentdb.enableProjectPushUpBeforeUnwindWithGroup'),
    ('documentdb.enableRbacCompliantSchemas'),
    ('documentdb.enableRegexPrefixIndexBounds'),
    ('documentdb.enableRoleCrud'),
    ('documentdb.enableRolesAdminDBCheck'),
    ('documentdb.enableRumCursorDynamicIndexScans'),
    ('documentdb.enableRumDynamicIndexScansSkipToTid'),
    ('documentdb.enableSampleScanFixOnSharded'),
    ('documentdb.enableSchemaEnforcementForCSFLE'),
    ('documentdb.enableSchemaValidation'),
    ('documentdb.enableSkipCommentFieldOnUpsert'),
    ('documentdb.enableSkipDottedFieldIndexTerms'),
    ('documentdb.enableSortGroupStage'),
    ('documentdb.enableSortPushToAccumulatorWithPrefix'),
    ('documentdb.enableStatementTimeout'),
    ('documentdb.enableStrictAddToSetModifierValidation'),
    ('documentdb.enableSubqueryPushdownForMatch'),
    ('documentdb.enableTailableCursorMaxAwaitTime'),
    ('documentdb.enableTTLBatchObservability'),
    ('documentdb.enableTTLDescSort'),
    ('documentdb.enableTTLJobsOnReadOnly'),
    ('documentdb.enableUniqueReindex'),
    ('documentdb.enableUserCrud'),
    ('documentdb.enableUsernamePasswordConstraints'),
    ('documentdb.enableUsersAdminDBCheck'),
    ('documentdb.enableUsersInfoPrivileges'),
    ('documentdb.enableValueOnlyIndexTerms'),
    ('documentdb.enableVectorCalculateDefaultSearchParam'),
    ('documentdb.enableVectorCompressionHalf'),
    ('documentdb.enableVectorCompressionPQ'),
    ('documentdb.enableVectorHNSWIndex'),
    ('documentdb.enableVectorPreFilter'),
    ('documentdb.enableVectorPreFilterV2'),
    ('documentdb.failOnGroupIdDuplicate'),
    ('documentdb.failOnNonEmptyGroupCountArg'),
    ('documentdb.forceBitmapScanForLookup'),
    ('documentdb.forceCollStatsDataCollection'),
    ('documentdb.forceDisableSeqScan'),
    ('documentdb.forceGroupSubqueryElimination'),
    ('documentdb.forceIndexOnlyScanIfAvailable'),
    ('documentdb.forceIndexTermTruncation'),
    ('documentdb.forceLocalExecutionShardQueries'),
    ('documentdb.forceParallelScanIfAvailable'),
    ('documentdb.forceRunDiagnosticCommandInline'),
    ('documentdb.forceUpdateIndexInline'),
    ('documentdb.forceUseIndexIfAvailable'),
    ('documentdb.forceWildcardReducedTerm'),
    ('documentdb.geo2dsphereSegmentMaxLength'),
    ('documentdb.geo2dsphereSegmentMaxVertices'),
    ('documentdb.indexBuildScheduleInSec'),
    ('documentdb.indexBuildsScheduledOnBgWorker'),
    ('documentdb.isNativeAuthEnabled'),
    ('documentdb.IsPgReadOnlyForDiskFull'),
    ('documentdb.logRelationIndexesOrder'),
    ('documentdb.logTTLProgressActivity'),
    ('documentdb.maxCursorFileCount'),
    ('documentdb.maxCursorIntermediateFileSizeMB'),
    ('documentdb.maxCustomCommandTimeoutLimit'),
    ('documentdb.maxIndexBuildAttempts'),
    ('documentdb.maxIndexesPerCollection'),
    ('documentdb.maxNumActiveUsersIndexBuilds'),
    ('documentdb.maxSchemaValidatorSize'),
    ('documentdb.maxTTLBatchSizeUnorderedIndex'),
    ('documentdb.maxTTLDeleteBatchSize'),
    ('documentdb.maxUserLimit'),
    ('documentdb.maxWildcardIndexKeySize'),
    ('documentdb.maxWriteBatchSize'),
    ('documentdb.multipleDollarPositionalNotAllowed'),
    ('documentdb.removeMatchNamespaceFilters'),
    ('documentdb.repeatPurgeIndexesForTTLTask'),
    ('documentdb.rumFailOnLostPath'),
    ('documentdb.scramDefaultSaltLen'),
    ('documentdb.simulateRecoveryState'),
    ('documentdb.SingleTTLTaskTimeBudget'),
    ('documentdb.skipFailOnCollation'),
    ('documentdb.skipIndexCleanupOnFailure'),
    ('documentdb.skipIndexCleanupOnReindex'),
    ('documentdb.skipRepeatDeleteForUnOrderedIndex'),
    ('documentdb.tdigestCompressionAccuracy'),
    ('documentdb.throwDeadlockOnCRUD'),
    ('documentdb.TTLPurgerLockTimeout'),
    ('documentdb.TTLPurgerStatementTimeout'),
    ('documentdb.TTLSkipCaughtUpIndexes'),
    ('documentdb.TTLTaskMaxRunTimeInMS'),
    ('documentdb.useFileBasedPersistedCursors'),
    ('documentdb.useIndexHintsForTTLTask'),
    ('documentdb.useLocalExecutionShardQueries'),
    ('documentdb.useNewUniqueHashEqualityFunction'),
    ('documentdb.vectorPreFilterIterativeScanMode');

-- Non-conforming GUCs that are not grandfathered by the baseline.
SELECT
    NOT EXISTS (
        SELECT 1
        FROM pg_settings s
        LEFT JOIN documentdb_guc_naming_baseline b ON b.name = s.name
        WHERE s.name ~ '^documentdb\.'
          AND s.name !~ '^documentdb\.[a-z0-9_]+$'
          AND b.name IS NULL
    ) AS all_snake_case,
    (
        SELECT 'GUCs should follow snake casing and not contain nested dots. The following GUCs do not: ' || string_agg(s.name, ', ' ORDER BY s.name)
        FROM pg_settings s
        LEFT JOIN documentdb_guc_naming_baseline b ON b.name = s.name
        WHERE s.name ~ '^documentdb\.'
          AND s.name !~ '^documentdb\.[a-z0-9_]+$'
          AND b.name IS NULL
    ) AS violations;

-- Baseline entries whose GUC no longer exists; these must be pruned from the baseline.
SELECT
    NOT EXISTS (
        SELECT 1
        FROM documentdb_guc_naming_baseline b
        LEFT JOIN pg_settings s ON s.name = b.name
        WHERE s.name IS NULL
    ) AS baseline_is_current,
    (
        SELECT 'Baseline entries no longer exist as GUCs and must be removed from this test: ' || string_agg(b.name, ', ' ORDER BY b.name)
        FROM documentdb_guc_naming_baseline b
        LEFT JOIN pg_settings s ON s.name = b.name
        WHERE s.name IS NULL
    ) AS stale_baseline_entries;

DROP TABLE documentdb_guc_naming_baseline;
