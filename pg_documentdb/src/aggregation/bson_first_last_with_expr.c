/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/aggregation/bson_first_last_with_expr.c
 *
 * Optimized aggregate implementations for $first/$last
 * accumulator operators in the "OnSorted" (no preceding $sort) path.
 *
 * Both aggregates embed expression evaluation directly in the
 * transition function, eliminating redundant BSON materialization.
 *
 * These aggregates also define combine functions for distributed
 * pushdown in sharded scenarios.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <fmgr.h>

#include "aggregation/bson_aggregate.h"
#include "collation/collation.h"
#include "io/bson_core.h"
#include "query/bson_compare.h"
#include "operators/bson_expression.h"
#include "operators/bson_expression_operators.h"

/* --------------------------------------------------------- */
/* Forward declarations */
/* --------------------------------------------------------- */

static bson_value_t EvaluateExprOnDoc(const BsonExpressionState *exprState,
									  pgbson *document, bool *isEod,
									  ExpressionLifetimeTracker *tracker);


/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

PG_FUNCTION_INFO_V1(bson_first_with_expr_transition);
PG_FUNCTION_INFO_V1(bson_first_with_expr_combine);
PG_FUNCTION_INFO_V1(bson_first_with_expr_final);

PG_FUNCTION_INFO_V1(bson_last_with_expr_transition);
PG_FUNCTION_INFO_V1(bson_last_with_expr_combine);
PG_FUNCTION_INFO_V1(bson_last_with_expr_final);

/* --------------------------------------------------------- */
/* Helper implementations */
/* --------------------------------------------------------- */

static bson_value_t
EvaluateExprOnDoc(const BsonExpressionState *exprState,
				  pgbson *document, bool *isEod,
				  ExpressionLifetimeTracker *tracker)
{
	ExpressionResultPrivate resultPrivate;
	memset(&resultPrivate, 0, sizeof(ExpressionResultPrivate));
	resultPrivate.tracker = tracker;
	resultPrivate.variableContext.parent = exprState->variableContext;

	ExpressionResult exprResult = { { 0 }, false, false, resultPrivate };

	EvaluateAggregationExpressionData(exprState->expressionData, document,
									  &exprResult, false /* isNullOnEmpty */);
	bson_value_t result = exprResult.value;
	*isEod = (result.value_type == BSON_TYPE_EOD);

	return result;
}


/* =========================================================
 * $first with expr
 * =========================================================
 * Args: (state bsonaggvalue, document bson, exprSpec bson, varSpec bson, collation text)
 */
Datum
bson_first_with_expr_transition(PG_FUNCTION_ARGS)
{
	MemoryContext aggCtx;
	if (!AggCheckCallContext(fcinfo, &aggCtx))
	{
		ereport(ERROR, errmsg(
					"aggregate function bson_first_with_expr_transition called in non-aggregate context"));
	}

	/* Once we have a value, skip all subsequent documents */
	if (!PG_ARGISNULL(0))
	{
		PG_RETURN_POINTER(PG_GETARG_POINTER(0));
	}

	pgbson *inputDoc = PG_GETARG_MAYBE_NULL_PGBSON_PACKED(1);
	if (inputDoc == NULL)
	{
		PG_RETURN_NULL();
	}

	pgbson *exprBson = PG_GETARG_PGBSON(2);
	pgbson *varSpec = PG_NARGS() > 3 ? PG_GETARG_MAYBE_NULL_PGBSON(3) : NULL;

	text *collationText = NULL;
	const char *collationString = NULL;
	if (PG_NARGS() > 4 && !PG_ARGISNULL(4))
	{
		collationText = PG_GETARG_TEXT_PP(4);
		collationString = text_to_cstring(collationText);
	}

	const BsonExpressionState *exprState = GetOrCreateCachedExpressionState(
		fcinfo->flinfo, exprBson, varSpec, collationText);

	bool isEod = false;
	ExpressionLifetimeTracker tracker = { 0 };
	bson_value_t evaluated = EvaluateExprOnDoc(exprState, inputDoc, &isEod, &tracker);

	MemoryContext oldCtx = MemoryContextSwitchTo(aggCtx);
	BsonAggValue *newState = (BsonAggValue *) palloc0(sizeof(BsonAggValue));
	SET_VARSIZE(newState, sizeof(BsonAggValue));
	newState->collationString = IsCollationValid(collationString) ?
								pstrdup(collationString) : NULL;
	if (isEod)
	{
		newState->value.value_type = BSON_TYPE_EOD;
	}
	else
	{
		bson_value_copy(&evaluated, &newState->value);
	}
	MemoryContextSwitchTo(oldCtx);

	PG_RETURN_POINTER(newState);
}


