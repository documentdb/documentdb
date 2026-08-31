/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/compact.c
 *
 * Implementation of the blocking compact command.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <commands/vacuum.h>
#include <nodes/parsenodes.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <storage/lmgr.h>
#include <utils/syscache.h>

#include "api_hooks.h"
#include "commands/commands_common.h"
#include "commands/parse_error.h"
#include "metadata/metadata_cache.h"
#include "utils/documentdb_errors.h"
#include "utils/error_utils.h"
#include "utils/feature_counter.h"
#include "utils/query_utils.h"
#include "utils/storage_utils.h"
#include "utils/version_utils.h"

extern bool EnableCompactVacuumFull;

/*
 * Controls which flavor of VACUUM the compact command performs.
 */
typedef enum CompactMode
{
	/* No mode option has been selected yet. */
	COMPACT_MODE_UNSPECIFIED = 0,

	/*
	 * Plain VACUUM: marks dead tuple space as reusable within the table (via
	 * the free space map) without rewriting it, so later inserts/updates reuse
	 * that space regardless of where the dead tuples are. It generally does not
	 * return space to the OS -- the file only shrinks when wholly-empty pages at
	 * the tail of the heap can be truncated. It takes only a
	 * ShareUpdateExclusiveLock, so it does not block concurrent reads or writes.
	 * This is the default so that an omitted mode runs the non-blocking VACUUM
	 * rather than the blocking, table-rewriting VACUUM FULL.
	 */
	COMPACT_MODE_STANDARD,

	/* Update planner statistics without vacuuming the table. */
	COMPACT_MODE_UPDATE_STATS,

	/*
	 * VACUUM FULL: rewrites the table, returning freed space to the OS but
	 * taking an AccessExclusiveLock for the duration. Must be requested
	 * explicitly via mode: "full".
	 */
	COMPACT_MODE_FULL,
} CompactMode;

typedef struct CompactArgs
{
	/* The name of the database */
	char *databaseName;

	/* The name of the collection */
	char *collectionName;

	/* The requested compact behavior. Defaults to COMPACT_MODE_STANDARD. */
	CompactMode mode;

	/* Estimate reclaimed space without performing table maintenance. */
	bool dryRun;

	/*
	 * Only run the compact operation if the amount of space freed is greater
	 * than this value (in MB). The default is no value which means always run compact
	 */
	double freeSpaceTargetMB;

	/*
	 * This is not used today, with this false compact should be run on secondary nodes.
	 * TODO: support force: false once we have writable secondaries. Today only force: true
	 * is supported with blocking primary
	 */
	bool force;
} CompactArgs;

static void ParseCompactCommandSpec(pgbson *compactSpec, CompactArgs *args);
static void SelectCompactMode(CompactArgs *args, CompactMode mode);
static void PerformCompactOperation(uint64 collectionId, CompactMode mode);
static void ValidateCompactAccess(MongoCollection *collection, CompactMode mode);
static void ValidateLocksAndCheckAccess(MongoCollection *collection, CompactMode mode);
static uint64 RunVacuumAndMeasureFreedSpace(uint64 collectionId,
											const CompactArgs *args);
static uint64 RunVacuumAndEstimateFreedSpace(uint64 collectionId,
											 const CompactArgs *args);


PG_FUNCTION_INFO_V1(command_compact);

/*
 * command_compact implements the functionality of compact Database command
 * dbcommand/compact.
 */
