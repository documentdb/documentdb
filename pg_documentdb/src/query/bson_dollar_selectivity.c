/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/query/selectivity.c
 *
 * Implementation of selectivity functions for BSON operators.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <utils/lsyscache.h>
#include <utils/memutils.h>
#include <catalog/pg_collation.h>
#include <nodes/pathnodes.h>
#include <nodes/makefuncs.h>
#include <utils/selfuncs.h>
#include <parser/parsetree.h>
#include <optimizer/pathnode.h>
#include <metadata/metadata_cache.h>
#include <planner/mongo_query_operator.h>
#include <query/bson_compare.h>
#include <utils/search_utils.h>
#include <catalog/pg_statistic_ext.h>
#include <catalog/pg_statistic.h>
#include <statistics/statistics.h>

#include "query/bson_dollar_selectivity.h"
#include "opclass/bson_gin_composite_scan.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "aggregation/bson_query_common.h"
#include "utils/docdb_make_funcs.h"
#include "utils/version_utils.h"
#include "io/bson_traversal.h"

extern bool EnablePerCollectionPlannerStatistics;
extern bool EnableCompositeIndexPlanner;
extern bool EnableIndexCorrelationFromStatistics;

/* CODESYNC with system_configs.c */
#define ARRAY_STATISTICS_MAX_SAMPLE_COUNT 128
extern int ArrayStatisticsMaxSampleCount;


/* See analyze.c in postgres for details on the limit */
#define MAX_SCALAR_TYPE_ANALYZE_SIZE 1024

typedef struct StatsProjectState
{
	bson_value_t samples[ARRAY_STATISTICS_MAX_SAMPLE_COUNT];
	int sampleCount;
	int maxAllowedSamples;
} StatsProjectState;

/* PG selectivity functions */
extern Datum eqsel(PG_FUNCTION_ARGS);
extern Datum scalargtsel(PG_FUNCTION_ARGS);
extern Datum scalargesel(PG_FUNCTION_ARGS);
extern Datum scalarltsel(PG_FUNCTION_ARGS);
extern Datum scalarlesel(PG_FUNCTION_ARGS);
extern Datum neqsel(PG_FUNCTION_ARGS);

static double GetStatisticsNoStatsData(List *args, Oid selectivityOpExpr, double
									   defaultExprSelectivity,
									   pgbsonelement *outputDollarElement,
									   BsonIndexStrategy *outputIndexStrategy);

static double GetDisableStatisticSelectivity(List *args, double
											 defaultDisabledSelectivity);

static bool StatsProjectVisitTopLevelField(pgbsonelement *element, const
										   StringView *traversePath,
										   void *state);
static bool StatsProjectContinueProcessingIntermediateArray(void *state, const
															bson_value_t *value, bool
															isArrayIndexSearch);
static bool StatsProjectVisitArrayField(pgbsonelement *element, const
										StringView *traversePath, int
										arrayIndex, void *state);
static void StatsSetIntermediateArrayStartEnd(void *state, bool isStart);

static void StatsHandleIntermediateArrayPathNotFound(void *state, int32_t arrayIndex,
													 const
													 StringView *remainingPath);

PG_FUNCTION_INFO_V1(bson_dollar_selectivity);
PG_FUNCTION_INFO_V1(bson_stats_project);
PG_FUNCTION_INFO_V1(test_bson_stats_project_with_memcheck);

static const TraverseBsonExecutionFuncs StatsProjectExecutionFuncs = {
	.ContinueProcessIntermediateArray = StatsProjectContinueProcessingIntermediateArray,
	.SetTraverseResult = NULL,
	.VisitArrayField = StatsProjectVisitArrayField,
	.VisitTopLevelField = StatsProjectVisitTopLevelField,
	.SetIntermediateArrayIndex = NULL,
	.HandleIntermediateArrayPathNotFound = StatsHandleIntermediateArrayPathNotFound,
	.SetIntermediateArrayStartEnd = StatsSetIntermediateArrayStartEnd,
};


