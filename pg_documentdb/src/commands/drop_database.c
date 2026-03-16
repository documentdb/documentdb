/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/drop_database.c
 *
 * Implementation of the drop_database BSON-based entry point.
 *
 * Parses the full BSON command spec from the Gateway, extracts the
 * database name, and delegates to the existing drop_database(text)
 * function which handles dropping all collections in the database.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"
#include "lib/stringinfo.h"

#include "utils/documentdb_errors.h"
#include "metadata/metadata_cache.h"
#include "utils/query_utils.h"

#include "commands/commands_common.h"
#include "commands/parse_error.h"

typedef struct DropDatabaseArgs
{
	Datum databaseNameDatum;
} DropDatabaseArgs;

static void ParseDropDatabaseSpec(pgbson *commandSpec, DropDatabaseArgs *args);
static void ExecuteDropDatabase(const char *databaseName);

PG_FUNCTION_INFO_V1(command_drop_database_by_bson_spec);

static void
ParseDropDatabaseSpec(pgbson *commandSpec, DropDatabaseArgs *args)
{
	if (commandSpec == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("dropDatabase command specification cannot be NULL")));
	}

	bson_iter_t specIter;
	PgbsonInitIterator(commandSpec, &specIter);

	while (bson_iter_next(&specIter))
	{
		pgbsonelement element;
		BsonIterToPgbsonElement(&specIter, &element);

		if (strcmp(element.path, "dropDatabase") == 0)
		{
			/* Command name field — value is always 1, nothing to extract */
		}
		else if (strcmp(element.path, "$db") == 0)
		{
			ValidateOrExtractDatabaseNameFromSpec(&specIter, &args->databaseNameDatum);
		}
		else if (!IsCommonSpecIgnoredField(element.path))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
							errmsg(
								"The BSON field 'dropDatabase.%s' is not recognized as a valid field",
								element.path)));
		}
	}

	if (args->databaseNameDatum == (Datum) 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("dropDatabase command must specify the $db field")));
	}
}


static void
ExecuteDropDatabase(const char *databaseName)
{
	/* Delegate to the existing drop_database(text) which already handles
	 * querying the collections catalog and dropping each collection. */
	StringInfo dropQuery = makeStringInfo();
	appendStringInfo(dropQuery,
					 "SELECT %s.drop_database(%s)",
					 ApiSchemaName,
					 quote_literal_cstr(databaseName));
	bool isNull = false;
	ExtensionExecuteQueryViaSPI(dropQuery->data, false, SPI_OK_SELECT, &isNull);
}


/*
 * command_drop_database_by_bson_spec is the C entry point for the
 * drop_database(bson) SQL function.
 */
Datum
command_drop_database_by_bson_spec(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("dropDatabase command specification cannot be NULL")));
	}

	pgbson *commandSpec = PG_GETARG_PGBSON(0);

	DropDatabaseArgs args;
	memset(&args, 0, sizeof(DropDatabaseArgs));

	ParseDropDatabaseSpec(commandSpec, &args);

	ThrowIfServerOrTransactionReadOnly();

	ExecuteDropDatabase(TextDatumGetCString(args.databaseNameDatum));

	pgbson_writer resultWriter;
	PgbsonWriterInit(&resultWriter);
	PgbsonWriterAppendDouble(&resultWriter, "ok", 2, 1);
	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&resultWriter));
}