Datum
command_compact(PG_FUNCTION_ARGS)
{
	pgbson *compactSpec = PG_GETARG_PGBSON(0);
	if (!IsMetadataCoordinator())
	{
		StringInfo compactQueryCoordinator = makeStringInfo();
		appendStringInfo(compactQueryCoordinator,
						 "SELECT %s.compact(%s::%s.bson)",
						 ApiSchemaNameV2,
						 quote_literal_cstr(
							 PgbsonToHexadecimalString(PG_GETARG_PGBSON(0))),
						 CoreSchemaNameV2);
		DistributedRunCommandResult result = RunCommandOnMetadataCoordinator(
			compactQueryCoordinator->data);
		if (!result.success)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Internal error while running compact in metadata coordinator %s",
								text_to_cstring(result.response)),
							errdetail_log(
								"Internal error while running compact in metadata coordinator %s",
								text_to_cstring(result.response))));
		}
		pgbson *response = PgbsonInitFromHexadecimalString(text_to_cstring(
															   result.response));
		PG_RETURN_POINTER(response);
	}

	ReportFeatureUsage(FEATURE_COMMAND_COMPACT);

	CompactArgs args;
	memset(&args, 0, sizeof(CompactArgs));
	ParseCompactCommandSpec(compactSpec, &args);
	if (args.mode == COMPACT_MODE_UNSPECIFIED)
	{
		args.mode = COMPACT_MODE_STANDARD;
	}
	if (args.dryRun && args.mode == COMPACT_MODE_UPDATE_STATS)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"compact option dryRun:true cannot be combined with mode 'updateStats'")));
	}

	if (args.databaseName == NULL || args.collectionName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Invalid command compact specification, missing database or collection name")));
	}

	/*
	 * VACUUM FULL is a blocking operation and it takes AccessExclusiveLock on the table.
	 * Also we can only execute it on the top level (not within a function and procedure tranasction), so we can't
	 * take any lock on the collection here to avoid deadlock situation.
	 */
	MongoCollection *collection = GetMongoCollectionByNameDatum(CStringGetTextDatum(
																	args.databaseName),
																CStringGetTextDatum(
																	args.collectionName),
																NoLock);

	if (collection == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_NAMESPACENOTFOUND),
						errmsg("ns does not exist: %s.%s", args.databaseName,
							   args.collectionName)));
	}

	/* Always validate the user has permission to run compact on this collection */
	ValidateCompactAccess(collection, args.mode);

	/*
	 * dryRun is always supported regardless of the GUC since it only
	 * reads bloat stats without performing vacuum or taking locks.
	 */
	if (args.dryRun)
	{
		CollectionBloatStats bloatStats;
		memset(&bloatStats, 0, sizeof(CollectionBloatStats));
		bloatStats = GetCollectionBloatEstimate(collection->collectionId);

		pgbson_writer response;
		PgbsonWriterInit(&response);
		PgbsonWriterAppendDouble(&response, "ok", 2, 1);
		PgbsonWriterAppendInt64(&response, "estimatedBytesFreed", 19,
								bloatStats.estimatedBloatStorage);
		PG_RETURN_POINTER(PgbsonWriterGetPgbson(&response));
	}

	/*
	 * Only VACUUM FULL is gated by the GUC, since it is blocking and rewrites
	 * the table. The non-blocking standard VACUUM mode is always allowed.
	 */
	if (args.mode == COMPACT_MODE_FULL && !EnableCompactVacuumFull)
	{
		pgbson_writer response;
		PgbsonWriterInit(&response);
		PgbsonWriterAppendDouble(&response, "ok", 2, 1);
		PgbsonWriterAppendInt64(&response, "bytesFreed", 10, 0);

		PG_RETURN_POINTER(PgbsonWriterGetPgbson(&response));
	}

	ValidateLocksAndCheckAccess(collection, args.mode);

	/* Start building the response */
	pgbson_writer response;
	PgbsonWriterInit(&response);
	PgbsonWriterAppendDouble(&response, "ok", 2, 1);

	if (args.mode == COMPACT_MODE_UPDATE_STATS)
	{
		elog(LOG, "Updating statistics for collection %s.%s",
			 args.databaseName, args.collectionName);
		PerformCompactOperation(collection->collectionId, args.mode);
		PgbsonWriterAppendInt64(&response, "bytesFreed", 10, 0);
		PG_RETURN_POINTER(PgbsonWriterGetPgbson(&response));
	}

	/*
	 * Resolve everything that is needed from the collection before running any
	 * query. The metadata cache entry must not be dereferenced past this point:
	 * the VACUUM invalidates the relation and evicts the entry, and the size
	 * queries run without holding a lock on the relation.
	 */
	uint64 freedSpace = RunVacuumAndMeasureFreedSpace(collection->collectionId, &args);

	PgbsonWriterAppendInt64(&response, "bytesFreed", 10, freedSpace);
	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&response));
}


