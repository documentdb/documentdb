/*-------------------------------------------------------------------------
 *
 * rumentrypage.c
 *	  page utilities routines for the postgres inverted index access method.
 *
 * Portions Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 1996-2013, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/table.h"
#include "access/tableam.h"
#include "lib/qunique.h"
#include "miscadmin.h"
#include "pg_documentdb_rum.h"
#include "utils/rel.h"
#include <utils/hsearch.h>

static inline int _entrypage_blk_cmp(const void *arg1, const void *arg2);

/* How to prepare the entry page for insertion */
typedef enum EntryPrepareMode
{
	/* Force delete the existing tuple */
	EntryPrepareMode_ForceDelete = 0,

	/* Allow replacing the existing tuple if it exists and can fit */
	EntryPrepareMode_AllowReplace = 1,

	/* Delete the existing tuple, but we don't need to reclaim space */
	EntryPrepareMode_Delete = 2
} EntryPrepareMode;

/*
 * Form a tuple for entry tree.
 *
 * If the tuple would be too big to be stored, function throws a suitable
 * error if errorTooBig is true, or returns NULL if errorTooBig is false.
 *
 * See src/backend/access/gin/README for a description of the index tuple
 * format that is being built here.  We build on the assumption that we
 * are making a leaf-level key entry containing a posting list of nipd items.
 * If the caller is actually trying to make a posting-tree entry, non-leaf
 * entry, or pending-list entry, it should pass nipd = 0 and then overwrite
 * the t_tid fields as necessary.  In any case, items can be NULL to skip
 * copying any itempointers into the posting list; the caller is responsible
 * for filling the posting list afterwards, if items = NULL and nipd > 0.
 */
IndexTuple
RumFormTuple(RumState *rumstate,
			 OffsetNumber attnum, Datum key, RumNullCategory category,
			 RumItem *items, uint32 nipd, bool errorTooBig)
{
	Datum datums[3];
	bool isnull[3];
	IndexTuple itup;
	uint32 newsize;
	int i;
	ItemPointerData nullItemPointer = { { 0, 0 }, 0 };

	/* Build the basic tuple: optional column number, plus key datum */
	if (rumstate->oneCol)
	{
		datums[0] = key;
		isnull[0] = (category != RUM_CAT_NORM_KEY);
		isnull[1] = true;
	}
	else
	{
		datums[0] = UInt16GetDatum(attnum);
		isnull[0] = false;
		datums[1] = key;
		isnull[1] = (category != RUM_CAT_NORM_KEY);
		isnull[2] = true;
	}

	itup = index_form_tuple(rumstate->tupdesc[attnum - 1], datums, isnull);

	/*
	 * Determine and store offset to the posting list, making sure there is
	 * room for the category byte if needed.
	 *
	 * Note: because index_form_tuple MAXALIGNs the tuple size, there may well
	 * be some wasted pad space.  Is it worth recomputing the data length to
	 * prevent that?  That would also allow us to Assert that the real data
	 * doesn't overlap the RumNullCategory byte, which this code currently
	 * takes on faith.
	 */
	newsize = IndexTupleSize(itup);

	RumSetPostingOffset(itup, newsize);

	RumSetNPosting(itup, nipd);

	/*
	 * Add space needed for posting list, if any.  Then check that the tuple
	 * won't be too big to store.
	 */

	if (nipd > 0)
	{
		newsize = rumCheckPlaceToDataPageLeaf(attnum, &items[0],
											  &nullItemPointer,
											  rumstate, newsize);
		for (i = 1; i < nipd; i++)
		{
			newsize = rumCheckPlaceToDataPageLeaf(attnum, &items[i],
												  &items[i - 1].iptr,
												  rumstate, newsize);
		}
	}


	if (category != RUM_CAT_NORM_KEY)
	{
		Assert(IndexTupleHasNulls(itup));
		newsize = newsize + sizeof(RumNullCategory);
	}
	newsize = MAXALIGN(newsize);

	if (newsize > RumMaxItemSize)
	{
		if (errorTooBig)
		{
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("index row size %lu exceeds maximum %lu for index \"%s\"",
							(unsigned long) newsize,
							(unsigned long) RumMaxItemSize,
							RelationGetRelationName(rumstate->index))));
		}
		pfree(itup);
		return NULL;
	}

	/*
	 * Resize tuple if needed
	 */
	if (newsize != IndexTupleSize(itup))
	{
		itup = repalloc(itup, newsize);

		memset((char *) itup + IndexTupleSize(itup),
			   0, newsize - IndexTupleSize(itup));

		/* set new size in tuple header */
		itup->t_info &= ~INDEX_SIZE_MASK;
		itup->t_info |= newsize;
	}

	/*
	 * Copy in the posting list, if provided
	 */
	if (nipd > 0)
	{
		char *ptr = RumGetPosting(itup);

		ptr = rumPlaceToDataPageLeaf(ptr, attnum, &items[0],
									 &nullItemPointer, rumstate);
		for (i = 1; i < nipd; i++)
		{
			ptr = rumPlaceToDataPageLeaf(ptr, attnum, &items[i],
										 &items[i - 1].iptr, rumstate);
		}

		Assert(MAXALIGN((ptr - ((char *) itup)) +
						((category == RUM_CAT_NORM_KEY) ? 0 : sizeof(RumNullCategory))) ==
			   newsize);
	}

	/*
	 * Insert category byte, if needed
	 */
	if (category != RUM_CAT_NORM_KEY)
	{
		Assert(IndexTupleHasNulls(itup));
		RumSetNullCategory(itup, category);
	}

	return itup;
}


/*
 * Read item pointers with additional information from leaf data page.
 * Information is stored in the same manner as in leaf data pages.
 */
