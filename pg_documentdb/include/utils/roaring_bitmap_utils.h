/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/utils/roaring_bitmap_utils.h
 *
 * Adapter layer for roaring bitmaps.
 * All consumers should use the RoaringBitmapAdapterFuncs instead
 * of the roaring library directly, restricting complete library exposure
 * and controlling what we use safely.
 *
 *-------------------------------------------------------------------------
 */

#ifndef ROARING_BITMAP_UTILS_H
#define ROARING_BITMAP_UTILS_H

#include <postgres.h>
#include <storage/itemptr.h>

/*
 * Opaque handle for bitmap state. The full definition lives in the
 * adapter's C file so consumers cannot dereference it; they may only
 * pass it through the adapter functions below.
 */
typedef struct RoaringBitmapState RoaringBitmapState;

/* Function pointer typedefs for each bitmap operation. */
typedef RoaringBitmapState *(*CreateRoaringBitmapFunc)(uint32 initialCapacity);
typedef void (*FreeRoaringBitmapFunc)(RoaringBitmapState *state);
typedef void (*RoaringBitmapAddManyFunc)(RoaringBitmapState *state, uint32 count,
										 const uint32 *values);
typedef uint64 (*RoaringBitmapGetCardinalityFunc)(RoaringBitmapState *state);
typedef void (*RoaringBitmapToUint32ArrayFunc)(RoaringBitmapState *state,
											   uint32 *outValues);
typedef void (*RoaringBitmapRunOptimizeFunc)(RoaringBitmapState *state);
typedef size_t (*RoaringBitmapSerializedSizeFunc)(RoaringBitmapState *state);
typedef void (*RoaringBitmapSerializeFunc)(RoaringBitmapState *state, char *buf);
typedef RoaringBitmapState *(*RoaringBitmapDeserializeFunc)(const char *buf,
															size_t length);


/*
 * Adapter struct that provides function pointers to abstract the roaring
 * bitmap library for serialization / deserialization of sets.
 */
typedef struct RoaringBitmapAdapterFuncs
{
	/* Create opaque bitmap state with the given initial capacity */
	CreateRoaringBitmapFunc create;

	/* Free opaque bitmap state */
	FreeRoaringBitmapFunc free;

	/* Bulk-add uint32 values into the bitmap */
	RoaringBitmapAddManyFunc addMany;

	/* Return the number of values stored in the bitmap */
	RoaringBitmapGetCardinalityFunc getCardinality;

	/* Copy all values into a caller-provided uint32 array */
	RoaringBitmapToUint32ArrayFunc toUint32Array;

	/* Optimize for serialization (run-length encode where beneficial) */
	RoaringBitmapRunOptimizeFunc runOptimize;

	/* Return serialized size in bytes (portable format) */
	RoaringBitmapSerializedSizeFunc serializedSize;

	/* Serialize into buf (must be at least serializedSize bytes) */
	RoaringBitmapSerializeFunc serialize;

	/* Deserialize from buf; returns NULL on failure */
	RoaringBitmapDeserializeFunc deserialize;
} RoaringBitmapAdapterFuncs;


/* Opaque 64-bit heap-TID de-duplication set. */
typedef struct RoaringTidDedupState RoaringTidDedupState;

RoaringTidDedupState * CreateRoaringTidDedup(void);

/*
 * Record a heap TID. Returns true if the TID was newly added (the row has not
 * been emitted before and should be returned), or false if the TID was already
 * present (a duplicate that should be dropped).
 */
bool RoaringTidDedupAddChecked(RoaringTidDedupState *state, ItemPointer tid);

/* Free a heap-TID de-duplication set (no-op when state is NULL). */
void FreeRoaringTidDedup(RoaringTidDedupState *state);


#endif /* ROARING_BITMAP_UTILS_H */
