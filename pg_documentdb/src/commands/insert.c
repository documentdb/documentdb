/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License.
 * SPDX-License-Identifier: MIT
 *
 * src/commands/insert.c
 *
 * Implementation of the insert operation.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <funcapi.h>
#include <nodes/makefuncs.h>
#include <utils/timestamp.h>
#include <utils/portal.h>
#include <tcop/dest.h>
#include <tcop/pquery.h>
#include <tcop/tcopprot.h>
#include <commands/portalcmds.h>
#include <utils/snapmgr.h>
#include <catalog/pg_class.h>
#include <parser/parse_relation.h>
#include <storage/lmgr.h>
#include <utils/lsyscache.h>
#include <access/heaptoast.h>
#include <access/toast_internals.h>

#include "access/xact.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"

#include "io/bson_core.h"
#include "commands/commands_common.h"
#include "commands/insert.h"
#include "commands/parse_error.h"
#include "metadata/collection.h"
#include "infrastructure/documentdb_plan_cache.h"
#include "sharding/sharding.h"
#include "commands/retryable_writes.h"
#include "io/pgbsonsequence.h"
#include "utils/query_utils.h"
#include "utils/feature_counter.h"
#include "metadata/metadata_cache.h"
#include "utils/error_utils.h"
#include "utils/guc_utils.h"
#include "utils/version_utils.h"
#include "utils/documentdb_errors.h"
#include "api_hooks.h"
#include "schema_validation/schema_validation.h"
#include "operators/bson_expr_eval.h"
#include "planner/documentdb_planner.h"
#include "optimizer/plancat.h"
#include "utils/index_utils.h"
#include "rbac_hooks.h"


/*
 * BatchInsertionSpec describes a batch of insert operations.
 */
typedef struct BatchInsertionSpec
{
	/* collection in which to perform insertions */
	char *collectionName;

	/* list of documents to insert */
	List *documents;

	/* if ordered, stop after the first failure */
	bool isOrdered;

	/* The shard OID if available */
	Oid insertShardOid;

	/* if true, bypass document validation */
	bool bypassDocumentValidation;
} BatchInsertionSpec;

/*
 * BatchInsertionResult contains the results that are sent to the
 * client after a insert command.
 */
typedef struct BatchInsertionResult
{
	/* response status (seems to always be 1?) */
	double ok;

	/* number of rows insert */
	uint64 rowsInserted;

	/* list of write errors for each insertion, or NIL */
	List *writeErrors;

	/* Memory context to write results/errors to */
	MemoryContext resultMemoryContext;

	/* Logical index names resolved while processing this request */
	HTAB *indexNameCache;
} BatchInsertionResult;


PG_FUNCTION_INFO_V1(command_insert);
PG_FUNCTION_INFO_V1(command_insert_one);
PG_FUNCTION_INFO_V1(command_insert_worker);
PG_FUNCTION_INFO_V1(command_insert_bulk);
PG_FUNCTION_INFO_V1(command_insert_txn_proc);
PG_FUNCTION_INFO_V1(test_compress_bson_if_needed);


static BatchInsertionSpec * BuildBatchInsertionSpec(bson_iter_t *insertCommandIter,
													pgbsonsequence *insertDocs,
													Datum *databaseNameDatum);
static List * BuildInsertionList(bson_iter_t *insertArrayIter, bool *hasSkippedDocuments);
static List * BuildInsertionListFromPgbsonSequence(pgbsonsequence *docSequence,
												   bool *hasSkippedDocuments);
static void ProcessBatchInsertion(MongoCollection *collection,
								  BatchInsertionSpec *batchSpec,
								  text *transactionId, BatchInsertionResult *batchResult,
								  WriteMode writeMode);
static void DoBatchInsertNoTransactionId(MongoCollection *collection,
										 BatchInsertionSpec *batchSpec,
										 BatchInsertionResult *batchResult,
										 ExprEvalState *evalState,
										 WriteMode writeMode);

static uint64 ProcessInsertion(MongoCollection *collection, Oid insertShardOid, const
							   bson_value_t *document,
							   text *transactionId, ExprEvalState *evalState);
static pgbson * BuildResponseMessage(BatchInsertionResult *batchResult);
static uint64_t RunInsertQuery(Query *insertQuery, ParamListInfo paramListInfo);
static Query * CreateInsertQuery(MongoCollection *collection, Oid shardOid,
								 List *valuesLists);
static pgbson * PreprocessInsertionDoc(const bson_value_t *docValue,
									   MongoCollection *collection,
									   int64 *shardKeyHash, pgbson **objectId,
									   ExprEvalState *evalState);
static uint64 InsertOneWithTransactionCore(uint64 collectionId, const
										   char *shardTableName,
										   int64 shardKeyValue, text *transactionId,
										   pgbson *objectId, pgbson *document);
static uint64 CallInsertWorkerForInsertOne(MongoCollection *collection, int64
										   shardKeyHash,
										   pgbson *document, text *transactionId);
static pgbson * CallInsertWorkerForInsert(MongoCollection *collection, int64 shardKeyHash,
										  pgbson *document, text *transactionId,
										  pgbsonsequence *documentsequence);
static Datum CommandInsertCore(PG_FUNCTION_ARGS, WriteMode writeMode, MemoryContext
							   allocContext);
static inline List * CreateValuesListForInsert(Const *shardKey, Expr *objectId,
											   Expr *document, AttrNumber
											   creationTimeVarAttNum);
static uint64_t ExecuteLocalShardInsertPlan(PlannedStmt *queryPlan, ParamListInfo
											paramListInfo);
static PlannedStmt * CreateLocalShardInsertPlan(MongoCollection *collection, Oid
												shardOid, List *valuesLists);
static inline RangeTblEntry * CreateValueRteForInsert(MongoCollection *collection,
													  List *valuesLists);
static inline List * CreateTargetListForInsert(MongoCollection *collection);
static inline RangeTblEntry * CreateBaseTableRteForInsert(MongoCollection *collection, Oid
														  shardOid,
														  List **optionalPermInfos);
static inline void ReportInsertFeatureUsage(int batchSize);

/*
 * ApiGucPrefix.enable_create_collection_on_insert GUC determines whether
 * an insert into a non-existent collection should create a collection.
 */
bool EnableCreateCollectionOnInsert = true;
extern bool UseLocalExecutionShardQueries;
extern bool EnableBypassDocumentValidation;
extern bool SkipFailOnCollation;
extern int BatchUpdateLockTimeoutMs;
extern int32_t DocumentToastCompressionThreshold;
extern bool DefaultInlineWriteOperations;


inline static bool
DoWorkerDispatchForInsertion(MongoCollection *collection,
							 text *transactionId,
							 ExprEvalState *evalState)
{
	return DocumentToastCompressionThreshold > 0 &&
		   transactionId == NULL &&
		   evalState == NULL &&
		   collection->shardKey == NULL &&
		   collection->isShardRemote;
}


/*
 * command_insert handles the insert command invocation through a PostgreSQL function.
 *
 * Server-side implementation of the insert command never attempts to deduplicate
 * the given document/s to be inserted.
 */
Datum
command_insert(PG_FUNCTION_ARGS)
{
	ReportFeatureUsage(FEATURE_COMMAND_INSERT);
	PG_RETURN_DATUM(CommandInsertCore(fcinfo, WriteMode_Txn_Func, CurrentMemoryContext));
}


/*
 * command_insert_bulk handles the insert command invocation through a PostgreSQL procedure and commits after each batch.
 */
Datum
command_insert_bulk(PG_FUNCTION_ARGS)
{
	ReportFeatureUsage(FEATURE_COMMAND_INSERT_BULK);
	bool isTopLevel = true;
	if (IsInTransactionBlock(isTopLevel))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_OPERATIONNOTSUPPORTEDINTRANSACTION),
						errmsg("the insert procedure cannot be used in transactions."
							   " Please use the insert function instead")));
	}


	/* For results we need a stable memory context across transactions */
	MemoryContext stableContext = fcinfo->flinfo->fn_mcxt;
	Datum result = CommandInsertCore(fcinfo, WriteMode_Bulk_Proc, stableContext);

	/* If it's not transactional, pop the active snapshot created during the transaction start */
	if (ActiveSnapshotSet())
	{
		Snapshot snapshot = GetActiveSnapshot();
		if (ActivePortal != NULL && ActivePortal->portalSnapshot == snapshot)
		{
			ActivePortal->portalSnapshot = NULL;
		}

		PopActiveSnapshot();
	}

	PG_RETURN_DATUM(result);
}


/*
 * command_insert_txn_proc handles the insert command invocation through a PostgreSQL procedure.
 * this function behaves the same way as command_insert.
 */
Datum
command_insert_txn_proc(PG_FUNCTION_ARGS)
{
	ReportFeatureUsage(FEATURE_COMMAND_INSERT);

	bool isTopLevel = true;
	if (IsInTransactionBlock(isTopLevel))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_OPERATIONNOTSUPPORTEDINTRANSACTION),
						errmsg("the insert procedure cannot be used in transactions."
							   " Please use the insert function instead")));
	}

	/* Use function context as a stable memory context to store errors across transaction aborts */
	PG_RETURN_DATUM(CommandInsertCore(fcinfo, WriteMode_Txn_Proc,
									  fcinfo->flinfo->fn_mcxt));
}


/*
 * CreateCollectionForInsert creates a new collection and takes the approriate
 * lock for insert, or errors if we disabled automatic creation creation.
 */
