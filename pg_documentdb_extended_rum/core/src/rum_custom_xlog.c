/*-------------------------------------------------------------------------
 *
 * rum_custom_xlog.c
 *	  xlog utilities routines for the postgres extended rum inverted index access method.
 *    This file provides WAL (Write-Ahead Log) support for the DocumentDB RUM
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * Note: Most portions of this file borrow very heavily from GIN's XLog routines
 * for applying and redoing WAL.
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/generic_xlog.h"
#include "miscadmin.h"
#include "storage/predicate.h"
#include "access/xlog_internal.h"
#include "access/rmgr.h"
#include "access/bufmask.h"
#include "access/xlogreader.h"
#include "access/xlogutils.h"

#include "pg_documentdb_rum.h"
#include "pg_documentdb_rum_xlogprivate.h"

#ifdef RUM_BUILT_IN_RMGR_MODE

void
DefineCustomRumRmgr(void)
{
	/* No-op in built-in mode */
}


#else

static MemoryContext opCtx = NULL;
static bool customRmgrRegistered = false;

static void
extended_rumRedoInsertEntry(Buffer buffer, bool isLeaf, BlockNumber rightblkno,
							void *rdata)
{
	Page page = BufferGetPage(buffer);
	ginxlogInsertEntry *data = (ginxlogInsertEntry *) rdata;
	OffsetNumber offset = data->offset;
	IndexTuple itup;

	if (rightblkno != InvalidBlockNumber)
	{
		ereport(PANIC, (errmsg(
							"unexpected right child block number in GIN INSERT record for entry page")));
	}

	if (data->isDelete)
	{
		Assert(RumPageIsLeaf(page));
		Assert(offset >= FirstOffsetNumber && offset <= PageGetMaxOffsetNumber(page));
		PageIndexTupleDelete(page, offset);
	}

	itup = &data->tuple;

	if (PageAddItem(page, (Item) itup, IndexTupleSize(itup), offset, false, false) ==
		InvalidOffsetNumber)
	{
		ereport(ERROR, errmsg("failed to add item to index page"));
	}
}


static void
extended_rum_redoInsert(XLogReaderState *record)
{
	XLogRecPtr lsn = record->EndRecPtr;
	ginxlogInsert *data = (ginxlogInsert *) XLogRecGetData(record);
	Buffer buffer;
#ifdef NOT_USED
	BlockNumber leftChildBlkno = InvalidBlockNumber;
#endif
	BlockNumber rightChildBlkno = InvalidBlockNumber;
	bool isLeaf = (data->flags & GIN_INSERT_ISLEAF) != 0;
	Assert(isLeaf);

	if (XLogReadBufferForRedo(record, 0, &buffer) == BLK_NEEDS_REDO)
	{
		Page page = BufferGetPage(buffer);
		Size len;
		char *payload = XLogRecGetBlockData(record, 0, &len);

		/* How to insert the payload is tree-type specific */
		if (data->flags & GIN_INSERT_ISDATA)
		{
			ereport(PANIC, (errmsg(
								"unexpected isdata flag in GIN INSERT record for entry page")));
		}
		else
		{
			Assert(!RumPageIsData(page));
			extended_rumRedoInsertEntry(buffer, isLeaf, rightChildBlkno, payload);
		}

		PageSetLSN(page, lsn);
		MarkBufferDirty(buffer);
	}
	if (BufferIsValid(buffer))
	{
		UnlockReleaseBuffer(buffer);
	}
}


static void
extended_rum_redo(XLogReaderState *record)
{
	uint8 info = XLogRecGetInfo(record) & ~XLR_INFO_MASK;
	MemoryContext oldCtx;

	/*
	 * GIN indexes do not require any conflict processing. NB: If we ever
	 * implement a similar optimization as we have in b-tree, and remove
	 * killed tuples outside VACUUM, we'll need to handle that here.
	 */

	oldCtx = MemoryContextSwitchTo(opCtx);
	switch (info)
	{
		case XLOG_GIN_INSERT:
		{
			extended_rum_redoInsert(record);
			break;
		}

		default:
		{
			elog(PANIC, "gin_redo: unknown op code %u", info);
		}
	}
	MemoryContextSwitchTo(oldCtx);
	MemoryContextReset(opCtx);
}


static void
extended_rum_xlog_startup(void)
{
	opCtx = AllocSetContextCreate(CurrentMemoryContext,
								  "GIN recovery temporary context",
								  ALLOCSET_DEFAULT_SIZES);
}


static void
extended_rum_xlog_cleanup(void)
{
	MemoryContextDelete(opCtx);
	opCtx = NULL;
}


static const char *
extended_rum_identify(uint8 info)
{
	const char *id = NULL;

	switch (info & ~XLR_INFO_MASK)
	{
		case XLOG_GIN_INSERT:
		{
			id = "INSERT";
			break;
		}
	}

	return id;
}


static void
extended_rum_mask(char *pagedata, BlockNumber blkno)
{
	Page page = (Page) pagedata;
	PageHeader pagehdr = (PageHeader) page;

	mask_page_lsn_and_checksum(page);
	mask_page_hint_bits(page);

	/*
	 * For a RUM_DELETED page, the page is initialized to empty.  Hence, mask
	 * the whole page content.  For other pages, mask the hole if pd_lower
	 * appears to have been set correctly.
	 */
	if (RumPageIsDeleted(page) || RumPageIsHalfDead(page))
	{
		mask_page_content(page);
	}
	else if (pagehdr->pd_lower > SizeOfPageHeaderData)
	{
		mask_unused_space(page);
	}
}


static void
extended_rum_desc(StringInfo buf, XLogReaderState *record)
{
	char *rec = XLogRecGetData(record);
	uint8 info = XLogRecGetInfo(record) & ~XLR_INFO_MASK;
	switch (info)
	{
		case XLOG_GIN_INSERT:
		{
			ginxlogInsert *xlrec = (ginxlogInsert *) rec;
			appendStringInfo(buf, "isdata: %c isleaf: %c",
							 (xlrec->flags & GIN_INSERT_ISDATA) ? 'T' : 'F',
							 (xlrec->flags & GIN_INSERT_ISLEAF) ? 'T' : 'F');

			char *payload = XLogRecGetBlockData(record, 0, NULL);
			appendStringInfo(buf, " isdelete: %c",
							 (((ginxlogInsertEntry *) payload)->isDelete) ? 'T' : 'F');
			break;
		}

		default:
		{
			ereport(ERROR, (errmsg("Unsupported XLOG operation %d", info)));
		}
	}
}


void
DefineCustomRumRmgr(void)
{
	if (customRmgrRegistered)
	{
		return;
	}

	RmgrData rumRmgr =
	{
		.rm_name = "DOCDB_EXRUM",
		.rm_redo = extended_rum_redo,
		.rm_desc = extended_rum_desc,
		.rm_identify = extended_rum_identify,
		.rm_startup = extended_rum_xlog_startup,
		.rm_cleanup = extended_rum_xlog_cleanup,
		.rm_mask = extended_rum_mask,
		.rm_decode = NULL
	};

	RegisterCustomRmgr(RM_EXPERIMENTAL_ID, &rumRmgr);
	customRmgrRegistered = true;
}


#endif
