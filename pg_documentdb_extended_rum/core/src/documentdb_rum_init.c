/*-------------------------------------------------------------------------
 *
 * documentdb_rum_init.c
 *	  initialization routines for the DocumentDB RUM index access method.
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "utils/builtins.h"
#include "utils/guc.h"
#include "miscadmin.h"
#include "pg_documentdb_rum.h"

PG_MODULE_MAGIC;

void _PG_init(void);

extern PGDLLEXPORT bool documentdb_rum_get_multi_key_status(Relation indexRelation);
extern PGDLLEXPORT void documentdb_rum_update_multi_key_status(Relation indexRelation);

extern PGDLLIMPORT void InitializeCommonDocumentDBGUCs(const char *rumGucPrefix, const
													   char *documentDBRumGucPrefix);

extern PGDLLIMPORT bool DocumentDBRumLoadCommonGUCs;

/*
 * Module load callback
 */
PGDLLEXPORT void
_PG_init(void)
{
	/* Assert things about the storage format */
	StaticAssertExpr(offsetof(RumPageOpaqueData, dataPageMaxoff) == sizeof(uint64_t),
					 "maxoff must be the 3rd field with a specific offset");
	StaticAssertExpr(offsetof(RumPageOpaqueData, entryPageUnused) == sizeof(uint64_t),
					 "entryPageCycleId must be the 3rd field with a specific offset");
	StaticAssertExpr(offsetof(RumPageOpaqueData, dataPageFreespace) == sizeof(uint64_t) +
					 sizeof(uint16_t),
					 "freespace must be the 3rd field with a specific offset");
	StaticAssertExpr(offsetof(RumPageOpaqueData, flags) == sizeof(uint64_t) +
					 sizeof(uint32_t),
					 "flags must be the 3rd field with a specific offset");

	StaticAssertExpr(offsetof(RumPageOpaqueData, cycleId) == sizeof(uint64_t) +
					 sizeof(uint32_t) + sizeof(uint16_t),
					 "cycleId must be the 4th field with a specific offset");
	StaticAssertExpr(sizeof(RumPageOpaqueData) == sizeof(uint64_t) + sizeof(uint64_t),
					 "RumPageOpaqueData must be the 2 bigint fields worth");

	StaticAssertExpr(sizeof(RumItem) == 16 && MAXALIGN(sizeof(RumItem)) == 16,
					 "rum item aligned should be 16 bytes");
	StaticAssertExpr(sizeof(RumDataLeafItemIndex) == 24, "LeafItemIndex is 24 bytes");

	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"pg_documentdb_extended_rum_core can only be loaded via shared_preload_libraries"),
						errdetail_log(
							"Add the caller library to shared_preload_libraries configuration "
							"variable in postgresql.conf. ")));
	}

	InitializeRumVacuumState();

	/* Define custom GUC variables. (if any) */
	if (DocumentDBRumLoadCommonGUCs)
	{
		DocumentDBRumLoadCommonGUCs = false;
		InitializeCommonDocumentDBGUCs("documentdb_rum", "documentdb_rum");
	}

	MarkGUCPrefixReserved("documentdb_rum");
}


PGDLLEXPORT bool
documentdb_rum_get_multi_key_status(Relation indexRelation)
{
	Buffer metabuffer;
	Page metapage;
	RumMetaPageData *metadata;
	bool hasMultiKeyPaths = false;

	metabuffer = ReadBuffer(indexRelation, RUM_METAPAGE_BLKNO);
	LockBuffer(metabuffer, RUM_SHARE);
	metapage = BufferGetPage(metabuffer);
	metadata = RumPageGetMeta(metapage);
	hasMultiKeyPaths = metadata->nPendingHeapTuples > 0;
	UnlockReleaseBuffer(metabuffer);

	return hasMultiKeyPaths;
}


PGDLLEXPORT void
documentdb_rum_update_multi_key_status(Relation index)
{
	/* First do a get to see if we even need to update */
	bool isMultiKey = documentdb_rum_get_multi_key_status(index);
	if (isMultiKey)
	{
		return;
	}

	Buffer metaBuffer;
	Page metapage;
	RumMetaPageData *metadata;
	GenericXLogState *state;

	metaBuffer = ReadBuffer(index, RUM_METAPAGE_BLKNO);
	LockBuffer(metaBuffer, RUM_EXCLUSIVE);

	state = GenericXLogStart(index);
	metapage = GenericXLogRegisterBuffer(state, metaBuffer, 0);
	metadata = RumPageGetMeta(metapage);

	/* Set pending heap tuples to 1 to indicate this is a multi-key index */
	metadata->nPendingHeapTuples = 1;

	GenericXLogFinish(state);
	UnlockReleaseBuffer(metaBuffer);
}