MongoCollection *
CreateCollectionForInsert(Datum databaseNameDatum, Datum collectionNameDatum)
{
	/*
	 * If the collection does not exist, the client might prefer to handle that.
	 *
	 * This is primarily relevant when routing inserts via worker nodes. As long
	 * as Citus does not support create_distributed_table via worker nodes, we
	 * need to fall back to doing the insert via the coordinator when we get
	 * this error.
	 */
	if (!EnableCreateCollectionOnInsert)
	{
		char *collectionName = TextDatumGetCString(collectionNameDatum);

		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_TABLE),
						errmsg("The collection named %s cannot be found",
							   quote_literal_cstr(collectionName))));
	}

	/*
	 * Call ApiSchemaName.create_collection. It internally handles concurrent
	 * calls in an idempotent manner, which means that if a concurrent insert raced
	 * to create the collection before us, this will be a noop.
	 */
	bool canUseLibPq = true;
	CreateCollection(databaseNameDatum, collectionNameDatum, canUseLibPq);

	MongoCollection *collection = GetMongoCollectionByNameDatum(databaseNameDatum,
																collectionNameDatum,
																RowExclusiveLock);

	if (collection == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Unable to create the specified collection"),
						errdetail_log(
							"Could not get collection from cache after creating the collection")));
	}

	return collection;
}


/*
 * BuildBatchInsertionSpec validates the insert command BSON and builds
 * a BatchInsertionSpec.
 */
static BatchInsertionSpec *
BuildBatchInsertionSpec(bson_iter_t *insertCommandIter, pgbsonsequence *insertDocs,
						Datum *databaseNameDatum)
{
	const char *collectionName = NULL;
	List *documents = NIL;
	bool isOrdered = true;
	bool hasDocuments = false;
	bool hasSkippedDocuments = false;
	bool bypassDocumentValidation = false;

	while (bson_iter_next(insertCommandIter))
	{
		const char *field = bson_iter_key(insertCommandIter);

		if (strcmp(field, "insert") == 0)
		{
			if (!BSON_ITER_HOLDS_UTF8(insertCommandIter))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("Collection name contains an invalid data type %s",
									   BsonIterTypeName(insertCommandIter))));
			}

			uint32_t collectionNameLength = 0;
			collectionName = bson_iter_utf8(insertCommandIter, &collectionNameLength);
			ValidateNamespaceStringForEmbeddedNull(collectionName,
												   collectionNameLength);
		}
		else if (strcmp(field, "documents") == 0)
		{
			EnsureTopLevelFieldType("insert.documents", insertCommandIter,
									BSON_TYPE_ARRAY);

			/* if both docs and spec are provided, fail */
			if (insertDocs != NULL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_FAILEDTOPARSE),
								errmsg(
									"Both 'documents' and 'insert.documents' cannot be specified.")));
			}

			bson_iter_t insertArrayIter;
			bson_iter_recurse(insertCommandIter, &insertArrayIter);

			documents = BuildInsertionList(&insertArrayIter, &hasSkippedDocuments);
			hasDocuments = true;
		}
		else if (strcmp(field, "ordered") == 0)
		{
			EnsureTopLevelFieldType("insert.ordered", insertCommandIter, BSON_TYPE_BOOL);

			isOrdered = bson_iter_bool(insertCommandIter);
		}
		else if (strcmp(field, "bypassDocumentValidation") == 0)
		{
			/* TODO: unsupport by default */
			if (!EnableBypassDocumentValidation)
			{
				continue;
			}

			EnsureTopLevelFieldType("insert.bypassDocumentValidation", insertCommandIter,
									BSON_TYPE_BOOL);

			bypassDocumentValidation = bson_iter_bool(insertCommandIter);
		}
		else if (strcmp(field, "maxTimeMS") == 0)
		{
			EnsureTopLevelFieldIsNumberLike("insert.maxTimeMS", bson_iter_value(
												insertCommandIter));
			SetExplicitStatementTimeout(BsonValueAsInt32(bson_iter_value(
															 insertCommandIter)));
		}
		else if (strcmp(field, "$db") == 0)
		{
			ValidateOrExtractDatabaseNameFromSpec(insertCommandIter, databaseNameDatum);
		}
		else if (strcmp(field, "collation") == 0)
		{
			if (!SkipFailOnCollation)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
								errmsg("BSON field 'insert.%s' is an unknown field.",
									   field)));
			}
		}
		else if (IsCommonSpecIgnoredField(field))
		{
			elog(DEBUG1, "Command field not recognized: insert.%s", field);

			/*
			 *  Silently ignore now, so that clients don't break
			 *  TODO: implement me
			 *      writeConcern
			 *      comment
			 */
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
							errmsg(
								"The BSON field 'insert.%s' is not recognized as a valid field.",
								field)));
		}
	}

	if (*databaseNameDatum == (Datum) 0)
	{
		ereport(ERROR, (errmsg("Database name must not be NULL value")));
	}

	if (collectionName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_LOCATION40414),
						errmsg(
							"The BSON field 'insert.insert' is required but not provided")));
	}

	if (insertDocs != NULL)
	{
		documents = BuildInsertionListFromPgbsonSequence(insertDocs,
														 &hasSkippedDocuments);
		hasDocuments = true;
	}

	if (!hasDocuments)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_LOCATION40414),
						errmsg("BSON field 'insert.documents' is missing but "
							   "a required field")));
	}

	int insertionCount = list_length(documents);
	if ((!hasSkippedDocuments && insertionCount == 0) ||
		insertionCount > MaxWriteBatchSize)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDLENGTH),
						errmsg(
							"Write batch size must fall within the range of 1 to %d, but %d operations were provided.",
							MaxWriteBatchSize, insertionCount)));
	}

	BatchInsertionSpec *batchSpec = palloc0(sizeof(BatchInsertionSpec));

	batchSpec->collectionName = (char *) collectionName;
	batchSpec->documents = documents;
	batchSpec->isOrdered = isOrdered;
	batchSpec->bypassDocumentValidation = bypassDocumentValidation;

	return batchSpec;
}


/*
 * Validates a given document value in the insert spec and checks
 * that it can be inserted. This currently does size validation,
 * and whether or not it's a valid document to be inserted.
 * Returns true if the document should be inserted.
 */
inline static bool
ValidateAndCheckShouldInsertDocument(const bson_value_t *docValue)
{
	pgbsonelement docElement;
	if (TryGetBsonValueToPgbsonElement(docValue, &docElement) &&
		strcmp(docElement.path, "_id") == 0 &&
		docElement.bsonValue.value_type == BSON_TYPE_UNDEFINED)
	{
		/* Skip documents that are { "_id": undefined } */
		return false;
	}

	/* Validate size of incoming docs in insert */
	uint32_t size = docValue->value.v_doc.data_len;
	if (size > BSON_MAX_ALLOWED_SIZE)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("Size %u is larger than MaxDocumentSize %u",
							   size, BSON_MAX_ALLOWED_SIZE)));
	}

	return true;
}


/*
 * BuildInsertionList iterates over an array of documents in an insert spec and
 * returns a list of pgbson documents to insert.
 */
static List *
BuildInsertionList(bson_iter_t *insertArrayIter, bool *hasSkippedDocuments)
{
	List *documents = NIL;
	*hasSkippedDocuments = false;

	while (bson_iter_next(insertArrayIter))
	{
		StringInfo fieldNameStr = makeStringInfo();
		int arrIdx = list_length(documents);
		appendStringInfo(fieldNameStr, "insert.documents.%d", arrIdx);

		EnsureTopLevelFieldType(fieldNameStr->data, insertArrayIter, BSON_TYPE_DOCUMENT);
		const bson_value_t *docValue = bson_iter_value(insertArrayIter);
		if (ValidateAndCheckShouldInsertDocument(docValue))
		{
			bson_value_t *clonedValue = palloc(sizeof(bson_value_t));
			*clonedValue = *docValue;
			documents = lappend(documents, clonedValue);
		}
		else
		{
			*hasSkippedDocuments = true;
		}
	}

	return documents;
}


/*
 * BuildInsertionListFromPgbsonSequence iterates over an
 * array of documents specified in the given pgbsonsequence
 * and returns a list of pgbson documents to insert.
 */
static List *
BuildInsertionListFromPgbsonSequence(pgbsonsequence *docSequence,
									 bool *hasSkippedDocuments)
{
	*hasSkippedDocuments = false;

	List *sequenceValues = PgbsonSequenceGetDocumentBsonValues(docSequence);

	ListCell *cell;
	foreach(cell, sequenceValues)
	{
		bson_value_t *docValue = lfirst(cell);
		if (!ValidateAndCheckShouldInsertDocument(docValue))
		{
			*hasSkippedDocuments = true;
			break;
		}
	}

	/* If there were no skipped docs, no need to allocate a new
	 * array, just return the original.
	 */
	if (!*hasSkippedDocuments)
	{
		return sequenceValues;
	}

	List *documents = NIL;
	foreach(cell, sequenceValues)
	{
		bson_value_t *docValue = lfirst(cell);
		if (ValidateAndCheckShouldInsertDocument(docValue))
		{
			documents = lappend(documents, docValue);
		}
	}

	return documents;
}


/*
 * Creates the Param values for the BSON types.
 * We do this as a BYTEA param so that Citus can
 * force the bson as a binary to the worker nodes
 * which can improve perf in multi-node scenarios.
 */
inline static Expr *
CreateBsonParam(int paramIndex, ParamListInfo paramListInfo, pgbson *bsonValue)
{
	Assert(paramListInfo->numParams > paramIndex);

	Param *bsonValueParam = makeNode(Param);
	bsonValueParam->paramid = paramIndex + 1;
	bsonValueParam->paramkind = PARAM_EXTERN;
	bsonValueParam->paramtype = BYTEAOID;
	bsonValueParam->paramtypmod = -1;
	paramListInfo->params[paramIndex].isnull = false;
	paramListInfo->params[paramIndex].pflags = PARAM_FLAG_CONST;
	paramListInfo->params[paramIndex].ptype = BYTEAOID;
	paramListInfo->params[paramIndex].value = PointerGetDatum(bsonValue);
	paramIndex++;

	return (Expr *) makeRelabelType((Expr *) bsonValueParam, BsonTypeId(), -1, InvalidOid,
									COERCE_IMPLICIT_CAST);
}


/*
 * SetCompressedDocumentParam compresses the document in the given parameter if
 * needed. A compressed document is left as a runtime Param instead of a
 * constant, since constant folding during planning flattens varlena values and
 * would decompress it before it is written.
 */