void
rumReadTuple(RumState *rumstate, OffsetNumber attnum,
			 IndexTuple itup, RumItem *items, bool copyAddInfo)
{
	Pointer ptr = RumGetPosting(itup);
	RumItem item;
	int nipd = RumGetNPosting(itup),
		i;
	RumItemSetMin(&item);

	InitBlockNumberIncr(blockNumberIncr, (&item.iptr));
	for (i = 0; i < nipd; i++)
	{
		ptr = rumDataPageLeafReadWithBlockNumberIncr(ptr, attnum, &item, copyAddInfo,
													 rumstate, &blockNumberIncr);
		items[i] = item;
	}
}


/*
 * Read only item pointers from leaf data page.
 * Information is stored in the same manner as in leaf data pages.
 */
void
rumReadTuplePointers(RumState *rumstate, OffsetNumber attnum,
					 IndexTuple itup, ItemPointerData *ipd)
{
	Pointer ptr = RumGetPosting(itup);
	int nipd = RumGetNPosting(itup),
		i;
	RumItem item;

	ItemPointerSetMin(&item.iptr);
	for (i = 0; i < nipd; i++)
	{
		ptr = rumDataPageLeafReadPointer(ptr, attnum, &item, rumstate);
		ipd[i] = item.iptr;
	}
}


/*
 * Form a non-leaf entry tuple by copying the key data from the given tuple,
 * which can be either a leaf or non-leaf entry tuple.
 *
 * Any posting list in the source tuple is not copied.  The specified child
 * block number is inserted into t_tid.
 */
static IndexTuple
RumFormInteriorTuple(RumBtree btree, IndexTuple itup, Page page,
					 BlockNumber childblk)
{
	IndexTuple nitup;
	RumNullCategory category;

	if (RumPageIsLeaf(page) && !RumIsPostingTree(itup))
	{
		/* Tuple contains a posting list, just copy stuff before that */
		uint32 origsize = RumGetPostingOffset(itup);

		origsize = MAXALIGN(origsize);
		nitup = (IndexTuple) palloc(origsize);
		memcpy(nitup, itup, origsize);

		/* ... be sure to fix the size header field ... */
		nitup->t_info &= ~INDEX_SIZE_MASK;
		nitup->t_info |= origsize;
	}
	else
	{
		/* Copy the tuple as-is */
		nitup = (IndexTuple) palloc(IndexTupleSize(itup));
		memcpy(nitup, itup, IndexTupleSize(itup));
	}

	/* Now insert the correct downlink */
	RumSetDownlink(nitup, childblk);

	rumtuple_get_key(btree->rumstate, itup, &category);
	if (category != RUM_CAT_NORM_KEY)
	{
		Assert(IndexTupleHasNulls(itup));
		nitup->t_info |= INDEX_NULL_MASK;
		RumSetNullCategory(nitup, category);
	}

	return nitup;
}


/*
 * Entry tree is a "static", ie tuple never deletes from it,
 * so we don't use right bound, we use rightmost key instead.
 */
IndexTuple
rumEntryGetRightMostTuple(Page page)
{
	OffsetNumber maxoff = PageGetMaxOffsetNumber(page);

	Assert(maxoff != InvalidOffsetNumber);

	return (IndexTuple) PageGetItem(page, PageGetItemId(page, maxoff));
}


/*
 * Steps in the direction specified in the entryTree for read-only scans.
 * This is different from rumStep for a few reasons:
 * Typically for Vacuum, we want to avoid races where a page could get deleted
 * as we're traversing into it. To avoid this race, we acquire the lock on the
 * next page first, then release the current page. However, this means that there is
 * no opportunity where we have no locks to check for interrupts.
 * We cannot release first, and then lock the next page typically since that races
 * with vacuum page deletion. However, for entry pages, deleted pages enter a half-dead
 * state and only get recycled after the transaction xid min. Consequently, stepping
 * for entry pages can release, check for interrupts, and then acquire the next page.
 */
Buffer
rumStepEntryForScans(Buffer buffer, Relation index, ScanDirection scanDirection)
{
	Buffer nextbuffer;
	Page page = BufferGetPage(buffer);
	bool isLeaf = RumPageIsLeaf(page);
	bool isData = RumPageIsData(page);
	BlockNumber blkno;

entryScanBegin:
	blkno = (ScanDirectionIsForward(scanDirection)) ?
			RumPageGetOpaque(page)->rightlink :
			RumPageGetOpaque(page)->leftlink;

	if (blkno == InvalidBlockNumber)
	{
		UnlockReleaseBuffer(buffer);
		return InvalidBuffer;
	}

	/* First unlock and release the current buffer */
	UnlockReleaseBuffer(buffer);

	/* Check for interrupts when we're not holding any pins or locks */
	CHECK_FOR_INTERRUPTS();

	/* Lock and read the next buffer */
	nextbuffer = ReadBuffer(index, blkno);
	LockBuffer(nextbuffer, RUM_SHARE);

	/* Sanity check that the page we stepped to is of similar kind. */
	rumCheckTreePage(index, nextbuffer);
	page = BufferGetPage(nextbuffer);
	if (isLeaf != RumPageIsLeaf(page) || isData != RumPageIsData(page))
	{
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("right sibling of RUM page is of different type"),
				 errdetail("Index \"%s\", block %u.",
						   RelationGetRelationName(index), blkno),
				 errhint("Please REINDEX it.")));
	}

	/*
	 * Given the proper lock sequence above, we should never land on a deleted
	 * page.
	 */
	if (RumPageIsDeleted(page))
	{
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("%s sibling of RUM page was deleted",
						ScanDirectionIsForward(scanDirection) ? "right" : "left"),
				 errdetail("Index \"%s\", block %u.",
						   RelationGetRelationName(index), blkno)));
	}

	if (RumPageIsHalfDead(page))
	{
		/* If on a half dead page, restart and move forward */
		buffer = nextbuffer;
		goto entryScanBegin;
	}

	return nextbuffer;
}


