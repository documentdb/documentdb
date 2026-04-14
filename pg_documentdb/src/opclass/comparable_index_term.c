/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/opclass/comparable_index_term.c
 *
 * Serialization and storage of index terms in the GIN/RUM index.
 *
 *-------------------------------------------------------------------------
 */


#include <postgres.h>
#include <math.h>
#include <port/pg_bswap.h>

#include "opclass/bson_gin_index_term_private.h"
#include "collation/collation.h"


#define MAX_FULL_FIDELITY_INT64 ((int64_t) 1 << 52)

#define UINT64_MSB (0x8000000000000000ull)


/* Serialized type code that preserves ordering characteristics
 * (BSON_TYPE does not preserve ordering.)
 * Types registered here can participate in memcmp based comparisons in
 * the index/ordering. The value of these codes are persisted and should not
 * be changed. There are gaps placed in the null and undefined range to allow
 * for additions of cases that may be missed here.
 * The number range also has gaps to support future additions when doubles
 * can participate. Note that when adding doubles the top level comparable
 * type code must rev as well (ComparableV1 cannot support doubles).
 */
typedef enum IndexTermComparableTypeCode
{
	SORT_TYPE_EOF = 0,

	SORT_TYPE_MINKEY = 1,

	SORT_TYPE_UNDEFINED_VALUE = 5,

	SORT_TYPE_MAYBE_UNDEFINED_VALUE = 8,

	SORT_TYPE_LITERAL_NULL = 11,

	SORT_TYPE_NUMBER_DOUBLE = 20,

	SORT_TYPE_UTF8 = 30,

	SORT_TYPE_DOCUMENT = 31,

	SORT_TYPE_ARRAY = 32,

	SORT_TYPE_BINARY = 33,

	SORT_TYPE_OID = 34,

	SORT_TYPE_BOOL_FALSE = 35,

	SORT_TYPE_BOOL_TRUE = 36,

	SORT_TYPE_DATE_TIME = 37,

	SORT_TYPE_TIMESTAMP = 38,

	SORT_TYPE_REGEX = 39,

	SORT_TYPE_DBPOINTER = 40,

	SORT_TYPE_CODE = 41,

	SORT_TYPE_CODE_W_SCOPE = 42,

	SORT_TYPE_MAXKEY = 255,
} IndexTermComparableTypeCode;


static double
DecodeSortableDouble(const uint8_t *p)
{
	uint64 val;
	uint64 c;

	/* 0th byte */
	c = *(p++);
	val = (c & 0xFF) << 56;

	/* varbyte: 1st byte */
	c = *(p++);
	val |= (c & 0xFE) << 48;
	if (c & 0x01)
	{
		/* 2nd byte */
		c = *(p++);
		val |= (c & 0xFE) << 41;
		if (c & 0x01)
		{
			/* 3rd byte */
			c = *(p++);
			val |= (c & 0xFE) << 34;
			if (c & 0x01)
			{
				/* 4th byte */
				c = *(p++);
				val |= (c & 0xFE) << 27;
				if (c & 0x01)
				{
					/* 5th byte */
					c = *(p++);
					val |= (c & 0xFE) << 20;
					if (c & 0x01)
					{
						/* 6th byte */
						c = *(p++);
						val |= (c & 0xFE) << 13;
						if (c & 0x01)
						{
							/* 7th byte */
							c = *(p++);
							val |= (c & 0xFE) << 6;
							if (c & 0x01)
							{
								/* 8th byte */
								c = *(p++);
								val |= (c & 0xFE) >> 1;
							}
						}
					}
				}
			}
		}
	}

	val = (val < UINT64_MSB) ? ~(val - 1) : val ^ UINT64_MSB;
	double result = *(double *) &val;
	return result;
}


