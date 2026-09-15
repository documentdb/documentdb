/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/validate.c
 *
 * Implementation of the validate command.
 *
 *-------------------------------------------------------------------------
 */

/*
 * Currently this will only support validating the indexes. It'll only check
 * if the index is valid (checking the 'indisvalid' column in pg_index)
 */

#include <postgres.h>
#include <executor/spi.h>
#include <fmgr.h>
#include <funcapi.h>
#include <utils/acl.h>
#include <utils/builtins.h>
#include <utils/lsyscache.h>

#include "utils/documentdb_errors.h"
#include "commands/commands_common.h"
#include "metadata/collection.h"
#include "metadata/metadata_cache.h"
#include "metadata/index.h"
#include "utils/feature_counter.h"
#include "utils/query_utils.h"
#include "utils/role_utils.h"
#include "commands/parse_error.h"

PG_FUNCTION_INFO_V1(command_validate);

typedef struct
{
	/* represents database name*/
	const char *databaseName;

	/* Indicates the name of a collection*/
	const char *collectionName;

	/* if full validation is required, currently a no-op*/
	bool full;

	/* if baseline collection privileges should be repaired */
	bool repair;

	/* if ONLY metadata validation is required, currently a no-op */
	bool metadata;

	/* if document conformance validation is required, currently a no-op */
	bool checkBsonConformance;
} ValidateSpec;

typedef struct
{
	/* The namespace of the collection */
	char *ns;

	/* The collection's total count of indexes */
	int32 totalIndexes;

	/* Details of each index along with it's validity */
	pgbson *indexDetailsPgbson;

	/* if true, the collection is valid */
	bool isValid;

	/* if true, the collection is repaired */
	bool isRepaired;

	/* List of warnings */
	List *warnings;

	/* List of errors for invalidity of indexes*/
	List *errors;

	/* if true, the command succeeded */
	int32 ok;
} ValidateResult;

static void validateCollection(MongoCollection *collection, ValidateResult *result);
static void CheckIndisvalid(uint64 collectionId, ValidateResult *result);
static pgbson * BuildResponseMessage(ValidateResult *result);
static bool HasBaselineRolePrivileges(Oid relationId, Oid baselineReadRole,
									  Oid baselineWriteRole);

/*
 * command_validate is the implementation of the internal logic for
 * 'validate' database diagnostic command.
 */