bool
entryIsMoveRight(RumBtree btree, Page page)
{
	IndexTuple itup;
	OffsetNumber attnum;
	Datum key;
	RumNullCategory category;

	if (RumPageRightMost(page))
	{
		return false;
	}

	if (RumPageIsHalfDead(page))
	{
		/* If on a half dead page, always move right */
		return true;
	}

	itup = rumEntryGetRightMostTuple(page);
	attnum = rumtuple_get_attrnum(btree->rumstate, itup);
	key = rumtuple_get_key(btree->rumstate, itup, &category);

	if (rumCompareAttEntries(btree->rumstate,
							 btree->entryAttnum, btree->entryKey, btree->entryCategory,
							 attnum, key, category) > 0)
	{
		return true;
	}

	return false;
}


/*
 * Find correct tuple in non-leaf page. It supposed that
 * page correctly chosen and searching value SHOULD be on page
 */
static BlockNumber
entryLocateEntry(RumBtree btree, RumBtreeStack *stack)
{
	OffsetNumber low,
				 high,
				 maxoff;
	IndexTuple itup = NULL;
	int result;
	Page page = BufferGetPage(stack->buffer);

	Assert(!RumPageIsLeaf(page));
	Assert(!RumPageIsData(page));

	if (btree->fullScan)
	{
		stack->off = FirstOffsetNumber;
		stack->predictNumber *= PageGetMaxOffsetNumber(page);
		return btree->getLeftMostPage(btree, page);
	}

	low = FirstOffsetNumber;
	maxoff = high = PageGetMaxOffsetNumber(page);
	Assert(high >= low);

	high++;

	while (high > low)
	{
		OffsetNumber mid = low + ((high - low) / 2);

		if (mid == maxoff && RumPageRightMost(page))
		{
			/* Right infinity */
			result = -1;
		}
		else
		{
			OffsetNumber attnum;
			Datum key;
			RumNullCategory category;

			itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, mid));
			attnum = rumtuple_get_attrnum(btree->rumstate, itup);
			key = rumtuple_get_key(btree->rumstate, itup, &category);
			result = rumCompareAttEntries(btree->rumstate,
										  btree->entryAttnum,
										  btree->entryKey,
										  btree->entryCategory,
										  attnum, key, category);
		}

		if (result == 0)
		{
			stack->off = mid;
			Assert(RumGetDownlink(itup) != RUM_ROOT_BLKNO);
			return RumGetDownlink(itup);
		}
		else if (result > 0)
		{
			low = mid + 1;
		}
		else
		{
			high = mid;
		}
	}

	Assert(high >= FirstOffsetNumber && high <= maxoff);

	stack->off = high;
	itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, high));
	Assert(RumGetDownlink(itup) != RUM_ROOT_BLKNO);
	return RumGetDownlink(itup);
}


/*
 * Searches correct position for value on leaf page.
 * Page should be correctly chosen.
 * Returns true if value found on page.
 */
static bool
entryLocateLeafEntry(RumBtree btree, RumBtreeStack *stack)
{
	Page page = BufferGetPage(stack->buffer);
	OffsetNumber low,
				 high;

	Assert(RumPageIsLeaf(page));
	Assert(!RumPageIsData(page));

	if (btree->fullScan)
	{
		stack->off = FirstOffsetNumber;
		return true;
	}

	low = FirstOffsetNumber;
	high = PageGetMaxOffsetNumber(page);

	return entryLocateLeafEntryBounds(btree, page, low, high, &stack->off);
}


bool
entryLocateLeafEntryBounds(RumBtree btree, Page page,
						   OffsetNumber low, OffsetNumber high,
						   OffsetNumber *targetOffset)
{
	Assert(!RumPageIsData(page));

	if (high < low)
	{
		*targetOffset = low;
		return false;
	}

	high++;

	while (high > low)
	{
		OffsetNumber mid = low + ((high - low) / 2);
		IndexTuple itup;
		OffsetNumber attnum;
		Datum key;
		RumNullCategory category;
		int result;

		itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, mid));
		attnum = rumtuple_get_attrnum(btree->rumstate, itup);
		key = rumtuple_get_key(btree->rumstate, itup, &category);
		result = rumCompareAttEntries(btree->rumstate,
									  btree->entryAttnum,
									  btree->entryKey,
									  btree->entryCategory,
									  attnum, key, category);
		if (result == 0)
		{
			*targetOffset = mid;
			return true;
		}
		else if (result > 0)
		{
			low = mid + 1;
		}
		else
		{
			high = mid;
		}
	}

	*targetOffset = high;
	return false;
}


static OffsetNumber
entryFindChildPtr(RumBtree btree, Page page, BlockNumber blkno, OffsetNumber storedOff)
{
	OffsetNumber i,
				 maxoff = PageGetMaxOffsetNumber(page);
	IndexTuple itup;

	Assert(!RumPageIsLeaf(page));
	Assert(!RumPageIsData(page));

	/* if page isn't changed, we returns storedOff */
	if (storedOff >= FirstOffsetNumber && storedOff <= maxoff)
	{
		itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, storedOff));
		if (RumGetDownlink(itup) == blkno)
		{
			return storedOff;
		}

		/*
		 * we hope, that needed pointer goes to right. It's true if there
		 * wasn't a deletion
		 */
		for (i = storedOff + 1; i <= maxoff; i++)
		{
			itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, i));
			if (RumGetDownlink(itup) == blkno)
			{
				return i;
			}
		}
		maxoff = storedOff - 1;
	}

	/* last chance */
	for (i = FirstOffsetNumber; i <= maxoff; i++)
	{
		itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, i));
		if (RumGetDownlink(itup) == blkno)
		{
			return i;
		}
	}

	return InvalidOffsetNumber;
}