static bytea *
EncodeSortableDouble(IndexTermMetadata writtenMetadata, double value)
{
	bytea *buffer = palloc0(VARHDRSZ + 2 + sizeof(double) + 2);
	uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
	dataBuffer[0] = writtenMetadata;
	dataBuffer[1] = SORT_TYPE_NUMBER_DOUBLE;
	uint8_t *p = &dataBuffer[2];
	uint64_t val = *(uint64_t *) &value;

	/* Flip the sign bit so that negative values are smaller than positive values */
	val = (val < UINT64_MSB) ? val ^ UINT64_MSB : (~val) + 1;

	/* We know the first byte is required - so just write that one as-is */
	*(p++) = (((val >> 56) & 0xFF));
	val <<= 8;

	/* Write continuation bytes. Use do-while to always emit at least one
	 * continuation byte so the decoder has a valid termination marker.
	 * Without this, values like 2.0 (lower 56 bits all zero) produce a
	 * single byte, causing DecodeSortableDouble to read past the buffer. */
	do {
		*(p++) = (((val >> 56) & 0xFF)) | 0x01;
		val <<= 7;
	} while (val > 0);

	/* Clear the continuation bit on the last byte to signal termination */
	*(p - 1) &= 0xFE;
	Size lengthUsed = p - &dataBuffer[2];

	SET_VARSIZE(buffer, VARHDRSZ + 2 + lengthUsed);
	return buffer;
}


static int64_t
DecodeSortableInt64(const uint8_t *buffer)
{
	uint64_t result;
	memcpy(&result, buffer, sizeof(uint64_t));

	/* Undo the sign bit flip applied during encoding */
	return (int64_t) (pg_bswap64(result) ^ UINT64_MSB);
}


static void
EncodeSortableInt64(uint8_t *buffer, int64_t value)
{
	/* Flip the sign bit so that negative values sort before positive values
	 * in unsigned (memcmp) comparison. Without this, negative values have
	 * the MSB set and would sort after all positive values. */
	uint64_t uval = (uint64_t) value ^ UINT64_MSB;
	uint64_t swappedValue = pg_bswap64(uval);
	memcpy(buffer, &swappedValue, sizeof(uint64_t));
}


static uint32_t
DecodeSortableUint32(const uint8_t *buffer)
{
	uint32_t result;
	uint8_t *resultBuffer = (uint8_t *) &result;
	memcpy(resultBuffer, buffer, sizeof(uint32_t));
	return pg_bswap32(result);
}


static void
EncodeSortableUint32(uint8_t *buffer, uint32_t value)
{
	/* Ensure we write it out in big endian */
	value = pg_bswap32(value);
	uint8_t *valueBuffer = (uint8_t *) &value;
	memcpy(buffer, valueBuffer, sizeof(uint32_t));
}


