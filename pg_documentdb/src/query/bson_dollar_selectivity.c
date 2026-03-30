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
#include <catalog/pg_collation.h>
#include <nodes/pathnodes.h>
#include <nodes/makefuncs.h>
#include <utils/selfuncs.h>
#include <parser/parsetree.h>
#include <optimizer/pathnode.h>
#include <metadata/metadata_cache.h>
#include <planner/mongo_query_operator.h>

#include "query/bson_dollar_selectivity.h"
#include "aggregation/bson_query_common.h"
#include "utils/docdb_make_funcs.h"
#include "utils/version_utils.h"

extern bool EnablePerCollectionPlannerStatistics;
extern bool EnableCompositeIndexPlanner;
extern bool LowSelectivityForLookup;

static double GetStatisticsNoStatsData(List *args, Oid selectivityOpExpr, double
									   defaultExprSelectivity,
									   pgbsonelement *outputDollarElement);

static double GetDisableStatisticSelectivity(List *args, double
											 defaultDisabledSelectivity);

PG_FUNCTION_INFO_V1(bson_dollar_selectivity);
PG_FUNCTION_INFO_V1(bson_stats_project);


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
		IsClusterVersionAtleast(DocDB_V0, 111, 0) &&
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
		IsClusterVersionAtleast(DocDB_V0, 111, 0) &&
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
			return GetStatisticsNoStatsData(args, selectivityOpExpr,
											defaultExprSelectivity, &elemMatchElement);
		}
	}

	bool isPerCollectionStatsEnabled = false;
	if (!EnablePlannerCostSelectivityExtended(planner, args,
											  &isPerCollectionStatsEnabled))
	{
		return GetDisableStatisticSelectivity(args, defaultExprSelectivity);
	}

	pgbsonelement dollarElement;
	double defaultInputSelectivity = GetStatisticsNoStatsData(args, selectivityOpExpr,
															  defaultExprSelectivity,
															  &dollarElement);

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
		Const *bsonConst = MakeBsonConst(BsonValueToDocumentPgbson(
											 &dollarElement.bsonValue));
		List *pathArgs = list_make2(linitial(args), pathValue);
		Node *updatedExpr = (Node *) makeFuncExpr(BsonStatsProjectFuncOid(),
												  BsonTypeId(), pathArgs,
												  InvalidOid,
												  DEFAULT_COLLATION_OID,
												  COERCE_EXPLICIT_CALL);
		List *newArgs = list_make2(updatedExpr, bsonConst);
		selectivity = generic_restriction_selectivity(
			planner, selectivityOpExpr, collation, newArgs, varRelId,
			defaultInputSelectivity);
		list_free_deep(newArgs);
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
						 pgbsonelement *outputDollarElement)
{
	outputDollarElement->bsonValue.value_type = BSON_TYPE_EOD;
	if (list_length(args) != 2)
	{
		/* this is not one of the default operators - return Postgres's default values */
		return defaultExprSelectivity;
	}

	Node *secondNode = lsecond(args);
	if (!IsA(secondNode, Const))
	{
		if (LowSelectivityForLookup &&
			IsLookupExtractFuncExpr(secondNode))
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
		if (LowSelectivityForLookup &&
			IsLookupExtractFuncExpr(secondNode))
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

	char *queryString = text_to_cstring(queryPath);

	/* For now, we do direct projection of the incoming path. Any intermediate arrays
	 * are not handled at the moment.
	 * TODO: handle intermediate array paths as well.'
	 * TODO: This is also lossy on array path indexes (e.g. a.b.0.1 will track as a field of 0): Fix this as well
	 */
	bson_iter_t iter;
	pgbson *resultBson;
	if (PgbsonInitIteratorAtPath(document, queryString, &iter))
	{
		pgbson_writer writer;
		PgbsonWriterInit(&writer);
		PgbsonWriterAppendValue(&writer, "", 0, bson_iter_value(&iter));
		resultBson = PgbsonWriterGetPgbson(&writer);
	}
	else
	{
		resultBson = NULL;
	}

	pfree(queryString);
	PG_FREE_IF_COPY(document, 0);
	PG_FREE_IF_COPY(queryPath, 1);

	if (resultBson == NULL)
	{
		PG_RETURN_NULL();
	}

	PG_RETURN_POINTER(resultBson);
}