static BlockNumber
entryGetLeftMostPage(RumBtree btree, Page page)
{
	IndexTuple itup;

	Assert(!RumPageIsLeaf(page));
	Assert(!RumPageIsData(page));
	Assert(PageGetMaxOffsetNumber(page) >= FirstOffsetNumber);

	itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, FirstOffsetNumber));
	return RumGetDownlink(itup);
}


static bool
entryIsEnoughSpace(RumBtree btree, Buffer buf, OffsetNumber off)
{
	Size itupsz = 0;
	Page page = BufferGetPage(buf);

	Assert(btree->entry);
	Assert(!RumPageIsData(page));

	if (btree->isDelete)
	{
		IndexTuple itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, off));

		itupsz = MAXALIGN(IndexTupleSize(itup)) + sizeof(ItemIdData);
	}

	if (PageGetFreeSpace(page) + itupsz >= MAXALIGN(IndexTupleSize(btree->entry)) +
		sizeof(ItemIdData))
	{
		return true;
	}

	return false;
}


static void
entryReplaceTuple(Relation index, Page page, OffsetNumber off,
				  IndexTuple replacement)
{
	Size replacementSize = IndexTupleSize(replacement);
	Size oldSize = ItemIdGetLength(PageGetItemId(page, off));

	if (MAXALIGN(replacementSize) <= MAXALIGN(oldSize))
	{
		if (!PageIndexTupleOverwrite(page, off, RumPageItem(replacement),
									 replacementSize))
		{
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("failed to overwrite item in index page in \"%s\"",
							RelationGetRelationName(index)),
					 errdetail("Entry offset: %u", (unsigned int) off)));
		}
	}
	else
	{
		bool overwrite = true;
		bool isHeap = false;

		PageIndexTupleDeleteNoCompact(page, off);

		if (PageAddItem(page, RumPageItem(replacement), replacementSize,
						off, overwrite, isHeap) != off)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("failed to add item in index page in \"%s\"",
							RelationGetRelationName(index)),
					 errdetail("Entry offset: %u", (unsigned int) off)));
		}
	}
}


/*
 * Delete tuple on leaf page if tuples existed and we
 * should update it, update old child blkno to new right page
 * if child split occurred
 */
static BlockNumber
entryPreparePage(RumBtree btree, Page page, OffsetNumber off,
				 EntryPrepareMode prepareMode,
				 bool *doReplace, bool *needsOverwrite)
{
	BlockNumber ret = InvalidBlockNumber;

	Assert(btree->entry);
	Assert(!RumPageIsData(page));

	*doReplace = false;
	if (btree->isDelete)
	{
		Assert(RumPageIsLeaf(page));
		if (RumAllowReplaceOnInsertTuple && prepareMode != EntryPrepareMode_ForceDelete)
		{
			ItemId currentItemId = PageGetItemId(page, off);
			if (!ItemIdIsNormal(currentItemId))
			{
				/* LP_DEAD entries - needs to replace and rewrite and revive */
				btree->isDelete = true;
				PageIndexTupleDelete(page, off);
			}
			else if (prepareMode != EntryPrepareMode_AllowReplace)
			{
				/* Since we're just about to add PageAddItem - skip the compact on this delete */
				btree->isDelete = true;
				PageIndexTupleDeleteNoCompact(page, off);
				*needsOverwrite = true;
			}
			else
			{
				*doReplace = true;
			}
		}
		else
		{
			PageIndexTupleDelete(page, off);
		}
	}

	if (!RumPageIsLeaf(page) && btree->rightblkno != InvalidBlockNumber)
	{
		IndexTuple itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, off));

		RumSetDownlink(itup, btree->rightblkno);
		ret = btree->rightblkno;
	}

	btree->rightblkno = InvalidBlockNumber;

	return ret;
}


/*
 * Place tuple on page and fills WAL record
 */
static bool
entryPlaceToPage(RumBtree btree, Page page, OffsetNumber off,
				 bool requireWalFromPlaceToPage)
{
	OffsetNumber placed;

	/* Don't do a replace if we're writing custom WAL - this ensures that
	 * the physical bits layout is identical between the primary and standby.
	 */
	EntryPrepareMode prepareMode = EntryPrepareMode_ForceDelete;
	bool needsOverwrite = false;
	bool doReplace = false;

	if (RumPageIsLeaf(page))
	{
		prepareMode = requireWalFromPlaceToPage ? EntryPrepareMode_Delete :
					  EntryPrepareMode_AllowReplace;
	}

	entryPreparePage(btree, page, off, prepareMode, &doReplace, &needsOverwrite);

	if (doReplace)
	{
		Assert(!needsOverwrite);
		entryReplaceTuple(btree->index, page, off, btree->entry);
	}
	else
	{
		placed = PageAddItem(page, RumPageItem(btree->entry), IndexTupleSize(
								 btree->entry), off,
							 needsOverwrite, false);
		if (placed != off)
		{
			elog(ERROR, "failed to add item to index page in \"%s\" offset %d",
				 RelationGetRelationName(btree->index), off);
		}
	}

	Assert(ItemIdIsNormal(PageGetItemId(page, off)));

	if (requireWalFromPlaceToPage)
	{
		/* In the standby we need to redo for delete + add for both delete and replace */
		WriteInsertEntryWalRecord(btree->isDelete, off, btree->entry);
	}

	btree->entry = NULL;
	return requireWalFromPlaceToPage;
}


/*
 * Place tuple and split page, original buffer(lbuf) leaves untouched,
 * returns shadow page of lbuf filled new data.
 * Tuples are distributed between pages by equal size on its, not
 * an equal number!
 */
