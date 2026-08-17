/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/utils/hashset_utils.c
 *
 * Utilities for HTAB objects.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <utils/hsearch.h>

#include "io/bson_core.h"
#include "query/bson_compare.h"
#include "utils/hashset_utils.h"
#include "collation/collation.h"
#include "io/bson_hash.h"

/*
 * Callbacks used to deal with bson element keys within a hash table.
 */
static uint32 PgbsonElementHashEntryHashFunc(const void *obj, size_t objsize);
static int PgbsonElementHashEntryCompareFunc(const void *obj1, const void *obj2,
											 Size objsize);
static uint32 StringViewHashEntryHashFunc(const void *obj, size_t objsize);
static int StringViewHashEntryCompareFunc(const void *obj1, const void *obj2,
										  Size objsize);
static uint32 BsonValueHashFunc(const void *obj, size_t objsize);
static int BsonValueHashEntryCompareFunc(const void *obj1, const void *obj2, Size
										 objsize);
static void BsonValueHashFuncCore(const bson_value_t *bsonValue, const
								  char *collationString, uint32_t *hashValue);
static uint32 PgbsonElementOrderedHashEntryFunc(const void *obj, size_t objsize);
static int PgbsonElementOrderedHashCompareFunc(const void *obj1, const void *obj2, Size
											   objsize);

/*
 * Creates a hash table that stores pgbsonelement entries using
 * a hash and search based on the element path.
 */
HTAB *
CreatePgbsonElementHashSet(void)
{
	HASHCTL hashInfo = CreateExtensionHashCTL(
		sizeof(PgbsonElementHashEntry),
		sizeof(PgbsonElementHashEntry),
		PgbsonElementHashEntryCompareFunc,
		PgbsonElementHashEntryHashFunc
		);
	HTAB *bsonElementHashSet =
		hash_create("Bson Element Hash Table", 32, &hashInfo, DefaultExtensionHashFlags);

	return bsonElementHashSet;
}


/*
 * PgbsonElementHashEntryHashFunc is the (HASHCTL.hash) callback (based on
 * string_hash()) used to hash a PgbsonElementHashEntry object based on key
 * of the bson element that it holds.
 */
static uint32
PgbsonElementHashEntryHashFunc(const void *obj, size_t objsize)
{
	const PgbsonElementHashEntry *hashEntry = obj;
	return hash_bytes((const unsigned char *) hashEntry->element.path,
					  (int) hashEntry->element.pathLength);
}


/*
 * PgbsonElementHashEntryCompareFunc is the (HASHCTL.match) callback (based
 * on string_compare()) used to determine if keys of the bson elements hold
 * by given two PgbsonElementHashEntry objects are the same.
 *
 * Returns 0 if those two bson element keys are same, +ve Int if first is greater otherwise -ve Int.
 */
static int
PgbsonElementHashEntryCompareFunc(const void *obj1, const void *obj2, Size objsize)
{
	const PgbsonElementHashEntry *hashEntry1 = obj1;
	const PgbsonElementHashEntry *hashEntry2 = obj2;

	int minLength = Min(hashEntry1->element.pathLength, hashEntry2->element.pathLength);
	int result = strncmp(hashEntry1->element.path, hashEntry2->element.path, minLength);

	if (result == 0)
	{
		return hashEntry1->element.pathLength - hashEntry2->element.pathLength;
	}
	return result;
}


/*
 * Creates a hash map that maps StringView to arbitrary data using a hash and search based on the StringView.
 * StringView is required to be the first field of the entry.
 */
HTAB *
CreateStringViewHashMap(Size entrySize)
{
	Assert(entrySize >= sizeof(StringView));
	HASHCTL hashInfo = CreateExtensionHashCTL(
		sizeof(StringView),
		entrySize,
		StringViewHashEntryCompareFunc,
		StringViewHashEntryHashFunc
		);
	return hash_create("StringView Hash Value", 32, &hashInfo, DefaultExtensionHashFlags);
}


/*
 * Creates a hash table that stores StringView using
 * a hash and search based on the StringView.
 */
HTAB *
CreateStringViewHashSet(void)
{
	return CreateStringViewHashMap(sizeof(StringView));
}


/*
 * StringViewHashEntryHashFunc is the (HASHCTL.hash) callback used to hash a StringView
 */
static uint32
StringViewHashEntryHashFunc(const void *obj, size_t objsize)
{
	const StringView *hashEntry = obj;
	return hash_bytes((const unsigned char *) hashEntry->string, hashEntry->length);
}


