/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/utils/heap_utils.c
 *
 * Utility to maintain min/max heap.
 *
 *-------------------------------------------------------------------------
 */

#include "utils/heap_utils.h"

#include "commands/commands_common.h"

static void Swap(bson_value_t *a, bson_value_t *b);
static void Heapify(bson_value_t *array, int64_t itemsInArray, int64_t index,
					HeapComparator comparator);
static void InitHeapFields(BinaryHeap *heap, int64_t heapSpace, int64_t maximumHeapSpace,
						   HeapComparator comparator, HeapType type);
static void PushToHeapCommon(BinaryHeap *heap, const bson_value_t *value);


/*
 *
 * Returns a pointer to a newly-allocated heap that has the capacity to
 * store the given number of nodes, with the heap property defined by
 * the given comparator function
 *
 * The capacity parameter defines the maximum space of the heap.
 * The comparator parameter defines how the heap is sorted.
 */
BinaryHeap *
AllocateHeap(int64_t capacity, HeapComparator comparator)
{
	BinaryHeap *heap = palloc(sizeof(BinaryHeap));
	InitHeapFields(heap, capacity, capacity, comparator, HeapType_Regular);
	return heap;
}


/*
 * Stores the provided value into the heap memory.
 */
void
PushToHeap(BinaryHeap *heap, const bson_value_t *value)
{
	Assert(heap->type == HeapType_Regular);

	if (heap->heapSize >= heap->heapSpace)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Heap capacity exceeded while pushing new value")));
	}

	PushToHeapCommon(heap, value);
}


/*
 * Pops the top of the heap.
 */
bson_value_t
PopFromHeap(BinaryHeap *heap)
{
	Assert(heap->type == HeapType_Regular);
	Assert(heap->heapSize > 0);

	bson_value_t result = heap->heapNodes[0];

	if (heap->heapSize == 1)
	{
		heap->heapSize--;
		return result;
	}

	heap->heapNodes[0] = heap->heapNodes[--heap->heapSize];
	Heapify(heap->heapNodes, heap->heapSize, 0, heap->heapComparator);

	return result;
}


/*
 * Returns the top of the heap.
 */
bson_value_t
TopHeap(BinaryHeap *heap)
{
	Assert(heap->heapSize > 0);

	return heap->heapNodes[0];
}


/*
 * Releases memory used by the given binaryheap.
 */
void
FreeHeap(BinaryHeap *heap)
{
	if (heap->heapNodes != NULL)
	{
		pfree(heap->heapNodes);
		heap->heapNodes = NULL;
	}

	heap->heapSpace = 0;
	heap->heapSize = 0;
	pfree(heap);
}


/*
 * Returns a pointer to a newly-allocated heap whose capacity can
 * grow exponentially, with the heap property defined by
 * the given comparator function.
 * The initialCapacity parameter defines the starting capacity of the heap.
 * The maximumCapacity parameter defines the maximum capacity the heap can grow to.
 * The comparator parameter defines how the heap is sorted.
 */
BinaryHeap *
AllocateDynamicHeap(int64_t initialCapacity, int64_t maximumCapacity, HeapComparator
					comparator)
{
	BinaryHeap *heap = palloc(sizeof(BinaryHeap));
	InitHeapFields(heap, initialCapacity, maximumCapacity, comparator,
				   HeapType_Extended);
	return heap;
}


/*
 * Inserts a value into a dynamically growing binary heap.
 *
 * If the underlying array is full, the heap capacity is doubled before
 * inserting the new value. After insertion, the value is percolated
 * up the heap to restore the heap property defined by the comparator.
 *
 * this maximumHeapSpace parameter defines the maximum capacity the heap can grow to.
 *
 * This API must not be mixed with non-dynamic heap functions.
 */