static void
SetCompressedDocumentParam(ParamExternData *documentParam)
{
	Datum compressedValue = CompressBsonIfNeeded(documentParam->value);
	if (compressedValue != documentParam->value)
	{
		documentParam->value = compressedValue;
		documentParam->pflags = 0;
	}
}


/*
 * Applies a set of inserts in a single transaction.
 * This applies without the case of retriable writes. In this case we just
 * directly call INSERT from the coordinator on a batch of documents.
 * This is an optimistic batch. On failures, we simply bail and go back to
 * A single document insert. This is because Mongo requires that we return
 * the failures associated with each insert back to the client while inserting
 * everything before it. Postgres rollsback the entire sub-transaction.
 * TODO: While we can optimize this by treating the sub-batch that succeeded first
 * and moving forward, this is left as an optimization for the future.
 */
static void
DoMultiInsertWithoutTransactionIdCore(MongoCollection *collection, List *inserts,
									  Oid shardOid, int insertIndex,
									  int *insertCountResult, int *insertIncrIndex,
									  ExprEvalState *evalState)
{
	int insertInnerIndex = insertIndex;
	int insertCount = 0;
	List *valuesList = NIL;
	ListCell *insertCell;

	/* Make params for all the BSONs - we have 2 per insert - objectId/insertDoc */
	int expectedNumParams = Min(list_length(inserts), BatchWriteSubTransactionCount);
	ParamListInfo paramListInfo = makeParamList(expectedNumParams * 2);
	int paramIndex = 0;
	while (insertInnerIndex < list_length(inserts) &&
		   insertCount < BatchWriteSubTransactionCount)
	{
		insertCell = list_nth_cell(inserts, insertInnerIndex);
		const bson_value_t *documentValue = lfirst(insertCell);

		int64_t shardKeyValue;
		pgbson *objectId;
		pgbson *insertDoc =
			PreprocessInsertionDoc(documentValue, collection, &shardKeyValue,
								   &objectId, evalState);

		/* Generate a values lists for the insert as
		 * VALUES(shard_key_value, object_id, document, creationTime)
		 */
		Const *shardKeyConst = makeConst(INT8OID, -1, InvalidOid, 8,
										 Int64GetDatum(shardKeyValue), false, true);
		Expr *objectidParam = CreateBsonParam(paramIndex, paramListInfo, objectId);
		paramIndex++;

		Expr *documentParam = CreateBsonParam(paramIndex, paramListInfo, insertDoc);
		SetCompressedDocumentParam(&paramListInfo->params[paramIndex]);

		paramIndex++;

		List *values = CreateValuesListForInsert(shardKeyConst, objectidParam,
												 documentParam,
												 collection->
												 mongoDataCreationTimeVarAttrNumber);

		valuesList = lappend(valuesList, values);
		insertCount++;
		insertInnerIndex++;
	}

	*insertIncrIndex = insertInnerIndex;
	paramListInfo->numParams = paramIndex;

	uint64_t rowsProcessed = 0;
	if (shardOid == InvalidOid)
	{
		Query *query = CreateInsertQuery(collection, shardOid,
										 valuesList);
		rowsProcessed = RunInsertQuery(query, paramListInfo);
	}
	else
	{
		ThrowIfWriteCommandNotAllowed();

		PlannedStmt *queryPlan = CreateLocalShardInsertPlan(collection,
															shardOid, valuesList);
		rowsProcessed = ExecuteLocalShardInsertPlan(queryPlan, paramListInfo);
	}

	/* Merge inner batchResult with outer batchResult */
	*insertCountResult = rowsProcessed;
	list_free_deep(valuesList);
	pfree(paramListInfo);
}


static void
DoMultiInsertWithoutTransactionViaInsertWorker(MongoCollection *collection, List *inserts,
											   int insertIndex, int *insertCountResult,
											   int *insertIncrIndex)
{
	/* Serialize the batch to a worker spec */
	Assert(collection->shardKey == NULL);
	int batchCount = Min(BatchWriteSubTransactionCount, list_length(inserts) -
						 insertIndex);
	*insertIncrIndex = insertIndex + batchCount;
	pgbsonsequence *batchSequence = PgbsonSequenceBuildFromBsonValuesList(inserts,
																		  insertIndex,
																		  batchCount);
	text *transactionId = NULL;
	int64 shardKeyHash = collection->collectionId;

	pgbsonelement element = { 0 };
	element.path = "insertMany";
	element.pathLength = 10;
	element.bsonValue.value_type = BSON_TYPE_INT64;
	element.bsonValue.value.v_int64 = (int64_t) collection->collectionId;
	pgbson *specDocument = PgbsonElementToPgbson(&element);
	pgbson *result = CallInsertWorkerForInsert(collection, shardKeyHash, specDocument,
											   transactionId,
											   batchSequence);
	pgbsonelement resultElement;
	PgbsonToSinglePgbsonElement(result, &resultElement);
	if (strcmp(resultElement.path, "n") != 0 ||
		resultElement.bsonValue.value_type != BSON_TYPE_INT32 ||
		resultElement.bsonValue.value.v_int32 != batchCount)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg(
							"insert_worker returned an unexpected batch insert count")));
	}

	*insertCountResult = resultElement.bsonValue.value.v_int32;
	pfree(result);
	pfree(batchSequence);
	pfree(specDocument);
}


static bool
DoMultiInsertWithoutTransactionId(MongoCollection *collection, List *inserts,
								  Oid shardOid,
								  BatchInsertionResult *batchResult, int insertIndex,
								  int *insertCountResult, int *insertIncrIndex,
								  ExprEvalState *evalState, WriteMode writeMode)
{
	*insertCountResult = 0;
	MemoryContext oldContext = CurrentMemoryContext;
	ResourceOwner oldOwner = CurrentResourceOwner;

	BeginInternalSubTransaction(NULL);

	PG_TRY();
	{
		if (writeMode == WriteMode_Bulk_Proc)
		{
			/* Set lock timeout inside the subtransaction so it is
			 * automatically reverted on rollback. */
			char *batchLockTimeoutStr = psprintf("%d", BatchUpdateLockTimeoutMs);
			SetGUCLocally("lock_timeout", batchLockTimeoutStr);
		}

		text *transactionId = NULL;
		if (DoWorkerDispatchForInsertion(collection, transactionId, evalState))
		{
			DoMultiInsertWithoutTransactionViaInsertWorker(collection, inserts,
														   insertIndex, insertCountResult,
														   insertIncrIndex);
		}
		else
		{
			DoMultiInsertWithoutTransactionIdCore(collection, inserts, shardOid,
												  insertIndex, insertCountResult,
												  insertIncrIndex, evalState);
		}

		/* Commit the inner transaction, return to outer xact context */
		batchResult->rowsInserted += *insertCountResult;
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldContext);
		CurrentResourceOwner = oldOwner;
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldContext);
		ErrorData *errorData = CopyErrorDataAndFlush();

		/* Abort inner transaction */
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldContext);
		CurrentResourceOwner = oldOwner;
		*insertCountResult = 0;

		if (IsOperatorInterventionError(errorData))
		{
			ReThrowError(errorData);
		}

		int errorCode = errorData->sqlerrcode;
		if (EreportCodeIsDocumentDBError(errorCode))
		{
			/*
			 * TODO: Since there is no mapping from PG error to mongo error today in engine,
			 * we can't deduce the mongo specific error code.
			 */
			elog_unredacted(
				"Batch insert failed; retrying sub-batch individually. Batch size: %d, start index: %d, DocumentDB error code: %d",
				list_length(inserts), insertIndex, errorCode);
		}
		else
		{
			elog_unredacted(
				"Batch insert failed; retrying sub-batch individually. Batch size: %d, start index: %d, SQL error code: %d",
				list_length(inserts), insertIndex, errorCode);
		}
	}
	PG_END_TRY();

	return *insertCountResult != 0;
}


/*
 * Performs a single insert; if it fails, rolls back the change.
 * Applicable only for inserts invoked via a procedure.
 *
 * Applicable only when the insert batch contains a single document.
 */
static bool
DoSingleInsert(MongoCollection *collection,
			   Oid insertShardOid,
			   const bson_value_t *document,
			   text *transactionId,
			   BatchInsertionResult *batchResult, int insertIndex,
			   ExprEvalState *evalState)
{
	/* declared volatile because of the longjmp in PG_CATCH */
	volatile bool isSuccess = false;
	volatile uint64 numDocsInserted = 0;


	PG_TRY();
	{
		numDocsInserted = ProcessInsertion(collection, insertShardOid, document,
										   transactionId, evalState);
		batchResult->rowsInserted += numDocsInserted;
		isSuccess = true;
	}
	PG_CATCH();
	{
		MemoryContext oldContext = MemoryContextSwitchTo(
			batchResult->resultMemoryContext);
		ErrorData *errorData = CopyErrorDataAndFlush();
		MemoryContextSwitchTo(oldContext);

		if (IsOperatorInterventionError(errorData))
		{
			ReThrowError(errorData);
		}

		PopAllActiveSnapshots();
		AbortCurrentTransaction();
		StartTransactionCommand();

		oldContext = MemoryContextSwitchTo(batchResult->resultMemoryContext);
		batchResult->writeErrors = lappend(batchResult->writeErrors,
										   GetWriteErrorFromErrorData(errorData,
																	  insertIndex,
																	  batchResult->
																	  resultMemoryContext,
																	  &batchResult->
																	  indexNameCache));
		MemoryContextSwitchTo(oldContext);
		FreeErrorData(errorData);
		isSuccess = false;
	}
	PG_END_TRY();
	return isSuccess;
}


/*
 * Applies a single insert in a single sub-transaction.
 */