/*-------------------*/
/* Private functions */
/*-------------------*/

/*
 * Runs the requested VACUUM and returns the number of bytes that it actually
 * returned to the OS.
 *
 * The size is sampled from the relation files immediately before and after the
 * VACUUM, so the reported number is a measurement rather than an estimate. The
 * statistics based bloat estimate is only consulted when the caller asked for a
 * freeSpaceTarget, because that is the only case where a decision has to be made
 * before any space has been reclaimed. With no target the estimate is pure
 * overhead: it is one of the most expensive queries the extension issues, and
 * its result would only ever be compared against zero.
 */
static uint64
RunVacuumAndMeasureFreedSpace(uint64 collectionId, const CompactArgs *args)
{
	/*
	 * get_storage_stats_worker is only present once every node has been upgraded.
	 * During a rolling upgrade fall back to the estimate based accounting so
	 * that compact keeps working instead of failing on a lagging worker.
	 */
	if (!IsClusterVersionAtleast(DocDB_V1, 0, 0))
	{
		return RunVacuumAndEstimateFreedSpace(collectionId, args);
	}

	if (args->freeSpaceTargetMB > 0)
	{
		CollectionBloatStats bloatStats = GetCollectionBloatEstimate(collectionId);

		if (bloatStats.nullStats ||
			(bloatStats.estimatedBloatStorage / BYTES_PER_MB) < args->freeSpaceTargetMB)
		{
			/* Not enough reclaimable space to justify the vacuum. */
			return 0;
		}
	}

	CollectionStorageSize sizeBeforeVacuum = GetCollectionStorageSize(collectionId);

	elog_unredacted("Performing compact isFull=%d on collection %lu",
					args->mode == COMPACT_MODE_FULL, collectionId);
	PerformCompactOperation(collectionId, args->mode);

	CollectionStorageSize sizeAfterVacuum = GetCollectionStorageSize(collectionId);

	if (sizeBeforeVacuum.nullStats || sizeAfterVacuum.nullStats ||
		sizeAfterVacuum.totalRelationSize >= sizeBeforeVacuum.totalRelationSize)
	{
		/*
		 * Either a size could not be read, or the relation did not shrink. A
		 * standard VACUUM usually cannot shrink the file at all, and concurrent
		 * writes can grow it, so this is an expected outcome rather than an error.
		 */
		return 0;
	}

	return sizeBeforeVacuum.totalRelationSize - sizeAfterVacuum.totalRelationSize;
}


/*
 * Pre-1.0 accounting, kept so that compact still behaves sanely while a
 * cluster is partially upgraded and get_storage_stats_worker is not yet
 * guaranteed to exist on every node.
 */
static uint64
RunVacuumAndEstimateFreedSpace(uint64 collectionId, const CompactArgs *args)
{
	CollectionBloatStats beforeVacuumStats = GetCollectionBloatEstimate(collectionId);

	if (beforeVacuumStats.nullStats ||
		(beforeVacuumStats.estimatedBloatStorage / BYTES_PER_MB) <
		args->freeSpaceTargetMB)
	{
		return 0;
	}

	elog_unredacted("Performing compact isFull=%d on collection %lu",
					args->mode == COMPACT_MODE_FULL, collectionId);
	PerformCompactOperation(collectionId, args->mode);

	/*
	 * VACUUM FULL rewrites the table and hands the bloat space back to the OS, so
	 * approximate the freed space with the pre-vacuum bloat estimate. A standard
	 * VACUUM only reclaims dead-tuple space for reuse within the relation, so
	 * nothing is returned to the OS.
	 */
	return args->mode == COMPACT_MODE_FULL ? beforeVacuumStats.estimatedBloatStorage : 0;
}


