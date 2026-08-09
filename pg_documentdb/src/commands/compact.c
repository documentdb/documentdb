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
	COMPACT_MODE_STANDARD = 0,

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

	/* Which VACUUM flavor to run. Defaults to COMPACT_MODE_STANDARD. */
	CompactMode mode;

	/*
	 * Estimate the amount of space that would be freed by a compact operation
	 * without actually performing it.
	 */
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
static void PerformVacuum(MongoCollection *collection, CompactMode mode);
static void ValidateCompactAccess(MongoCollection *collection, CompactMode mode);
static void ValidateLocksAndCheckAccess(MongoCollection *collection, CompactMode mode);


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

	/* Get the bloat stats before vacuuming */
	CollectionBloatStats beforeVacuumStats;
	memset(&beforeVacuumStats, 0, sizeof(CollectionBloatStats));

	/* Get the bloat stats before vacuuming */
	beforeVacuumStats = GetCollectionBloatEstimate(collection->collectionId);

	uint64 freedSpace = 0;
	if (!beforeVacuumStats.nullStats && (beforeVacuumStats.estimatedBloatStorage /
										 BYTES_PER_MB) >= args.freeSpaceTargetMB)
	{
		/* Only perform vacuum if there are stats available and freeSpace target is met */
		elog(LOG, "Performing compact (%s) on collection %s.%s",
			 args.mode == COMPACT_MODE_FULL ? "vacuum full" : "vacuum",
			 args.databaseName, args.collectionName);
		PerformVacuum(collection, args.mode);

		/*
		 * Report the on-disk space returned to the OS. VACUUM FULL rewrites the
		 * table and hands the bloat space back to the OS, so approximate the
		 * freed space with the pre-vacuum bloat estimate. A standard VACUUM only
		 * reclaims dead-tuple space for reuse within the relation and does not
		 * shrink the file, so nothing is returned to the OS.
		 *
		 * Note: this is a rough estimate and does not account for index space.
		 */
		if (args.mode == COMPACT_MODE_FULL)
		{
			freedSpace = beforeVacuumStats.estimatedBloatStorage;
		}
	}

	PgbsonWriterAppendInt64(&response, "bytesFreed", 10, freedSpace);
	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&response));
}


/*-------------------*/
/* Private functions */
/*-------------------*/

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

	uint32 options = VACOPT_VACUUM;
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
	 * PerformVacuum), so if this backend kept holding the lock, that connection
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
 * This sends a VACUUM (FULL, for compact mode "full") command to the local server via
 * libpq, as VACUUM can't be executed in a transaction block.
 */
static void
PerformVacuum(MongoCollection *collection, CompactMode mode)
{
	Assert(collection != NULL && collection->relationId != InvalidOid);

	const char *vacuumQuery = mode == COMPACT_MODE_FULL ?
							  FormatSqlQuery("VACUUM FULL %s.documents_%ld",
											 ApiDataSchemaName,
											 collection->collectionId) :
							  FormatSqlQuery("VACUUM %s.documents_%ld",
											 ApiDataSchemaName,
											 collection->collectionId);

	/* VACUUM needs to be performed at the top level */
	bool useSerialExecution = false;
	Oid userOid = GetUserId();
	ExtensionExecuteQueryAsUserOnLocalhostViaLibPQ((char *) vacuumQuery, userOid,
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
				args->mode = COMPACT_MODE_FULL;
			}
			else if (strcmp(modeStr, "standard") == 0)
			{
				args->mode = COMPACT_MODE_STANDARD;
			}
			else
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Invalid compact mode '%s'. Supported values are 'full' and 'standard'.",
									modeStr),
								errdetail_log(
									"Invalid compact mode '%s'. Supported values are 'full' and 'standard'.",
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
