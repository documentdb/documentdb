/*-------------------------------------------------------------------------
 *
 * rumvacuum.c
 *	  delete & vacuum routines for the postgres RUM
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "miscadmin.h"

#include "commands/progress.h"
#include "commands/vacuum.h"
#include "commands/progress.h"
#include "postmaster/autovacuum.h"
#include "storage/indexfsm.h"
#include "storage/lmgr.h"
#include "storage/predicate.h"
#include "storage/ipc.h"
#include "utils/backend_progress.h"

#include "pg_documentdb_rum.h"

#if PG_VERSION_NUM >= 180000
#define RumVacuumDelayPointCompat() \
	vacuum_delay_point(false);
#else
#define RumVacuumDelayPointCompat() \
	vacuum_delay_point();
#endif

extern bool RumSkipRetryOnDeletePage;
extern bool RumPruneEmptyPages;
extern bool RumEnableNewBulkDelete;
extern bool RumVacuumSkipPrunePostingTreePages;
extern bool RumTraversePageOnlyOnBackTrack;
extern bool RumSkipGlobalVisibilityCheckOnPrune;
extern bool RumEnableOverwriteEntryTupleOnVacuum;
extern bool RumEnableTargetedPostingTreePruning;
extern bool RumEnableSinglePassPostingTreeVacuum;

typedef struct
{
	Relation index;
	IndexBulkDeleteResult *result;
	IndexBulkDeleteCallback callback;
	void *callback_state;
	RumState rumstate;
	BufferAccessStrategy strategy;
	RumVacuumCycleId cycleId;
	bool inlineVacuumBulkDelDataPages;
	AttrNumber postingTreeAttNum;
}   RumVacuumState;

typedef struct RumVacuumStatistics
{
	uint32_t numEmptyPages;
	uint32_t numEmptyEntries;
	uint32_t numEmptyPostingTrees;
	uint32_t numPrunedEntries;
	uint32_t numPrunedPages;
	uint32_t prunedEmptyPostingRoots;
	uint32_t numPostingTreePagesDeleted;
	uint32_t numEmptyPostingTreePages;
	uint32_t numFullScanPostingTreePrunes;
	uint32_t numTargetedPostingTreePrunes;
	uint32_t numSinglePassPostingTreePrunes;
	uint32_t numEntryBacktracks;
	uint32_t numEntryPages;
	uint32_t numDataPages;
	uint32_t numVoidPages;
	uint32_t numPagesSkippedForBackTrack;
} RumVacuumStatistics;

typedef struct RumPostingTreeDeleteEntry
{
	RumItem pageMaxItem;
	BlockNumber deleteBlock;
	bool entryDeleted;
} RumPostingTreeDeleteEntry;

static IndexBulkDeleteResult * rumBulkDeleteDiskOrdered(IndexVacuumInfo *info,
														IndexBulkDeleteResult *stats,
														IndexBulkDeleteCallback callback,
														void *callback_state);
static void LogFinalVacuumState(Relation index, RumVacuumStatistics *stats,
								bool isNewBulkDelete, bool isVacuumCleanup);

static void TraverseAndPrunePostingTrees(RumVacuumState *gvs, Page page, Buffer buffer,
										 BlockNumber currentBlockNo,
										 RumVacuumStatistics *vacStats);

static uint32_t rumPostingTreePruneEmptyPagesTargeted(RumVacuumState *gvs,
													  OffsetNumber attnum,
													  BlockNumber rootBlkno);

static void TryDeletePostingLeafFromTree(RumVacuumState *gvs, BlockNumber rootBlkno,
										 AttrNumber attnum,
										 RumPostingTreeDeleteEntry *deleteEntry,
										 RumVacuumStatistics *vacStats);

inline static bool
IsCurrentVacuumCycleId(RumVacuumState *gvs, Page page)
{
	return RumEnableNewBulkDelete &&
		   gvs->cycleId != 0 &&
		   RumPageGetCycleId(page) == gvs->cycleId;
}


/*
 * Cleans array of ItemPointer (removes dead pointers)
 * Results are always stored in *cleaned, which will be allocated
 * if it's needed. In case of *cleaned!=NULL caller is responsible to
 * have allocated enough space. *cleaned and items may point to the same
 * memory address.
 * Returns the number of alive items.
 */
static OffsetNumber
rumFilterDeadTidsInPostingList(RumVacuumState *gvs, OffsetNumber attnum, Pointer src,
							   OffsetNumber nitem, Pointer *cleaned,
							   Size size, Size *newSize)
{
	OffsetNumber i,
				 nAliveItems = 0;
	RumItem item;
	ItemPointerData prevIptr;
	Pointer dst = NULL,
			prev,
			ptr = src;

	*newSize = 0;
	ItemPointerSetMin(&item.iptr);

	/*
	 * just scan over ItemPointer array
	 */

	prevIptr = item.iptr;
	for (i = 0; i < nitem; i++)
	{
		prev = ptr;
		ptr = rumDataPageLeafRead(ptr, attnum, &item, false, &gvs->rumstate);
		if (gvs->callback(&item.iptr, gvs->callback_state))
		{
			gvs->result->tuples_removed += 1;
			if (!dst)
			{
				dst = (Pointer) palloc(size);
				*cleaned = dst;
				if (i != 0)
				{
					memcpy(dst, src, prev - src);
					dst += prev - src;
				}
			}
		}
		else
		{
			gvs->result->num_index_tuples += 1;
			if (i != nAliveItems)
			{
				dst = rumPlaceToDataPageLeaf(dst, attnum, &item,
											 &prevIptr, &gvs->rumstate);
			}
			nAliveItems++;
			prevIptr = item.iptr;
		}
	}

	if (i != nAliveItems)
	{
		*newSize = dst - *cleaned;
	}
	return nAliveItems;
}


/*
 * Form a tuple for entry tree based on already encoded array of item pointers
 * with additional information.
 */
static IndexTuple
RumVacFormTuple(RumState *rumstate,
				OffsetNumber attnum, Datum key, RumNullCategory category,
				Pointer data,
				Size dataSize,
				uint32 nipd,
				bool errorTooBig)
{
	Datum datums[3];
	bool isnull[3];
	IndexTuple itup;
	uint32 newsize;

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
		newsize += dataSize;
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

		memcpy(ptr, data, dataSize);
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


static bool
rumCleanPostingTreeLeafTids(RumVacuumState *gvs,
							OffsetNumber attnum,
							Page page,
							Buffer buffer,
							bool isRoot,
							OffsetNumber *maxOffsetAfterPrune)
{
	bool hasVoidPage = false;
	OffsetNumber newMaxOff,
				 oldMaxOff = RumDataPageMaxOff(page);
	Pointer cleaned = NULL;
	Size newSize;

	newMaxOff = rumFilterDeadTidsInPostingList(gvs, attnum,
											   RumDataPageGetData(page), oldMaxOff,
											   &cleaned,
											   RumDataPageSize -
											   RumDataPageReadFreeSpaceValue(
												   page), &newSize);

	/* saves changes about deleted tuple ... */
	if (oldMaxOff != newMaxOff)
	{
		GenericXLogState *state;
		Page newPage;

		state = GenericXLogStart(gvs->index);

		newPage = GenericXLogRegisterBuffer(state, buffer, 0);

		if (IsCurrentVacuumCycleId(gvs, page))
		{
			/* Done with this page - set cycleId to 0 */
			RumPageGetCycleId(newPage) = 0;
		}

		if (newMaxOff > 0)
		{
			memcpy(RumDataPageGetData(newPage), cleaned, newSize);
		}

		pfree(cleaned);
		RumDataPageMaxOff(newPage) = newMaxOff;
		updateItemIndexes(newPage, attnum, &gvs->rumstate);

		/* if root is a leaf page, we don't desire further processing */
		if (!isRoot && RumDataPageMaxOff(newPage) < FirstOffsetNumber)
		{
			hasVoidPage = true;
		}

		GenericXLogFinish(state);
	}
	else if (IsCurrentVacuumCycleId(gvs, page))
	{
		RumPageGetCycleId(page) = 0;
		MarkBufferDirtyHint(buffer, true);
	}

	/*
	 * TODO(vacuum): hasVoidPage only reports leaves emptied *this* cycle
	 * (guarded by oldMaxOff != newMaxOff above). A leaf that was emptied in a
	 * prior cycle but never deleted -- e.g. its single-pass inline delete
	 * bailed on contention -- reaches here with oldMaxOff == newMaxOff == 0 and
	 * returns false, so the single-pass caller never revisits it, and an empty
	 * leaf can never shed more tids to re-trigger. Validated that vacuumcleanup
	 * cannot reclaim it either: rumvacuumcleanup only prunes posting-tree pages
	 * via TraverseAndPrunePostingTrees, which is gated on
	 * gvs.inlineVacuumBulkDelDataPages -- the mutually exclusive non-single-pass
	 * path (single-pass runs only from rumBulkDeleteOneEntryPage's
	 * !inlineVacuumBulkDelDataPages branch). Its recyclable scan only frees
	 * pages already marked deleted/half-dead; a still-linked empty leaf is a
	 * live data page and is skipped. Future work: run posting-tree page pruning
	 * (by page state, not by this-cycle emptiness) in vacuumcleanup so stale
	 * empty leaves are reclaimed in a later vacuum cycle.
	 */

	*maxOffsetAfterPrune = newMaxOff;
	return hasVoidPage;
}


/*
 * Delete a posting tree page.
 */
static bool
rumDeletePage(RumVacuumState *gvs, BlockNumber deleteBlkno,
			  BlockNumber parentBlkno, OffsetNumber myoff)
{
	BlockNumber leftBlkno,
				rightBlkno;
	const int32_t maxRetryCount = 10;
	int32_t retryCount = 0;
	Buffer dBuffer;
	Buffer lBuffer,
		   rBuffer;
	Buffer pBuffer;
	Page lPage,
		 dPage,
		 rPage,
		 parentPage;
	GenericXLogState *state;

restart:

	dBuffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, deleteBlkno,
								 RBM_NORMAL, gvs->strategy);

	LockBuffer(dBuffer, RUM_EXCLUSIVE);

	dPage = BufferGetPage(dBuffer);
	leftBlkno = RumPageGetOpaque(dPage)->leftlink;
	rightBlkno = RumPageGetOpaque(dPage)->rightlink;

	/* do not remove left/right most pages */
	if (leftBlkno == InvalidBlockNumber || rightBlkno == InvalidBlockNumber)
	{
		UnlockReleaseBuffer(dBuffer);
		return false;
	}

	LockBuffer(dBuffer, RUM_UNLOCK);

	/*
	 * Lock the pages in the same order as an insertion would, to avoid
	 * deadlocks: left, then right, then parent.
	 */
	lBuffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, leftBlkno,
								 RBM_NORMAL, gvs->strategy);
	rBuffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, rightBlkno,
								 RBM_NORMAL, gvs->strategy);
	pBuffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, parentBlkno,
								 RBM_NORMAL, gvs->strategy);

	LockBuffer(lBuffer, RUM_EXCLUSIVE);
	if (ConditionalLockBufferForCleanup(dBuffer) == false)
	{
		UnlockReleaseBuffer(lBuffer);
		ReleaseBuffer(dBuffer);
		ReleaseBuffer(rBuffer);
		ReleaseBuffer(pBuffer);

		/* Even when bailing, retry a few times before
		 * moving on and trying again next time.
		 *
		 * No CHECK_FOR_INTERRUPTS() or vacuum delay here: the enclosing
		 * posting-tree scan holds the root cleanup lock and exclusive locks
		 * (plus pins) on the ancestor pages across this call, so yielding while
		 * those are held would stall other backends. The loop is bounded via
		 * maxRetryCount instead.
		 */
		if (RumSkipRetryOnDeletePage &&
			retryCount >= maxRetryCount)
		{
			return false;
		}

		retryCount++;
		goto restart;
	}
	LockBuffer(rBuffer, RUM_EXCLUSIVE);

	/*
	 * The parent page is already held exclusively locked by the caller (the
	 * posting-tree DFS holds every ancestor down to this page locked while it
	 * descends), so we only pin it here and modify it in place below.
	 */

	lPage = BufferGetPage(lBuffer);
	rPage = BufferGetPage(rBuffer);

	/*
	 * last chance to check
	 */
	if (!(RumPageGetOpaque(lPage)->rightlink == deleteBlkno &&
		  RumPageGetOpaque(rPage)->leftlink == deleteBlkno &&
		  RumDataPageMaxOff(dPage) < FirstOffsetNumber))
	{
		OffsetNumber dMaxoff = RumDataPageMaxOff(dPage);

		ReleaseBuffer(pBuffer);
		UnlockReleaseBuffer(lBuffer);
		UnlockReleaseBuffer(dBuffer);
		UnlockReleaseBuffer(rBuffer);

		if (dMaxoff >= FirstOffsetNumber)
		{
			return false;
		}

		/* Even when bailing, retry a few times before
		 * moving on and trying again next time.
		 *
		 * This retry deliberately does NOT run CHECK_FOR_INTERRUPTS() or a
		 * vacuum delay: although this frame has released its own buffers, the
		 * enclosing posting-tree scan still holds the posting-tree root cleanup
		 * lock and exclusive content locks (and pins) on the ancestor pages for
		 * the whole descent. Yielding here would service a cancel / sleep while
		 * those cleanup/exclusive locks are held, stalling every backend blocked
		 * on them. The loop is instead kept bounded via maxRetryCount.
		 */
		if (RumSkipRetryOnDeletePage &&
			retryCount >= maxRetryCount)
		{
			return false;
		}

		retryCount++;
		goto restart;
	}

	/* At least make the WAL record */

	state = GenericXLogStart(gvs->index);

	dPage = GenericXLogRegisterBuffer(state, dBuffer, 0);
	lPage = GenericXLogRegisterBuffer(state, lBuffer, 0);
	rPage = GenericXLogRegisterBuffer(state, rBuffer, 0);

	RumPageGetOpaque(lPage)->rightlink = rightBlkno;
	RumPageGetOpaque(rPage)->leftlink = leftBlkno;

	/*
	 * Any insert which would have gone on the leaf block will now go to its
	 * right sibling.
	 */
	PredicateLockPageCombine(gvs->index, deleteBlkno, rightBlkno);

	/* Delete downlink from parent */
	parentPage = GenericXLogRegisterBuffer(state, pBuffer, 0);