Datum
command_validate(PG_FUNCTION_ARGS)
{
	ValidateSpec validateSpec = { 0 };

	if (PG_ARGISNULL(1))
	{
		ereport(ERROR, (errmsg("The provided namespace value is not valid.")));
	}

	pgbson *validationBsonSpec = PG_GETARG_PGBSON(1);
	Datum databaseNameDatum = PG_ARGISNULL(0) ? (Datum) 0 : PG_GETARG_DATUM(0);

	bson_iter_t validateIter;
	PgbsonInitIterator(validationBsonSpec, &validateIter);

	while (bson_iter_next(&validateIter))
	{
		StringView keyView = bson_iter_key_string_view(&validateIter);
		const bson_value_t *value = bson_iter_value(&validateIter);

		if (StringViewEqualsCString(&keyView, "validate"))
		{
			if (bson_iter_type(&validateIter) == BSON_TYPE_DOCUMENT)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDNAMESPACE),
								errmsg(
									"Collection name contains an invalid object type")));
			}

			EnsureTopLevelFieldType("validate", &validateIter, BSON_TYPE_UTF8);
			ValidateNamespaceStringForEmbeddedNull(value->value.v_utf8.str,
												   value->value.v_utf8.len);
			validateSpec.collectionName = value->value.v_utf8.str;
		}
		else if (StringViewEqualsCString(&keyView, "$db"))
		{
			ValidateOrExtractDatabaseNameFromSpec(&validateIter, &databaseNameDatum);
		}
		else if (StringViewEqualsCString(&keyView, "full"))
		{
			validateSpec.full = BsonValueAsBool(value);
		}
		else if (StringViewEqualsCString(&keyView, "repair"))
		{
			validateSpec.repair = BsonValueAsBool(value);
		}
		else if (StringViewEqualsCString(&keyView, "metadata"))
		{
			validateSpec.metadata = BsonValueAsBool(value);
		}
		else if (StringViewEqualsCString(&keyView, "checkBSONConformance"))
		{
			validateSpec.checkBsonConformance = BsonValueAsBool(value);
		}
	}

	if (databaseNameDatum == (Datum) 0)
	{
		ereport(ERROR, (errmsg("Database name must not be NULL")));
	}

	validateSpec.databaseName = TextDatumGetCString(databaseNameDatum);

	if (validateSpec.collectionName == NULL || strlen(validateSpec.collectionName) == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDNAMESPACE),
						errmsg("The specified namespace is invalid: '%s'.",
							   validateSpec.databaseName)));
	}

	/* Check that validate->metadata is not specified with validateSpec->full and validateSpec->repair */
	if (validateSpec.metadata && (validateSpec.full || validateSpec.repair))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg(
							"Running the validate command with { metadata: true } is not supported with any other options")));
	}

	if (validateSpec.checkBsonConformance && validateSpec.repair)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg(
							"Cannot specify both { checkBSONConformance: true } and { repair: true }")));
	}

	MongoCollection *collection =
		GetMongoCollectionOrViewByNameDatum(PointerGetDatum(cstring_to_text(
																validateSpec.databaseName)),
											PointerGetDatum(cstring_to_text(
																validateSpec.
																collectionName)),
											AccessShareLock);

	if (collection == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_NAMESPACENOTFOUND), errmsg(
							"The collection '%s.%s' cannot be validated because it does not exist.",
							validateSpec.databaseName, validateSpec.collectionName)));
	}

	if (collection->viewDefinition != NULL)
	{
		if (validateSpec.repair)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
							errmsg(
								"Running the validate command with { repair: true } is not supported on views.")));
		}

		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTEDONVIEW),
						errmsg(
							"The namespace %s.%s refers to a view object rather than a collection",
							collection->name.databaseName,
							collection->name.collectionName)));
	}

	/* TODO: This should happen before checking for views, however EnsureCollectionOwner can't do that yet. */
	EnsureCollectionOwner(collection);

	char retryTableName[NAMEDATALEN] = { 0 };
	pg_snprintf(retryTableName, NAMEDATALEN, "retry_" INT64_FORMAT,
				collection->collectionId);
	Oid retryTableOid = get_relname_relid(retryTableName, ApiDataNamespaceOid());

	bool isRepaired = false;
	List *warnings = NIL;
	if (validateSpec.repair)
	{
		ReportFeatureUsage(FEATURE_COMMAND_VALIDATE_REPAIR);

		if (CollectionRbacBaselineReadRoleOid() == InvalidOid ||
			CollectionRbacBaselineWriteRoleOid() == InvalidOid)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED), errmsg(
								"Running the validate command with { repair: true } is not supported yet.")));
		}

		isRepaired = true;
		bool includeRetryTable = OidIsValid(retryTableOid);
		GrantCollectionPrivilegesToBaselineRoles(collection->collectionId,
												 includeRetryTable);
	}
	else if (collection != NULL && collection->viewDefinition == NULL)
	{
		Oid baselineReadRole = CollectionRbacBaselineReadRoleOid();
		Oid baselineWriteRole = CollectionRbacBaselineWriteRoleOid();
		if (OidIsValid(baselineReadRole) && OidIsValid(baselineWriteRole))
		{
			bool hasValidAcl = HasBaselineRolePrivileges(collection->relationId,
														 baselineReadRole,
														 baselineWriteRole);
			if (OidIsValid(retryTableOid))
			{
				hasValidAcl = HasBaselineRolePrivileges(retryTableOid,
														baselineReadRole,
														baselineWriteRole) &&
							  hasValidAcl;
			}

			if (!hasValidAcl)
			{
				StringInfo warning = makeStringInfo();
				appendStringInfoString(warning,
									   "Collection is missing readWriteAnyDatabase access, run repair to fix it.");
				warnings = lappend(warnings, warning);
			}
		}
	}

	StringInfo namespaceString = makeStringInfo();
	appendStringInfo(namespaceString, "%s.%s", validateSpec.databaseName,
					 validateSpec.collectionName);

	ValidateResult result;
	result.ns = namespaceString->data;
	result.isValid = list_length(warnings) == 0;
	result.isRepaired = isRepaired;
	result.indexDetailsPgbson = NULL;
	result.warnings = warnings;
	result.errors = NIL;
	result.ok = 1;


	validateCollection(collection, &result);
	pgbson *response = BuildResponseMessage(&result);
	PG_RETURN_POINTER(response);
}


