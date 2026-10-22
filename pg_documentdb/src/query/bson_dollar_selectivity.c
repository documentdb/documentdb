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
#include <optimizer/optimizer.h>
#include <metadata/metadata_cache.h>
#include <planner/mongo_query_operator.h>
#include <query/bson_compare.h>
#include <utils/search_utils.h>
#include <catalog/pg_statistic_ext.h>
#include <catalog/pg_statistic.h>
#include <statistics/statistics.h>
#include <utils/fmgrprotos.h>

#include "query/bson_dollar_selectivity.h"
#include "planner/selectivity.h"
#include "opclass/bson_gin_composite_scan.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "opclass/bson_gin_index_types_core.h"
#include "aggregation/bson_query_common.h"
#include "query/query_operator.h"
#include "utils/docdb_make_funcs.h"
#include "utils/hashset_utils.h"
#include "utils/version_utils.h"
#include "io/bson_traversal.h"
#include "api_hooks.h"

extern bool EnablePerCollectionPlannerStatistics;
extern bool EnableCompositeIndexPlanner;
extern bool EnableIndexCorrelationFromStatistics;
extern bool EnableLookupJoinSelectivityFromStats;
extern bool EnableElemMatchSelectivityFromStats;
extern bool EnableElemMatchSelectivityLowerBound;
extern bool EnableArrayBsonStatsWithPlannerStatistics;
extern bool EnableInGranularSelectivity;
extern bool BsonStatsEnableArrayValueUnpack;
extern int MaxInGranularSelectivityInputSizeBytes;
extern bool EnableOrderByIdOnCostFunction;
extern bool EnableOrderByIdOnCostFunctionWithStats;

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

static double GetStatisticsNoStatsData(List *args, Oid selectivityOpExpr, double
									   defaultExprSelectivity,
									   pgbsonelement *outputDollarElement,
									   BsonIndexStrategy *outputIndexStrategy);

static double GetDisableStatisticSelectivity(List *args, double
											 defaultDisabledSelectivity);

static Oid GetNativeStatsBtreeOperatorForIndexStrategy(BsonIndexStrategy strategy);

static bool TryBuildElemMatchStatsClauses(List *clauses,
										  const pgbsonelement *elemMatchElement,
										  Node *documentExpr,
										  Oid collation,
										  List **statsClauses);

static bool TryGetElemMatchSelectivity(PlannerInfo *planner,
									   Node *documentExpr,
									   const pgbsonelement *elemMatchElement,
									   int varRelId, Oid collation,
									   double *selectivity);

static bool TryGetElemMatchIndexSelectivity(PlannerInfo *planner,
											Node *documentExpr,
											const pgbsonelement *elemMatchElement,
											const DollarRangeParams *rangeParams,
											int varRelId,
											double *selectivity);

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

static bool ShouldEnableBsonStatsArrayValueUnpack(void);

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
 * Registers the hooks that control how bson statistics are collected.
 */
void
RegisterBsonStatisticsHooks(void)
{
	should_enable_bson_stats_array_value_unpack_hook =
		ShouldEnableBsonStatsArrayValueUnpack;
}


/*
 * Array value unpacking during ANALYZE is enabled either by the core GUC, or
 * when planner statistics for new collections and the feature flag are both
 * enabled.
 */