/*
 * StringViewHashEntryCompareFunc is the (HASHCTL.match) callback used to determine if two StringView are same.
 * Returns 0 if those two StringView are same, 1 otherwise.
 */
static int
StringViewHashEntryCompareFunc(const void *obj1, const void *obj2, Size objsize)
{
	const StringView *hashEntry1 = obj1;
	const StringView *hashEntry2 = obj2;

	return CompareStringView(hashEntry1, hashEntry2);
}


/*
 * Creates a hash table that stores bson_value_t entries using
 * a hash and search based on the bson_value_t.
 */
HTAB *
CreateBsonValueHashSet(void)
{
	HASHCTL hashInfo = CreateExtensionHashCTL(
		sizeof(bson_value_t),
		sizeof(bson_value_t),
		BsonValueHashEntryCompareFunc,
		BsonValueHashFunc);
	static const int numElements = 32;
	HTAB *bsonValueHashSet =
		hash_create("Bson Value Hash Table", numElements, &hashInfo,
					DefaultExtensionHashFlags);

	return bsonValueHashSet;
}


static uint32
BsonValueHashFunc(const void *obj, size_t objsize)
{
	uint32_t hashValue = 0;
	const char *collationString = NULL;
	BsonValueHashFuncCore((const bson_value_t *) obj, collationString, &hashValue);
	return hashValue;
}


static int
BsonValueHashEntryCompareFunc(const void *obj1, const void *obj2, Size objsize)
{
	bool isComparisonValidIgnore;
	return CompareBsonValueAndType((const bson_value_t *) obj1,
								   (const bson_value_t *) obj2,
								   &isComparisonValidIgnore);
}


/*
 * BsonValueWithCollationHashFunc is the (HASHCTL.hash) callback
 * used to hash a BsonValueHashEntry object based on bson value
 * of the BsonValueHashEntry that it holds and the sort key of the collation.
 */
static uint32_t
BsonValueWithCollationHashFunc(const void *obj, size_t objsize)
{
	const BsonValueHashEntry *hashEntry = obj;
	const bson_value_t bsonValue = hashEntry->bsonValue;
	const char *collationString = hashEntry->collationString;

	uint32_t hashValue = 0;
	BsonValueHashFuncCore(&bsonValue, collationString, &hashValue);
	return hashValue;
}


/*
 * BsonValueWithCollationHashEntryCompareFunc is the (HASHCTL.match) callback (based
 * on BsonValueEquals()) used to determine if two bson values are same with respect to
 * a provided collation, if applicable.
 *
 * Returns 0 if those two bson values are same, 1 otherwise.
 */
static int
BsonValueWithCollationHashEntryCompareFunc(const void *obj1, const void *obj2,
										   Size objsize)
{
	const BsonValueHashEntry *hashEntry1 = obj1;
	const BsonValueHashEntry *hashEntry2 = obj2;

	bool isComparisonValidIgnore;
	bool cmp = CompareBsonValueAndTypeWithCollation(&hashEntry1->bsonValue,
													&hashEntry2->bsonValue,
													&isComparisonValidIgnore,
													hashEntry1->collationString);
	return cmp ? 1 : 0;
}


/*
 * Creates a hash table that stores bson value entries using
 * collation-aware hash values.
 *
 * extraDataSize is the total size of all other fields that will be stored
 * in the hash entry in addition to the bson value and collation string.
 * See SetOperatorBsonValueHashEntry in bson_expression_set_operators.c for an example.
 */
HTAB *
CreateBsonValueWithCollationHashSet(int extraDataSize)
{
	HASHCTL hashInfo = CreateExtensionHashCTL(
		sizeof(BsonValueHashEntry) + extraDataSize,
		sizeof(BsonValueHashEntry) + extraDataSize,
		BsonValueWithCollationHashEntryCompareFunc,
		BsonValueWithCollationHashFunc);

	HTAB *bsonElementHashSet =
		hash_create("Bson Value Hash Table", 32, &hashInfo, DefaultExtensionHashFlags);

	return bsonElementHashSet;
}


/*
 * Creates a hash table that stores pgbsonelement entries using
 * a hash and search based on the element path.
 */
HTAB *
CreatePgbsonElementOrderedHashSet(void)
{
	HASHCTL hashInfo = CreateExtensionHashCTL(
		sizeof(PgbsonElementHashEntryOrdered),
		sizeof(PgbsonElementHashEntryOrdered),
		PgbsonElementOrderedHashCompareFunc,
		PgbsonElementOrderedHashEntryFunc
		);
	HTAB *bsonElementHashSet =
		hash_create("Ordered Bson Element Hash Table", 32, &hashInfo,
					DefaultExtensionHashFlags);

	return bsonElementHashSet;
}