/*
 * Validates that the current user has privileges to perform compact on the collection.
 */
static void
ValidateCompactAccess(MongoCollection *collection, CompactMode mode)
{
	HeapTuple tuple = SearchSysCache1(RELOID, ObjectIdGetDatum(collection->relationId));
	if (!HeapTupleIsValid(tuple))
	{
		ereport(ERROR, (
					errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
					errmsg(
						"Cannot find relation in cache while performing compact on collection %s.%s",
						collection->name.databaseName,
						collection->name.collectionName),
					errdetail_log(
						"Cannot find relation in cache while performing compact on collection %s.%s",
						collection->name.databaseName, collection->name.collectionName)));
	}
	Form_pg_class classForm = (Form_pg_class) GETSTRUCT(tuple);

	uint32 options = mode == COMPACT_MODE_UPDATE_STATS ? VACOPT_ANALYZE : VACOPT_VACUUM;
	if (mode == COMPACT_MODE_FULL)
	{
		options |= VACOPT_FULL;
	}
	bool userCanVacuum = false;
#if PG_VERSION_NUM >= 170000
	userCanVacuum = vacuum_is_permitted_for_relation(collection->relationId,
													 classForm, options);
#else
	userCanVacuum = vacuum_is_relation_owner(collection->relationId,
											 classForm, options);
#endif
	ReleaseSysCache(tuple);

	if (!userCanVacuum)
	{
		ereport(ERROR, (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
						errmsg(
							"permisson denied for performing compact on collection %s.%s",
							collection->name.databaseName,
							collection->name.collectionName),
						errdetail_log(
							"permisson denied for performing compact on collection %s.%s",
							collection->name.databaseName,
							collection->name.collectionName)));
	}
}


/*
 * Checks if the relation to be vacuumed is available for the lock level that the
 * requested compact mode needs. VACUUM FULL takes an AccessExclusiveLock, while a
 * plain VACUUM only takes a ShareUpdateExclusiveLock; checking the matching lock
 * level lets us fail early when a conflicting operation is already in progress
 * without being overly strict for the non-blocking standard mode.
 * Note: ValidateCompactAccess is already called before this function in command_compact,
 * so we only need to check locking here.
 */
static void
ValidateLocksAndCheckAccess(MongoCollection *collection, CompactMode mode)
{
	LOCKMODE lockMode = mode == COMPACT_MODE_FULL ? AccessExclusiveLock :
						ShareUpdateExclusiveLock;

	/* Now checking if the collection is available for the required lock level :
	 * - To validate early if only 1 vacuum is running on the collection.
	 *
	 * We only take the lock conditionally to test availability and then release
	 * it immediately. The actual VACUUM runs on a separate libpq connection (see
	 * PerformCompactOperation), so if this backend kept holding the lock, that connection
	 * would block on our own session and hang. Releasing here lets the subsequent
	 * VACUUM acquire the lock itself.
	 */
	if (ConditionalLockRelationOid(collection->relationId, lockMode))
	{
		UnlockRelationOid(collection->relationId, lockMode);
	}
	else
	{
		/* Throw conflicting operations in progress */
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_LOCATION17308),
						errmsg(
							"compact is not allowed on collection %s.%s because another operation is in progress",
							collection->name.databaseName,
							collection->name.collectionName),
						errdetail_log(
							"compact is not allowed on collection %s.%s because another operation is in progress",
							collection->name.databaseName,
							collection->name.collectionName)));
	}
}


/*
 * This sends an ANALYZE or VACUUM (FULL, for compact mode "full") command to the
 * local server via libpq, as VACUUM can't be executed in a transaction block.
 */
