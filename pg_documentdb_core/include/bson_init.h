/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/bson_init.h
 *
 * Exports related to shared library initialization for the bson type.
 *
 *-------------------------------------------------------------------------
 */
#ifndef BSON_INIT_H
#define BSON_INIT_H

#include <bson/bson.h>
#include <utils/memutils.h>

void InitDocumentDBCoreConfigurations(const char *prefix);
void DocumentDBCore_InstallBsonMemVTablesLocal(void);


/*
 * InstallBsonMemVTablesLocal sets the libbson memory vtable for the
 * statically-linked copy of libbson.
 *
 * Because libbson is linked with -DBSON_STATIC, each .so gets its own
 * private copy of bson_mem_set_vtable and the global allocator dispatch
 * table (gMemVtable).
 * Each .so that uses libbson
 * functions (e.g., bson_value_copy) must call this inline function in
 * its _PG_init() to ensure its local libbson copy uses palloc/pfree.
 */
static void *
BsonMemVTableMalloc(size_t num_bytes)
{
	return palloc(num_bytes);
}


static void *
BsonMemVTableCalloc(size_t n_members, size_t num_bytes)
{
	return palloc0(n_members * num_bytes);
}


static void *
BsonMemVTableRealloc(void *mem, size_t num_bytes)
{
	if (mem == NULL)
	{
		return palloc(num_bytes);
	}
	return repalloc(mem, num_bytes);
}


static void
BsonMemVTableFree(void *mem)
{
	if (mem != NULL)
	{
		pfree(mem);
	}
}


static void *
BsonMemVTableAlignedAlloc(size_t alignment, size_t num_bytes)
{
#if PG_VERSION_NUM >= 160000
	return palloc_aligned(num_bytes, alignment, 0);
#else
	return palloc(num_bytes);
#endif
}


static inline void
InstallBsonMemVTablesLocal(void)
{
	static bool hasSetVTable = false;
	if (!hasSetVTable)
	{
		bson_mem_vtable_t vtable = {
			.malloc = BsonMemVTableMalloc,
			.calloc = BsonMemVTableCalloc,
			.realloc = BsonMemVTableRealloc,
			.free = BsonMemVTableFree,
			.aligned_alloc = BsonMemVTableAlignedAlloc,
			.padding = { 0 }
		};
		bson_mem_set_vtable(&vtable);
		hasSetVTable = true;
	}
}


/*
 * BsonMemVTableSelfTest verifies that libbson allocations in the calling
 * .so go through palloc (i.e., the bson memory vtable was set correctly).
 *
 * Creates a temp memory context, switches to it, calls bson_malloc(),
 * and checks whether the returned pointer belongs to that context via
 * GetMemoryChunkContext().  Returns true if palloc is being used.
 *
 * This is static inline so each .so tests its own statically-linked
 * libbson copy — the whole point of the per-.so vtable setup.
 */
static inline bool
BsonMemVTableSelfTest(void)
{
	MemoryContext tempContext = AllocSetContextCreate(
		CurrentMemoryContext,
		"BsonVTableSelfTest",
		ALLOCSET_DEFAULT_SIZES);

	MemoryContext oldContext = MemoryContextSwitchTo(tempContext);

	/*
	 * Use the bson_malloc/bson_free wrappers instead of bson_new/bson_destroy
	 * to avoid depending on bson_t, which is redefined by bson_core.h in
	 * the service layer (#define bson_t do_not_use_this_type).
	 *
	 * If the vtable is installed correctly, bson_malloc routes through palloc
	 * and the chunk will belong to tempContext.  If not, the pointer came
	 * from libc malloc and GetMemoryChunkContext would return a bogus value.
	 */
	void *mem = bson_malloc(64);

	bool usingPalloc = (GetMemoryChunkContext(mem) == tempContext);

	bson_free(mem);
	MemoryContextSwitchTo(oldContext);
	MemoryContextDelete(tempContext);

	return usingPalloc;
}


#endif
