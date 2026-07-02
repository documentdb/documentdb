### documentdb v0.115-0 (Unreleased) ###
* Optimize `$sample` over an Index Scan by avoiding heap reads for rows the reservoir discards (visible rows are counted via the visibility map). Applies to Index Scans without runtime filters over btree or regular RUM indexes. *[Perf]*
* Fix `$exists` argument coercion so falsy non-boolean values (`null`, `undefined`, `0`) are treated as `$exists: false` and truthy non-boolean values as `$exists: true`, matching the documented truthiness semantics. Previously `$exists: null` behaved like `$exists: true`. *[Bugfix]*
* Fix `$size` returning wrong results when applied to a field path nested inside `$elemMatch`. *[Bugfix]*
* Fix backend crash (heap-buffer-overflow) in `$setUnion`/`$setIntersection` element deduplication when hashing `CodeWScope` values (wrong union member read), and fix `Regex` values failing to deduplicate plus a latent over-read for long patterns, in `BsonValueHashUint32`. *[Bugfix]*
* Inject a field-pruning `$project` before `$unwind` when the downstream is `$group` (with only `$match` stages in between), keeping only the top-level fields consumed downstream so the unwound rows are smaller. Guarded by `enableProjectPushUpBeforeUnwindWithGroup` feature flag, disabled by default while pending stabilization. *[Perf]*
* Fix crash in `$fill` with `partitionByFields` when the pipeline includes a stage that migrates the window query into a subquery (e.g. a preceding `$sort` or a `$limit`). The partition expression is now built after the migration so it references the correct range-table level. *[Bugfix]*
* Fix backend crash (use-after-free) when a `$let` declaring more than one variable has an `in` that produces a document or array and is evaluated more than once (across multiple documents, or nested inside `$map`/`$filter`/`$reduce` iterating over multiple elements). The shared variable table is no longer destroyed on the writer finalization path when it is flagged to be preserved. *[Bugfix]*
* Add feature-flagged single-pass RUM posting-tree vacuum that prunes emptied leaf pages inline during the bulk-delete TID cleanup walk instead of a separate pruning pass. Guarded by `enable_single_pass_posting_tree_vacuum`, disabled by default while pending stabilization. *[Perf]*
* Fix backend crash when serializing a SQL array that contains a NULL element. *[Bugfix]*

