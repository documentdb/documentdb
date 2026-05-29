#include <postgres.h>
	 #include <miscadmin.h>
	 #include <fmgr.h>
	 #include <funcapi.h>
	 #include <storage/shmem.h>
	 #include <storage/ipc.h>
	 #include <utils/timestamp.h>
	 #include <sys/time.h>
	 #include <lib/stringinfo.h>
	 
	 #include "utils/op_metadata.h"
	 #include "io/bson_core.h"
	 #include "pgstat.h"
	 
	 /* Global shared memory array for operation metadata */
	 OpMetadata *OpMetadataBackendArray = NULL;
	 
	 /*
	  * SharedOpMetadataShmemSize
	  *
	  * Calculate the size of shared memory needed for the operation metadata array.
	  * Similar to feature_counter, we allocate one OpMetadata slot per backend.
	  */
	 Size
	 SharedOpMetadataShmemSize(void)
	 {
	 	return mul_size(sizeof(OpMetadata), MaxBackends);
	 }
	 
	 
	 /*
	  * SharedOpMetadataShmemInit
	  *
	  * Initialize the shared memory used for operation metadata tracking.
	  * This is called during shared memory initialization.
	  */
	 void
	 SharedOpMetadataShmemInit(void)
	 {
	 	bool found;
	 	size_t op_metadata_shmem_size = SharedOpMetadataShmemSize();
	 
	 	OpMetadataBackendArray = (OpMetadata *)
	 							 ShmemInitStruct("Op Metadata Array",
	 											 op_metadata_shmem_size, &found);
	 
	 	if (!found)
	 	{
	 		/*
	 		 * We're the first - initialize all slots to inactive.
	 		 */
	 		MemSet(OpMetadataBackendArray, 0, op_metadata_shmem_size);
	 	}
	 }


	 /*
	  * GetCurrentBackendIndex
	  *
	  * Returns the shared memory slot index for the current backend.
	  * Returns -1 if the index is invalid.
	  */
	 static inline int
	 GetCurrentBackendIndex(void)
	 {
#if PG_VERSION_NUM >= 170000
	 	return MyProcNumber;
#else
	 	return MyBackendId - 1;
#endif
	 }
	 
	 
	 /*
	  * RegisterOpMetadata
	  *
	  * Register operation metadata in the shared memory array for the current backend.
	  * This should be called at the beginning of an operation (e.g., insert command).
	  *
	  * The metadata is written to the slot corresponding to the current backend ID.
	  */
	 void
	 RegisterOpMetadata(OpMetadata *metadata)
	 {
	 	/* Check if operation metadata collection is enabled */
	 	if (!EnableOpMetadataCollection || OpMetadataBackendArray == NULL)
	 	{
	 		return;
	 	}
	 
	 	if (metadata == NULL)
	 	{
	 		return;
	 	}
	 
	 	int backendIndex = GetCurrentBackendIndex();
	 
	 	if (backendIndex < 0 || backendIndex >= MaxBackends)
	 	{
	 		return;
	 	}
	 
	 	/* Use MyBEEntry's changecount protocol to protect concurrent access */
	 	volatile PgBackendStatus *beentry = MyBEEntry;
	 	
	 	if (!beentry)
	 	{
	 		return;
	 	}
	 	
	 	PGSTAT_BEGIN_WRITE_ACTIVITY(beentry);
	 	
	 	/* Copy the metadata to the shared memory slot while changecount is odd */
	 	memcpy(&OpMetadataBackendArray[backendIndex], metadata, sizeof(OpMetadata));
	 	
	 	PGSTAT_END_WRITE_ACTIVITY(beentry);
	 }
	 
	 
	 /*
	  * ExtractAndRegisterOpMetadataFromCommand
	  *
	  * Helper function that extracts operation metadata (including lsid) from a command BSON
	  * and stores it in shared memory for currentOp visibility.
	  *
	  * This function should be called by all command handlers (insert, find, update, count, etc.)
	  * at the beginning of command execution via documentDbPreCommand().
	  *
	  * Parameters:
	  *   commandSpec - The full command BSON specification containing the command name,
	  *                 collection name, and any metadata fields (lsid, $db, etc.)
	  */
	 void
	 ExtractAndRegisterOpMetadataFromCommand(pgbson *commandSpec)
	 {
	 	OpMetadata metadata;
	 	MemSet(&metadata, 0, sizeof(OpMetadata));
	 
	 	/* Check if operation metadata collection is enabled */
	 	if (!EnableOpMetadataCollection || OpMetadataBackendArray == NULL)
	 	{
	 		return;
	 	}

	 	if (commandSpec == NULL)
	 	{
	 		return;
	 	}

	 	/*
	 	 * Preserve cursor originating command across MemSet.
	 	 * For pinned backends (persistent cursors), the originating command
	 	 * was set once at cursor creation and should persist across getMore calls.
	 	 * Safe to read without changecount — this is our own slot, and only we
	 	 * write the originating command fields.
	 	 */
	 	int backendIndex = GetCurrentBackendIndex();
	 	if (backendIndex >= 0 && backendIndex < MaxBackends &&
	 		OpMetadataBackendArray[backendIndex].hasOriginatingCommand)
	 	{
	 		metadata.originatingCursorId = OpMetadataBackendArray[backendIndex].originatingCursorId;
	 		metadata.originatingCommandLength = OpMetadataBackendArray[backendIndex].originatingCommandLength;
	 		/* Defense-in-depth: clamp length to prevent buffer overflow if value is corrupted */
	 		if (metadata.originatingCommandLength > MAX_OP_COMMAND_LENGTH)
	 			metadata.originatingCommandLength = MAX_OP_COMMAND_LENGTH;
	 		memcpy(metadata.originatingCommandData,
	 			   OpMetadataBackendArray[backendIndex].originatingCommandData,
	 			   metadata.originatingCommandLength);
	 		metadata.hasOriginatingCommand = true;
	 	}
	 
	 	/* Extract lsid, txnNumber, autocommit, readConcern from the command */
	 	bson_iter_t commandIter;
	 	PgbsonInitIterator(commandSpec, &commandIter);
	 
	 	while (bson_iter_next(&commandIter))
	 	{
	 		const char *field = bson_iter_key(&commandIter);
	 
	 		if (strcmp(field, "lsid") == 0 && BSON_ITER_HOLDS_DOCUMENT(&commandIter))
	 		{
	 			/* Extract lsid.id UUID */
	 			bson_iter_t lsidIter;
	 			if (bson_iter_recurse(&commandIter, &lsidIter))
	 			{
	 				while (bson_iter_next(&lsidIter))
	 				{
	 					if (strcmp(bson_iter_key(&lsidIter), "id") == 0)
	 					{
	 						const bson_value_t *idValue = bson_iter_value(&lsidIter);
	 						if (idValue->value_type == BSON_TYPE_BINARY &&
	 							idValue->value.v_binary.subtype == BSON_SUBTYPE_UUID &&
	 							idValue->value.v_binary.data_len == 16)
	 						{
	 							/* Store raw UUID bytes directly */
	 							const uint8_t *uuid_data = idValue->value.v_binary.data;
	 							memcpy(metadata.lsidData, uuid_data, LSID_UUID_LENGTH);
	 							metadata.hasLsid = true;
	 						}
	 						break;
	 					}
	 				}
	 			}
	 		}
	 		else if (strcmp(field, "txnNumber") == 0)
	 		{
	 			const bson_value_t *val = bson_iter_value(&commandIter);
	 			if (val->value_type == BSON_TYPE_INT64)
	 			{
	 				metadata.txnNumber = val->value.v_int64;
	 				metadata.hasTxnNumber = true;
	 			}
	 			else if (val->value_type == BSON_TYPE_INT32)
	 			{
	 				metadata.txnNumber = val->value.v_int32;
	 				metadata.hasTxnNumber = true;
	 			}
	 		}
	 		else if (strcmp(field, "autocommit") == 0)
	 		{
	 			const bson_value_t *val = bson_iter_value(&commandIter);
	 			if (val->value_type == BSON_TYPE_BOOL)
	 				metadata.autocommit = val->value.v_bool;
	 		}
	 		else if (strcmp(field, "readConcern") == 0 && BSON_ITER_HOLDS_DOCUMENT(&commandIter))
	 		{
	 			bson_iter_t rcIter;
	 			if (bson_iter_recurse(&commandIter, &rcIter))
	 			{
	 				while (bson_iter_next(&rcIter))
	 				{
	 					if (strcmp(bson_iter_key(&rcIter), "level") == 0)
	 					{
	 						const bson_value_t *val = bson_iter_value(&rcIter);
	 						if (val->value_type == BSON_TYPE_UTF8 &&
	 							val->value.v_utf8.len < MAX_READ_CONCERN_LENGTH)
	 						{
	 							memcpy(metadata.readConcernLevel, val->value.v_utf8.str,
	 								   val->value.v_utf8.len);
	 							metadata.readConcernLevel[val->value.v_utf8.len] = '\0';
	 							metadata.hasReadConcern = true;
	 						}
	 						break;
	 					}
	 				}
	 			}
	 		}
	 	}
	 
	 	/* Store the command as raw BSON */
	 	const uint8_t *bsonData = (const uint8_t *) VARDATA(commandSpec);
	 	uint32_t bsonLength = VARSIZE(commandSpec) - VARHDRSZ;
	 
	 	/*
	 	 * Store up to MAX_OP_COMMAND_LENGTH bytes.
	 	 * BSON format already has its length in the first 4 bytes, so even if
	 	 * truncated, we know the original intended length.
	 	 */
	 	uint32_t storedLength = bsonLength;
	 	if (storedLength > MAX_OP_COMMAND_LENGTH)
	 	{
	 		storedLength = MAX_OP_COMMAND_LENGTH;
	 	}
	 
	 	metadata.commandLength = storedLength;
	 	memcpy(metadata.commandData, bsonData, storedLength);
	 
	 	/* Register the metadata in shared memory */
	 	RegisterOpMetadata(&metadata);
	 }
	 
	 
	 /*
	  * SetOpMetadataKillPending
	  *
	  * Sets the killPending flag in the OpMetadata slot for the backend with the given PID.
	  * Called from killOp before sending the cancel/terminate signal.
	  *
	  * Note: We intentionally do NOT use the PGSTAT changecount protocol here.
	  * A single bool write is atomic on all supported architectures (x86/ARM).
	  * The pg_write_barrier() ensures visibility to readers. Using the full
	  * changecount protocol would require access to the target backend's MyBEEntry,
	  * which is not safely accessible from another backend.
	  *
	  * Cleanup philosophy: We do not clear killPending when an operation completes.
	  * The slot is overwritten when the next command starts via
	  * ExtractAndRegisterOpMetadataFromCommand (which MemSets the entire struct to 0).
	  * The read side only reads OpMetadata for active backends, so stale data in
	  * idle backend slots is never emitted.
	  */
	 void
	 SetOpMetadataKillPending(int targetPid)
	 {
	 	if (!EnableOpMetadataCollection || OpMetadataBackendArray == NULL)
	 		return;
	 
	 	int numBackends = pgstat_fetch_stat_numbackends();
	 	for (int i = 1; i <= numBackends; i++)
	 	{
	 		LocalPgBackendStatus *localBe = pgstat_get_local_beentry_by_index(i);
	 		if (localBe == NULL)
	 			continue;
	 
	 		PgBackendStatus *beStatus = &localBe->backendStatus;
	 		if (beStatus->st_procpid != targetPid)
	 			continue;
	 
	 		int backendIndex;
	 #if PG_VERSION_NUM >= 170000
	 		backendIndex = localBe->proc_number;
	 #else
	 		backendIndex = localBe->backend_id - 1;
	 #endif
	 
	 		if (backendIndex < 0 || backendIndex >= MaxBackends)
	 			break;
	 
	 		/*
	 		 * We write to another backend's slot here. Since we're only setting
	 		 * a single bool, the write is atomic on all supported architectures.
	 		 * We use a write barrier to ensure visibility to readers.
	 		 */
	 		OpMetadataBackendArray[backendIndex].killPending = true;
	 		pg_write_barrier();
	 
	 		break;
	 	}
	 }



	 /*
	  * RegisterCursorOriginatingCommand
	  *
	  * Stores the originating command (find/aggregate) and cursor ID in the current
	  * backend's OpMetadata slot. This data persists across getMore calls for pinned
	  * backends (persistent cursors) because ExtractAndRegisterOpMetadataFromCommand
	  * preserves these fields across its MemSet.
	  *
	  * Called once at cursor creation time in HandleFirstPageRequest.
	  */
	 void
	 RegisterCursorOriginatingCommand(int64 cursorId, pgbson *originatingCommand)
	 {
	 	if (!EnableOpMetadataCollection || OpMetadataBackendArray == NULL)
	 		return;

	 	if (originatingCommand == NULL)
	 		return;

	 	int backendIndex = GetCurrentBackendIndex();

	 	if (backendIndex < 0 || backendIndex >= MaxBackends)
	 		return;

	 	const uint8_t *bsonData = (const uint8_t *) VARDATA(originatingCommand);
	 	uint32_t bsonLength = VARSIZE(originatingCommand) - VARHDRSZ;
	 	uint32_t storedLength = bsonLength;
	 	if (storedLength > MAX_OP_COMMAND_LENGTH)
	 		storedLength = MAX_OP_COMMAND_LENGTH;

	 	/* Use changecount protocol to protect the multi-field write. Without this,
	 	 * a concurrent reader could see a stable (even) changecount from the earlier
	 	 * RegisterOpMetadata call while we're mid-write here, resulting in torn data.
	 	 * Since this is our own backend's slot, MyBEEntry is safely accessible. */
	 	volatile PgBackendStatus *beentry = MyBEEntry;
	 	if (!beentry)
	 		return;

	 	PGSTAT_BEGIN_WRITE_ACTIVITY(beentry);

	 	OpMetadataBackendArray[backendIndex].originatingCursorId = cursorId;
	 	OpMetadataBackendArray[backendIndex].originatingCommandLength = storedLength;
	 	memcpy(OpMetadataBackendArray[backendIndex].originatingCommandData, bsonData, storedLength);
	 	OpMetadataBackendArray[backendIndex].hasOriginatingCommand = true;

	 	PGSTAT_END_WRITE_ACTIVITY(beentry);
	 }