#ifdef USE_ASSERT_CHECKING
	do {
		RumPostingItem *tod = (RumPostingItem *) RumDataPageGetItem(parentPage, myoff);

		Assert(PostingItemGetBlockNumber(tod) == deleteBlkno);
	} while (0);
#endif
	RumPageDeletePostingItem(parentPage, myoff);

	/*
	 * we shouldn't change left/right link field to save workability of running
	 * search scan
	 */
	RumPageForceSetDeleted(dPage);
	RumPageSetDeleteXid(dPage, ReadNextTransactionId());

	GenericXLogFinish(state);

	ReleaseBuffer(pBuffer);
	UnlockReleaseBuffer(lBuffer);
	UnlockReleaseBuffer(dBuffer);
	UnlockReleaseBuffer(rBuffer);

	gvs->result->pages_deleted++;

	return true;
}


typedef struct DataPageDeleteStack
{
	struct DataPageDeleteStack *child;
	struct DataPageDeleteStack *parent;

	BlockNumber blkno;          /* current block number */
	bool isRoot;
} DataPageDeleteStack;

/*
 * scans posting tree and deletes empty pages
 */
static bool
rumPostingTreePruneEmptyPagesUnderRootLock(RumVacuumState *gvs,
										   BlockNumber blkno,
										   bool isRoot,
										   DataPageDeleteStack *parent,
										   OffsetNumber myoff,
										   int *numDeletedPages)
{
	DataPageDeleteStack *me;
	Buffer buffer;
	Page page;
	bool meDelete = false;

	if (isRoot)
	{
		me = parent;
	}
	else
	{
		if (!parent->child)
		{
			me = (DataPageDeleteStack *) palloc0(sizeof(DataPageDeleteStack));
			me->parent = parent;
			parent->child = me;
		}
		else
		{
			me = parent->child;
		}
	}

	buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, blkno,
								RBM_NORMAL, gvs->strategy);

	if (!isRoot)
	{
		LockBuffer(buffer, RUM_EXCLUSIVE);
	}

	page = BufferGetPage(buffer);

	Assert(RumPageIsData(page));

	if (!RumPageIsLeaf(page))
	{
		OffsetNumber i;

		me->blkno = blkno;
		for (i = FirstOffsetNumber; i <= RumDataPageMaxOff(page); i++)
		{
			RumPostingItem *pitem = (RumPostingItem *) RumDataPageGetItem(page, i);

			if (rumPostingTreePruneEmptyPagesUnderRootLock(
					gvs,
					PostingItemGetBlockNumber(pitem),
					false,
					me,
					i,
					numDeletedPages))
			{
				i--;
			}
		}
	}

	if (RumDataPageMaxOff(page) < FirstOffsetNumber && !isRoot)
	{
		/*
		 * Release the buffer because in rumDeletePage() we need to pin it again
		 * and call ConditionalLockBufferForCleanup().
		 */
		UnlockReleaseBuffer(buffer);
		meDelete = rumDeletePage(gvs, blkno, me->parent->blkno, myoff);

		if (meDelete)
		{
			(*numDeletedPages)++;
		}
	}
	else if (!isRoot)
	{
		UnlockReleaseBuffer(buffer);
	}
	else
	{
		ReleaseBuffer(buffer);
	}

	return meDelete;
}


static Buffer
FindLeftMostLeafDataPage(RumVacuumState *gvs, BlockNumber blkno, bool *isPageRoot,
						 bool exclusive)
{
	Buffer buffer;
	Page page;

	/* Find leftmost leaf page of posting tree and lock it in exclusive mode */
	while (true)
	{
		RumPostingItem *pitem;

		buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, blkno,
									RBM_NORMAL, gvs->strategy);
		LockBuffer(buffer, RUM_SHARE);
		page = BufferGetPage(buffer);

		Assert(RumPageIsData(page));

		if (RumPageIsLeaf(page))
		{
			if (exclusive)
			{
				LockBuffer(buffer, RUM_UNLOCK);
				LockBuffer(buffer, RUM_EXCLUSIVE);
			}

			break;
		}

		*isPageRoot = false;
		Assert(RumDataPageMaxOff(page) >= FirstOffsetNumber);

		pitem = (RumPostingItem *) RumDataPageGetItem(page, FirstOffsetNumber);
		blkno = PostingItemGetBlockNumber(pitem);
		Assert(blkno != InvalidBlockNumber);

		UnlockReleaseBuffer(buffer);
	}

	return buffer;
}


/*
 * Scan through posting tree leafs, delete empty tuples.
 * Returns the number of empty pages in the leaves.
 */
static int
rumCleanPostingTreeLeavesTidsByRightlink(RumVacuumState *gvs, OffsetNumber attnum,
										 BlockNumber blkno,
										 int32_t *nonVoidPageCount,
										 RumVacuumStatistics *vacStats)
{
	Buffer buffer;
	Page page;
	bool isPageRoot = true;
	int numVoidPages = 0;
	int32_t numNonVoidPages = 0;
	bool exclusive = true;
	BlockNumber rootBlockNo = blkno;

	/* Find leftmost leaf page of posting tree and lock it in exclusive mode */
	buffer = FindLeftMostLeafDataPage(gvs, blkno, &isPageRoot, exclusive);
	page = BufferGetPage(buffer);

	/* Iterate all posting tree leaves using rightlinks and vacuum them */
	while (true)
	{
		OffsetNumber maxOffAfterPrune;
		blkno = RumPageGetOpaque(page)->rightlink;
		if (rumCleanPostingTreeLeafTids(gvs, attnum, page, buffer, isPageRoot,
										&maxOffAfterPrune))
		{
			numVoidPages++;

			/*
			 * A leaf with no left or right sibling is the posting tree's
			 * leftmost/rightmost bound, which rumDeletePage always refuses to
			 * remove. Skip the inline prune for those so we do not take the
			 * posting-tree root cleanup lock for a delete that cannot succeed.
			 */
			bool isBoundLeaf =
				RumPageGetOpaque(page)->leftlink == InvalidBlockNumber ||
				RumPageGetOpaque(page)->rightlink == InvalidBlockNumber;

			if (RumEnableSinglePassPostingTreeVacuum &&
				!RumVacuumSkipPrunePostingTreePages &&
				!isBoundLeaf)
			{
				/* Single-pass vacuum: prune the now-empty leaf inline instead
				 * of deferring it to the second pass in rumVacuumPostingTree.
				 *
				 * TODO(vacuum): if this inline delete bails (contention), the
				 * leaf stays empty-but-linked and is never retried -- see the
				 * TODO in rumCleanPostingTreeLeafTids. Reclaiming stale empty
				 * leaves needs posting-tree page pruning to run in
				 * vacuumcleanup so a future cycle can handle them.
				 */
				RumItem *maxEntry = RumDataPageGetRightBound(page);
				RumPostingTreeDeleteEntry deleteEntry = { 0 };
				deleteEntry.deleteBlock = BufferGetBlockNumber(buffer);
				deleteEntry.pageMaxItem = *maxEntry;
				deleteEntry.entryDeleted = false;
				UnlockReleaseBuffer(buffer);
				TryDeletePostingLeafFromTree(gvs, rootBlockNo, attnum, &deleteEntry,
											 vacStats);
			}
			else
			{
				UnlockReleaseBuffer(buffer);
			}
		}
		else
		{
			if (maxOffAfterPrune > 0)
			{
				numNonVoidPages++;
			}
			UnlockReleaseBuffer(buffer);
		}

		if (blkno == InvalidBlockNumber)
		{
			break;
		}

		buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, blkno,
									RBM_NORMAL, gvs->strategy);
		LockBuffer(buffer, RUM_EXCLUSIVE);
		page = BufferGetPage(buffer);
	}

	*nonVoidPageCount = numNonVoidPages;
	return numVoidPages;
}


/*
 * Vacuum one posting tree end-to-end.
 *
 * Step 1: clean dead TIDs from all leaves (via rightlinks).
 * Step 2: if any leaves became empty, prune empty pages (leaves and
 *         internal pages) via a full tree DFS under root cleanup lock.
 *
 * The disk-ordered path (rumBulkDeleteDiskOrdered) defers step 2 to
 * rumvacuumcleanup when inlineVacuumBulkDelDataPages is on; otherwise
 * it still calls this bundled function via rumBulkDeleteOneEntryPage.
 */
