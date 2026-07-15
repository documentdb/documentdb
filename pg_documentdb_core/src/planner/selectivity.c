/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/planner/selectivity.c
 *
 * Implementation of selectivity functions for BSON operators.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <access/stratnum.h>
#include <utils/lsyscache.h>
#include <utils/typcache.h>
#include <utils/selfuncs.h>

#include "utils/type_cache.h"

#define BSON_DEFAULT_SELECTIVITY 0.01

extern bool EnableBsonSelectivityFromBtreeStats;

/* PG selectivity functions */
extern Datum eqsel(PG_FUNCTION_ARGS);
extern Datum neqsel(PG_FUNCTION_ARGS);
extern Datum scalargtsel(PG_FUNCTION_ARGS);
extern Datum scalargesel(PG_FUNCTION_ARGS);
extern Datum scalarltsel(PG_FUNCTION_ARGS);
extern Datum scalarlesel(PG_FUNCTION_ARGS);
extern Datum neqsel(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(bson_operator_selectivity);
PG_FUNCTION_INFO_V1(bson_eqsel);
PG_FUNCTION_INFO_V1(bson_scalargtsel);
PG_FUNCTION_INFO_V1(bson_scalargesel);
PG_FUNCTION_INFO_V1(bson_scalarltsel);
PG_FUNCTION_INFO_V1(bson_scalarlesel);
PG_FUNCTION_INFO_V1(bson_neqsel);

/*
 * bson_operator_selectivity returns the selectivity of a BSON operator
 * on a relation. It calls into PG selectivity functions if the operator is a well known btree operator.
 */
Datum
bson_operator_selectivity(PG_FUNCTION_ARGS)
{
	/* default to 1% if not enabled to preerve the old behavior. */
	double selectivity = BSON_DEFAULT_SELECTIVITY;
	if (!EnableBsonSelectivityFromBtreeStats)
	{
		PG_RETURN_FLOAT8(selectivity);
	}

	TypeCacheEntry *typeCacheEntry = lookup_type_cache(BsonTypeId(), TYPECACHE_EQ_OPR);

	Datum oidDatum = PG_GETARG_DATUM(1);
	Oid opno = DatumGetObjectId(oidDatum);

	int strategy = get_op_opfamily_strategy(opno, typeCacheEntry->btree_opf);

	switch (strategy)
	{
		case BTEqualStrategyNumber:
		{
			selectivity = DatumGetFloat8(DirectFunctionCall4(eqsel, PG_GETARG_DATUM(0),
															 oidDatum, PG_GETARG_DATUM(2),
															 PG_GETARG_DATUM(3)));
			break;
		}

		case BTGreaterStrategyNumber:
		{
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalargtsel, PG_GETARG_DATUM(
																 0), oidDatum,
															 PG_GETARG_DATUM(2),
															 PG_GETARG_DATUM(3)));
			break;
		}

		case BTGreaterEqualStrategyNumber:
		{
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalargesel, PG_GETARG_DATUM(
																 0), oidDatum,
															 PG_GETARG_DATUM(2),
															 PG_GETARG_DATUM(3)));
			break;
		}

		case BTLessStrategyNumber:
		{
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalarltsel, PG_GETARG_DATUM(
																 0), oidDatum,
															 PG_GETARG_DATUM(2),
															 PG_GETARG_DATUM(3)));
			break;
		}

		case BTLessEqualStrategyNumber:
		{
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalarlesel,
															 PG_GETARG_DATUM(0), oidDatum,
															 PG_GETARG_DATUM(2),
															 PG_GETARG_DATUM(3)));
			break;
		}

		default:
		{
			bool isNotEquals = get_negator(typeCacheEntry->eq_opr) == opno;

			if (isNotEquals)
			{
				Datum result = DirectFunctionCall4(eqsel, PG_GETARG_DATUM(0), oidDatum,
												   PG_GETARG_DATUM(2),
												   PG_GETARG_DATUM(3));
				selectivity = 1.0 - DatumGetFloat8(result);
			}

			break;
		}
	}

	CLAMP_PROBABILITY(selectivity);
	PG_RETURN_FLOAT8(selectivity);
}


