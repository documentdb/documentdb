/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/rename_collection.c
 *
 * Implementation of the rename_collection UDF.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/resowner.h"
#include "lib/stringinfo.h"
#include "access/xact.h"

#include "utils/documentdb_errors.h"
#include "metadata/collection.h"
#include "metadata/metadata_cache.h"
#include "utils/query_utils.h"
#include "utils/string_view.h"

#include "api_hooks.h"
#include "commands/commands_common.h"
#include "commands/parse_error.h"
#include "commands/rename_collection.h"

extern bool EnableNewNamespaceValidation;

static void DropMongoCollection(char *, char *);
static void UpdateMongoCollectionName(char *, char *, char *);

PG_FUNCTION_INFO_V1(command_rename_collection);
PG_FUNCTION_INFO_V1(command_rename_collection_by_bson_spec);

/*
 * ParseRenameCollectionSpec parses BSON command specification for renameCollection.
 * Extracts "renameCollection" (source namespace), "to" (target namespace), and "dropTarget".
 * Splits namespaces into database and collection names.
 */
void
ParseRenameCollectionSpec(pgbson *commandSpec, RenameCollectionArgs *args)
{
	if (commandSpec == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("renameCollection command specification cannot be NULL")));
	}

	char *sourceNamespace = NULL;
	char *targetNamespace = NULL;

	bson_iter_t specIter;
	PgbsonInitIterator(commandSpec, &specIter);

	while (bson_iter_next(&specIter))
	{
		pgbsonelement element;
		BsonIterToPgbsonElement(&specIter, &element);

		if (strcmp(element.path, "renameCollection") == 0)
		{
			EnsureTopLevelFieldType("renameCollection", &specIter, BSON_TYPE_UTF8);
			sourceNamespace = pstrdup(element.bsonValue.value.v_utf8.str);
		}
		else if (strcmp(element.path, "to") == 0)
		{
			EnsureTopLevelFieldType("to", &specIter, BSON_TYPE_UTF8);
			targetNamespace = pstrdup(element.bsonValue.value.v_utf8.str);
		}
		else if (strcmp(element.path, "dropTarget") == 0)
		{
			EnsureTopLevelFieldType("dropTarget", &specIter, BSON_TYPE_BOOL);
			args->dropTarget = element.bsonValue.value.v_bool;
		}
		else if (!IsCommonSpecIgnoredField(element.path))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
							errmsg(
								"The BSON field 'renameCollection.%s' is not recognized as a valid field",
								element.path)));
		}
	}

	if (sourceNamespace == NULL || targetNamespace == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"renameCollection command must specify both renameCollection and to fields")));
	}

	/* Split "db.collection" into separate parts */
	StringView sourceView = CreateStringViewFromString(sourceNamespace);
	StringView sourceDbView = StringViewFindPrefix(&sourceView, '.');
	StringView sourceCollView = StringViewFindSuffix(&sourceView, '.');

	StringView targetView = CreateStringViewFromString(targetNamespace);
	StringView targetDbView = StringViewFindPrefix(&targetView, '.');
	StringView targetCollView = StringViewFindSuffix(&targetView, '.');

	if (sourceDbView.length == 0 || sourceCollView.length == 0 ||
		targetDbView.length == 0 || targetCollView.length == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"Invalid namespace format, expected 'database.collection'")));
	}

	args->databaseName = CreateStringFromStringView(&sourceDbView);
	args->sourceCollectionName = CreateStringFromStringView(&sourceCollView);

	char *targetDatabaseName = CreateStringFromStringView(&targetDbView);
	args->targetCollectionName = CreateStringFromStringView(&targetCollView);

	/* Validate source and target are in the same database */
	if (strcmp(args->databaseName, targetDatabaseName) != 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg("renameCollection cannot change databases")));
	}
}


/*
 * ExecuteRenameCollection contains the core rename logic shared by both
 * the BSON and legacy entry points.
 */