static bool
rumVacuumPostingTree(RumVacuumState *gvs,
					 OffsetNumber attnum,
					 BlockNumber rootBlkno,
					 BlockNumber *blocks_done,
					 uint32_t *postingTreeEmptyPages,
					 RumVacuumStatistics *vacStats)
{
	int numSecondPassDeletedPages = 0;
	int numNonEmptyLeafPages = 0;
	uint32_t numPagesDeletedBefore = vacStats->numPostingTreePagesDeleted;

	/*
	 * Step 1 always cleans dead TIDs from the leaves. When single-pass vacuum
	 * is enabled it also prunes the emptied leaves inline, so the second pass
	 * below is skipped. Once single-pass is the default this second pass (and
	 * the targeted/full-scan branches) can be removed entirely.
	 */
	int numEmptyLeafPages = rumCleanPostingTreeLeavesTidsByRightlink(gvs, attnum,
																	 rootBlkno,
																	 &numNonEmptyLeafPages,
																	 vacStats);

	if (!RumEnableSinglePassPostingTreeVacuum &&
		!RumVacuumSkipPrunePostingTreePages && numEmptyLeafPages > 0)
	{
		if (RumEnableTargetedPostingTreePruning)
		{
			/* Perform targeted pruning of the posting tree */
			vacStats->numTargetedPostingTreePrunes++;
			numSecondPassDeletedPages = rumPostingTreePruneEmptyPagesTargeted(gvs,
																			  attnum,
																			  rootBlkno);
		}
		else
		{
			/* Perform full tree traversal under a root lock to prune empty pages */
			Buffer buffer;
			DataPageDeleteStack root,
								*ptr,
								*tmp;

			vacStats->numFullScanPostingTreePrunes++;

			buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, rootBlkno,
										RBM_NORMAL, gvs->strategy);

			/*
			 * Lock posting tree root for cleanup to ensure there are no
			 * concurrent inserts.
			 */
			LockBufferForCleanup(buffer);
			memset(&root, 0, sizeof(DataPageDeleteStack));
			root.isRoot = true;

			rumPostingTreePruneEmptyPagesUnderRootLock(gvs, rootBlkno, true, &root,
													   InvalidOffsetNumber,
													   &numSecondPassDeletedPages);

			ptr = root.child;

			while (ptr)
			{
				tmp = ptr->child;
				pfree(ptr);
				ptr = tmp;
			}

			UnlockReleaseBuffer(buffer);
		}
	}

	*blocks_done += numEmptyLeafPages + numNonEmptyLeafPages;
	vacStats->numPostingTreePagesDeleted += numSecondPassDeletedPages;
	*postingTreeEmptyPages += numEmptyLeafPages;

	/*
	 * Pages deleted while vacuuming this posting tree, regardless of which
	 * pruning path ran: single-pass records its deletions inline during step 1,
	 * and the second pass folds its count in just above. Both land in
	 * vacStats->numPostingTreePagesDeleted, so this tree's count is the delta
	 * since entry. The two paths are mutually exclusive on the GUC, so at most
	 * one contributes.
	 */
	uint32_t pagesDeletedThisTree = vacStats->numPostingTreePagesDeleted -
									numPagesDeletedBefore;

	/*
	 * When single-pass vacuum is on, those deletions came from the inline prune
	 * path, so a non-zero count means it pruned >= 1 leaf on this tree. Record it
	 * once per tree, like the per-tree full-scan/targeted counters.
	 */
	if (RumEnableSinglePassPostingTreeVacuum && pagesDeletedThisTree > 0)
	{
		vacStats->numSinglePassPostingTreePrunes++;
	}

	ereport(DEBUG1, (errmsg("[RUM] Vacuum posting tree void pages %d, deleted pages %d",
							numEmptyLeafPages,
							(int) pagesDeletedThisTree)));
	return numNonEmptyLeafPages == 0;
}


static Page
rumCleanupEmptyEntries(Page respage, uint32 *nPrunedRows)
{
	OffsetNumber i,
				 maxoff = PageGetMaxOffsetNumber(respage);

	/* We cannot delete the rightMost entry in the page since the rightMost entry
	 * is placed in the parent as a downLink. To ensure we don't do that, we iterate
	 * from FirstOffsetNumber to maxoff - 1
	 */
	for (i = FirstOffsetNumber; i < maxoff; i++)
	{
		IndexTuple itup = (IndexTuple) PageGetItem(respage, PageGetItemId(respage, i));
		if (RumIsPostingTree(itup))
		{
			/* TODO: We do need to handle posting trees somehow */
			continue;
		}
		if (RumGetNPosting(itup) == 0)
		{
			/* entry is empty: prune it and readjust the pruned rows */
			(*nPrunedRows)++;
			PageIndexTupleDelete(respage, i);
			maxoff = PageGetMaxOffsetNumber(respage);
			i--;
		}
	}

	return respage;
}


inline static bool
IsRumEntryPageEmptyCheck(Page page, Relation index, BufferAccessStrategy bufferStrategy,
						 List **postingRootList)
{
	OffsetNumber off;
	IndexTuple pageTuple;
	for (off = FirstOffsetNumber; off <= PageGetMaxOffsetNumber(page); off++)
	{
		pageTuple = (IndexTuple) PageGetItem(page, PageGetItemId(page, off));
		if (RumIsPostingTree(pageTuple))
		{
			/* On an insert into a page with a posting tree, the insert releases
			 * the lock on the entry tree and releases the buffer, and acquires a
			 * lock on the root posting tree, releasing locks as it traverses the tree
			 * but leaving the root and path to the child pinned. Since we're not
			 * actually inserting or modifying the posting tree yet, we grab a share lock
			 * and ensure that it's an empty single page posting tree.
			 */
			Page postingRootPage;
			bool isPostingTreeNotEmpty;
			BlockNumber postingTreeBlock = RumGetDownlink(pageTuple);
			Buffer postingRootBuffer = ReadBufferExtended(index, MAIN_FORKNUM,
														  postingTreeBlock,
														  RBM_NORMAL, bufferStrategy);
			if (ConditionalLockBufferForCleanup(postingRootBuffer) == false)
			{
				/* Someone has a pin to the root, we can't clean up this page */
				ReleaseBuffer(postingRootBuffer);
				return false;
			}

			/* We don't hold the lock for too long to ensure we minimize stalling other operations */
			postingRootPage = BufferGetPage(postingRootBuffer);
			isPostingTreeNotEmpty = RumDataPageMaxOff(postingRootPage) >=
									FirstOffsetNumber ||
									RumPageGetOpaque(postingRootPage)->rightlink !=
									InvalidBlockNumber;
			UnlockReleaseBuffer(postingRootBuffer);
			if (isPostingTreeNotEmpty)
			{
				/* This posting tree is not empty - unlock and skip */
				return false;
			}

			/* Track the root pages that we need to clean up */
			if (postingRootList)
			{
				*postingRootList = lappend_int(*postingRootList, postingTreeBlock);
			}
		}
		else if (RumGetNPosting(pageTuple) > 0)
		{
			/* Page is no longer empty can't clean up */
			return false;
		}
	}

	return true;
}