bytea *
WriteComparableIndexTermToWriter(const IndexTermCreateMetadata *createMetadata,
								 pgbson_writer *writer, IndexTermMetadata termMetadata)
{
	IndexTermMetadata writtenMetadata;
	switch (termMetadata)
	{
		case IndexTermValueOnly:
		case IndexTermUndefinedValue:
		case IndexTermPartialUndefinedValue:
		{
			writtenMetadata = IndexTermComparableV1;
			break;
		}

		case IndexTermDescendingPartialUndefinedValue:
		case IndexTermValueOnlyDescending:
		case IndexTermDescendingUndefinedValue:
		{
			writtenMetadata = IndexTermDescendingComparableV1;
			break;
		}

		default:
		{
			return NULL;
		}
	}

	bson_value_t docValue = PgbsonWriterGetValue(writer);

	pgbsonelement currentElement;
	BsonValueToPgbsonElement(&docValue, &currentElement);

	bson_value_t currentValue = currentElement.bsonValue;
	switch (currentValue.value_type)
	{
		case BSON_TYPE_MINKEY:
		{
			/* requires 2 bytes - 1 for term metadata, and 1 for type code */
			bytea *buffer = palloc(VARHDRSZ + 2);
			SET_VARSIZE(buffer, VARHDRSZ + 2);
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = SORT_TYPE_MINKEY;
			return buffer;
		}

		case BSON_TYPE_MAXKEY:
		{
			/* requires 2 bytes - 1 for term metadata, and 1 for type code */
			bytea *buffer = palloc(VARHDRSZ + 2);
			SET_VARSIZE(buffer, VARHDRSZ + 2);
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = SORT_TYPE_MAXKEY;
			return buffer;
		}

		case BSON_TYPE_UNDEFINED:
		{
			bytea *buffer = palloc(VARHDRSZ + 2);
			SET_VARSIZE(buffer, VARHDRSZ + 2);
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;

			switch (termMetadata)
			{
				case IndexTermUndefinedValue:
				case IndexTermDescendingUndefinedValue:
				{
					dataBuffer[1] = SORT_TYPE_UNDEFINED_VALUE;
					break;
				}

				case IndexTermPartialUndefinedValue:
				case IndexTermDescendingPartialUndefinedValue:
				{
					dataBuffer[1] = SORT_TYPE_MAYBE_UNDEFINED_VALUE;
					break;
				}

				default:
				case IndexTermValueOnly:
				case IndexTermValueOnlyDescending:
				{
					dataBuffer[1] = SORT_TYPE_LITERAL_NULL;
					break;
				}
			}

			return buffer;
		}

		case BSON_TYPE_NULL:
		{
			bytea *buffer = palloc(VARHDRSZ + 2);
			SET_VARSIZE(buffer, VARHDRSZ + 2);
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = SORT_TYPE_LITERAL_NULL;
			return buffer;
		}

		case BSON_TYPE_UTF8:
		case BSON_TYPE_SYMBOL:
		{
			if (IsCollationValid(createMetadata->collation))
			{
				/* Exclude strings from memcmp terms if collation is valid */
				return NULL;
			}

			/* metadata code, sort code, string and the trailing \0 */
			Size requiredSize = VARHDRSZ + 2 + currentValue.value.v_utf8.len + 1;
			bytea *buffer = palloc(requiredSize);
			SET_VARSIZE(buffer, requiredSize);
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = SORT_TYPE_UTF8;

			memcpy(&dataBuffer[2], currentValue.value.v_utf8.str,
				   currentValue.value.v_utf8.len);
			dataBuffer[2 + currentValue.value.v_utf8.len] = '\0';
			return buffer;
		}

		case BSON_TYPE_BOOL:
		{
			bytea *buffer = palloc(VARHDRSZ + 2);
			SET_VARSIZE(buffer, VARHDRSZ + 2);
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = currentValue.value.v_bool ? SORT_TYPE_BOOL_TRUE :
							SORT_TYPE_BOOL_FALSE;
			return buffer;
		}

		case BSON_TYPE_OID:
		{
			/* OID is simply memcomparable, so just copy it out. */
			bytea *buffer = palloc(VARHDRSZ + 2 + sizeof(bson_oid_t));
			SET_VARSIZE(buffer, VARHDRSZ + 2 + sizeof(bson_oid_t));
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = SORT_TYPE_OID;
			memcpy(&dataBuffer[2], currentValue.value.v_oid.bytes, sizeof(bson_oid_t));
			return buffer;
		}

		case BSON_TYPE_DATE_TIME:
		{
			/* DATETIME is milliseconds since epoch. as of 2026, this is
			 * 1,700,000,000,000 which is much bigger than INT32 already.
			 * We can simply store it as int64 in big endian order.
			 * We can try to optimize this with more recent epochs if needed
			 * but that can be a future optimization.
			 */
			bytea *buffer = palloc(VARHDRSZ + 2 + sizeof(uint64));
			SET_VARSIZE(buffer, VARHDRSZ + 2 + sizeof(uint64));
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = SORT_TYPE_DATE_TIME;
			EncodeSortableInt64(&dataBuffer[2], currentValue.value.v_datetime);
			return buffer;
		}

		case BSON_TYPE_TIMESTAMP:
		{
			/*
			 * Timestamps are first compared on the timestamp and then the offset increment.
			 * Simply store them as two uint32s in big endian order. This allows us to maintain the sort order
			 * We could var encode these if needed, but that is left as a future optimization.
			 */
			bytea *buffer = palloc(VARHDRSZ + 2 + sizeof(uint32_t) + sizeof(uint32_t));
			SET_VARSIZE(buffer, VARHDRSZ + 2 + sizeof(uint32_t) + sizeof(uint32_t));
			uint8_t *dataBuffer = (uint8_t *) VARDATA(buffer);
			dataBuffer[0] = writtenMetadata;
			dataBuffer[1] = SORT_TYPE_TIMESTAMP;
			EncodeSortableUint32(&dataBuffer[2],
								 currentValue.value.v_timestamp.timestamp);
			EncodeSortableUint32(&dataBuffer[6],
								 currentValue.value.v_timestamp.increment);
			return buffer;
		}

		case BSON_TYPE_INT32:
		{
			double value = (double) currentValue.value.v_int32;
			return EncodeSortableDouble(writtenMetadata, value);
		}

		case BSON_TYPE_DOUBLE:
		{
			double value = currentValue.value.v_double;
			if (isnan(value))
			{
				/* NaNs make memcmp range checks hard - so just make it ineligible for comparable terms. */
				return NULL;
			}

			return EncodeSortableDouble(writtenMetadata, value);
		}

		case BSON_TYPE_INT64:
		{
			int64_t intValue = currentValue.value.v_int64;
			if (intValue >= MAX_FULL_FIDELITY_INT64 ||
				intValue <= -MAX_FULL_FIDELITY_INT64)
			{
				return NULL;
			}

			double value = (double) intValue;
			return EncodeSortableDouble(writtenMetadata, value);
		}

		case BSON_TYPE_BINARY:
		case BSON_TYPE_DOCUMENT:
		case BSON_TYPE_ARRAY:
		case BSON_TYPE_REGEX:
		case BSON_TYPE_DBPOINTER:
		case BSON_TYPE_CODE:
		case BSON_TYPE_CODEWSCOPE:
		case BSON_TYPE_DECIMAL128:
		{
			return NULL;
		}

		case BSON_TYPE_EOD:
		default:
		{
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("invalid bson type - not supported yet")));
		}
	}
}


