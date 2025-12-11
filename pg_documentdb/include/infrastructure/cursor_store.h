/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/infrastructure/cursor_store.h
 *
 * Common declarations for the pg_documentdb cursor store.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_CURSOR_STORE_H
#define DOCUMENTDB_CURSOR_STORE_H
#include <postgres.h>

typedef struct CursorFileState CursorFileState;

void SetupCursorStorage(void);
void InitializeFileCursorShmem(void);
Size FileCursorShmemSize(void);

void DeletePendingCursorFiles(void);
void GetCurrentCursorCount(int32_t *currentCursorCount, int32_t *measuredCursorCount,
						   int64_t *lastCursorSize);
void DeleteCursorFile(const char *cursorName);
CursorFileState * CreateCursorFile(const char *cursorName);
void WriteToCursorFile(CursorFileState *cursorFileState, pgbson *bson);
pgbson * ReadFromCursorFile(CursorFileState *cursorFileState);
bytea * CursorFileStateClose(CursorFileState *cursorFileState, MemoryContext
							 writerContext);

CursorFileState * DeserializeFileState(bytea *cursorFileState);

#endif