static bool
CheckAndPruneEmptyRumPage(RumState *rumState, BufferAccessStrategy bufferStrategy,
						  BlockNumber blkno,
						  uint32 *numPostingTreesDeleted)
{
	Buffer buffer, leftBuffer = InvalidBuffer, rightBuffer = InvalidBuffer;
	Page page, parentPage, leftPage, rightPage;
	BlockNumber leftBlkNo, rightBlkNo;
	IndexTuple rightMostTuple = NULL, pageTuple = NULL;
	RumBtreeData btreeEntry;
	RumBtreeStack *stack = NULL;
	RumNullCategory category;
	GenericXLogState *state;
	OffsetNumber off;
	List *postingRootList = NIL;
	ListCell *postingRootCell;
	Buffer *postingRootBuffers = NULL;
	int nPostingRootBuffers = 0;
	int postingRootIdx;
	bool parentNeedsUnlock = false, bufferNeedsUnlock = false;
	bool cleanedPage = false;
	Datum key;

	if (blkno == RUM_ROOT_BLKNO)
	{
		/* never prune root page */
		return false;
	}

	/* First lock and get the entry page again */
	buffer = ReadBufferExtended(rumState->index, MAIN_FORKNUM, blkno,
								RBM_NORMAL, bufferStrategy);

	LockBuffer(buffer, RUM_SHARE);
	page = BufferGetPage(buffer);

	if (!RumPageIsLeaf(page))
	{
		/* only leaf pages can be pruned for now */
		UnlockReleaseBuffer(buffer);
		return false;
	}

	if (RumPageRightMost(page) || RumPageLeftMost(page))
	{
		/* never prune leftmost or rightmost pages */
		UnlockReleaseBuffer(buffer);
		return false;
	}

	pageTuple = rumEntryGetRightMostTuple(page);

	/* Copy it so we don't have a reference to the page */
	rightMostTuple = CopyIndexTuple(pageTuple);
	UnlockReleaseBuffer(buffer);

	/* Now find the page based on the right bound */
	key = rumtuple_get_key(rumState, rightMostTuple, &category);
	rumPrepareEntryScan(&btreeEntry,
						rumtuple_get_attrnum(rumState, rightMostTuple),
						key, category, rumState);

	/* Mark it as non-search mode - in this mode we get exclusive locks to the parents */
	btreeEntry.searchMode = false;

	/* Do a search based on the item to locate the buffer */
	stack = rumFindLeafPage(&btreeEntry, NULL, false);
	bufferNeedsUnlock = true;

	/* If we didn't land on the same page we started with, bail */
	if (stack->blkno != blkno)
	{
		goto cleanupState;
	}

	if (IsBufferCleanupOK(stack->buffer) == false)
	{
		/* can't get cleanup lock - skip for this iteration */
		goto cleanupState;
	}

	/* We found our page - recheck that it's empty:
	 * Prune and revalidate that the page is genuinely empty
	 * Trimming posting trees as we encounter them.
	 *
	 * We released the target lock above and reacquire all locks below, so the
	 * definitive list of empty posting-tree roots is collected under the final
	 * lock (not here) to avoid acting on a stale set.
	 */
	page = BufferGetPage(stack->buffer);

	if (!IsRumEntryPageEmptyCheck(page, rumState->index, bufferStrategy,
								  NULL))
	{
		/* page is no longer empty - skip */
		goto cleanupState;
	}

	/*
	 * Now we have a page that is a single empty posting list. We also have an exclusive lock
	 * on the page. We can attempt to delete it if it's safe to do so. We have a lock on the parent buffer
	 * on the stack - check that buffer
	 */
	if (stack->parent == NULL)
	{
		/* no parent - can't delete */
		goto cleanupState;
	}

	/* Now lock the pages in the same order as inserts would
	 * to avoid deadlocks: left then right then parent.
	 */

	/* Final stages - get an exclusive lock over right and left siblings */
	leftBlkNo = RumPageGetOpaque(page)->leftlink;
	rightBlkNo = RumPageGetOpaque(page)->rightlink;

	/* Unlock and relock in order */
	LockBuffer(stack->buffer, RUM_UNLOCK);
	bufferNeedsUnlock = false;
	leftBuffer = ReadBufferExtended(rumState->index, MAIN_FORKNUM, leftBlkNo,
									RBM_NORMAL, bufferStrategy);
	if (!ConditionalLockBuffer(leftBuffer))
	{
		ReleaseBuffer(leftBuffer);
		leftBuffer = InvalidBuffer;
		goto cleanupState;
	}

	rightBuffer = ReadBufferExtended(rumState->index, MAIN_FORKNUM, rightBlkNo,
									 RBM_NORMAL, bufferStrategy);
	if (!ConditionalLockBuffer(rightBuffer))
	{
		UnlockReleaseBuffer(leftBuffer);
		ReleaseBuffer(rightBuffer);
		leftBuffer = InvalidBuffer;
		rightBuffer = InvalidBuffer;
		goto cleanupState;
	}

	if (ConditionalLockBuffer(stack->parent->buffer) == false)
	{
		/* can't get lock on parent - skip for this iteration */
		goto cleanupState;
	}
	parentNeedsUnlock = true;

	if (ConditionalLockBufferForCleanup(stack->buffer) == false)
	{
		/* can't get lock on current buffer - skip for this iteration */
		goto cleanupState;
	}

	bufferNeedsUnlock = true;

	/* We can't prune the page if we're the right most child of the parent */
	parentPage = BufferGetPage(stack->parent->buffer);

	if (!entryLocateLeafEntryBounds(&btreeEntry, parentPage, FirstOffsetNumber,
									PageGetMaxOffsetNumber(parentPage),
									&stack->parent->off))
	{
		/* Can't find it in the parent - this is unexpected but bail */
		goto cleanupState;
	}

	if (stack->parent->off == PageGetMaxOffsetNumber(parentPage))
	{
		/* we're the right most child - can't delete */
		goto cleanupState;
	}

	/* This is an interior page - so get the downlink to see if it's our buffer */
	pageTuple = (IndexTuple) PageGetItem(parentPage, PageGetItemId(parentPage,
																   stack->parent->off));
	if (RumGetDownlink(pageTuple) != blkno)
	{
		/* this is weird - but could be possible with a page split - skip for this iteration */
		goto cleanupState;
	}

	/* Now that the page is locked for the final time, check that the page is
	 * still empty and collect the definitive set of empty posting-tree roots
	 * under this final lock.
	 */
	if (!IsRumEntryPageEmptyCheck(page, rumState->index, bufferStrategy,
								  &postingRootList))
	{
		/* page is no longer empty - skip */
		goto cleanupState;
	}

	/* Now current buffer is locked for cleanup, parent is locked, right and left buffers are locked */
	leftPage = BufferGetPage(leftBuffer);
	rightPage = BufferGetPage(rightBuffer);

	/* Revalidate the sibling links now that all pages are locked. We captured
	 * leftBlkNo/rightBlkNo and then released the target lock, so a concurrent
	 * split of the left sibling could have inserted a new page between it and
	 * the target, leaving our captured leftBlkNo stale. Relinking a stale left
	 * sibling would drop the newly split page (and the target) out of the leaf
	 * chain and corrupt the index. Only proceed if both siblings still bracket
	 * the target.
	 */
	if (RumPageGetOpaque(leftPage)->rightlink != blkno ||
		RumPageGetOpaque(rightPage)->leftlink != blkno)
	{
		goto cleanupState;
	}

	if (RumPageIsHalfDead(rightPage))
	{
		/* Can't delete current entry page since right sibling is half-dead
		 * we can't repoint the parent to this node in this cycle. We will
		 * try again in the next vacuum cycle.
		 */
		goto cleanupState;
	}

	/* Acquire cleanup locks on all empty posting-tree roots up front, before we
	 * modify any pages. We must not block on a concurrent pinner while holding
	 * the sibling/parent/target locks (that would stall every backend waiting on
	 * those pages), so take the cleanup locks conditionally. If any can't be
	 * acquired, abandon this attempt with all pages still intact and retry in a
	 * later vacuum cycle. Holding the target's cleanup lock guarantees no new
	 * scan can reach these roots, so their empty state (verified just above)
	 * cannot change before we delete them.
	 */
	if (postingRootList != NIL)
	{
		postingRootBuffers = (Buffer *) palloc(sizeof(Buffer) *
											   list_length(postingRootList));
		foreach(postingRootCell, postingRootList)
		{
			BlockNumber postingTreeBlock = (BlockNumber) lfirst_int(postingRootCell);
			Buffer postingRootBuffer = ReadBufferExtended(rumState->index,
														  MAIN_FORKNUM,
														  postingTreeBlock,
														  RBM_NORMAL, bufferStrategy);
			if (!ConditionalLockBufferForCleanup(postingRootBuffer))
			{
				ReleaseBuffer(postingRootBuffer);
				goto cleanupState;
			}

			postingRootBuffers[nPostingRootBuffers++] = postingRootBuffer;
		}
	}

	/* Start XLog: From here on out all operations are non-conditional */
	state = GenericXLogStart(rumState->index);

	/* First step: Unlink yourself from the parent: In the case of RUM, interior tuples
	 * point to the high key of a page. In the case of page deletion, the high key points to
	 * the right sibling (since the current page's keyspace is moved over). Since the right
	 * page is guaranteed to be not dead, and has a high key greater than the current page,
	 * it is sufficient to delete the downlink directly.
	 */
	parentPage = GenericXLogRegisterBuffer(state, stack->parent->buffer, 0);
	PageIndexTupleDelete(parentPage, stack->parent->off);

	/* Mark the current page as half dead: Set full image to prevent delta computation
	 * (since we're resetting the page anyway) */
	page = GenericXLogRegisterBuffer(state, stack->buffer, GENERIC_XLOG_FULL_IMAGE);
	RumPageSetHalfDead(page);
	RumPageSetDeleteXid(page, ReadNextTransactionId());
	for (off = FirstOffsetNumber; off <= PageGetMaxOffsetNumber(page); off++)
	{
		/* Trim any remaining tuples from the page */
		if (off != PageGetMaxOffsetNumber(page))
		{
			PageIndexTupleDelete(page, off);
			off--;
		}
		else
		{
			/* Last tuple we still shouldn't delete but ensure the posting tree pointer
			 * isn't followed.
			 */
			pageTuple = (IndexTuple) PageGetItem(page, PageGetItemId(page, off));
			if (RumIsPostingTree(pageTuple))
			{
				/* Ensure we don't follow the posting tree */
				RumSetNPosting(pageTuple, 0);
			}
		}
	}

	/* Update left and right siblings to point to each other
	 * but do not update the siblings in the current page so that in progress
	 * searches can continue safely.
	 */
	leftPage = GenericXLogRegisterBuffer(state, leftBuffer, 0);
	rightPage = GenericXLogRegisterBuffer(state, rightBuffer, 0);
	RumPageGetOpaque(leftPage)->rightlink = rightBlkNo;
	RumPageGetOpaque(rightPage)->leftlink = leftBlkNo;

	/*
	 * Any insert which would have gone on the leaf block will now go to its
	 * right sibling.
	 */
	PredicateLockPageCombine(rumState->index, stack->blkno, rightBlkNo);

	/* Since we can only register 4 xlog pages per xlog, do the posting tree in a new xlog */
	GenericXLogFinish(state);

	/*
	 * TODO(vacuum): this ordering can orphan posting-tree pages on crash. WAL
	 * record 1 above already removes the parent downlink and half-deletes the
	 * leaf, but the empty posting roots are force-deleted below in *separate*
	 * WAL records (forced because GenericXLog caps at MAX_GENERIC_XLOG_PAGES==4,
	 * already used by parent/leaf/left/right). A crash between record 1 and the
	 * posting-root records leaves the roots as ordinary RUM_DATA pages with no
	 * referencing entry -- unreachable and never reclaimed by vacuumcleanup,
	 * which only frees deleted/half-dead/new pages. Ideally we should prune the
	 * posting trees (delete the empty roots) and remove their entries BEFORE
	 * deleting/half-deleting the empty leaf page, so a crash leaves the leaf
	 * still pointing at an intact (empty) posting tree that a later vacuum cycle
	 * can re-attempt, rather than an orphan.
	 */

	/* For all the posting tree roots found, delete them with separate XLogs.
	 * We already hold cleanup locks on these buffers from the up-front step. */
	for (postingRootIdx = 0; postingRootIdx < nPostingRootBuffers; postingRootIdx++)
	{
		Buffer postingRootBuffer = postingRootBuffers[postingRootIdx];
		Page postingRootPage;

		state = GenericXLogStart(rumState->index);
		postingRootPage = GenericXLogRegisterBuffer(state, postingRootBuffer,
													GENERIC_XLOG_FULL_IMAGE);
		RumPageForceSetDeleted(postingRootPage);

		/*
		 * Stamp the delete horizon so the page is not recycled until every
		 * scan that could still hold this block number has drained. Without
		 * it RumPageIsRecyclable() would treat the stale pd_prune_xid as
		 * InvalidTransactionId and recycle the block immediately, bypassing
		 * the GlobalVisCheckRemovableXid gate that every other deleted page
		 * (rumDeletePage and the entry leaf above) relies on.
		 */
		RumPageSetDeleteXid(postingRootPage, ReadNextTransactionId());
		GenericXLogFinish(state);
		UnlockReleaseBuffer(postingRootBuffer);

		(*numPostingTreesDeleted)++;
	}

	/* All posting-root buffers have been released above; prevent cleanupState
	 * from releasing them again. */
	nPostingRootBuffers = 0;
	cleanedPage = true;

cleanupState:
	if (rightMostTuple)
	{
		pfree(rightMostTuple);
	}

	/* Release any posting-root cleanup locks still held (bail-out paths). On the
	 * success path nPostingRootBuffers was reset to 0 after releasing each. */
	if (postingRootBuffers)
	{
		for (postingRootIdx = 0; postingRootIdx < nPostingRootBuffers; postingRootIdx++)
		{
			UnlockReleaseBuffer(postingRootBuffers[postingRootIdx]);
		}
		pfree(postingRootBuffers);
	}

	if (postingRootList != NIL)
	{
		list_free(postingRootList);
	}

	if (leftBuffer != InvalidBuffer)
	{
		UnlockReleaseBuffer(leftBuffer);
	}

	if (rightBuffer != InvalidBuffer)
	{
		UnlockReleaseBuffer(rightBuffer);
	}

	if (stack)
	{
		if (bufferNeedsUnlock)
		{
			LockBuffer(stack->buffer, RUM_UNLOCK);
		}

		if (parentNeedsUnlock)
		{
			LockBuffer(stack->parent->buffer, RUM_UNLOCK);
		}

		freeRumBtreeStack(stack);
	}

	return cleanedPage;
}


/*
 * returns modified page or NULL if page isn't modified.
 * Function works with original page until first change is occurred,
 * then page is copied into temporary one.
 */
static Page
rumVacuumEntryPage(RumVacuumState *gvs, Buffer buffer, BlockNumber *roots,
				   OffsetNumber *attnums, uint32 *nroot, bool *isEmptyPage,
				   uint32 *numEmptyEntries, uint32 *numPrunedEntries)
{
	Page origpage = BufferGetPage(buffer),
		 tmppage;
	OffsetNumber entryOffset,
				 maxoff = PageGetMaxOffsetNumber(origpage);
	bool hasEmptyEntries = false;
	*isEmptyPage = true;
	tmppage = origpage;

	*nroot = 0;

	for (entryOffset = FirstOffsetNumber; entryOffset <= maxoff; entryOffset++)
	{
		IndexTuple itup = (IndexTuple) PageGetItem(tmppage, PageGetItemId(tmppage,
																		  entryOffset));

		if (RumIsPostingTree(itup))
		{
			/*
			 * store posting tree's roots for further processing, we can't
			 * vacuum it just now due to risk of deadlocks with scans/inserts
			 */
			roots[*nroot] = RumGetDownlink(itup);
			attnums[*nroot] = rumtuple_get_attrnum(&gvs->rumstate, itup);
			(*nroot)++;

			/* We don't track emptiness of posting trees here -
			 * we will do so after the tree is scanned */
		}
		else if (RumGetNPosting(itup) > 0)
		{
			/*
			 * if we already create temporary page, we will make changes in
			 * place
			 */
			Size cleanedSize;
			Pointer cleaned = NULL;
			uint32 newN =
				rumFilterDeadTidsInPostingList(gvs, rumtuple_get_attrnum(&gvs->rumstate,
																		 itup),
											   RumGetPosting(itup), RumGetNPosting(itup),
											   &cleaned,
											   IndexTupleSize(itup) - RumGetPostingOffset(
												   itup),
											   &cleanedSize);

			if (RumGetNPosting(itup) != newN)
			{
				OffsetNumber attnum;
				Datum key;
				RumNullCategory category;

				/*
				 * Some ItemPointers was deleted, so we should remake our
				 * tuple
				 */

				if (tmppage == origpage)
				{
					/*
					 * On first difference we create temporary page in memory
					 * and copies content in to it.
					 */
					tmppage = PageGetTempPageCopy(origpage);

					/* set itup pointer to new page */
					itup = (IndexTuple) PageGetItem(tmppage, PageGetItemId(tmppage,
																		   entryOffset));
				}

				attnum = rumtuple_get_attrnum(&gvs->rumstate, itup);
				key = rumtuple_get_key(&gvs->rumstate, itup, &category);

				Size oldTupleSize = IndexTupleSize(itup);

				itup = RumVacFormTuple(&gvs->rumstate, attnum, key, category,
									   cleaned, cleanedSize, newN, true);
				Size newTupleSize = IndexTupleSize(itup);

				pfree(cleaned);

				if (RumEnableOverwriteEntryTupleOnVacuum && MAXALIGN(newTupleSize) <=
					MAXALIGN(oldTupleSize))
				{
					/* overwrite the existing tuple in place instead of deleting and readding it */
					if (!PageIndexTupleOverwrite(tmppage, entryOffset, (Item) itup,
												 newTupleSize))
					{
						ereport(ERROR,
								(errcode(ERRCODE_INTERNAL_ERROR),
								 errmsg(
									 "failed to overwrite item in index page in \"%s\"",
									 RelationGetRelationName(gvs->index)),
								 errdetail("Block number: %u, entry offset: %u",
										   BufferGetBlockNumber(buffer), entryOffset)));
					}
				}
				else
				{
					PageIndexTupleDelete(tmppage, entryOffset);

					if (PageAddItem(tmppage, (Item) itup, newTupleSize,
									entryOffset, false, false) != entryOffset)
					{
						ereport(ERROR,
								(errcode(ERRCODE_INTERNAL_ERROR),
								 errmsg("failed to add item in index page in \"%s\"",
										RelationGetRelationName(gvs->index)),
								 errdetail("Block number: %u, entry offset: %u",
										   BufferGetBlockNumber(buffer), entryOffset)));
					}
				}

				pfree(itup);
			}

			if (newN == 0)
			{
				(*numEmptyEntries)++;
				hasEmptyEntries = true;
			}
			else
			{
				/* Has at least 1 valid entry */
				*isEmptyPage = false;
			}
		}
		else if (RumGetNPosting(itup) == 0)
		{
			(*numEmptyEntries)++;
			hasEmptyEntries = true;
		}
	}

	/* Check if we can lock the page for cleanup - note we can't
	 * cleanup this page if the page is pinned at all since a
	 * regular query may be holding it mid-scan.
	 * IsBufferCleanupOK will ensure we have a single Pin on the buffer
	 * which means we're the only ones interested in this buffer.
	 */
	if (hasEmptyEntries &&
		IsBufferCleanupOK(buffer))
	{
		if (tmppage == origpage)
		{
			/*
			 * On first difference we create temporary page in memory
			 * and copies content in to it.
			 */
			tmppage = PageGetTempPageCopy(origpage);
		}

		rumCleanupEmptyEntries(tmppage, numPrunedEntries);
	}

	return (tmppage == origpage) ? NULL : tmppage;
}


