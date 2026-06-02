/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/utils/roaring_bitmap_utils.c
 *
 * Adapter implementation for 32-bit roaring bitmaps
 * This file is the only compilation unit that includes the roaring library
 * header; all other code goes through the opaque API
 * declared in include/utils/roaring_bitmap_utils.h.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>

#include "roaring_bitmaps/roaring.h"
#include "utils/roaring_bitmap_utils.h"


/*
 * Concrete definition of the opaque RoaringBitmapState handle declared in
 * include/utils/roaring_bitmap_utils.h. Consumers see only the incomplete
 * type and must go through the adapter functions below.
 */
struct RoaringBitmapState
{
	roaring_bitmap_t *bitmap;
};


static RoaringBitmapState * CreateRoaringBitmap(uint32 initialCapacity);
static void FreeRoaringBitmap(RoaringBitmapState *state);
static void RoaringBitmapAddMany(RoaringBitmapState *state, uint32 count,
								 const uint32 *values);
static uint64 RoaringBitmapGetCardinality(RoaringBitmapState *state);
static void RoaringBitmapToUint32Array(RoaringBitmapState *state, uint32 *outValues);
static void RoaringBitmapRunOptimize(RoaringBitmapState *state);
static size_t RoaringBitmapSerializedSize(RoaringBitmapState *state);
static void RoaringBitmapSerialize(RoaringBitmapState *state, char *buf);
static RoaringBitmapState * RoaringBitmapDeserialize(const char *buf, size_t length);


const RoaringBitmapAdapterFuncs RoaringBitmapAdapter = {
	.create = CreateRoaringBitmap,
	.free = FreeRoaringBitmap,
	.addMany = RoaringBitmapAddMany,
	.getCardinality = RoaringBitmapGetCardinality,
	.toUint32Array = RoaringBitmapToUint32Array,
	.runOptimize = RoaringBitmapRunOptimize,
	.serializedSize = RoaringBitmapSerializedSize,
	.serialize = RoaringBitmapSerialize,
	.deserialize = RoaringBitmapDeserialize,
};


static RoaringBitmapState *
CreateRoaringBitmap(uint32 initialCapacity)
{
	RoaringBitmapState *state = palloc(sizeof(RoaringBitmapState));
	state->bitmap = roaring_bitmap_create_with_capacity(
		(uint32_t) initialCapacity);
	return state;
}


static void
FreeRoaringBitmap(RoaringBitmapState *state)
{
	if (state == NULL)
	{
		return;
	}

	roaring_bitmap_free(state->bitmap);
	pfree(state);
}


static void
RoaringBitmapAddMany(RoaringBitmapState *state, uint32 count, const uint32 *values)
{
	roaring_bitmap_add_many(state->bitmap, (size_t) count, values);
}


static uint64
RoaringBitmapGetCardinality(RoaringBitmapState *state)
{
	return roaring_bitmap_get_cardinality(state->bitmap);
}


static void
RoaringBitmapToUint32Array(RoaringBitmapState *state, uint32 *outValues)
{
	roaring_bitmap_to_uint32_array(state->bitmap, outValues);
}


static void
RoaringBitmapRunOptimize(RoaringBitmapState *state)
{
	roaring_bitmap_run_optimize(state->bitmap);
}


static size_t
RoaringBitmapSerializedSize(RoaringBitmapState *state)
{
	return roaring_bitmap_portable_size_in_bytes(state->bitmap);
}


static void
RoaringBitmapSerialize(RoaringBitmapState *state, char *buf)
{
	roaring_bitmap_portable_serialize(state->bitmap, buf);
}


static RoaringBitmapState *
RoaringBitmapDeserialize(const char *buf, size_t length)
{
	roaring_bitmap_t *bitmap =
		roaring_bitmap_portable_deserialize_safe(buf, length);
	if (bitmap == NULL)
	{
		return NULL;
	}

	RoaringBitmapState *state = palloc(sizeof(RoaringBitmapState));
	state->bitmap = bitmap;
	return state;
}
