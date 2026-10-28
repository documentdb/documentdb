/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * Native UPDATE construction and execution for update-all operations.
 *-------------------------------------------------------------------------
 */
#ifndef DOCUMENTDB_UPDATE_QUERY_H
#define DOCUMENTDB_UPDATE_QUERY_H

#include "commands/update.h"


/*
 * Defines the format of the result for update-all operations.
 * Number of rows matched vs number of documents actually updated.
 */
typedef struct UpdateAllMatchingDocsResult
{
	/* No-op writes match a document without incrementing rowsUpdated. */
	uint64 rowsUpdated;
	uint64 matchedDocs;
} UpdateAllMatchingDocsResult;


/*
 * Flags indicating the characteristics of an update query.
 */
typedef enum UpdateQueryFlags
{
	UPDATE_QUERY_FLAG_NONE = 0,

	/* Update query has an applicable shard key filter */
	UPDATE_QUERY_FLAG_HAS_SHARD_KEY = 1 << 0,

	/* Update query has an object ID filter */
	UPDATE_QUERY_FLAG_HAS_OBJECT_ID = 1 << 1,

	/* Update query has non-ID filters */
	UPDATE_QUERY_FLAG_HAS_NON_ID_FILTERS = 1 << 2,

	/* Update query has a collation-aware object_id filter */
	UPDATE_QUERY_FLAG_HAS_COLLATION_AWARE_ID_FILTER = 1 << 3,

	/* Update query has only an object ID filter, equivalent to flag combination
	 * UPDATE_QUERY_FLAG_HAS_OBJECT_ID && !UPDATE_QUERY_FLAG_HAS_NON_ID_FILTERS
	 */
	UPDATE_QUERY_FLAG_HAS_ONLY_OBJECT_ID_FILTER = 1 << 4,
} UpdateQueryFlags;


/*
 * Specification for an update-all query.
 */
typedef struct UpdateAllQuerySpec
{
	/* The target collection for the update-all operation. */
	MongoCollection *collection;

	/* The update parameters for the update-all operation. */
	UpdateOneParams *updateParams;

	/* object_id filter if present */
	pgbson *objectIdFilter;

	/* Query flags indicating the characteristics of the update query. */
	UpdateQueryFlags queryFlags;

	/* The hash of the shard key, if applicable. */
	int64 shardKeyHash;

	/* The schema validator for the collection, if applicable. */
	pgbson *schemaValidator;

	/* Is collation required for the update query. */
	bool isCollationApplicable;
} UpdateAllQuerySpec;


static inline bool
IsUpdateAstEnabled(bool hasOnlyObjectIdFilter)
{
	return EnableUpdateQueryAst && !hasOnlyObjectIdFilter;
}


static inline bool
UpdateQueryHasFlag(const UpdateAllQuerySpec *spec, UpdateQueryFlags flag)
{
	return (spec->queryFlags & flag) != 0;
}


/* The caller owns the SPI frame and the lifetime of request values. */
UpdateAllMatchingDocsResult PerformUpdateAll(const UpdateAllQuerySpec *spec);

#endif