void
ExecuteRenameCollection(char *databaseName, char *sourceCollectionName,
						char *targetCollectionName, bool dropTarget)
{
	/* Validate source and target collection names are different */
	if (strcmp(sourceCollectionName, targetCollectionName) == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_ILLEGALOPERATION),
						errmsg("Can't rename a collection to itself")));
	}

	Datum database_datum = CStringGetTextDatum(databaseName);
	Datum collection_datum = CStringGetTextDatum(sourceCollectionName);
	Datum new_collection_datum = CStringGetTextDatum(targetCollectionName);

	if (EnableNewNamespaceValidation)
	{
		StringView collectionView = CreateStringViewFromString(sourceCollectionName);
		ValidateCollectionNameForValidSystemNamespace(&collectionView, database_datum);

		StringView targetCollectionView = CreateStringViewFromString(
			targetCollectionName);
		ValidateCollectionNameForValidSystemNamespace(&targetCollectionView,
													  database_datum);
	}

	/*
	 * Check if the collection to be updated exists. if not, throw an error.
	 */
	MongoCollection *collection =
		GetMongoCollectionByNameDatum(database_datum,
									  collection_datum,
									  NoLock);

	if (collection == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_NAMESPACENOTFOUND),
						errmsg("collection %s.%s does not exist",
							   databaseName, sourceCollectionName)));
	}

	/*
	 * Checking whether the new collection name already exists in the database.
	 * If yes and drop_target is false, throw an error. Drop it otherwise.
	 */
	MongoCollection *target_collection =
		GetMongoCollectionOrViewByNameDatum(database_datum,
											new_collection_datum,
											NoLock);

	if (target_collection != NULL)
	{
		if (dropTarget)
		{
			DropMongoCollection(databaseName, targetCollectionName);
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_NAMESPACEEXISTS),
							errmsg(
								"The collection %s.%s is already present in the system",
								databaseName, targetCollectionName)));
		}
	}

	/*
	 * Update the specified collection name.
	 */
	UpdateMongoCollectionName(databaseName, sourceCollectionName, targetCollectionName);
}


/*
 * command_rename_collection_by_bson_spec handles the BSON-based signature.
 * Signature: rename_collection(bson)
 */
Datum
command_rename_collection_by_bson_spec(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		ereport(ERROR, (errmsg("renameCollection command specification cannot be NULL")));
	}

	RenameCollectionArgs args;
	memset(&args, 0, sizeof(RenameCollectionArgs));
	pgbson *commandSpec = PG_GETARG_PGBSON(0);

	/* Parse BSON to extract source/target namespaces and dropTarget */
	ParseRenameCollectionSpec(commandSpec, &args);

	ExecuteRenameCollection(args.databaseName, args.sourceCollectionName,
							args.targetCollectionName, args.dropTarget);

	pgbson_writer resultWriter;
	PgbsonWriterInit(&resultWriter);
	PgbsonWriterAppendDouble(&resultWriter, "ok", 2, 1);
	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&resultWriter));
}


/*
 * command_rename_collection implements the functionality
 * of the renameCollection database command (legacy text signature).
 */
Datum
command_rename_collection(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		ereport(ERROR, (errmsg("Database name must not be NULL")));
	}

	if (PG_ARGISNULL(1))
	{
		ereport(ERROR, (errmsg("collection name cannot be NULL")));
	}

	if (PG_ARGISNULL(2))
	{
		ereport(ERROR, (errmsg("collection target name cannot be NULL")));
	}

	char *databaseName = TextDatumGetCString(PG_GETARG_DATUM(0));
	char *sourceCollectionName = TextDatumGetCString(PG_GETARG_DATUM(1));
	char *targetCollectionName = TextDatumGetCString(PG_GETARG_DATUM(2));
	bool dropTarget = PG_ARGISNULL(3) ? false : PG_GETARG_BOOL(3);

	ExecuteRenameCollection(databaseName, sourceCollectionName,
							targetCollectionName, dropTarget);

	PG_RETURN_VOID();
}


/*
 * Drops a collection
 */
static void
DropMongoCollection(char *database_name, char *target_collection_name)
{
	Datum argValues[2] = {
		CStringGetTextDatum(database_name), CStringGetTextDatum(target_collection_name)
	};
	Oid argTypes[2] = { TEXTOID, TEXTOID };
	char *argNulls = NULL;
	StringInfo cmdStr = makeStringInfo();

	appendStringInfo(cmdStr,
					 "SELECT %s.drop_collection($1, $2);",
					 ApiSchemaName);

	bool isNull = false;
	bool readOnly = false;
	ExtensionExecuteQueryWithArgsViaSPI(cmdStr->data,
										2,
										argTypes, argValues, argNulls,
										readOnly, SPI_OK_SELECT,
										&isNull);
}


/*
 * Update the name of a specified collection in the database.
 */
static void
UpdateMongoCollectionName(char *database_name, char *collection_name, char *new_name)
{
	Datum argValues[3] = {
		CStringGetTextDatum(new_name), CStringGetTextDatum(database_name),
		CStringGetTextDatum(collection_name)
	};
	Oid argTypes[3] = { TEXTOID, TEXTOID, TEXTOID };
	char *argNulls = NULL;

	StringInfo cmdStr = makeStringInfo();
	appendStringInfo(cmdStr,
					 "UPDATE %s.collections SET collection_name = $1 WHERE database_name = $2 AND collection_name = $3",
					 ApiCatalogSchemaName);

	bool isNull = false;
	bool readOnly = false;
	ExtensionExecuteQueryWithArgsViaSPI(cmdStr->data,
										3,
										argTypes, argValues, argNulls,
										readOnly, SPI_OK_UPDATE,
										&isNull);
}
