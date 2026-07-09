/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/bson/bson_query_common.h
 *
 * Private and common declarations of functions for handling bson query
 * Shared across runtime and index implementations.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_QUERY_COMMON_H
#define BSON_QUERY_COMMON_H

#include "io/bson_core.h"
#include "utils/documentdb_errors.h"

/*
 * This struct defines the parameters for a range query.
 */
typedef struct DollarRangeParams
{
	bson_value_t minValue;
	bson_value_t maxValue;
	bool isMinInclusive;
	bool isMaxInclusive;

	bool isFullScan;
	int32_t orderScanDirection;

	bool isElemMatch;
	bson_value_t elemMatchValue;

	bool isMinIndexKey;
	bool isMaxIndexKey;
	bson_value_t minOrMaxIndexKey;

	/* Reservoir sampling: when true, the range signals the planner to wrap
	 * scan paths with a reservoir sampling CustomScan. */
	bool isSample;
	int64_t sampleSize;

	/* Internal $in-prefix merge-sort marker. It must be stripped before
	 * execution, so the index-bounds and runtime paths throw if it is ever
	 * seen. */
	bool isMergeSortInPrefixMarker;
} DollarRangeParams;

DollarRangeParams * ParseQueryDollarRange(pgbsonelement *filterElement);

bool IsBsonRangeArgsForFullScan(List *args);
bool IsBsonRangeArgsForFullScanOrElemMatch(List *args);
bool TryGetRangeParamsForRangeArgs(List *args, DollarRangeParams *params);
bool IsBsonRangeArgsForReservoirSample(List *args);
void InitializeQueryDollarRange(const bson_value_t *rangeValue,
								DollarRangeParams *params);

void ElemMatchIndexOpStrategyClassify(DollarRangeParams *params,
									  int32_t *queryStrategy,
									  bool *equalityPrefixes,
									  bool *nonEqualityPrefixes);

bool TryGetSingleFieldPathFromBsonValue(const bson_value_t *value,
										pgbsonelement *element);

#endif