static bool
DoSingleInsertWithSubTxn(MongoCollection *collection,
						 Oid insertShardOid,
						 const bson_value_t *document,
						 text *transactionId,
						 BatchInsertionResult *batchResult, int insertIndex,
						 ExprEvalState *evalState)
{
	/* declared volatile because of the longjmp in PG_CATCH */
	volatile bool isSuccess = false;
	volatile uint64 numDocsInserted = 0;

	/* use a subtransaction to correctly handle failures */
	MemoryContext oldContext = CurrentMemoryContext;
	ResourceOwner oldOwner = CurrentResourceOwner;
	BeginInternalSubTransaction(NULL);

	PG_TRY();
	{
		numDocsInserted = ProcessInsertion(collection, insertShardOid, document,
										   transactionId, evalState);

		/* Commit the inner transaction, return to outer xact context */
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldContext);
		CurrentResourceOwner = oldOwner;
		batchResult->rowsInserted += numDocsInserted;
		isSuccess = true;
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldContext);
		ErrorData *errorData = CopyErrorDataAndFlush();

		/* Abort inner transaction */
		RollbackAndReleaseCurrentSubTransaction();
		CurrentResourceOwner = oldOwner;
		if (IsOperatorInterventionError(errorData))
		{
			ReThrowError(errorData);
		}

		MemoryContextSwitchTo(batchResult->resultMemoryContext);
		batchResult->writeErrors = lappend(batchResult->writeErrors,
										   GetWriteErrorFromErrorData(errorData,
																	  insertIndex,
																	  batchResult->
																	  resultMemoryContext,
																	  &batchResult->
																	  indexNameCache));
		MemoryContextSwitchTo(oldContext);
		FreeErrorData(errorData);
		isSuccess = false;
	}
	PG_END_TRY();
	return isSuccess;
}


/*
 * ProcessBatchInsertion iterates over the inserts array and executes each
 * insertion in a subtransaction, to allow us to continue after an error.
 *
 * If batchSpec->isOrdered is false, we continue with remaining tasks and
 * track the error for the response.
 *
 * Using subtransactions is slightly different from Mongo, which effectively
 * does each insert operation in a separate transaction, but it has roughly
 * the same overall UX.
 */
static void
ProcessBatchInsertion(MongoCollection *collection, BatchInsertionSpec *batchSpec,
					  text *transactionId, BatchInsertionResult *batchResult,
					  WriteMode writeMode)
{
	batchResult->ok = 1;
	batchResult->rowsInserted = 0;
	batchResult->writeErrors = NIL;

	ExprEvalState *evalState = NULL;

	/* Document validation occurs regardless of whether the validation action is set to error or warn.
	 * If validation fails and the action is error, an error is thrown; if the action is warn, a warning is logged.
	 * Since we do not need to log a warning in this context, we will avoid calling ValidateSchemaOnDocumentInsert when the validation action is set to warn.
	 */
	if (CheckSchemaValidationEnabled(collection, batchSpec->bypassDocumentValidation))
	{
		evalState = PrepareForSchemaValidation(
			collection->schemaValidator.validator, batchResult->resultMemoryContext,
			collection->options.collationString);
	}

	/*
	 * We cannot pass the same transactionId to BatchInsert when there are
	 * multiple inserts, since they would be considered retries of each
	 * other. We pass NULL for batch insert to disable retryable writes.
	 */
	if (list_length(batchSpec->documents) == 1)
	{
		/* So at this point, we have a single document */
		int insertIndex = 0;
		if (writeMode == WriteMode_Txn_Proc && transactionId == NULL)
		{
			DoSingleInsert(collection, batchSpec->insertShardOid,
						   linitial(batchSpec->documents), transactionId,
						   batchResult, insertIndex, evalState);
		}
		else
		{
			ereport(DEBUG1, (errmsg("Using single insert with subtransaction")));
			DoSingleInsertWithSubTxn(collection, batchSpec->insertShardOid,
									 linitial(batchSpec->documents), transactionId,
									 batchResult, insertIndex, evalState);
		}
	}
	else
	{
		/* The else scenario - we have no transactionId (or we ignore it)
		 * and/or we have more than 1 document. Do a batch insert directly.
		 */
		DoBatchInsertNoTransactionId(collection, batchSpec, batchResult, evalState,
									 writeMode);
	}

	if (evalState != NULL)
	{
		FreeExprEvalState(evalState, batchResult->resultMemoryContext);
	}
}


/*
 * Process an insertion for batch of inserts using the INSERT command.
 */
static void
DoBatchInsertNoTransactionId(MongoCollection *collection, BatchInsertionSpec *batchSpec,
							 BatchInsertionResult *batchResult, ExprEvalState *evalState,
							 WriteMode writeMode)
{
	List *insertions = batchSpec->documents;
	bool isOrdered = batchSpec->isOrdered;

	int insertIndex = 0;
	int singleInsertFailureCount = 0;
	int insertIncrIndex = -1;
	bool hasBatchedInsertFailed = false;

	ListCell *insertCell = NULL;
	while (insertIndex < list_length(insertions))
	{
		CHECK_FOR_INTERRUPTS();

		if (writeMode == WriteMode_Bulk_Proc && insertIndex > 0)
		{
			/* For each iteration of the loop, commit prior work */
			bool setSnapshot = true;
			CommitWriteProcedureAndReacquireCollectionLock(collection,
														   batchSpec->insertShardOid,
														   setSnapshot);
		}

		if (list_length(insertions) > 1 && !hasBatchedInsertFailed)
		{
			/* Optimistically try to do multiple updates together, if it fails, try again one by one to figure out which one failed */
			int incrementCount = 0;
			int failedBatchIndexEnd = -1;
			bool performedBatchInsert = DoMultiInsertWithoutTransactionId(collection,
																		  insertions,
																		  batchSpec->
																		  insertShardOid,
																		  batchResult,
																		  insertIndex,
																		  &incrementCount,
																		  &
																		  failedBatchIndexEnd,
																		  evalState,
																		  writeMode);

			Assert(!performedBatchInsert || incrementCount > 0);
			if (!performedBatchInsert)
			{
				/* Has a failure, set hasFailures and retry */
				hasBatchedInsertFailed = true;
				insertIncrIndex = failedBatchIndexEnd;
			}
			else
			{
				insertIndex += incrementCount;
				continue;
			}
		}

		insertCell = list_nth_cell(insertions, insertIndex);
		const bson_value_t *document = lfirst(insertCell);
		text *transactionId = NULL;
		bool isSuccess = DoSingleInsertWithSubTxn(collection, batchSpec->insertShardOid,
												  document,
												  transactionId, batchResult,
												  insertIndex, evalState);
		insertIndex++;

		if (!isSuccess)
		{
			singleInsertFailureCount++;
			if (isOrdered)
			{
				/* stop trying insert operations after a failure if using ordered:true */
				break;
			}
		}

		if (hasBatchedInsertFailed && insertIndex >= insertIncrIndex)
		{
			elog_unredacted(
				"Single-insert retries for the current sub-batch encountered %d failures",
				singleInsertFailureCount);

			insertIncrIndex = -1;
			hasBatchedInsertFailed = false;
			singleInsertFailureCount = 0;
		}
	}

	if (hasBatchedInsertFailed)
	{
		elog_unredacted(
			"Single-insert retries for the current sub-batch encountered %d failures",
			singleInsertFailureCount);
	}
}


inline static bool
DocumentDatumNeedsCompression(Datum inputDatum)
{
	Size varSize = VARSIZE(DatumGetPointer(inputDatum));
	return DocumentToastCompressionThreshold > 0 &&
		   varSize > (Size) DocumentToastCompressionThreshold &&
		   varSize < TOAST_TUPLE_THRESHOLD;
}


/*
 * CompressBsonIfNeeded returns an inline compressed copy of the document if it
 * exceeds the configured compression threshold but is small enough that the
 * heap would not compress it on its own. Returns the input otherwise, including
 * when compression does not reduce the size.
 */
Datum
CompressBsonIfNeeded(Datum inputDatum)
{
	if (DocumentDatumNeedsCompression(inputDatum))
	{
		Datum compressedDatum = toast_compress_datum(inputDatum,
													 default_toast_compression);
		if (DatumGetPointer(compressedDatum) != NULL)
		{
			return compressedDatum;
		}
	}

	return inputDatum;
}


/*
 * test_compress_bson_if_needed is a test only function that returns the input
 * document compressed with CompressBsonIfNeeded. It is not part of the
 * extension schema and is created by tests that need it.
 */
Datum
test_compress_bson_if_needed(PG_FUNCTION_ARGS)
{
	pgbson *document = PG_GETARG_PGBSON(0);
	PG_RETURN_DATUM(CompressBsonIfNeeded(PointerGetDatum(document)));
}


/*
 * IsDocumentCompressionEligible returns true if writes to the given target can
 * pass the document as a compressed bson parameter. The bson type is only used
 * as a parameter type when the write executes locally.
 */
bool
IsDocumentCompressionEligible(const char *shardTableName)
{
	if (DocumentToastCompressionThreshold <= 0)
	{
		return false;
	}

	return (shardTableName != NULL && shardTableName[0] != '\0') ||
		   DefaultInlineWriteOperations;
}


/*
 * ExecuteSPIPlanWithCompressedDocument executes the plan with the document
 * argument at documentArgIndex compressed if needed. Parameters flagged
 * PARAM_FLAG_CONST are folded into Const nodes when the plan cache builds a
 * custom plan, and makeConst flattens varlena values, which decompresses the
 * document. The document is therefore left as a runtime Param so that the
 * compressed datum reaches the heap as is. None of the arguments can be null.
 */
int
ExecuteSPIPlanWithCompressedDocument(SPIPlanPtr plan, Datum *argValues, Oid *argTypes,
									 int argCount, int documentArgIndex, bool readOnly,
									 long maxTupleCount)
{
	Assert(documentArgIndex >= 0 && documentArgIndex < argCount);

	ParamListInfo paramList = makeParamList(argCount);
	paramList->numParams = argCount;
	for (int i = 0; i < argCount; i++)
	{
		paramList->params[i].value = argValues[i];
		paramList->params[i].isnull = false;
		paramList->params[i].ptype = argTypes[i];
		paramList->params[i].pflags = PARAM_FLAG_CONST;
	}

	if (DocumentToastCompressionThreshold > 0)
	{
		paramList->params[documentArgIndex].value =
			CompressBsonIfNeeded(argValues[documentArgIndex]);
		paramList->params[documentArgIndex].pflags = 0;
	}
	else
	{
		paramList->params[documentArgIndex].value = argValues[documentArgIndex];
		paramList->params[documentArgIndex].pflags = PARAM_FLAG_CONST;
	}

	int spiStatus = SPI_execute_plan_with_paramlist(plan, paramList, readOnly,
													maxTupleCount);
	pfree(paramList);
	return spiStatus;
}


