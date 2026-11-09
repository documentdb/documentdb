/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 *
 * include/commands/insert_on_conflict_scan.h
 *
 * Conflict handling for optimized insert batches.
 *
 *-------------------------------------------------------------------------
 */
#ifndef INSERT_ON_CONFLICT_H
#define INSERT_ON_CONFLICT_H

#include <nodes/execnodes.h>
#include <nodes/plannodes.h>
#include <utils/elog.h>
#include <utils/memutils.h>

#include "commands/commands_common.h"

/*
 * Command-scoped state learned from the first duplicate batch failure.
 * indexName lives in the result context so bulk-procedure commits cannot
 * invalidate it before later retries and batches finish.
 */
typedef struct InsertConflictState
{
	/* True after the arbiter and logical name are resolved. */
	bool isValid;

	/* Physical index used as the ON CONFLICT arbiter. */
	Oid arbiterIndexOid;

	/* Request-owned logical index name used in write errors. */
	char *indexName;
} InsertConflictState;

void TrySetInsertConflictState(InsertConflictState *conflictState,
							   ErrorData *errorData, Oid shardOid,
							   MemoryContext targetContext,
							   HTAB **indexNameCache);
WriteError * BuildInsertConflictWriteError(int writeErrorIndex,
										   const InsertConflictState *conflictState);
void ModifyInsertPlanWithOnConflict(PlannedStmt *stmt, Oid arbiterIndexOid,
									bool captureSkippedIndexes);
List * CopyInsertConflictSkippedIndexes(PlanState *modifyTableState,
										MemoryContext targetContext);

#endif