void
PushToDynamicHeap(BinaryHeap *heap, const bson_value_t *value)
{
	Assert(heap->type == HeapType_Extended);

	if (heap->heapSize >= heap->maximumHeapSpace)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Heap capacity exceeded while pushing new value")));
	}

	/* Extend the heap space if needed */
	if (heap->heapSize >= heap->heapSpace)
	{
		heap->heapSpace = Min(heap->heapSpace * 2, heap->maximumHeapSpace);

		heap->heapNodes = (bson_value_t *) repalloc(heap->heapNodes,
													sizeof(bson_value_t) *
													heap->heapSpace);
	}

	PushToHeapCommon(heap, value);
}


/*
 * Pops the top of the heap.
 *
 * This API must not be mixed with non-dynamic heap functions.
 */
bson_value_t
PopFromDynamicHeap(BinaryHeap *heap)
{
	Assert(heap->heapSize > 0);
	Assert(heap->type == HeapType_Extended);

	bson_value_t result = heap->heapNodes[0];

	if (heap->heapSize == 1)
	{
		heap->heapSize--;
		return result;
	}

	heap->heapNodes[0] = heap->heapNodes[--heap->heapSize];
	Heapify(heap->heapNodes, heap->heapSize, 0, heap->heapComparator);

	/* Shrink extended heaps when under-utilized to release memory. */
	if (heap->type == HeapType_Extended && heap->heapSpace > 1 &&
		heap->heapSize < heap->heapSpace / 2)
	{
		int64_t newSpace = Max((int64_t) 1, heap->heapSpace / 2);
		newSpace = Max(newSpace, heap->heapSize);

		if (newSpace != heap->heapSpace)
		{
			heap->heapSpace = newSpace;
			heap->heapNodes = (bson_value_t *) repalloc(heap->heapNodes,
														sizeof(bson_value_t) *
														heap->heapSpace);
		}
	}

	return result;
}


/*
 * Shared initializer for both static and dynamic heaps.
 */
static void
InitHeapFields(BinaryHeap *heap, int64_t heapSpace, int64_t maximumHeapSpace,
			   HeapComparator comparator,
			   HeapType type)
{
	heap->type = type;
	heap->heapComparator = comparator;
	heap->heapSize = 0;
	heap->heapSpace = heapSpace;
	heap->maximumHeapSpace = maximumHeapSpace;

	if (heapSpace > 0)
	{
		heap->heapNodes = (bson_value_t *) palloc(sizeof(bson_value_t) * heapSpace);
	}
	else
	{
		heap->heapNodes = NULL;
	}
}


/*
 * Inserts a value into the binary heap.
 * After insertion, the value is percolated up the heap to restore
 * the heap property defined by the comparator.
 */
static void
PushToHeapCommon(BinaryHeap *heap, const bson_value_t *value)
{
	int64_t index = heap->heapSize++;
	heap->heapNodes[index] = *value;

	/* Ensures that the heap property is maintained after insertion. */
	while (index != 0 && !heap->heapComparator(&heap->heapNodes[(index - 1) / 2],
											   &heap->heapNodes[index]))
	{
		/* If the parent node does not satisfy the heap property with the current node.*/
		Swap(&heap->heapNodes[(index - 1) / 2], &heap->heapNodes[index]);

		/* Move up the tree by setting the current index to its parent's index. */
		index = (index - 1) / 2;
	}
}


/*
 * Swaps the two values
 */
static void
Swap(bson_value_t *a, bson_value_t *b)
{
	bson_value_t temp = *a;
	*a = *b;
	*b = temp;
}


/*
 * Recursively heapifies the array
 */
static void
Heapify(bson_value_t *array, int64_t itemsInArray, int64_t index,
		HeapComparator comparator)
{
	int64_t limit = index;
	int64_t leftIndex = 2 * index + 1;
	int64_t rightIndex = 2 * index + 2;

	if (leftIndex < itemsInArray && comparator(&array[leftIndex], &array[limit]))
	{
		limit = leftIndex;
	}

	if (rightIndex < itemsInArray && comparator(&array[rightIndex], &array[limit]))
	{
		limit = rightIndex;
	}

	if (limit != index)
	{
		Swap(&array[index], &array[limit]);
		Heapify(array, itemsInArray, limit, comparator);
	}
}