static void
PerformCompactOperation(uint64 collectionId, CompactMode mode)
{
	const char *maintenanceQuery;
	if (mode == COMPACT_MODE_UPDATE_STATS)
	{
		maintenanceQuery = FormatSqlQuery("ANALYZE %s.documents_%ld",
										  ApiDataSchemaName,
										  collectionId);
	}
	else
	{
		maintenanceQuery = mode == COMPACT_MODE_FULL ?
						   FormatSqlQuery("VACUUM FULL %s.documents_%ld",
										  ApiDataSchemaName,
										  collectionId) :
						   FormatSqlQuery("VACUUM %s.documents_%ld",
										  ApiDataSchemaName,
										  collectionId);
	}

	/* VACUUM needs to be performed at the top level */
	bool useSerialExecution = false;
	Oid userOid = GetUserId();
	ExtensionExecuteQueryAsUserOnLocalhostViaLibPQ((char *) maintenanceQuery, userOid,
												   useSerialExecution);
}


static void
ParseCompactCommandSpec(pgbson *compactSpec, CompactArgs *args)
{
	if (compactSpec == NULL)
	{
		return;
	}

	bson_iter_t specIter;
	PgbsonInitIterator(compactSpec, &specIter);
	while (bson_iter_next(&specIter))
	{
		pgbsonelement element;
		BsonIterToPgbsonElement(&specIter, &element);

		if (strcmp(element.path, "compact") == 0)
		{
			EnsureTopLevelFieldType("compact", &specIter, BSON_TYPE_UTF8);
			ValidateNamespaceStringForEmbeddedNull(
				element.bsonValue.value.v_utf8.str,
				element.bsonValue.value.v_utf8.len);
			args->collectionName = pstrdup(element.bsonValue.value.v_utf8.str);
		}
		else if (strcmp(element.path, "$db") == 0)
		{
			EnsureTopLevelFieldType("$db", &specIter, BSON_TYPE_UTF8);
			args->databaseName = pstrdup(element.bsonValue.value.v_utf8.str);
		}
		else if (strcmp(element.path, "force") == 0)
		{
			EnsureTopLevelFieldType("force", &specIter, BSON_TYPE_BOOL);
			args->force = element.bsonValue.value.v_bool;
			if (!args->force)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
								errmsg(
									"command compact option force:false is not supported")));
			}
		}
		else if (strcmp(element.path, "dryRun") == 0)
		{
			EnsureTopLevelFieldType("dryRun", &specIter, BSON_TYPE_BOOL);
			args->dryRun = element.bsonValue.value.v_bool;
		}
		else if (strcmp(element.path, "freeSpaceTargetMB") == 0)
		{
			EnsureTopLevelFieldIsNumberLike("freeSpaceTargetMB", &element.bsonValue);
			args->freeSpaceTargetMB = BsonValueAsDouble(&element.bsonValue);
		}
		else if (strcmp(element.path, "mode") == 0)
		{
			EnsureTopLevelFieldType("mode", &specIter, BSON_TYPE_UTF8);
			const char *modeStr = element.bsonValue.value.v_utf8.str;
			if (strcmp(modeStr, "full") == 0)
			{
				SelectCompactMode(args, COMPACT_MODE_FULL);
			}
			else if (strcmp(modeStr, "updateStats") == 0)
			{
				SelectCompactMode(args, COMPACT_MODE_UPDATE_STATS);
			}
			else if (strcmp(modeStr, "standard") == 0)
			{
				SelectCompactMode(args, COMPACT_MODE_STANDARD);
			}
			else
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Invalid compact mode '%s'. Supported values are 'full', 'standard', and 'updateStats'.",
									modeStr),
								errdetail_log(
									"Invalid compact mode '%s'. Supported values are 'full', 'standard', and 'updateStats'.",
									modeStr)));
			}
		}
		else if (!IsCommonSpecIgnoredField(element.path))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
							errmsg(
								"The BSON field compact.%s is not recognized as a known field",
								element.path),
							errdetail_log(
								"The BSON field compact.%s is not recognized as a known field",
								element.path)));
		}
	}
}


static void
SelectCompactMode(CompactArgs *args, CompactMode mode)
{
	if (args->mode != COMPACT_MODE_UNSPECIFIED && args->mode != mode)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"conflicting compact mode values are mutually exclusive")));
	}

	args->mode = mode;
}