static Page
entrySplitPage(RumBtree btree, Buffer lbuf, Buffer rbuf,
			   Page lPage, Page rPage, OffsetNumber off)
{
	OffsetNumber i, maxoff, maxoffOrig;
	Size totalsize = 0, splitPointSize = 0;
	Size lsize = 0,
		 size;
	char *ptr;
	IndexTuple itup,
			   leftrightmost = NULL;
	Page page;
	Page newlPage = PageGetTempPageCopy(lPage);
	Size pageSize = PageGetPageSize(newlPage);

	/*
	 * Must have tupstore MAXALIGNed to use PG macros to access data in
	 * it. Should not rely on compiler alignment preferences to avoid
	 * tupstore overflow related to PG in-memory page items alignment
	 * inside rumDataPageLeafRead() or elsewhere.
	 */
	static char tupstoreStorage[2 * BLCKSZ + MAXIMUM_ALIGNOF];
	char *tupstore = (char *) MAXALIGN(tupstoreStorage);

	bool needsOverwrite = false;
	bool doReplace = false;
	entryPreparePage(btree, newlPage, off, EntryPrepareMode_ForceDelete, &doReplace,
					 &needsOverwrite);

	Assert(!needsOverwrite && !doReplace);
	maxoff = PageGetMaxOffsetNumber(newlPage);
	ptr = tupstore;

	for (i = FirstOffsetNumber; i <= maxoff; i++)
	{
		if (i == off)
		{
			size = MAXALIGN(IndexTupleSize(btree->entry));
			memcpy(ptr, btree->entry, size);
			ptr += size;
			totalsize += size + sizeof(ItemIdData);
		}

		itup = (IndexTuple) PageGetItem(newlPage, PageGetItemId(newlPage, i));
		size = MAXALIGN(IndexTupleSize(itup));
		memcpy(ptr, itup, size);
		ptr += size;
		totalsize += size + sizeof(ItemIdData);
	}

	if (off == maxoff + 1)
	{
		size = MAXALIGN(IndexTupleSize(btree->entry));
		memcpy(ptr, btree->entry, size);
		totalsize += size + sizeof(ItemIdData);
	}

	RumInitPage(rPage, RumPageGetOpaque(newlPage)->flags, pageSize);
	RumInitPage(newlPage, RumPageGetOpaque(rPage)->flags, pageSize);

	/* A fill-factor target cannot exceed one page's physical capacity. */
	Size pageCapacity = PageGetExactFreeSpace(newlPage);
	if (RumEnableNewBulkDelete)
	{
		RumPageGetCycleId(newlPage) = rum_vacuum_get_cycleId(btree->index);
		RumPageGetCycleId(rPage) = RumPageGetCycleId(newlPage);
	}

	/* By default we split in half by size */
	splitPointSize = totalsize / 2;

	/* For now we consider split scenarios on tail insertions of the leaf to be
	 * the case where we consider fillfactor. This can be improved in the future.
	 */
	if (RumEnablePageFillFactor && btree->rumstate->fillFactor != 50 &&
		RumPageIsLeaf(lPage) && RumPageRightMost(lPage))
	{
		Size effectiveSize = Min(pageCapacity, totalsize);
		splitPointSize = effectiveSize * btree->rumstate->fillFactor / 100;

		/* Keep enough tuples on the left for the remainder to fit on the right. */
		if (totalsize > pageCapacity)
		{
			splitPointSize = Max(splitPointSize, totalsize - pageCapacity);
		}
	}

	ptr = tupstore;
	maxoffOrig = maxoff;
	maxoff++;
	lsize = 0;
	page = newlPage;
	for (i = FirstOffsetNumber; i <= maxoff; i++)
	{
		PG_USED_FOR_ASSERTS_ONLY OffsetNumber writtenoffset = InvalidOffsetNumber;
		itup = (IndexTuple) ptr;

		/*
		 * If the size exceeds the split point, move to the new page.
		 * Don't go over the original max on the left page since we know that the sum total
		 * of the original offset + the new item exceeds the size of 1 page.
		 */
		Size itemSize = MAXALIGN(IndexTupleSize(itup)) + sizeof(ItemIdData);
		Size newSize = lsize + itemSize;
		if (lsize > splitPointSize || i > maxoffOrig || newSize > pageCapacity)
		{
			page = rPage;
		}
		else
		{
			leftrightmost = itup;
			lsize += itemSize;
		}

		if ((writtenoffset = PageAddItem(page, RumPageItem(itup), IndexTupleSize(itup),
										 InvalidOffsetNumber,
										 false, false)) == InvalidOffsetNumber)
		{
			elog(ERROR, "failed to add item to index page in \"%s\"",
				 RelationGetRelationName(btree->index));
		}

		Assert(ItemIdIsNormal(PageGetItemId(page, writtenoffset)));
		ptr += MAXALIGN(IndexTupleSize(itup));
	}

	btree->entry = RumFormInteriorTuple(btree, leftrightmost, newlPage,
										BufferGetBlockNumber(lbuf));

	btree->rightblkno = BufferGetBlockNumber(rbuf);

	return newlPage;
}


/*
 * return newly allocated rightmost tuple
 */
IndexTuple
rumPageGetLinkItup(RumBtree btree, Buffer buf, Page page)
{
	IndexTuple itup,
			   nitup;

	itup = rumEntryGetRightMostTuple(page);
	nitup = RumFormInteriorTuple(btree, itup, page, BufferGetBlockNumber(buf));

	return nitup;
}


/*
 * Fills new root by rightest values from child.
 * Also called from rumxlog, should not use btree
 */
void
rumEntryFillRoot(RumBtree btree, Buffer root, Buffer lbuf, Buffer rbuf,
				 Page page, Page lpage, Page rpage)
{
	IndexTuple itup;

	itup = rumPageGetLinkItup(btree, lbuf, lpage);
	if (PageAddItem(page, RumPageItem(itup), IndexTupleSize(itup), InvalidOffsetNumber,
					false,
					false) == InvalidOffsetNumber)
	{
		elog(ERROR, "failed to add item to index root page");
	}
	pfree(itup);

	itup = rumPageGetLinkItup(btree, rbuf, rpage);
	if (PageAddItem(page, RumPageItem(itup), IndexTupleSize(itup), InvalidOffsetNumber,
					false,
					false) == InvalidOffsetNumber)
	{
		elog(ERROR, "failed to add item to index root page");
	}
	pfree(itup);
}


