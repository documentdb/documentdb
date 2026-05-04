/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/retryable_writes.
 *
 * Implementation of retryable write bookkeeping.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"

#include "io/bson_core.h"
#include "infrastructure/documentdb_plan_cache.h"
#include "commands/retryable_writes.h"
#include "metadata/metadata_cache.h"
#include "utils/version_utils.h"


/*
 * FindRetryRecordByObjectId searches for a retry record in any shard
 * returns whether it was found, and sets the rowsAffected.
 *
 * We do this only when doing a single-row write with an _id filter on a
 * collection that is not sharded by _id. In other cases, we check for
 * retryable writes directly on the shard.
 */
bool
FindRetryRecordInAnyShard(uint64 collectionId, text *transactionId,
						  RetryableWriteResult *writeResult)
{
	StringInfoData query;
	MemoryContext originalContext = CurrentMemoryContext;
	int spiStatus PG_USED_FOR_ASSERTS_ONLY = 0;

	bool retryRecordExists = false;
	MemoryContext outerContext = CurrentMemoryContext;

	SPI_connect();

	if (UseLocalRetryTable())
	{
		const int argCount = 2;
		Oid argTypes[2];
		Datum argValues[2];

		initStringInfo(&query);

		/*
		 * This query performs a prefix scan on collection_id because the PK index
		 * on the retryable_writes table is (collection_id, shard_key_value,
		 * transaction_id). Without an exact shard_key_value predicate, the index
		 * scan must visit all entries for this collection_id. This is acceptable
		 * today because retryable write entries are short-lived (cleaned up after
		 * retry or TTL), but a future optimization could add a secondary index on
		 * (collection_id, transaction_id) if this becomes a bottleneck.
		 *
		 * Note: This function is in the hot path for retryable writes on
		 * collections not sharded by _id.
		 */
		appendStringInfo(&query,
						 "SELECT object_id, rows_affected, shard_key_value "
						 " FROM %s.retryable_writes"
						 " WHERE collection_id = $1 AND transaction_id = $2",
						 ApiDataSchemaName);

		argTypes[0] = INT8OID;
		argValues[0] = Int64GetDatum((int64) collectionId);

		argTypes[1] = TEXTOID;
		argValues[1] = PointerGetDatum(transactionId);

		char *argNulls = NULL;
		bool readOnly = false;
		long maxTupleCount = 0;

		SPIPlanPtr plan = GetSPIQueryPlan(collectionId,
										  QUERY_ID_GLOBAL_RETRY_RECORD_SELECT,
										  query.data, argTypes, argCount);

		spiStatus = SPI_execute_plan(plan, argValues, argNulls, readOnly,
									 maxTupleCount);
		Assert(spiStatus == SPI_OK_SELECT);
	}
	else
	{
		const int argCount = 1;
		Oid argTypes[1];
		Datum argValues[1];

		initStringInfo(&query);
		appendStringInfo(&query,
						 "SELECT object_id, rows_affected, shard_key_value "
						 " FROM %s.retry_" UINT64_FORMAT
						 " WHERE transaction_id = $1",
						 ApiDataSchemaName, collectionId);

		argTypes[0] = TEXTOID;
		argValues[0] = PointerGetDatum(transactionId);

		char *argNulls = NULL;
		bool readOnly = false;
		long maxTupleCount = 0;

		SPIPlanPtr plan = GetSPIQueryPlan(collectionId,
										  QUERY_ID_RETRY_RECORD_SELECT,
										  query.data, argTypes, argCount);

		spiStatus = SPI_execute_plan(plan, argValues, argNulls, readOnly,
									 maxTupleCount);
		Assert(spiStatus == SPI_OK_SELECT);
	}

	if (SPI_processed > 0)
	{
		retryRecordExists = true;

		if (writeResult != NULL)
		{
			bool isNull = false;

			int columnNumber = 1;
			Datum objectIdDatum = SPI_getbinval(SPI_tuptable->vals[0],
												SPI_tuptable->tupdesc, columnNumber,
												&isNull);
			if (!isNull)
			{
				/* copy object ID into outer memory context */
				pgbson *objectId = DatumGetPgBson(objectIdDatum);
				writeResult->objectId = CopyPgbsonIntoMemoryContext(objectId,
																	outerContext);
			}
			else
			{
				/* write affected 0 rows */
				writeResult->objectId = NULL;
			}

			columnNumber = 2;
			Datum rowsAffectedDatum = SPI_getbinval(SPI_tuptable->vals[0],
													SPI_tuptable->tupdesc, columnNumber,
													&isNull);
			Assert(!isNull);

			writeResult->rowsAffected = BoolGetDatum(rowsAffectedDatum);

			columnNumber = 3;
			Datum shardKeyValueDatum = SPI_getbinval(SPI_tuptable->vals[0],
													 SPI_tuptable->tupdesc, columnNumber,
													 &isNull);
			Assert(!isNull);

			writeResult->shardKeyValue = Int64GetDatum(shardKeyValueDatum);
		}
	}

	pfree(query.data);

	SPI_finish();
	MemoryContextSwitchTo(originalContext);

	return retryRecordExists;
}