static Buffer
rumFindLeftMostLeafPage(Relation index, BlockNumber blkno,
						BufferAccessStrategy strategy)
{
	Buffer buffer;
	buffer = ReadBufferExtended(index, MAIN_FORKNUM, blkno,
								RBM_NORMAL, strategy);

	/* find leaf page */
	for (;;)
	{
		Page page = BufferGetPage(buffer);
		IndexTuple itup;

		LockBuffer(buffer, RUM_SHARE);

		Assert(!RumPageIsData(page));

		if (RumPageIsLeaf(page))
		{
			LockBuffer(buffer, RUM_UNLOCK);
			LockBuffer(buffer, RUM_EXCLUSIVE);

			if (blkno == RUM_ROOT_BLKNO && !RumPageIsLeaf(page))
			{
				LockBuffer(buffer, RUM_UNLOCK);
				continue;       /* check it one more */
			}
			break;
		}

		Assert(PageGetMaxOffsetNumber(page) >= FirstOffsetNumber);

		itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, FirstOffsetNumber));
		blkno = RumGetDownlink(itup);
		Assert(blkno != InvalidBlockNumber);

		UnlockReleaseBuffer(buffer);
		buffer = ReadBufferExtended(index, MAIN_FORKNUM, blkno,
									RBM_NORMAL, strategy);
	}

	return buffer;
}


static void
rumBulkDeleteOneEntryPage(Page page, Buffer buffer, BlockNumber currentBlockNo,
						  RumVacuumState *gvs, BlockNumber *blocks_done,
						  uint32_t *numEmptyEntries, uint32_t *numPrunedEntries,
						  uint32_t *numEmptyPostingTrees, uint32_t *numEmptyPages,
						  uint32_t *prunedEmptyPostingRoots, uint32_t *numPrunedPages,
						  uint32_t *postingTreeEmptyPages,
						  RumVacuumStatistics *vacStats)
{
	Page resPage;
	bool isEmptyPage = true;
	uint32_t i;

	BlockNumber rootOfPostingTree[BLCKSZ / (sizeof(IndexTupleData) + sizeof(ItemId))];
	OffsetNumber attnumOfPostingTree[BLCKSZ / (sizeof(IndexTupleData) + sizeof(ItemId))];
	uint32 nRoot;

	Assert(!RumPageIsData(page));
	resPage = rumVacuumEntryPage(gvs, buffer, rootOfPostingTree, attnumOfPostingTree,
								 &nRoot, &isEmptyPage, numEmptyEntries,
								 numPrunedEntries);

	if (resPage)
	{
		GenericXLogState *state;
		if (IsCurrentVacuumCycleId(gvs, page))
		{
			/* Done with this page - set cycleId to 0 */
			RumPageGetCycleId(resPage) = 0;
		}

		state = GenericXLogStart(gvs->index);
		page = GenericXLogRegisterBuffer(state, buffer, 0);
		PageRestoreTempPage(resPage, page);
		GenericXLogFinish(state);
	}
	else if (IsCurrentVacuumCycleId(gvs, page))
	{
		RumPageGetCycleId(page) = 0;
		MarkBufferDirtyHint(buffer, true);
	}

	UnlockReleaseBuffer(buffer);

	RumVacuumDelayPointCompat();

	if (gvs->inlineVacuumBulkDelDataPages)
	{
		/* If we're deleting posting trees inline, then skip traversing
		 * posting trees here. We also mark the page as not empty if there's
		 * any posting tree roots. Pruning pages will then happen in
		 * rumvacuumcleanup (at the end of the table traversal)
		 */
		if (nRoot > 0)
		{
			isEmptyPage = false;
		}
	}
	else
	{
		for (i = 0; i < nRoot; i++)
		{
			bool isEmptyTree = rumVacuumPostingTree(gvs,
													attnumOfPostingTree[i],
													rootOfPostingTree[i],
													blocks_done,
													postingTreeEmptyPages,
													vacStats);

			if (isEmptyTree)
			{
				(*numEmptyPostingTrees)++;
			}
			else
			{
				isEmptyPage = false;
			}

			RumVacuumDelayPointCompat();
		}
	}

	if (isEmptyPage)
	{
		(*numEmptyPages)++;
	}

	/* If we found a truly empty page, now handle this here */
	if (isEmptyPage && RumPruneEmptyPages)
	{
		if (CheckAndPruneEmptyRumPage(&gvs->rumstate, gvs->strategy,
									  currentBlockNo, prunedEmptyPostingRoots))
		{
			(*numPrunedPages)++;
		}
	}

	/* The entry page is done */
	(*blocks_done)++;
}


static void
InitRumVacuumState(RumVacuumState *gvs, Relation rel, IndexBulkDeleteResult *stats)
{
	gvs->callback = NULL;
	gvs->callback_state = NULL;
	gvs->strategy = NULL;
	gvs->cycleId = 0;

	gvs->index = rel;
	gvs->inlineVacuumBulkDelDataPages = false;
	gvs->postingTreeAttNum = InvalidAttrNumber;
	gvs->result = stats;
	initRumState(&gvs->rumstate, rel);

	if (RumEnableNewBulkDelete &&
		RumNewBulkDeleteInlineDataPages)
	{
		/*/
		 * Note that we do this for single column indexes now since we don't know the
		 * attnum here.
		 * For multi-column indexes, we do this if we know that no column has addAtrs set.
		 */
		if (gvs->rumstate.oneCol)
		{
			gvs->inlineVacuumBulkDelDataPages = true;
			gvs->postingTreeAttNum = (AttrNumber) 1;
		}
		else
		{
			bool hasAddAttrs = false;
			int i;
			for (i = 0; i < RelationGetNumberOfAttributes(rel); i++)
			{
				if (gvs->rumstate.addAttrs[i] != NULL)
				{
					hasAddAttrs = true;
					break;
				}
			}

			if (!hasAddAttrs)
			{
				gvs->inlineVacuumBulkDelDataPages = true;
				gvs->postingTreeAttNum = InvalidAttrNumber;
			}
		}
	}
}


static IndexBulkDeleteResult *
rumBulkDeleteTreeOrdered(IndexVacuumInfo *info,
						 IndexBulkDeleteResult *stats, IndexBulkDeleteCallback callback,
						 void *callback_state)
{
	Relation index = info->index;
	bool needLock;
	bool isVacuumCleanup = false;
	bool isNewBulkDelete = false;
	BlockNumber blkno = RUM_ROOT_BLKNO;
	BlockNumber num_pages, blocks_done;
	RumVacuumState gvs;
	Buffer buffer;
	RumVacuumStatistics vacStats = { 0 };

	/* Is this the first time running through? */
	if (stats == NULL)
	{
		/* Yes, so initialize stats to zeroes */
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));
	}

	InitRumVacuumState(&gvs, index, stats);
	gvs.callback = callback;
	gvs.callback_state = callback_state;
	gvs.strategy = info->strategy;

	/* we'll re-count the tuples each time */
	stats->num_index_tuples = 0;

	buffer = rumFindLeftMostLeafPage(index, blkno, gvs.strategy);

	needLock = !RELATION_IS_LOCAL(index);

	if (needLock)
	{
		LockRelationForExtension(index, ExclusiveLock);
	}

	num_pages = RelationGetNumberOfBlocks(index);

	if (needLock)
	{
		UnlockRelationForExtension(index, ExclusiveLock);
	}

	blocks_done = 0;

	pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_TOTAL,
								 num_pages);
	pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_DONE,
								 0);

	/* right now we found leftmost page in entry's BTree */
	for (;;)
	{
		Page page = BufferGetPage(buffer);
		BlockNumber currentBlockNo = blkno;

		blkno = RumPageGetOpaque(page)->rightlink;
		rumBulkDeleteOneEntryPage(page, buffer, currentBlockNo, &gvs, &blocks_done,
								  &vacStats.numEmptyEntries, &vacStats.numPrunedEntries,
								  &vacStats.numEmptyPostingTrees,
								  &vacStats.numEmptyPages,
								  &vacStats.prunedEmptyPostingRoots,
								  &vacStats.numPrunedPages,
								  &vacStats.numEmptyPostingTreePages,
								  &vacStats);

		pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_DONE, blocks_done);
		if (blkno == InvalidBlockNumber)        /* rightmost page */
		{
			break;
		}

		buffer = ReadBufferExtended(index, MAIN_FORKNUM, blkno,
									RBM_NORMAL, info->strategy);
		LockBuffer(buffer, RUM_EXCLUSIVE);
	}

	LogFinalVacuumState(index, &vacStats, isNewBulkDelete, isVacuumCleanup);
	return gvs.result;
}


static void
LogFinalVacuumState(Relation index, RumVacuumStatistics *stats, bool isNewBulkDelete,
					bool isVacuumCleanup)
{
	elog_rum_unredacted(
		"Vacuum[index=%u,vacuumCleanup=%d] emptyEntryPages=%u, emptyEntries=%u, emptyPostingTrees=%u, prunedEntries=%u, prunedPages=%u,"
		"prunedPostingTrees=%u, postingPagesDeleted=%u, emptyPostingPages=%u, numBacktracks=%u, isNewBulkDelete=%d, "
		"numEntryPages=%u, numDataPages=%u, numVoidPages=%u, "
		"fullScanPostingTreePrunes=%u, targetedPostingTreePrunes=%u, singlePassPostingTreePrunes=%u",
		index->rd_id, isVacuumCleanup, stats->numEmptyPages, stats->numEmptyEntries,
		stats->numEmptyPostingTrees,
		stats->numPrunedEntries, stats->numPrunedPages, stats->prunedEmptyPostingRoots,
		stats->numPostingTreePagesDeleted, stats->numEmptyPostingTreePages,
		stats->numEntryBacktracks, isNewBulkDelete, stats->numEntryPages,
		stats->numDataPages,
		stats->numVoidPages,
		stats->numFullScanPostingTreePrunes, stats->numTargetedPostingTreePrunes,
		stats->numSinglePassPostingTreePrunes);

	/* Log test only stats */
	if (stats->numPagesSkippedForBackTrack > 0)
	{
		elog(LOG, "Skipped buffers for the backtrack %u",
			 stats->numPagesSkippedForBackTrack);
	}
}


