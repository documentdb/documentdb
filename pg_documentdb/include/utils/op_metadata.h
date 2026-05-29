#ifndef OP_METADATA_H
#define OP_METADATA_H

#if PG_VERSION_NUM >= 170000
#include <storage/proc.h>
#else
#include <storage/backendid.h>
#endif
#include "io/bson_core.h"


#define MAX_OP_COMMAND_LENGTH 1024
#define LSID_UUID_LENGTH 16
#define MAX_READ_CONCERN_LENGTH 16


/*
* OpMetadata structure stores per-operation information in shared memory.
* Process info (PID, active status, timestamps, opId) accessed from BackendStatusArray/pg_stat_activity.
* Fixed-size format optimized for shared memory access.
*/
typedef struct OpMetadata
{
/* Command BSON data (truncated to MAX_OP_COMMAND_LENGTH if larger) */
uint32_t commandLength;
char commandData[MAX_OP_COMMAND_LENGTH];

/* Logical session ID extracted from command (raw 16-byte UUID binary) */
uint8_t lsidData[LSID_UUID_LENGTH];
bool hasLsid;

/* Whether a kill signal has been sent to this operation */
bool killPending;

/* Transaction metadata extracted from command */
int64 txnNumber;
bool hasTxnNumber;
bool autocommit;
char readConcernLevel[MAX_READ_CONCERN_LENGTH];
bool hasReadConcern;

/* Cursor originating command (persists across getMore calls for pinned backends) */
int64 originatingCursorId;
uint32_t originatingCommandLength;
char originatingCommandData[MAX_OP_COMMAND_LENGTH];
bool hasOriginatingCommand;
} OpMetadata;

/* Global shared memory array for operation metadata */
extern OpMetadata *OpMetadataBackendArray;

/* GUC variable to enable/disable operation metadata collection */
extern bool EnableOpMetadataCollection;

/* Function declarations */
extern Size SharedOpMetadataShmemSize(void);
extern void SharedOpMetadataShmemInit(void);
extern void RegisterOpMetadata(OpMetadata *metadata);
/* Helper function to extract and register operation metadata from command BSON */
extern void ExtractAndRegisterOpMetadataFromCommand(pgbson *commandSpec);
extern void SetOpMetadataKillPending(int targetPid);
extern void RegisterCursorOriginatingCommand(int64 cursorId, pgbson *originatingCommand);

#endif /* OP_METADATA_H */