/*
 * DeleteRetryRecordGetObjectId deletes a retry record and returns the object ID
 * that was stored in the record.
 */
bool
DeleteRetryRecord(uint64 collectionId, int64 shardKeyValue,
				  text *transactionId, RetryableWriteResult *writeResult)
{
	StringInfoData query;
	int spiStatus PG_USED_FOR_ASSERTS_ONLY = 0;
	bool foundRetryRecord = false;

	MemoryContext outerContext = CurrentMemoryContext;

	SPI_connect();

	if (UseLocalRetryTable())
	{
		const int argCount = 3;
		Oid argTypes[3];
		Datum argValues[3];

		initStringInfo(&query);
		appendStringInfo(&query,
						 "DELETE FROM %s.retryable_writes"
						 " WHERE collection_id = $1 AND shard_key_value = $2"
						 " AND transaction_id = $3"
						 " RETURNING object_id, rows_affected, result_document",
						 ApiDataSchemaName);

		argTypes[0] = INT8OID;
		argValues[0] = Int64GetDatum((int64) collectionId);

		argTypes[1] = INT8OID;
		argValues[1] = Int64GetDatum(shardKeyValue);

		argTypes[2] = TEXTOID;
		argValues[2] = PointerGetDatum(transactionId);

		char *argNulls = NULL;
		bool readOnly = false;
		long maxTupleCount = 0;

		SPIPlanPtr plan = GetSPIQueryPlan(collectionId,
										  QUERY_ID_GLOBAL_RETRY_RECORD_DELETE,
										  query.data, argTypes, argCount);

		spiStatus = SPI_execute_plan(plan, argValues, argNulls, readOnly,
									 maxTupleCount);
		Assert(spiStatus == SPI_OK_DELETE_RETURNING);
	}
	else
	{
		const int argCount = 2;
		Oid argTypes[2];
		Datum argValues[2];

		initStringInfo(&query);
		appendStringInfo(&query,
						 "DELETE FROM %s.retry_" UINT64_FORMAT
						 " WHERE shard_key_value = $1 AND transaction_id = $2"
						 " RETURNING object_id, rows_affected, result_document",
						 ApiDataSchemaName, collectionId);

		argTypes[0] = INT8OID;
		argValues[0] = Int64GetDatum(shardKeyValue);

		argTypes[1] = TEXTOID;
		argValues[1] = PointerGetDatum(transactionId);

		char *argNulls = NULL;
		bool readOnly = false;
		long maxTupleCount = 0;

		SPIPlanPtr plan = GetSPIQueryPlan(collectionId,
										  QUERY_ID_RETRY_RECORD_DELETE,
										  query.data, argTypes, argCount);

		spiStatus = SPI_execute_plan(plan, argValues, argNulls, readOnly,
									 maxTupleCount);
		Assert(spiStatus == SPI_OK_DELETE_RETURNING);
	}

	if (SPI_processed > 0)
	{
		foundRetryRecord = true;

		if (writeResult != NULL)
		{
			bool isNull = false;
			Datum objectIdDatum = SPI_getbinval(SPI_tuptable->vals[0],
												SPI_tuptable->tupdesc, 1,
												&isNull);
			if (!isNull)
			{
				/* copy object ID into outer memory context */
				pgbson *objectId = DatumGetPgBson(objectIdDatum);
				writeResult->objectId = CopyPgbsonIntoMemoryContext(objectId,
																	outerContext);
			}
			else
			{
				/* write affected 0 rows */
				writeResult->objectId = NULL;
			}

			Datum rowsAffectedDatum = SPI_getbinval(SPI_tuptable->vals[0],
													SPI_tuptable->tupdesc, 2,
													&isNull);
			Assert(!isNull);

			writeResult->rowsAffected = BoolGetDatum(rowsAffectedDatum);
			writeResult->shardKeyValue = shardKeyValue;

			Datum resultDocumentDatum = SPI_getbinval(SPI_tuptable->vals[0],
													  SPI_tuptable->tupdesc, 3,
													  &isNull);
			if (!isNull)
			{
				pgbson *resultDocument = DatumGetPgBson(resultDocumentDatum);
				writeResult->resultDocument = CopyPgbsonIntoMemoryContext(resultDocument,
																		  outerContext);
			}
			else
			{
				writeResult->resultDocument = NULL;
			}
		}
	}

	pfree(query.data);

	SPI_finish();

	return foundRetryRecord;
}