static inline bool
IsLookupExtractFuncExpr(Node *expr)
{
	if (!IsA(expr, FuncExpr))
	{
		return false;
	}

	FuncExpr *funcExpr = (FuncExpr *) expr;
	return funcExpr->funcid ==
		   DocumentDBApiInternalBsonLookupExtractFilterExpressionFunctionOid();
}


/*
 * bson_operator_selectivity returns the selectivity of a BSON operator
 * on a relation.
 */
Datum
bson_dollar_selectivity(PG_FUNCTION_ARGS)
{
	PlannerInfo *planner = (PlannerInfo *) PG_GETARG_POINTER(0);
	Oid selectivityOpExpr = PG_GETARG_OID(1);
	List *args = (List *) PG_GETARG_POINTER(2);
	int varRelId = PG_GETARG_INT32(3);
	Oid collation = PG_GET_COLLATION();

	/* The default selectivity Postgres applies for matching clauses. */
	const double defaultOperatorSelectivity = 0.5;
	double selectivity = GetDollarOperatorSelectivity(
		planner, selectivityOpExpr, args, collation, varRelId,
		defaultOperatorSelectivity);

	PG_RETURN_FLOAT8(selectivity);
}


inline static bool
EnablePlannerCostSelectivityFromRelOptInfoCore(PlannerInfo *planner, RelOptInfo *rel,
											   bool *isPerCollectionStatsEnabled)
{
	*isPerCollectionStatsEnabled = false;
	bool enableOperatorSelectivity = EnableCompositeIndexPlanner;
	if (EnablePerCollectionPlannerStatistics &&
		rel != NULL)
	{
		*isPerCollectionStatsEnabled = list_length(rel->statlist) > 0;
		enableOperatorSelectivity = enableOperatorSelectivity ||
									*isPerCollectionStatsEnabled;
	}

	return enableOperatorSelectivity;
}


bool
EnablePlannerCostSelectivityFromRelOptInfo(PlannerInfo *planner, RelOptInfo *rel)
{
	bool isPerCollectionStatsEnabled = false;
	return EnablePlannerCostSelectivityFromRelOptInfoCore(planner, rel,
														  &isPerCollectionStatsEnabled);
}


inline static bool
EnablePlannerCostSelectivityExtended(PlannerInfo *planner, List *args,
									 bool *isPerCollectionStatsEnabled)
{
	RelOptInfo *rel = NULL;
	if (EnablePerCollectionPlannerStatistics &&
		list_length(args) > 0)
	{
		Expr *firstArg = linitial(args);
		if (IsA(firstArg, Var))
		{
			Var *firstVar = castNode(Var, firstArg);
			rel = find_base_rel(planner, firstVar->varno);
		}
	}

	return EnablePlannerCostSelectivityFromRelOptInfoCore(planner, rel,
														  isPerCollectionStatsEnabled);
}


bool
EnablePlannerCostSelectivity(PlannerInfo *planner, List *args)
{
	bool isPerCollectionStatsEnabled = false;
	return EnablePlannerCostSelectivityExtended(planner, args,
												&isPerCollectionStatsEnabled);
}


/*
 * Calculate the selectivity for $exists queries.
 * Which is essentially $exists: false -> $eq: null
 * For $exists: true is the inverse, so we can just do 1.0 - $eq: null selectivity.
 */
static double
GetDollarExistsSelectivity(PlannerInfo *planner, Oid selectivityOpExpr, Node *leftOperand,
						   bson_value_t *rightValue, int varRelId, bool isExistsTrue)
{
	rightValue->value_type = BSON_TYPE_NULL;
	List *args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
														   rightValue)));
	double selectivity = DatumGetFloat8(DirectFunctionCall4(eqsel,
															PointerGetDatum(planner),
															ObjectIdGetDatum(
																selectivityOpExpr),
															PointerGetDatum(args),
															Int32GetDatum(
																varRelId)));

	if (isExistsTrue)
	{
		selectivity = 1.0 - selectivity;
	}

	CLAMP_PROBABILITY(selectivity);
	list_free(args);
	return selectivity;
}