Datum
bson_first_with_expr_combine(PG_FUNCTION_ARGS)
{
	MemoryContext aggCtx;
	if (!AggCheckCallContext(fcinfo, &aggCtx))
	{
		ereport(ERROR, errmsg(
					"aggregate function bson_first_with_expr_combine called in non-aggregate context"));
	}

	if (PG_ARGISNULL(0) && PG_ARGISNULL(1))
	{
		PG_RETURN_NULL();
	}

	/* Return left (first) if available, else right */
	BsonAggValue *source;
	if (!PG_ARGISNULL(0))
	{
		source = (BsonAggValue *) PG_GETARG_POINTER(0);
	}
	else
	{
		source = (BsonAggValue *) PG_GETARG_POINTER(1);
	}

	MemoryContext oldCtx = MemoryContextSwitchTo(aggCtx);
	BsonAggValue *result = (BsonAggValue *) palloc0(sizeof(BsonAggValue));
	SET_VARSIZE(result, sizeof(BsonAggValue));
	bson_value_copy(&source->value, &result->value);

	/* Propagate collation for consistency even though final does not use it */
	result->collationString = source->collationString ?
							  pstrdup(source->collationString) : NULL;
	MemoryContextSwitchTo(oldCtx);

	PG_RETURN_POINTER(result);
}


Datum
bson_first_with_expr_final(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		pgbsonelement finalValue;
		finalValue.path = "";
		finalValue.pathLength = 0;
		finalValue.bsonValue.value_type = BSON_TYPE_NULL;
		PG_RETURN_POINTER(PgbsonElementToPgbson(&finalValue));
	}

	BsonAggValue *state = (BsonAggValue *) PG_GETARG_POINTER(0);

	pgbsonelement finalValue;
	finalValue.path = "";
	finalValue.pathLength = 0;

	if (state->value.value_type == BSON_TYPE_EOD)
	{
		finalValue.bsonValue.value_type = BSON_TYPE_NULL;
	}
	else
	{
		finalValue.bsonValue = state->value;
	}

	PG_RETURN_POINTER(PgbsonElementToPgbson(&finalValue));
}


/* =========================================================
 * $last with expr
 * =========================================================
 * Args: (state bsonaggvalue, document bson, exprSpec bson, varSpec bson, collation text)
 *
 * Evaluates the expression in the transition function
 * and always overwrites with the latest value.
 */