static uint64
ProcessInsertionCore(MongoCollection *collection,
					 Oid optionalInsertShardOid,
					 int64 shardKeyHash,
					 pgbson *objectIdPtr,
					 pgbson *insertDoc,
					 ExprEvalState *evalState)
{
	/*
	 * If retry is NULL then we don't really need to call insert_one on the worker, and then
	 * have that call INSERT - we can just do that directly from the coordinator (which probably
	 * saves one query parsing and planning per document).
	 */
	Const *shardKeyConst = makeConst(INT8OID, -1, InvalidOid, 8,
									 Int64GetDatum(shardKeyHash), false, true);

	List *singleInsertList = NULL;
	uint64_t insertResult = 0;

	ParamListInfo paramListInfo = makeParamList(2);
	paramListInfo->numParams = 2;
	Expr *objectidParam = CreateBsonParam(0, paramListInfo, objectIdPtr);
	Expr *documentParam = CreateBsonParam(1, paramListInfo, insertDoc);

	SetCompressedDocumentParam(&paramListInfo->params[1]);

	singleInsertList = CreateValuesListForInsert(shardKeyConst, objectidParam,
												 documentParam,
												 collection->
												 mongoDataCreationTimeVarAttrNumber);

	if (optionalInsertShardOid == InvalidOid)
	{
		Query *query = CreateInsertQuery(collection, optionalInsertShardOid,
										 list_make1(
											 singleInsertList));
		insertResult = RunInsertQuery(query, paramListInfo);
	}
	else
	{
		ThrowIfWriteCommandNotAllowed();

		PlannedStmt *queryPlan = CreateLocalShardInsertPlan(collection,
															optionalInsertShardOid,
															list_make1(
																singleInsertList));
		insertResult = ExecuteLocalShardInsertPlan(queryPlan, paramListInfo);
	}
	pfree(paramListInfo);
	list_free_deep(singleInsertList);
	return insertResult;
}


/*
 * ProcessInsertion processes a single insertion operation.
 */
static uint64
ProcessInsertion(MongoCollection *collection,
				 Oid optionalInsertShardOid,
				 const bson_value_t *documentValue,
				 text *transactionId, ExprEvalState *evalState)
{
	if (transactionId != NULL &&
		collection->shardKey != NULL &&
		!DocumentBsonValueHasDocumentId(documentValue) &&
		PgbsonHasDocumentId(collection->shardKey))
	{
		RetryableWriteResult writeResult;

		/*
		 * This edge case is slightly problematic: We have a collection that is
		 * sharded by _id, but the document does not specify an _id so we will
		 * generate one randomly. If this is the second try, we do not know which
		 * shard holds the retry record, so we search all of them.
		 *
		 * Clients can prevent this by setting the object ID.
		 */
		if (FindRetryRecordInAnyShard(collection->collectionId, transactionId,
									  &writeResult))
		{
			return writeResult.rowsAffected;
		}
	}

	int64 shardKeyHash;
	pgbson *objectIdPtr = NULL;
	pgbson *insertDoc = PreprocessInsertionDoc(documentValue, collection, &shardKeyHash,
											   &objectIdPtr, evalState);

	/* make sure the document has an _id and it is in the right place */

	/* If there's compression required, and it's a remote *unsharded* collection,
	 * use the insertOne path to let the insert go to the local shard so we can compress
	 * before passing it on to PG.
	 */
	if (DoWorkerDispatchForInsertion(collection, transactionId, evalState) &&
		DocumentDatumNeedsCompression(PointerGetDatum(insertDoc)))
	{
		return CallInsertWorkerForInsertOne(collection, shardKeyHash, insertDoc,
											transactionId);
	}

	if (transactionId == NULL)
	{
		return ProcessInsertionCore(collection, optionalInsertShardOid,
									shardKeyHash, objectIdPtr,
									insertDoc, evalState);
	}
	else
	{
		return CallInsertWorkerForInsertOne(collection, shardKeyHash, insertDoc,
											transactionId);
	}
}


/* core implementation of insert command */
static Datum
CommandInsertCore(PG_FUNCTION_ARGS, WriteMode writeMode, MemoryContext allocContext)
{
	if (PG_ARGISNULL(1))
	{
		ereport(ERROR, (errmsg("insert document cannot be NULL")));
	}

	ThrowIfServerOrTransactionReadOnly();

	pgbson *insertSpec = PG_GETARG_PGBSON(1);
	Datum databaseNameDatum = PG_ARGISNULL(0) ? (Datum) 0 : PG_GETARG_DATUM(0);

	pgbsonsequence *insertDocs = PG_GETARG_MAYBE_NULL_PGBSON_SEQUENCE(2);

	text *transactionId = NULL;
	if (!PG_ARGISNULL(3))
	{
		transactionId = PG_GETARG_TEXT_P(3);
	}

	/* fetch TupleDesc for return value, not interested in resultTypeId */
	Oid *resultTypeId = NULL;
	TupleDesc resultTupDesc;
	TypeFuncClass resultTypeClass =
		get_call_result_type(fcinfo, resultTypeId, &resultTupDesc);

	if (resultTypeClass != TYPEFUNC_COMPOSITE)
	{
		ereport(ERROR, (errmsg("return type must be a row type")));
	}

	bson_iter_t insertCommandIter;
	PgbsonInitIterator(insertSpec, &insertCommandIter);
	MemoryContext oldContext = MemoryContextSwitchTo(allocContext);

	/* we first validate insert command BSON and build a specification */
	BatchInsertionSpec *batchSpec = BuildBatchInsertionSpec(&insertCommandIter,
															insertDocs,
															&databaseNameDatum);

	ReportInsertFeatureUsage(list_length(batchSpec->documents));
	BatchInsertionResult batchResult;
	batchResult.resultMemoryContext = allocContext;
	batchResult.indexNameCache = NULL;
	MemoryContextSwitchTo(oldContext);
	if (list_length(batchSpec->documents) == 0)
	{
		/* Don't create the collection if there are no documents to insert */
		batchResult.rowsInserted = 0;
		batchResult.ok = 1;
		batchResult.writeErrors = NIL;
	}
	else
	{
		/* open collection */
		Datum collectionNameDatum = CStringGetTextDatum(batchSpec->collectionName);
		MongoCollection *collection =
			GetMongoCollectionByNameDatum(databaseNameDatum, collectionNameDatum,
										  RowExclusiveLock);

		if (collection == NULL)
		{
			collection = CreateCollectionForInsert(databaseNameDatum,
												   collectionNameDatum);
		}
		else
		{
			batchSpec->insertShardOid = TryGetCollectionShardTable(collection,
																   RowExclusiveLock);
		}

		/* execute data inserts */
		ProcessBatchInsertion(collection, batchSpec, transactionId, &batchResult,
							  writeMode);
	}

	Datum values[2];
	bool isNulls[2] = { false, false };

	values[0] = PointerGetDatum(BuildResponseMessage(&batchResult));
	values[1] = BoolGetDatum(batchResult.writeErrors == NIL);
	HeapTuple resultTuple = heap_form_tuple(resultTupDesc, values, isNulls);
	return HeapTupleGetDatum(resultTuple);
}


static pgbson *
CallInsertWorkerForInsert(MongoCollection *collection, int64 shardKeyHash,
						  pgbson *specDocument, text *transactionId,
						  pgbsonsequence *documentsequence)
{
	int argCount = 6;
	Datum argValues[6];

	/* whitespace means not null, n means null */
	char argNulls[6] = { ' ', ' ', ' ', ' ', 'n', 'n' };
	Oid argTypes[6] = { INT8OID, INT8OID, REGCLASSOID, BYTEAOID, BYTEAOID, TEXTOID };

	const char *updateQuery = FormatSqlQuery(
		" SELECT %s.insert_worker($1, $2, $3, $4::%s.bson, $5::%s.bsonsequence, $6) FROM %s.documents_"
		UINT64_FORMAT " WHERE shard_key_value = %ld",
		DocumentDBApiInternalSchemaName, CoreSchemaNameV2, CoreSchemaNameV2,
		ApiDataSchemaName, collection->collectionId,
		shardKeyHash);

	argValues[0] = UInt64GetDatum(collection->collectionId);

	/* p_shard_key_value */
	argValues[1] = Int64GetDatum(shardKeyHash);

	/* p_shard_oid */
	argValues[2] = ObjectIdGetDatum(InvalidOid);

	/* p_spec_document */
	argValues[3] = PointerGetDatum(specDocument);

	if (documentsequence != NULL)
	{
		argValues[4] = PointerGetDatum(documentsequence);
		argNulls[4] = ' ';
	}

	if (transactionId != NULL)
	{
		argValues[5] = PointerGetDatum(transactionId);
		argNulls[5] = ' ';
	}

	bool readOnly = false;

	Datum resultDatum[1] = { 0 };
	bool isNulls[1] = { false };
	int numResults = 1;

	/* forceDelegation assumes nested distribution */
	RunMultiValueQueryWithNestedDistribution(updateQuery, argCount, argTypes, argValues,
											 argNulls,
											 readOnly, SPI_OK_SELECT, resultDatum,
											 isNulls, numResults);

	if (isNulls[0])
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("insert_worker should not return null")));
	}

	/* If we got here, then it succeeded and inserted */
	return DatumGetPgBson(resultDatum[0]);
}