static double
GetCustomStatisticsSelectivity(PlannerInfo *planner, BsonIndexStrategy
							   indexStrategy, Oid selectivityOpExpr,
							   Node *leftOperand, bson_value_t *rightValue,
							   int varRelId, Oid collation,
							   double defaultInputSelectivity)
{
	/*
	 * TODO Selectivity:
	 * REGEX: for regex with anchored prefix, we should use range selectivity. Calculate the gte and lte boundaries selectivity.
	 * $IN/$NIN: for $in and $nin with small set of elements (i.e <= 20) we should consider using scalararray selectivity functions
	 * (scalararraysel/scalararraynesel), or exploring what btree does for SAOP to have the best selectivity estimate.
	 */

	List *args = NIL;
	double selectivity = defaultInputSelectivity;

	/* Generic default selectivity clamps at 0.0001, so for large tables, the selectivity would be very high, i.e for a 2B row table, that would be 200,000 rows
	 * which gives false positive results when doing the plan, making postgres it is better to do index bitmap intersections rather than pushing filters to the runtime
	 * etc. For well known strategies, we can use the more accurate selectivity functions which has no clamping and just trusts the mvc data. */
	switch (indexStrategy)
	{
		case BSON_INDEX_STRATEGY_DOLLAR_EQUAL:
		{
			args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
															 rightValue)));
			selectivity = DatumGetFloat8(DirectFunctionCall4(eqsel, PointerGetDatum(
																 planner),
															 ObjectIdGetDatum(
																 selectivityOpExpr),
															 PointerGetDatum(args),
															 Int32GetDatum(varRelId)));
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER:
		{
			args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
															 rightValue)));
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalargtsel, PointerGetDatum(
																 planner),
															 ObjectIdGetDatum(
																 selectivityOpExpr),
															 PointerGetDatum(args),
															 Int32GetDatum(varRelId)));
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL:
		{
			/* We transform $exists: true as $gte: MinKey for PFE support. */
			if (rightValue->value_type == BSON_TYPE_MINKEY)
			{
				bool isExistsTrue = true;
				return GetDollarExistsSelectivity(planner, selectivityOpExpr, leftOperand,
												  rightValue, varRelId, isExistsTrue);
			}

			args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
															 rightValue)));
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalargesel, PointerGetDatum(
																 planner),
															 ObjectIdGetDatum(
																 selectivityOpExpr),
															 PointerGetDatum(args),
															 Int32GetDatum(varRelId)));
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_EXISTS:
		{
			bool isExistsTrue = BsonValueAsBool(rightValue);
			return GetDollarExistsSelectivity(planner, selectivityOpExpr, leftOperand,
											  rightValue, varRelId, isExistsTrue);
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS:
		{
			args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
															 rightValue)));
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalarltsel, PointerGetDatum(
																 planner),
															 ObjectIdGetDatum(
																 selectivityOpExpr),
															 PointerGetDatum(args),
															 Int32GetDatum(varRelId)));

			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL:
		{
			args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
															 rightValue)));
			selectivity = DatumGetFloat8(DirectFunctionCall4(scalarlesel, PointerGetDatum(
																 planner),
															 ObjectIdGetDatum(
																 selectivityOpExpr),
															 PointerGetDatum(args),
															 Int32GetDatum(varRelId)));
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_NOT_EQUAL:
		{
			args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
															 rightValue)));
			selectivity = DatumGetFloat8(DirectFunctionCall4(neqsel, PointerGetDatum(
																 planner),
															 ObjectIdGetDatum(
																 selectivityOpExpr),
															 PointerGetDatum(args),
															 Int32GetDatum(varRelId)));
			break;
		}

		/* For all other cases use the default generic selectivity which clamps at 0.0001 selectivity. */
		default:
		{
			args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
															 rightValue)));
			selectivity = generic_restriction_selectivity(planner, selectivityOpExpr,
														  collation, args, varRelId,
														  defaultInputSelectivity);
			break;
		}
	}

	list_free(args);

	/* Clamp the selectivity to a valid range [0.0, 1.0] */
	CLAMP_PROBABILITY(selectivity);
	return selectivity;
}