### documentdb v0.114-0 (Unreleased) ###
* Extend `enableNewNamespaceValidation` to block create/drop/rename/createIndex on reserved collections in `admin` and `local` databases, and complete the `config` reserved-collection list (added sharding-runtime names: `changelog`, `mongos`, `placementHistory`, `tags`, `transactions`, `locks`, `lockpings`, `migrations`, `migrationCoordinators`, `rangeDeletions`, `reshardingOperations`, `cache.collections`, `cache.databases`). *[Feature]*
* Emit a btree `REUSE_PAGE` WAL marker before a RUM page is reused from the FSM, so streaming standbys resolve recovery conflicts before the page contents are overwritten. Mirrors nbtree's `_bt_allocbuf` behavior. Guarded by `documentdb_rum.enable_emit_reuse_page_on_recycle` feature flag, disabled by default while pending stabilization. *[Perf]*
* Support configuring the gateway via `DOCUMENTDB_*` environment variables for systemd-managed installs, and add a `documentdb-gateway check` connectivity-probe subcommand. *[Feature]*
* Support non-blocking background unique index build for ordered indexes via `CREATE INDEX CONCURRENTLY` with post-processing to register exclusion constraints and validate existing rows. Guarded by `documentdb.enableNonBlockingUniqueIndexBuild` flag, enabled by default. *[Feature]*
* Add feature-flagged targeted RUM posting-tree pruning to shorten root cleanup-lock hold time during vacuum. Guarded by `enable_targeted_posting_tree_pruning`, disabled by default while pending stabilization. *[Perf]*
* Fix crash when `$natural` sort on non-base relations that are already sorted by pipeline. *[Bugfix]* (#532)
* Fix schema validation propagation and ensure correct caching of the parsed validator across calls. *[Bugfix]*
* Fix `$sample` TABLESAMPLE optimization not being applied on sharded collections when preceded by an empty filter. Guarded by `enableSampleScanFixOnSharded` feature flag *[Bugfix]*
* Schema Validation: enabled by default.
* Reservoir sampling CustomScan for `$sample` after filter stages, replacing `ORDER BY random() LIMIT K` with O(N) single pass sampling. Guarded by `enableDollarSampleReservoirScan` feature flag *[Perf]*

### documentdb v0.113-0 (June 22, 2026) ###
* Add `EnableSortPushToAccumulator` GUC to control pushing sort order into accumulator in `$sortGroup` stage *[Perf]*
* Support collation with non-unique ordered indexes with $elemMatch. Requires `EnableCollationWithNonUniqueOrderedIndexes` flag to be `on`.  *[Feature]*
* Use in-place tuple overwrite instead of delete-and-reinsert when vacuuming RUM entry page posting lists *[Perf]*
* Push suffix sort keys into accumulator in `$sortGroup` when group-by keys form a non-dotted prefix of the sort keys. Guarded by `enableSortPushToAccumulatorWithPrefix` feature flag, disabled by default while pending stabilization. *[Perf]*
* Support collation with non-unique ordered indexes with `$in` and `$nin` but not with ordered scans. Requires `documentdb.EnableCollationWithNonUniqueOrderedIndexes` flag to be `on`.  *[Feature]*
* Support for pruning dead index entry on ordered TTL indexes. Requires `EnableDeadIndexEntryMarkingByTTLTask` to be on. *[Perf]*
* Support `$elemMatch`, `$slice`, and `$` positional projection operators in `findAndModify` by routing through the find-specific projection path *[Feature]*
* Enable index-only scan for `$group` accumulators when all referenced fields are covered by the composite index *[Perf]*

### documentdb v0.112-0 (May 26, 2026) ###
* Removed feature flag `documentdb.enableUpdateBsonDocument` and dropped legacy composite-returning `bson_update_document` UDF — all callers now use the scalar `update_bson_document` UDF
* Eliminate subquery migration in $group for unsharded and sharded with constant _id aggregation queries. Guarded with `EnableGroupSubqueryElimination` *[Perf]*
* Support collation with non-unique ordered indexes with $lt, $lte. Requires `EnableCollationWithNonUniqueOrderedIndexes` flag to be `on`.  *[Feature]*
* Support index pushdown for `$group` stage when `_id` is a multi-field document expression *[Perf]*
* Support collation with non-unique ordered indexes with $ne. Requires `EnableCollationWithNonUniqueOrderedIndexes` flag to be `on`.  *[Feature]*
* Support collation with non-unique ordered indexes with `$not` combined with `$gt`, `$gte`, `$lt`, `$lte`. Requires `EnableCollationWithNonUniqueOrderedIndexes` flag to be `on`.  *[Feature]*
* Fix crash in `BsonOrderFinal` and `BsonOrderFinalOnSorted` when `BSONFIRSTN`/`BSONLASTN` aggregates run on empty sharded collections, caused by a NULL datum not being detected before detoasting. Also fix similar crash in `bson_maxminn_combine` for `BSONMAXN`/`BSONMINN` *[Bugfix]* (#531)
* Migrate `DrainStreamingQuery` from SPI cursor-based execution to direct executor invocation via `DestReceiver`, eliminating Portal/SPI overhead for streaming queries *[Perf]*

### documentdb v0.111-0 (May 11, 2026) ###
* Support index pushdown for `$group` stage when `_id` is a single-field document expression (e.g., `{ _id: { "field": "$path" } }`) *[Perf]*
* Add init background job infrastructure for running one time C callback initialization tasks before the periodic job loop. Guarded by `enableBackgroundWorkerInitJobs` feature flag *[Feature]*
* Add feature flag `enableCollationWithIndexes` to `enableCollationWithNonUniqueOrderedIndexes` to gate collation support specifically for non-unique ordered/composite indexes. Collation is rejected for other index types/options *[Feature]*
* Fix `$count:{}` accumulator in `$group` to reject invalid arguments. Guarded by `failOnNonEmptyGroupCountArg` feature flag *[Bugfix]*
* Reject duplicate `_id` in `$group` stage. Guarded by `failOnGroupIdDuplicate` feature flag *[Bugfix]*
* Update file modification time in `DeserializeFileState` to prevent TTL-based cleanup from expiring actively-used cursor files *[Bugfix]*
* Improved performance for `$first` and `$last` accumulators in `$group` pipeline stage (no preceding `$sort`) under flag `enableNewWithExprAccumulators`. *[Perf]* (#457)
* Support `$db` field in wire protocol command specs for insert, update, delete, findAndModify, createIndexes, dropIndexes, collMod, and background index commands *[Feature]*
* Removed feature flag `documentdb.enableNowSystemVariable` — `$$NOW` time system variable support is now always enabled
* Fixes crash that occurs when `enableDebugQueryText` is enabled and certain commands (e.g., `count_query`, `find_cursor_first_page`) operate on queries whose query trees are mutated by the PostgreSQL planner. *[Bugfix]* (#484)
* Map PostgreSQL `Gather Merge` plan node to `PARALLEL_SORT_MERGE` in explain output *[Bugfix]*
* Fix crash in `BsonTextGenerateTSQueryCore` when `$text` search contains only stop words or empty string, causing `QT2QTN` to read past the end of an empty TSQuery *[Bugfix]*
* Support collation with $min and $max aggregation $group accumulators. Guarded by `EnableNewWithExprAccumulators` and `EnableCollation`
* Optimize OP_INSERT and refactor opcode parsers
* Enable index only scan by default and move to the cost estimate function *[Feature]*
* Optimize index boundaries for $regex when there is an anchored prefix *[Perf]*
* Push $in filters on object_id to the primary key index, during evaluation of a streaming cursor query *[Bugfix]*
* Improved performance for `$sum` and `$avg` accumulators in `$group` and `$setWindowFields` pipeline stages under flag `enableNewWithExprAccumulators`, with moving window support via inverse transition. (#457)
* Fix segfault due to use after free in bson_dollar_project_find *[Bugfix]*
* Remove unnecessary explicit frees of items allocated on tuple-context *[Perf]*
* Add support for ordering by index term order (matching the ordering spec more closely) for both index and runtime. This also makes index and runtime orders match *[Bugfix]*
* Support collation with non-unique ordered indexes with $eq, $gt, $gte. Requires `EnableCollationWithNonUniqueOrderedIndexes` flag to be `on`.  *[Feature]*
* Enable collated index pushdown for collation-insensitive operators; avoid pushdown for unsupported operator strategies. *[Feature]*

### documentdb v0.110-0 (April 22, 2026) ###
* Add support for keyword `description` in `$jsonSchema` *[Feature]*
* Integrate cargo tools to identify dependencies for pg_documentdb_gw *[Feature]* (#263)
* Add support for killSessions command *[Feature]* (#402)
* Support arbitrary database user and password *[Feature]* (#306)
* Improved performance for `$max` and `$min` accumulators in `$group` and `$setWindowFields` pipeline stages under flag `enableNewMinMaxAccumulators`. (#457)
* Fix crash in `bson_dollar_lookup_project` when matched documents array contains NULL elements from LEFT JOIN *[Bugfix]* (#465)
* Fix crash in `$densify` with `partitionByFields` on shard key due to mismatched sort operators for INT8 partition expression *[Bugfix]* (#464)
* Fix crash in `shard_collection` when implicit collection creation fails and returns NULL *[Bugfix]* (#462)
* Fix crash in `$let` when `in` expression is a constant *[Bugfix]* (#463)
* Support for TTL cron job to repeat deletes in batches until the one minute budget is exhausted, instead of deleting one batch per index per minute.*[Perf]*
* Crash fix when zero rows reach $first/$last/$firstN/$lastN accumulators in $group stage with no $sort *[Bugfix]*. (#466)

### documentdb v0.109-0 (March 09, 2026) ###
* Support collation with find positional queries *[Feature]*
* Short-circuit in `$cond` runtime evaluation *[Perf]*
* Support operator variables(eg: $map.as alias) in let variable spec *[Bugfix]*
* Support for `killOp` administrative command *[Feature]*
* Fix `$addToSet` behavior and skip the top-level field rewrite because it's already done in the operator *[Bugfix]*
* Performance improvements for $addToSet update operator up to ~70x for large existing and update arrays. *[Perf]*
* Removed feature flags `documentdb.enableCompact`, `documentdb.enableBucketAutoStage` and `documentdb.enableIndexHintSupport`
* Fix use-after-free segmentation fault in `$let` *[Bugfix]* 
* Optimize `$makeArray` on constant expressions.*[Perf]*
* Short-circuit in `$switch` at parse time *[Perf]*
* Enable ordered indexes by default. Can be turned off by specifying "storageEngine": {"enableOrderedIndex": false} for a single index or by turning off the `documentdb.defaultUseCompositeOpClass` GUC.
* Fix NULL document crash from `$in: []` optimization on sharded collections.

### documentdb v0.108-0 (January 08, 2026) ###
* Top-level `let` variables and `$$NOW` supported by default.
* Fix collation support on find and aggregation when variableSpec is not available *[Bugfix]*.
* Support `dropRole` command *[Feature]*
* Support `rolesInfo` command *[Feature]*
* Fix concurrent upsert behavior, update the documents in case of conflicts during insert *[Bugfix]* (#295).
* Support collation with `$sortArray` aggregation operator *[Feature]*
* Add support for keyword `required` in `$jsonSchema` *[Feature]*
* Fix a segmentation fault when using ordered aggregate such as `$last` with `$setWindowFields` aggregation stage. *[Bugfix]*
* Fix crash when building lookup pipeline queries from nested pipelines and $group aggregates *[Bugfix]*
* Add basic support for compiling with pg18 *[Feature]*
* Drop unused environment variable `ENFORCE_SSL` in dockerfile *[Bugfix]* (#313)
* Remove the explicit dependency on the RUM extension (it's now implicit on the .so file). Flip to documentdb_extended_rum for PG18+ *[Feature]*
* Use the appropriate GUC for the user_crud_commands.sql *[Bugfix]* (#319)
* Provide Rust dev environment in devcontainer *[Feature]*
* Add extension that adds a gateway host that's run as a postgres background worker *[Feature]*

### documentdb v0.107-0 (October 22, 2025) ###
* Support sort by _id against the _id index using the enableIndexOrderbyPushdown flag *[Feature]*.
* Improvements to explain for various scan types *[Feature]*.
* Support schema enforcement with CSFLE integration *[Preview]*
* Validate $jsonSchema syntax during rule creation or modification(schema validation) *[Preview]*

### documentdb v0.106-0 (August 29, 2025) ###
* Add internal extension that provides extensions to the `rum` index. *[Feature]*
* Enable let support for update queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
* Enable let support for findAndModify queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
* Add internal extension that provides extensions to the `rum` index. *[Feature]*
* Optimized query for `usersInfo` command.
* Support collation with `delete` *[Feature]*. Requires `EnableCollation` to be `on`.
* Support for index hints for find/aggregate/count/distinct *[Feature]*
* Support `createRole` command *[Feature]*
* Add schema changes for Role CRUD APIs *[Feature]*
* Add support for using EntraId tokens via Plain Auth

### documentdb v0.105-0 (July 28, 2025) ###
* Support `$bucketAuto` aggregation stage, with granularity types: `POWERSOF2`, `1-2-5`, `R5`, `R10`, `R20`, `R40`, `R80`, `E6`, `E12`, `E24`, `E48`, `E96`, `E192` *[Feature]*
* Support `conectionStatus` command *[Feature]*.

### documentdb v0.104-0 (June 09, 2025) ###
* Add string case support for `$toDate` operator
* Support `sort` with collation in runtime*[Feature]*
* Support collation with `$indexOfArray` aggregation operator. *[Feature]*
* Support collation with arrays and objects comparisons *[Feature]*
* Support background index builds *[Bugfix]* (#36)
* Enable user CRUD by default *[Feature]*
* Enable let support for delete queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
* Enable rum_enable_index_scan as default on *[Perf]*
* Add public `documentdb-local` Docker image with gateway to GHCR
* Support `compact` command *[Feature]*. Requires `documentdb.enablecompact` GUC to be `on`.
* Enable role privileges for `usersInfo` command *[Feature]* 

### documentdb v0.103-0 (May 09, 2025) ###
* Support collation with aggregation and find on sharded collections *[Feature]*
* Support `$convert` on `binData` to `binData`, `string` to `binData` and `binData` to `string` (except with `format: auto`) *[Feature]*
* Fix list_databases for databases with size > 2 GB *[Bugfix]* (#119)
* Support half-precision vector indexing, vectors can have up to 4,000 dimensions *[Feature]*
* Support ARM64 architecture when building docker container *[Preview]*
* Support collation with `$documents` and `$replaceWith` stage of the aggregation pipeline *[Feature]*
* Push pg_documentdb_gw for documentdb connections *[Feature]*

### documentdb v0.102-0 (March 26, 2025) ###
* Support index pushdown for vector search queries *[Bugfix]*
* Support exact search for vector search queries *[Feature]*
* Inline $match with let in $lookup pipelines as JOIN Filter *[Perf]*
* Support TTL indexes *[Bugfix]* (#34)
* Support joining between postgres and documentdb tables *[Feature]* (#61)
* Support current_op command *[Feature]* (#59)
* Support for list_databases command *[Feature]* (#45)
* Disable analyze statistics for unique index uuid columns which improves resource usage *[Perf]*
* Support collation with `$expr`, `$in`, `$cmp`, `$eq`, `$ne`, `$lt`, `$lte`, `$gt`, `$gte` comparison operators (Opt-in) *[Feature]*
* Support collation in `find`, aggregation `$project`, `$redact`, `$set`, `$addFields`, `$replaceRoot` stages (Opt-in) *[Feature]*
* Support collation with `$setEquals`, `$setUnion`, `$setIntersection`, `$setDifference`, `$setIsSubset` in the aggregation pipeline (Opt-in) *[Feature]*
* Support unique index truncation by default with new operator class *[Feature]*
* Top level aggregate command `let` variables support for `$geoNear` stage *[Feature]*
* Enable Backend Command support for Statement Timeout *[Feature]*
* Support type aggregation operator `$toUUID`. *[Feature]*
* Support Partial filter pushdown for `$in` predicates *[Perf]*
* Support the $dateFromString operator with full functionality *[Feature]*
* Support extended syntax for `$getField` aggregation operator. Now the value of 'field' could be an expression that resolves to a string. *[Feature]*

### documentdb v0.101-0 (February 12, 2025) ###
* Push $graphlookup recursive CTE JOIN filters to index *[Perf]*
* Build pg_documentdb for PostgreSQL 17 *[Infra]* (#13)
* Enable support of currentOp aggregation stage, along with collstats, dbstats, and indexStats *[Commands]* (#52)
* Allow inlining $unwind with $lookup with `preserveNullAndEmptyArrays` *[Perf]*
* Skip loading documents if group expression is constant *[Perf]*
* Fix Merge stage not outputing to target collection *[Bugfix]* (#20)

### documentdb v0.100-0 (January 23rd, 2025) ###
Initial Release
