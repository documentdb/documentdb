/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * src/io/bson_external_io.c
 *
 * Dictionary-free Zstandard compression and I/O for BSON external values.
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <fmgr.h>
#include <libpq/pqformat.h>
#include <utils/builtins.h>
#include <utils/memutils.h>
#include <zstd.h>

#include "io/bson_core.h"
#include "io/pgbson_external.h"

extern bool BsonTextUseJsonRepresentation;

/*
 * Stored payload flags:
 * 0: raw BSON bytes.
 * 1: a standard ZSTD frame.
 */
#define BSON_EXTERNAL_FLAG_UNCOMPRESSED 0
#define BSON_EXTERNAL_FLAG_ZSTD 1
#define BSON_EXTERNAL_FLAG_SIZE sizeof(uint8)

/* Bound decoded external values independently of command and query limits.
 * Corresponds to BSON_MAX_ALLOWED_SIZE_INTERMEDIATE.
 */
#define BSON_EXTERNAL_MAX_UNCOMPRESSED_SIZE (100 * 1024 * 1024)

static pgbson_external * CompressBsonExternal(const pgbson *bson);
static pgbson * DecompressBsonExternal(const pgbson_external *externalBson);

PG_FUNCTION_INFO_V1(bson_external_in);
PG_FUNCTION_INFO_V1(bson_external_out);
PG_FUNCTION_INFO_V1(bson_external_recv);
PG_FUNCTION_INFO_V1(bson_external_send);
PG_FUNCTION_INFO_V1(bson_to_bson_external);
PG_FUNCTION_INFO_V1(bson_external_to_bson);


Datum
bson_external_in(PG_FUNCTION_ARGS)
{
	char *arg = PG_GETARG_CSTRING(0);
	pgbson *bson = IsBsonHexadecimalString(arg) ?
				   PgbsonInitFromHexadecimalString(arg) : PgbsonInitFromJson(arg);
	pgbson_external *externalBson = CompressBsonExternal(bson);
	pfree(bson);
	PG_RETURN_POINTER(externalBson);
}


Datum
bson_external_out(PG_FUNCTION_ARGS)
{
	pgbson_external *externalBson = PG_GETARG_PGBSON_EXTERNAL_PACKED(0);
	pgbson *bson = DecompressBsonExternal(externalBson);
	const char *output = BsonTextUseJsonRepresentation ?
						 PgbsonToCanonicalExtendedJson(bson) :
						 PgbsonToHexadecimalString(bson);
	pfree(bson);
	PG_FREE_IF_COPY(externalBson, 0);
	PG_RETURN_CSTRING(output);
}


/*
 * Receive [flag][encoded BSON], without the PostgreSQL varlena length header.
 * The one-byte flag is 0 for raw BSON or 1 for a Zstandard frame.
 * Rebuild the local varlena header and validate without changing the encoded bytes.
 */
Datum
bson_external_recv(PG_FUNCTION_ARGS)
{
	StringInfo buffer = (StringInfo) PG_GETARG_POINTER(0);
	int payloadSize = buffer->len - buffer->cursor;
	if ((Size) payloadSize > MaxAllocSize - VARHDRSZ)
	{
		ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						errmsg("BSON external binary data is too large")));
	}

	const char *payload = pq_getmsgbytes(buffer, payloadSize);
	pgbson_external *externalBson = (pgbson_external *) palloc(payloadSize + VARHDRSZ);
	SET_VARSIZE(externalBson, payloadSize + VARHDRSZ);
	memcpy(VARDATA(externalBson), payload, payloadSize);

	/* Decompress only for validation; return the original encoded bytes unchanged. */
	pgbson *bson = DecompressBsonExternal(externalBson);
	pfree(bson);

	PG_RETURN_POINTER(externalBson);
}


/*
 * Send [flag][encoded BSON]: a one-byte format flag followed by raw BSON (flag 0)
 * or a Zstandard frame (flag 1). Exclude the PostgreSQL varlena length header
 * and preserve the encoded bytes without decompressing.
 */
Datum
bson_external_send(PG_FUNCTION_ARGS)
{
	pgbson_external *externalBson = PG_GETARG_PGBSON_EXTERNAL_PACKED(0);
	StringInfoData buffer;
	pq_begintypsend(&buffer);
	pq_sendbytes(&buffer, VARDATA_ANY(externalBson), VARSIZE_ANY_EXHDR(externalBson));
	PG_FREE_IF_COPY(externalBson, 0);
	PG_RETURN_BYTEA_P(pq_endtypsend(&buffer));
}


Datum
bson_to_bson_external(PG_FUNCTION_ARGS)
{
	pgbson *bson = PG_GETARG_PGBSON_PACKED(0);
	pgbson_external *externalBson = CompressBsonExternal(bson);
	PG_FREE_IF_COPY(bson, 0);
	PG_RETURN_POINTER(externalBson);
}