double
GetDollarOperatorSelectivity(PlannerInfo *planner, Oid selectivityOpExpr,
							 List *args, Oid collation, int varRelId,
							 double defaultExprSelectivity)
{
	/* Special case, check if it's a full scan */
	DollarRangeParams params = { 0 };
	if (selectivityOpExpr == BsonRangeMatchOperatorOid() &&
		TryGetRangeParamsForRangeArgs(args, &params))
	{
		if (params.isFullScan)
		{
			return 1.0;
		}

		if (params.isElemMatch)
		{
			/* Since elemMatch runtime evaluation is not implemented yet, the generic_restriction_selectivity
			 * yields a selectivity of 1.0 for small docs.
			 * TODO: Once elemMatch runtime selectivity is enabled - remove this logic.
			 */
			pgbsonelement elemMatchElement;
			BsonIndexStrategy indexStrategyIgnore = BSON_INDEX_STRATEGY_INVALID;
			return GetStatisticsNoStatsData(args, selectivityOpExpr,
											defaultExprSelectivity, &elemMatchElement,
											&indexStrategyIgnore);
		}
	}

	bool isPerCollectionStatsEnabled = false;
	if (!EnablePlannerCostSelectivityExtended(planner, args,
											  &isPerCollectionStatsEnabled))
	{
		return GetDisableStatisticSelectivity(args, defaultExprSelectivity);
	}

	pgbsonelement dollarElement;
	BsonIndexStrategy indexStrategy = BSON_INDEX_STRATEGY_INVALID;
	double defaultInputSelectivity = GetStatisticsNoStatsData(args, selectivityOpExpr,
															  defaultExprSelectivity,
															  &dollarElement,
															  &indexStrategy);

	/*
	 * This is Postgres's default selectivity implementation that looks at statistics
	 * and gets the Most common values/ histograms and gets the overall selectivity
	 * from the raw table.
	 */
	double selectivity;
	if (isPerCollectionStatsEnabled &&
		list_length(args) == 2 && dollarElement.bsonValue.value_type != BSON_TYPE_EOD)
	{
		/* update the args to contain the right value for the LHS to pick up the selectivity */
		Const *pathValue = MakeTextConst(dollarElement.path,
										 dollarElement.pathLength);
		List *pathArgs = list_make2(linitial(args), pathValue);
		Node *updatedExpr = (Node *) makeFuncExpr(BsonStatsProjectFuncOid(),
												  BsonTypeId(), pathArgs,
												  InvalidOid,
												  DEFAULT_COLLATION_OID,
												  COERCE_EXPLICIT_CALL);

		selectivity = GetCustomStatisticsSelectivity(planner, indexStrategy,
													 selectivityOpExpr,
													 updatedExpr,
													 &dollarElement.bsonValue,
													 varRelId, collation,
													 defaultInputSelectivity);

		list_free(pathArgs);
		pfree(pathValue);
	}
	else
	{
		selectivity = generic_restriction_selectivity(
			planner, selectivityOpExpr, collation, args, varRelId,
			defaultInputSelectivity);
	}

	return selectivity;
}


/*
 * Legacy function for compat to restore prior value to
 * implementing selectivity.
 */