static void
rumEntryFillBtreeForIncompleteSplit(RumBtree btree, RumBtreeStack *stack, Buffer buffer)
{
	IndexTuple itup;
	Page page = BufferGetPage(buffer);

	/* Fill rightblkno to ensure we're tracking the split page */
	btree->rightblkno = RumPageGetOpaque(page)->rightlink;

	itup = rumEntryGetRightMostTuple(page);
	btree->entry = RumFormInteriorTuple(btree, itup, page, BufferGetBlockNumber(buffer));
}


/*
 * Builds sorted and unique-ified array of table block numbers from index
 * tuple TIDs whose line pointers are marked LP_DEAD.  Also adds the table
 * blocks from incoming posting list just in case it isn't among the LP_DEAD-related
 * table blocks.
 *
 * See _bt_deadblocks for btree implementation.
 */
static BlockNumber *
rumGetDeadBlocks(RumBtree btree, Page page,
				 OffsetNumber *deletable, int ndeletable,
				 const RumItem *pending, uint32 npending,
				 int *nblocks)
{
	int ntids = 0;
	BlockNumber *tidblocks;

	tidblocks = palloc(sizeof(BlockNumber) * (MaxTIDsPerRumPage + npending));

	/*
	 * Collect all table block numbers from the LP_DEAD index tuples.
	 */
	for (int i = 0; i < ndeletable; i++)
	{
		ItemPointerData *tids;
		OffsetNumber off = deletable[i];
		IndexTuple itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, off));
		int nPostings = RumGetNPosting(itup);
		OffsetNumber attnum = rumtuple_get_attrnum(btree->rumstate, itup);

		tids = palloc(sizeof(ItemPointerData) * nPostings);
		rumReadTuplePointers(btree->rumstate, attnum, itup, tids);

		for (int j = 0; j < nPostings; j++)
		{
			tidblocks[ntids++] = ItemPointerGetBlockNumber(&tids[j]);
		}

		pfree(tids);
	}

	/*
	 * Collect all table block numbers from the incoming posting list.
	 */
	for (uint32 i = 0; i < npending; i++)
	{
		tidblocks[ntids++] = ItemPointerGetBlockNumber(&pending[i].iptr);
	}

	qsort(tidblocks, ntids, sizeof(BlockNumber), _entrypage_blk_cmp);
	*nblocks = qunique(tidblocks, ntids, sizeof(BlockNumber),
					   _entrypage_blk_cmp);

	return tidblocks;
}


/*
 * Deletes or Updates item(s) from a RUM leaf page during single-page cleanup.
 *
 * See _bt_delitems_delete for equivalent btree implementation.
 */
static void
rumEntryPageItemsModify(RumBtree btree, Buffer buffer,
						OffsetNumber *deletable, int ndeletable,
						OffsetNumber *updatedOffsets, IndexTuple *updatable,
						int nupdatable)
{
	/* Shouldn't be called unless there's something to do */
	Assert(ndeletable > 0 || nupdatable > 0);

	/*
	 * We could potentially optimize amount of WAL generated by only logging the specific changes made to the page,
	 * rather than the whole page, to reduce WAL volume.
	 * We can also consider using GENERIC_XLOG_FULL_IMAGE to log the entire page image if needed.
	 */
	GenericXLogState *state = GenericXLogStart(btree->index);
	Page newPage = GenericXLogRegisterBuffer(state, buffer, 0);

	for (int i = 0; i < nupdatable; i++)
	{
		entryReplaceTuple(btree->index, newPage, updatedOffsets[i], updatable[i]);
	}

	if (ndeletable > 0)
	{
		PageIndexMultiDelete(newPage, deletable, ndeletable);
	}

	GenericXLogFinish(state);
}


/*
 * Try to delete item(s) during single-page cleanup.
 *
 * nbtree interface to table_index_delete_tuples().  Deletes a subset of index
 * tuples from caller's deltids array: those whose TIDs are found safe to
 * delete by the tableam (or already marked LP_DEAD in index, and so already
 * known to be deletable by our simple index deletion caller).
 *
 * Simple index deletion caller only includes TIDs from index tuples marked
 * LP_DEAD, as well as extra TIDs it found on the same leaf page that can be
 * included without increasing the total number of distinct table blocks for
 * the deletion operation as a whole.
 *
 * See _bt_delitems_delete_check for btree implementation.
 */