/*
 * ambulkdelete callback dispatcher for RUM index.
 *
 * Picks between two outer walk strategies based on the RumEnableNewBulkDelete GUC:
 *
 * - If true, use rumBulkDeleteDiskOrdered: scans the relation by block number.
 *   When inlineVacuumBulkDelDataPages is on, posting-tree leaf TID cleanup also happens
 *   inline per data leaf and empty-page pruning is deferred to rumvacuumcleanup.
 *   When inlineVacuumBulkDelDataPages is off, posting trees are vacuumed via the
 *   bundled (TID cleanup + empty page pruning) rumVacuumPostingTree path.
 *
 * - If false, use rumBulkDeleteTreeOrdered: descends the entry tree, walks entry leaves
 *   via rightlinks, and for each entry leaf, vacuums posting lists and posting trees before
 *   moving to the next entry leaf.
 *   Empty page pruning is attempted immediately after vacuuming each entry leaf.
 */
IndexBulkDeleteResult *
rumbulkdelete(IndexVacuumInfo *info,
			  IndexBulkDeleteResult *stats, IndexBulkDeleteCallback callback,
			  void *callback_state)
{
	rumValidateIndexVersion(info->index);
	if (RumEnableNewBulkDelete)
	{
		return rumBulkDeleteDiskOrdered(info, stats, callback, callback_state);
	}
	else
	{
		return rumBulkDeleteTreeOrdered(info, stats, callback, callback_state);
	}
}


static Page
rumPruneEmptyEntriesInEntryPage(Buffer buffer, RumState *rumState, bool *isEmptyPage,
								uint32 *numEmptyEntries, uint32 *numPrunedEntries)
{
	Page origpage = BufferGetPage(buffer),
		 tmppage;
	OffsetNumber i,
				 maxoff = PageGetMaxOffsetNumber(origpage);
	bool hasEmptyEntries = false;
	*isEmptyPage = true;
	tmppage = origpage;

	for (i = FirstOffsetNumber; i <= maxoff; i++)
	{
		IndexTuple itup = (IndexTuple) PageGetItem(tmppage, PageGetItemId(tmppage, i));
		if (RumIsPostingTree(itup))
		{
			/* Just assume we won't prune pages here */
			*isEmptyPage = false;
		}
		else if (RumGetNPosting(itup) > 0)
		{
			*isEmptyPage = false;
		}
		else if (RumGetNPosting(itup) == 0)
		{
			(*numEmptyEntries)++;
			hasEmptyEntries = true;
		}
	}

	/* Check if we can lock the page for cleanup - note we can't
	 * cleanup this page if the page is pinned at all since a
	 * regular query may be holding it mid-scan.
	 * IsBufferCleanupOK will ensure we have a single Pin on the buffer
	 * which means we're the only ones interested in this buffer.
	 */
	if (hasEmptyEntries &&
		IsBufferCleanupOK(buffer))
	{
		if (tmppage == origpage)
		{
			/*
			 * On first difference we create temporary page in memory
			 * and copies content in to it.
			 */
			tmppage = PageGetTempPageCopy(origpage);
		}

		rumCleanupEmptyEntries(tmppage, numPrunedEntries);
	}

	return (tmppage == origpage) ? NULL : tmppage;
}


void
rumVacuumPruneEmptyEntries(Relation index)
{
	BlockNumber blkno = RUM_ROOT_BLKNO;
	Buffer buffer;
	RumState rumState;
	uint32 numEmptyPages = 0, numEmptyEntries = 0, numPrunedEntries = 0, numPrunedPages =
		0,
		   prunedEmptyPostingRoots = 0;

	initRumState(&rumState, index);

	buffer = rumFindLeftMostLeafPage(index, blkno, NULL);

	/* right now we found leftmost page in entry's BTree */
	for (;;)
	{
		Page page = BufferGetPage(buffer);
		Page resPage;
		BlockNumber currentBlockNo;
		bool isEmptyPage = true;

		Assert(!RumPageIsData(page));
		resPage = rumPruneEmptyEntriesInEntryPage(buffer, &rumState, &isEmptyPage,
												  &numEmptyEntries,
												  &numPrunedEntries);

		currentBlockNo = blkno;
		blkno = RumPageGetOpaque(page)->rightlink;

		if (resPage)
		{
			GenericXLogState *state;

			state = GenericXLogStart(index);
			page = GenericXLogRegisterBuffer(state, buffer, 0);
			PageRestoreTempPage(resPage, page);
			GenericXLogFinish(state);
			UnlockReleaseBuffer(buffer);
		}
		else
		{
			UnlockReleaseBuffer(buffer);
		}

		if (isEmptyPage)
		{
			numEmptyPages++;
		}

		if (blkno == InvalidBlockNumber)        /* rightmost page */
		{
			break;
		}

		if (isEmptyPage && RumPruneEmptyPages)
		{
			BufferAccessStrategy bufferStrategy = NULL;
			if (CheckAndPruneEmptyRumPage(&rumState, bufferStrategy, currentBlockNo,
										  &prunedEmptyPostingRoots))
			{
				numPrunedPages++;
			}
		}

		/* Check for interrupts before locking the next buffer */
		CHECK_FOR_INTERRUPTS();
		buffer = ReadBufferExtended(index, MAIN_FORKNUM, blkno,
									RBM_NORMAL, NULL);
		LockBuffer(buffer, RUM_EXCLUSIVE);
	}

	elog(INFO,
		 "Vacuum found %u empty pages, %u empty entries, %u pruned entries, %u pruned pages, %u pruned posting trees",
		 numEmptyPages, numEmptyEntries, numPrunedEntries, numPrunedPages,
		 prunedEmptyPostingRoots);
}


static bool
RumPageIsRecyclable(Page page)
{
	TransactionId delete_xid;

	if (PageIsNew(page))
	{
		return false;
	}

	if (!RumPruneEmptyPages)
	{
		return RumPageIsDeleted(page);
	}

	if (!RumPageIsHalfDead(page) &&
		!RumPageIsDeleted(page))
	{
		return false;
	}

	delete_xid = RumPageGetDeleteXid(page);

	if (!TransactionIdIsValid(delete_xid))
	{
		return true;
	}

	if (RumSkipGlobalVisibilityCheckOnPrune)
	{
		return true;
	}

	/*
	 * If no backend still could view delete_xid as in running, all scans
	 * concurrent with pruning empty pages must have finished.
	 */
	return GlobalVisCheckRemovableXid(NULL, delete_xid);
}


static void
RumPageMarkAsDeleted(Relation index, Buffer buffer)
{
	GenericXLogState *state;
	Page page;
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buffer, 0);
	RumPageSetDeleted(page);
	GenericXLogFinish(state);
}


IndexBulkDeleteResult *
rumvacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
	Relation index = info->index;
	bool needLock;
	BlockNumber npages,
				blkno;
	BlockNumber totFreePages;
	RumStatsData idxStat;
	bool isVacuumCleanup = true;
	RumVacuumState gvs;
	RumVacuumStatistics vacStats = { 0 };

	/*
	 * In an autovacuum analyze, we want to clean up pending insertions.
	 * Otherwise, an ANALYZE-only call is a no-op.
	 */
	if (info->analyze_only)
	{
		return stats;
	}

	/*
	 * Set up all-zero stats and cleanup pending inserts if rumbulkdelete
	 * wasn't called
	 */
	if (stats == NULL)
	{
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));
	}

	InitRumVacuumState(&gvs, index, stats);
	memset(&idxStat, 0, sizeof(idxStat));

	/*
	 * XXX we always report the heap tuple count as the number of index
	 * entries.  This is bogus if the index is partial, but it's real hard to
	 * tell how many distinct heap entries are referenced by a RUM index.
	 */
	stats->num_index_tuples = Max(info->num_heap_tuples, 0);
	stats->estimated_count = info->estimated_count;

	/*
	 * Need lock unless it's local to this backend.
	 */
	needLock = !RELATION_IS_LOCAL(index);

	if (needLock)
	{
		LockRelationForExtension(index, ExclusiveLock);
	}

	npages = RelationGetNumberOfBlocks(index);

	if (needLock)
	{
		UnlockRelationForExtension(index, ExclusiveLock);
	}

	pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_TOTAL,
								 npages);
	pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_DONE,
								 0);
	totFreePages = 0;

	for (blkno = RUM_ROOT_BLKNO; blkno < npages; blkno++)
	{
		Buffer buffer;
		Page page;
		bool releaseBuffer = true;

		RumVacuumDelayPointCompat();

		buffer = ReadBufferExtended(index, MAIN_FORKNUM, blkno,
									RBM_NORMAL, info->strategy);
		LockBuffer(buffer, RUM_SHARE);
		page = (Page) BufferGetPage(buffer);

		if (PageIsNew(page))
		{
			Assert(blkno != RUM_ROOT_BLKNO);
			RecordFreeIndexPage(index, blkno);
			totFreePages++;
		}
		else if (RumPageIsRecyclable(page))
		{
			if (!RumPageIsDeleted(page) && RumPruneEmptyPages)
			{
				/* Mark the page as explicitly deleted */
				LockBuffer(buffer, RUM_UNLOCK);
				LockBuffer(buffer, RUM_EXCLUSIVE);
				RumPageMarkAsDeleted(info->index, buffer);
			}

			Assert(blkno != RUM_ROOT_BLKNO);
			RecordFreeIndexPage(index, blkno);
			totFreePages++;
		}
		else if (RumPageIsData(page))
		{
			idxStat.nDataPages++;
		}
		else if (RumPageIsDeleted(page) && !RumPageIsLeaf(page))
		{
			/*
			 * A deleted page that has not yet reached its recycle horizon (so
			 * RumPageIsRecyclable() above returned false). Posting-tree pruning
			 * deletes pages with RumPageForceSetDeleted(), which overwrites the
			 * flags word with exactly RUM_DELETED and therefore clears both
			 * RUM_DATA and RUM_LEAF, so RumPageIsData() no longer recognizes it.
			 * Without this branch such a page would fall through to the
			 * entry-page bucket below and inflate both the logged numEntryPages
			 * and the metapage's nEntryPages (rumUpdateStats).
			 *
			 * We deliberately require !RumPageIsLeaf here to validate that we are
			 * not misclassifying an entry page as an empty posting page: a
			 * deleted entry leaf keeps its RUM_LEAF flag (RumPageMarkAsDeleted
			 * uses RumPageSetDeleted, which preserves the existing flags) and is
			 * only ever marked deleted once already recyclable (accounted as free
			 * above), so it never reaches here. Any leaf-flagged deleted page
			 * therefore falls through to the entry bucket rather than being
			 * counted as a posting page.
			 */
			vacStats.numEmptyPostingTreePages++;
		}
		else
		{
			idxStat.nEntryPages++;

			if (RumPageIsLeaf(page))
			{
				if (gvs.inlineVacuumBulkDelDataPages &&
					!RumVacuumSkipPrunePostingTreePages)
				{
					/* If we did an inline bulk delete of data pages, then
					 * We will have empty data pages that are still parented
					 * to their posting trees. We don't want to prune them in
					 * bulk delete since that would happen with multiple cycles
					 * on large indexes. Instead we do the pruning as part of the
					 * vacuumcleanup once per vacuum cycle here.
					 * As part of that, if the page becomes empty, we apply page
					 * deletion to the page.
					 * TraverseAndPrunePostingTrees will release the buffer as well.
					 */
					releaseBuffer = false;
					TraverseAndPrunePostingTrees(&gvs, page, buffer, blkno, &vacStats);
				}

				idxStat.nEntries += PageGetMaxOffsetNumber(page);
			}
		}

		if (releaseBuffer)
		{
			UnlockReleaseBuffer(buffer);
		}

		pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_DONE,
									 blkno);
	}

	/* Update the metapage with accurate page and entry counts */
	idxStat.nTotalPages = npages;
	rumUpdateStats(info->index, &idxStat, false);

	/* Finally, vacuum the FSM */
	IndexFreeSpaceMapVacuum(info->index);

	stats->pages_free = totFreePages;

	if (needLock)
	{
		LockRelationForExtension(index, ExclusiveLock);
	}

	stats->num_pages = RelationGetNumberOfBlocks(index);

	if (needLock)
	{
		UnlockRelationForExtension(index, ExclusiveLock);
	}

	vacStats.numEntryPages = idxStat.nEntryPages;
	vacStats.numDataPages = idxStat.nDataPages;
	vacStats.numVoidPages = stats->pages_free;

	LogFinalVacuumState(index, &vacStats, RumEnableNewBulkDelete, isVacuumCleanup);
	return stats;
}


