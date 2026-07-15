/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/utils/search_utils.h
 *
 * Utilities to execute a search.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>

#ifndef SEARCH_UTILS_H
#define SEARCH_UTILS_H


/*
 * Modified binary search where on mismatch returns the position.
 * returns index if item is found;
 * otherwise, a negative number that is the bitwise complement of the index of the next element that is larger than item or,
 * if there is no larger element, the bitwise complement of length.
 * See https://github.com/dotnet/runtime/blob/4fa917e666f88701785d0ed5e801fded279ee2a8/src/libraries/System.Private.CoreLib/src/System/Array.cs#L1254-L1279
 */
static int32
BinarySearchWithMissingPositionCheck(void *pointer, int startIndex, int length,
									 int elemSize, const void *toFind,
									 int (*compar)(const void *, const void *, void *),
									 void *arg)
{
	const char *base = (const char *) pointer;
	int lo = startIndex;
	int hi = length - 1;
	while (lo <= hi)
	{
		int i = lo + ((hi - lo) >> 1);

		const char *p = base + (i * elemSize);
		int c = compar(p, toFind, arg);
		if (c == 0)
		{
			return i;
		}
		if (c < 0)
		{
			lo = i + 1;
		}
		else
		{
			hi = i - 1;
		}
	}

	return ~lo;
}


#endif
