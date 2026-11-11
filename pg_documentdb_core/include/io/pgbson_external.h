/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * include/io/pgbson_external.h
 *
 * C representation of BSON external values.
 *-------------------------------------------------------------------------
 */

#ifndef PG_BSON_EXTERNAL_H
#define PG_BSON_EXTERNAL_H

#include <postgres.h>
#include <fmgr.h>

#if PG_VERSION_NUM >= 160000
#include <varatt.h>
#endif

/*
 * Uses the standard varlena layout but remains a distinct C type from pgbson.
 * The bytes after the varlena header (vl_dat in an unpacked value) start with
 * a one-byte format flag: 0 for raw BSON, 1 for a Zstandard frame.
 * Access these bytes through VARDATA_ANY() to also support packed values.
 */
typedef struct
{
	int32 vl_len_; /* varlena header (do not touch directly!) */
	char vl_dat[FLEXIBLE_ARRAY_MEMBER];
} pgbson_external;

#define DatumGetPgBsonExternal(n) ((pgbson_external *) PG_DETOAST_DATUM(n))
#define DatumGetPgBsonExternal_MAYBE_NULL(n) \
	(DatumGetPointer(n) == NULL ? NULL : DatumGetPgBsonExternal(n))
#define PG_GETARG_PGBSON_EXTERNAL(n) (DatumGetPgBsonExternal(PG_GETARG_DATUM(n)))
#define PG_GETARG_MAYBE_NULL_PGBSON_EXTERNAL(n) \
	(PG_ARGISNULL(n) ? NULL : PG_GETARG_PGBSON_EXTERNAL(n))

/* Packed values require VARSIZE_ANY_EXHDR and VARDATA_ANY. */
#define DatumGetPgBsonExternalPacked(n) \
	((pgbson_external *) PG_DETOAST_DATUM_PACKED(n))
#define PG_GETARG_PGBSON_EXTERNAL_PACKED(n) \
	(DatumGetPgBsonExternalPacked(PG_GETARG_DATUM(n)))
#define PG_GETARG_MAYBE_NULL_PGBSON_EXTERNAL_PACKED(n) \
	(PG_ARGISNULL(n) ? NULL : PG_GETARG_PGBSON_EXTERNAL_PACKED(n))

#endif
