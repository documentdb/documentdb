/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * include/commands/cursor_common.h
 *
 * Common declarations of Cursor commands.
 *
 *-------------------------------------------------------------------------
 */

#ifndef CURSOR_COMMON_H
#define CURSOR_COMMON_H

#include "utils/string_view.h"

/* Keep serialized keys stable for continuations issued by earlier versions. */
typedef struct ContinuationFieldNames
{
	StringView BatchCount;
	StringView BatchSize;
	StringView BatchSizeAttribute;
	StringView BatchSizeHint;
	StringView ClusterTime;
	StringView Collation;
	StringView Continuation;
	StringView CursorId;
	StringView CursorName;
	StringView DistributedTableOid;
	StringView DynamicCursorState;
	StringView DynamicQuery;
	StringView FileState;
	StringView HasFetchedRows;
	StringView HasParallelPlan;
	StringView NowValue;
	StringView NumIterations;
	StringView Persisted;
	StringView PrimaryKey;
	StringView QueryKind;
	StringView RemainingLimit;
	StringView RemoteQuery;
	StringView ResumeToken;
	StringView ResumeTokenData;
	StringView StreamingQuery;
	StringView TableName;
	StringView TailableQuery;
	StringView Value;
	StringView WorkerContinuation;
} ContinuationFieldNames;

extern const ContinuationFieldNames ContinuationFields;

/*
 * Tailable (change stream) resume tokens may carry an optional cluster-time
 * prefix ahead of their base64 body: the hex of a one-byte type marker plus an
 * 8-byte cluster time (18 hex chars). The marker matches the wire-protocol
 * timestamp type so the leading bytes read as a timestamp. Legacy tokens have
 * no prefix and their base64 body starts with a different character.
 */
#define RESUME_TOKEN_TIMESTAMP_TYPE 0x82
#define RESUME_TOKEN_PREFIX_BIN_LEN 9
#define RESUME_TOKEN_PREFIX_HEX_LEN (RESUME_TOKEN_PREFIX_BIN_LEN * 2)

char * EncodeResumeTokenWithClusterTime(const char *rawToken, uint64 clusterTime);

#endif
