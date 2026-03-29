/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/opclass/bson_gin_index_term_private.h
 *
 * Common declarations of the serialization of index terms.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_GIN_INDEX_TERM_PRIVATE_H
#define BSON_GIN_INDEX_TERM_PRIVATE_H

#include "opclass/bson_gin_index_term.h"

/*
 * While this looks like a flags enum, it started out that way
 * but it's not. Intermediate values are allowed. However, at
 * the point of conversion, the binaries using the first 2 bits were
 * not upgraded, so the code uses 0x04 and 0x08 until the next release.
 * Note that subsequent metadata values can use intermediate values.
 * IndexTermPartialUndefinedValue uses 2 flags that were not used earlier
 * and so is safe to use as a new value.
 * The descending metadata values are also treated as flags style. This is
 * primarily from a perf standpoint to say descending terms are those that
 * are `>= 0x80` but there's not a need for 1:1 mapping. We do retain the 1:1
 * mapping so that back-compat flag checks work.
 */
typedef enum IndexTermMetadata
{
	IndexTermNoMetadata = 0x00,

	IndexTermTruncated = 0x01,

	IndexTermIsMetadata = 0x02,

	IndexTermComposite = 0x04,

	IndexTermValueOnly = 0x05,

	IndexTermValueOnlyTruncated = 0x06,

	IndexTermComparableV1 = 0x07,

	IndexTermUndefinedValue = 0x08,

	IndexTermPartialUndefinedValue = 0x0C,

	IndexTermDescending = 0x80,

	IndexTermDescendingTruncated = 0x81,

	IndexTermValueOnlyDescending = 0x85,

	IndexTermValueOnlyDescendingTruncated = 0x86,

	IndexTermDescendingComparableV1 = 0x87,

	IndexTermDescendingUndefinedValue = 0x88,

	IndexTermDescendingPartialUndefinedValue = 0x8C,

	/* This is used by bsonindexterm to indicate it has
	 * collation prefixed data. This is not used for data
	 * storage in the index.
	 */
	IndexTermMetadataCollationPrefixed = 0xFF,
} IndexTermMetadata;

bytea * WriteComparableIndexTermToWriter(pgbson_writer *writer, IndexTermMetadata
										 termMetadata);
void ComparableBufferToBsonIndexTerm(const uint8_t *buffer, uint32_t indexTermSize,
									 BsonIndexTerm *bsonIndexTerm);

#endif