static uint64
CallInsertWorkerForInsertOne(MongoCollection *collection, int64 shardKeyHash,
							 pgbson *document, text *transactionId)
{
	pgbsonsequence *documentsequence = NULL;

	/* We just send the document for now */
	pgbsonelement element = { 0 };
	element.path = "insertOne";
	element.pathLength = 9;
	element.bsonValue = ConvertPgbsonToBsonValue(document);
	pgbson *specDocument = PgbsonElementToPgbson(&element);
	pgbson *bson = CallInsertWorkerForInsert(collection, shardKeyHash, specDocument,
											 transactionId, documentsequence);
	pfree(specDocument);
	pfree(bson);
	return 1;
}


/*
 * command_insert_one is the internal implementation of the db.collection.insertOne() API.
 */
Datum
command_insert_one(PG_FUNCTION_ARGS)
{
	ereport(ERROR, (errmsg("insert_one is deprecated and should not be called")));
}


static uint64
InsertOneWithTransactionCore(uint64 collectionId, const char *shardTableName,
							 int64 shardKeyValue, text *transactionId,
							 pgbson *objectId, pgbson *document)
{
	RetryableWriteResult writeResult;

	/*
	 * If a retry record exists, delete it since only a single retry is allowed.
	 */
	if (DeleteRetryRecord(collectionId, shardKeyValue, transactionId, &writeResult))
	{ }
	else
	{
		/* no retry record exists, insert the document */
		InsertDocument(collectionId, shardTableName, shardKeyValue, objectId, document);

		/* we always insert 1 row */
		bool rowsAffected = true;

		/* remember that transaction performed the insert */
		InsertRetryRecord(collectionId, shardKeyValue, transactionId, objectId,
						  rowsAffected, NULL);
	}

	return 1;
}


static void
DoInsertWorkerInsertOne(Oid shardOid, text *transactionId, pgbsonelement element,
						int64_t shardKeyValue, uint64_t collectionId)
{
	const char *localShardTable = NULL;
	if (UseLocalExecutionShardQueries)
	{
		localShardTable = get_rel_name(shardOid);
	}

	if (transactionId != NULL)
	{
		pgbson *document = PgbsonInitFromDocumentBsonValue(&element.bsonValue);
		pgbson *objectId = PgbsonGetDocumentId(document);
		InsertOneWithTransactionCore(collectionId, localShardTable, shardKeyValue,
									 transactionId, objectId,
									 document);
	}
	else
	{
		/* The direct insert plan bypasses the planner's write-lock acquisition. */
		LockRelationOid(shardOid, RowExclusiveLock);
		MongoCollection *mongoCollection = GetMongoCollectionByColId(collectionId,
																	 NoLock);

		if (mongoCollection == NULL)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Collection not found for collectionId %lu on command_insert_worker. This could be a metadata sync issue",
								collectionId),
							errdetail_log(
								"Collection not found for collectionId %lu on command_insert_worker. This could be a metadata sync issue.",
								collectionId)));
		}

		UpdateMongoCollectionUsingIds(mongoCollection, collectionId, shardOid);

		/* Call the core insertion function for nested distribution */
		pgbson *document = PgbsonInitFromDocumentBsonValue(&element.bsonValue);
		pgbson *objectId = PgbsonGetDocumentId(document);
		ExprEvalState *evalState = NULL;
		ProcessInsertionCore(mongoCollection, shardOid,
							 shardKeyValue, objectId,
							 document, evalState);
	}
}


Datum
command_insert_worker(PG_FUNCTION_ARGS)
{
	uint64 collectionId = PG_GETARG_INT64(0);
	int64 shardKeyValue = PG_GETARG_INT64(1);
	Oid shardOid = PG_GETARG_OID(2);

	pgbson *insertInternalSpec = PG_GETARG_PGBSON_PACKED(3);
	text *transactionId = PG_ARGISNULL(5) ? NULL : PG_GETARG_TEXT_P(5);

	if (shardOid == InvalidOid)
	{
		/* The planner is expected to replace this */
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Explicit shardOid must be set - this is a server bug"),
						errdetail_log(
							"Explicit shardOid must be set - this is a server bug")));
	}

	ThrowIfServerOrTransactionReadOnly();
	AllowNestedDistributionInCurrentTransaction();
	pgbsonelement element = { 0 };
	PgbsonToSinglePgbsonElement(insertInternalSpec, &element);

	if (strcmp(element.path, "insertOne") == 0)
	{
		if (element.bsonValue.value_type != BSON_TYPE_DOCUMENT)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Only insertOne with a single document on the worker is supported currently")));
		}

		DoInsertWorkerInsertOne(shardOid, transactionId, element, shardKeyValue,
								collectionId);
		PG_RETURN_POINTER(PgbsonInitEmpty());
	}
	else if (strcmp(element.path, "insertMany") == 0)
	{
		if (PG_ARGISNULL(4) || transactionId != NULL ||
			element.bsonValue.value_type != BSON_TYPE_INT64 ||
			element.bsonValue.value.v_int64 != (int64) collectionId)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Invalid insertMany worker specification")));
		}

		LockRelationOid(shardOid, RowExclusiveLock);
		MongoCollection *collection = GetMongoCollectionByColId(collectionId, NoLock);
		if (collection == NULL)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Collection not found for collectionId %lu on command_insert_worker",
								collectionId)));
		}

		pgbsonsequence *insertSequence = PG_GETARG_PGBSON_SEQUENCE(4);
		List *inserts = PgbsonSequenceGetDocumentBsonValues(insertSequence);
		if (inserts == NIL)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"insertMany worker requires a nonempty document sequence")));
		}

		int insertIndex = 0;
		int rowsInserted = 0;
		ExprEvalState *evalState = NULL;

		/* Consume the whole sequence even if this session uses a smaller batch limit. */
		while (insertIndex < list_length(inserts))
		{
			CHECK_FOR_INTERRUPTS();
			int insertCountResult = 0;
			int insertIncrIndex = insertIndex;
			DoMultiInsertWithoutTransactionIdCore(collection, inserts, shardOid,
												  insertIndex,
												  &insertCountResult, &insertIncrIndex,
												  evalState);
			rowsInserted += insertCountResult;
			insertIndex = insertIncrIndex;
		}

		pgbson_writer resultWriter;
		PgbsonWriterInit(&resultWriter);
		PgbsonWriterAppendInt32(&resultWriter, "n", 1, rowsInserted);
		PG_RETURN_POINTER(PgbsonWriterGetPgbson(&resultWriter));
	}
	else
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Unsupported insert worker specification")));
	}

	PG_RETURN_POINTER(PgbsonInitEmpty());
}


/*
 * InsertDocument adds a new document into the specified collection.
 */
bool
InsertDocument(uint64 collectionId, const char *shardTableName,
			   int64 shardKeyValue, pgbson *objectId,
			   pgbson *document)
{
	StringInfoData query;
	const int argCount = 3;
	Oid argTypes[3];
	Datum argValues[3];
	int spiStatus PG_USED_FOR_ASSERTS_ONLY = 0;

	SPI_connect();

	initStringInfo(&query);
	appendStringInfo(&query, "INSERT INTO %s.", ApiDataSchemaName);

	if (shardTableName != NULL && shardTableName[0] != '\0')
	{
		appendStringInfoString(&query, shardTableName);
	}
	else
	{
		appendStringInfo(&query, "documents_" UINT64_FORMAT, collectionId);
	}

	bool compressDocument = IsDocumentCompressionEligible(shardTableName);
	if (compressDocument)
	{
		appendStringInfo(&query, " (shard_key_value, object_id, document) "
								 " VALUES ($1, %s.bson_from_bytea($2), $3)",
						 CoreSchemaName);
	}
	else
	{
		appendStringInfo(&query, " (shard_key_value, object_id, document) "
								 " VALUES ($1, %s.bson_from_bytea($2), "
								 "%s.bson_from_bytea($3))",
						 CoreSchemaName, CoreSchemaName);
	}

	argTypes[0] = INT8OID;
	argValues[0] = Int64GetDatum(shardKeyValue);
	argTypes[1] = BYTEAOID;
	argValues[1] = PointerGetDatum(CastPgbsonToBytea(objectId));
	argTypes[2] = compressDocument ? BsonTypeId() : BYTEAOID;
	argValues[2] = PointerGetDatum(CastPgbsonToBytea(document));

	SPIPlanPtr plan = GetSPIQueryPlanWithLocalShard(collectionId, shardTableName,
													compressDocument ?
													QUERY_ID_INSERT_COMPRESSED :
													QUERY_ID_INSERT, query.data,
													argTypes, argCount);

	if (compressDocument)
	{
		spiStatus = ExecuteSPIPlanWithCompressedDocument(plan, argValues, argTypes,
														 argCount, 2, false, 1);
	}
	else
	{
		spiStatus = SPI_execute_plan(plan, argValues, NULL, false, 1);
	}
	pfree(query.data);

	SPI_finish();

	return spiStatus == SPI_OK_INSERT;
}


/*
 * Inserts a document with the given shardKeyValue and object_id, and on conflict
 * with the _id index, reapplies the update on the conflicting document (Similar to upsert behavior)
 */
