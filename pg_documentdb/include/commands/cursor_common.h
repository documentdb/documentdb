/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/commands/cursor_common.h
 *
 * Common declarations of Cursor commands.
 *
 *-------------------------------------------------------------------------
 */

extern const StringView CursorContinuationTableName;
extern const StringView CursorContinuationValue;
extern const StringView PrimaryKeyShardKey;

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