static bool
ShouldEnableBsonStatsArrayValueUnpack(void)
{
	return BsonStatsEnableArrayValueUnpack ||
		   (ShouldEnablePlannerStatisticsNewCollections() &&
			EnableArrayBsonStatsWithPlannerStatistics);
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


/*
 * IsBtreeBsonSelectivityFromStatsEnabledForRelation returns whether btree
 * selectivity can use statistics for the relation. This intentionally ignores
 * the composite index planner GUC.
 */
bool
IsBtreeBsonSelectivityFromStatsEnabledForRelation(PlannerInfo *planner,
												  RelOptInfo *rel)
{
	bool isPerCollectionStatsEnabled = false;
	EnablePlannerCostSelectivityFromRelOptInfoCore(planner, rel,
												   &isPerCollectionStatsEnabled);
	return isPerCollectionStatsEnabled ||
		   IsBtreeBsonSelectivityFromStatsEnabled();
}


bool
ShouldEnableOrderByIdOnCostFunction(PlannerInfo *root, RelOptInfo *rel)
{
	if (EnableOrderByIdOnCostFunction)
	{
		return true;
	}

	if (EnableOrderByIdOnCostFunctionWithStats &&
		IsBtreeBsonSelectivityFromStatsEnabledForRelation(root, rel))
	{
		return true;
	}

	return false;
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


/*
 * Computes the join selectivity for a lookup join filter from the collected
 * statistics on the two joined paths.
 *
 * The lookup join filter is a plain boolean function rather than an equality
 * operator, so the standard estimator never sees it and the planner would
 * otherwise fall back to a fixed selectivity that ignores cardinality. This
 * rewrites the filter into an equality between the two extracted paths and
 * asks the standard estimator for a number, so a high cardinality path
 * estimates the small number of matching rows it actually has.
 *
 * Returns the fixed low selectivity fallback when the shape is not recognized,
 * when statistics are unavailable, or when the behavior is disabled.
 */
double
GetCustomStatisticsSelectivityForLookup(Oid funcExpr, List *funcArgs,
										SpecialJoinInfo *sjinfo,
										PlannerInfo *planner, JoinType joinType,
										int varRelid)
{
	if (!EnableLookupJoinSelectivityFromStats)
	{
		return LowSelectivity;
	}

	Expr *leftDocExpr = linitial(funcArgs);
	Expr *pathExpr = lthird(funcArgs);
	Expr *joinExpr = lsecond(funcArgs);

	if (IsA(leftDocExpr, Var) &&
		IsA(pathExpr, Const) &&
		IsA(joinExpr, FuncExpr))
	{
		FuncExpr *joinFunc = (FuncExpr *) joinExpr;
		if (joinFunc->funcid ==
			DocumentDBApiInternalBsonLookupExtractFilterExpressionFunctionOid() &&
			list_length(joinFunc->args) >= 2)
		{
			Expr *rightDocExpr = linitial(joinFunc->args);
			Expr *rightPathExpr = lsecond(joinFunc->args);

			if ((IsA(rightDocExpr, Var) || IsA(rightDocExpr, Param)) &&
				IsA(rightPathExpr, Const))
			{
				Var *leftVar = castNode(Var, leftDocExpr);
				RelOptInfo *leftRel = find_base_rel(planner, leftVar->varno);

				if (!EnablePlannerCostSelectivityFromRelOptInfo(planner, leftRel))
				{
					/* Default if planner stats is not available */
					return LowSelectivity;
				}

				/* Form the OpExpr for the $lookup join. We write the lookup join to be of the form
				 * bson_stats_project(document, 'pathExpr') = bson_stats_project(document, 'pathexpr')
				 * and then apply eqjoinsel for it.
				 */
				pgbson *extractBson = DatumGetPgBson(
					((Const *) rightPathExpr)->constvalue);
				pgbsonelement pgbsonElement;
				PgbsonToSinglePgbsonElementWithCollation(extractBson,
														 &pgbsonElement);

				Const *rightFilterConst = MakeTextConst(pgbsonElement.path,
														pgbsonElement.pathLength);

				FuncExpr *leftFunc = makeFuncExpr(BsonStatsProjectFuncOid(),
												  BsonTypeId(), list_make2(
													  leftDocExpr, pathExpr),
												  InvalidOid,
												  DEFAULT_COLLATION_OID,
												  COERCE_EXPLICIT_CALL);
				FuncExpr *rightFunc = makeFuncExpr(BsonStatsProjectFuncOid(),
												   BsonTypeId(), list_make2(
													   rightDocExpr,
													   rightFilterConst),
												   InvalidOid,
												   DEFAULT_COLLATION_OID,
												   COERCE_EXPLICIT_CALL);

				float8 joinSelectivity;
				if (sjinfo != NULL)
				{
					Datum joinSel = DirectFunctionCall5(eqjoinsel,
														PointerGetDatum(planner),
														ObjectIdGetDatum(
															BsonEqualOperatorId()),
														PointerGetDatum(
															list_make2(leftFunc,
																	   rightFunc)),
														Int32GetDatum(
															joinType),
														PointerGetDatum(
															sjinfo));
					joinSelectivity = DatumGetFloat8(joinSel);
				}
				else
				{
					joinSelectivity = DatumGetFloat8(
						DirectFunctionCall4(eqsel, PointerGetDatum(planner),
											ObjectIdGetDatum(
												BsonEqualOperatorId()),
											PointerGetDatum(list_make2(leftFunc,
																	   rightFunc)),
											Int32GetDatum(varRelid)));
				}

				CLAMP_PROBABILITY(joinSelectivity);
				return joinSelectivity;
			}
		}
	}

	return LowSelectivity;
}


/*
 * Estimate $in by combining the selectivity of each distinct array element.
 * This follows PostgreSQL's scalararraysel() approach for "= ANY": maintain
 * both an independence estimate and, for distinct equality values, a
 * disjoint-probability sum. Prefer the disjoint sum when it is in [0, 1],
 * otherwise retain the independence estimate. Regex elements use the regex
 * operator's generic estimator and disable the disjoint assumption because
 * regex matches can overlap literals or other regexes. $nin is the complement
 * of the resulting $in estimate.
 */
static double
GetDollarInCustomSelectivity(PlannerInfo *planner,
							 Node *leftOperand,
							 const bson_value_t *rightValue,
							 Oid selectivityOpExpr,
							 Oid collation,
							 int varRelId,
							 double defaultInputSelectivity,
							 bool isNotIn)
{
	if (rightValue->value_type != BSON_TYPE_ARRAY)
	{
		ereport(ERROR, errmsg(
					"Unexpected non-array value for $in/$nin during selectivity estimation."));
	}

	if (EnableInGranularSelectivity && ShouldEnableBsonStatsArrayValueUnpack() &&
		rightValue->value.v_doc.data_len <=
		(uint32_t) MaxInGranularSelectivityInputSizeBytes)
	{
		double selectivity = 0.0;

		bson_iter_t arrayIter;
		BsonValueInitIterator(rightValue, &arrayIter);

		double disjointSelectivity = 0.0;
		double perItemSelectivity = 0.0;
		bool hasRegex = false;
		Oid regexOperatorOid = InvalidOid;
		int i = 0;
		Const *inValueConst = NULL;

		/* TODO: Collation needs to handle deduplication of values. */
		HTAB *seenValues = CreateBsonValueHashSet();
		List *args = NIL;
		while (bson_iter_next(&arrayIter))
		{
			CHECK_FOR_INTERRUPTS();

			const bson_value_t *inElement = bson_iter_value(&arrayIter);

			bool found = false;
			hash_search(seenValues, inElement, HASH_ENTER, &found);

			if (found)
			{
				continue;
			}

			if (i == 0)
			{
				inValueConst = MakeBsonConst(BsonValueToDocumentPgbson(inElement));
				args = list_make2(leftOperand, inValueConst);
			}
			else
			{
				inValueConst = lsecond(args);
				pfree(DatumGetPointer(inValueConst->constvalue));
				inValueConst->constvalue = PointerGetDatum(BsonValueToDocumentPgbson(
															   inElement));
			}

			if (inElement->value_type == BSON_TYPE_REGEX)
			{
				if (!OidIsValid(regexOperatorOid))
				{
					const MongoIndexOperatorInfo *regexOperator =
						GetMongoIndexOperatorInfoByOperatorType(QUERY_OPERATOR_REGEX);
					regexOperatorOid = GetMongoQueryOperatorOid(regexOperator);
				}

				const double defaultPerItemRegexSelectivity = 0.0;
				perItemSelectivity = generic_restriction_selectivity(
					planner, regexOperatorOid, collation, args, varRelId,
					defaultPerItemRegexSelectivity);
				hasRegex = true;
			}
			else
			{
				perItemSelectivity = DatumGetFloat8(DirectFunctionCall4(eqsel,
																		PointerGetDatum(
																			planner),
																		ObjectIdGetDatum(
																			BsonEqualOperatorId()),
																		PointerGetDatum(
																			args),
																		Int32GetDatum(
																			varRelId)));
			}

			selectivity = selectivity + perItemSelectivity - selectivity *
						  perItemSelectivity;
			disjointSelectivity += perItemSelectivity;

			i++;
		}

		if (!hasRegex &&
			disjointSelectivity >= 0.0 && disjointSelectivity <= 1.0)
		{
			selectivity = disjointSelectivity;
		}

		if (isNotIn)
		{
			CLAMP_PROBABILITY(selectivity);
			selectivity = 1.0 - selectivity;
		}

		if (inValueConst != NULL)
		{
			pfree(DatumGetPointer(inValueConst->constvalue));
			pfree(inValueConst);
		}

		if (seenValues != NULL)
		{
			hash_destroy(seenValues);
		}

		list_free(args);
		return selectivity;
	}

	List *args = list_make2(leftOperand, MakeBsonConst(BsonValueToDocumentPgbson(
														   rightValue)));
	double selectivity = generic_restriction_selectivity(planner, selectivityOpExpr,
														 collation, args, varRelId,
														 defaultInputSelectivity);
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

		case BSON_INDEX_STRATEGY_DOLLAR_IN:
		{
			bool isNotIn = false;
			selectivity = GetDollarInCustomSelectivity(planner, leftOperand, rightValue,
													   selectivityOpExpr, collation,
													   varRelId, defaultInputSelectivity,
													   isNotIn);
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_NOT_IN:
		{
			bool isNotIn = true;
			selectivity = GetDollarInCustomSelectivity(planner, leftOperand, rightValue,
													   selectivityOpExpr, collation,
													   varRelId, defaultInputSelectivity,
													   isNotIn);
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


/*
 * TODO: Include query collation when native statistics comparisons support
 * collation-aware values. Callers intentionally omit collation metadata.
 */
static Oid
GetNativeStatsBtreeOperatorForIndexStrategy(BsonIndexStrategy strategy)
{
	switch (strategy)
	{
		case BSON_INDEX_STRATEGY_DOLLAR_EQUAL:
		{
			return BsonNativeStatsBtreeEqualOperatorId();
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER:
		{
			return BsonNativeStatsBtreeGreaterThanOperatorId();
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL:
		{
			return BsonNativeStatsBtreeGreaterThanEqualOperatorId();
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS:
		{
			return BsonNativeStatsBtreeLessThanOperatorId();
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL:
		{
			return BsonNativeStatsBtreeLessThanEqualOperatorId();
		}

		default:
		{
			return InvalidOid;
		}
	}
}


/*
 * Convert the query AST generated for an $elemMatch expression into clauses
 * over bson_stats_project. Reject the whole estimate when any child cannot be
 * represented so unsupported predicates continue to use the legacy fallback.
 */
static bool
TryBuildElemMatchStatsClauses(List *clauses,
							  const pgbsonelement *elemMatchElement,
							  Node *documentExpr, Oid collation,
							  List **statsClauses)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	ListCell *clauseCell;
	foreach(clauseCell, clauses)
	{
		Node *clause = lfirst(clauseCell);
		if (IsA(clause, BoolExpr))
		{
			BoolExpr *boolExpr = (BoolExpr *) clause;
			if (boolExpr->boolop != AND_EXPR ||
				!TryBuildElemMatchStatsClauses(boolExpr->args, elemMatchElement,
											   documentExpr,
											   collation, statsClauses))
			{
				return false;
			}
			continue;
		}

		List *operatorArgs = NIL;
		const MongoQueryOperator *queryOperator =
			GetMongoQueryOperatorFromExpr(clause, &operatorArgs);
		if (!((queryOperator->operatorType >= QUERY_OPERATOR_EQ &&
			   queryOperator->operatorType <= QUERY_OPERATOR_LTE) ||
			  queryOperator->operatorType == QUERY_OPERATOR_REGEX) ||
			list_length(operatorArgs) != 2 ||
			!IsA(lsecond(operatorArgs), Const))
		{
			return false;
		}

		Const *queryConst = lsecond(operatorArgs);
		if (queryConst->constisnull)
		{
			return false;
		}

		pgbsonelement queryElement;
		PgbsonToSinglePgbsonElementWithCollation(
			DatumGetPgBson(queryConst->constvalue), &queryElement);
		if (queryElement.pathLength == elemMatchElement->pathLength &&
			strncmp(queryElement.path, elemMatchElement->path,
					queryElement.pathLength) == 0 &&
			!ShouldEnableBsonStatsArrayValueUnpack())
		{
			/*
			 * Whole-array statistics do not model same-element semantics for a
			 * scalar-array $elemMatch. Retain the legacy estimate until ANALYZE
			 * collects statistics over individual array elements.
			 */
			return false;
		}

		Const *pathValue = MakeTextConst(queryElement.path,
										 queryElement.pathLength);
		List *pathArgs = list_make2(documentExpr, pathValue);
		Expr *statsExpr = (Expr *) makeFuncExpr(BsonStatsProjectFuncOid(),
												BsonTypeId(), pathArgs,
												InvalidOid,
												DEFAULT_COLLATION_OID,
												COERCE_EXPLICIT_CALL);
		Const *valueConst = MakeBsonConst(
			BsonValueToDocumentPgbson(&queryElement.bsonValue));
		Oid statsOperator = InvalidOid;
		if (queryOperator->operatorType == QUERY_OPERATOR_REGEX)
		{
			if (queryElement.bsonValue.value_type != BSON_TYPE_REGEX)
			{
				return false;
			}

			const MongoIndexOperatorInfo *regexOperator =
				GetMongoIndexOperatorInfoByOperatorType(QUERY_OPERATOR_REGEX);
			statsOperator = GetMongoQueryOperatorOid(regexOperator);
		}
		else
		{
			if (queryOperator->operatorType == QUERY_OPERATOR_EQ &&
				(queryElement.bsonValue.value_type == BSON_TYPE_NULL ||
				 queryElement.bsonValue.value_type == BSON_TYPE_BOOL))
			{
				return false;
			}

			const MongoIndexOperatorInfo *indexOperator =
				GetMongoIndexOperatorInfoByOperatorType(queryOperator->operatorType);
			statsOperator = GetNativeStatsBtreeOperatorForIndexStrategy(
				indexOperator->indexStrategy);
			valueConst->consttype = BsonQueryTypeId();
		}

		if (!OidIsValid(statsOperator))
		{
			return false;
		}

		bool operatorReturnsSet = false;
		*statsClauses = lappend(*statsClauses,
								make_opclause(statsOperator, BOOLOID,
											  operatorReturnsSet,
											  statsExpr,
											  (Expr *) valueConst,
											  InvalidOid, collation));
	}

	return true;
}


/*
 * Estimate direct comparison and regex children together so Postgres can
 * combine their selectivities using its standard conjunction handling.
 */
static bool
TryGetElemMatchSelectivity(PlannerInfo *planner, Node *documentExpr,
						   const pgbsonelement *elemMatchElement,
						   int varRelId, Oid collation,
						   double *selectivity)
{
	if (elemMatchElement->bsonValue.value_type != BSON_TYPE_DOCUMENT)
	{
		return false;
	}

	MemoryContext oldContext = CurrentMemoryContext;
	MemoryContext tempContext = AllocSetContextCreate(oldContext,
													  "ElemMatch selectivity",
													  ALLOCSET_DEFAULT_SIZES);
	MemoryContextSwitchTo(tempContext);
	bool foundSelectivity = false;

	BsonQueryOperatorContext context = { 0 };
	BsonQueryOperatorContextCommonBuilder(&context);
	context.documentExpr = (Expr *) documentExpr;
	context.skipObjectArrayFilter = true;

	Expr *elemMatchExpr = CreateQualForBsonExpression(
		&elemMatchElement->bsonValue, elemMatchElement->path, &context);
	List *clauses = make_ands_implicit(elemMatchExpr);
	List *statsClauses = NIL;
	if (TryBuildElemMatchStatsClauses(clauses, elemMatchElement,
									  documentExpr, collation,
									  &statsClauses) &&
		statsClauses != NIL)
	{
		*selectivity = clauselist_selectivity(planner, statsClauses, varRelId,
											  JOIN_INNER, NULL);
		CLAMP_PROBABILITY(*selectivity);
		if (EnableElemMatchSelectivityLowerBound)
		{
			*selectivity = Max(*selectivity, LowSelectivity);
		}
		foundSelectivity = true;
	}

	MemoryContextSwitchTo(oldContext);
	MemoryContextDelete(tempContext);
	return foundSelectivity;
}


/*
 * Estimate the operations applied by a range-encoded elemMatch index qual.
 * This is separate from the residual elemMatch estimate because only
 * operations kept in elemMatchIndexOp constrain the index scan.
 */
static bool
TryGetElemMatchIndexSelectivity(PlannerInfo *planner, Node *documentExpr,
								const pgbsonelement *elemMatchElement,
								const DollarRangeParams *rangeParams,
								int varRelId, double *selectivity)
{
	if (rangeParams->elemMatchValue.value_type != BSON_TYPE_ARRAY)
	{
		return false;
	}

	Const *pathValue = MakeTextConst(elemMatchElement->path,
									 elemMatchElement->pathLength);
	List *pathArgs = list_make2(documentExpr, pathValue);
	Expr *statsExpr = (Expr *) makeFuncExpr(BsonStatsProjectFuncOid(),
											BsonTypeId(), pathArgs,
											InvalidOid,
											DEFAULT_COLLATION_OID,
											COERCE_EXPLICIT_CALL);
	List *operationClauses = NIL;
	bool foundOperation = false;
	bool operatorReturnsSet = false;

	bson_iter_t elemMatchIter;
	BsonValueInitIterator(&rangeParams->elemMatchValue, &elemMatchIter);
	while (bson_iter_next(&elemMatchIter))
	{
		bson_iter_t operationIter;
		if (!bson_iter_recurse(&elemMatchIter, &operationIter))
		{
			foundOperation = false;
			break;
		}

		BsonIndexStrategy strategy = BSON_INDEX_STRATEGY_INVALID;
		const bson_value_t *operationValue = NULL;
		while (bson_iter_next(&operationIter))
		{
			const char *key = bson_iter_key(&operationIter);
			if (strcmp(key, "op") == 0)
			{
				strategy = (BsonIndexStrategy) BsonValueAsInt32(
					bson_iter_value(&operationIter));
			}
			else if (strcmp(key, "value") == 0)
			{
				operationValue = bson_iter_value(&operationIter);
			}
		}

		if (operationValue == NULL)
		{
			foundOperation = false;
			break;
		}

		if (strategy == BSON_INDEX_STRATEGY_DOLLAR_REGEX)
		{
			if (operationValue->value_type != BSON_TYPE_REGEX)
			{
				foundOperation = false;
				break;
			}

			bson_value_t lowerBound = { 0 };
			bson_value_t upperBound = { 0 };
			bool lowerBoundInclusive = false;
			bool upperBoundInclusive = false;
			GetBoundsForRegex(operationValue->value.v_regex.regex,
							  operationValue->value.v_regex.options,
							  &lowerBound, &lowerBoundInclusive,
							  &upperBound, &upperBoundInclusive);

			BsonIndexStrategy lowerStrategy = lowerBoundInclusive ?
											  BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL :
											  BSON_INDEX_STRATEGY_DOLLAR_GREATER;
			BsonIndexStrategy upperStrategy = upperBoundInclusive ?
											  BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL :
											  BSON_INDEX_STRATEGY_DOLLAR_LESS;
			Oid lowerOperator = GetNativeStatsBtreeOperatorForIndexStrategy(
				lowerStrategy);
			Oid upperOperator = GetNativeStatsBtreeOperatorForIndexStrategy(
				upperStrategy);
			if (!OidIsValid(lowerOperator) || !OidIsValid(upperOperator))
			{
				foundOperation = false;
				break;
			}

			Const *lowerConst = MakeBsonConst(
				BsonValueToDocumentPgbson(&lowerBound));
			Const *upperConst = MakeBsonConst(
				BsonValueToDocumentPgbson(&upperBound));
			lowerConst->consttype = BsonQueryTypeId();
			upperConst->consttype = BsonQueryTypeId();
			operationClauses = lappend(operationClauses,
									   make_opclause(lowerOperator, BOOLOID,
													 operatorReturnsSet,
													 statsExpr,
													 (Expr *) lowerConst,
													 InvalidOid, InvalidOid));
			operationClauses = lappend(operationClauses,
									   make_opclause(upperOperator, BOOLOID,
													 operatorReturnsSet,
													 statsExpr,
													 (Expr *) upperConst,
													 InvalidOid, InvalidOid));
			foundOperation = true;
			continue;
		}

		Oid operationOperator = GetNativeStatsBtreeOperatorForIndexStrategy(strategy);
		if (!OidIsValid(operationOperator))
		{
			foundOperation = false;
			break;
		}

		Const *operationConst = MakeBsonConst(
			BsonValueToDocumentPgbson(operationValue));
		operationConst->consttype = BsonQueryTypeId();
		operationClauses = lappend(operationClauses,
								   make_opclause(operationOperator, BOOLOID,
												 operatorReturnsSet,
												 statsExpr, (Expr *) operationConst,
												 InvalidOid, InvalidOid));
		foundOperation = true;
	}

	if (foundOperation)
	{
		*selectivity = clauselist_selectivity(planner, operationClauses, varRelId,
											  JOIN_INNER, NULL);
		CLAMP_PROBABILITY(*selectivity);
		if (EnableElemMatchSelectivityLowerBound)
		{
			*selectivity = Max(*selectivity, LowSelectivity);
		}
	}

	list_free(operationClauses);
	list_free(pathArgs);
	pfree(pathValue);
	return foundOperation;
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
	}

	bool isPerCollectionStatsEnabled = false;
	if (!EnablePlannerCostSelectivityExtended(planner, args,
											  &isPerCollectionStatsEnabled))
	{
		if (params.isElemMatch)
		{
			pgbsonelement elemMatchElement;
			BsonIndexStrategy indexStrategyIgnore = BSON_INDEX_STRATEGY_INVALID;
			return GetStatisticsNoStatsData(args, selectivityOpExpr,
											defaultExprSelectivity, &elemMatchElement,
											&indexStrategyIgnore);
		}

		return GetDisableStatisticSelectivity(args, defaultExprSelectivity);
	}

	pgbsonelement dollarElement;
	BsonIndexStrategy indexStrategy = BSON_INDEX_STRATEGY_INVALID;
	double defaultInputSelectivity = GetStatisticsNoStatsData(args, selectivityOpExpr,
															  defaultExprSelectivity,
															  &dollarElement,
															  &indexStrategy);

	if (!isPerCollectionStatsEnabled)
	{
		if (params.isElemMatch)
		{
			return defaultInputSelectivity;
		}

		return generic_restriction_selectivity(
			planner, selectivityOpExpr, collation, args, varRelId,
			defaultInputSelectivity);
	}

	if (params.isElemMatch)
	{
		double elemMatchSelectivity;
		if (EnableElemMatchSelectivityFromStats &&
			TryGetElemMatchIndexSelectivity(planner, linitial(args),
											&dollarElement, &params,
											varRelId,
											&elemMatchSelectivity))
		{
			return elemMatchSelectivity;
		}

		return defaultInputSelectivity;
	}

	if (EnableElemMatchSelectivityFromStats &&
		indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_ELEMMATCH)
	{
		double elemMatchSelectivity;
		if (TryGetElemMatchSelectivity(planner, linitial(args), &dollarElement,
									   varRelId, collation,
									   &elemMatchSelectivity))
		{
			return elemMatchSelectivity;
		}
	}

	/*
	 * This is Postgres's default selectivity implementation that looks at statistics
	 * and gets the Most common values/ histograms and gets the overall selectivity
	 * from the raw table.
	 */
	double selectivity;
	if (list_length(args) == 2 &&
		dollarElement.bsonValue.value_type != BSON_TYPE_EOD)
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
 * GetObjectIdOperatorSelectivity computes selectivity for an object_id
 * FuncExpr using PG's built-in selectivity functions (eqsel, scalargtsel, etc.)
 * based on the index strategy derived from the function OID.
 */
double
GetObjectIdOperatorSelectivity(PlannerInfo *planner, Oid funcId,
							   Expr *objectIdExpr, Expr *querySpecExpr,
							   int varRelId, Oid collation)
{
	const ObjectIdMongoOperatorInfo *operatorInfo =
		GetObjectIdMongoIndexOperatorByPostgresFuncId(funcId);

	if (operatorInfo->indexOperator.indexStrategy == BSON_INDEX_STRATEGY_INVALID)
	{
		return DEFAULT_INEQ_SEL;
	}

	const MongoIndexOperatorInfo *mongoIndexOperatorInfo =
		GetMongoIndexOperatorInfoByOperatorType(operatorInfo->queryOperator.operatorType);
	Oid operatorOid = GetMongoQueryOperatorOid(mongoIndexOperatorInfo);

	if (!OidIsValid(operatorOid))
	{
		return DEFAULT_INEQ_SEL;
	}

	if (IsA(querySpecExpr, Const) && !((Const *) querySpecExpr)->constisnull)
	{
		pgbson *queryBson = DatumGetPgBson(((Const *) querySpecExpr)->constvalue);
		pgbsonelement queryElement;
		PgbsonToSinglePgbsonElement(queryBson, &queryElement);

		return GetCustomStatisticsSelectivity(planner,
											  operatorInfo->indexOperator.indexStrategy,
											  operatorOid,
											  (Node *) objectIdExpr,
											  &queryElement.bsonValue,
											  varRelId,
											  collation,
											  DEFAULT_INEQ_SEL);
	}

	List *newArgs = list_make2(objectIdExpr, querySpecExpr);
	double selectivity = generic_restriction_selectivity(planner, operatorOid,
														 collation,
														 newArgs, varRelId,
														 DEFAULT_INEQ_SEL);
	list_free(newArgs);
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
 * This is the projection function that manages statistics for filters in the documents table.
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
