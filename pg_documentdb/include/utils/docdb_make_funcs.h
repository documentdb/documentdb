/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/utils/docdb_make_funcs.h
 *
 * Utilities for making DocDB function expressions
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCDB_MAKE_FUNCS_H
#define DOCDB_MAKE_FUNCS_H

#include <postgres.h>
#include <nodes/parsenodes.h>
#include <utils/builtins.h>
#include <catalog/pg_collation.h>
#include <nodes/makefuncs.h>
#include <io/bson_core.h>
#include <metadata/metadata_cache.h>

inline static Const *
MakeTextConst(const char *cstring, uint32_t stringLength)
{
	text *textValue = cstring_to_text_with_len(cstring, stringLength);
	return makeConst(TEXTOID, -1, DEFAULT_COLLATION_OID, -1, PointerGetDatum(textValue),
					 false,
					 false);
}


inline static Const *
MakeBsonConst(pgbson *pgbson)
{
	return makeConst(BsonTypeId(), -1, InvalidOid, -1, PointerGetDatum(pgbson), false,
					 false);
}


/*
 * Inline method for a bool const specifying the isNull attribute.
 */
inline static Node *
MakeBoolValueConst(bool value)
{
	bool isNull = false;
	return makeBoolConst(value, isNull);
}


inline static Const *
MakeFloat8Const(float8 floatValue)
{
	return makeConst(FLOAT8OID, -1, InvalidOid, sizeof(float8),
					 Float8GetDatum(floatValue), false, true);
}


#endif