static double
GetStatisticsNoStatsData(List *args, Oid selectivityOpExpr, double defaultExprSelectivity,
						 pgbsonelement *outputDollarElement,
						 BsonIndexStrategy *outputIndexStrategy)
{
	outputDollarElement->bsonValue.value_type = BSON_TYPE_EOD;
	*outputIndexStrategy = BSON_INDEX_STRATEGY_INVALID;

	if (list_length(args) != 2)
	{
		/* this is not one of the default operators - return Postgres's default values */
		return defaultExprSelectivity;
	}

	Node *secondNode = lsecond(args);
	if (!IsA(secondNode, Const))
	{
		if (IsLookupExtractFuncExpr(secondNode))
		{
			/* This means a lookup modified index qual, consider low selectivity */
			return LowSelectivity;
		}

		/* Can't determine anything here */
		return defaultExprSelectivity;
	}

	Const *secondConst = (Const *) secondNode;
	BsonIndexStrategy indexStrategy = BSON_INDEX_STRATEGY_INVALID;
	if (secondConst->consttype == BsonQueryTypeId())
	{
		Oid selectFuncId = get_opcode(selectivityOpExpr);
		const MongoIndexOperatorInfo *indexOp = GetMongoIndexOperatorInfoByPostgresFuncId(
			selectFuncId);
		indexStrategy = indexOp->indexStrategy;
	}
	else
	{
		/* This is an index pushdown operator */
		const MongoIndexOperatorInfo *indexOp = GetMongoIndexOperatorByPostgresOperatorId(
			selectivityOpExpr);
		indexStrategy = indexOp->indexStrategy;
	}

	if (indexStrategy == BSON_INDEX_STRATEGY_INVALID)
	{
		if (selectivityOpExpr == BsonRangeMatchOperatorOid())
		{
			indexStrategy = BSON_INDEX_STRATEGY_DOLLAR_RANGE;
		}
		else
		{
			/* Unknown - thunk to PG value */
			return defaultExprSelectivity;
		}
	}

	*outputIndexStrategy = indexStrategy;

	pgbsonelement dollarElement;
	PgbsonToSinglePgbsonElement(
		DatumGetPgBson(secondConst->constvalue), &dollarElement);

	*outputDollarElement = dollarElement;
	switch (indexStrategy)
	{
		case BSON_INDEX_STRATEGY_DOLLAR_EQUAL:
		{
			if (dollarElement.bsonValue.value_type == BSON_TYPE_NULL ||
				dollarElement.bsonValue.value_type == BSON_TYPE_BOOL)
			{
				/* $eq: null matches paths that don't exist: presume normal selectivity */
				return defaultExprSelectivity;
			}

			/* Use prior value - assume $eq supports lower selectivity */
			return LowSelectivity;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_NOT_IN:
		case BSON_INDEX_STRATEGY_DOLLAR_NOT_EQUAL:
		{
			return HighSelectivity;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_EXISTS:
		{
			/* Inverse selectivity of $eq or general exists check
			 * so assume high selectivity. Exists false should return the same selectivity as
			 * equals null above.
			 */
			int32_t value = BsonValueAsInt32(&dollarElement.bsonValue);
			return value > 0 ? HighSelectivity : defaultExprSelectivity;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_IN:
		{
			if (dollarElement.bsonValue.value_type == BSON_TYPE_ARRAY)
			{
				int inElements = BsonDocumentValueCountKeys(&dollarElement.bsonValue);

				/* $in is basically N $eq - selectivity is multiplied */
				return Min(inElements * LowSelectivity, HighSelectivity);
			}

			return defaultExprSelectivity;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_RANGE:
		{
			/* Since $range does a $gt/$lt together, assume that it gives you
			 * half the selectivity of each $gt/$lt.
			 */
			DollarRangeParams rangeParams = { 0 };
			InitializeQueryDollarRange(&dollarElement.bsonValue, &rangeParams);
			if (rangeParams.isFullScan)
			{
				return 1.0;
			}

			if (rangeParams.isElemMatch)
			{
				int32_t elemMatchStrategy = BSON_INDEX_STRATEGY_INVALID;
				bool hasEqualityPrefix = false;
				bool hasNonEqualityPrefix = false;
				ElemMatchIndexOpStrategyClassify(&rangeParams, &elemMatchStrategy,
												 &hasEqualityPrefix,
												 &hasNonEqualityPrefix);

				/* If the elemMatch has an equality prefix, then we can assume the selectivity is similar to an equality match */
				return hasEqualityPrefix ? LowSelectivity : defaultExprSelectivity;
			}

			return defaultExprSelectivity / 2;
		}

		default:
		{
			return defaultExprSelectivity;
		}
	}
}


/*
 * Legacy function for compat to restore prior value to
 * implementing selectivity.
 */
static double
GetDisableStatisticSelectivity(List *args, double defaultExprSelectivity)
{
	if (list_length(args) != 2)
	{
		/* this is not one of the default operators - return Postgres's default values */
		return defaultExprSelectivity;
	}

	Node *secondNode = lsecond(args);
	if (!IsA(secondNode, Const))
	{
		if (IsLookupExtractFuncExpr(secondNode))
		{
			/* This means a lookup modified index qual, consider low selectivity */
			return LowSelectivity;
		}

		/* Can't determine anything here */
		return defaultExprSelectivity;
	}

	Const *secondConst = (Const *) secondNode;
	if (secondConst->consttype == BsonQueryTypeId())
	{
		/* These didn't have a restrict info so they were using the PG default*/
		return defaultExprSelectivity;
	}
	else
	{
		/* These were the default Selectivity value for $operators */
		return LowSelectivity;
	}
}


static int32_t
CompareBsonValuesSort(const void *a, const void *b)
{
	const bson_value_t *valueA = (const bson_value_t *) a;
	const bson_value_t *valueB = (const bson_value_t *) b;

	bool isComparisonValid = false;
	return CompareBsonValueAndType(valueA, valueB, &isComparisonValid);
}


static int32_t
CompareBsonValuesSortWithArg(const void *a, const void *b, void *arg)
{
	return CompareBsonValuesSort(a, b);
}


/*
 * This is the projection function that managed statistics for filters in the documents table.
 * This provides a similar functionality to expression indexes against documentdb indexes for stats collections.
 * Note: This varies from the projection function since allocations here must be managed extremely carefully
 * and must be freed agressively to prevent OOMs in Analyze.
 * Note that this OOM is fixed in Pg17 but any prior versions will need to exercise caution.
 */
Datum
bson_stats_project(PG_FUNCTION_ARGS)
{
	pgbson *document = PG_GETARG_PGBSON_PACKED(0);
	text *queryPath = PG_GETARG_TEXT_PP(1);

	StringView queryStringView = CreateStringViewFromText(queryPath);

	/* Traverse the path using the BSON traversal framework which handles
	 * intermediate arrays by visiting each element.
	 * TODO: This is lossy on array path indexes (e.g. a.b.0.1 will track as a field of 0): Fix this as well
	 */
	bson_iter_t iter;
	pgbson *resultBson;
	StatsProjectState state = { 0 };
	state.maxAllowedSamples = Min(ArrayStatisticsMaxSampleCount,
								  ARRAY_STATISTICS_MAX_SAMPLE_COUNT);

	PgbsonInitIterator(document, &iter);
	TraverseBsonPathStringView(&iter, &queryStringView, &state,
							   &StatsProjectExecutionFuncs);

	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	if (state.sampleCount == 0)
	{
		PgbsonWriterAppendNull(&writer, "", 0);
	}
	else if (state.sampleCount == 1)
	{
		PgbsonWriterAppendValue(&writer, "", 0, &state.samples[0]);
	}
	else
	{
		pgbson_array_writer arrayWriter;
		PgbsonWriterStartArray(&writer, "", 0, &arrayWriter);
		for (int i = 0; i < state.sampleCount; i++)
		{
			if (i > 0 && CompareBsonValuesSort(&state.samples[i - 1],
											   &state.samples[i]) == 0)
			{
				/* Skip duplicate values */
				continue;
			}

			if (PgbsonArrayWriterGetSize(&arrayWriter) >= MAX_SCALAR_TYPE_ANALYZE_SIZE)
			{
				/* Stop adding values if the array is full and would cause the stats to get skipped */
				break;
			}

			PgbsonArrayWriterWriteValue(&arrayWriter, &state.samples[i]);
		}

		PgbsonWriterEndArray(&writer, &arrayWriter);
	}

	resultBson = PgbsonWriterGetPgbson(&writer);
	PG_FREE_IF_COPY(document, 0);
	PG_FREE_IF_COPY(queryPath, 1);
	PG_RETURN_POINTER(resultBson);
}


static void
AddValueToSamples(StatsProjectState *projectState, const bson_value_t *value)
{
	if (projectState->sampleCount >= projectState->maxAllowedSamples)
	{
		return;
	}

	int32_t index = BinarySearchWithMissingPositionCheck(projectState->samples, 0,
														 projectState->sampleCount,
														 sizeof(bson_value_t), value,
														 CompareBsonValuesSortWithArg,
														 NULL);

	if (index >= 0)
	{
		/* Value already exists, do nothing */
		return;
	}

	/* Value should be inserted at ~index */
	index = ~index;
	if (index < projectState->sampleCount)
	{
		memmove(&projectState->samples[index + 1], &projectState->samples[index],
				(projectState->sampleCount - index) * sizeof(bson_value_t));
	}

	projectState->samples[index] = *value;
	projectState->sampleCount++;
}


static bool
StatsProjectVisitTopLevelField(pgbsonelement *element, const StringView *traversePath,
							   void *state)
{
	StatsProjectState *projectState = (StatsProjectState *) state;
	if (element->bsonValue.value_type != BSON_TYPE_ARRAY ||
		IsBsonValueEmptyArray(&element->bsonValue))
	{
		AddValueToSamples(projectState, &element->bsonValue);
	}

	return true;
}


static bool
StatsProjectContinueProcessingIntermediateArray(void *state, const bson_value_t *value,
												bool
												isArrayIndexSearch)
{
	return true;
}


static bool
StatsProjectVisitArrayField(pgbsonelement *element, const StringView *traversePath, int
							arrayIndex, void *state)
{
	StatsProjectState *projectState = (StatsProjectState *) state;
	AddValueToSamples(projectState, &element->bsonValue);
	return true;
}


static void
StatsSetIntermediateArrayStartEnd(void *state, bool isStart)
{ }


static void
StatsHandleIntermediateArrayPathNotFound(void *state, int32_t arrayIndex, const
										 StringView *remainingPath)
{
	StatsProjectState *projectState = (StatsProjectState *) state;

	/* Write null to indicate a missing value */
	bson_value_t nullValue = { .value_type = BSON_TYPE_NULL };
	AddValueToSamples(projectState, &nullValue);
}


/*
 * Test function for the bson stats project with memory checking.
 * Creates a temporary memory context, calls bson_stats_project in a loop,
 * validates that memory is fully freed after a single reset, returns the last result.
 */
Datum
test_bson_stats_project_with_memcheck(PG_FUNCTION_ARGS)
{
	Datum documentDatum = PG_GETARG_DATUM(0);
	Datum queryPathDatum = PG_GETARG_DATUM(1);
	int32 loopCount = PG_GETARG_INT32(2);

	MemoryContext oldContext = CurrentMemoryContext;
	MemoryContext tempContext = AllocSetContextCreate(oldContext,
													  "StatsProjectMemCheck",
													  ALLOCSET_DEFAULT_SIZES);

	/* Record baseline memory (keeper block) */
	Size baselineMemory = MemoryContextMemAllocated(tempContext, true);

	MemoryContextSwitchTo(tempContext);

	for (int i = 0; i < loopCount; i++)
	{
		LOCAL_FCINFO(innerFcinfo, 2);
		InitFunctionCallInfoData(*innerFcinfo, NULL, 2, InvalidOid, NULL, NULL);
		innerFcinfo->args[0].value = documentDatum;
		innerFcinfo->args[0].isnull = false;
		innerFcinfo->args[1].value = queryPathDatum;
		innerFcinfo->args[1].isnull = false;

		Datum iterResult = bson_stats_project(innerFcinfo);
		pfree(DatumGetPointer(iterResult));
	}

	MemoryContextSwitchTo(oldContext);

	/* Verify no leaked allocations beyond the keeper block */
	Size memAllocated = MemoryContextMemAllocated(tempContext, true);
	if (memAllocated != baselineMemory)
	{
		ereport(ERROR,
				(errmsg("Memory leak detected: %zu bytes allocated vs %zu baseline",
						memAllocated, baselineMemory)));
	}

	MemoryContextDelete(tempContext);

	/* Run one final time in the caller's context to get the return value */
	LOCAL_FCINFO(finalFcinfo, 2);
	InitFunctionCallInfoData(*finalFcinfo, NULL, 2, InvalidOid, NULL, NULL);
	finalFcinfo->args[0].value = documentDatum;
	finalFcinfo->args[0].isnull = false;
	finalFcinfo->args[1].value = queryPathDatum;
	finalFcinfo->args[1].isnull = false;

	Datum result = bson_stats_project(finalFcinfo);

	PG_RETURN_DATUM(result);
}


void
GetCorrelationFromStatistics(PlannerInfo *root, IndexPath *path,
							 double *indexCorrelation)
{
	if (!EnableIndexCorrelationFromStatistics)
	{
		return;
	}

	bool isWildCardIndex = false;
	const char *firstPath = GetFirstPathFromIndexOptionsIfApplicable(
		path->indexinfo->opclassoptions[0], &isWildCardIndex);
	if (isWildCardIndex || firstPath == NULL || path->path.parent == NULL ||
		path->path.parent->statlist == NIL)
	{
		return;
	}

	int32_t numPaths = GetCompositeOpClassPathCount(path->indexinfo->opclassoptions[0]);
	StatisticExtInfo *foundStatistic = NULL;
	ListCell *cell;
	foreach(cell, path->path.parent->statlist)
	{
		StatisticExtInfo *stat = (StatisticExtInfo *) lfirst(cell);

		if (stat->exprs == NULL || list_length(stat->exprs) < 1)
		{
			continue;
		}

		Expr *statExpr = (Expr *) linitial(stat->exprs);
		if (!IsA(statExpr, FuncExpr))
		{
			continue;
		}

		FuncExpr *funcExpr = (FuncExpr *) statExpr;
		if (funcExpr->funcid != BsonStatsProjectFuncOid())
		{
			continue;
		}

		Expr *secondArg = lsecond(funcExpr->args);
		if (!IsA(secondArg, Const))
		{
			continue;
		}

		Const *constArg = (Const *) secondArg;
		if (constArg->consttype != TEXTOID)
		{
			continue;
		}

		StringView statPath = CreateStringViewFromText(DatumGetTextPP(
														   constArg->constvalue));
		if (!StringViewEqualsCString(&statPath, firstPath))
		{
			continue;
		}

		/* found a matching statistic */
		foundStatistic = stat;
		break;
	}

	if (foundStatistic != NULL)
	{
		RangeTblEntry *rte = planner_rt_fetch(path->path.parent->relid, root);
		VariableStatData vardata;
		vardata.statsTuple =
			statext_expressions_load(foundStatistic->statOid, rte->inh, 0);

		Oid sortop;
		AttStatsSlot sslot;

		sortop = get_opfamily_member(BsonBtreeOpFamilyOid(),
									 BsonTypeId(),
									 BsonTypeId(),
									 BTLessStrategyNumber);
		if (OidIsValid(sortop) &&
			get_attstatsslot(&sslot, vardata.statsTuple,
							 STATISTIC_KIND_CORRELATION, sortop,
							 ATTSTATSSLOT_NUMBERS))
		{
			double varCorrelation;
			Assert(sslot.nnumbers == 1);
			varCorrelation = sslot.numbers[0];
			free_attstatsslot(&sslot);

			/* Now set the index correlation */
			if (numPaths > 1)
			{
				/* Adjust correlation for composite indexes with multiple paths
				 * simliar to btree.
				 */
				varCorrelation = varCorrelation * 0.75;
			}

			ScanDirection indexScanDir = GetIndexScanDirectionForComposite(
				path->indexinfo->opclassoptions[0]);

			/* If there are sorts, find the sort direction & flip the correlation if needed */
			if (path->path.pathkeys != NIL)
			{
				PathKey *pathKey = linitial(path->path.pathkeys);
				ScanDirection sortScanDir =
					SortPathKeyStrategy(pathKey) == BTGreaterStrategyNumber
					? BackwardScanDirection : ForwardScanDirection;

				/* Combine the scan directions (Desc * Desc = Asc, Desc * Asc = Desc, etc.) */
				ScanDirection effectiveDirection = sortScanDir * indexScanDir;
				if (effectiveDirection == BackwardScanDirection)
				{
					/* If the effective direction is backward, invert the correlation */
					varCorrelation = -varCorrelation;
				}
			}
			else if (indexScanDir == BackwardScanDirection)
			{
				/* If the index is a descending index, the correlation will be inverted from the stats */
				varCorrelation = -varCorrelation;
			}

			*indexCorrelation = varCorrelation;
		}

		pfree(vardata.statsTuple);
	}
}