bool
IsComparableIndexTermValueUndefined(const uint8_t *buffer, uint32_t indexTermSize)
{
	return buffer[0] == SORT_TYPE_UNDEFINED_VALUE;
}


void
ComparableBufferToBsonIndexTerm(const uint8_t *buffer, uint32_t indexTermSize,
								BsonIndexTerm *bsonIndexTerm)
{
	bool isDescending = bsonIndexTerm->termMetadata >= IndexTermDescending;
	bsonIndexTerm->element.path = "$";
	bsonIndexTerm->element.pathLength = 1;
	bsonIndexTerm->termMetadata = isDescending ?
								  IndexTermValueOnlyDescending : IndexTermValueOnly;
	switch (buffer[0])
	{
		case SORT_TYPE_MINKEY:
		{
			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_MINKEY;
			return;
		}

		case SORT_TYPE_UNDEFINED_VALUE:
		{
			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_UNDEFINED;
			bsonIndexTerm->termMetadata =
				isDescending ? IndexTermDescendingUndefinedValue :
				IndexTermUndefinedValue;
			return;
		}

		case SORT_TYPE_MAYBE_UNDEFINED_VALUE:
		{
			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_UNDEFINED;
			bsonIndexTerm->termMetadata =
				isDescending ? IndexTermDescendingPartialUndefinedValue :
				IndexTermPartialUndefinedValue;
			return;
		}

		case SORT_TYPE_LITERAL_NULL:
		{
			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_NULL;
			return;
		}

		case SORT_TYPE_NUMBER_DOUBLE:
		{
			if (indexTermSize < 3)
			{
				ereport(ERROR, (errmsg(
									"Invalid comparable buffer for double value - size too small: %d",
									indexTermSize)));
			}

			double decodeDouble = DecodeSortableDouble(&buffer[1]);

			if (floor(decodeDouble) == decodeDouble)
			{
				/* Representable as an integer */
				if (decodeDouble >= INT32_MIN && decodeDouble <= INT32_MAX)
				{
					bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_INT32;
					bsonIndexTerm->element.bsonValue.value.v_int32 =
						(int32_t) decodeDouble;
					return;
				}
				else if (decodeDouble >= INT64_MIN && decodeDouble <= INT64_MAX)
				{
					bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_INT64;
					bsonIndexTerm->element.bsonValue.value.v_int64 =
						(int64_t) decodeDouble;
					return;
				}
			}

			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_DOUBLE;
			bsonIndexTerm->element.bsonValue.value.v_double = decodeDouble;
			return;
		}

		case SORT_TYPE_UTF8:
		{
			if (indexTermSize < 2)
			{
				ereport(ERROR, (errmsg(
									"Invalid comparable buffer for string value - size too small: %d",
									indexTermSize)));
			}

			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_UTF8;
			bsonIndexTerm->element.bsonValue.value.v_utf8.str = (char *) &buffer[1];

			/* Length includes the trailing \0 */
			bsonIndexTerm->element.bsonValue.value.v_utf8.len = indexTermSize - 2;
			return;
		}

		case SORT_TYPE_BOOL_FALSE:
		{
			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_BOOL;
			bsonIndexTerm->element.bsonValue.value.v_bool = false;
			return;
		}

		case SORT_TYPE_BOOL_TRUE:
		{
			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_BOOL;
			bsonIndexTerm->element.bsonValue.value.v_bool = true;
			return;
		}

		case SORT_TYPE_DATE_TIME:
		{
			if (indexTermSize < 9)
			{
				ereport(ERROR, (errmsg(
									"Invalid comparable buffer for date time value - size too small: %d",
									indexTermSize)));
			}

			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_DATE_TIME;
			bsonIndexTerm->element.bsonValue.value.v_datetime = DecodeSortableInt64(
				&buffer[1]);
			return;
		}

		case SORT_TYPE_MAXKEY:
		{
			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_MAXKEY;
			return;
		}

		case SORT_TYPE_OID:
		{
			if (indexTermSize < 13)
			{
				ereport(ERROR, (errmsg(
									"Invalid comparable buffer for OID value - size too small: %d",
									indexTermSize)));
			}

			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_OID;
			memcpy(bsonIndexTerm->element.bsonValue.value.v_oid.bytes, &buffer[1], 12);
			return;
		}

		case SORT_TYPE_TIMESTAMP:
		{
			if (indexTermSize < 9)
			{
				ereport(ERROR, (errmsg(
									"Invalid comparable buffer for timestamp value - size too small: %d",
									indexTermSize)));
			}

			bsonIndexTerm->element.bsonValue.value_type = BSON_TYPE_TIMESTAMP;
			bsonIndexTerm->element.bsonValue.value.v_timestamp.timestamp =
				DecodeSortableUint32(&buffer[1]);
			bsonIndexTerm->element.bsonValue.value.v_timestamp.increment =
				DecodeSortableUint32(&buffer[5]);
			return;
		}

		case SORT_TYPE_BINARY:
		case SORT_TYPE_DOCUMENT:
		case SORT_TYPE_ARRAY:
		case SORT_TYPE_REGEX:
		case SORT_TYPE_DBPOINTER:
		case SORT_TYPE_CODE:
		case SORT_TYPE_CODE_W_SCOPE:
		default:
		{
			ereport(ERROR, (errmsg("Unexpected complex type in comparable buffer: %d",
								   buffer[0])));
		}
	}
}