static void
rumEntryPageDeleteCheck(RumBtree btree,
						Relation heapRel,
						RumBtreeStack *stack,
						TM_IndexDeleteOp *delstate,
						HTAB *addedTids)
{
	Buffer buffer = stack->buffer;
	Page page = BufferGetPage(buffer);
	OffsetNumber maxoff = PageGetMaxOffsetNumber(page);
	OffsetNumber deletable[MaxIndexTuplesPerPage];
	OffsetNumber updatedOffsets[MaxIndexTuplesPerPage];
	IndexTuple updatable[MaxIndexTuplesPerPage];
	int ndeletable = 0;
	int nupdatable = 0;
	TransactionId latestRemovedXid;

	latestRemovedXid = table_index_delete_tuples(heapRel, delstate);

	for (OffsetNumber off = FirstOffsetNumber; off <= maxoff; off = OffsetNumberNext(off))
	{
		ItemId itemId;
		IndexTuple itup;
		OffsetNumber attnum;
		RumItem *items = NULL;
		int npostings;
		int nlive = 0;
		RumNullCategory category;
		Datum key;

		/* Do not remove the high key and the replacement target key from the page */
		bool keepKey = off == maxoff || (btree->isDelete && off == stack->off);

		itemId = PageGetItemId(page, off);
		itup = (IndexTuple) PageGetItem(page, itemId);

		if (RumIsPostingTree(itup))
		{
			continue;
		}

		if (RumIndexEntryIsDead(itemId) && !keepKey)
		{
			deletable[ndeletable++] = off;
			continue;
		}

		npostings = RumGetNPosting(itup);
		attnum = rumtuple_get_attrnum(btree->rumstate, itup);
		if (!RumIndexEntryIsDead(itemId))
		{
			items = palloc(sizeof(RumItem) * npostings);
			rumReadTuple(btree->rumstate, attnum, itup, items,
						 false /* copyAddInfo */);

			for (int i = 0; i < npostings; i++)
			{
				TM_IndexDelete *entry;

				entry = hash_search(addedTids, &items[i].iptr,
									HASH_FIND, NULL);

				if (entry != NULL &&
					delstate->status[entry->id].knowndeletable)
				{
					continue;
				}

				items[nlive++] = items[i];
			}
		}

		if (nlive == 0 && !keepKey)
		{
			deletable[ndeletable++] = off;
		}
		else if (nlive < npostings)
		{
			key = rumtuple_get_key(btree->rumstate, itup, &category);

			updatedOffsets[nupdatable] = off;
			updatable[nupdatable] =
				RumFormTuple(btree->rumstate, attnum, key, category,
							 items, nlive, true /* errorTooBig */);
			nupdatable++;
		}

		if (items)
		{
			pfree(items);
		}
	}

	bool pageChanged = ndeletable > 0 || nupdatable > 0;

	if (pageChanged &&
		XLogStandbyInfoActive() && RelationNeedsWAL(btree->index))
	{
		RumLogReusePageWithHorizon(btree->index, buffer, latestRemovedXid);
	}

	if (pageChanged)
	{
		rumEntryPageItemsModify(btree, buffer, deletable, ndeletable, updatedOffsets,
								updatable, nupdatable);
	}

	for (int i = 0; i < nupdatable; i++)
	{
		pfree(updatable[i]);
	}
}


/*
 * Scan over all items to see which ones need to be deleted according to
 * LP_DEAD flags.
 *
 * The rightmost key must survive as the page boundary, just as in vacuum.
 * The replacement target must also survive so the caller can re-read it.
 * Their posting lists can still be pruned, including to zero postings.
 *
 * See _bt_simpledel_pass for equivalent btree implementation.
 */
static void
rumCleanupEntryPageSimplePass(Relation heapRel, RumBtree btree, Buffer buffer,
							  RumBtreeStack *stack,
							  const RumItem *pending, uint32 npending)
{
	Page page = BufferGetPage(buffer);
	OffsetNumber maxoff = PageGetMaxOffsetNumber(page);

	OffsetNumber deletable[MaxIndexTuplesPerPage];
	int nDeletable = 0;
	int ntids = 0;

	/*
	 * Collect all LP_DEAD items
	 */
	for (OffsetNumber off = FirstOffsetNumber; off <= maxoff; off = OffsetNumberNext(off))
	{
		ItemId itemId = PageGetItemId(page, off);

		if (!RumIndexEntryIsDead(itemId))
		{
			continue;
		}

		/*
		 * We should never see LP_DEAD on posting tree pointers.
		 */
		IndexTuple itup = (IndexTuple) PageGetItem(page, itemId);
		Assert(!RumIsPostingTree(itup));

		deletable[nDeletable++] = off;
		ntids += RumGetNPosting(itup);
	}

	/* TODO: Consider making incremental progress, instead of returning early. */
	if (ntids == 0 || ntids > MaxTIDsPerRumPage)
	{
		return;
	}

	/* Simple pass cleanup requires at least one deletable entry on this page. */
	if (nDeletable > 0)
	{
		BlockNumber *deadblocks;
		int ndeadblocks;
		HASHCTL ctl = { 0 };
		HTAB *addedTids;
		TM_IndexDeleteOp delstate;

		/* get all the heap blocks for the LP_DEAD entries */
		deadblocks = rumGetDeadBlocks(btree, page, deletable, nDeletable,
									  pending, npending,
									  &ndeadblocks);

		ctl.keysize = sizeof(ItemPointerData);
		ctl.entrysize = sizeof(TM_IndexDelete);
		ctl.hcxt = CurrentMemoryContext;
		addedTids = hash_create("addedTids", MaxIndexTuplesPerPage, &ctl, HASH_ELEM |
								HASH_BLOBS | HASH_CONTEXT);

		/* create the table_am request */
		rumProbeBegin(btree->index, &delstate,
					  BufferGetBlockNumber(buffer), false /* bottomup */,
					  0 /* bottomupfreespace */,
					  MaxTIDsPerRumPage + npending);

		/* collect all TIDs that are LP_DEAD or whose heapblock is listed in deadblocks */
		for (OffsetNumber off = FirstOffsetNumber; off <= maxoff; off = OffsetNumberNext(
				 off))
		{
			ItemId itemId = PageGetItemId(page, off);
			IndexTuple itup = (IndexTuple) PageGetItem(page, itemId);

			if (RumIsPostingTree(itup))
			{
				continue;
			}

			int nPostings = RumGetNPosting(itup);

			if (nPostings == 0)
			{
				continue;
			}

			RumItem *items = palloc(nPostings * sizeof(RumItem));
			OffsetNumber attnum = rumtuple_get_attrnum(btree->rumstate, itup);
			rumReadTuple(btree->rumstate, attnum, itup, items, false /* copyAddInfo */);
			for (int i = 0; i < nPostings; i++)
			{
				BlockNumber block = ItemPointerGetBlockNumber(&items[i].iptr);

				/* Skip TIDs that are not in deadblocks */
				if (bsearch(&block, deadblocks, ndeadblocks, sizeof(BlockNumber),
							_entrypage_blk_cmp) == NULL)
				{
					continue;
				}

				/* NOTE: unlike btree simple pass, rumbtree supports multi-key, so a TID can appear in multiple index entries
				 * Since the table_am request requires unique TIDs, we use a hash table to avoid adding duplicates.
				 */
				rumProbeAddTid(&delstate, addedTids, items[i].iptr, off,
							   RumIndexEntryIsDead(itemId));
			}
			pfree(items);
		}

		for (uint32 i = 0; i < npending; i++)
		{
			rumProbeAddTid(&delstate, addedTids, pending[i].iptr, stack->off,
						   false /* knownDeletable */);
		}

		pfree(deadblocks);

		/* Physically delete LP_DEAD tuples (plus any delete-safe extra TIDs) */
		rumEntryPageDeleteCheck(btree, heapRel, stack, &delstate,
								addedTids);

		hash_destroy(addedTids);
		rumProbeCleanupFinish(&delstate);

		/* Offsets shifted by the prune since we actually deleted line pointers, re-find the insert position. */
		btree->findItem(btree, stack);
	}
}