static void
rum_end_vacuum_callback(int code, Datum arg)
{
	rum_end_vacuum_cycle_id((Relation) DatumGetPointer(arg));
}


static void
rumBulkDeleteDiskOrderedOnePage(RumVacuumState *gvs, BlockNumber scanblkno,
								RumVacuumStatistics *vacStats, BlockNumber *blocks_done)
{
	Relation rel = gvs->index;
	BlockNumber blkno,
				backtrack_to;
	Buffer buf;
	Page page;

	blkno = scanblkno;

backtrack:

	backtrack_to = InvalidBlockNumber;

	/* call vacuum_delay_point while not holding any buffer lock */
	RumVacuumDelayPointCompat();

	/* Check for interripts before acquiring any locks */
	CHECK_FOR_INTERRUPTS();

	/*
	 * We can't use _bt_getbuf() here because it always applies
	 * _bt_checkpage(), which will barf on an all-zero page. We want to
	 * recycle all-zero pages, not fail.  Also, we want to use a nondefault
	 * buffer access strategy.
	 */
	buf = ReadBufferExtended(rel, MAIN_FORKNUM, blkno, RBM_NORMAL,
							 gvs->strategy);
	LockBuffer(buf, RUM_SHARE);
	page = BufferGetPage(buf);
	if (!PageIsNew(page))
	{
		if (PageGetSpecialSize(page) != MAXALIGN(sizeof(RumPageOpaqueData)))
		{
			ereport(ERROR,
					(errcode(ERRCODE_INDEX_CORRUPTED),
					 errmsg("index \"%s\" contains corrupted page at block %u",
							RelationGetRelationName(rel), BufferGetBlockNumber(buf))));
		}
	}
	else
	{
		/* PageIsNew: Don't parse this page any further */
		UnlockReleaseBuffer(buf);
		vacStats->numVoidPages++;
		return;
	}

	Assert(blkno <= scanblkno);
	if (blkno != scanblkno)
	{
		/*
		 * We're backtracking.
		 *
		 * We followed a right link to a sibling leaf page (a page that
		 * happens to be from a block located before scanblkno).  The only
		 * case we want to do anything with is a live leaf page having the
		 * current vacuum cycle ID.
		 *
		 * Check that the page is in a state that's consistent.
		 */
		if (!RumPageIsLeaf(page) || RumPageIsHalfDead(page) || RumPageIsDeleted(page))
		{
			ereport(LOG,
					(errcode(ERRCODE_INDEX_CORRUPTED),
					 errmsg_internal(
						 "[RUM] right sibling %u of scanblkno %u unexpectedly in an inconsistent state in index \"%s\"",
						 blkno, scanblkno, RelationGetRelationName(rel))));
			UnlockReleaseBuffer(buf);
			return;
		}

		/*
		 * We may have already processed the page in an earlier call, when the
		 * page was scanblkno.  This happens when the leaf page split occurred
		 * after the scan began, but before the right sibling page became the
		 * scanblkno.
		 */
		if (RumPageGetCycleId(page) != gvs->cycleId)
		{
			/* Done with current scanblkno (and all lower split pages) */
			UnlockReleaseBuffer(buf);
			return;
		}
	}
	else if (RumPageIsHalfDead(page) || RumPageIsDeleted(page))
	{
		/* Don't bother processing deleted pages */
		vacStats->numVoidPages++;
		UnlockReleaseBuffer(buf);
		return;
	}
	else if (RumPageIsData(page))
	{
		vacStats->numDataPages++;
	}
	else
	{
		vacStats->numEntryPages++;
	}

	/* Only vacuum leaf pages here */
	if (!RumPageIsLeaf(page))
	{
		/* Done with current scanblkno. */
		UnlockReleaseBuffer(buf);
		return;
	}

	/* Upgrade read lock for a exclusive lock on this page. */
	LockBuffer(buf, RUM_UNLOCK);
	LockBuffer(buf, RUM_EXCLUSIVE);
	page = BufferGetPage(buf);

	/*
	 * Check whether we need to backtrack to earlier pages.  What we are
	 * concerned about is a page split that happened since we started the
	 * vacuum scan.  If the split moved tuples on the right half of the
	 * split (i.e. the tuples that sort high) to a block that we already
	 * passed over, then we might have missed the tuples.  We need to
	 * backtrack now.  (Must do this before possibly clearing btpo_cycleid
	 * or deleting scanblkno page below!)
	 */
	if (gvs->cycleId != 0 &&
		RumPageGetCycleId(page) == gvs->cycleId &&
		!RumPageRightMost(page) &&
		RumPageGetOpaque(page)->rightlink < scanblkno)
	{
		backtrack_to = RumPageGetOpaque(page)->rightlink;
	}

	/* Test path that forces pages only to be visited via the backtrack path */
	if (RumTraversePageOnlyOnBackTrack &&
		gvs->cycleId != 0 &&
		RumPageGetCycleId(page) == gvs->cycleId &&
		!RumPageLeftMost(page) &&
		RumPageGetOpaque(page)->leftlink > scanblkno &&
		blkno == scanblkno)
	{
		/*
		 * In this path, we're encountering the right page of
		 * a page split - if the GUC is enabled
		 * traverse it only on the backtrack path.
		 */
		vacStats->numPagesSkippedForBackTrack++;
		UnlockReleaseBuffer(buf);
		return;
	}

	/* Leaf entry page */
	if (!RumPageIsData(page))
	{
		rumBulkDeleteOneEntryPage(page, buf, blkno, gvs, blocks_done,
								  &vacStats->numEmptyEntries, &vacStats->numPrunedEntries,
								  &vacStats->numEmptyPostingTrees,
								  &vacStats->numEmptyPages,
								  &vacStats->prunedEmptyPostingRoots,
								  &vacStats->numPrunedPages,
								  &vacStats->numEmptyPostingTreePages,
								  vacStats);
	}
	else if (RumPageIsData(page) && gvs->inlineVacuumBulkDelDataPages)
	{
		OffsetNumber postingTreeAttNum = gvs->postingTreeAttNum;
		OffsetNumber maxOffsetAfterVacuum = InvalidOffsetNumber;

		/* We don't know if it's a root page but pretend it is for now. */
		bool isRoot = true;
		rumCleanPostingTreeLeafTids(gvs, postingTreeAttNum, page, buf, isRoot,
									&maxOffsetAfterVacuum);
		UnlockReleaseBuffer(buf);
	}
	else
	{
		/* Interior pages or non vacuumable data pages - not vacuumed in this cycle
		 * We also don't backtrack in this path.
		 */
		backtrack_to = InvalidBlockNumber;
		UnlockReleaseBuffer(buf);
	}

	if (backtrack_to != InvalidBlockNumber)
	{
		vacStats->numEntryBacktracks++;
		blkno = backtrack_to;
		goto backtrack;
	}
}


static void
rumBulkDeleteDiskOrderedCore(IndexVacuumInfo *info, IndexBulkDeleteResult *stats,
							 IndexBulkDeleteCallback callback, void *callback_state,
							 RumVacuumCycleId cycleid)
{
	Relation rel = info->index;
	RumVacuumState gvs;
	BlockNumber num_pages;
	BlockNumber scanblkno;
	BlockNumber blocks_done;
	bool isVacuumCleanup = false;
	bool isNewBulkDelete = true;

	RumVacuumStatistics vacStats = { 0 };

	InitRumVacuumState(&gvs, rel, stats);
	gvs.callback = callback;
	gvs.callback_state = callback_state;
	gvs.strategy = info->strategy;
	gvs.cycleId = cycleid;

	/* we'll re-count the tuples each time */
	stats->num_index_tuples = 0;

	/*
	 * For more details on this loop see btvacuumscan.
	 */
	scanblkno = RUM_ROOT_BLKNO;
	blocks_done = 0;
	for (;;)
	{
		/* Get the current relation length */
		LockRelationForExtension(rel, ExclusiveLock);
		num_pages = RelationGetNumberOfBlocks(rel);
		UnlockRelationForExtension(rel, ExclusiveLock);
		pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_TOTAL, num_pages);

		/* Quit if we've scanned the whole relation */
		if (scanblkno >= num_pages)
		{
			break;
		}

		/* Iterate over pages, then loop back to recheck length */
		for (; scanblkno < num_pages; scanblkno++)
		{
			rumBulkDeleteDiskOrderedOnePage(&gvs, scanblkno, &vacStats, &blocks_done);

			pgstat_progress_update_param(PROGRESS_SCAN_BLOCKS_DONE, scanblkno);
		}
	}

	/* Set statistics num_pages field to final size of index */
	stats->num_pages = num_pages;

	LogFinalVacuumState(rel, &vacStats, isNewBulkDelete, isVacuumCleanup);
}


#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wclobbered"

static IndexBulkDeleteResult *
rumBulkDeleteDiskOrdered(IndexVacuumInfo *info,
						 IndexBulkDeleteResult *stats, IndexBulkDeleteCallback callback,
						 void *callback_state)
{
	Relation rel = info->index;
	RumVacuumCycleId cycleid;

	/* Is this the first time running through? */
	if (stats == NULL)
	{
		/* Yes, so initialize stats to zeroes */
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));
	}

	/* Establish the vacuum cycle ID to use for this scan */
	/* The ENSURE stuff ensures we clean up shared memory on failure */
	PG_ENSURE_ERROR_CLEANUP(rum_end_vacuum_callback, PointerGetDatum(rel));
	{
		cycleid = rum_start_vacuum_cycle_id(rel);

		rumBulkDeleteDiskOrderedCore(info, stats, callback, callback_state, cycleid);
	}
	PG_END_ENSURE_ERROR_CLEANUP(rum_end_vacuum_callback, PointerGetDatum(rel));
	rum_end_vacuum_cycle_id(rel);

	return stats;
}


#pragma GCC diagnostic pop


/*
 * This is a modified version of rumPostingTreePruneEmptyPagesUnderRootLock where we only try to traverse down
 * to the target page to prune and delete the one page. We then traverse back up until
 * the root and prune any intermediate empty pages that we meet in the process.
 * Note - the root must be locked with a cleanup lock before entering this method.
 *
 * This ensures that we still do cleanup of intermediate pages, but we hold the
 * exclusive lock on the root *only* for the duration of deleting one page. Each page
 * deletion reacquires the root cleanup lock so we don't end up blocking writes with
 * BufferContentLocks.
 */
