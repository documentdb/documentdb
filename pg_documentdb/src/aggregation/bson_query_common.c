/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/aggregation/bson_query_common.c
 *
 * Implementation of the common BSON query utility.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>

#include "io/bson_core.h"
#include "aggregation/bson_query_common.h"


DollarRangeParams *
ParseQueryDollarRange(pgbsonelement *filterElement)
{
	DollarRangeParams *rangeParams = palloc0(sizeof(DollarRangeParams));
	InitializeQueryDollarRange(&filterElement->bsonValue, rangeParams);
	return rangeParams;
}


void
InitializeQueryDollarRange(const bson_value_t *filterValue,
						   DollarRangeParams *rangeParams)
{
	bson_iter_t rangeIter;
	BsonValueInitIterator(filterValue, &rangeIter);
	while (bson_iter_next(&rangeIter))
	{
		const char *key = bson_iter_key(&rangeIter);
		if (strcmp(key, "min") == 0)
		{
			rangeParams->minValue = *bson_iter_value(&rangeIter);
		}
		else if (strcmp(key, "max") == 0)
		{
			rangeParams->maxValue = *bson_iter_value(&rangeIter);
		}
		else if (strcmp(key, "minInclusive") == 0)
		{
			rangeParams->isMinInclusive = bson_iter_bool(&rangeIter);
		}
		else if (strcmp(key, "maxInclusive") == 0)
		{
			rangeParams->isMaxInclusive = bson_iter_bool(&rangeIter);
		}
		else if (strcmp(key, "fullScan") == 0)
		{
			rangeParams->isFullScan = true;
		}
		else if (strcmp(key, "orderByScan") == 0)
		{
			rangeParams->isFullScan = true;
			rangeParams->orderScanDirection = BsonValueAsInt32(bson_iter_value(
																   &rangeIter));
		}
		else if (strcmp(key, "elemMatchIndexOp") == 0)
		{
			rangeParams->isElemMatch = true;
			rangeParams->elemMatchValue = *bson_iter_value(&rangeIter);
		}
		else
		{
			ereport(ERROR, (errmsg("Range predicate not supported: %s", key),
							errdetail_log(
								"Range predicate not supported: %s", key)));
		}
	}

	if (rangeParams->isFullScan)
	{
		/* If full scan is requested, we ignore min and max values */
		rangeParams->minValue.value_type = BSON_TYPE_MINKEY;
		rangeParams->maxValue.value_type = BSON_TYPE_MAXKEY;
		rangeParams->isMinInclusive = true;
		rangeParams->isMaxInclusive = true;
	}
}


/*
 * Given a BSON_TYPE_DOCUMENT value, checks if it contains exactly one field
 * whose value is a "$path" expression (not a "$$variable").
 * On success, populates *element with the single field element.
 */
bool
TryGetSingleFieldPathFromBsonValue(const bson_value_t *value,
								   pgbsonelement *element)
{
	if (value->value_type != BSON_TYPE_DOCUMENT)
	{
		return false;
	}

	bson_iter_t iter;
	BsonValueInitIterator(value, &iter);

	if (TryGetSinglePgbsonElementFromBsonIterator(&iter, element) &&
		element->bsonValue.value_type == BSON_TYPE_UTF8 &&
		element->bsonValue.value.v_utf8.len > 1 &&
		element->bsonValue.value.v_utf8.str[0] == '$' &&
		element->bsonValue.value.v_utf8.str[1] != '$')
	{
		return true;
	}

	return false;
}