static bool
HasBaselineRolePrivileges(Oid relationId, Oid baselineReadRole,
						  Oid baselineWriteRole)
{
	AclMode expectedMask = ACL_SELECT;
	AclMode aclMode = pg_class_aclmask(relationId, baselineReadRole,
									   expectedMask, ACLMASK_ALL);
	if (aclMode != expectedMask)
	{
		return false;
	}

	expectedMask = ACL_SELECT | ACL_INSERT | ACL_UPDATE | ACL_DELETE;
	aclMode = pg_class_aclmask(relationId, baselineWriteRole, expectedMask,
							   ACLMASK_ALL);
	return aclMode == expectedMask;
}


/*
 * validateCollection is the internal implementation for validating a collection.
 */
static void
validateCollection(MongoCollection *collection, ValidateResult *result)
{
	/* Validate indexes */

	/* check the indisvalid column in pg_index */
	CheckIndisvalid(collection->collectionId, result);

	/*
	 * TODO Add further index validations here:
	 * 1. Unique indexes must not have duplicate documents
	 * 2. Hashed indexes should not be multikey
	 * 3. Except for multikey indexes, number of doc entries for an index should not be greater
	 *    than num of docs in the collection
	 * 4. Number of _id index entries should be equal to number of documents in the collection
	 * 5. Except for sparse or partial indexes, num of index entries should not be lesser than
	 *    num of docs in the collection
	 */

	/*
	 * TODO Add document validations here
	 * 1. Check if the document conforms to the schema validation
	 * 2. Check if the document is corrupted
	 */
}


/*
 * CheckIndisvalid is the internal implementation for checking the indisvalid column in pg_index.
 */