static bool
TryDeletePostingTreePage(RumVacuumState *gvs, BlockNumber blkno, bool isRoot,
						 AttrNumber postingTreeAttNum,
						 DataPageDeleteStack *parent, OffsetNumber myoff,
						 RumPostingTreeDeleteEntry *deleteEntry,
						 RumVacuumStatistics *vacStats)
{
	DataPageDeleteStack *me;
	Buffer buffer;
	Page page;
	bool meDelete = false;

	if (isRoot)
	{
		me = parent;
	}
	else
	{
		if (!parent->child)
		{
			me = (DataPageDeleteStack *) palloc0(sizeof(DataPageDeleteStack));
			me->parent = parent;
			parent->child = me;
		}
		else
		{
			me = parent->child;
		}
	}

	buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, blkno,
								RBM_NORMAL, gvs->strategy);

	if (!isRoot)
	{
		LockBuffer(buffer, RUM_EXCLUSIVE);
	}

	page = BufferGetPage(buffer);

	Assert(RumPageIsData(page));

	if (!RumPageIsLeaf(page))
	{
		OffsetNumber i;

		me->blkno = blkno;
		for (i = FirstOffsetNumber; i <= RumDataPageMaxOff(page); i++)
		{
			RumPostingItem *pitem = (RumPostingItem *) RumDataPageGetItem(page, i);
			int compare = compareRumItem(&gvs->rumstate,
										 postingTreeAttNum,
										 &pitem->item,
										 &deleteEntry->pageMaxItem);

			/* If the max of the posting entry is >= the item we're comparing, descend */
			if (compare >= 0 || i == RumDataPageMaxOff(page))
			{
				TryDeletePostingTreePage(gvs, PostingItemGetBlockNumber(pitem), false,
										 postingTreeAttNum,
										 me, i, deleteEntry, vacStats);

				/* Don't traverse any further */
				break;
			}
		}
	}

	if (RumDataPageMaxOff(page) < FirstOffsetNumber && !isRoot)
	{
		/*
		 * Capture the leaf flag before releasing the buffer: once the pin is
		 * dropped the frame can be evicted and refilled with an unrelated block,
		 * so the page must not be dereferenced afterwards.
		 */
		bool wasLeaf = RumPageIsLeaf(page);

		/*
		 * Release the buffer because in rumDeletePage() we need to pin it again
		 * and call ConditionalLockBufferForCleanup().
		 */
		UnlockReleaseBuffer(buffer);
		if (deleteEntry->deleteBlock == blkno || !wasLeaf)
		{
			meDelete = rumDeletePage(gvs, blkno, me->parent->blkno, myoff);
			if (meDelete)
			{
				if (deleteEntry->deleteBlock == blkno)
				{
					deleteEntry->entryDeleted = true;
				}

				vacStats->numPostingTreePagesDeleted++;
			}
		}
	}
	else if (!isRoot)
	{
		UnlockReleaseBuffer(buffer);
	}
	else
	{
		ReleaseBuffer(buffer);
	}

	return meDelete;
}


static void
TryDeletePostingLeafFromTree(RumVacuumState *gvs, BlockNumber rootBlkno,
							 AttrNumber attnum,
							 RumPostingTreeDeleteEntry *deleteEntry,
							 RumVacuumStatistics *vacStats)
{
	/*
	 * There is at least one empty page.  So we have to rescan the tree
	 * deleting empty pages.
	 */
	Buffer buffer;
	DataPageDeleteStack root,
						*ptr,
						*tmp;

	buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, rootBlkno,
								RBM_NORMAL, gvs->strategy);

	/*
	 * Lock posting tree root for cleanup to ensure there are no
	 * concurrent inserts.
	 */
	LockBufferForCleanup(buffer);
	memset(&root, 0, sizeof(DataPageDeleteStack));
	root.isRoot = true;

	TryDeletePostingTreePage(gvs, rootBlkno, true, attnum, &root, InvalidOffsetNumber,
							 deleteEntry, vacStats);

	ptr = root.child;

	while (ptr)
	{
		tmp = ptr->child;
		pfree(ptr);
		ptr = tmp;
	}

	UnlockReleaseBuffer(buffer);
}


/*
 * Prune empty pages from the posting tree.
 * Returns the number of posting tree pages deleted.
 *
 * Walks leaves without holding the root cleanup lock. For each empty leaf, takes
 * the root cleanup lock only for a targeted descent to that leaf. Also prunes
 * empty ancestors on the stack unwind.
 *
 * This intentionally mirrors RumVacuumPrunePostingTree, but keeps an ambulkdelete-facing
 * contract: rumVacuumPostingTree already computed leaf emptiness during TID cleanup and
 * only needs deleted-page accounting.
 *
 * Also uses BufferGetBlockNumber(buffer) for the leaf being inspected instead of the
 * traversal cursor, since FindLeftMostLeafDataPage may move buffer from the root
 * to the leftmost leaf before the scan starts. This is a change we want to evaluate in production
 * before making it the default behavior.
 *
 * TODO: armaans Extract the common rightlink scan and targeted empty-leaf deletion into
 * a shared helper after this ambulkdelete path has been evaluated.
 */
static uint32_t
rumPostingTreePruneEmptyPagesTargeted(RumVacuumState *gvs,
									  OffsetNumber attnum,
									  BlockNumber rootBlkno)
{
	Buffer buffer;
	Page page;
	BlockNumber nextBlockNumber;
	bool isPageRoot = true;
	bool exclusive = false;

	/*
	 * TryDeletePostingLeafFromTree reports page deletions through
	 * RumVacuumStatistics because its existing caller is rumvacuumcleanup.
	 * Use local stats here for now and translate back to the returned count.
	 */
	RumVacuumStatistics localStats = { 0 };

	/* Find leftmost leaf page of posting tree and lock it in non-exclusive mode */
	buffer = FindLeftMostLeafDataPage(gvs, rootBlkno, &isPageRoot, exclusive);
	page = BufferGetPage(buffer);
	if (isPageRoot)
	{
		/* We don't ever prune the root posting tree */
		UnlockReleaseBuffer(buffer);

		return 0;
	}

	/*
	 * Iterate posting tree leaves using rightlinks. For each empty leaf, use a
	 * targeted descent from the root to attempt to delete the leaf and prune empty ancestors.
	 */
	while (true)
	{
		BlockNumber currentBlockNo = BufferGetBlockNumber(buffer);
		nextBlockNumber = RumPageGetOpaque(page)->rightlink;
		if (RumDataPageMaxOff(page) < FirstOffsetNumber)
		{
			/* We're trying to delete this page - send the right bound entry of the current page
			 * So that's the one being searched for in the parents.
			 */
			RumItem *maxEntry = RumDataPageGetRightBound(page);
			RumPostingTreeDeleteEntry deleteEntry = { 0 };
			deleteEntry.deleteBlock = currentBlockNo;
			deleteEntry.pageMaxItem = *maxEntry;
			deleteEntry.entryDeleted = false;
			UnlockReleaseBuffer(buffer);
			TryDeletePostingLeafFromTree(gvs, rootBlkno, attnum, &deleteEntry,
										 &localStats);
		}
		else
		{
			UnlockReleaseBuffer(buffer);
		}

		if (nextBlockNumber == InvalidBlockNumber)
		{
			break;
		}

		/* Delay here and check for interrupts when not holding locks */
		RumVacuumDelayPointCompat();
		CHECK_FOR_INTERRUPTS();

		buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, nextBlockNumber,
									RBM_NORMAL, gvs->strategy);
		LockBuffer(buffer, RUM_SHARE);
		page = BufferGetPage(buffer);
	}

	return localStats.numPostingTreePagesDeleted;
}


static bool
RumVacuumPrunePostingTree(RumVacuumState *gvs, OffsetNumber attnum, BlockNumber blockNo,
						  RumVacuumStatistics *vacStats)
{
	Buffer buffer;
	Page page;
	BlockNumber rootBlockNumber = blockNo;
	bool isPageRoot = true;
	bool exclusive = false;
	bool isPostingTreePrunableEmpty = true;
	bool isPostingTreeLeavesEmpty = true;

	/* Find leftmost leaf page of posting tree and lock it in non-exclusive mode */
	buffer = FindLeftMostLeafDataPage(gvs, blockNo, &isPageRoot, exclusive);
	page = BufferGetPage(buffer);
	if (isPageRoot)
	{
		/* We don't ever prune the root posting tree */
		bool isPageEmpty = RumDataPageMaxOff(page) < FirstOffsetNumber;
		UnlockReleaseBuffer(buffer);
		if (isPageEmpty)
		{
			vacStats->numEmptyPostingTrees++;
		}

		return isPageEmpty;
	}

	/* Iterate all posting tree leaves using rightlinks and check if they're empty.
	 * if they are, then apply deletion on the chain recursively.
	 */
	while (true)
	{
		BlockNumber currentBlockNo = blockNo;
		blockNo = RumPageGetOpaque(page)->rightlink;
		if (RumDataPageMaxOff(page) < FirstOffsetNumber)
		{
			/* We're trying to delete this page - send the right bound entry of the current page
			 * So that's the one being searched for in the parents.
			 */
			RumItem *maxEntry = RumDataPageGetRightBound(page);
			RumPostingTreeDeleteEntry deleteEntry = { 0 };
			deleteEntry.deleteBlock = currentBlockNo;
			deleteEntry.pageMaxItem = *maxEntry;
			deleteEntry.entryDeleted = false;
			UnlockReleaseBuffer(buffer);
			TryDeletePostingLeafFromTree(gvs, rootBlockNumber, attnum, &deleteEntry,
										 vacStats);
			if (!deleteEntry.entryDeleted)
			{
				isPostingTreePrunableEmpty = false;
			}
		}
		else
		{
			isPostingTreePrunableEmpty = false;
			isPostingTreeLeavesEmpty = false;
			UnlockReleaseBuffer(buffer);
		}

		if (blockNo == InvalidBlockNumber)
		{
			break;
		}

		/* Delay here and check for interrupts when not holding locks */
		RumVacuumDelayPointCompat();
		CHECK_FOR_INTERRUPTS();

		buffer = ReadBufferExtended(gvs->index, MAIN_FORKNUM, blockNo,
									RBM_NORMAL, gvs->strategy);
		LockBuffer(buffer, RUM_SHARE);
		page = BufferGetPage(buffer);
	}

	if (isPostingTreeLeavesEmpty)
	{
		vacStats->numEmptyPostingTrees++;
	}

	return isPostingTreePrunableEmpty;
}


static void
TraverseAndPrunePostingTrees(RumVacuumState *gvs, Page page, Buffer buffer,
							 BlockNumber currentBlockNo,
							 RumVacuumStatistics *vacStats)
{
	bool isEmptyPage = true;
	uint32_t i;
	OffsetNumber maxoff = PageGetMaxOffsetNumber(page);

	BlockNumber rootOfPostingTree[BLCKSZ / (sizeof(IndexTupleData) + sizeof(ItemId))];
	OffsetNumber attnumOfPostingTree[BLCKSZ / (sizeof(IndexTupleData) + sizeof(ItemId))];
	uint32 nRoot = 0;

	Assert(!RumPageIsData(page));
	Assert(gvs->inlineVacuumBulkDelDataPages);
	for (i = FirstOffsetNumber; i <= maxoff; i++)
	{
		IndexTuple itup = (IndexTuple) PageGetItem(page, PageGetItemId(page, i));

		if (RumIsPostingTree(itup))
		{
			/*
			 * store posting tree's roots for further processing, we can't
			 * vacuum it just now due to risk of deadlocks with scans/inserts
			 */
			rootOfPostingTree[nRoot] = RumGetDownlink(itup);
			attnumOfPostingTree[nRoot] = rumtuple_get_attrnum(&gvs->rumstate, itup);
			nRoot++;

			/* We don't track emptiness of posting trees here -
			 * we will do so below */
		}
		else if (RumGetNPosting(itup) > 0)
		{
			isEmptyPage = false;
		}
	}

	UnlockReleaseBuffer(buffer);

	/* Now process the posting trees */
	for (i = 0; i < nRoot; i++)
	{
		bool isEmptyPrunableTree = RumVacuumPrunePostingTree(gvs, attnumOfPostingTree[i],
															 rootOfPostingTree[i],
															 vacStats);

		if (!isEmptyPrunableTree)
		{
			isEmptyPage = false;
		}
	}


	/* If we found a truly empty page, now handle this here */
	if (isEmptyPage && RumPruneEmptyPages)
	{
		CheckAndPruneEmptyRumPage(&gvs->rumstate, gvs->strategy,
								  currentBlockNo, &vacStats->prunedEmptyPostingRoots);
	}
}
