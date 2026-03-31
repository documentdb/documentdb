/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/commands/commands_common.h
 *
 * Common declarations of commands.
 *
 *-------------------------------------------------------------------------
 */

#ifndef COMMANDS_COMMON_H
#define COMMANDS_COMMON_H

#include <utils/elog.h>
#include <metadata/collection.h>
#include <io/bson_core.h>
#include <utils/documentdb_errors.h>
#include <access/xact.h>
#include <access/xlog.h>

/*
 * Maximum size of a output bson document is 16MB.
 */
#define BSON_MAX_ALLOWED_SIZE (16 * 1024 * 1024)

/*
 * Maximum size of a document produced by an intermediate stage of an aggregation pipeline.
 * For example, in a pipeline like [$facet, $unwind], $facet is allowed to generate a document
 * larger than 16MB, since $unwind can break it into smaller documents. However, $facet cannot
 * generate a document larger than 100MB.
 */
#define BSON_MAX_ALLOWED_SIZE_INTERMEDIATE (100 * 1024 * 1024)

/* StringView that represents the _id field */
extern PGDLLIMPORT const StringView IdFieldStringView;


/*
 * ApiGucPrefix.enable_create_collection_on_insert GUC determines whether
 * an insert into a non-existent collection should create a collection.
 */
extern bool EnableCreateCollectionOnInsert;

/*
 * Whether to enforce that $db in the command body matches the database
 * passed as a function argument. When off, mismatches are silently ignored.
 */
extern bool EnableDbNameValidation;

/*
 * Whether or not write operations are inlined or if they are dispatched
 * to a remote shard. For single node scenarios like DocumentDB that don't need
 * distributed dispatch. Reset in scenarios that need distributed dispatch.
 */
extern bool DefaultInlineWriteOperations;
extern int BatchWriteSubTransactionCount;
extern int MaxWriteBatchSize;

/*
 * Specifies how write commands (insert/update) are executed, controlling
 * their transactional behavior.
 */
typedef enum WriteMode
{
	/*
	 * Called via insert()/update() SQL *functions*.
	 * Uses subtransactions for all writes. single-document write, wrapped in a subtransaction;
	 * on failure the subtransaction is rolled back.
	 * For batch writes, multiple documents are first attempted together in a
	 * single subtransaction (optimistic path). If that fails, the subtransaction
	 * is rolled back and the documents are retried one-by-one, each in its own
	 * subtransaction, to identify exactly which document(s) failed.
	 */
	WriteMode_Txn_Func = 0,

	/*
	 * Called via insert_txn_proc()/update_txn_proc() SQL *procedures*.
	 * Optimized for single-document writes: skips subtransactions, which
	 * reduces WAL overhead compared to Txn_Func. Batch and error-handling
	 * behavior is otherwise the same as Txn_Func.
	 * Cannot be used inside an explicit client transaction block.
	 */
	WriteMode_Txn_Proc = 1,

	/*
	 * Called via insert_bulk()/update_bulk() SQL *procedures*.
	 * Designed for large batch writes. Commits after smaller sub-batches
	 * and starts a new transaction, reducing the time locks are held and
	 * allowing other operations to proceed.
	 */
	WriteMode_Bulk_Proc = 2,
} WriteMode;

/*
 * WriteError can be part of the response of a batch write operation.
 */
typedef struct WriteError
{
	/* Index specified within a write operation batch */
	int index;

	/* error code */
	int code;

	/* description of the error */
	char *errmsg;
} WriteError;


bool FindShardKeyValueForDocumentId(MongoCollection *collection, const
									bson_value_t *queryDoc,
									bson_value_t *objectId,
									bool isIdValueCollationAware,
									bool queryHasNonIdFilters,
									int64 *shardKeyValue,
									const bson_value_t *variableSpec,
									const char *collationString);

bool IsCommonSpecIgnoredField(const char *fieldName);
void ValidateOrExtractDatabaseNameFromSpec(bson_iter_t *iter, Datum *databaseNameDatum);
void ValidateOrExtractDatabaseNameTextFromSpec(bson_iter_t *iter,
											   text **databaseNameText);

WriteError * GetWriteErrorFromErrorData(ErrorData *errorData, int writeErrorIdx);
bool TryGetErrorMessageAndCode(ErrorData *errorData, int *code, char **errmessage);

pgbson * GetObjectIdFilterFromQueryDocumentValue(const bson_value_t *queryDoc,
												 bool *hasNonIdFields,
												 bool *isObjectIdFilter);
pgbson * GetObjectIdFilterFromQueryDocument(pgbson *queryDoc, bool *hasNonIdFields,
											bool *isIdValueCollationAware);


pgbson * RewriteDocumentAddObjectId(pgbson *document);
pgbson * RewriteDocumentValueAddObjectId(const bson_value_t *value);
pgbson * RewriteDocumentWithCustomObjectId(pgbson *document,
										   pgbson *objectIdToWrite);

void ValidateIdField(const bson_value_t *idValue);
void SetExplicitStatementTimeout(int timeoutMilliseconds);

void CommitWriteProcedureAndReacquireCollectionLock(MongoCollection *collection,
													Oid shardTableOid,
													bool setSnapshot);

extern bool SimulateRecoveryState;
extern bool DocumentDBPGReadOnlyForDiskFull;

inline static void
ThrowIfServerOrTransactionReadOnly(void)
{
	if (!XactReadOnly)
	{
		return;
	}

	if (RecoveryInProgress() || SimulateRecoveryState)
	{
		/*
		 * Skip these checks in recovery mode - let the system throw the appropriate
		 * error.
		 */
		return;
	}

	if (DocumentDBPGReadOnlyForDiskFull)
	{
		ereport(ERROR, (errcode(ERRCODE_DISK_FULL), errmsg(
							"Can't execute write operation, The database disk is full")));
	}

	/* Error is coming because the server has been put in a read-only state, but we're a writable node (primary) */
	if (DefaultXactReadOnly)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_NOTWRITABLEPRIMARY),
						errmsg(
							"Write operations cannot be performed because the server is currently operating in a read-only mode."),
						errdetail("the default transaction is read-only"),
						errdetail_log(
							"cannot execute write operations when default_transaction_read_only is set to true")));
	}

	/* Error is coming because the transaction has been in a readonly state */
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_OPERATIONNOTSUPPORTEDINTRANSACTION),
					errmsg(
						"cannot execute write operation when the transaction is in a read-only state."),
					errdetail("the current transaction is read-only")));
}


#endif