static void
CheckIndisvalid(uint64 collectionId, ValidateResult *result)
{
	StringInfo cmdStr = makeStringInfo();
	appendStringInfo(cmdStr,
					 "WITH collection_pg_indexes AS "
					 "( SELECT idx.indrelid::REGCLASS, i.relname, idx.indisvalid, "
					 "( CASE "
					 "WHEN starts_with(i.relname, 'documents_rum_index_') THEN substring(i.relname, 21)::int "
					 "WHEN starts_with(i.relname, 'collection_pk_"UINT64_FORMAT
					 "') THEN (SELECT index_id from "
					 "%s.collection_indexes where collection_id = "UINT64_FORMAT
					 " AND (index_spec).index_name = '_id_') "
					 "END ) AS indexId "
					 "FROM pg_index idx "
					 "JOIN pg_class as i ON i.oid = idx.indexrelid "
					 "where indrelid::REGCLASS = '%s.documents_"UINT64_FORMAT
					 "'::REGCLASS ORDER BY idx.indrelid) "
					 "SELECT (index_spec).index_name, cpi.indisvalid "
					 "FROM collection_pg_indexes cpi "
					 "JOIN %s.collection_indexes ci ON ci.index_id = cpi.indexId "
					 "ORDER BY cpi.indexId;",
					 collectionId, ApiCatalogSchemaName, collectionId,
					 ApiDataSchemaName, collectionId, ApiCatalogSchemaName);

	pgbson_writer indexValidityWriter;
	PgbsonWriterInit(&indexValidityWriter);
	MemoryContext oldContext = CurrentMemoryContext;

	SPI_connect();
	bool readOnly = true;
	int tupleCount = 0; /* fetch all applicable rows */
	int status = SPI_execute(cmdStr->data, readOnly, tupleCount);
	bool isNull;

	if (status == SPI_OK_SELECT && SPI_tuptable->numvals > 0)
	{
		SPITupleTable *tuptable = SPI_tuptable;
		TupleDesc tupdesc = tuptable->tupdesc;

		for (uint64 row = 0; row < tuptable->numvals; row++)
		{
			HeapTuple tuple = tuptable->vals[row];

			/* There are two columns in the result
			 * 1. index_name: name of the index
			 * 2. indisvalid: if the index is valid in pg_index
			 */
			int columnNumber = 1;
			Datum indexNameDatum = SPI_getbinval(tuple, tupdesc, columnNumber, &isNull);
			char *indexName = NULL;
			bool isIndexValid = true;
			if (!isNull)
			{
				bool typeByValue = false;
				int typeLength = -1;
				indexNameDatum = SPI_datumTransfer(indexNameDatum,
												   typeByValue, typeLength);
				indexName = TextDatumGetCString(indexNameDatum);
			}

			columnNumber = 2;
			Datum indisvalidDatum = SPI_getbinval(tuple, tupdesc, columnNumber, &isNull);
			Assert(!isNull);
			isIndexValid = DatumGetBool(indisvalidDatum);

			MemoryContext spiContext = MemoryContextSwitchTo(oldContext);
			pgbson_writer writeDetailsWriter;
			PgbsonWriterStartDocument(&indexValidityWriter, indexName,
									  strlen(indexName),
									  &writeDetailsWriter);
			PgbsonWriterAppendBool(&writeDetailsWriter, "valid", 5, isIndexValid);
			PgbsonWriterEndDocument(&indexValidityWriter, &writeDetailsWriter);
			MemoryContextSwitchTo(spiContext);

			/* Update overall valid status of the validate() command*/
			result->isValid = result->isValid && isIndexValid;
		}
	}

	/* Total number of indexes */
	result->totalIndexes = SPI_tuptable->numvals;

	SPI_finish();
	pfree(cmdStr->data);
	result->indexDetailsPgbson = PgbsonWriterGetPgbson(&indexValidityWriter);
}


/*
 * Builds the pgbson response for the validate() command
 */
static pgbson *
BuildResponseMessage(ValidateResult *result)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	PgbsonWriterAppendUtf8(&writer, "ns", 2, result->ns);
	PgbsonWriterAppendInt64(&writer, "nIndexes", 8, result->totalIndexes);
	PgbsonWriterAppendDocument(&writer, "indexDetails", 12, result->indexDetailsPgbson);
	PgbsonWriterAppendBool(&writer, "valid", 5, result->isValid);
	PgbsonWriterAppendBool(&writer, "repaired", 8, result->isRepaired);

	pgbson_array_writer writeWarningsWriter;
	PgbsonWriterStartArray(&writer, "warnings", 8, &writeWarningsWriter);
	ListCell *writeWarningCell = NULL;
	foreach(writeWarningCell, result->warnings)
	{
		StringInfo warning = lfirst(writeWarningCell);
		PgbsonArrayWriterWriteUtf8(&writeWarningsWriter, warning->data);
	}
	PgbsonWriterEndArray(&writer, &writeWarningsWriter);

	pgbson_array_writer writeErrorsWriter;
	PgbsonWriterStartArray(&writer, "errors", 6, &writeErrorsWriter);
	ListCell *writeErrorCell = NULL;
	foreach(writeErrorCell, result->errors)
	{
		StringInfo error = lfirst(writeErrorCell);
		PgbsonArrayWriterWriteUtf8(&writeErrorsWriter, error->data);
	}
	PgbsonWriterEndArray(&writer, &writeErrorsWriter);

	PgbsonWriterAppendDouble(&writer, "ok", 2, result->ok);
	return PgbsonWriterGetPgbson(&writer);
}