Datum
bson_eqsel(PG_FUNCTION_ARGS)
{
	if (!EnableBsonSelectivityFromBtreeStats)
	{
		PG_RETURN_FLOAT8(BSON_DEFAULT_SELECTIVITY);
	}

	double selectivity = DatumGetFloat8(DirectFunctionCall4(eqsel, PG_GETARG_DATUM(0),
															PG_GETARG_DATUM(1),
															PG_GETARG_DATUM(2),
															PG_GETARG_DATUM(3)));
	CLAMP_PROBABILITY(selectivity);
	PG_RETURN_FLOAT8(selectivity);
}


Datum
bson_scalargtsel(PG_FUNCTION_ARGS)
{
	if (!EnableBsonSelectivityFromBtreeStats)
	{
		PG_RETURN_FLOAT8(BSON_DEFAULT_SELECTIVITY);
	}

	double selectivity = DatumGetFloat8(DirectFunctionCall4(scalargtsel, PG_GETARG_DATUM(
																0),
															PG_GETARG_DATUM(1),
															PG_GETARG_DATUM(2),
															PG_GETARG_DATUM(3)));
	CLAMP_PROBABILITY(selectivity);
	PG_RETURN_FLOAT8(selectivity);
}


Datum
bson_scalargesel(PG_FUNCTION_ARGS)
{
	if (!EnableBsonSelectivityFromBtreeStats)
	{
		PG_RETURN_FLOAT8(BSON_DEFAULT_SELECTIVITY);
	}

	double selectivity = DatumGetFloat8(DirectFunctionCall4(scalargesel, PG_GETARG_DATUM(
																0),
															PG_GETARG_DATUM(1),
															PG_GETARG_DATUM(2),
															PG_GETARG_DATUM(3)));
	CLAMP_PROBABILITY(selectivity);
	PG_RETURN_FLOAT8(selectivity);
}


Datum
bson_scalarltsel(PG_FUNCTION_ARGS)
{
	if (!EnableBsonSelectivityFromBtreeStats)
	{
		PG_RETURN_FLOAT8(BSON_DEFAULT_SELECTIVITY);
	}

	double selectivity = DatumGetFloat8(DirectFunctionCall4(scalarltsel, PG_GETARG_DATUM(
																0),
															PG_GETARG_DATUM(1),
															PG_GETARG_DATUM(2),
															PG_GETARG_DATUM(3)));
	CLAMP_PROBABILITY(selectivity);
	PG_RETURN_FLOAT8(selectivity);
}


Datum
bson_scalarlesel(PG_FUNCTION_ARGS)
{
	if (!EnableBsonSelectivityFromBtreeStats)
	{
		PG_RETURN_FLOAT8(BSON_DEFAULT_SELECTIVITY);
	}

	double selectivity = DatumGetFloat8(DirectFunctionCall4(scalarlesel, PG_GETARG_DATUM(
																0),
															PG_GETARG_DATUM(1),
															PG_GETARG_DATUM(2),
															PG_GETARG_DATUM(3)));
	CLAMP_PROBABILITY(selectivity);
	PG_RETURN_FLOAT8(selectivity);
}


Datum
bson_neqsel(PG_FUNCTION_ARGS)
{
	if (!EnableBsonSelectivityFromBtreeStats)
	{
		PG_RETURN_FLOAT8(BSON_DEFAULT_SELECTIVITY);
	}

	double selectivity = DatumGetFloat8(DirectFunctionCall4(neqsel, PG_GETARG_DATUM(0),
															PG_GETARG_DATUM(1),
															PG_GETARG_DATUM(2),
															PG_GETARG_DATUM(3)));
	CLAMP_PROBABILITY(selectivity);
	PG_RETURN_FLOAT8(selectivity);
}
