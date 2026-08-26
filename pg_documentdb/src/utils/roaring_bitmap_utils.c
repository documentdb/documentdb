/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/utils/roaring_bitmap_utils.c
 *
 * Adapter implementation for roaring bitmaps: a 32-bit bitmap adapter for
 * serializable uint32 sets, and a 64-bit heap-TID de-duplication set (used to
 * drop already-emitted rows above an order-preserving merge). This file is the
 * only compilation unit that includes the roaring library header; all other
 * code goes through the opaque API declared in
 * include/utils/roaring_bitmap_utils.h.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>

#include "roaring_bitmaps/roaring.h"
#include "utils/roaring_bitmap_utils.h"


/*
 * Concrete definition of the opaque RoaringBitmap32State handle declared in
 * include/utils/roaring_bitmap_utils.h. Consumers see only the incomplete
 * type and must go through the adapter functions below.
 */
struct RoaringBitmap32State
{
	roaring_bitmap_t *bitmap;
};


/*
 * Concrete definition of the opaque RoaringTidDedupState handle. Uses a 64-bit
 * roaring bitmap so a full heap ItemPointer (block + offset) fits in a single
 * key.
 */
struct RoaringTidDedupState
{
	roaring64_bitmap_t *bitmap;
};


/*
 * Pack a heap ItemPointer into a 64-bit key: block number in the high bits,
 * item offset in the low 16 bits.
 *
 * An ItemPointer has no relation/shard id, so (block, offset) is unique only
 * within a single relation -- two shards can share the same value. That is safe
 * here because each de-dup set is scoped to one scan over one relation (a single
 * shard's heap in the distributed case) and is never shared across relations.
 */
#define ItemPointerToUint64(pointer) \
	((((uint64) ItemPointerGetBlockNumber(pointer)) << 16) | \
	 ItemPointerGetOffsetNumber(pointer))

static RoaringBitmap32State * CreateRoaringBitmap(uint32 initialCapacity);
static void FreeRoaringBitmap(RoaringBitmap32State *state);
static void RoaringBitmapAddMany(RoaringBitmap32State *state, uint32 count,
								 const uint32 *values);
static uint64 RoaringBitmapGetCardinality(RoaringBitmap32State *state);
static void RoaringBitmapToUint32Array(RoaringBitmap32State *state, uint32 *outValues);
static void RoaringBitmapRunOptimize(RoaringBitmap32State *state);
static size_t RoaringBitmapSerializedSize(RoaringBitmap32State *state);
static void RoaringBitmapSerialize(RoaringBitmap32State *state, char *buf);
static RoaringBitmap32State * RoaringBitmapDeserialize(const char *buf, size_t length);


const RoaringBitmap32AdapterFuncs RoaringBitmapAdapter = {
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


static RoaringBitmap32State *
CreateRoaringBitmap(uint32 initialCapacity)
{
	RoaringBitmap32State *state = palloc(sizeof(RoaringBitmap32State));
	state->bitmap = roaring_bitmap_create_with_capacity(
		(uint32_t) initialCapacity);
	return state;
}


static void
FreeRoaringBitmap(RoaringBitmap32State *state)
{
	if (state == NULL)
	{
		return;
	}

	roaring_bitmap_free(state->bitmap);
	pfree(state);
}


static void
RoaringBitmapAddMany(RoaringBitmap32State *state, uint32 count, const uint32 *values)
{
	roaring_bitmap_add_many(state->bitmap, (size_t) count, values);
}


static uint64
RoaringBitmapGetCardinality(RoaringBitmap32State *state)
{
	return roaring_bitmap_get_cardinality(state->bitmap);
}


static void
RoaringBitmapToUint32Array(RoaringBitmap32State *state, uint32 *outValues)
{
	roaring_bitmap_to_uint32_array(state->bitmap, outValues);
}


static void
RoaringBitmapRunOptimize(RoaringBitmap32State *state)
{
	roaring_bitmap_run_optimize(state->bitmap);
}


static size_t
RoaringBitmapSerializedSize(RoaringBitmap32State *state)
{
	return roaring_bitmap_portable_size_in_bytes(state->bitmap);
}


static void
RoaringBitmapSerialize(RoaringBitmap32State *state, char *buf)
{
	roaring_bitmap_portable_serialize(state->bitmap, buf);
}


static RoaringBitmap32State *
RoaringBitmapDeserialize(const char *buf, size_t length)
{
	roaring_bitmap_t *bitmap =
		roaring_bitmap_portable_deserialize_safe(buf, length);
	if (bitmap == NULL)
	{
		return NULL;
	}

	RoaringBitmap32State *state = palloc(sizeof(RoaringBitmap32State));
	state->bitmap = bitmap;
	return state;
}


RoaringTidDedupState *
CreateRoaringTidDedup(void)
{
	RoaringTidDedupState *state = palloc(sizeof(RoaringTidDedupState));
	state->bitmap = roaring64_bitmap_create();
	if (state->bitmap == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY),
						errmsg(
							"failed to allocate roaring bitmap for TID de-duplication")));
	}

	return state;
}


bool
RoaringTidDedupAddChecked(RoaringTidDedupState *state, ItemPointer tid)
{
	uint64 key = ItemPointerToUint64(tid);
	return roaring64_bitmap_add_checked(state->bitmap, key);
}


void
FreeRoaringTidDedup(RoaringTidDedupState *state)
{
	if (state == NULL)
	{
		return;
	}

	roaring64_bitmap_free(state->bitmap);
	pfree(state);
}


static void *
roaring_pg_malloc(size_t num_bytes)
{
	return palloc(num_bytes);
}


static void *
roaring_pg_calloc(size_t n_members, size_t num_bytes)
{
	/* TODO: Is this the best way to handle this? */
	return palloc0(n_members * num_bytes);
}


static void *
roaring_pg_realloc(void *mem, size_t num_bytes)
{
	if (mem == NULL)
	{
		return roaring_pg_malloc(num_bytes);
	}

	return repalloc(mem, num_bytes);
}


static void *
roaring_pg_aligned_alloc(size_t alignment, size_t num_bytes)
{
#if PG_VERSION_NUM >= 160000
	return palloc_aligned(num_bytes, alignment, 0);
#else
	return roaring_pg_malloc(num_bytes);
#endif
}


static void
roaring_pg_free(void *mem)
{
	if (mem != NULL)
	{
		pfree(mem);
	}
}


static void
InstallRoaringMemoryHooks(void)
{
	roaring_memory_t memory_hook = {
		.malloc = roaring_pg_malloc,
		.realloc = roaring_pg_realloc,
		.calloc = roaring_pg_calloc,
		.free = roaring_pg_free,
		.aligned_malloc = roaring_pg_aligned_alloc,
		.aligned_free = roaring_pg_free,
	};
	roaring_init_memory_hook(memory_hook);
}


void
RegisterDocumentDBRoaringBitmapUtilHooks(void)
{
	InstallRoaringMemoryHooks();
}
