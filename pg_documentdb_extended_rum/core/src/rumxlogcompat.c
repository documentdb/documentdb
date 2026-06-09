/*-------------------------------------------------------------------------
 *
 * rumxlogcompat.c
 *	  xlog utilities routines for the postgres extended rum inverted index access method.
 *
 * This file hosts WAL helpers that emit *standard* PostgreSQL rmgr records
 * on behalf of RUM, along with the cross-PG-version struct shims those
 * records require. Two families of helpers live here today:
 *
 * (a) RUM entry-page inserts that emit GIN-format xlog records instead of
 *     the default Generic xlog records. This is safe because:
 *
 *     1. RUM entry pages share the same physical page layout as GIN entry
 *        pages. The entry page structure (leaf entries with index tuples
 *        at offsets) is identical between GIN and RUM.
 *
 *     2. The GIN INSERT redo logic for entry pages performs the same
 *        mutation that RUM does: it optionally deletes an existing tuple
 *        at the given offset and then adds the new tuple at that offset.
 *        This delete + add operation is exactly what RUM needs when
 *        replacing an entry (e.g., updating a posting list pointer after
 *        the posting list grows into a posting tree).
 *
 *     3. By using GIN's record-level xlog format, we avoid the Generic
 *        xlog approach which stores a full-page XOR diff (~8KB worst case
 *        per page modification). The GIN entry insert record only stores
 *        the inserted tuple data (typically tens of bytes), dramatically
 *        reducing WAL volume for workloads with many duplicate keys.
 *
 * (b) XLOG_BTREE_REUSE_PAGE markers emitted before RUM reclaims space from
 *     dead entries on an entry page. Borrowing nbtree's record format lets
 *     hot standbys resolve recovery conflicts using the existing built-in
 *     btree rmgr, with no custom redo path required.
 *
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
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
#include "access/nbtxlog.h"
#include "access/transam.h"
#include "storage/procarray.h"

#include "pg_documentdb_rum.h"
#include "pg_documentdb_rum_xlogprivate.h"


/*
 * Promote a 32-bit horizon TransactionId to a FullTransactionId.
 *
 * Mirrors widen_snapshot_xid() in src/backend/utils/adt/xid8funcs.c, which
 * is static there. The 64-bit result must be <= next_fxid; every snapshot
 * xid is therefore from the same epoch as next_fxid or the epoch before.
 */
static FullTransactionId
WidenSnapshotXid(TransactionId xid, FullTransactionId next_fxid)
{
	TransactionId nextXid = XidFromFullTransactionId(next_fxid);
	uint32 epoch = EpochFromFullTransactionId(next_fxid);

	if (!TransactionIdIsNormal(xid))
	{
		return FullTransactionIdFromEpochAndXid(0, xid);
	}

	if (xid > nextXid)
	{
		epoch--;
	}

	return FullTransactionIdFromEpochAndXid(epoch, xid);
}


/*
 * Emit an XLOG_BTREE_REUSE_PAGE marker so hot standbys can resolve recovery
 * conflicts before we reuse space freed by dead index entries on `buf`.
 */
void
RumLogReusePage(Relation index, Buffer buf)
{
	Page page = BufferGetPage(buf);
	TransactionId horizon = RumPageGetDeleteXid(page);
	FullTransactionId conflictHorizon =
		WidenSnapshotXid(horizon, ReadNextFullTransactionId());
	xl_btree_reuse_page xlrec_reuse;

	xlrec_reuse.block = BufferGetBlockNumber(buf);
#if PG_VERSION_NUM >= 160000
	xlrec_reuse.locator = index->rd_locator;
	xlrec_reuse.snapshotConflictHorizon = conflictHorizon;
	xlrec_reuse.isCatalogRel = false;
#else
	xlrec_reuse.node = index->rd_node;
	xlrec_reuse.latestRemovedFullXid = conflictHorizon;
#endif

	XLogBeginInsert();
	XLogRegisterData((char *) &xlrec_reuse, SizeOfBtreeReusePage);
	XLogInsert(RM_BTREE_ID, XLOG_BTREE_REUSE_PAGE);
}


#if PG_VERSION_NUM >= 190000
#error "rumxlogcompat.c is not expected to be compiled for PG 19 or later"
#endif


/*
 * SupportsXLogInsertForEntry
 *
 * Returns true if the current entry page insert can use the GIN xlog insert
 * record format instead of Generic xlog. This is only safe for leaf entry
 * pages (not data pages or internal pages), and only when there is no child
 * buffer involved (i.e., we are not completing an incomplete split).
 */
bool
SupportsXLogInsertForEntry(Page page, Buffer childbuf)
{
	return RumEnableXlogInsertEntry && RumPageIsLeaf(page) &&
		   !RumPageIsData(page) && !BufferIsValid(childbuf) &&
#ifdef RUM_BUILT_IN_RMGR_MODE
		   true;
#else
		   EnableCustomXlogRmgr;
#endif
}


/*
 * WriteInsertEntryWalRecord
 *
 * Registers the entry tuple data for a GIN-compatible xlog insert record.
 * The isDelete flag indicates whether an existing tuple at the given offset
 * should be removed before inserting the new one — this mirrors GIN's redo
 * behavior which performs the same delete + add sequence on replay.
 */
void
WriteInsertEntryWalRecord(bool isDelete, OffsetNumber off, IndexTuple entry)
{
	static ginxlogInsertEntry data;
	data.isDelete = isDelete;
	data.offset = off;

	XLogRegisterBufData(0, (char *) &data,
						offsetof(ginxlogInsertEntry, tuple));
	XLogRegisterBufData(0, (char *) entry,
						IndexTupleSize(entry));
}


/*
 * WriteInsertWalRecord
 *
 * Finalizes and emits the GIN INSERT xlog record for a leaf entry page.
 * Uses RM_GIN_ID as the resource manager so that PostgreSQL's built-in GIN
 * redo handler (gin_xlog_insert) replays the record. The redo handler
 * performs the same delete-at-offset + add-at-offset mutation that was
 * applied during the original insert, ensuring crash recovery correctness.
 */
void
WriteInsertWalRecord(Buffer buffer, Page page)
{
	XLogRecPtr recptr;
	ginxlogInsert xlrec;
	uint16 xlflags = GIN_INSERT_ISLEAF;

	xlrec.flags = xlflags;

	XLogRegisterData((char *) &xlrec, sizeof(ginxlogInsert));
#ifdef RUM_BUILT_IN_RMGR_MODE
	recptr = XLogInsert(RM_GIN_ID, XLOG_GIN_INSERT);
#else
	recptr = XLogInsert(RM_EXPERIMENTAL_ID, XLOG_GIN_INSERT);
#endif
	MarkBufferDirty(buffer);
	PageSetLSN(page, recptr);
}