Datum
bson_external_to_bson(PG_FUNCTION_ARGS)
{
	pgbson_external *externalBson = PG_GETARG_PGBSON_EXTERNAL_PACKED(0);
	pgbson *bson = DecompressBsonExternal(externalBson);
	PG_FREE_IF_COPY(externalBson, 0);
	PG_RETURN_POINTER(bson);
}


static pgbson_external *
CompressBsonExternal(const pgbson *bson)
{
	size_t bsonSize = VARSIZE_ANY_EXHDR(bson);
	if (bsonSize > BSON_EXTERNAL_MAX_UNCOMPRESSED_SIZE)
	{
		ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						errmsg(
							"BSON external uncompressed size exceeds the limit of %d bytes",
							BSON_EXTERNAL_MAX_UNCOMPRESSED_SIZE)));
	}

	size_t compressedCapacity = ZSTD_compressBound(bsonSize);
	if (compressedCapacity > MaxAllocSize - VARHDRSZ - BSON_EXTERNAL_FLAG_SIZE)
	{
		ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						errmsg("BSON data is too large to compress")));
	}

	pgbson_external *externalBson = (pgbson_external *) palloc(
		compressedCapacity + VARHDRSZ + BSON_EXTERNAL_FLAG_SIZE);
	uint8 *externalData = (uint8 *) VARDATA(externalBson);
	externalData[0] = BSON_EXTERNAL_FLAG_ZSTD;

	/* The Zstandard frame starts immediately after the one-byte format flag. */
	size_t compressedSize = ZSTD_compress(externalData + BSON_EXTERNAL_FLAG_SIZE,
										  compressedCapacity,
										  VARDATA_ANY(bson), bsonSize,
										  ZSTD_CLEVEL_DEFAULT);
	if (ZSTD_isError(compressedSize))
	{
		ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR),
						errmsg("could not compress BSON data: %s",
							   ZSTD_getErrorName(compressedSize))));
	}

	SET_VARSIZE(externalBson, compressedSize + VARHDRSZ + BSON_EXTERNAL_FLAG_SIZE);
	return externalBson;
}


static pgbson *
DecompressBsonExternal(const pgbson_external *externalBson)
{
	size_t externalSize = VARSIZE_ANY_EXHDR(externalBson);
	if (externalSize < BSON_EXTERNAL_FLAG_SIZE)
	{
		ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
						errmsg("BSON external data does not include a flags byte")));
	}

	uint8 flags = *((const uint8 *) VARDATA_ANY(externalBson));
	const char *payload = VARDATA_ANY(externalBson) + BSON_EXTERNAL_FLAG_SIZE;
	size_t payloadSize = externalSize - BSON_EXTERNAL_FLAG_SIZE;
	if (flags == BSON_EXTERNAL_FLAG_UNCOMPRESSED)
	{
		if (payloadSize > BSON_EXTERNAL_MAX_UNCOMPRESSED_SIZE)
		{
			ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
							errmsg(
								"BSON external uncompressed size exceeds the limit of %d bytes",
								BSON_EXTERNAL_MAX_UNCOMPRESSED_SIZE)));
		}

		pgbson *bson = PgbsonInitFromBuffer(payload, (uint32) payloadSize);
		PgbsonValidateInputBson(bson, BSON_VALIDATE_NONE);
		return bson;
	}
	else if (flags != BSON_EXTERNAL_FLAG_ZSTD)
	{
		ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
						errmsg("unsupported BSON external flags value: %u", flags)));
	}

	unsigned long long bsonSize = ZSTD_getFrameContentSize(payload, payloadSize);
	if (bsonSize == ZSTD_CONTENTSIZE_ERROR)
	{
		ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
						errmsg("invalid compressed BSON data")));
	}
	else if (bsonSize == ZSTD_CONTENTSIZE_UNKNOWN)
	{
		ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
						errmsg(
							"compressed BSON data does not include its uncompressed size")));
	}
	else if (bsonSize > BSON_EXTERNAL_MAX_UNCOMPRESSED_SIZE)
	{
		ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						errmsg(
							"BSON external uncompressed size exceeds the limit of %d bytes",
							BSON_EXTERNAL_MAX_UNCOMPRESSED_SIZE)));
	}

	pgbson *bson = (pgbson *) palloc((Size) bsonSize + VARHDRSZ);
	size_t decompressedSize = ZSTD_decompress(VARDATA(bson), (size_t) bsonSize,
											  payload, payloadSize);
	if (ZSTD_isError(decompressedSize))
	{
		ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
						errmsg("could not decompress BSON data: %s",
							   ZSTD_getErrorName(decompressedSize))));
	}
	else if (decompressedSize != bsonSize)
	{
		ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
						errmsg("decompressed BSON size does not match the stored size")));
	}

	SET_VARSIZE(bson, (Size) bsonSize + VARHDRSZ);
	PgbsonValidateInputBson(bson, BSON_VALIDATE_NONE);
	return bson;
}