bool
InsertOrReplaceDocument(MongoCollection *collection, const char *shardTableName, int64
						shardKeyValue,
						pgbson *objectId, pgbson *document,
						const bson_value_t *updateSpecValue)
{
	StringInfoData query;
	const int argCount = 4;
	Oid argTypes[4];
	Datum argValues[4];
	int spiStatus PG_USED_FOR_ASSERTS_ONLY = 0;
	uint64 planId;

	SPI_connect();

	pgbson *updateSpecDoc = BsonValueToDocumentPgbson(updateSpecValue);

	initStringInfo(&query);
	appendStringInfo(&query, "INSERT INTO %s.", ApiDataSchemaName);

	if (shardTableName != NULL && shardTableName[0] != '\0')
	{
		appendStringInfoString(&query, shardTableName);
	}
	else
	{
		appendStringInfo(&query, "documents_" UINT64_FORMAT, collection->collectionId);
	}

	bool compressDocument = IsDocumentCompressionEligible(shardTableName);
	if (compressDocument)
	{
		appendStringInfo(&query, " (shard_key_value, object_id, document) "
								 " VALUES ($1, %s.bson_from_bytea($2), $3)",
						 CoreSchemaName);
		planId = QUERY_ID_INSERT_OR_REPLACE_COMPRESSED;
	}
	else
	{
		appendStringInfo(&query, " (shard_key_value, object_id, document) "
								 " VALUES ($1, %s.bson_from_bytea($2), "
								 "%s.bson_from_bytea($3))",
						 CoreSchemaName, CoreSchemaName);
		planId = QUERY_ID_INSERT_OR_REPLACE;
	}

	const char *additionalArgs = "";
	if (IsClusterVersionAtleast(DocDB_V0, 111, 0) &&
		collection->options.updateDescriptionEnabled)
	{
		additionalArgs = ", ctid, tableoid";
	}

	if (shardTableName != NULL && shardTableName[0] != '\0')
	{
		/* Direct shard - we need to extract tableId_shardId as a suffix */
		/* Prefix length is the length of documents_ */
		const int prefixLength = 10;
		const char *shardSuffix = shardTableName + prefixLength;
		appendStringInfo(&query, " ON CONFLICT ON CONSTRAINT collection_pk_%s"
								 " DO UPDATE SET document ="
								 " COALESCE(%s.update_bson_document("
								 " %s.documents_%s.document, %s.bson_from_bytea($4), '{}'::%s.bson, NULL::%s.bson, NULL::%s.bson, NULL::TEXT%s),"
								 " %s.documents_%s.document)",
						 shardSuffix, ApiInternalSchemaNameV2, ApiDataSchemaName,
						 shardSuffix, CoreSchemaName, CoreSchemaName, CoreSchemaName,
						 CoreSchemaName, additionalArgs,
						 ApiDataSchemaName, shardSuffix);
	}
	else
	{
		appendStringInfo(&query,
						 " ON CONFLICT ON CONSTRAINT collection_pk_" UINT64_FORMAT
						 " DO UPDATE SET document ="
						 " COALESCE(%s.update_bson_document(%s.documents_"UINT64_FORMAT
						 ".document, %s.bson_from_bytea($4), '{}'::%s.bson, NULL::%s.bson, NULL::%s.bson, NULL::TEXT%s),"
						 " %s.documents_"UINT64_FORMAT ".document)",
						 collection->collectionId, ApiInternalSchemaNameV2,
						 ApiDataSchemaName, collection->collectionId,
						 CoreSchemaName, CoreSchemaName, CoreSchemaName,
						 CoreSchemaName, additionalArgs,
						 ApiDataSchemaName, collection->collectionId);
	}

	argTypes[0] = INT8OID;
	argValues[0] = Int64GetDatum(shardKeyValue);
	argTypes[1] = BYTEAOID;
	argValues[1] = PointerGetDatum(CastPgbsonToBytea(objectId));
	argTypes[2] = compressDocument ? BsonTypeId() : BYTEAOID;
	argValues[2] = PointerGetDatum(CastPgbsonToBytea(document));
	argTypes[3] = BYTEAOID;
	argValues[3] = PointerGetDatum(CastPgbsonToBytea(updateSpecDoc));

	SPIPlanPtr plan = GetSPIQueryPlanWithLocalShard(collection->collectionId,
													shardTableName,
													planId, query.data, argTypes,
													argCount);

	if (compressDocument)
	{
		spiStatus = ExecuteSPIPlanWithCompressedDocument(plan, argValues, argTypes,
														 argCount, 2, false, 1);
	}
	else
	{
		spiStatus = SPI_execute_plan(plan, argValues, NULL, false, 1);
	}
	pfree(query.data);

	SPI_finish();

	return spiStatus == SPI_OK_INSERT || spiStatus == SPI_OK_UPDATE;
}


/*
 * BuildResponseMessage builds the response BSON for an insert command.
 */
static pgbson *
BuildResponseMessage(BatchInsertionResult *batchResult)
{
	pgbson_writer resultWriter;
	PgbsonWriterInit(&resultWriter);
	PgbsonWriterAppendInt32(&resultWriter, "n", 1, batchResult->rowsInserted);
	PgbsonWriterAppendDouble(&resultWriter, "ok", 2, batchResult->ok);

	if (batchResult->writeErrors != NIL)
	{
		pgbson_array_writer writeErrorsArrayWriter;
		PgbsonWriterStartArray(&resultWriter, "writeErrors", 11, &writeErrorsArrayWriter);

		ListCell *writeErrorCell = NULL;
		foreach(writeErrorCell, batchResult->writeErrors)
		{
			WriteError *writeError = lfirst(writeErrorCell);

			pgbson_writer writeErrorWriter;
			PgbsonArrayWriterStartDocument(&writeErrorsArrayWriter, &writeErrorWriter);
			PgbsonWriterAppendInt32(&writeErrorWriter, "index", 5, writeError->index);
			PgbsonWriterAppendInt32(&writeErrorWriter, "code", 4, writeError->code);
			PgbsonWriterAppendUtf8(&writeErrorWriter, "errmsg", 6, writeError->errmsg);
			PgbsonArrayWriterEndDocument(&writeErrorsArrayWriter, &writeErrorWriter);
		}

		PgbsonWriterEndArray(&resultWriter, &writeErrorsArrayWriter);
	}

	return PgbsonWriterGetPgbson(&resultWriter);
}


/*
 * Given a bson_value for an insert that was in the insert.documents or bson sequence
 * ensures it's of a proper form, validates the document, and extracts required
 * fields from it (shard_key, object_id) and creates a pgbson for insertion.
 */
static pgbson *
PreprocessInsertionDoc(const bson_value_t *docValue, MongoCollection *collection,
					   int64 *shardKeyHash, pgbson **objectId, ExprEvalState *evalState)
{
	if (evalState != NULL)
	{
		ValidateSchemaOnDocumentInsert(
			evalState, docValue, FAILED_VALIDATION_ERROR_MSG);
	}

	/* make sure the document has an _id and it is in the right place */
	pgbson *insertDoc = RewriteDocumentValueAddObjectId(docValue);

	PgbsonValidateInputBson(insertDoc, BSON_VALIDATE_NONE);

	/*
	 * It's possible that the document does not specify the full shard key.
	 * In that case we will only hash the parts that are specified. That
	 * is not problematic in terms of querying, because it means this
	 * object can only be found by queries that do not specify a full
	 * shard key filter and those queries scan all the shards.
	 */
	*shardKeyHash = ComputeShardKeyHashForDocument(collection->shardKey,
												   collection->collectionId,
												   insertDoc);

	if (objectId != NULL)
	{
		*objectId = PgbsonGetDocumentId(insertDoc);
	}

	return insertDoc;
}


/*
 * Creates a Query for the purposes of inserting a document. This takes
 * the form
 * INSERT INTO <collection> (shard_key_value, object_id, document, creation_time)
 * VALUES ( <list of values> )
 */
static Query *
CreateInsertQuery(MongoCollection *collection, Oid shardOid, List *valuesLists)
{
	Query *query = makeNode(Query);
	query->commandType = CMD_INSERT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;

#if PG_VERSION_NUM >= 160000
	RangeTblEntry *rte = CreateBaseTableRteForInsert(collection, shardOid,
													 &query->rteperminfos);
#else
	RangeTblEntry *rte = CreateBaseTableRteForInsert(collection, shardOid, NULL);
#endif

	RangeTblEntry *valuesRte = CreateValueRteForInsert(collection, valuesLists);

	query->rtable = list_make2(rte, valuesRte);
	query->resultRelation = 1;

	RangeTblRef *valuesRteRef = makeNode(RangeTblRef);
	valuesRteRef->rtindex = 2;
	List *fromList = list_make1(valuesRteRef);

	query->jointree = makeFromExpr(fromList, NULL);
	query->targetList = CreateTargetListForInsert(collection);

	/* In order to use a portal & SPI we create a returning list of a const */
	query->returningList = list_make1(
		makeTargetEntry((Expr *) makeConst(INT4OID, -1, InvalidOid, 4, Int32GetDatum(1),
										   false, true), 1, "intVal", false)
		);
	return query;
}


/*
 * Executes the Insert query and returns the total count of processed results.
 */
static uint64_t
RunInsertQuery(Query *insertQuery, ParamListInfo paramListInfo)
{
	uint64_t numRowsProcessed = 0;

	int cursorOptions = CURSOR_OPT_NO_SCROLL | CURSOR_OPT_BINARY;
	Portal queryPortal = CreateNewPortal();
	queryPortal->visible = false;
	queryPortal->cursorOptions = cursorOptions;

	PlannedStmt *queryPlan = PgPlanQueryCompat(insertQuery, NULL, cursorOptions,
											   paramListInfo);

	/* Set the plan in the cursor for this iteration */
	PortalDefineQuery(queryPortal, NULL, "",
					  CMDTAG_SELECT,
					  list_make1(queryPlan),
					  NULL);

	/* Trigger execution (Start the ExecEngine etc.) */
	PortalStart(queryPortal, paramListInfo, 0, GetActiveSnapshot());

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		ereport(ERROR, (errmsg("could not connect to SPI manager")));
	}

	/* run through everything but load no results. */
	SPI_cursor_move(queryPortal, true, FETCH_ALL);

	numRowsProcessed = SPI_processed;
	SPI_cursor_close(queryPortal);

	if (SPI_finish() != SPI_OK_FINISH)
	{
		ereport(ERROR, (errmsg("could not complete SPI query")));
	}

	return numRowsProcessed;
}


/*
 * CreateLocalShardInsertPlan
 *
 * Creates a PlannedStmt for inserting into a local shard table directly.
 * This avoids planning phase.
 *
 * Returns:
 *   PlannedStmt* - The planned statement ready for execution.
 */
