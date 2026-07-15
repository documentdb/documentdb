/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/planner/bson_index_force_pushdown_types.h
 *
 * Types for index force pushdown
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_INDEX_FORCE_PUSHDOWN_TYPES_H
#define BSON_INDEX_FORCE_PUSHDOWN_TYPES_H

#include <postgres.h>
#include <nodes/pathnodes.h>

/* The operation type for forcing index pushdown */
typedef enum ForceIndexOpType
{
	/* No index pushdown required */
	ForceIndexOpType_None = 0,

	/* Index pushdown required due to $text */
	ForceIndexOpType_Text = 1,

	/* Index pushdown required due to $geoNear */
	ForceIndexOpType_GeoNear = 2,

	/* Index pushdown required for a vectorSearch */
	ForceIndexOpType_VectorSearch = 3,

	/* Index pushdown required for a index hint */
	ForceIndexOpType_IndexHint = 4,

	/* Index pushdown required for a primary key lookup */
	ForceIndexOpType_PrimaryKeyLookup = 5,

	/* Index pushdown required for an extended index */
	ForceIndexOpType_ExtendedIndex = 6,

	ForceIndexOpType_Max,
} ForceIndexOpType;

/*
 * Data used to enforce index to special query operators like $geoNear, $text etc
 */
typedef struct ForceIndexQueryOperatorData
{
	/* Type of the mongo query operator used */
	ForceIndexOpType type;

	/*
	 * If pushed to index by default by Postgres, then the it points to the index path otherwise NULL
	 * In case this is NULL, we try to push to the available index
	 */
	IndexPath *path;

	/*
	 * Any operator specific metadata or state.
	 * e.g. For $geoNear, it is the operatorExpression which is used for deciding the index pushdown
	 */
	void *opExtraState;
} ForceIndexQueryOperatorData;

#endif
