/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/utils/storage_utils.h
 *
 * Utilities that provide physical storage related metrics and information.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <nodes/parsenodes.h>
#include <utils/array.h>

#ifndef DOCDB_STORAGE_UTILS_H
#define DOCDB_STORAGE_UTILS_H

#define BYTES_PER_MB (double) (1024 * 1024)

typedef struct CollectionBloatStats
{
	/* Whether the PG stats are available or not for the collection */
	bool nullStats;

	/* Estimated bloats storage consumed by dead tuples for the colleciton in bytes based on PG relation's stats */
	uint64 estimatedBloatStorage;

	/* Estimated total collection size based on PG relation's stats  */
	uint64 estimatedTableStorage;
} CollectionBloatStats;

/*
 * Physical on-disk size of a collection, measured from the relation files
 * rather than from planner statistics. Unlike CollectionBloatStats these
 * numbers are exact at the time they are read, which is what allows callers
 * to difference two samples and attribute the change to an operation.
 */
typedef struct CollectionStorageSize
{
	/* Whether a size could be determined for the collection */
	bool nullStats;

	/* Size of the collection including indexes, TOAST and the free space/visibility maps, in bytes */
	uint64 totalRelationSize;

	/* Size of the collection's heap and TOAST data, excluding indexes, in bytes */
	uint64 totalTableSize;
} CollectionStorageSize;

CollectionBloatStats GetCollectionBloatEstimate(uint64 collectionId);
CollectionStorageSize GetCollectionStorageSize(uint64 collectionId);
CollectionStorageSize GetPostgresRelationSizes(ArrayType *relationIds);

#endif
