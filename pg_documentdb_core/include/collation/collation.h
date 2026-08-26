/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/collation/collation.h
 *
 * Common declarations of functions for handling collation.
 *
 *-------------------------------------------------------------------------
 */

#ifndef CORE_COLLATION_H
#define CORE_COLLATION_H

#include "io/bson_core.h"

/* This value is calulated assuming all parameters in collation document is specified
 * and each of them are set to the longest possible character values*/
#define MAX_ICU_COLLATION_LENGTH 110

/* Stack scratch capacity for a sort key, and for the UTF-16 conversion that feeds it;
 * larger inputs fall back to a palloc'd buffer. */
#define COLLATION_SORT_KEY_SCRATCH_BYTES 512

extern bool EnableCollation;

void ParseAndGetCollationString(const bson_value_t *collationValue,
								const char *collationString);
int32_t GetCollationSortKey(const char *collationString, const char *string,
							int32_t stringLength, uint8_t *scratch, int32_t
							scratchCapacity,
							uint8_t **sortKey);

int StringCompareWithCollation(const char *left, uint32_t leftLength,
							   const char *right, uint32_t rightLength, const
							   char *collationStr);

static inline bool
IsCollationValid(const char *collationString)
{
	return collationString != NULL && strlen(collationString) > 2;
}


static inline bool
IsCollationApplicable(const char *collationString)
{
	return EnableCollation && IsCollationValid(collationString);
}


/*
 * True for bson types a collation can affect. Must stay in sync with the types
 * CompareBsonValue collates; documents and arrays may contain such values.
 */
static inline bool
IsBsonTypeCollationAware(bson_type_t type)
{
	return type == BSON_TYPE_UTF8 || type == BSON_TYPE_DOCUMENT ||
		   type == BSON_TYPE_ARRAY || type == BSON_TYPE_SYMBOL;
}


static inline bool
IsSimpleCollation(const char *collationString)
{
	return strncmp(collationString, "simple", 6) == 0;
}


#endif