/*
 * InsertRetryRecord inserts a retryable write record into the retry
 * table of a collection.
 */
void
InsertRetryRecord(uint64 collectionId, int64 shardKeyValue, text *transactionId,
				  pgbson *objectId, bool rowsAffected, pgbson *resultDocument)
{
	StringInfoData query;
	int spiStatus PG_USED_FOR_ASSERTS_ONLY = 0;

	SPI_connect();

	if (UseLocalRetryTable())
	{
		const int argCount = 6;
		Oid argTypes[6];
		Datum argValues[6];
		char argNulls[] = { ' ', ' ', ' ', ' ', ' ', ' ' };

		/*
		 * With a single shared retry table, all collections' retry records
		 * share the same index pages, which may cause buffer contention under
		 * heavy concurrent write workloads compared to per-collection retry
		 * tables. In practice this is expected to be low severity since retry
		 * records are short-lived.
		 */
		initStringInfo(&query);
		appendStringInfo(&query,
						 "INSERT INTO %s.retryable_writes"
						 " (collection_id, shard_key_value, transaction_id, object_id, "
						 "  rows_affected, result_document) "
						 " VALUES ($1, $2, $3, $4::%s, $5, $6::%s)",
						 ApiDataSchemaName, FullBsonTypeName, FullBsonTypeName);

		argTypes[0] = INT8OID;
		argValues[0] = Int64GetDatum((int64) collectionId);

		argTypes[1] = INT8OID;
		argValues[1] = Int64GetDatum(shardKeyValue);

		argTypes[2] = TEXTOID;
		argValues[2] = PointerGetDatum(transactionId);

		argTypes[3] = BYTEAOID;

		if (objectId != NULL)
		{
			argValues[3] = PointerGetDatum(objectId);
			argNulls[3] = ' ';
		}
		else
		{
			argNulls[3] = 'n';
		}

		argTypes[4] = BOOLOID;
		argValues[4] = BoolGetDatum(rowsAffected);

		argTypes[5] = BYTEAOID;

		if (resultDocument != NULL)
		{
			argValues[5] = PointerGetDatum(resultDocument);
			argNulls[5] = ' ';
		}
		else
		{
			argNulls[5] = 'n';
		}

		bool readOnly = false;
		long maxTupleCount = 0;

		SPIPlanPtr plan = GetSPIQueryPlan(collectionId,
										  QUERY_ID_GLOBAL_RETRY_RECORD_INSERT,
										  query.data, argTypes, argCount);

		spiStatus = SPI_execute_plan(plan, argValues, argNulls, readOnly,
									 maxTupleCount);
		Assert(spiStatus == SPI_OK_INSERT);
		Assert(SPI_processed == 1);
	}
	else
	{
		const int argCount = 5;
		Oid argTypes[5];
		Datum argValues[5];
		char argNulls[] = { ' ', ' ', ' ', ' ', ' ' };

		initStringInfo(&query);
		appendStringInfo(&query,
						 "INSERT INTO %s.retry_" UINT64_FORMAT
						 " (shard_key_value, transaction_id, object_id, "
						 "  rows_affected, result_document) "
						 " VALUES ($1, $2, $3::%s, $4, $5::%s)",
						 ApiDataSchemaName, collectionId,
						 FullBsonTypeName, FullBsonTypeName);

		argTypes[0] = INT8OID;
		argValues[0] = Int64GetDatum(shardKeyValue);

		argTypes[1] = TEXTOID;
		argValues[1] = PointerGetDatum(transactionId);

		argTypes[2] = BYTEAOID;

		if (objectId != NULL)
		{
			argValues[2] = PointerGetDatum(objectId);
			argNulls[2] = ' ';
		}
		else
		{
			argNulls[2] = 'n';
		}

		argTypes[3] = BOOLOID;
		argValues[3] = BoolGetDatum(rowsAffected);

		argTypes[4] = BYTEAOID;

		if (resultDocument != NULL)
		{
			argValues[4] = PointerGetDatum(resultDocument);
			argNulls[4] = ' ';
		}
		else
		{
			argNulls[4] = 'n';
		}

		bool readOnly = false;
		long maxTupleCount = 0;

		SPIPlanPtr plan = GetSPIQueryPlan(collectionId,
										  QUERY_ID_RETRY_RECORD_INSERT,
										  query.data, argTypes, argCount);

		spiStatus = SPI_execute_plan(plan, argValues, argNulls, readOnly,
									 maxTupleCount);
		Assert(spiStatus == SPI_OK_INSERT);
		Assert(SPI_processed == 1);
	}

	pfree(query.data);

	SPI_finish();
}
