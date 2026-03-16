/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/drop_collection.c
 *
 * Implementation of view and collection creation functions.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/resowner.h"
#include "utils/uuid.h"
#include "lib/stringinfo.h"
#include "access/xact.h"
#include "utils/syscache.h"
#include "nodes/makefuncs.h"
#include "catalog/namespace.h"

#include "utils/documentdb_errors.h"
#include "metadata/collection.h"
#include "metadata/metadata_cache.h"
#include "metadata/index.h"
#include "utils/query_utils.h"
#include "utils/index_utils.h"
#include "utils/guc_utils.h"
#include "utils/version_utils.h"
#include "commands/commands_common.h"

#include "api_hooks.h"
#include "commands/parse_error.h"

typedef struct DropCollectionArgs
{
	char *databaseName;
	char *collectionName;
	Datum collectionUuid;
	bool hasUuid;
	bool trackChanges;
} DropCollectionArgs;

static void ParseDropCollectionSpec(pgbson *commandSpec, DropCollectionArgs *args);
static bool ValidateAndExecuteDrop(DropCollectionArgs *args, pgbson *commandSpec,
								   pgbson *writeConcern);
static char * ConstructDropCommandCstr(char *databaseName, char *collectionName,
									   pgbson *writeConcern, char *uuid, bool
									   trackChanges);

PG_FUNCTION_INFO_V1(command_drop_collection);
PG_FUNCTION_INFO_V1(command_drop_collection_by_bson_spec);

/*
 * ParseDropCollectionSpec parses BSON command specification
 */
static void
ParseDropCollectionSpec(pgbson *commandSpec, DropCollectionArgs *args)
{
	if (commandSpec == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("drop command specification cannot be NULL")));
	}

	bson_iter_t specIter;
	PgbsonInitIterator(commandSpec, &specIter);

	while (bson_iter_next(&specIter))
	{
		pgbsonelement element;
		BsonIterToPgbsonElement(&specIter, &element);

		if (strcmp(element.path, "drop") == 0)
		{
			EnsureTopLevelFieldType("drop", &specIter, BSON_TYPE_UTF8);
			args->collectionName = pstrdup(element.bsonValue.value.v_utf8.str);
		}
		else if (strcmp(element.path, "$db") == 0)
		{
			Datum databaseNameDatum = (Datum) 0;
			ValidateOrExtractDatabaseNameFromSpec(&specIter, &databaseNameDatum);
			args->databaseName = TextDatumGetCString(databaseNameDatum);
		}
		else if (!IsCommonSpecIgnoredField(element.path))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
							errmsg(
								"The BSON field 'drop.%s' is not recognized as a valid field",
								element.path)));
		}
	}

	if (args->databaseName == NULL || args->collectionName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("drop command must specify both $db and drop fields")));
	}
}


/*
 * ValidateAndExecuteDrop
 */
static bool
ValidateAndExecuteDrop(DropCollectionArgs *args, pgbson *commandSpec,
					   pgbson *writeConcern)
{
	Datum databaseNameDatum = CStringGetTextDatum(args->databaseName);
	Datum collectionNameDatum = CStringGetTextDatum(args->collectionName);

	MongoCollection *collection =
		GetMongoCollectionOrViewByNameDatum(databaseNameDatum,
											collectionNameDatum,
											NoLock);

	if (collection == NULL)
	{
		return false;
	}

	if (strncmp(args->collectionName, "system.", 7) == 0 &&
		strcmp(args->collectionName, "system.dbSentinel") != 0)
	{
		/* system collection, cannot drop */
		return false;
	}

	if (!IsMetadataCoordinator())
	{
		char *uuid = NULL;
		if (args->hasUuid)
		{
			uuid = DatumGetCString(DirectFunctionCall1(uuid_out, args->collectionUuid));
		}

		StringInfo dropQuery = makeStringInfo();

		/* Always use legacy text path when forwarding to coordinator.
		 * This is safe during rolling upgrades where the coordinator
		 * may not yet have the BSON signature. Once the old method is
		 * fully retired, this can be switched to the BSON signature. */
		char *legacyCommand = ConstructDropCommandCstr(args->databaseName,
													   args->collectionName,
													   writeConcern, uuid,
													   args->trackChanges);
		appendStringInfoString(dropQuery, legacyCommand);

		DistributedRunCommandResult result = RunCommandOnMetadataCoordinator(
			dropQuery->data);

		if (!result.success)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Internal error dropping collection in metadata coordinator"),
							errdetail_log("Error: %s", text_to_cstring(
											  result.response))));
		}

		return strcasecmp(text_to_cstring(result.response), "t") == 0;
	}

	/* UUID validation */
	Datum collectionIdArgValue[1] = { UInt64GetDatum(collection->collectionId) };
	Oid collectionIdArgType[1] = { INT8OID };
	char collectionIdArgNull[1] = { ' ' };

	if (args->hasUuid)
	{
		StringInfo findUuidByRelIdQuery = makeStringInfo();
		appendStringInfo(findUuidByRelIdQuery,
						 "SELECT collection_uuid FROM %s.collections "
						 "WHERE collection_id = $1",
						 ApiCatalogSchemaName);

		bool readOnly = true;
		bool isNull = false;

		Datum collectionUuid_db = ExtensionExecuteQueryWithArgsViaSPI(
			findUuidByRelIdQuery->data,
			1, collectionIdArgType, collectionIdArgValue,
			collectionIdArgNull, readOnly,
			SPI_OK_SELECT,
			&isNull);

		if (isNull || memcmp(DatumGetPointer(collectionUuid_db),
							 DatumGetPointer(args->collectionUuid),
							 sizeof(pg_uuid_t)) != 0)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COLLECTIONUUIDMISMATCH),
							errmsg("drop collection %s.%s UUID mismatch",
								   args->databaseName, args->collectionName)));
		}
	}

	/* Execute drop operations */
	StringInfo deleteCommand = makeStringInfo();
	bool readOnly;
	bool isNull;

	/* Drop documents table */
	appendStringInfo(deleteCommand,
					 "DROP TABLE IF EXISTS %s.documents_"
					 INT64_FORMAT,
					 ApiDataSchemaName,
					 collection->collectionId);
	readOnly = false;
	isNull = false;
	ExtensionExecuteQueryViaSPI(deleteCommand->data, readOnly, SPI_OK_UTILITY, &isNull);

	/* Drop retry table */
	resetStringInfo(deleteCommand);
	appendStringInfo(deleteCommand,
					 "DROP TABLE IF EXISTS %s.retry_" INT64_FORMAT,
					 ApiDataSchemaName, collection->collectionId);
	ExtensionExecuteQueryViaSPI(deleteCommand->data, readOnly, SPI_OK_UTILITY, &isNull);

	/* Delete from collections catalog */
	StringInfo deleteFromCollectionsCommand = makeStringInfo();
	appendStringInfo(deleteFromCollectionsCommand,
					 "DELETE FROM %s.collections WHERE collection_id = $1",
					 ApiCatalogSchemaName);
	isNull = false;
	RunQueryWithCommutativeWrites(deleteFromCollectionsCommand->data, 1,
								  collectionIdArgType, collectionIdArgValue,
								  collectionIdArgNull, SPI_OK_DELETE,
								  &isNull);

	DeleteAllCollectionIndexRecords(collection->collectionId);

	/* Delete from index queue */
	bool tableExists = false;
	if (IsClusterVersionAtleast(DocDB_V0, 12, 0))
	{
		tableExists = true;
	}

	if (tableExists)
	{
		StringInfo deleteFromIndexQueueCommand = makeStringInfo();
		appendStringInfo(deleteFromIndexQueueCommand,
						 "DELETE FROM %s WHERE collection_id = $1", GetIndexQueueName());
		RunQueryWithCommutativeWrites(deleteFromIndexQueueCommand->data, 1,
									  collectionIdArgType, collectionIdArgValue,
									  collectionIdArgNull, SPI_OK_DELETE,
									  &isNull);
	}

	DeleteAllCollectionIndexRecords(collection->collectionId);

	return true;
}