Datum
bson_last_with_expr_transition(PG_FUNCTION_ARGS)
{
	MemoryContext aggCtx;
	if (!AggCheckCallContext(fcinfo, &aggCtx))
	{
		ereport(ERROR, errmsg(
					"aggregate function bson_last_with_expr_transition called in non-aggregate context"));
	}

	pgbson *inputDoc = PG_GETARG_MAYBE_NULL_PGBSON_PACKED(1);
	if (inputDoc == NULL)
	{
		if (PG_ARGISNULL(0))
		{
			PG_RETURN_NULL();
		}
		PG_RETURN_POINTER(PG_GETARG_POINTER(0));
	}

	pgbson *exprBson = PG_GETARG_PGBSON(2);
	pgbson *varSpec = PG_NARGS() > 3 ? PG_GETARG_MAYBE_NULL_PGBSON(3) : NULL;

	text *collationText = NULL;
	const char *collationString = NULL;
	if (PG_NARGS() > 4 && !PG_ARGISNULL(4))
	{
		collationText = PG_GETARG_TEXT_PP(4);
		collationString = text_to_cstring(collationText);
	}

	const BsonExpressionState *exprState = GetOrCreateCachedExpressionState(
		fcinfo->flinfo, exprBson, varSpec, collationText);

	bool isEod = false;
	ExpressionLifetimeTracker tracker = { 0 };
	bson_value_t evaluated = EvaluateExprOnDoc(exprState, inputDoc, &isEod, &tracker);

	/*
	 * Allocate in aggCtx so internal bson_value_copy data survives
	 * across per-tuple context resets (bson_malloc routes to palloc).
	 */
	MemoryContext oldCtx = MemoryContextSwitchTo(aggCtx);
	BsonAggValue *state;
	if (!PG_ARGISNULL(0))
	{
		/* Reuse existing state, destroy old value to avoid leaking memory */
		state = (BsonAggValue *) PG_GETARG_POINTER(0);
		bson_value_destroy(&state->value);
		memset(&state->value, 0, sizeof(bson_value_t));
	}
	else
	{
		state = (BsonAggValue *) palloc0(sizeof(BsonAggValue));
		SET_VARSIZE(state, sizeof(BsonAggValue));
		state->collationString = IsCollationValid(collationString) ?
								 pstrdup(collationString) : NULL;
	}

	if (isEod)
	{
		state->value.value_type = BSON_TYPE_EOD;
	}
	else
	{
		bson_value_copy(&evaluated, &state->value);
	}
	MemoryContextSwitchTo(oldCtx);

	PG_RETURN_POINTER(state);
}


Datum
bson_last_with_expr_combine(PG_FUNCTION_ARGS)
{
	MemoryContext aggCtx;
	if (!AggCheckCallContext(fcinfo, &aggCtx))
	{
		ereport(ERROR, errmsg(
					"aggregate function bson_last_with_expr_combine called in non-aggregate context"));
	}

	if (PG_ARGISNULL(0) && PG_ARGISNULL(1))
	{
		PG_RETURN_NULL();
	}

	/* Return right (last) if available, else left */
	BsonAggValue *source;
	if (!PG_ARGISNULL(1))
	{
		source = (BsonAggValue *) PG_GETARG_POINTER(1);
	}
	else
	{
		source = (BsonAggValue *) PG_GETARG_POINTER(0);
	}

	MemoryContext oldCtx = MemoryContextSwitchTo(aggCtx);
	BsonAggValue *result = (BsonAggValue *) palloc0(sizeof(BsonAggValue));
	SET_VARSIZE(result, sizeof(BsonAggValue));
	bson_value_copy(&source->value, &result->value);

	/* Propagate collation for consistency even though final does not use it */
	result->collationString = source->collationString ?
							  pstrdup(source->collationString) : NULL;
	MemoryContextSwitchTo(oldCtx);

	PG_RETURN_POINTER(result);
}


Datum
bson_last_with_expr_final(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		pgbsonelement finalValue;
		finalValue.path = "";
		finalValue.pathLength = 0;
		finalValue.bsonValue.value_type = BSON_TYPE_NULL;
		PG_RETURN_POINTER(PgbsonElementToPgbson(&finalValue));
	}

	BsonAggValue *state = (BsonAggValue *) PG_GETARG_POINTER(0);

	pgbsonelement finalValue;
	finalValue.path = "";
	finalValue.pathLength = 0;

	if (state->value.value_type == BSON_TYPE_EOD)
	{
		finalValue.bsonValue.value_type = BSON_TYPE_NULL;
	}
	else
	{
		finalValue.bsonValue = state->value;
	}

	PG_RETURN_POINTER(PgbsonElementToPgbson(&finalValue));
}
