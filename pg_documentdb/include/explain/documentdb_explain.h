/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/explain/documentdb_explain.h
 *
 * Common declarations for explain functionality in documentdb.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_EXPLAIN_H
#define DOCUMENTDB_EXPLAIN_H

#include "io/bson_core.h"

typedef bool (*DocumentDBExplainStageHook)(pgbson_writer *writer, QueryDesc *queryDesc,
										   PlanState *planState,
										   void (*stageWriteFunc)(pgbson_writer *, const
																  char *,
																  QueryDesc *,
																  PlanState *));

extern DocumentDBExplainStageHook explain_stage_hook;
#endif