/*
 * command_drop_collection_by_bson_spec handles the BSON-based signature.
 * Signature: drop_collection(bson, uuid DEFAULT NULL, bool DEFAULT true)
 */
Datum
command_drop_collection_by_bson_spec(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		PG_RETURN_BOOL(false);
	}

	DropCollectionArgs args;
	memset(&args, 0, sizeof(DropCollectionArgs));
	pgbson *commandSpec = PG_GETARG_PGBSON(0);

	ParseDropCollectionSpec(commandSpec, &args);

	args.hasUuid = !PG_ARGISNULL(1);
	if (args.hasUuid)
	{
		args.collectionUuid = PG_GETARG_DATUM(1);
	}
	args.trackChanges = PG_ARGISNULL(2) ? true : PG_GETARG_BOOL(2);

	ThrowIfServerOrTransactionReadOnly();

	PG_RETURN_BOOL(ValidateAndExecuteDrop(&args, commandSpec, NULL));
}


/*
 * command_drop_collection handles the text-based signature.
 * Signature: drop_collection(text, text, bson DEFAULT NULL, uuid DEFAULT NULL, bool DEFAULT true)
 */
Datum
command_drop_collection(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
	{
		PG_RETURN_BOOL(false);
	}

	ThrowIfServerOrTransactionReadOnly();
	DropCollectionArgs args;
	memset(&args, 0, sizeof(DropCollectionArgs));
	args.databaseName = TextDatumGetCString(PG_GETARG_DATUM(0));
	args.collectionName = TextDatumGetCString(PG_GETARG_DATUM(1));
	args.trackChanges = PG_GETARG_BOOL(4);
	args.hasUuid = !PG_ARGISNULL(3);
	if (args.hasUuid)
	{
		args.collectionUuid = PG_GETARG_DATUM(3);
	}

	pgbson *writeConcern = PG_ARGISNULL(2) ? NULL : PG_GETARG_PGBSON(2);

	PG_RETURN_BOOL(ValidateAndExecuteDrop(&args, NULL, writeConcern));
}


/*
 * Reconstructs the drop command from the parameter values
 */
static char *
ConstructDropCommandCstr(char *databaseName, char *collectionName, pgbson *writeConcern,
						 char *uuid, bool trackChanges)
{
	StringInfo dropCollectionQuery = makeStringInfo();
	appendStringInfo(dropCollectionQuery,
					 "SELECT %s.drop_collection(%s, %s",
					 ApiSchemaName,
					 quote_literal_cstr(databaseName),
					 quote_literal_cstr(collectionName));

	if (writeConcern != NULL)
	{
		appendStringInfo(dropCollectionQuery,
						 ", p_write_concern => %s::%s",
						 quote_literal_cstr(PgbsonToHexadecimalString(writeConcern)),
						 FullBsonTypeName
						 );
	}

	if (uuid != NULL)
	{
		appendStringInfo(dropCollectionQuery,
						 ", p_collection_uuid => %s",
						 quote_literal_cstr(uuid));
	}

	if (trackChanges == false)
	{
		appendStringInfo(dropCollectionQuery, ", p_track_changes => false");
	}

	appendStringInfoChar(dropCollectionQuery, ')');

	return dropCollectionQuery->data;
}
