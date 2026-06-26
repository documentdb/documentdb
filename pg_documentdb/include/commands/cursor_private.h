/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/commands/cursor_private.h
 *
 * Private declarations of functions and types shared between
 * cursors.c and aggregation_cursors.c
 *
 *-------------------------------------------------------------------------
 */

#ifndef CURSOR_PRIVATE_H
#define CURSOR_PRIVATE_H

typedef struct QueryCursorPlanResult QueryCursorPlanResult;

bool DrainStreamingQuery(HTAB *cursorMap, Query *query, int batchSize,
						 int32_t *numIterations, uint32_t accumulatedSize,
						 pgbson_array_writer *arrayWriters);
pgbson * DrainTailableQuery(pgbson *cursorSpec, Query *query, int batchSize,
							int32_t *numIterations, uint32_t accumulatedSize,
							pgbson_array_writer *arrayWriter);
bool CreateAndDrainPersistedQuery(const char *cursorName,
								  QueryCursorPlanResult *planResult,
								  int batchSize, int32_t *numIterations, uint32_t
								  accumulatedSize,
								  pgbson_array_writer *arrayWriter, bool isHoldCursor,
								  bool closeCursor);
void CreateAndDrainSingleBatchQuery(const char *cursorName, Query *query,
									int batchSize, int32_t *numIterations, uint32_t
									accumulatedSize, pgbson_array_writer *arrayWriter);
bytea * CreateAndDrainPersistedQueryWithFiles(const char *cursorName,
											  QueryCursorPlanResult *planResult,
											  int batchSize, int32_t *numIterations,
											  uint32_t
											  accumulatedSize,
											  pgbson_array_writer *arrayWriter, bool
											  closeCursor, bool useFileBasedCursors);
bool DrainPersistedCursor(const char *cursorName, int batchSize,
						  int32_t *numIterations, uint32_t accumulatedSize,
						  pgbson_array_writer *arrayWriter);
bytea * DrainPersistedFileCursor(const char *cursorName, int batchSize,
								 int32_t *numIterations, uint32_t accumulatedSize,
								 pgbson_array_writer *arrayWriter,
								 bytea *cursorFileState,
								 bool useFileBasedCursors);

void CreateAndDrainPointReadQuery(const char *cursorName, Query *query,
								  int32_t *numIterations, uint32_t
								  accumulatedSize,
								  pgbson_array_writer *arrayWriter);

QueryCursorPlanResult * PlanForcedPersistentQuery(Query *query, bool isHoldCursor);


QueryCursorPlanResult * PlanDynamicQueryAndDetermineCursorType(Query *query,
															   bool *isDynamicStreamable);
pgbson * DrainDynamicStreamingCursor(QueryCursorPlanResult *planResult,
									 int batchSize, pgbson *inputContinuation,
									 pgbson_array_writer *arrayWriter,
									 uint32_t accumulatedSize);

TupleDesc ConstructCursorResultTupleDesc(AttrNumber maxAttrNum);

int64_t FinishWriteCursorPage(pgbson_writer *cursorDoc, pgbson_array_writer *arrayWriter,
							  pgbson_writer *topLevelWriter, int64_t cursorId,
							  pgbson *continuation, bool persistConnection,
							  pgbson *lastContinuationToken);
Datum FormFinalCursorResultTuple(pgbson *resultDocument, pgbson *continuation,
								 bool persistConnection, int64_t cursorId,
								 TupleDesc cursorResultTupleDesc);

HTAB * CreateCursorHashSet(void);
void BuildContinuationMap(pgbson *continuationValue, HTAB *cursorMap);
void SerializeContinuationsToWriter(pgbson_writer *writer, HTAB *cursorMap);
pgbson * SerializeContinuationForWorker(HTAB *cursorMap, int32_t batchSize);
pgbson * ExtendTailableContinuation(pgbson *continuationValue, int32_t batchSize);
pgbson * DrainSingleResultQuery(Query *query);

void SetupCursorPagePreamble(pgbson_writer *topLevelWriter,
							 pgbson_writer *cursorDoc,
							 pgbson_array_writer *arrayWriter,
							 const char *namespaceName, bool isFirstPage,
							 uint32_t *accumulatedLength);

#endif