/*
 * Initialize a heap-deletion request sized for up to `maxtids` candidate
 * TIDs.  When `bottomup` is true the request runs in
 * bottom-up mode (visiting only the densest promising heap blocks until
 * `bottomupfreespace` is satisfied); when false it runs in simple mode, where
 * every provided TID is examined.  The caller pushes candidates with
 * rumProbeAddTid(), runs table_index_delete_tuples(), and releases the state
 * with rumProbeCleanupFinish().
 */
void
rumProbeBegin(Relation index, TM_IndexDeleteOp *delstate,
			  BlockNumber iblknum, bool bottomup, Size bottomupfreespace,
			  int maxtids)
{
	delstate->irel = index;
	delstate->iblknum = iblknum;
	delstate->bottomup = bottomup;
	delstate->bottomupfreespace = bottomupfreespace;
	delstate->ndeltids = 0;
	delstate->deltids = palloc(maxtids * sizeof(TM_IndexDelete));
	delstate->status = palloc(maxtids * sizeof(TM_IndexStatus));
}


/*
 * Append one candidate TID to a heap-deletion request.  `idxoffnum` is the
 * index offset the TID belongs to.  `promising` marks it as worth ranking
 * (bottom-up mode only); `knownDeletable` marks a TID already known dead (e.g.
 * from an LP_DEAD entry).
 */
void
rumProbeAddTid(TM_IndexDeleteOp *delstate, HTAB *addedTids, ItemPointerData tid,
			   OffsetNumber idxoffnum, bool knownDeletable)
{
	TM_IndexDelete *deltid;
	TM_IndexStatus *status;
	TM_IndexDelete *entry;
	bool found;

	entry = hash_search(addedTids, &tid, HASH_ENTER, &found);

	if (found)
	{
		status = &delstate->status[entry->id];
		status->knowndeletable |= knownDeletable;
		return;
	}

	entry->id = delstate->ndeltids;
	deltid = &delstate->deltids[entry->id];
	status = &delstate->status[entry->id];

	deltid->tid = tid;
	deltid->id = entry->id;
	status->idxoffnum = idxoffnum;
	status->knowndeletable = knownDeletable;
	status->promising = false; /* unused for simple pass */
	status->freespace = 0; /* unused for simple pass */

	delstate->ndeltids++;
}


/*
 * Release the per-call heap-deletion state.
 */
void
rumProbeCleanupFinish(TM_IndexDeleteOp *delstate)
{
	pfree(delstate->deltids);
	pfree(delstate->status);
}


/*
 * Try to reclaim space on an entry page.
 */
static void
rumEntryCleanupPage(Relation heapRel, RumBtree btree, RumBtreeStack *stack,
					const RumItem *pending, uint32 npending)
{
	/* Simple pass to reclaim space on the entry page */
	rumCleanupEntryPageSimplePass(heapRel, btree, stack->buffer, stack,
								  pending, npending);

	/* TODO: Perform a second pass to remove more entries similar to bottom-up index deletion pass in btree.
	 */
}


/*
 * Set up RumBtree for entry page access
 *
 * Note: during WAL recovery, there may be no valid data in rumstate
 * other than a faked-up Relation pointer; the key datum is bogus too.
 */
void
rumPrepareEntryScan(RumBtree btree, OffsetNumber attnum,
					Datum key, RumNullCategory category,
					RumState *rumstate)
{
	memset(btree, 0, sizeof(RumBtreeData));

	btree->index = rumstate->index;
	btree->rumstate = rumstate;

	btree->findChildPage = entryLocateEntry;
	btree->isMoveRight = entryIsMoveRight;
	btree->findItem = entryLocateLeafEntry;
	btree->findChildPtr = entryFindChildPtr;
	btree->getLeftMostPage = entryGetLeftMostPage;
	btree->isEnoughSpace = entryIsEnoughSpace;
	btree->placeToPage = entryPlaceToPage;
	btree->splitPage = entrySplitPage;
	btree->fillRoot = rumEntryFillRoot;
	btree->fillBtreeForIncompleteSplit = rumEntryFillBtreeForIncompleteSplit;
	btree->cleanupPage = rumEntryCleanupPage;

	btree->isData = false;
	btree->searchMode = false;
	btree->fullScan = false;

	btree->entryAttnum = attnum;
	btree->entryKey = key;
	btree->entryCategory = category;
	btree->isDelete = false;
}


/*
 * qsort comparison function for entry page block numbers
 */
static inline int
_entrypage_blk_cmp(const void *arg1, const void *arg2)
{
	BlockNumber b1 = *((BlockNumber *) arg1);
	BlockNumber b2 = *((BlockNumber *) arg2);

	if (b1 < b2)
	{
		return -1;
	}
	else if (b1 > b2)
	{
		return 1;
	}

	return 0;
}