/*
 * PgbsonElementOrderedHashEntryFunc is the (HASHCTL.hash) callback (based on
 * string_hash()) used to hash a PgbsonElementHashEntryOrdered object based on key
 * of the bson element that it holds.
 */
static uint32
PgbsonElementOrderedHashEntryFunc(const void *obj, size_t objsize)
{
	const PgbsonElementHashEntryOrdered *hashEntry = obj;
	return hash_bytes((const unsigned char *) hashEntry->element.path,
					  (int) hashEntry->element.pathLength);
}


/*
 * PgbsonElementOrderedHashCompareFunc is the (HASHCTL.match) callback (based
 * on string_compare()) used to determine if keys of the bson elements hold
 * by given two PgbsonElementHashEntryOrdered objects are the same.
 *
 * Returns 0 if those two bson element keys are same, +ve Int if first is greater otherwise -ve Int.
 */
static int
PgbsonElementOrderedHashCompareFunc(const void *obj1, const void *obj2, Size objsize)
{
	const PgbsonElementHashEntryOrdered *hashEntry1 = obj1;
	const PgbsonElementHashEntryOrdered *hashEntry2 = obj2;

	int minPathLength = Min(hashEntry1->element.pathLength,
							hashEntry2->element.pathLength);
	int result = strncmp(hashEntry1->element.path, hashEntry2->element.path,
						 minPathLength);

	if (result == 0)
	{
		return hashEntry1->element.pathLength - hashEntry2->element.pathLength;
	}

	return result;
}


/*
 * Hashes a string under a non-simple collation by hashing its ICU sort key.
 * pg_noinline keeps the scratch out of the recursive caller's stack frame.
 */
static pg_noinline uint32_t
HashStringWithCollation(const char *collationString, const char *string,
						uint32_t stringLength)
{
	uint8_t sortKeyScratch[COLLATION_SORT_KEY_SCRATCH_BYTES];
	uint8_t *sortKey;
	int32_t sortKeyLength = GetCollationSortKey(collationString, string, stringLength,
												sortKeyScratch, sizeof(sortKeyScratch),
												&sortKey);

	uint32_t hashValue = hash_bytes(sortKey, sortKeyLength);
	if (sortKey != sortKeyScratch)
	{
		pfree(sortKey);
	}
	return hashValue;
}


/*
 * Hashes a bson value for use in hash set.
 *
 * (1) No collation to apply, either because none was given, collation is disabled, the
 *     locale is the binary "simple" one, or the type is not collation aware: hash the
 *     bson value directly.
 * (2) string-family bson value: hash its collation sort key.
 * (3) arrays and documents: recurse into them, applying (1), (2), (3) to each entry.
 *
 * The final hash value is the sum of all the hash values.
 */
static void
BsonValueHashFuncCore(const bson_value_t *bsonValue, const
					  char *collationString, uint32_t *hashValue)
{
	check_stack_depth();

	/*
	 * (1) No collation, the binary "simple" locale, or a type that collation does not
	 * apply to: hash the bson value directly.
	 */
	if (!IsCollationApplicable(collationString) ||
		IsSimpleCollation(collationString) ||
		!IsBsonTypeCollationAware(bsonValue->value_type))
	{
		*hashValue += BsonValueHashUint32(bsonValue);
		return;
	}

	/* (2) string-family bson value, create collation sort key and hash that */
	switch (bsonValue->value_type)
	{
		case BSON_TYPE_UTF8:
		{
			*hashValue += HashStringWithCollation(collationString,
												  bsonValue->value.v_utf8.str,
												  bsonValue->value.v_utf8.len);
			return;
		}

		case BSON_TYPE_SYMBOL:
		{
			*hashValue += HashStringWithCollation(collationString,
												  bsonValue->value.v_symbol.symbol,
												  bsonValue->value.v_symbol.len);
			return;
		}

		default:
		{
			/* documents and arrays fall through to the recursive case */
			break;
		}
	}

	/* recursive case: arrays and documents */
	/* process each element and recurse into array and document values */
	bson_iter_t arrayValueIterator;
	bson_iter_init_from_data(&arrayValueIterator,
							 bsonValue->value.v_doc.data,
							 bsonValue->value.v_doc.data_len);

	while (bson_iter_next(&arrayValueIterator))
	{
		CHECK_FOR_INTERRUPTS();

		const bson_value_t *value = bson_iter_value(&arrayValueIterator);
		BsonValueHashFuncCore(value, collationString, hashValue);
	}
}