static PlannedStmt *
CreateLocalShardInsertPlan(MongoCollection *collection, Oid shardOid,
						   List *valuesLists)
{
	const Cost startupCost = 0.0; /* No startup cost for VALUES scan */
	const Cost totalCost = 0.0125; /* Arbitrary small cost for the VALUES scan */
	const Cardinality planRows = list_length(valuesLists);
	int planWidth = get_relation_data_width(shardOid, NULL);
	const Index relationRelId = 1; /* RTE index for the base table */
	const Index valueListRelId = 2; /* RTE index for the VALUES list */

	PlannedStmt *stmt = makeNode(PlannedStmt);
#if PG_VERSION_NUM >= 160000
	RangeTblEntry *relationRte = CreateBaseTableRteForInsert(collection, shardOid,
															 &stmt->permInfos);
#else
	RangeTblEntry *relationRte = CreateBaseTableRteForInsert(collection, shardOid, NULL);
#endif

	/*
	 * This plan is returned without running the planner, so the permission
	 * record it carries has not been evaluated.
	 *
	 * Only this plan needs it. A range table entry built for a Query reaches
	 * the planner, which settles the record itself, so doing it there too
	 * would run the decision twice for the same relation.
	 */
	ApplyCollectionAccessIdentityToPlan(relationRte, stmt);

	RangeTblEntry *valuesRte = CreateValueRteForInsert(collection, valuesLists);
	List *targetList = CreateTargetListForInsert(collection);


	/* Create the ValuesScan node for the VALUES RTE */
	ValuesScan *vscan = makeNode(ValuesScan);
	vscan->scan.scanrelid = valueListRelId;
	vscan->values_lists = copyObject(valuesRte->values_lists);
	valuesRte->values_lists = NULL;

	Plan *vplan = &vscan->scan.plan;
	vplan->startup_cost = startupCost;
	vplan->total_cost = totalCost;
	vplan->plan_rows = planRows;
	vplan->plan_width = planWidth;
	vplan->targetlist = targetList;

	/* Create the ModifyTable node for the insert operation */
	ModifyTable *mt = makeNode(ModifyTable);
	mt->operation = CMD_INSERT;
	mt->canSetTag = true;
	mt->resultRelations = list_make1_int(relationRelId);
	mt->plan.lefttree = (Plan *) vscan;
	mt->plan.total_cost = totalCost;
	mt->plan.plan_rows = planRows;
	mt->plan.plan_width = planWidth;
	mt->nominalRelation = relationRelId;
	mt->fdwPrivLists = list_make1(NIL);

	/* Fill in the PlannedStmt */
	stmt->commandType = CMD_INSERT;
	stmt->canSetTag = true;
	stmt->planTree = (Plan *) mt;
	stmt->rtable = list_make2(relationRte, valuesRte);
#if PG_VERSION_NUM >= 190000
	stmt->resultRelationRelids = bms_make_singleton(relationRelId);
#else
	stmt->resultRelations = list_make1_int(relationRelId);
#endif
	stmt->relationOids = list_make1_oid(relationRte->relid);

	return stmt;
}


/*
 * Executes a local insert plan for a sharded table using the provided PlannedStmt.
 * Returns the number of rows processed.
 */
static uint64_t
ExecuteLocalShardInsertPlan(PlannedStmt *queryPlan, ParamListInfo paramListInfo)
{
	ScanDirection scanDirection = ForwardScanDirection;
	QueryEnvironment *queryEnv = create_queryEnv();
	int eflags = 0;

	MemoryContext localContext = AllocSetContextCreate(CurrentMemoryContext,
													   "DocumentDBExecutePlan",
													   ALLOCSET_DEFAULT_SIZES);
	MemoryContext oldContext = MemoryContextSwitchTo(localContext);
	DestReceiver *receiver = CreateDestReceiver(DestNone);

	/* Create a QueryDesc for the query */
	QueryDesc *queryDesc = CreateQueryDesc(queryPlan, "",
										   GetActiveSnapshot(), InvalidSnapshot,
										   receiver, paramListInfo,
										   queryEnv, 0);

	ExecutorStart(queryDesc, eflags);

	ExecutorRun_Compat(queryDesc, scanDirection, 0L, true);

	uint64_t numRowsProcessed = queryDesc->estate->es_processed;

	ExecutorFinish(queryDesc);
	ExecutorEnd(queryDesc);

	FreeQueryDesc(queryDesc);
	MemoryContextSwitchTo(oldContext);
	MemoryContextDelete(localContext);

	return numRowsProcessed;
}


/* indicates the presence of a creation_time column in the table, either at attribute number 4 or 5 */
static inline List *
CreateValuesListForInsert(Const *shardKey, Expr *objectId, Expr *document, AttrNumber
						  creationTimeVarAttNum)
{
	if (creationTimeVarAttNum != -1)
	{
		TimestampTz nowValueTime = (TimestampTz) 000000000000000LL;  /* "2000-01-01 00:00:00+00" */
		Const *nowValue = makeConst(TIMESTAMPTZOID, -1, InvalidOid, 8,
									TimestampTzGetDatum(nowValueTime), false, true);
		return list_make4(shardKey, objectId, document, nowValue);
	}
	else
	{
		return list_make3(shardKey, objectId, document);
	}
}


/* Build RangeTblEntry for base table */
static inline RangeTblEntry *
CreateBaseTableRteForInsert(MongoCollection *collection, Oid shardOid,
							List **optionalPermInfos)
{
	RangeTblEntry *rte = makeNode(RangeTblEntry);
	List *colNames = list_make3(makeString("shard_key_value"), makeString("object_id"),
								makeString("document"));


	if (collection->mongoDataCreationTimeVarAttrNumber == 4)
	{
		colNames = lappend(colNames, makeString("creation_time"));
	}
	else if (collection->mongoDataCreationTimeVarAttrNumber == 5)
	{
		/* If "creation_time" is the fifth column, then we should include "change_description" in the RTE. */
		colNames = ModifyTableColumnNames(colNames);
	}

	rte->rtekind = RTE_RELATION;
	rte->relid = collection->relationId;

	/* If there is a shardOid and we can thunk directly to the shard,
	 * then set it. This will point the insert to the shard directly and avoid
	 * going through citus distributed planning.
	 */
	if (shardOid != InvalidOid)
	{
		rte->relid = shardOid;
	}

	rte->alias = rte->eref = makeAlias("collection", colNames);
	rte->lateral = false;
	rte->inFromCl = false;
	rte->relkind = RELKIND_RELATION;
	rte->functions = NIL;
	rte->inh = true;
	rte->rellockmode = RowExclusiveLock;

#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permInfo = addRTEPermissionInfo(optionalPermInfos, rte);
	permInfo->requiredPerms = ACL_INSERT;
#else
	rte->requiredPerms = ACL_INSERT;
#endif

	return rte;
}


/* Build RangeTblEntry for values */
static inline RangeTblEntry *
CreateValueRteForInsert(MongoCollection *collection, List *valuesLists)
{
	/* Build the VALUES RTE */
	List *valuesColNames = list_make3(makeString("shard_key_value"),
									  makeString("object_id"),
									  makeString("document"));

	if (collection->mongoDataCreationTimeVarAttrNumber != -1)
	{
		valuesColNames = lappend(valuesColNames, makeString("creation_time"));
	}

	RangeTblEntry *valuesRte = makeNode(RangeTblEntry);
	valuesRte->rtekind = RTE_VALUES;
	valuesRte->alias = valuesRte->eref = makeAlias("values", valuesColNames);
	valuesRte->lateral = false;
	valuesRte->inFromCl = true;
	valuesRte->values_lists = valuesLists;
	valuesRte->inh = false;

	/* Set column types and widths */
	if (collection->mongoDataCreationTimeVarAttrNumber != -1)
	{
		valuesRte->coltypes = list_make4_oid(INT8OID, BsonTypeId(), BsonTypeId(),
											 TIMESTAMPTZOID);
		valuesRte->coltypmods = list_make4_int(-1, -1, -1, -1);
		valuesRte->colcollations = list_make4_oid(InvalidOid, InvalidOid, InvalidOid,
												  InvalidOid);
	}
	else
	{
		valuesRte->coltypes = list_make3_oid(INT8OID, BsonTypeId(), BsonTypeId());
		valuesRte->coltypmods = list_make3_int(-1, -1, -1);
		valuesRte->colcollations = list_make3_oid(InvalidOid, InvalidOid, InvalidOid);
	}

	return valuesRte;
}


/* Build targetList for insert */
static inline List *
CreateTargetListForInsert(MongoCollection *collection)
{
	List *targetList = list_make3(
		makeTargetEntry((Expr *) makeVar(2, 1, INT8OID, -1, InvalidOid, 0),
						DOCUMENT_DATA_TABLE_SHARD_KEY_VALUE_VAR_ATTR_NUMBER,
						"shard_key_value", false),
		makeTargetEntry((Expr *) makeVar(2, 2, BsonTypeId(), -1, InvalidOid, 0),
						DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER, "object_id",
						false),
		makeTargetEntry((Expr *) makeVar(2, 3, BsonTypeId(), -1, InvalidOid, 0),
						DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER, "document",
						false)
		);

	if (collection->mongoDataCreationTimeVarAttrNumber != -1)
	{
		targetList = lappend(targetList,
							 makeTargetEntry((Expr *) makeVar(2, 4, TIMESTAMPTZOID, -1,
															  InvalidOid, 0),
											 collection->
											 mongoDataCreationTimeVarAttrNumber,
											 "creation_time", false));
	}

	return targetList;
}


static inline void
ReportInsertFeatureUsage(int batchSize)
{
	if (batchSize == 1)
	{
		ReportFeatureUsage(FEATURE_COMMAND_INSERT_ONE);
	}
	else if (batchSize <= 100)
	{
		ReportFeatureUsage(FEATURE_COMMAND_INSERT_100);
	}
	else if (batchSize <= 500)
	{
		ReportFeatureUsage(FEATURE_COMMAND_INSERT_500);
	}
	else if (batchSize <= 1000)
	{
		ReportFeatureUsage(FEATURE_COMMAND_INSERT_1000);
	}
	else
	{
		ReportFeatureUsage(FEATURE_COMMAND_INSERT_EXTENDED);
	}
}
