/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/utils/heap_utils.h
 *
 * Utility to maintain min/max heap.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <common/hashfn.h>
#include <utils/hsearch.h>
#include "commands/commands_common.h"

#ifndef HEAP_UTILS_H
#define HEAP_UTILS_H

typedef enum HeapType
{
	HeapType_Regular = 0,
	HeapType_Extended = 1
} HeapType;

/**
 * Defines how the heap is sorted.
 * For minheap, the comparator should return true if first < second.
 * For maxheap, the comparator should return true if first > second.
 */
typedef bool (*HeapComparator)(const bson_value_t *first, const bson_value_t *second);

/*
 * binaryheap
 *      type            type of heap (regular/dynamic)
 *		heapNodes		variable-length array of "space" nodes
 *		heapSpace		how many nodes can be stored in "nodes"
 *		heapSize		how many nodes are currently in "nodes"
 *		maximumHeapSpace maximum capacity of the heap (only for dynamic heaps)
 *		heapComparator	comparison function to define the heap property
 */
typedef struct BinaryHeap
{
	HeapType type;
	bson_value_t *heapNodes;
	int64_t heapSpace;
	int64_t heapSize;
	int64_t maximumHeapSpace;
	HeapComparator heapComparator;
} BinaryHeap;


BinaryHeap * AllocateHeap(int64_t capacity, HeapComparator comparator);
void PushToHeap(BinaryHeap *heap, const bson_value_t *value);
bson_value_t PopFromHeap(BinaryHeap *heap);
bson_value_t TopHeap(BinaryHeap *heap);
void FreeHeap(BinaryHeap *heap);

BinaryHeap * AllocateDynamicHeap(int64_t initialCapacity, int64_t maximumCapacity,
								 HeapComparator comparator);
void PushToDynamicHeap(BinaryHeap *heap, const bson_value_t *value);
bson_value_t PopFromDynamicHeap(BinaryHeap *heap);
#endif
