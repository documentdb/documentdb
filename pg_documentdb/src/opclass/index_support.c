/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/opclass/index_support.c
 *
 * Support methods for index selection and push down.
 * See also: https://www.postgresql.org/docs/current/gin-extensibility.html
 * See also: https://www.postgresql.org/docs/current/xfunc-optimization.html
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <fmgr.h>
#include <nodes/nodes.h>
#include <utils/builtins.h>
#include <catalog/pg_type.h>
#include <nodes/pathnodes.h>
#include <nodes/supportnodes.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <catalog/pg_am.h>
#include <optimizer/paths.h>
#include <parser/parsetree.h>
#include <optimizer/pathnode.h>
#include "nodes/pg_list.h"
#include <pg_config_manual.h>
#include <utils/lsyscache.h>
#include <optimizer/restrictinfo.h>
#include <optimizer/cost.h>
#include <access/genam.h>
#include <utils/index_selfuncs.h>
#include <utils/selfuncs.h>
#include <access/gin.h>
#include <catalog/pg_collation.h>

#include "metadata/index.h"
#include "query/query_operator.h"
#include "collation/collation.h"
#include "opclass/bson_gin_index_types_core.h"
#include "geospatial/bson_geospatial_geonear.h"
#include "planner/mongo_query_operator.h"
#include "opclass/bson_index_support.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "opclass/bson_gin_composite_scan.h"
#include "opclass/bson_text_gin.h"
#include "metadata/metadata_cache.h"
#include "utils/documentdb_errors.h"
#include "vector/vector_utilities.h"
#include "vector/vector_spec.h"
#include "utils/version_utils.h"
#include "query/bson_compare.h"
#include "index_am/index_am_utils.h"
#include "utils/docdb_make_funcs.h"
#include "query/bson_dollar_selectivity.h"
#include "planner/documentdb_planner.h"
#include "aggregation/bson_query_common.h"
#include "index_am/documentdb_rum.h"
#include "index_am/index_am_extend_query.h"

typedef struct
{
	pgbsonelement minElement;
	bool isMinInclusive;
	IndexClause *minClause;
	pgbsonelement maxElement;
	bool isMaxInclusive;
	IndexClause *maxClause;

	bool isInvalidCandidateForRange;
} DollarRangeElement;

typedef struct
{
	Expr *documentExpr;
	const char *documentDBIndexName;
	bool isSparse;
} IndexHintMatchContext;

typedef struct
{
	bson_value_t value;
	RestrictInfo *restrictInfo;
} RuntimePrimaryKeyRestrictionData;

typedef struct
{
	RestrictInfo *shardKeyQualExpr;
	struct
	{
		bson_value_t equalityBsonValue;
		RestrictInfo *restrictInfo;
		bool isPrimaryKeyEquality;
	} objectId;


	/* Found paths */
	IndexPath *primaryKeyLookupPath;

	/* Runtime expression checks for $eq
	 * List of RuntimePrimaryKeyRestrictionData
	 */
	List *runtimeEqualityRestrictionData;

	/* Runtime expression checks for $in
	 * List of RuntimePrimaryKeyRestrictionData
	 */
	List *runtimeDollarInRestrictionData;
} PrimaryKeyLookupContext;

/*
 * A single query predicate for an elemMatch call.
 */
typedef struct IndexElemMatchSingleOp
{
	/* The indexop for the request */
	BsonIndexStrategy op;

	/* The query predicate value */
	bson_value_t value;
} IndexElemMatchSingleOp;

/* the per path match operations */
typedef struct IndexElemMatchPathState
{
	/* The path that is matched */
	const char *indexPath;
	uint32_t indexPathLength;

	/* Whether or not the path is the top level index query
	 * e.g. if the query is "a": { "$elemMatch": { "b": 5 } }
	 * on index "a.b": -> isTopLevel: false
	 * if the query is "a.b": { "$elemMatch": { "$eq": 5 } }
	 * on index "a.b": -> isTopLevel: true
	 */
	bool isTopLevel;

	/* A list of IndexElemMatchSingleOp for this path */
	List *singleOps;
} IndexElemMatchPathState;

/* State tracking the query walking for elemMatch operators */
typedef struct IndexElemmatchState
{
	/* A list of IndexElemMatchPathState - one per index paths */
	List *pathStates;
} IndexElemmatchState;

/* State tracking the query walking for projection variables and subqueries */
typedef struct ProjectionVarQueryState
{
	bool hasNonDocumentVar;
	bool hasDocumentVar;
	bool hasQuery;
	PlannerInfo *root;
	Index scanRti;
} ProjectionVarQueryState;

/* State tracking field coverage for index-only scans */
typedef struct FieldCoverageState
{
	PlannerInfo *root;
	Index expectedRti;
	IndexPath *indexPath;
	bool hasUncoveredField;
} FieldCoverageState;

extern bool EnableExtendedExplainPlans;
extern bool EnableExplainScanIndexCosts;
extern bool EnableOrderByIndexTerm;
extern bool EnableIndexOnlyScanForCoveredAggregateTargets;
extern bool EnableIndexOnlyScanForRangeMatch;
extern bool EnableIndexOnlyScanForFindProject;
extern bool EnableObjectIdFuncExprConversion;
extern bool EnableExtendedIndexes;
extern bool EnableDynamicCursors;
extern bool EnableDistinctIndexPushdown;
extern bool EnableDistinctMultiKeyFilterPushdown;
extern bool EnableCollationWithNonUniqueOrderedIndexes;
extern bool EnablePerPathMultiKeySortPushdown;

/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */
static Expr * HandleSupportRequestCondition(SupportRequestIndexCondition *req);
static Path * ReplaceFunctionOperatorsInPlanPath(PlannerInfo *root, RelOptInfo *rel,
												 Path *path, PlanParentType parentType,
												 ReplaceExtensionFunctionContext *context);
static Expr * ProcessRestrictionInfoAndRewriteFuncExpr(Expr *clause,
													   ReplaceExtensionFunctionContext *
													   context, bool trimClauses);

static void ExtractAndSetSearchParamterFromWrapFunction(IndexPath *indexPath,
														ReplaceExtensionFunctionContext *
														context);
static Path * OptimizeBitmapQualsForBitmapAnd(BitmapAndPath *path,
											  ReplaceExtensionFunctionContext *context);
static IndexPath * OptimizeIndexPathForFilters(IndexPath *indexPath,
											   ReplaceExtensionFunctionContext *context);
static Expr * OpExprForAggregationStageSupportFunction(Node *supportRequest);
static const char * GetJoinFilterArgCollation(Node *matchArg);
static Path * FindIndexPathForQueryOperator(RelOptInfo *rel, List *pathList,
											ReplaceExtensionFunctionContext *context,
											MatchIndexPath matchIndexPath,
											void *matchContext);
static bool IsMatchingPathForQueryOperator(RelOptInfo *rel, Path *path,
										   ReplaceExtensionFunctionContext *context,
										   MatchIndexPath matchIndexPath,
										   void *matchContext);
static Expr * ProcessFullScanForOrderBy(SupportRequestIndexCondition *req, List *args);
static Expr * CreateKnownFullScanExpr(Datum queryValue, Expr *documentExpr, int
									  sortDirection);
static OpExpr * CreateExistsTrueOpExpr(Expr *documentExpr, const char *sourcePath,
									   uint32_t sourcePathLength);
static List * GetSortDetails(PlannerInfo *root, Index rti,
							 bool *hasGroupby, bool *isOrderById, bool *hasDistinct);
static bool IsQueryCollationCompatibleWithIndex(const char *queryCollation,
												bytea *indexOptions);
static bool IsValidIndexPathForIdOrderBy(IndexPath *indexPath, List *sortDetails);

static Expr * HandleSupportRequestForBtreeObjectIdCondition(
	SupportRequestIndexCondition *req);
static Expr * HandleSupportRequestForRegularObjectIdCondition(
	SupportRequestIndexCondition *req);

/*-------------------------------*/
/* Force index support functions */
/*-------------------------------*/
static List * UpdateIndexListForGeonear(List *existingIndex,
										ReplaceExtensionFunctionContext *context);
static bool MatchIndexPathForGeonear(IndexPath *path, void *matchContext);
static bool TryUseAlternateIndexGeonear(PlannerInfo *root, RelOptInfo *rel,
										ReplaceExtensionFunctionContext *context,
										MatchIndexPath matchIndexPath);
static List * UpdateIndexListForText(List *existingIndex,
									 ReplaceExtensionFunctionContext *context);
static List * UpdateIndexListForVector(List *existingIndex,
									   ReplaceExtensionFunctionContext *context);
static bool MatchIndexPathForText(IndexPath *path, void *matchContext);
static bool MatchIndexPathForVector(IndexPath *path, void *matchContext);
static bool PushTextQueryToRuntime(PlannerInfo *root, RelOptInfo *rel,
								   ReplaceExtensionFunctionContext *context,
								   MatchIndexPath matchIndexPath);
static void ThrowNoTextIndexFound(void);
static void ThrowNoVectorIndexFound(void);

static bool MatchIndexPathEquals(IndexPath *path, void *matchContext);
static bool EnableGeoNearForceIndexPushdown(PlannerInfo *root,
											ReplaceExtensionFunctionContext *context);
static bool DefaultTrueForceIndexPushdown(PlannerInfo *root,
										  ReplaceExtensionFunctionContext *context);
static bool DefaultFalseForceIndexPushdown(PlannerInfo *root,
										   ReplaceExtensionFunctionContext *context);
static Expr * ProcessElemMatchOperator(bytea *options, Datum queryValue, const
									   MongoIndexOperatorInfo *operator, List *args);

static List * UpdateIndexListForIndexHint(List *existingIndex,
										  ReplaceExtensionFunctionContext *context);
static bool MatchIndexPathForIndexHint(IndexPath *path, void *matchContext);
static bool TryUseAlternateIndexForIndexHint(PlannerInfo *root, RelOptInfo *rel,
											 ReplaceExtensionFunctionContext *context,
											 MatchIndexPath matchIndexPath);
static void ThrowIndexHintUnableToFindIndex(void);

static List * UpdateIndexListForPrimaryKeyLookup(List *existingIndex,
												 ReplaceExtensionFunctionContext *context);
static bool MatchIndexPathForPrimaryKeyLookup(IndexPath *path, void *matchContext);
static bool TryUseAlternateIndexForPrimaryKeyLookup(PlannerInfo *root, RelOptInfo *rel,
													ReplaceExtensionFunctionContext *
													context,
													MatchIndexPath matchIndexPath);
static void PrimaryKeyLookupUnableToFindIndex(void);
static bool IndexClauseIsValidForIndexOnlyScan(const IndexClause *clause,
											   bytea *indexOptions);

static List * UpdateIndexListForExtendedIndex(List *existingIndex,
											  ReplaceExtensionFunctionContext *context);
static bool MatchIndexPathForExtendedIndex(IndexPath *path, void *matchContext);
static bool TryUseAlternateIndexForExtendedIndex(PlannerInfo *root, RelOptInfo *rel,
												 ReplaceExtensionFunctionContext *context,
												 MatchIndexPath matchIndexPath);
static void ThrowNoExtendedIndexFound(void);
static bool EnableExtendedIndexForceIndexPushdown(PlannerInfo *root,
												  ReplaceExtensionFunctionContext *context);

static const ForceIndexSupportFuncs ForceIndexOperatorSupport[] =
{
	[ForceIndexOpType_None] = {
		.operator = ForceIndexOpType_None,
		.updateIndexes = NULL,
		.matchIndexPath = &MatchIndexPathEquals,
		.alternatePath = NULL,
		.noIndexHandler = NULL,
		.enableForceIndexPushdown = &DefaultFalseForceIndexPushdown
	},
	[ForceIndexOpType_Text] = {
		.operator = ForceIndexOpType_Text,
		.updateIndexes = &UpdateIndexListForText,
		.matchIndexPath = &MatchIndexPathForText,
		.noIndexHandler = &ThrowNoTextIndexFound,
		.alternatePath = &PushTextQueryToRuntime,
		.enableForceIndexPushdown = &DefaultTrueForceIndexPushdown
	},
	[ForceIndexOpType_GeoNear] = {
		.operator = ForceIndexOpType_GeoNear,
		.updateIndexes = &UpdateIndexListForGeonear,
		.matchIndexPath = &MatchIndexPathForGeonear,
		.alternatePath = &TryUseAlternateIndexGeonear,
		.noIndexHandler = &ThrowGeoNearUnableToFindIndex,
		.enableForceIndexPushdown = &EnableGeoNearForceIndexPushdown
	},
	[ForceIndexOpType_VectorSearch] = {
		.operator = ForceIndexOpType_VectorSearch,
		.updateIndexes = &UpdateIndexListForVector,
		.matchIndexPath = &MatchIndexPathForVector,
		.noIndexHandler = &ThrowNoVectorIndexFound,
		.enableForceIndexPushdown = &DefaultTrueForceIndexPushdown
	},
	[ForceIndexOpType_IndexHint] = {
		.operator = ForceIndexOpType_IndexHint,
		.updateIndexes = &UpdateIndexListForIndexHint,
		.matchIndexPath = &MatchIndexPathForIndexHint,
		.alternatePath = &TryUseAlternateIndexForIndexHint,
		.noIndexHandler = &ThrowIndexHintUnableToFindIndex,
		.enableForceIndexPushdown = &DefaultTrueForceIndexPushdown
	},
	[ForceIndexOpType_PrimaryKeyLookup] = {
		.operator = ForceIndexOpType_PrimaryKeyLookup,
		.updateIndexes = &UpdateIndexListForPrimaryKeyLookup,
		.matchIndexPath = &MatchIndexPathForPrimaryKeyLookup,
		.alternatePath = &TryUseAlternateIndexForPrimaryKeyLookup,
		.noIndexHandler = &PrimaryKeyLookupUnableToFindIndex,
		.enableForceIndexPushdown = &DefaultTrueForceIndexPushdown
	},
	[ForceIndexOpType_ExtendedIndex] = {
		.operator = ForceIndexOpType_ExtendedIndex,
		.updateIndexes = &UpdateIndexListForExtendedIndex,
		.matchIndexPath = &MatchIndexPathForExtendedIndex,
		.alternatePath = &TryUseAlternateIndexForExtendedIndex,
		.noIndexHandler = &ThrowNoExtendedIndexFound,
		.enableForceIndexPushdown = &EnableExtendedIndexForceIndexPushdown
	}
};

extern bool EnableVectorForceIndexPushdown;
extern bool EnableGeonearForceIndexPushdown;
extern bool ForceIndexOnlyScanIfAvailable;
extern bool EnableIndexOnlyScan;
extern bool EnableIndexOnlyScanOnCostFunction;
extern bool EnableOrderByIdOnCostFunction;
extern bool EnablePrimaryKeyCursorScan;

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */
PG_FUNCTION_INFO_V1(dollar_support);
PG_FUNCTION_INFO_V1(dollar_support_object_id);
PG_FUNCTION_INFO_V1(bson_dollar_lookup_filter_support);
PG_FUNCTION_INFO_V1(bson_dollar_merge_filter_support);

/*
 * Handles the Support functions for the dollar logical operators.
 * Currently, this only supports the 'SupportRequestIndexCondition'
 * This basically takes a FuncExpr input that has a bson_dollar_<op>
 * and *iff* the index pointed to by the index matches the function,
 * returns the equivalent OpExpr for that function.
 * This means that this hook allows us to match each Qual directly against
 * an index (and each index column) independently, and push down each qual
 * directly against an index column custom matching against the index.
 * For more details see: https://www.postgresql.org/docs/current/xfunc-optimization.html
 * See also: https://github.com/postgres/postgres/blob/677a1dc0ca0f33220ba1ea8067181a72b4aff536/src/backend/optimizer/path/indxpath.c#L2329
 */
Datum
dollar_support(PG_FUNCTION_ARGS)
{
	Node *supportRequest = (Node *) PG_GETARG_POINTER(0);
	Pointer responsePointer = NULL;
	if (IsA(supportRequest, SupportRequestIndexCondition))
	{
		/* Try to convert operator/function call to index conditions */
		SupportRequestIndexCondition *req =
			(SupportRequestIndexCondition *) supportRequest;

		/* if we matched the condition to the index, then this function is not lossy -
		 * The operator is a perfect match for the function.
		 */
		req->lossy = false;

		Expr *finalNode = HandleSupportRequestCondition(req);
		if (finalNode != NULL)
		{
			if (IsA(finalNode, BoolExpr))
			{
				BoolExpr *boolExpr = (BoolExpr *) finalNode;
				responsePointer = (Pointer) boolExpr->args;
			}
			else
			{
				responsePointer = (Pointer) list_make1(finalNode);
			}
		}
	}
	else if (IsA(supportRequest, SupportRequestSelectivity))
	{
		SupportRequestSelectivity *req = (SupportRequestSelectivity *) supportRequest;
		if (EnablePlannerCostSelectivity(req->root, req->args))
		{
			const MongoIndexOperatorInfo *indexOperator =
				GetMongoIndexOperatorInfoByPostgresFuncId(req->funcid);
			if (indexOperator != NULL && indexOperator->indexStrategy !=
				BSON_INDEX_STRATEGY_INVALID)
			{
				/* See plancat.c function_selectivity */
				const double defaultFuncExprSelectivity = 0.3333333;
				Oid selectivityOpExpr = GetMongoQueryOperatorOid(indexOperator);
				double selectivity = GetDollarOperatorSelectivity(
					req->root, selectivityOpExpr, req->args, req->inputcollid,
					req->varRelid, defaultFuncExprSelectivity);
				req->selectivity = selectivity;
				responsePointer = (Pointer) req;
			}
		}
		else if (req->funcid == BsonRangeMatchFunctionId())
		{
			/* For fullScan for orderby, we want to ensure we mark the
			 * selectivity as 1.0 to ensure that we say that it will select
			 * all rows for planner estimation.
			 */
			if (IsBsonRangeArgsForFullScan(req->args))
			{
				req->selectivity = 1.0;
				responsePointer = (Pointer) req;
			}
		}
	}
	else if (IsA(supportRequest, SupportRequestCost))
	{
		/* Since a fullscan qpqual is ripped out by the planner,
		 * we simply say here that its cost is super low.
		 */
		SupportRequestCost *req = (SupportRequestCost *) supportRequest;
		if (req->funcid == BsonRangeMatchFunctionId() && req->node != NULL &&
			IsA(req->node, FuncExpr))
		{
			FuncExpr *func = (FuncExpr *) req->node;
			if (IsBsonRangeArgsForFullScanOrElemMatch(func->args))
			{
				req->per_tuple = 1e-9;
				req->startup = 0;
				responsePointer = (Pointer) req;
			}
		}
	}

	PG_RETURN_POINTER(responsePointer);
}


Datum
dollar_support_object_id(PG_FUNCTION_ARGS)
{
	Node *supportRequest = (Node *) PG_GETARG_POINTER(0);
	Pointer responsePointer = NULL;
	if (IsA(supportRequest, SupportRequestIndexCondition))
	{
		/* Try to convert operator/function call to index conditions */
		SupportRequestIndexCondition *req =
			(SupportRequestIndexCondition *) supportRequest;

		/* if we matched the condition to the index, then this function is not lossy -
		 * The operator is a perfect match for the function.
		 */
		req->lossy = false;

		Expr *finalNode = NULL;
		if (req->index->relam == BTREE_AM_OID)
		{
			finalNode = HandleSupportRequestForBtreeObjectIdCondition(req);
		}
		else if (IsBsonRegularIndexAm(req->index->relam))
		{
			finalNode = HandleSupportRequestForRegularObjectIdCondition(req);
		}

		if (finalNode != NULL)
		{
			if (IsA(finalNode, BoolExpr))
			{
				BoolExpr *boolExpr = (BoolExpr *) finalNode;
				responsePointer = (Pointer) boolExpr->args;
			}
			else if (IsA(finalNode, List))
			{
				responsePointer = (Pointer) finalNode;
			}
			else
			{
				responsePointer = (Pointer) list_make1(finalNode);
			}
		}
	}
	else if (IsA(supportRequest, SupportRequestSelectivity))
	{
		SupportRequestSelectivity *req = (SupportRequestSelectivity *) supportRequest;

		if (!req->is_join)
		{
			Oid operatorOid = InvalidOid;

			/* TODO(object_id_funcs): Make this more generalizable. Also move to bson_dollar_selectivity.c */
			if (IsClusterVersionAtleast(DocDB_V0, 112, 1) &&
				req->funcid == BsonRegexObjectIdMatchFunctionId())
			{
				const MongoIndexOperatorInfo *operator =
					GetMongoIndexOperatorInfoByPostgresFuncId(BsonRegexMatchFunctionId());
				operatorOid = GetMongoQueryOperatorOid(operator);
			}

			if (operatorOid == InvalidOid)
			{
				PG_RETURN_POINTER(responsePointer);
			}

			/* Run selectivity against object_id and the query spec. */
			List *newArgs = list_make2(lsecond(req->args), lthird(req->args));

			/* default to 0.333 to match PG default selectivity. */
			req->selectivity = generic_restriction_selectivity(req->root,
															   operatorOid,
															   req->inputcollid,
															   newArgs,
															   req->varRelid,
															   DEFAULT_INEQ_SEL);

			list_free(newArgs);
			responsePointer = (Pointer) req;
		}
	}

	PG_RETURN_POINTER(responsePointer);
}


/*
 * Support function for index pushdown for $lookup join
 * filters. This is needed and can't use the regular index filters
 * since those use a Const value and require Const values to push down
 * to extract the index paths. So we use a 3rd argument which provides
 * the index path and use that to push down to the appropriate index.
 */
Datum
bson_dollar_lookup_filter_support(PG_FUNCTION_ARGS)
{
	Node *supportRequest = (Node *) PG_GETARG_POINTER(0);

	if (IsA(supportRequest, SupportRequestSelectivity))
	{
		SupportRequestSelectivity *req = (SupportRequestSelectivity *) supportRequest;

		/*
		 * Consider low selectivity of lookup filter for better index estimates.
		 */
		req->selectivity = LowSelectivity;
		PG_RETURN_POINTER(req);
	}

	Expr *finalOpExpr = OpExprForAggregationStageSupportFunction(supportRequest);

	if (finalOpExpr)
	{
		PG_RETURN_POINTER(list_make1(finalOpExpr));
	}

	PG_RETURN_POINTER(NULL);
}


/*
 * Support function for index pushdown for $merge join
 * filters. This is needed and can't use the regular index filters
 * since those use a Const value and require Const values to push down
 * to extract the index paths. So we use a 3rd argument which provides
 * the index path and use that to push down to the appropriate index.
 */
Datum
bson_dollar_merge_filter_support(PG_FUNCTION_ARGS)
{
	Node *supportRequest = (Node *) PG_GETARG_POINTER(0);
	Expr *finalOpExpr = OpExprForAggregationStageSupportFunction(supportRequest);

	if (finalOpExpr)
	{
		PG_RETURN_POINTER(list_make1(finalOpExpr));
	}

	PG_RETURN_POINTER(NULL);
}


bool
TryGetRangeParamsForRangeArgs(List *args, DollarRangeParams *params)
{
	if (list_length(args) != 2)
	{
		return false;
	}

	Expr *queryVal = lsecond(args);
	if (!IsA(queryVal, Const))
	{
		/* If the query value is not a constant, we can't push down */
		return false;
	}

	Const *queryConst = (Const *) queryVal;
	pgbson *queryBson = DatumGetPgBson(queryConst->constvalue);

	pgbsonelement queryElement;
	PgbsonToSinglePgbsonElement(queryBson, &queryElement);

	InitializeQueryDollarRange(&queryElement.bsonValue, params);
	return true;
}


bool
IsBsonRangeArgsForFullScanOrElemMatch(List *args)
{
	DollarRangeParams rangeParams = { 0 };
	if (!TryGetRangeParamsForRangeArgs(args, &rangeParams))
	{
		return false;
	}

	return rangeParams.isElemMatch || rangeParams.isFullScan;
}


bool
IsBsonRangeArgsForFullScan(List *args)
{
	DollarRangeParams rangeParams = { 0 };
	if (!TryGetRangeParamsForRangeArgs(args, &rangeParams))
	{
		return false;
	}

	return rangeParams.isFullScan;
}


/**
 * This function creates an operator expression for support functions used in aggregation stages. These support functions enable the
 * pushdown of operations to the index. Regular support functions cannot be used because they require constants, while some aggregation
 * stages, such as $lookup and $merge, use variable expressions. To handle these cases, we need specialized support functions.
 *
 * Return opExpression for
 * $merge stage we create opExpr for $eq `@=` operator
 * $lookup stage we create opExpr for $in `@*=` operator
 */
static Expr *
OpExprForAggregationStageSupportFunction(Node *supportRequest)
{
	if (!IsA(supportRequest, SupportRequestIndexCondition))
	{
		return NULL;
	}

	SupportRequestIndexCondition *req = (SupportRequestIndexCondition *) supportRequest;

	if (!IsA(req->node, FuncExpr))
	{
		return NULL;
	}

	Oid operatorOid = -1;
	BsonIndexStrategy strategy = BSON_INDEX_STRATEGY_INVALID;
	if (req->funcid == BsonDollarLookupJoinFilterFunctionOid())
	{
		operatorOid = BsonInMatchFunctionId();
		strategy = BSON_INDEX_STRATEGY_DOLLAR_IN;
	}
	else if (req->funcid == BsonDollarMergeJoinFunctionOid())
	{
		operatorOid = BsonEqualMatchIndexFunctionId();
		strategy = BSON_INDEX_STRATEGY_DOLLAR_EQUAL;
	}
	else
	{
		return NULL;
	}

	FuncExpr *funcExpr = (FuncExpr *) req->node;
	if (list_length(funcExpr->args) != 3)
	{
		return NULL;
	}

	/*
	 * TODO_COLLATION: never push a collated join filter to an index, nor any join
	 * filter to a collated index. $lookup embeds collation in its filter spec; $merge
	 * carries none today (HandleMerge rejects it) but its extract filter is inspected
	 * defensively in case that changes.
	 */
	const char *joinFilterCollation =
		GetJoinFilterArgCollation(lsecond(funcExpr->args));
	if (IsCollationPresentOnQueryOrIndex(joinFilterCollation,
										 req->index->opclassoptions[req->indexcol]))
	{
		return NULL;
	}

	Node *thirdNode = lthird(funcExpr->args);
	if (!IsA(thirdNode, Const))
	{
		return NULL;
	}

	/* This is the lookup/merge join function. We can't use regular support functions
	 * since they need Consts and Lookup is an expression. So we use a 3rd arg for
	 * the index path.
	 */
	Const *thirdConst = (Const *) thirdNode;
	text *path = DatumGetTextPP(thirdConst->constvalue);

	StringView pathView = CreateStringViewFromText(path);
	const MongoIndexOperatorInfo *operator = GetMongoIndexOperatorInfoByPostgresFuncId(
		operatorOid);

	bytea *options = req->index->opclassoptions[req->indexcol];
	if (options == NULL)
	{
		return NULL;
	}

	if (!ValidateIndexForQualifierPathForEquality(options, &pathView, strategy))
	{
		return NULL;
	}

	OpExpr *finalExpression = GetOpExprClauseFromIndexOperator(operator,
															   linitial(funcExpr->args),
															   lsecond(funcExpr->args),
															   options);
	return (Expr *) finalExpression;
}


/*
 * Returns the query collation embedded in a join-filter match argument -- the
 * inlined $lookup (bson_dollar_lookup_extract_filter_expression) or $merge
 * (bson_dollar_extract_merge_filter) extract-filter spec -- or NULL when the
 * argument is not a recognized filter expression or carries no collation. ($merge
 * carries no collation today since HandleMerge rejects it; recognized defensively.)
 */
static const char *
GetJoinFilterArgCollation(Node *matchArg)
{
	if (matchArg == NULL || !IsA(matchArg, FuncExpr))
	{
		return NULL;
	}

	FuncExpr *matchFunc = (FuncExpr *) matchArg;
	if (matchFunc->funcid !=
		DocumentDBApiInternalBsonLookupExtractFilterExpressionFunctionOid() &&
		matchFunc->funcid != BsonLookupExtractFilterArrayFunctionOid() &&
		matchFunc->funcid != BsonDollarMergeExtractFilterFunctionOid())
	{
		return NULL;
	}

	if (list_length(matchFunc->args) < 2)
	{
		return NULL;
	}

	Node *specNode = lsecond(matchFunc->args);
	if (!IsA(specNode, Const))
	{
		return NULL;
	}

	Const *specConst = (Const *) specNode;
	if (specConst->constisnull ||
		(specConst->consttype != BsonTypeId() &&
		 specConst->consttype != DocumentDBCoreBsonTypeId()))
	{
		return NULL;
	}

	pgbsonelement element = { 0 };
	return PgbsonToSinglePgbsonElementWithCollation(
		DatumGetPgBson(specConst->constvalue), &element);
}


/* Checks if the expr is a shard key equality expr and if so returns true and populates the shardKeyValue */
bool
IsOpExprShardKeyEquality(Expr *expr, int64 *shardKeyValue)
{
	if (!IsA(expr, OpExpr))
	{
		return false;
	}

	OpExpr *opExpr = (OpExpr *) expr;
	Expr *firstArg = linitial(opExpr->args);
	Expr *secondArg = lsecond(opExpr->args);

	if (opExpr->opno != BigintEqualOperatorId())
	{
		return false;
	}

	if (!IsA(firstArg, Var) || !IsA(secondArg, Const))
	{
		return false;
	}

	Var *firstArgVar = (Var *) firstArg;
	Const *secondArgConst = (Const *) secondArg;
	if (firstArgVar->varattno == DOCUMENT_DATA_TABLE_SHARD_KEY_VALUE_VAR_ATTR_NUMBER)
	{
		if (shardKeyValue != NULL && !secondArgConst->constisnull)
		{
			*shardKeyValue = DatumGetInt64(secondArgConst->constvalue);
		}

		return true;
	}

	return false;
}


/*
 * Checks if an Expr is the expression
 * WHERE shard_key_value = 'collectionId'
 * and is an unsharded equality operator.
 */
bool
IsOpExprShardKeyForUnshardedCollections(Expr *expr, uint64 collectionId)
{
	int64 extractedShardKeyValue = 0;
	return IsOpExprShardKeyEquality(expr, &extractedShardKeyValue) &&
		   extractedShardKeyValue == (int64) collectionId;
}


/*
 * This is used to ensure that incompatible force index operations are not used together in the same query.
 */
inline static void
ThrowIfIncompatibleForceIndexOp(ForceIndexOpType currentType, ForceIndexOpType newType)
{
	/* No conflict if no force-index op is active yet */
	if (currentType == ForceIndexOpType_None)
	{
		return;
	}

	/*
	 * Identify the incompatible operator for index hint
	 */
	if (currentType == ForceIndexOpType_IndexHint ||
		newType == ForceIndexOpType_IndexHint)
	{
		ForceIndexOpType opType =
			(currentType == ForceIndexOpType_IndexHint) ? newType : currentType;

		if (opType == ForceIndexOpType_Text)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("$text queries cannot specify hint")));
		}
		else if (opType == ForceIndexOpType_VectorSearch)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Vector search queries cannot specify hint")));
		}
		else if (opType == ForceIndexOpType_GeoNear)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("GeoNear queries cannot specify hint")));
		}
		else if (EnableExtendedIndexes && opType == ForceIndexOpType_ExtendedIndex)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg("Extended index queries cannot specify hint")));
		}
	}

	/*
	 * Identify the incompatible operator for extended index
	 */
	if (EnableExtendedIndexes &&
		(currentType == ForceIndexOpType_ExtendedIndex ||
		 newType == ForceIndexOpType_ExtendedIndex))
	{
		ForceIndexOpType opType =
			(currentType == ForceIndexOpType_ExtendedIndex) ? newType : currentType;

		if (opType == ForceIndexOpType_Text)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"$text is not allowed in combination with extended index queries")));
		}
		else if (opType == ForceIndexOpType_VectorSearch)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Vector search is not allowed in combination with extended index queries")));
		}
		else if (opType == ForceIndexOpType_GeoNear)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"$geoNear is not allowed in combination with extended index queries")));
		}
	}
}


static void
CheckNullTestForGeoSpatialForcePushdown(ReplaceExtensionFunctionContext *context,
										NullTest *nullTest)
{
	if (context->forceIndexQueryOpData.type != ForceIndexOpType_GeoNear &&
		nullTest->nulltesttype == IS_NOT_NULL &&
		IsA(nullTest->arg, FuncExpr))
	{
		Oid functionOid = ((FuncExpr *) nullTest->arg)->funcid;
		if (functionOid == BsonValidateGeographyFunctionId() ||
			functionOid == BsonValidateGeometryFunctionId())
		{
			/*
			 * The query contains a geospatial operator, now assume that it is a potential
			 * geonear query as well, because today for few instances we can't uniquely identify
			 * if the query is a geonear query.
			 *
			 * e.g. Sharded collections cases where ORDER BY is not pushed to the shards so we only
			 * get the PFE of geospatial operators.
			 */
			ThrowIfIncompatibleForceIndexOp(
				context->forceIndexQueryOpData.type, ForceIndexOpType_GeoNear);
			context->forceIndexQueryOpData.type = ForceIndexOpType_GeoNear;
		}
	}
}


/*
 * Walks an specific restriction expr and collections the necessary information from it
 * and stores the relevant information in the ReplaceExtensionFunctionContext. This may be
 * information about streaming cursors, geospatial indexes, and other index-related metadata.
 * Note that currentRestrictInfo can be NULL if there's an OR/AND and this is recursing.
 */
static void
CheckRestrictionPathNodeForIndexOperation(Expr *currentExpr,
										  ReplaceExtensionFunctionContext *context,
										  PrimaryKeyLookupContext *primaryKeyContext,
										  RestrictInfo *currentRestrictInfo)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();
	if (IsA(currentExpr, FuncExpr))
	{
		FuncExpr *funcExpr = (FuncExpr *) currentExpr;
		if (funcExpr->funcid == BsonIndexHintFunctionOid())
		{
			Node *secondNode = lsecond(funcExpr->args);
			if (!IsA(secondNode, Const))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("Index hint must be a constant value")));
			}

			Node *keyDocumentNode = lthird(funcExpr->args);
			if (!IsA(keyDocumentNode, Const))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("Index key document must be a constant value")));
			}

			Node *sparseNode = lfourth(funcExpr->args);
			if (!IsA(sparseNode, Const))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("Index sparse must be a constant value")));
			}

			ThrowIfIncompatibleForceIndexOp(
				context->forceIndexQueryOpData.type, ForceIndexOpType_IndexHint);
			Const *secondConst = (Const *) secondNode;
			IndexHintMatchContext *hintContext = palloc0(
				sizeof(IndexHintMatchContext));
			hintContext->documentExpr = linitial(funcExpr->args);
			hintContext->documentDBIndexName = TextDatumGetCString(
				secondConst->constvalue);
			hintContext->isSparse = DatumGetBool(((Const *) sparseNode)->constvalue);

			context->forceIndexQueryOpData.type = ForceIndexOpType_IndexHint;
			context->forceIndexQueryOpData.path = NULL;
			context->forceIndexQueryOpData.opExtraState = hintContext;
		}
		else if (funcExpr->funcid == ApiBsonSearchParamFunctionId())
		{
			/* Just validate indexHint is incompatible with vector search but don't set
			 * the forceIndexQueryOpData.type to vector search yet to keep compatibility.
			 */
			context->hasVectorSearchQuery = true;
			ThrowIfIncompatibleForceIndexOp(
				context->forceIndexQueryOpData.type, ForceIndexOpType_VectorSearch);
		}
		else if (funcExpr->funcid == ApiCursorStateFunctionId())
		{
			context->hasStreamingContinuationScan = true;
		}
		else if (IsClusterVersionAtleast(DocDB_V0, 112, 1) &&
				 funcExpr->funcid == ApiCursorTrackerFunctionId())
		{
			context->hasDynamicStreamingContinuationScan = true;
		}
		else if (funcExpr->funcid == BsonRangeMatchFunctionId() &&
				 IsBsonRangeArgsForReservoirSample(funcExpr->args))
		{
			context->reservoirSampleExpr = funcExpr;
		}
		else
		{
			const MongoQueryOperator *operator =
				GetMongoQueryOperatorByQueryOperatorType(QUERY_OPERATOR_TEXT,
														 MongoQueryOperatorInputType_Bson);
			if (operator->postgresRuntimeFunctionOidLookup() == funcExpr->funcid)
			{
				ThrowIfIncompatibleForceIndexOp(
					context->forceIndexQueryOpData.type, ForceIndexOpType_Text);
				context->forceIndexQueryOpData.type = ForceIndexOpType_Text;
			}
			else if (primaryKeyContext != NULL && funcExpr->funcid ==
					 BsonInMatchFunctionId())
			{
				Expr *firstArg = linitial(funcExpr->args);
				Expr *secondArg = lsecond(funcExpr->args);
				if (IsA(firstArg, Var) && IsA(secondArg, Const))
				{
					Var *var = (Var *) firstArg;
					Const *rightConst = (Const *) secondArg;
					if (var->varattno == DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER &&
						var->varno == (int) context->inputData.rteIndex)
					{
						pgbsonelement queryElement;
						if (TryGetSinglePgbsonElementFromPgbson(
								DatumGetPgBsonPacked(rightConst->constvalue),
								&queryElement) &&
							queryElement.pathLength == 3 && strcmp(queryElement.path,
																   "_id") == 0)
						{
							RuntimePrimaryKeyRestrictionData *runtimeDollarIn =
								palloc0(sizeof(RuntimePrimaryKeyRestrictionData));
							runtimeDollarIn->value = queryElement.bsonValue;
							runtimeDollarIn->restrictInfo = currentRestrictInfo;

							primaryKeyContext->runtimeDollarInRestrictionData =
								lappend(primaryKeyContext->runtimeDollarInRestrictionData,
										runtimeDollarIn);
						}
					}
				}
			}
			else if (EnableExtendedIndexes)
			{
				/* otherwise check if this function matches an extended index AM */
				QueryExtendedIndexContext *indexAmContext =
					MatchRestrictionPathExprByExtendedIndex((Expr *) funcExpr, context);
				if (indexAmContext != NULL)
				{
					ThrowIfIncompatibleForceIndexOp(
						context->forceIndexQueryOpData.type,
						ForceIndexOpType_ExtendedIndex);

					/* Check if a different extended AM already claimed this context */
					if (context->forceIndexQueryOpData.type ==
						ForceIndexOpType_ExtendedIndex &&
						context->forceIndexQueryOpData.opExtraState != NULL)
					{
						QueryExtendedIndexContext *existingContext =
							(QueryExtendedIndexContext *) context->forceIndexQueryOpData.
							opExtraState;
						if (existingContext->indexAmEntry != indexAmContext->indexAmEntry)
						{
							ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
											errmsg(
												"Conflicting extended index: '%s' and '%s'",
												existingContext->indexAmEntry->am_name,
												indexAmContext->indexAmEntry->am_name)));
						}
					}

					context->forceIndexQueryOpData.type = ForceIndexOpType_ExtendedIndex;
					context->forceIndexQueryOpData.opExtraState = indexAmContext;
				}
			}
		}
	}
	else if (primaryKeyContext != NULL && currentRestrictInfo != NULL && IsA(currentExpr,
																			 OpExpr))
	{
		OpExpr *opExpr = (OpExpr *) currentExpr;
		if (opExpr->opno == BigintEqualOperatorId())
		{
			Expr *firstArg = linitial(opExpr->args);
			if (IsA(firstArg, Var))
			{
				Var *var = (Var *) firstArg;
				if (var->varattno ==
					DOCUMENT_DATA_TABLE_SHARD_KEY_VALUE_VAR_ATTR_NUMBER &&
					var->varno == (int) context->inputData.rteIndex)
				{
					primaryKeyContext->shardKeyQualExpr = currentRestrictInfo;
					context->plannerOrderByData.shardKeyEqualityExpr =
						currentRestrictInfo;
					context->plannerOrderByData.isShardKeyEqualityOnUnsharded =
						IsOpExprShardKeyForUnshardedCollections(currentExpr,
																context->inputData.
																collectionId);
				}
			}
		}
		else if (opExpr->opno == BsonEqualOperatorId())
		{
			Expr *firstArg = linitial(opExpr->args);
			Expr *secondArg = lsecond(opExpr->args);
			if (IsA(firstArg, Var) && IsA(secondArg, Const))
			{
				Var *var = (Var *) firstArg;
				Const *rightConst = (Const *) secondArg;
				if (var->varattno == DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER &&
					var->varno == (int) context->inputData.rteIndex)
				{
					pgbsonelement queryElement;
					primaryKeyContext->objectId.restrictInfo = currentRestrictInfo;
					primaryKeyContext->objectId.isPrimaryKeyEquality = true;
					if (TryGetSinglePgbsonElementFromPgbson(
							DatumGetPgBsonPacked(rightConst->constvalue), &queryElement))
					{
						primaryKeyContext->objectId.equalityBsonValue =
							queryElement.bsonValue;
					}
				}
			}
		}
		else if (opExpr->opno == BsonEqualMatchRuntimeOperatorId())
		{
			Expr *firstArg = linitial(opExpr->args);
			Expr *secondArg = lsecond(opExpr->args);
			if (IsA(firstArg, Var) && IsA(secondArg, Const))
			{
				Var *var = (Var *) firstArg;
				Const *rightConst = (Const *) secondArg;
				if (var->varattno == DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER &&
					var->varno == (int) context->inputData.rteIndex)
				{
					pgbsonelement queryElement;
					if (TryGetSinglePgbsonElementFromPgbson(
							DatumGetPgBsonPacked(rightConst->constvalue),
							&queryElement) &&
						queryElement.pathLength == 3 && strcmp(queryElement.path,
															   "_id") == 0)
					{
						RuntimePrimaryKeyRestrictionData *equalityRestrictionData =
							palloc0(sizeof(RuntimePrimaryKeyRestrictionData));
						equalityRestrictionData->value = queryElement.bsonValue;
						equalityRestrictionData->restrictInfo = currentRestrictInfo;
						primaryKeyContext->runtimeEqualityRestrictionData =
							lappend(primaryKeyContext->runtimeEqualityRestrictionData,
									equalityRestrictionData);
					}
				}
			}
		}
		else if (EnableExtendedIndexes)
		{
			/* otherwise check if this operator matches an extended index AM */
			QueryExtendedIndexContext *indexAmContext =
				MatchRestrictionPathExprByExtendedIndex((Expr *) opExpr, context);
			if (indexAmContext != NULL)
			{
				/* Check if the current force index type is already set and is not compatible */
				ThrowIfIncompatibleForceIndexOp(
					context->forceIndexQueryOpData.type,
					ForceIndexOpType_ExtendedIndex);

				/* Check if a different extended AM already claimed this context */
				if (context->forceIndexQueryOpData.type ==
					ForceIndexOpType_ExtendedIndex &&
					context->forceIndexQueryOpData.opExtraState != NULL)
				{
					QueryExtendedIndexContext *existingContext =
						(QueryExtendedIndexContext *) context->forceIndexQueryOpData.
						opExtraState;
					if (existingContext->indexAmEntry != indexAmContext->indexAmEntry)
					{
						ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
										errmsg(
											"Conflicting extended index: '%s' and '%s'",
											existingContext->indexAmEntry->am_name,
											indexAmContext->indexAmEntry->am_name)));
					}
				}

				context->forceIndexQueryOpData.type = ForceIndexOpType_ExtendedIndex;
				context->forceIndexQueryOpData.opExtraState = indexAmContext;
			}
		}
	}
	else if (primaryKeyContext != NULL && primaryKeyContext->objectId.restrictInfo ==
			 NULL &&
			 IsA(currentExpr, ScalarArrayOpExpr))
	{
		ScalarArrayOpExpr *scalarArrayOpExpr = (ScalarArrayOpExpr *) currentExpr;
		if (scalarArrayOpExpr->opno == BsonEqualOperatorId() &&
			scalarArrayOpExpr->useOr)
		{
			Expr *firstArg = linitial(scalarArrayOpExpr->args);
			if (IsA(firstArg, Var))
			{
				Var *var = (Var *) firstArg;
				if (var->varattno == DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER &&
					var->varno == (int) context->inputData.rteIndex)
				{
					primaryKeyContext->objectId.restrictInfo = currentRestrictInfo;
				}
			}
		}
	}
	else if (IsA(currentExpr, NullTest))
	{
		NullTest *nullTest = (NullTest *) currentExpr;
		CheckNullTestForGeoSpatialForcePushdown(context, nullTest);
	}
	else if (IsA(currentExpr, BoolExpr))
	{
		BoolExpr *boolExpr = (BoolExpr *) currentExpr;
		ListCell *boolArgs;
		PrimaryKeyLookupContext *childContext = NULL;
		foreach(boolArgs, boolExpr->args)
		{
			CheckRestrictionPathNodeForIndexOperation(lfirst(boolArgs), context,
													  childContext, NULL);
		}
	}
}


static bool
HasTextPathOpFamily(IndexOptInfo *indexInfo)
{
	Oid textOpClass = GetTextPathOpFamilyOid(indexInfo->relam);
	if (textOpClass == InvalidOid)
	{
		return false;
	}

	for (int i = 0; i < indexInfo->ncolumns; i++)
	{
		if (indexInfo->opfamily[i] == textOpClass)
		{
			return true;
		}
	}

	return false;
}


/*
 * CheckPathForIndexOperations recursively walks a path tree and inspects each
 * IndexPath to detect operators that require a forced index pushdown.
 *
 * When it reaches an IndexPath, it checks:
 *
 *  - Primary key btree: PK btree (_id_) with >1 clause -> saves as
 *    primaryKeyLookupPath (used later by TryUseAlternateIndexForPrimaryKeyLookup).
 *  - Vector search: indexorderbys with a recognized vector AM -> sets
 *    ForceIndexOpType_VectorSearch and extracts the search parameter.
 *  - GeoNear: GIST index with a single bson_geonear_distance order-by ->
 *    sets ForceIndexOpType_GeoNear.
 *  - Text search: text-path OpFamily (RUM/GIST) -> extracts text index options
 *    and sets ForceIndexOpType_Text. Errors if multiple text expressions found.
 *
 * Called from WalkPathsForIndexOperations which iterates rel->pathlist.
 * The data collected here drives ForceIndexForQueryOperators, which replaces
 * the planner's chosen path with the mandatory index path.
 */
static void
CheckPathForIndexOperations(Path *path, ReplaceExtensionFunctionContext *context)
{
	check_stack_depth();
	CHECK_FOR_INTERRUPTS();

	if (IsA(path, BitmapOrPath))
	{
		BitmapOrPath *orPath = (BitmapOrPath *) path;
		WalkPathsForIndexOperations(orPath->bitmapquals, context);
	}
	else if (IsA(path, BitmapAndPath))
	{
		BitmapAndPath *andPath = (BitmapAndPath *) path;
		WalkPathsForIndexOperations(andPath->bitmapquals, context);
	}
	else if (IsA(path, BitmapHeapPath))
	{
		BitmapHeapPath *heapPath = (BitmapHeapPath *) path;
		CheckPathForIndexOperations(heapPath->bitmapqual, context);
	}
	else if (IsA(path, IndexPath))
	{
		IndexPath *indexPath = (IndexPath *) path;

		/* Ignore primary key lookup paths parented in a bitmap scan:
		 * This can happen because a RUM index lookup can produce a 0 cost query as well
		 * and Postgres picks both and does a BitmapAnd - instead rely on a top level index path.
		 */
		if (IsBtreePrimaryKeyIndex(indexPath->indexinfo) &&
			list_length(indexPath->indexclauses) > 1)
		{
			context->primaryKeyLookupPath = indexPath;
		}

		const VectorIndexDefinition *vectorDefinition = NULL;
		if (indexPath->indexorderbys != NIL)
		{
			/* Only check for vector when there's an order by */
			vectorDefinition = GetVectorIndexDefinitionByIndexAmOid(
				indexPath->indexinfo->relam);
		}

		if (vectorDefinition != NULL)
		{
			context->hasVectorSearchQuery = true;
			context->queryDataForVectorSearch.VectorAccessMethodOid =
				indexPath->indexinfo->relam;

			/*
			 * For vector search, we also need to extract the search parameter from the wrap function.
			 * ApiCatalogSchemaName.bson_search_param(document, '{ "nProbes": 4 }'::ApiCatalogSchemaName.bson)
			 */
			ExtractAndSetSearchParamterFromWrapFunction(indexPath, context);

			if (EnableVectorForceIndexPushdown)
			{
				context->forceIndexQueryOpData.type = ForceIndexOpType_VectorSearch;
				context->forceIndexQueryOpData.path = indexPath;
			}
		}
		else if (indexPath->indexinfo->relam == GIST_AM_OID &&
				 list_length(indexPath->indexorderbys) == 1)
		{
			/* Specific to geonear: Check if the geonear query is pushed to index */
			Expr *orderByExpr = linitial(indexPath->indexorderbys);
			if (IsA(orderByExpr, OpExpr) && ((OpExpr *) orderByExpr)->opno ==
				BsonGeonearDistanceOperatorId())
			{
				context->forceIndexQueryOpData.type = ForceIndexOpType_GeoNear;
				context->forceIndexQueryOpData.path = indexPath;
			}
		}
		else if (HasTextPathOpFamily(indexPath->indexinfo))
		{
			/* RUM/GIST indexes */
			ListCell *indexPathCell;
			foreach(indexPathCell, indexPath->indexclauses)
			{
				IndexClause *iclause = (IndexClause *) lfirst(indexPathCell);
				bytea *options = NULL;
				if (indexPath->indexinfo->opclassoptions != NULL)
				{
					options = indexPath->indexinfo->opclassoptions[iclause->indexcol];
				}

				/* Specific to text indexes: If the OpFamily is for Text, update the context
				 * with the index options for text. This is used later to process restriction info
				 * so that we can push down the TSQuery with the appropriate default language settings.
				 */
				if (IsTextPathOpFamilyOid(
						indexPath->indexinfo->relam,
						indexPath->indexinfo->opfamily[iclause->indexcol]))
				{
					/* If there's no options, set it. Otherwise, fail with "too many paths" */
					if (context->forceIndexQueryOpData.opExtraState != NULL)
					{
						ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
										errmsg("Excessive number of text expressions")));
					}
					context->forceIndexQueryOpData.type = ForceIndexOpType_Text;
					context->forceIndexQueryOpData.path = indexPath;
					QueryTextIndexData *textIndexData = palloc0(
						sizeof(QueryTextIndexData));
					textIndexData->indexOptions = options;
					context->forceIndexQueryOpData.opExtraState = (void *) textIndexData;
				}
			}
		}
	}
}


void
WalkPathsForIndexOperations(List *pathsList,
							ReplaceExtensionFunctionContext *context)
{
	ListCell *cell;
	foreach(cell, pathsList)
	{
		Path *path = (Path *) lfirst(cell);
		CheckPathForIndexOperations(path, context);
	}
}


/*
 * WalkRestrictionPathsForIndexOperations inspects restriction and join quals
 * to detect whether a primary key force-pushdown should be activated.
 *
 * It walks each qual via CheckRestrictionPathNodeForIndexOperation which
 * populates a PrimaryKeyLookupContext by detecting:
 *
 *  Qual type                                     | Detects                          | Sets
 *  ----------------------------------------------+----------------------------------+-------------------------------------------
 *  FuncExpr: BsonInMatchFunctionId on _id        | Runtime $in on _id               | runtimeDollarInRestrictionData
 *  FuncExpr: ApiCursorStateFunctionId            | Cursor continuation              | context->hasStreamingContinuationScan
 *  FuncExpr: ApiCursorTrackerFunctionId          | Dynamic cursor continuation      | context->hasDynamicStreamingContinuationScan
 *  FuncExpr: BsonIndexHintFunctionId             | Index hint                       | context->forceIndexQueryOpData (IndexHint)
 *  OpExpr:   BigintEqualOperatorId on shard_key  | shard_key_value = X              | shardKeyQualExpr
 *  OpExpr:   BsonEqualOperatorId on object_id    | object_id = val                  | objectId.restrictInfo
 *  OpExpr:   BsonEqualMatchRuntimeOperatorId _id | Runtime _id equality             | runtimeEqualityRestrictionData
 *  ScalarArrayOpExpr: BsonEqualOp on object_id   | object_id = ANY(...) ($in)       | objectId.restrictInfo
 *
 * After walking, if no other force-index op is set and both shardKeyQualExpr
 * and objectId.restrictInfo are populated, activates ForceIndexOpType_PrimaryKeyLookup.
 *
 * Note that, actual index path creation for primary key lookup is not done here - we only set the relevant context and then
 * the index path is created in the support function when we have all the necessary information. Index path creation happens later
 * in ForceIndexForQueryOperators → TryUseAlternateIndexForPrimaryKeyLookup.
 */
void
WalkRestrictionPathsForIndexOperations(List *restrictInfo,
									   List *joinInfo,
									   ReplaceExtensionFunctionContext *
									   context)
{
	PrimaryKeyLookupContext primaryKeyContext = { 0 };

	ListCell *cell;
	foreach(cell, restrictInfo)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, cell);
		CheckRestrictionPathNodeForIndexOperation(
			rinfo->clause, context, &primaryKeyContext, rinfo);
	}

	foreach(cell, joinInfo)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, cell);
		CheckRestrictionPathNodeForIndexOperation(
			rinfo->clause, context, &primaryKeyContext, rinfo);
	}

	/* Set primary key force pushdown if requested. */
	if (context->forceIndexQueryOpData.type == ForceIndexOpType_None &&
		primaryKeyContext.shardKeyQualExpr != NULL &&
		primaryKeyContext.objectId.restrictInfo != NULL)
	{
		PrimaryKeyLookupContext *pkContext = palloc(sizeof(PrimaryKeyLookupContext));
		primaryKeyContext.primaryKeyLookupPath = context->primaryKeyLookupPath;

		*pkContext = primaryKeyContext;
		context->forceIndexQueryOpData.type = ForceIndexOpType_PrimaryKeyLookup;
		context->forceIndexQueryOpData.path = NULL;
		context->forceIndexQueryOpData.opExtraState = pkContext;
	}
	else
	{
		list_free_deep(primaryKeyContext.runtimeDollarInRestrictionData);
		list_free_deep(primaryKeyContext.runtimeEqualityRestrictionData);
	}
}


/*
 * Given a set of restriction paths (Qualifiers) built from the query plan,
 * Replaces any unresolved bson_dollar_<op> functions with the equivalent
 * OpExpr calls across the primary path relations that are built from the logical
 * plan.
 * Note that This is done before the best path and scan plan is decided.
 * We do this here because we introduce functions like
 * "bson_dollar_eq" in the parse phase.
 * In the early plan phase, the support function maps the eq function to the index
 * as an operator if possible. However, in the case of BitMapHeap scan paths, the FuncExpr
 * rels are considered ON TOP of the OpExpr rels and Postgres today does not do an EquivalenceClass
 * between OpExpr and FuncExpr of the same type. Consequently, what ends up happening is that there's
 * an index scan with a Recheck on the function value and matched documents are revalidated.
 * To prevent this, we rewrite any unresolved functions as OpExpr values. This meets Postgres's equivalence
 * checks and therefore gets removed from the 'qpquals' (runtime post-evaluation quals) for a bitmap scan.
 * Note that this is not something we see in IndexScans since IndexScans directly use the index paths we pass
 * in via the support functions. Only BitMap scans are impacted here for the qpqualifiers.
 * This also has the benefit of having unified views on Explain wtih opexpr being the mode to view operators.
 */
List *
ReplaceExtensionFunctionOperatorsInRestrictionPaths(List *restrictInfo,
													ReplaceExtensionFunctionContext *
													context)
{
	if (list_length(restrictInfo) < 1)
	{
		return restrictInfo;
	}

	ListCell *cell;
	foreach(cell, restrictInfo)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, cell);
		if (context->inputData.isShardQuery &&
			context->inputData.collectionId > 0 &&
			IsOpExprShardKeyForUnshardedCollections(rinfo->clause,
													context->inputData.collectionId))
		{
			/* Simplify expression:
			 * On unsharded collections, we need the shard_key_value
			 * filter to route to the appropriate shard. However
			 * inside the shard, we know that the filter is always true
			 * so in this case, replace the shard_key_value filter with
			 * "TRUE" by removing it from the baserestrictinfo.
			 * We don't remove it from all paths and generation since we
			 * may need it for BTREE lookups with object_id filters.
			 */
			if (list_length(restrictInfo) == 1)
			{
				return NIL;
			}

			restrictInfo = foreach_delete_current(restrictInfo, cell);
			continue;
		}

		/* These paths don't have an index associated with it */
		bool trimClauses = true;
		Expr *expr = ProcessRestrictionInfoAndRewriteFuncExpr(rinfo->clause,
															  context, trimClauses);
		if (expr == NULL)
		{
			if (list_length(restrictInfo) == 1)
			{
				return NIL;
			}

			restrictInfo = foreach_delete_current(restrictInfo, cell);
			continue;
		}

		rinfo->clause = expr;
	}

	return restrictInfo;
}


/*
 * Given a List of Index Paths, walks the paths and substitutes any unresolved
 * and unreplaced bson_dollar_<op> functions with the equivalent OpExpr calls
 * across the various Index Path types (BitMap, IndexScan, SeqScan). This way
 * when the EXPLAIN output is read out, we see the @= operators instead of the
 * functions. This is primarily aesthetic for EXPLAIN output - but good to be
 * consistent.
 */
void
ReplaceExtensionFunctionOperatorsInPaths(PlannerInfo *root, RelOptInfo *rel,
										 List *pathsList, PlanParentType parentType,
										 ReplaceExtensionFunctionContext *context)
{
	if (list_length(pathsList) < 1)
	{
		return;
	}

	ListCell *cell;
	foreach(cell, pathsList)
	{
		Path *path = (Path *) lfirst(cell);
		lfirst(cell) = ReplaceFunctionOperatorsInPlanPath(root, rel, path, parentType,
														  context);
	}
}


/*
 * Returns true if the index is the primary key index for
 * the collections.
 */
bool
IsBtreePrimaryKeyIndex(IndexOptInfo *indexInfo)
{
	return indexInfo->relam == BTREE_AM_OID &&
		   indexInfo->nkeycolumns == 2 &&
		   indexInfo->unique &&
		   indexInfo->indexkeys[0] ==
		   DOCUMENT_DATA_TABLE_SHARD_KEY_VALUE_VAR_ATTR_NUMBER &&
		   indexInfo->indexkeys[1] == DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER;
}


/*
 * ForceIndexForQueryOperators ensures that the index path is available for a
 * query operator which requires a mandatory index, e.g ($geoNear, $text etc).
 *
 * Today we assume that only one such operator is used in a query, because we only try to
 * prioritize one index path, if the operator is not pushed to the index.
 *
 * Note: This function doesn't do any validation to make sure only one such operator is provided
 * in the query, so this should be done during the query construction.
 */
Path *
ForceIndexForQueryOperators(PlannerInfo *root, RelOptInfo *rel,
							ReplaceExtensionFunctionContext *context)
{
	if (context->forceIndexQueryOpData.type == ForceIndexOpType_None ||
		context->forceIndexQueryOpData.type >= ForceIndexOpType_Max)
	{
		/* If no special operator requirement */
		return NULL;
	}

	const ForceIndexSupportFuncs *forceIndexFuncs =
		&ForceIndexOperatorSupport[context->forceIndexQueryOpData.type];
	if (!forceIndexFuncs->enableForceIndexPushdown(root, context))
	{
		/* No index support functions !!, or force index pushdown not required then can't do anything */
		return NULL;
	}

	/*
	 * First check if the query for special operator is pushed to index and there are multiple index paths, then
	 * discard other paths so that only the index path for the special operator is used.
	 */
	if (context->forceIndexQueryOpData.path != NULL)
	{
		if (list_length(rel->pathlist) == 1)
		{
			/* If there is only one index path, then return */
			return NULL;
		}

		Path *matchingPath = FindIndexPathForQueryOperator(rel, rel->pathlist, context,
														   MatchIndexPathEquals,
														   context->forceIndexQueryOpData.
														   path);
		rel->partial_pathlist = NIL;
		rel->pathlist = list_make1(matchingPath);
		return matchingPath;
	}

	List *oldIndexList = rel->indexlist;
	List *oldPathList = rel->pathlist;
	List *oldPartialPathList = rel->partial_pathlist;

	Path *matchingPath = NULL;

	/* Only consider the indexes that we want to push to based on the operator */
	List *newIndexList = forceIndexFuncs->updateIndexes(oldIndexList, context);
	if (list_length(newIndexList) > 0)
	{
		/* Generate interesting index paths again with filtered indexes */
		rel->indexlist = newIndexList;
		rel->pathlist = NIL;
		rel->partial_pathlist = NIL;

		create_index_paths(root, rel);

		/* Check if index path was created for the operator based on matching criteria */
		matchingPath = FindIndexPathForQueryOperator(rel, rel->pathlist,
													 context,
													 forceIndexFuncs->matchIndexPath,
													 context->forceIndexQueryOpData.
													 opExtraState);
	}

	if (matchingPath == NULL)
	{
		/* We didn't find any index path for the query operators by just updating the
		 * indexlist, if the operator supports alternate index pushdown delegate to the
		 * operator otherwise its just a failure to find the index.
		 */
		bool alternatePathCreated = false;
		if (forceIndexFuncs->alternatePath != NULL)
		{
			alternatePathCreated =
				forceIndexFuncs->alternatePath(root, rel, context,
											   forceIndexFuncs->matchIndexPath);
		}

		if (!alternatePathCreated)
		{
			forceIndexFuncs->noIndexHandler();
		}
		else if (list_length(rel->pathlist) > 0)
		{
			/* If alternate path is created, then we can use the first path as the matching path */
			matchingPath = linitial(rel->pathlist);
		}
	}


	rel->indexlist = oldIndexList;
	if (rel->pathlist == NIL)
	{
		/* Just use the old pathlist if no new paths are added and there is no error
		 * because we want to continue with the query
		 */
		rel->pathlist = oldPathList;
		rel->partial_pathlist = oldPartialPathList;
	}

	return matchingPath;
}


/* Returns true if var is the document column of the relation this scan path is for. */
static bool
IsCurrentScanDocumentVar(Var *var, PlannerInfo *root, Index scanRti)
{
	/* Requires a local BSON Var from the same query source as the scan path,
	 * then confirm that source is a real relation (not a CTE or subquery).
	 */
	if (var->varlevelsup != 0 ||
		var->varno != (int) scanRti ||
		var->varattno != DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER ||
		(var->vartype != BsonTypeId() && var->vartype != DocumentDBCoreBsonTypeId()))
	{
		return false;
	}

	return planner_rt_fetch(var->varno, root)->rtekind == RTE_RELATION;
}


static bool
ProjectionReferencesDocumentVarOrQuery(Expr *node, void *state)
{
	CHECK_FOR_INTERRUPTS();

	if (node == NULL)
	{
		return false;
	}

	if (IsA(node, Var))
	{
		Var *var = (Var *) node;
		ProjectionVarQueryState *projectionState = (ProjectionVarQueryState *) state;
		if (!IsCurrentScanDocumentVar(var, projectionState->root,
									  projectionState->scanRti))
		{
			projectionState->hasNonDocumentVar = true;
			return true;
		}
		else
		{
			projectionState->hasDocumentVar = true;

			/* If we find a document var, we want to continue walking
			 * the tree to see if there are any non-document vars or queries. */
		}
	}
	else if (IsA(node, Query))
	{
		ProjectionVarQueryState *projectionState = (ProjectionVarQueryState *) state;
		projectionState->hasQuery = true;
		return true;
	}

	return expression_tree_walker((Node *) node, ProjectionReferencesDocumentVarOrQuery,
								  state);
}


static inline bool
IndexStrategySupportsIndexOnlyScan(BsonIndexStrategy indexStrategy)
{
	return !IsNegationStrategy(indexStrategy) &&
		   indexStrategy != BSON_INDEX_STRATEGY_INVALID &&
		   indexStrategy != BSON_INDEX_STRATEGY_DOLLAR_GEOINTERSECTS &&
		   indexStrategy != BSON_INDEX_STRATEGY_DOLLAR_GEOWITHIN &&
		   indexStrategy != BSON_INDEX_STRATEGY_DOLLAR_TEXT &&
		   indexStrategy != BSON_INDEX_STRATEGY_DOLLAR_ELEMMATCH &&
		   indexStrategy != BSON_INDEX_STRATEGY_DOLLAR_TYPE &&
		   indexStrategy != BSON_INDEX_STRATEGY_DOLLAR_SIZE;
}


static inline bool
IsScalarArrayOpExprTrimmable(const ScalarArrayOpExpr *scalarArrayOpExpr)
{
	return scalarArrayOpExpr->opno == BsonIndexBoundsEqualOperatorId();
}


static inline bool
IsFuncExprTrimmable(const FuncExpr *funcExpr)
{
	return funcExpr->funcid == BsonIndexHintFunctionOid() ||
		   funcExpr->funcid == BsonFullScanFunctionOid() ||
		   (IsClusterVersionAtleast(DocDB_V0, 112, 1) &&
			funcExpr->funcid == ApiCursorTrackerFunctionId());
}


static bool
IsExprTrimmable(Expr *expr)
{
	if (IsA(expr, FuncExpr))
	{
		return IsFuncExprTrimmable((FuncExpr *) expr);
	}
	if (IsA(expr, ScalarArrayOpExpr))
	{
		return IsScalarArrayOpExprTrimmable((ScalarArrayOpExpr *) expr);
	}

	return false;
}


static bool
IsBsonValueArgumentValidForIndexOnlyScan(const bson_value_t *bsonValue)
{
	/* These are special and need runtime recheck. */
	if (IsBsonValueEmptyArray(bsonValue) || bsonValue->value_type == BSON_TYPE_NULL)
	{
		return false;
	}

	return true;
}


static bool
CheckOpArgIsValidForIndexOnlyScan(Const *arg, bytea *indexOptions, BsonIndexStrategy
								  indexStrategy)
{
	if (indexOptions == NULL)
	{
		return false;
	}

	Datum queryValue = arg->constvalue;
	pgbsonelement queryElement;
	const char *queryCollation = PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(
																			  queryValue),
																		  &queryElement);

	if (indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_IN)
	{
		bson_iter_t iter;
		BsonValueInitIterator(&queryElement.bsonValue, &iter);
		while (bson_iter_next(&iter))
		{
			const bson_value_t *arrayValue = bson_iter_value(&iter);
			if (!IsBsonValueArgumentValidForIndexOnlyScan(arrayValue))
			{
				return false;
			}
		}
	}
	else if (!IsBsonValueArgumentValidForIndexOnlyScan(&queryElement.bsonValue))
	{
		return false;
	}

	return ValidateIndexForQualifierElement(indexOptions, &queryElement, queryCollation,
											indexStrategy);
}


static bool
ExprIsValidForIndexOnlyScan(Expr *expr, bytea *indexOptions, bool *isShardKeyExpr,
							int64 *shardKeyValue)
{
	check_stack_depth();
	CHECK_FOR_INTERRUPTS();

	if (IsExprTrimmable(expr))
	{
		/* If the clause is something that we can trim off for index only scan, then it's valid for index only scan. */
		return true;
	}

	if (IsA(expr, OpExpr) || IsA(expr, FuncExpr))
	{
		List *args = NIL;
		const MongoIndexOperatorInfo *operator = NULL;

		/* Can't use the function that gets the mongo index operator info from node
		 *  because that one gets the funcId from the opExpr and there are some cases at the planner
		 *  layer where the opExpr funcId isn't populated when we transform the funcExpr into opExpr
		 *  so we get an invalid operator strategy, because of that we call each API depending on the expr kind.*/
		if (IsA(expr, OpExpr))
		{
			OpExpr *opExpr = (OpExpr *) expr;
			args = opExpr->args;
			operator = GetMongoIndexOperatorByPostgresOperatorId(opExpr->opno);
		}
		else
		{
			FuncExpr *funcExpr = (FuncExpr *) expr;
			args = funcExpr->args;
			operator = GetMongoIndexOperatorInfoByPostgresFuncId(funcExpr->funcid);
		}

		if (operator == NULL || list_length(args) != 2)
		{
			/* We only support binary operators for index only scan. */
			return false;
		}

		if (operator->indexStrategy == BSON_INDEX_STRATEGY_INVALID)
		{
			/* @<> range match: valid for index only scans if the field path is covered by the index. */
			if (IsA(expr, OpExpr) &&
				((OpExpr *) expr)->opno == BsonRangeMatchOperatorOid())
			{
				if (!EnableIndexOnlyScanForRangeMatch)
				{
					return false;
				}

				Expr *secondArg = lsecond(args);
				if (IsA(secondArg, Const))
				{
					return CheckOpArgIsValidForIndexOnlyScan(
						(Const *) secondArg, indexOptions,
						BSON_INDEX_STRATEGY_DOLLAR_RANGE);
				}

				return false;
			}

			bool isOpExprShardKeyResult = IsOpExprShardKeyEquality(expr, shardKeyValue);
			if (isShardKeyExpr != NULL)
			{
				*isShardKeyExpr = isOpExprShardKeyResult;
			}

			return isOpExprShardKeyResult;
		}

		if (!IndexStrategySupportsIndexOnlyScan(operator->indexStrategy))
		{
			return false;
		}

		Expr *secondArg = lsecond(args);
		if (!IsA(secondArg, Const))
		{
			return false;
		}

		return CheckOpArgIsValidForIndexOnlyScan((Const *) secondArg, indexOptions,
												 operator->indexStrategy);
	}
	else if (IsA(expr, BoolExpr))
	{
		/* For BoolExpr, we recursively check if all the arguments are valid for index only scan. */
		BoolExpr *boolExpr = (BoolExpr *) expr;
		ListCell *boolArgs;
		foreach(boolArgs, boolExpr->args)
		{
			Expr *boolArg = (Expr *) lfirst(boolArgs);
			bool isShardKeyExprInner = false;
			if (!ExprIsValidForIndexOnlyScan(boolArg, indexOptions, &isShardKeyExprInner,
											 shardKeyValue))
			{
				return false;
			}

			if (isShardKeyExpr != NULL)
			{
				*isShardKeyExpr = *isShardKeyExpr || isShardKeyExprInner;
			}
		}

		return true;
	}

	return false;
}


static bool
IndexClauseIsValidForIndexOnlyScan(const IndexClause *clause, bytea *indexOptions)
{
	if (clause->lossy)
	{
		return false;
	}

	if (clause->indexcol != 0 ||
		list_length(clause->indexquals) != 1)
	{
		/* Only support indexonlyscan if the index clause is on the first column */
		return false;
	}

	RestrictInfo *rinfo = clause->rinfo;

	/* We ignore if it is a shard key expression or not as for rum indexes a shard key value opExpr will never be valid to be pushed down. */
	bool isShardKeyExpr = false;
	return ExprIsValidForIndexOnlyScan(rinfo->clause, indexOptions, &isShardKeyExpr,
									   NULL);
}


static bool
IndexRestrictInfoSupportIndexOnlyScan(const RestrictInfo *rinfo,
									  bytea *indexOptions,
									  const RestrictInfo **shardKeyRestrictInfo,
									  int64 *shardKeyValue)
{
	if (indexOptions == NULL)
	{
		return false;
	}

	bool isShardKeyExpr = false;
	bool supportsIndexOnlyScan = ExprIsValidForIndexOnlyScan(rinfo->clause, indexOptions,
															 &isShardKeyExpr,
															 shardKeyValue);
	if (isShardKeyExpr && shardKeyRestrictInfo != NULL)
	{
		*shardKeyRestrictInfo = rinfo;
	}

	return supportsIndexOnlyScan;
}


static bool
IndexClausesSupportIndexOnlyScan(IndexPath *indexPath,
								 RelOptInfo *rel,
								 ReplaceExtensionFunctionContext *replaceContext)
{
	bytea *indexOptions = indexPath->indexinfo->opclassoptions != NULL ?
						  indexPath->indexinfo->opclassoptions[0] : NULL;
	if (indexOptions == NULL)
	{
		return false;
	}

	ListCell *clauseCell;
	foreach(clauseCell, indexPath->indexclauses)
	{
		IndexClause *clause = (IndexClause *) lfirst(clauseCell);

		if (!IndexClauseIsValidForIndexOnlyScan(clause, indexOptions))
		{
			return false;
		}
	}

	ListCell *rinfoCell;
	foreach(rinfoCell, indexPath->indexinfo->indrestrictinfo)
	{
		RestrictInfo *baseRestrictInfo = (RestrictInfo *) lfirst(rinfoCell);

		const RestrictInfo *shardKeyRestrictInfo = NULL;

		/* at the planner layer these are trimmed out so we shouldn't see them for index only scan here. */
		if (!IndexRestrictInfoSupportIndexOnlyScan(baseRestrictInfo, indexOptions,
												   &shardKeyRestrictInfo, NULL))
		{
			return false;
		}

		/* if we have a shard key value filter we can only do index only scan for unsharded for RUM indexes because if it is sharded the shard key value needs to be evaluated at runtime and that goes against
		 * the index only scan semantics.
		 */
		if (shardKeyRestrictInfo != NULL &&
			(!replaceContext->plannerOrderByData.isShardKeyEqualityOnUnsharded ||
			 shardKeyRestrictInfo !=
			 replaceContext->plannerOrderByData.shardKeyEqualityExpr))
		{
			return false;
		}
	}

	/* All indexclauses are covered by the index and are not lossy operators. */
	return true;
}


static bool
PlanHasAggregates(PlannerInfo *root)
{
	return list_length(root->agginfos) != 0 ||
		   (root->parent_root != NULL && PlanHasAggregates(root->parent_root));
}


static bool
PlanHasGroupBy(PlannerInfo *root)
{
	return list_length(root->group_pathkeys) != 0 ||
		   (root->parent_root != NULL && PlanHasGroupBy(root->parent_root));
}


static pgbson *
TryExtractPgbsonFromConst(Expr *expr)
{
	if (!IsA(expr, Const))
	{
		return NULL;
	}

	Const *constExpr = (Const *) expr;
	if (!(constExpr->consttype == BsonTypeId() || constExpr->consttype ==
		  DocumentDBCoreBsonTypeId()) || constExpr->constisnull)
	{
		return NULL;
	}

	return DatumGetPgBson(constExpr->constvalue);
}


/* Returns the field path from a constant BSON expression, or NULL if not applicable. */
static const char *
TryExtractFieldPathFromConst(Expr *expr)
{
	pgbson *pathBson = TryExtractPgbsonFromConst(expr);
	if (pathBson == NULL)
	{
		return NULL;
	}

	pgbsonelement pathElement;
	if (!TryGetSinglePgbsonElementFromPgbson(pathBson, &pathElement))
	{
		return NULL;
	}

	if (pathElement.bsonValue.value_type == BSON_TYPE_UTF8)
	{
		if (pathElement.bsonValue.value.v_utf8.len < 2 ||
			pathElement.bsonValue.value.v_utf8.str[0] != '$' ||
			pathElement.bsonValue.value.v_utf8.str[1] == '$')
		{
			/* must be "$fieldName"; reject non-field-path values and
			 * "$$" system variables like $$NOW, $$CLUSTER_TIME, etc. */
			return NULL;
		}

		/* Strip off the leading '$' to get the raw field path. */
		return pathElement.bsonValue.value.v_utf8.str + 1;
	}
	else if (pathElement.bsonValue.value_type == BSON_TYPE_DOCUMENT)
	{
		pgbsonelement docElement;
		if (TryGetSingleFieldPathFromBsonValue(&pathElement.bsonValue,
											   &docElement))
		{
			/* Strip off the leading '$' to get the raw field path. */
			return docElement.bsonValue.value.v_utf8.str + 1;
		}

		return NULL;
	}

	return NULL;
}


static bool
IsFieldPathCoveredByIndex(const char *fieldPath, IndexPath *indexPath)
{
	int8_t sortDirectionIgnored = 0;
	int32_t colNum = GetCompositeOpClassColumnNumber(
		fieldPath,
		indexPath->indexinfo->opclassoptions[0], /*[0] because there's only one column indexed (Document)*/
		&sortDirectionIgnored);

	return colNum >= 0;
}


/* Strips any RelabelType nodes from the expression, returning the underlying expression. */
static Expr *
StripRelabels(Expr *expr)
{
	while (expr != NULL && IsA(expr, RelabelType))
	{
		expr = (Expr *) ((RelabelType *) expr)->arg;
	}

	return expr;
}


/* Returns the sort path from a constant BSON expression, or NULL if not applicable. */
static const char *
TryExtractSortPathFromConst(Expr *expr)
{
	pgbson *sortBson = TryExtractPgbsonFromConst(expr);
	if (sortBson == NULL)
	{
		return NULL;
	}

	/* Unlike field paths, sort paths are not prefixed with a $.*/
	pgbsonelement sortElement;
	PgbsonToSinglePgbsonElement(sortBson, &sortElement);
	return sortElement.path;
}


static bool
IsProjectionCoveredByIndex(Expr *expr, IndexPath *indexPath)
{
	pgbson *projectBson = TryExtractPgbsonFromConst(expr);
	if (projectBson == NULL)
	{
		return false;
	}

	bool isIdProjectedByDefault = true;
	bool checkFixedInteger = false;
	bool hasInclusion = false;
	bson_iter_t bsonIter;
	PgbsonInitIterator(projectBson, &bsonIter);

	while (bson_iter_next(&bsonIter))
	{
		const char *fieldPath = bson_iter_key(&bsonIter);
		const bson_value_t *bsonValue = bson_iter_value(&bsonIter);

		/*
		 * Expression projections cannot be reasoned about for coverage.
		 * TODO: projections like: {a: { b: 1 }} are completely valid, we should consider those.
		 */
		if (!IsBsonValue64BitInteger(bsonValue, checkFixedInteger))
		{
			return false;
		}

		bool isIdProjection = strcmp(fieldPath, "_id") == 0;
		bool isExclusion = BsonValueAsInt64(bsonValue) == 0;

		if (isIdProjection)
		{
			/* If _id: 1, we will check as part of walking the spec. If _id: 0,
			 * it is not projected by default. */
			isIdProjectedByDefault = false;

			/* The only exclusion we can have such that an index only scan can work is _id: 0. */
			if (isExclusion)
			{
				continue;
			}
		}
		else if (isExclusion)
		{
			/* If we have a non _id exclusion we can just bail, since projection doesn't allow mixed inclusion and exclusion for non id fields. */
			return false;
		}

		hasInclusion = true;

		if (!IsFieldPathCoveredByIndex(fieldPath, indexPath))
		{
			return false;
		}
	}

	/* Pure-exclusion projections (e.g { _id: 0 }) need to read every other field, which we
	 * cannot reason about - no IOS. */
	if (!hasInclusion)
	{
		return false;
	}

	if (isIdProjectedByDefault && !IsFieldPathCoveredByIndex("_id", indexPath))
	{
		return false;
	}

	return true;
}


static bool
IsSortPathFunctionOid(Oid oid)
{
	if (oid == BsonOrderByFunctionOid() ||
		oid == BsonOrderByWithCollationFunctionOid() ||
		oid == BsonOrderByIndexFunctionOid() ||
		oid == BsonOrderByIndexReverseFunctionOid())
	{
		return true;
	}

	if (IsClusterVersionAtleast(DocDB_V0, 110, 0) &&
		oid == BsonOrderByIndexWithCollationFunctionOid())
	{
		return true;
	}

	if (IsClusterVersionAtleast(DocDB_V0, 111, 0) &&
		oid == BsonOrderByIndexWithCollationReverseFunctionOid())
	{
		return true;
	}

	return false;
}


inline static bool
IsExpressionPathFunctionOid(Oid oid)
{
	return oid == BsonExpressionGetFunctionOid() ||
		   oid == BsonExpressionGetWithLetFunctionOid() ||
		   oid == BsonExpressionGetWithLetAndCollationFunctionOid();
}


inline static bool
IsProjectFunctionOid(Oid oid)
{
	return oid == BsonDollarProjectFunctionOid() ||
		   oid == BsonDollarProjectWithLetFunctionOid() ||
		   oid == BsonDollarProjectWithLetAndCollationFunctionOid() ||
		   oid == BsonDollarProjectFindFunctionOid() ||
		   oid == BsonDollarProjectFindWithLetFunctionOid() ||
		   oid == BsonDollarProjectFindWithLetAndCollationFunctionOid();
}


/* tree_walker_callback that recursively checks if all field paths in the tree are covered by the index.
 * Returns true to exit early if any uncovered path is found. */
static bool
CheckFieldCoverage(Node *node, void *context)
{
	check_stack_depth();
	CHECK_FOR_INTERRUPTS();

	FieldCoverageState *state = (FieldCoverageState *) context;

	if (node == NULL)
	{
		return false;
	}

	/* We need to check Aggrefs in addition to functions because they may have a field path directly under the Aggref, not inside a FuncExpr. */
	if (IsA(node, Aggref))
	{
		/* There are two shapes of aggregates:
		 *  1. The child node is a FuncExpr
		 *  2. The field path is directly on the Aggref args
		 *
		 *  We try to find a direct Var(document) and a BSON const.
		 *  If we can't find it, we are probably in case one, so we recurse to the FuncExpr.
		 *  If we find it, we check if the field path is covered by the index. If not, we can mark the field coverage as uncovered and abort.
		 */

		const char *fieldPath = NULL;
		bool sawDocumentVar = false;
		bool sawEmptyBsonConst = false;

		Aggref *aggref = (Aggref *) node;
		ListCell *aggArgCell;

		foreach(aggArgCell, aggref->args)
		{
			Expr *argExpr = StripRelabels(((TargetEntry *) lfirst(aggArgCell))->expr);
			if (IsA(argExpr, Var) &&
				IsCurrentScanDocumentVar((Var *) argExpr, state->root,
										 state->expectedRti))
			{
				sawDocumentVar = true;
				continue;
			}

			/* Detect placeholder empty-BSON Consts emitted by
			 * GetDocumentExprForGroupAccumulatorValue() when the accumulator
			 * expression is a constant (e.g., $sum: 1). These carry no field
			 * reference, so they don't disqualify the aggregate from IOS.
			 */
			if (IsA(argExpr, Const))
			{
				pgbson *constBson = TryExtractPgbsonFromConst(argExpr);
				if (constBson != NULL && IsPgbsonEmptyDocument(constBson))
				{
					sawEmptyBsonConst = true;
					continue;
				}
			}

			/* Currently, we only handle aggregate functions with two arguments, and one field path. */
			if (fieldPath == NULL)
			{
				fieldPath = TryExtractFieldPathFromConst(argExpr);
			}
		}

		Assert(!(sawEmptyBsonConst && fieldPath != NULL));
		Assert(!(sawDocumentVar && sawEmptyBsonConst));

		if (sawDocumentVar && fieldPath != NULL)
		{
			if (!IsFieldPathCoveredByIndex(fieldPath, state->indexPath))
			{
				/* Field path is not in this index so we can't do index-only. */
				state->hasUncoveredField = true;
				return true; /* abort the walk early */
			}

			return false; /* Type 2 agg handled; don't recurse */
		}

		/* Constant-valued accumulator (e.g., $sum: 1): the
		 * accumulator expression was constant-folded by
		 * GetDocumentExprForGroupAccumulatorValue() to an empty BSON Const,
		 * and the document Var is unused. There is no field reference to
		 * cover, so this aggregate is safe for index-only scan.
		 */
		if (sawEmptyBsonConst && fieldPath == NULL)
		{
			return false; /* Type 2 agg with constant operand; don't recurse */
		}

		return expression_tree_walker(node, CheckFieldCoverage, context); /* Type 1 agg; recurse to inner Func */
	}

	if (IsA(node, FuncExpr))
	{
		FuncExpr *funcExpr = (FuncExpr *) node;

		if (funcExpr->funcid == DocumentDBCoreBsonToBsonFunctionOId())
		{
			/* This is a wrapper function. */
			return expression_tree_walker(node, CheckFieldCoverage, context);
		}

		/* Check if the first argument is the document Var and the second argument is a constant path. */
		if (list_length(funcExpr->args) >= 2)
		{
			Expr *firstArg = StripRelabels(linitial(funcExpr->args));
			Expr *secondArg = StripRelabels(lsecond(funcExpr->args));
			if (IsA(firstArg, Var) && IsCurrentScanDocumentVar((Var *) firstArg,
															   state->root,
															   state->expectedRti))
			{
				const char *fieldPath = NULL;

				if (IsSortPathFunctionOid(funcExpr->funcid))
				{
					fieldPath = TryExtractSortPathFromConst(secondArg);
				}
				else if (IsExpressionPathFunctionOid(funcExpr->funcid))
				{
					fieldPath = TryExtractFieldPathFromConst(secondArg);
				}
				else if (EnableIndexOnlyScanForFindProject &&
						 IsProjectFunctionOid(funcExpr->funcid))
				{
					/* all our bson_dollar_project variants take the projection as the second argument. */
					bool isProjectionCoveredByIndex = IsProjectionCoveredByIndex(
						secondArg, state->indexPath);
					state->hasUncoveredField = !isProjectionCoveredByIndex;
					return state->hasUncoveredField;
				}
				else if (EnableDistinctIndexPushdown &&
						 funcExpr->funcid == BsonDistinctUnwindFunctionOid() &&
						 IsA(secondArg, Const))
				{
					Const *constArg = (Const *) secondArg;
					if (constArg->constisnull)
					{
						/* If the constant is null, we can't do index-only scan. */
						state->hasUncoveredField = true;
						return true;
					}

					fieldPath = TextDatumGetCString(constArg->constvalue);
				}
				else
				{
					/* To be safe, err on the side of not using index-only scan when the function is not recognized. */
					state->hasUncoveredField = true;
					return true;
				}

				if (fieldPath == NULL || !IsFieldPathCoveredByIndex(fieldPath,
																	state->indexPath))
				{
					/* Path is not in this index so we can't do index-only. */
					state->hasUncoveredField = true;
					return true; /* abort the walk early */
				}

				return false;
			}
		}
	}

	if (IsA(node, Var))
	{
		/* If there's a Var node, that means there's a reference to a field that's not covered by the index. */
		state->hasUncoveredField = true;
		return true; /* abort the walk early */
	}

	return expression_tree_walker(node, CheckFieldCoverage, context);
}


/*
 * Returns true if all targets in the query are covered by the index.
 *
 * A target is considered covered by the index when every field it reference is either:
 *   1. a constant-only expression (e.g., $count), or
 *   2. a document field extraction of the form bson_expression_get(document, path) where 'path' is a
 *      constant string that matches a field path in the index.
 *
 * If any target contains a field reference outside those covered shapes, the function returns false.
 */
static bool
AreAllTargetsCoveredByIndex(PlannerInfo *root, IndexPath *indexPath)
{
	FieldCoverageState state = {
		.hasUncoveredField = false,
		.indexPath = indexPath,
		.expectedRti = indexPath->path.parent->relid,
		.root = root
	};

	ListCell *cell;
	foreach(cell, root->processed_tlist) /* for each target in the query... */
	{
		TargetEntry *targetEntry = (TargetEntry *) lfirst(cell);
		CheckFieldCoverage((Node *) targetEntry->expr, &state);

		if (state.hasUncoveredField)
		{
			return false;
		}
	}

	return true;
}


static bool
IsQueryEligibleForIndexOnlyScan(PlannerInfo *root, Index scanRti, bool *hasDocumentVar)
{
	bool planHasAggregates = PlanHasAggregates(root);
	bool planHasGroupby = PlanHasGroupBy(root);
	if (root->hasJoinRTEs ||
		(!planHasAggregates && !planHasGroupby && !EnableIndexOnlyScanForFindProject))
	{
		return false;
	}

	ProjectionVarQueryState projectionState = {
		.hasDocumentVar = false,
		.hasNonDocumentVar = false,
		.hasQuery = false,
		.root = root,
		.scanRti = scanRti
	};
	expression_tree_walker((Node *) root->processed_tlist,
						   ProjectionReferencesDocumentVarOrQuery,
						   &projectionState);

	if (projectionState.hasDocumentVar)
	{
		if (!EnableIndexOnlyScanForCoveredAggregateTargets && (planHasAggregates ||
															   planHasGroupby))
		{
			return false;
		}

		if (hasDocumentVar != NULL)
		{
			*hasDocumentVar = true;
		}
	}

	if (projectionState.hasQuery)
	{
		/* If there are subqueries in the projection,
		 * we can't do index only scans because we can't cover the projection. */
		return false;
	}

	if (projectionState.hasNonDocumentVar)
	{
		/* If there are non-document variables in the projection, we can't do index only scans. */
		return false;
	}

	return true;
}


/*
 * Check whether we can handle index scans as index only scans.
 * This is possible if:
 * 1) The query is against a base table
 * 2) There are no joins
 * 3) Projection is covered (Today this requires projection to be a constant but
 *    this can be extended in the future)
 * 4) Filters are covered by the index.
 * 5) The index filters are are not lossy operators.
 * 6) The index is a composite index.
 */
void
ConsiderIndexOnlyScan(PlannerInfo *root, RelOptInfo *rel, RangeTblEntry *rte,
					  Index rti, ReplaceExtensionFunctionContext *context)
{
	if (rte->rtekind != RTE_RELATION || !enable_indexonlyscan)
	{
		return;
	}

	bool hasDocumentVar = false;
	if (!IsQueryEligibleForIndexOnlyScan(root, rti, &hasDocumentVar))
	{
		return;
	}

	if (rel->pathlist == NIL)
	{
		/* No paths to consider */
		return;
	}

	List *addedPaths = NIL;
	ListCell *cell;
	foreach(cell, rel->pathlist)
	{
		bool isBitmapPath = false;
		Path *path = (Path *) lfirst(cell);
		if (IsA(path, BitmapHeapPath))
		{
			BitmapHeapPath *bitmapPath = (BitmapHeapPath *) path;

			if (IsA(bitmapPath->bitmapqual, IndexPath))
			{
				/* In this case, the bitmap path is based on an index path (e.g., BitmapHeapPath->IndexPath on index),
				 * and we may be able to remove the BitmapHeapPath*/
				path = (Path *) bitmapPath->bitmapqual;
				isBitmapPath = true;
			}
		}

		if (!IsA(path, IndexPath))
		{
			continue;
		}

		bool isBtreeIndex = false;
		IndexPath *indexPath = (IndexPath *) path;

		if (indexPath->path.pathtype == T_IndexOnlyScan)
		{
			/* Already an index only scan if it is under a bitmap heap scan, we try to cost it and add it
			 * to let the planner decide whether promoting the index only scan is better or not. */
			if (isBitmapPath)
			{
				bool partialPath = false;
				double loopCount = 1.0;
				cost_index(indexPath, root, loopCount, partialPath);
				addedPaths = lappend(addedPaths, indexPath);
			}

			continue;
		}

		if (IsBtreePrimaryKeyIndex(indexPath->indexinfo))
		{
			if (hasDocumentVar || !ForceIndexOnlyScanIfAvailable)
			{
				continue;
			}

			isBtreeIndex = true;
			bool hasOtherQuals = false;
			IndexPath *modified = TrimIndexRestrictInfoForBtreePath(root, indexPath,
																	&hasOtherQuals);
			if (hasOtherQuals)
			{
				/* Not modified or has non _id quals - skip */
				continue;
			}

			if (modified == indexPath)
			{
				indexPath = palloc(sizeof(IndexPath));
				memcpy(indexPath, modified, sizeof(IndexPath));
			}
			else
			{
				indexPath = modified;
			}
		}
		else
		{
			if (!ForceIndexOnlyScanIfAvailable && EnableIndexOnlyScanOnCostFunction)
			{
				/* Only convert on the planner if we want to force it or if the cost function is not enabled. */
				continue;
			}

			if (indexPath->indexinfo->nkeycolumns < 1 ||
				!IsOrderBySupportedOnOpClass(indexPath->indexinfo->relam,
											 indexPath->indexinfo->opfamily[0]))
			{
				continue;
			}

			if (!CompositeIndexSupportsIndexOnlyScan(indexPath))
			{
				continue;
			}

			if (!IndexClausesSupportIndexOnlyScan(indexPath, rel, context))
			{
				continue;
			}

			if (!AreAllTargetsCoveredByIndex(root, indexPath))
			{
				continue;
			}
		}

		/* we need to copy the index path and set it as index only scan.
		 * Also we need to set canreturn to true so that postgres allows the index only scan path. */
		IndexPath *indexPathCopy;
		if (!isBtreeIndex)
		{
			indexPathCopy = makeNode(IndexPath);
			memcpy(indexPathCopy, indexPath, sizeof(IndexPath));

			indexPathCopy->indexinfo = palloc(sizeof(IndexOptInfo));
			memcpy(indexPathCopy->indexinfo, indexPath->indexinfo,
				   sizeof(IndexOptInfo));

			indexPathCopy->indexinfo->canreturn = palloc0(sizeof(bool) *
														  indexPathCopy->indexinfo->
														  ncolumns);
			indexPathCopy->indexinfo->canreturn[0] = true;
		}
		else
		{
			/* This is pre-copied by TrimIndexRestrictInfoForBtreePath */
			indexPathCopy = indexPath;
		}

		indexPathCopy->path.pathtype = T_IndexOnlyScan;

		bool partialPath = false;
		double loopCount = 1.0;
		cost_index(indexPathCopy, root, loopCount, partialPath);

		addedPaths = lappend(addedPaths, indexPathCopy);
	}

	if (ForceIndexOnlyScanIfAvailable &&
		list_length(addedPaths) > 0)
	{
		/* reset pathlist to only have these */
		rel->pathlist = addedPaths;
		rel->partial_pathlist = NIL;
	}
	else
	{
		ListCell *pathsToAddCell;
		foreach(pathsToAddCell, addedPaths)
		{
			/* now add the new paths */
			Path *newPath = lfirst(pathsToAddCell);
			add_path(rel, newPath);
		}

		list_free(addedPaths);
	}
}


inline static IndexOptInfo *
GetPrimaryKeyIndexOptInfo(RelOptInfo *rel)
{
	ListCell *index;
	foreach(index, rel->indexlist)
	{
		IndexOptInfo *indexInfo = lfirst(index);
		if (IsBtreePrimaryKeyIndex(indexInfo))
		{
			return indexInfo;
		}
	}

	return NULL;
}


void
ConsiderBtreeOrderByPushdown(PlannerInfo *root, IndexPath *indexPath)
{
	bool isOrderById = false;
	bool hasGroupby = false;
	bool hasDistinct = false;
	List *sortDetails = GetSortDetails(root, indexPath->path.parent->relid, &hasGroupby,
									   &isOrderById, &hasDistinct);

	if (sortDetails == NIL || !isOrderById)
	{
		list_free_deep(sortDetails);
		return;
	}

	if (!IsValidIndexPathForIdOrderBy(indexPath, sortDetails))
	{
		list_free_deep(sortDetails);
		return;
	}

	/*
	 * We have a single sort and a primary key - consider if
	 * it is an _id pushdown.
	 */
	SortIndexInputDetails *sortDetailsInput = linitial(sortDetails);

	/* The first clause is a shard key equality - can push order by */
	indexPath->path.pathkeys = list_make1(sortDetailsInput->sortPathKey);

	/* If the sort is descending, we need to scan the index backwards */
	if (SortPathKeyStrategy(sortDetailsInput->sortPathKey) == BTGreaterStrategyNumber)
	{
		indexPath->indexscandir = BackwardScanDirection;
	}

	list_free_deep(sortDetails);
}


void
documentdb_btcostestimate(PlannerInfo *root, IndexPath *path, double loop_count,
						  Cost *indexStartupCost, Cost *indexTotalCost,
						  Selectivity *indexSelectivity, double *indexCorrelation,
						  double *indexPages)
{
	bool convertedToIndexOnlyScan = false;

	if (EnableOrderByIdOnCostFunction &&
		list_length(root->query_pathkeys) == 1)
	{
		ConsiderBtreeOrderByPushdown(root, path);
	}

	bool hasDocumentVar = false;
	if (enable_indexonlyscan && EnableIndexOnlyScan &&
		IsQueryEligibleForIndexOnlyScan(root, path->path.parent->relid,
										&hasDocumentVar) &&
		!hasDocumentVar)
	{
		bool hasOtherQuals = false;
		IndexPath *modified = TrimIndexRestrictInfoForBtreePath(root, path,
																&hasOtherQuals);
		if (!hasOtherQuals)
		{
			*path = *modified;
			path->path.pathtype = T_IndexOnlyScan;
			convertedToIndexOnlyScan = true;
		}

		if (modified != path)
		{
			/* Free if copy */
			pfree(modified);
		}
	}

	btcostestimate(root, path, loop_count, indexStartupCost, indexTotalCost,
				   indexSelectivity, indexCorrelation, indexPages);

	if (convertedToIndexOnlyScan)
	{
		/*
		 * We convert this path to T_IndexOnlyScan inside the AM cost callback.
		 * At that point, PostgreSQL's cost_index() has already taken the is-index-only
		 * decision for this costing pass, so cost_index() does not apply its usual allvisfrac
		 * adjustment here. We apply the same visibility-fraction adjustment in this
		 * callback to approximate index-only scan costing for this pass.
		 */
		*indexSelectivity = *indexSelectivity * (1.0 - path->indexinfo->rel->allvisfrac);
	}

	if (EnableExtendedExplainPlans && EnableExplainScanIndexCosts)
	{
		RangeTblEntry *rte = planner_rt_fetch(path->indexinfo->rel->relid, root);
		RecordCostEstimateForIndex(path->indexinfo->indexoid, rte->relid,
								   *indexStartupCost,
								   *indexTotalCost, *indexSelectivity,
								   *indexCorrelation, *indexPages,
								   path->indexinfo->pages, path->indexinfo->tuples,
								   *indexSelectivity, 0, 0);
	}
}


inline static IndexClause *
BuildPointReadIndexClause(RestrictInfo *restrictInfo, int indexCol)
{
	IndexClause *iclause = makeNode(IndexClause);
	iclause->rinfo = restrictInfo;
	iclause->indexquals = list_make1(restrictInfo);
	iclause->lossy = false;
	iclause->indexcol = indexCol;
	iclause->indexcols = NIL;
	return iclause;
}


static List *
GetSortDetails(PlannerInfo *root, Index rti, bool *hasGroupby,
			   bool *isOrderById, bool *hasDistinctScan)
{
	List *sortDetails = NIL;
	ListCell *sortCell;
	bool hasOrderBy = false;
	bool hasDistinct = false;
	foreach(sortCell, root->query_pathkeys)
	{
		PathKey *pathkey = (PathKey *) lfirst(sortCell);
		if (pathkey->pk_eclass == NULL ||
			list_length(pathkey->pk_eclass->ec_members) != 1)
		{
			return NIL;
		}

		EquivalenceMember *member = linitial(pathkey->pk_eclass->ec_members);

		if (!IsA(member->em_expr, FuncExpr))
		{
			return NIL;
		}

		FuncExpr *func = (FuncExpr *) member->em_expr;
		Const *collationConst = NULL;
		bool isGroupByEntry = false;
		if (func->funcid == BsonOrderByFunctionOid())
		{
			if (hasDistinct)
			{
				return NIL;
			}

			hasOrderBy = true;
		}
		else if (EnableOrderByIndexTerm &&
				 (func->funcid == BsonOrderByIndexFunctionOid() ||
				  func->funcid == BsonOrderByIndexReverseFunctionOid()))
		{
			if (hasDistinct)
			{
				return NIL;
			}

			hasOrderBy = true;
		}
		else if (EnableOrderByIndexTerm &&
				 (func->funcid == BsonOrderByIndexWithCollationFunctionOid() ||
				  func->funcid == BsonOrderByIndexWithCollationReverseFunctionOid()))
		{
			if (list_length(func->args) < 3)
			{
				return NIL;
			}

			Expr *thirdArg = lthird(func->args);
			if (IsA(thirdArg, RelabelType))
			{
				thirdArg = ((RelabelType *) thirdArg)->arg;
			}

			if (!IsA(thirdArg, Const))
			{
				return NIL;
			}

			Const *thirdConst = (Const *) thirdArg;
			if (thirdConst->constisnull || thirdConst->consttype != TEXTOID)
			{
				return NIL;
			}

			collationConst = thirdConst;
			if (hasDistinct)
			{
				return NIL;
			}

			hasOrderBy = true;
		}
		else if (func->funcid == BsonExpressionGetFunctionOid() ||
				 func->funcid == BsonExpressionGetWithLetFunctionOid())
		{
			/* Reject GROUP BY pathkey appearing after ORDER BY pathkeys;
			 * GROUP BY entries must form a leading prefix of the pathkey list. */
			if (hasOrderBy)
			{
				return NIL;
			}

			*hasGroupby = true;
			isGroupByEntry = true;
		}
		else if (func->funcid == DocumentDBCoreBsonToBsonFunctionOId())
		{
			Expr *firstArg = linitial(func->args);
			if (!IsA(firstArg, FuncExpr))
			{
				return NIL;
			}

			FuncExpr *firstArgFunc = (FuncExpr *) firstArg;
			if (firstArgFunc->funcid == BsonExpressionGetWithLetFunctionOid())
			{
				func = firstArgFunc;
			}
			else
			{
				return NIL;
			}

			/* This is a special function that we allow for group by pushdown - it is used for the case
			 * where we have a group by with an expression that can be rewritten to a path and we want
			 * to be able to push down the path extraction to the index. We only allow this for group by
			 * because for order by we want to be more strict and only allow direct paths.
			 * Reject GROUP BY pathkey appearing after ORDER BY pathkeys;
			 * GROUP BY entries must form a leading prefix of the pathkey list.
			 */
			if (hasOrderBy)
			{
				return NIL;
			}

			*hasGroupby = true;
			isGroupByEntry = true;
		}
		else if (func->funcid == BsonDistinctUnwindFunctionOid() &&
				 EnableDistinctIndexPushdown)
		{
			/* Similar to $group case, reject if ORDER BY has already been seen */
			if (hasOrderBy)
			{
				return NIL;
			}

			hasDistinct = true;
			*hasDistinctScan = true;
			*hasGroupby = true;
		}
		else
		{
			return NIL;
		}

		/* This is an order by function */
		Expr *firstArg = linitial(func->args);
		Expr *secondArg = lsecond(func->args);

		if (IsA(firstArg, RelabelType))
		{
			firstArg = ((RelabelType *) firstArg)->arg;
		}

		if (IsA(secondArg, RelabelType))
		{
			secondArg = ((RelabelType *) secondArg)->arg;
		}

		if (!IsA(firstArg, Var) || !IsA(secondArg, Const))
		{
			return NIL;
		}

		Var *firstVar = (Var *) firstArg;
		Const *secondConst = (Const *) secondArg;

		if (firstVar->varno != (int) rti ||
			firstVar->varattno != DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER ||
			(firstVar->vartype != BsonTypeId() && firstVar->vartype !=
			 DocumentDBCoreBsonTypeId()))
		{
			return NIL;
		}

		pgbsonelement sortElement;

		if (EnableDistinctIndexPushdown && hasDistinct)
		{
			if (secondConst->consttype != TEXTOID || secondConst->constisnull)
			{
				return NIL;
			}

			sortElement.path = TextDatumGetCString(secondConst->constvalue);
			sortElement.pathLength = strlen(sortElement.path);
			sortElement.bsonValue.value_type = BSON_TYPE_INT32;
			sortElement.bsonValue.value.v_int32 = 1;

			secondConst = MakeBsonConst(PgbsonElementToPgbson(&sortElement));
		}
		else if ((secondConst->consttype != BsonTypeId() && secondConst->consttype !=
				  DocumentDBCoreBsonTypeId()) ||
				 secondConst->constisnull)
		{
			return NIL;
		}
		else
		{
			PgbsonToSinglePgbsonElement(
				DatumGetPgBson(secondConst->constvalue), &sortElement);
		}

		if (isGroupByEntry)
		{
			/* In the case of group by the expression would be { "": expr }
			 * Here we can push down to the index iff the expression is a path.
			 */
			const char *groupFieldPath = NULL;
			uint32_t groupFieldPathLen = 0;

			if (sortElement.bsonValue.value_type == BSON_TYPE_UTF8)
			{
				if (sortElement.bsonValue.value.v_utf8.len > 1 &&
					sortElement.bsonValue.value.v_utf8.str[0] == '$' &&
					sortElement.bsonValue.value.v_utf8.str[1] != '$')
				{
					groupFieldPath = sortElement.bsonValue.value.v_utf8.str + 1;
					groupFieldPathLen = sortElement.bsonValue.value.v_utf8.len - 1;
				}
			}
			else if (sortElement.bsonValue.value_type == BSON_TYPE_DOCUMENT)
			{
				pgbsonelement docElement;
				if (TryGetSingleFieldPathFromBsonValue(&sortElement.bsonValue,
													   &docElement))
				{
					groupFieldPath = docElement.bsonValue.value.v_utf8.str + 1;
					groupFieldPathLen = docElement.bsonValue.value.v_utf8.len - 1;
				}
			}

			if (groupFieldPath == NULL)
			{
				return NIL;
			}

			/* This is a valid path: Track the path in the sortElement to decide pushdown */
			sortElement.path = groupFieldPath;
			sortElement.pathLength = groupFieldPathLen;
			sortElement.bsonValue.value_type = BSON_TYPE_INT32;
			sortElement.bsonValue.value.v_int32 = SortPathKeyStrategy(pathkey) ==
												  BTGreaterStrategyNumber ? -1 : 1;
			pgbson *sortSpec = PgbsonElementToPgbson(&sortElement);

			/* Also rewrite the secondConst so that the Expr on the sort operator is correct */
			secondConst = makeConst(BsonTypeId(), -1, InvalidOid, -1, PointerGetDatum(
										sortSpec), false, false);
		}

		SortIndexInputDetails *sortDetailsInput =
			palloc0(sizeof(SortIndexInputDetails));
		sortDetailsInput->sortPath = sortElement.path;
		sortDetailsInput->sortPathKey = pathkey;
		sortDetailsInput->sortVar = (Expr *) firstVar;
		sortDetailsInput->sortDatum = (Expr *) secondConst;
		sortDetailsInput->funcOid = func->funcid;
		sortDetailsInput->collationConst = collationConst;
		sortDetails = lappend(sortDetails, sortDetailsInput);

		*isOrderById = *isOrderById ||
					   (sortElement.pathLength == 3 && strcmp(sortElement.path, "_id") ==
						0);
	}

	return sortDetails;
}


static bool
IsQueryCollationCompatibleWithIndex(const char *queryCollation, bytea *indexOptions)
{
	const char *indexCollation = NULL;
	uint32_t indexCollationLength = 0;
	if (indexOptions != NULL)
	{
		Get_Index_Collation_Option((BsonGinIndexOptionsBase *) indexOptions, collation,
								   indexCollation, indexCollationLength);
	}

	bool queryHasCollation = IsCollationValid(queryCollation);
	bool indexHasCollation = IsCollationValid(indexCollation);
	if (!EnableCollationWithNonUniqueOrderedIndexes)
	{
		return !queryHasCollation && !indexHasCollation;
	}

	if (queryHasCollation != indexHasCollation)
	{
		return false;
	}

	if (!queryHasCollation)
	{
		return true;
	}

	return strcmp(queryCollation, indexCollation) == 0;
}


/*
 * Returns true when either the query (queryCollation) or the candidate index
 * (indexOptions) carries a collation. Callers use it to skip $expr/$lookup index
 * pushdown, which is not yet collation-aware.
 */
bool
IsCollationPresentOnQueryOrIndex(const char *queryCollation, bytea *indexOptions)
{
	if (IsCollationApplicable(queryCollation))
	{
		return true;
	}

	if (indexOptions != NULL)
	{
		const char *indexCollation = NULL;
		uint32_t indexCollationLength = 0;
		Get_Index_Collation_Option((BsonGinIndexOptionsBase *) indexOptions, collation,
								   indexCollation, indexCollationLength);
		if (IsCollationValid(indexCollation))
		{
			return true;
		}
	}

	return false;
}


static bool
IsValidIndexPathForIdOrderBy(IndexPath *indexPath, List *sortDetails)
{
	if (indexPath->indexinfo->relam != BTREE_AM_OID ||
		!IsBtreePrimaryKeyIndex(indexPath->indexinfo))
	{
		return false;
	}

	if (list_length(sortDetails) != 1)
	{
		return false;
	}

	/* We have a single sort and a primary key - consider if
	 * it is an _id pushdown.
	 */
	SortIndexInputDetails *sortDetailsInput = linitial(sortDetails);
	if (strcmp(sortDetailsInput->sortPath, "_id") != 0)
	{
		return false;
	}

	/* The primary key index has no collation, so we cannot honor a collation-
	 * aware sort by streaming results from this index when _id values would
	 * be compared as strings under that collation. */
	if (sortDetailsInput->collationConst != NULL)
	{
		return false;
	}

	/*
	 * We can push down the _id sort to the primary key index
	 * if and only if there's a shard_key equality.
	 */
	if (list_length(indexPath->indexclauses) < 1)
	{
		return false;
	}

	IndexClause *indexClause = linitial(indexPath->indexclauses);
	if (!IsA(indexClause->rinfo->clause, OpExpr))
	{
		return false;
	}

	OpExpr *opExpr = (OpExpr *) indexClause->rinfo->clause;
	Expr *firstArg = linitial(opExpr->args);
	Expr *secondArg = lsecond(opExpr->args);

	if (opExpr->opno != BigintEqualOperatorId() ||
		!IsA(firstArg, Var) || !IsA(secondArg, Const))
	{
		return false;
	}

	Var *firstVar = (Var *) firstArg;
	return firstVar->varattno == DOCUMENT_DATA_TABLE_SHARD_KEY_VALUE_VAR_ATTR_NUMBER;
}


void
ConsiderIndexOrderByPushdownForId(PlannerInfo *root, RelOptInfo *rel, RangeTblEntry *rte,
								  Index rti, ReplaceExtensionFunctionContext *context)
{
	/* In this path, we only consider order by pushdown for the PK index - so we only support
	 * having a single order by path key
	 */
	if (EnableOrderByIdOnCostFunction || list_length(root->query_pathkeys) != 1)
	{
		return;
	}

	if (rte->rtekind != RTE_RELATION)
	{
		return;
	}

	bool isOrderById = false;
	bool hasGroupby = false;
	bool hasDistinct = false;
	List *sortDetails = GetSortDetails(root, rti, &hasGroupby, &isOrderById,
									   &hasDistinct);

	if (sortDetails == NIL || !isOrderById)
	{
		list_free_deep(sortDetails);
		return;
	}

	List *pathsToAdd = NIL;
	ListCell *cell;
	bool hasIndexPaths = false;
	foreach(cell, rel->pathlist)
	{
		Path *path = lfirst(cell);

		if (IsA(path, BitmapHeapPath))
		{
			BitmapHeapPath *bitmapPath = (BitmapHeapPath *) path;

			if (IsA(bitmapPath->bitmapqual, IndexPath))
			{
				path = (Path *) bitmapPath->bitmapqual;
			}
		}

		if (IsA(path, CustomPath) &&
			context->hasDynamicStreamingContinuationScan)
		{
			/* In case of a custom path with streaming continuation,
			 * don't try to overwrite with order by paths.
			 */
			return;
		}

		if (!IsA(path, IndexPath))
		{
			continue;
		}

		IndexPath *indexPath = (IndexPath *) path;
		hasIndexPaths = true;
		if (!IsValidIndexPathForIdOrderBy(indexPath, sortDetails))
		{
			continue;
		}

		/* The first clause is a shard key equality - can push order by */
		IndexPath *newPath = makeNode(IndexPath);
		memcpy(newPath, indexPath, sizeof(IndexPath));
		SortIndexInputDetails *sortDetailsInput = linitial(sortDetails);
		newPath->path.pathkeys = list_make1(sortDetailsInput->sortPathKey);

		/* If the sort is descending, we need to scan the index backwards */
		if (SortPathKeyStrategy(sortDetailsInput->sortPathKey) == BTGreaterStrategyNumber)
		{
			newPath->indexscandir = BackwardScanDirection;
		}

		/* Don't modify the list we're enumerating */
		pathsToAdd = lappend(pathsToAdd, newPath);
	}

	/* Special case: if there were no index paths and
	 * this is a single sort on the _id path, then we can
	 * add a new index path for the _id sort iff it's filtered on shard key.
	 * While we have a FullScan Expr for regular indexes, we don't for _id
	 * so instead we do that logic here.
	 */
	if (isOrderById && list_length(sortDetails) == 1 &&
		!hasIndexPaths && context->plannerOrderByData.shardKeyEqualityExpr != NULL)
	{
		SortIndexInputDetails *sortDetailsInput = linitial(sortDetails);

		/* The primary key index has no collation; skip the synthetic _id index
		 * path when the orderby is collation-aware so we don't return rows in
		 * the wrong order. */
		if (sortDetailsInput->collationConst != NULL)
		{
			list_free_deep(sortDetails);
			return;
		}

		IndexOptInfo *primaryKeyIndex = GetPrimaryKeyIndexOptInfo(rel);

		if (primaryKeyIndex != NULL)
		{
			ScanDirection scanDir =
				SortPathKeyStrategy(sortDetailsInput->sortPathKey) ==
				BTGreaterStrategyNumber ?
				BackwardScanDirection : ForwardScanDirection;

			IndexClause *shard_key_clause =
				BuildPointReadIndexClause(
					context->plannerOrderByData.shardKeyEqualityExpr, 0);
			List *indexClauses = list_make1(shard_key_clause);
			IndexPath *primaryKeyPath = create_index_path(
				root, primaryKeyIndex, indexClauses, NIL, NIL, NIL, scanDir, false, NULL,
				1, false);
			primaryKeyPath->path.pathkeys = list_make1(sortDetailsInput->sortPathKey);
			pathsToAdd = lappend(pathsToAdd, primaryKeyPath);
		}
	}

	list_free_deep(sortDetails);

	foreach(cell, pathsToAdd)
	{
		/* now add the new paths */
		Path *newPath = lfirst(cell);
		add_path(rel, newPath);
	}
}


static void
ProcessOrderByStatements(PlannerInfo *root,
						 IndexPath *path, int32_t minOrderByColumn,
						 int32_t maxOrderByColumn, bool isMultiKeyIndex,
						 uint32_t multiKeyBitMask,
						 const char *queryOrderPaths[INDEX_MAX_KEYS],
						 bool equalityPrefixes[INDEX_MAX_KEYS],
						 bool nonEqualityPrefixes[INDEX_MAX_KEYS],
						 int32_t pathSortOrders[INDEX_MAX_KEYS])
{
	int i = 0, sortDetailsIndex = 0;

	bool hasGroupby = false;
	bool isOrderById = false;
	bool hasDistinct = false;
	List *sortDetails = GetSortDetails(root, path->path.parent->relid, &hasGroupby,
									   &isOrderById, &hasDistinct);

	if (list_length(sortDetails) == 0)
	{
		return;
	}

	if (isMultiKeyIndex && hasDistinct)
	{
		/* if it's multi-key and there's a distinct, we can't push down an order by.
		 * However, we can push an $exists: true filter down to the index so that we
		 * can reduce the overall data set to the index.
		 */
		if (EnableDistinctMultiKeyFilterPushdown && list_length(sortDetails) >= 1)
		{
			SortIndexInputDetails *sortDetailsInput = linitial(sortDetails);
			if (sortDetailsInput->funcOid == BsonDistinctUnwindFunctionOid())
			{
				int sortColumn = -1;
				for (int col = minOrderByColumn; col <= maxOrderByColumn; col++)
				{
					if (queryOrderPaths[col] != NULL &&
						strcmp(sortDetailsInput->sortPath, queryOrderPaths[col]) == 0)
					{
						sortColumn = col;
						break;
					}
				}

				/*
				 * Only push the $exists: true filter when the distinct path
				 * maps to a column of this index (sortColumn >= 0) that does
				 * not already carry an equality or non-equality bound. If the
				 * column already has a bound, the exists clause is redundant;
				 * if the distinct path is not part of the index at all, there
				 * is no column to constrain.
				 *
				 * NOTE: sortColumn and the prefix arrays are both keyed off the
				 * distinct path (the first sort detail). Today a distinct always
				 * drives the leading order-by, so this is safe. If a future
				 * shape allows the distinct key (e.g. "a") to differ from the
				 * column that carries the order-by/filter (e.g. an order and
				 * filter on "b" over an index on "b"), this single-column check
				 * would look at the wrong column's prefixes and must be revised
				 * to resolve the exists target independently of the order-by.
				 */
				if (sortColumn >= 0 && !(equalityPrefixes[sortColumn] ||
										 nonEqualityPrefixes[sortColumn]))
				{
					/* push down an $exists: true filter to the index for this path */
					Expr *existsTrueOpExpr = (Expr *) CreateExistsTrueOpExpr(
						(Expr *) sortDetailsInput->sortVar,
						sortDetailsInput->sortPath, strlen(sortDetailsInput->sortPath));
					RestrictInfo *existsTrueRestrictInfo = make_simple_restrictinfo(
						root, (Expr *) existsTrueOpExpr);
					IndexClause *indexClause = BuildPointReadIndexClause(
						existsTrueRestrictInfo, 0);
					path->indexclauses = lappend(path->indexclauses, indexClause);
				}
			}
		}

		list_free(sortDetails);
		return;
	}

	if (isMultiKeyIndex && hasGroupby)
	{
		/* We can't push down orderby on a multikey index if there is a group by */
		list_free_deep(sortDetails);
		return;
	}

	List *indexOrderBys = NIL;
	List *indexPathKeys = NIL;
	List *indexOrderbyCols = NIL;
	int32_t determinedSortOrder = 0;
	for (; i < minOrderByColumn; i++)
	{
		if (!equalityPrefixes[i])
		{
			/* No orderby on the column */
			list_free_deep(sortDetails);
			return;
		}
	}

	for (i = minOrderByColumn; i <= maxOrderByColumn; i++)
	{
		if (isMultiKeyIndex)
		{
			/*
			 * Respect the per-path multi-key bitmask when the feature flag is on:
			 * only treat this order-by column as multi-key if its own path bit is
			 * set (or the bitmask is unavailable). When the flag is off, fall back
			 * to treating every order-by column of a multi-key index as multi-key.
			 */
			bool isMultiKeyPath = !EnablePerPathMultiKeySortPushdown ||
								  multiKeyBitMask == 0 ||
								  ((multiKeyBitMask & (UINT32_C(1) << i)) != 0);

			/* For a multi-key index, all order by related paths must have no filter specifications */
			if (isMultiKeyPath && (nonEqualityPrefixes[i] || equalityPrefixes[i]))
			{
				break;
			}
		}

		/* From this point, onwards, each path must either have an order or a valid filter
		 * for the path.
		 */
		if (pathSortOrders[i] != 0)
		{
			/* This path has an order by */
			if (determinedSortOrder == 0)
			{
				determinedSortOrder = pathSortOrders[i];
			}
			else if (pathSortOrders[i] != determinedSortOrder)
			{
				/* Can no longer push any further orderby to this index */
				break;
			}

			SortIndexInputDetails *sortDetailsInput =
				(SortIndexInputDetails *) list_nth(sortDetails, sortDetailsIndex);

			if (strcmp(sortDetailsInput->sortPath, queryOrderPaths[i]) != 0)
			{
				/* The order by path does not match the index path */
				break;
			}

			sortDetailsIndex++;

			/* Path sort order matches the currently determined index sort order */
			/* Now we've reached the first orderby */
			OpExpr *orderElement;
			if (sortDetailsInput->funcOid == BsonOrderByIndexFunctionOid() ||
				sortDetailsInput->funcOid == BsonOrderByIndexReverseFunctionOid() ||
				sortDetailsInput->funcOid == BsonOrderByIndexWithCollationFunctionOid() ||
				sortDetailsInput->funcOid ==
				BsonOrderByIndexWithCollationReverseFunctionOid())
			{
				Oid indexOperator = BsonOrderByBsonIndexTypeOperatorId();

				/* sortDatum in the index order case we push is the index sort datum */
				pgbsonelement sortElement;
				sortElement.path = sortDetailsInput->sortPath;
				sortElement.pathLength = strlen(sortDetailsInput->sortPath);
				sortElement.bsonValue.value_type = BSON_TYPE_INT32;
				sortElement.bsonValue.value.v_int32 =
					SortPathKeyStrategy(sortDetailsInput->sortPathKey) ==
					BTGreaterStrategyNumber ?
					-1 : 1;
				pgbson *sortDatum = PgbsonElementToPgbson(&sortElement);
				Const *sortConst = makeConst(BsonTypeId(), -1, InvalidOid, -1,
											 PointerGetDatum(sortDatum),
											 false, false);

				orderElement = (OpExpr *) make_opclause(
					indexOperator, BsonIndexTermTypeId(), false,
					(Expr *) sortDetailsInput->sortVar,
					(Expr *) sortConst,
					InvalidOid, InvalidOid);
				orderElement->opfuncid = get_opcode(indexOperator);
			}
			else
			{
				Oid indexOperator = pathSortOrders[i] < 0 ?
									BsonOrderByReverseIndexOperatorId() :
									BsonOrderByIndexOperatorId();
				orderElement = (OpExpr *) make_opclause(
					indexOperator, BsonTypeId(), false,
					(Expr *) sortDetailsInput->sortVar,
					(Expr *) sortDetailsInput->sortDatum,
					InvalidOid, InvalidOid);
				orderElement->opfuncid = get_opcode(indexOperator);
			}

			indexOrderBys = lappend(indexOrderBys, orderElement);
			indexPathKeys = lappend(indexPathKeys, sortDetailsInput->sortPathKey);
			indexOrderbyCols = lappend_int(indexOrderbyCols, 0);
		}
		else if (!equalityPrefixes[i])
		{
			/* No order by on this column but we're less than the maxOrderBy.
			 * If we don't have an equality prefix, this is no longer valid
			 * for orderby
			 */
			break;
		}
	}

	path->indexorderbys = indexOrderBys;
	path->indexorderbycols = indexOrderbyCols;
	path->path.pathkeys = indexPathKeys;

	list_free_deep(sortDetails);
}


static bool
PopulateQueryPathAndValueFromOpExpr(OpExpr *opExpr, const char **queryPathString,
									bson_value_t *queryValue)
{
	Expr *queryVal = lsecond(opExpr->args);
	queryValue->value_type = BSON_TYPE_EOD;
	if (IsA(queryVal, Const))
	{
		Const *queryConst = (Const *) queryVal;
		pgbson *queryBson = DatumGetPgBson(queryConst->constvalue);

		pgbsonelement queryElement;
		PgbsonToSinglePgbsonElement(queryBson, &queryElement);
		*queryPathString = queryElement.path;
		*queryValue = queryElement.bsonValue;
		return true;
	}
	else if (IsA(queryVal, FuncExpr))
	{
		FuncExpr *funcExpr = (FuncExpr *) queryVal;
		if (funcExpr->funcid ==
			DocumentDBApiInternalBsonLookupExtractFilterExpressionFunctionOid() &&
			list_length(funcExpr->args) >= 2)
		{
			Expr *secondArg = lsecond(funcExpr->args);
			if (IsA(secondArg, Const) && !castNode(Const, secondArg)->constisnull)
			{
				Const *secondConst = (Const *) secondArg;

				pgbsonelement queryElement;
				PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(
															 secondConst->
															 constvalue),
														 &queryElement);
				*queryPathString = queryElement.path;
				return true;
			}
		}
		else if (funcExpr->funcid == BsonDollarMergeExtractFilterFunctionOid() &&
				 list_length(funcExpr->args) >= 2)
		{
			Expr *secondArg = lsecond(funcExpr->args);
			if (IsA(secondArg, Const) && !castNode(Const, secondArg)->constisnull)
			{
				Const *secondConst = (Const *) secondArg;
				*queryPathString = TextDatumGetCString(secondConst->constvalue);
				return true;
			}
		}
		else if (funcExpr->funcid == BsonExpressionGetWithLetFunctionOid() &&
				 list_length(funcExpr->args) >= 4)
		{
			Expr *secondArg = lsecond(funcExpr->args);
			if (IsA(secondArg, Const) && !castNode(Const, secondArg)->constisnull)
			{
				Const *thirdConst = (Const *) secondArg;

				pgbsonelement queryElement;
				PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(
															 thirdConst->
															 constvalue),
														 &queryElement);
				*queryPathString = queryElement.path;
				return true;
			}
		}
	}

	*queryPathString = NULL;
	return false;
}


static void
IndexStrategyClassify(int32_t indexStrategy, bool *equalityPrefixes,
					  bool *nonEqualityPrefixes,
					  Oid opNo, bool isPartialFilterExpr, const
					  bson_value_t *optionalQueryValue,
					  int8_t *orderScanDirection, int32_t *outputIndexStrategy)
{
	*outputIndexStrategy = indexStrategy;
	switch (indexStrategy)
	{
		case BSON_INDEX_STRATEGY_DOLLAR_EQUAL:
		{
			*equalityPrefixes = true;
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL:
		{
			/* this is not a full scan (only exists: true is allowed) */
			if (optionalQueryValue->value_type != BSON_TYPE_MINKEY)
			{
				*nonEqualityPrefixes = true;
			}

			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL:
		{
			/* this is not a full scan (only <= MaxKey is allowed) */
			if (optionalQueryValue->value_type != BSON_TYPE_MAXKEY)
			{
				*nonEqualityPrefixes = true;
			}

			break;
		}

		case BSON_INDEX_STRATEGY_INVALID:
		{
			if (opNo == BsonRangeMatchOperatorOid() &&
				optionalQueryValue->value_type != BSON_TYPE_EOD)
			{
				*outputIndexStrategy = BSON_INDEX_STRATEGY_DOLLAR_RANGE;
				DollarRangeParams rangeParams = { 0 };
				InitializeQueryDollarRange(optionalQueryValue, &rangeParams);

				if (rangeParams.isElemMatch)
				{
					ElemMatchIndexOpStrategyClassify(&rangeParams, outputIndexStrategy,
													 equalityPrefixes,
													 nonEqualityPrefixes);
				}
				else if (!rangeParams.isFullScan)
				{
					*nonEqualityPrefixes = true;
				}

				*orderScanDirection = rangeParams.orderScanDirection;
			}
			else if (isPartialFilterExpr && opNo == BsonEqualMatchRuntimeOperatorId())
			{
				*equalityPrefixes = true;
			}
			else
			{
				*nonEqualityPrefixes = true;
			}

			break;
		}

		default:
		{
			/* Track the filters as being a non-equality (range predicate) */
			*nonEqualityPrefixes = true;
			break;
		}
	}
}


void
ElemMatchIndexOpStrategyClassify(DollarRangeParams *params,
								 int32_t *queryStrategy,
								 bool *equalityPrefixes,
								 bool *nonEqualityPrefixes)
{
	bson_iter_t elemMatchIter;
	bool hasStrategies = false;
	BsonValueInitIterator(&params->elemMatchValue, &elemMatchIter);
	while (bson_iter_next(&elemMatchIter))
	{
		bson_iter_t innerIter;
		if (bson_iter_recurse(&elemMatchIter, &innerIter))
		{
			BsonIndexStrategy strat = BSON_INDEX_STRATEGY_INVALID;
			bson_value_t queryValue = { 0 };
			while (bson_iter_next(&innerIter))
			{
				const char *key = bson_iter_key(&innerIter);
				const bson_value_t *value = bson_iter_value(&innerIter);
				if (strcmp(key, "op") == 0)
				{
					strat = (BsonIndexStrategy) BsonValueAsInt32(value);
				}
				else if (strcmp(key, "value") == 0)
				{
					queryValue = *value;
				}
			}

			bool isPartialFilterExpr = false;
			int8_t indexSortDirection = 0;
			hasStrategies = true;
			IndexStrategyClassify(strat, equalityPrefixes, nonEqualityPrefixes,
								  InvalidOid, isPartialFilterExpr, &queryValue,
								  &indexSortDirection, queryStrategy);
		}
	}

	if (!hasStrategies)
	{
		*nonEqualityPrefixes = true;
	}
}


static int32_t
UpdateEqualityPrefixesAndGetSortOrder(const char *queryPath, bytea *opClassOptions,
									  OpExpr *expr, bool isPartialFilterExpr,
									  const bson_value_t *optionalQueryValue,
									  bool equalityPrefixes[INDEX_MAX_KEYS],
									  bool nonEqualityPrefixes[INDEX_MAX_KEYS],
									  int32_t *outputColumnNumber,
									  int8_t *indexSortDirection,
									  int32_t *indexStrategy)
{
	int columnNumber = GetCompositeOpClassColumnNumber(queryPath,
													   opClassOptions,
													   indexSortDirection);

	*outputColumnNumber = columnNumber;

	/* Collect orderby clauses here */
	if (columnNumber < 0)
	{
		return 0;
	}

	int8_t orderScanDirection = 0;
	const MongoIndexOperatorInfo *info =
		GetMongoIndexOperatorByPostgresOperatorId(expr->opno);
	IndexStrategyClassify(info->indexStrategy, &equalityPrefixes[columnNumber],
						  &nonEqualityPrefixes[columnNumber],
						  expr->opno, isPartialFilterExpr, optionalQueryValue,
						  &orderScanDirection, indexStrategy);

	return orderScanDirection;
}


static int
ProcessSingleCompositeFilter(Node *predQual, bytea *opClassOptions,
							 bool equalityPrefixes[INDEX_MAX_KEYS],
							 bool nonEqualityPrefixes[INDEX_MAX_KEYS],
							 int32_t *indexStrategy)
{
	/* walk the index predicates and check if they match the index */
	if (!IsA(predQual, OpExpr))
	{
		return -1;
	}

	OpExpr *expr = (OpExpr *) predQual;

	const char *queryPath = NULL;
	bson_value_t optionalQueryValue = { 0 };
	if (!PopulateQueryPathAndValueFromOpExpr(expr, &queryPath, &optionalQueryValue))
	{
		return -1;
	}

	if (queryPath == NULL)
	{
		return -1;
	}

	int columnNumber = -1;
	int8_t indexSortDirection = -1;
	bool isPartialFilterExpr = true;
	UpdateEqualityPrefixesAndGetSortOrder(
		queryPath, opClassOptions, expr, isPartialFilterExpr,
		&optionalQueryValue, equalityPrefixes, nonEqualityPrefixes, &columnNumber,
		&indexSortDirection, indexStrategy);

	return columnNumber;
}


/*
 * Some of the quals for order by can come from the PFE:
 * Consider a case where you have an index (a, b, c) with a pfe b = 1
 * where you have a = 1, b = 1, order by c. b = 1 gets stripped since it
 * matches the PFE exactly, so this code only sees a = 1, fullscan(c).
 * This should be considered valid for order by since the PFE covers the
 * missing column. This is tracked by walking the PFE here.
 *
 * Similarly, consider the index (a) with pfe a = 1.
 * While this may seem like a corner case, this is still valid, and in this
 * case we can push down to the index as the first column is found from the PFE.
 * Or an index with (a) with PFE a > 1 where teh query predicate is a > 1. Similarly
 * we need to walk the PFEs to ensure we capture whether the first path is specified.
 */
static bool
ProcessCompositePartialFilter(List *indexPredicate, bytea *opClassOptions,
							  bool equalityPrefixes[INDEX_MAX_KEYS],
							  bool nonEqualityPrefixes[INDEX_MAX_KEYS])
{
	ListCell *cell;
	bool hasFirstPathSpecified = false;
	foreach(cell, indexPredicate)
	{
		Node *predQual = (Node *) lfirst(cell);

		/* walk the index predicates and check if they match the index */
		int indexStrategyIgnore = 0;
		int columnNumber = ProcessSingleCompositeFilter(predQual, opClassOptions,
														equalityPrefixes,
														nonEqualityPrefixes,
														&indexStrategyIgnore);
		if (columnNumber < 0)
		{
			continue;
		}

		if (columnNumber == 0)
		{
			hasFirstPathSpecified = true;
		}
	}

	return hasFirstPathSpecified;
}


bool
TraverseIndexPathForCompositeIndex(struct IndexPath *indexPath, struct PlannerInfo *root,
								   bool *canSupportIndexOnlyScan)
{
	ListCell *cell;
	bool firstFilterColumnFound = false;
	bool indexCanOrder = false;
	uint32_t multiKeyBitMask = 0;
	bool isMultiKeyIndex = CompositeIndexOptInfoIsMultiKey(indexPath->indexinfo,
														   &multiKeyBitMask);
	bool indexSupportsOrderByDesc = GetIndexSupportsBackwardsScan(
		indexPath->indexinfo->relam, &indexCanOrder);

	bool indexOnlyScanPossible = EnableIndexOnlyScan &&
								 enable_indexonlyscan &&
								 EnableIndexOnlyScanOnCostFunction &&
								 indexPath->path.pathtype != T_IndexOnlyScan &&
								 IsQueryEligibleForIndexOnlyScan(root,
																 indexPath->path.parent->
																 relid, NULL) &&
								 AreAllTargetsCoveredByIndex(root, indexPath) &&
								 CompositeIndexSupportsIndexOnlyScan(indexPath);

	bytea *indexOptions = indexPath->indexinfo->opclassoptions != NULL ?
						  indexPath->indexinfo->opclassoptions[0] : NULL;
	int32_t pathSortOrders[INDEX_MAX_KEYS] = { 0 };
	bool equalityPrefixes[INDEX_MAX_KEYS] = { false };
	bool nonEqualityPrefixes[INDEX_MAX_KEYS] = { false };
	const char *queryOrderPaths[INDEX_MAX_KEYS] = { 0 };
	int32_t minOrderByColumn = INT_MAX;
	int32_t maxOrderByColumn = -1;
	List *orderbyIndexClauses = NIL;
	foreach(cell, indexPath->indexclauses)
	{
		IndexClause *clause = (IndexClause *) lfirst(cell);

		if (indexOnlyScanPossible && !IndexClauseIsValidForIndexOnlyScan(clause,
																		 indexOptions))
		{
			indexOnlyScanPossible = false;
		}

		ListCell *iclauseCell;
		foreach(iclauseCell, clause->indexquals)
		{
			RestrictInfo *qual = (RestrictInfo *) lfirst(iclauseCell);
			if (!IsA(qual->clause, OpExpr))
			{
				continue;
			}

			OpExpr *expr = (OpExpr *) qual->clause;

			const char *queryPath = NULL;
			bson_value_t optionalQueryValue = { 0 };
			if (!PopulateQueryPathAndValueFromOpExpr(expr, &queryPath,
													 &optionalQueryValue))
			{
				continue;
			}

			if (queryPath == NULL)
			{
				continue;
			}

			int columnNumber = -1;
			int8_t indexSortDirection = 0;
			bool isPartialFilterExpr = false;
			int32_t indexStrategy = BSON_INDEX_STRATEGY_INVALID;
			int8_t orderScanDirection = UpdateEqualityPrefixesAndGetSortOrder(
				queryPath, indexPath->indexinfo->opclassoptions[0],
				expr, isPartialFilterExpr, &optionalQueryValue, equalityPrefixes,
				nonEqualityPrefixes, &columnNumber, &indexSortDirection, &indexStrategy);
			if (columnNumber < 0)
			{
				continue;
			}

			if (orderScanDirection == 0)
			{
				/* Found a filter path */
				if (columnNumber == 0)
				{
					firstFilterColumnFound = true;
				}

				continue;
			}

			bool currentPathKeyIsReverseSort = orderScanDirection != indexSortDirection;
			if (currentPathKeyIsReverseSort && !indexSupportsOrderByDesc)
			{
				continue;
			}

			pathSortOrders[columnNumber] = currentPathKeyIsReverseSort ? -1 : 1;
			queryOrderPaths[columnNumber] = queryPath;
			minOrderByColumn = Min(minOrderByColumn, columnNumber);
			maxOrderByColumn = Max(maxOrderByColumn, columnNumber);
			orderbyIndexClauses = lappend(orderbyIndexClauses, clause);
		}
	}

	if (indexPath->indexinfo->indpred != NIL)
	{
		if (ProcessCompositePartialFilter(
				indexPath->indexinfo->indpred,
				indexPath->indexinfo->opclassoptions[0],
				equalityPrefixes, nonEqualityPrefixes))
		{
			firstFilterColumnFound = true;
		}
	}

	/* One final pass to add the appropriate order by clauses to the index path */
	if (indexCanOrder && maxOrderByColumn >= 0)
	{
		ProcessOrderByStatements(root, indexPath, minOrderByColumn,
								 maxOrderByColumn, isMultiKeyIndex,
								 multiKeyBitMask,
								 queryOrderPaths, equalityPrefixes,
								 nonEqualityPrefixes, pathSortOrders);

		/* Trim the order by clauses from the index if there's filters */
		if (firstFilterColumnFound && list_length(orderbyIndexClauses) > 0)
		{
			/* If the index supports parallel scan, we need to duplicate this list
			 * so that parallel scans can also see the trimmed clauses.
			 */
			if (indexPath->indexinfo->amcanparallel)
			{
				indexPath->indexclauses = list_copy(indexPath->indexclauses);
			}

			foreach(cell, orderbyIndexClauses)
			{
				IndexClause *clause = lfirst(cell);
				if (list_length(indexPath->indexclauses) <= 1)
				{
					/* Don't delete the last clause */
					break;
				}

				indexPath->indexclauses = list_delete_ptr(indexPath->indexclauses,
														  clause);
			}
		}

		list_free(orderbyIndexClauses);
	}

	/* Check if the restrict info can be satisfied by the index. We don't have a replace context at this point since we're past the planning phase. */
	if (indexOnlyScanPossible)
	{
		const RestrictInfo *shardKeyExpr = NULL;
		int64 shardKeyValue = 0;
		ListCell *rinfoCell;
		foreach(rinfoCell, indexPath->indexinfo->indrestrictinfo)
		{
			RestrictInfo *baseRestrictInfo = (RestrictInfo *) lfirst(rinfoCell);

			if (indexOnlyScanPossible && !IndexRestrictInfoSupportIndexOnlyScan(
					baseRestrictInfo, indexOptions, &shardKeyExpr, &shardKeyValue))
			{
				indexOnlyScanPossible = false;
				break;
			}
		}

		if (indexOnlyScanPossible && shardKeyExpr != NULL)
		{
			/* If we have a shard key restrict info we need to validate the relation is unsharded. Get the relation oid and try to get the collection. */
			Oid relationOid =
				root->simple_rte_array[indexPath->indexinfo->rel->relid]->relid;

			uint64_t collectionId = 0;
			bool requireShardTable = true;
			if (!TryGetCollectionIdByRelationOid(relationOid, &collectionId,
												 requireShardTable))
			{
				indexOnlyScanPossible = false;
			}
			else
			{
				indexOnlyScanPossible = (int64) collectionId == shardKeyValue;
			}
		}
	}

	if (canSupportIndexOnlyScan != NULL)
	{
		*canSupportIndexOnlyScan = indexOnlyScanPossible;
	}

	/* Valid if we pushed some order by or a filter path was found on at least the first column */
	return firstFilterColumnFound || indexPath->indexorderbys != NIL;
}


/*
 * Extracts the boundary qualifiers for an index path. This basically includes
 * all the equality prefixes fully specified for a path and the *first* inequality prefix.
 * These will be the quals that will filter out portions of the index in a composite index.
 * e.g. given an index a, b, c, d
 * for a query that specifies a && d -> the boundary is "a"
 * for a query that has EQ(A), RANGE(B), EQ(C) -> the boundary is "A, RANGE(B)"
 * for a query that has RANGE(A), EQ(B), EQ(C) -> the boundary is "RANGE(A)"
 * for a query that has EQ(A), EQ(B), RANGE(C) -> the boundary is "EQ(A), EQ(B), RANGE(C)"
 * for a query that has EQ(A), EQ(C) -> the boundary is "EQ(A)"
 */
List *
ExtractBoundaryQualsForOrderedIndexPath(IndexPath *indexPath, int *num_sa_scans)
{
	List *validRestrictInfos[INDEX_MAX_KEYS] = { 0 };
	bool equalityPrefixesGlobal[INDEX_MAX_KEYS] = { 0 };
	int32_t numSaopScans[INDEX_MAX_KEYS] = { 0 };
	int maxGlobalColumnNumber = -1;
	*num_sa_scans = 1;

	ListCell *cell;
	foreach(cell, indexPath->indexclauses)
	{
		bool equalityPrefixes[INDEX_MAX_KEYS] = { 0 };
		bool nonEqualityPrefixes[INDEX_MAX_KEYS] = { 0 };

		IndexClause *iclause = (IndexClause *) lfirst(cell);
		ListCell *lc2;
		foreach(lc2, iclause->indexquals)
		{
			RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc2);
			Expr *clause = rinfo->clause;

			if (!IsA(clause, OpExpr))
			{
				continue;
			}

			Expr *clauseArg = lsecond(((OpExpr *) clause)->args);
			if (!IsA(clauseArg, Const))
			{
				/* We only support const args for now */
				continue;
			}

			Const *clauseConst = (Const *) clauseArg;
			if (clauseConst->constisnull)
			{
				/* We don't support null const args for now */
				continue;
			}

			int32_t indexStrategy = 0;
			int columnNumber = ProcessSingleCompositeFilter(
				(Node *) clause, indexPath->indexinfo->opclassoptions[iclause->indexcol],
				equalityPrefixes, nonEqualityPrefixes, &indexStrategy);
			if (columnNumber < 0)
			{
				continue;
			}

			maxGlobalColumnNumber = Max(maxGlobalColumnNumber, columnNumber);

			validRestrictInfos[columnNumber] = lappend(validRestrictInfos[columnNumber],
													   rinfo);
			if (indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_IN)
			{
				equalityPrefixesGlobal[columnNumber] = true;
				numSaopScans[columnNumber]++;
			}
			else if (indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_NOT_IN)
			{
				numSaopScans[columnNumber]++;
			}

			if (equalityPrefixes[columnNumber])
			{
				equalityPrefixesGlobal[columnNumber] = true;
			}
		}
	}

	/* Now walk the paths from left to right, and only allow clauses until the first non-equality/range/missing */
	int i;
	List *finalBoundaryClauses = NIL;
	for (i = 0; i <= maxGlobalColumnNumber; i++)
	{
		/* This path has no valid indexes, subsequent paths cannot be considered */
		if (validRestrictInfos[i] == NIL)
		{
			break;
		}

		/* This path is valid for consideration with boundary clauses */
		finalBoundaryClauses = list_concat(finalBoundaryClauses, validRestrictInfos[i]);

		*num_sa_scans += numSaopScans[i];

		list_free(validRestrictInfos[i]);
		validRestrictInfos[i] = NIL;

		/* If the current path does not have an equality match then subsequent paths cannot be considered */
		if (!equalityPrefixesGlobal[i])
		{
			break;
		}
	}

	for (; i <= maxGlobalColumnNumber; i++)
	{
		/* Free any remaining clauses that are not being considered */
		if (validRestrictInfos[i] != NIL)
		{
			list_free(validRestrictInfos[i]);
		}
	}

	return finalBoundaryClauses;
}


/* --------------------------------------------------------- */
/* Private functions */
/* --------------------------------------------------------- */

/*
 * Inspects an input SupportRequestIndexCondition and associated FuncExpr
 * and validates whether it is satisfied by the index specified in the request.
 * If it is, then returns a new OpExpr for the condition.
 * Else, returns NULL;
 */
static Expr *
HandleSupportRequestCondition(SupportRequestIndexCondition *req)
{
	/* Input validation */
	List *args;
	const MongoIndexOperatorInfo *operator = GetMongoIndexQueryOperatorFromNode(req->node,
																				&args);

	if (list_length(args) != 2)
	{
		return NULL;
	}

	if (operator->indexStrategy == BSON_INDEX_STRATEGY_INVALID)
	{
		if (req->funcid == BsonFullScanFunctionOid())
		{
			/* Process this separate for orderby */
			return ProcessFullScanForOrderBy(req, args);
		}

		return NULL;
	}

	/*
	 *  TODO : Push down to index if operand is not a constant
	 */
	Node *operand = lsecond(args);
	if (!IsA(operand, Const))
	{
		return NULL;
	}

	/* Try to get the index options we serialized for the index.
	 * If one doesn't exist, we can't handle push downs of this clause */
	bytea *options = req->index->opclassoptions[req->indexcol];
	if (options == NULL)
	{
		return NULL;
	}

	Oid operatorFamily = req->index->opfamily[req->indexcol];

	Datum queryValue = ((Const *) operand)->constvalue;

	/* Lookup the func in the set of operators */
	if (operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_TEXT)
	{
		/* For text, we only match the operator family with the op family
		 * For the bson text.
		 */
		if (!IsTextPathOpFamilyOid(req->index->relam, operatorFamily))
		{
			return NULL;
		}

		Expr *finalExpression =
			(Expr *) GetOpExprClauseFromIndexOperator(operator, linitial(args),
													  (Expr *) operand, options);
		return finalExpression;
	}

	if (operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_ELEMMATCH &&
		IsCompositeOpFamilyOid(req->index->relam, operatorFamily))
	{
		Expr *elemMatchExpr = ProcessElemMatchOperator(options, queryValue, operator,
													   args);
		if (elemMatchExpr != NULL)
		{
			req->lossy = true;
			return elemMatchExpr;
		}

		return NULL;
	}

	if (operator->indexStrategy != BSON_INDEX_STRATEGY_INVALID)
	{
		/* Check if the index is valid for the function */
		if (!ValidateIndexForQualifierValue(options, queryValue,
											operator->indexStrategy))
		{
			return NULL;
		}

		Expr *finalExpression =
			(Expr *) GetOpExprClauseFromIndexOperator(operator, linitial(args),
													  (Expr *) operand, options);
		return finalExpression;
	}

	return NULL;
}


/*
 * Extract search parameters from indexPath->indexinfo->indrestrictinfo, which contains a list of restriction clauses represents clause of WHERE or JOIN
 * set to context->queryDataForVectorSearch
 *
 * For vector search, it is of the following form.
 * ApiCatalogSchemaName.bson_search_param(document, '{ "nProbes": 4 }'::ApiCatalogSchemaName.bson)
 */
static void
ExtractAndSetSearchParamterFromWrapFunction(IndexPath *indexPath,
											ReplaceExtensionFunctionContext *context)
{
	List *quals = indexPath->indexinfo->indrestrictinfo;
	if (quals != NULL)
	{
		ListCell *cell;
		foreach(cell, quals)
		{
			RestrictInfo *rinfo = lfirst_node(RestrictInfo, cell);
			Expr *qual = rinfo->clause;
			if (IsA(qual, FuncExpr))
			{
				FuncExpr *expr = (FuncExpr *) qual;
				if (expr->funcid == ApiBsonSearchParamFunctionId())
				{
					Const *bsonConst = (Const *) lsecond(expr->args);
					context->queryDataForVectorSearch.SearchParamBson =
						bsonConst->constvalue;
					break;
				}
			}
		}
	}
}


static List *
OptimizeIndexExpressionsForRange(List *indexClauses)
{
	ListCell *indexPathCell;
	DollarRangeElement rangeElements[INDEX_MAX_KEYS];
	memset(&rangeElements, 0, sizeof(DollarRangeElement) * INDEX_MAX_KEYS);

	foreach(indexPathCell, indexClauses)
	{
		IndexClause *iclause = (IndexClause *) lfirst(indexPathCell);
		RestrictInfo *rinfo = iclause->rinfo;

		if (!IsA(rinfo->clause, OpExpr))
		{
			continue;
		}

		OpExpr *opExpr = (OpExpr *) rinfo->clause;
		const MongoIndexOperatorInfo *operator =
			GetMongoIndexOperatorByPostgresOperatorId(opExpr->opno);
		bool isComparisonInvalidIgnore = false;

		DollarRangeElement *element = &rangeElements[iclause->indexcol];

		if (element->isInvalidCandidateForRange)
		{
			continue;
		}

		switch (operator->indexStrategy)
		{
			case BSON_INDEX_STRATEGY_DOLLAR_GREATER:
			case BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL:
			{
				Const *argsConst = lsecond(opExpr->args);
				pgbson *secondArg = DatumGetPgBson(argsConst->constvalue);
				pgbsonelement argElement;
				PgbsonToSinglePgbsonElement(secondArg, &argElement);

				if (argElement.bsonValue.value_type == BSON_TYPE_NULL &&
					operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL)
				{
					/* $gte: null - skip range optimization (go through normal path)
					 * that skips ComparePartial and uses runtime recheck
					 */
					break;
				}

				if (argElement.bsonValue.value_type == BSON_TYPE_MINKEY &&
					operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL)
				{
					/* This is similar to $exists: true, skip optimization and rely on
					 * more efficient $exists: true check that doesn't need comparePartial.
					 * This is still okay since $lte/$lt starts with At least MinKey() so
					 * it doesn't change the bounds to be any better.
					 */
					break;
				}

				if (element->minElement.pathLength == 0)
				{
					element->minElement = argElement;
					element->isMinInclusive = operator->indexStrategy ==
											  BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL;
					element->minClause = iclause;
				}
				else if (element->minElement.pathLength != argElement.pathLength ||
						 strncmp(element->minElement.path, argElement.path,
								 argElement.pathLength) != 0)
				{
					element->isInvalidCandidateForRange = true;
				}
				else if (CompareBsonValueAndType(
							 &element->minElement.bsonValue, &argElement.bsonValue,
							 &isComparisonInvalidIgnore) < 0)
				{
					element->minElement = argElement;
					element->isMinInclusive = operator->indexStrategy ==
											  BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL;
					element->minClause = iclause;
				}

				break;
			}

			case BSON_INDEX_STRATEGY_DOLLAR_LESS:
			case BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL:
			{
				Const *argsConst = lsecond(opExpr->args);
				pgbson *secondArg = DatumGetPgBson(argsConst->constvalue);
				pgbsonelement argElement;
				PgbsonToSinglePgbsonElement(secondArg, &argElement);

				if (argElement.bsonValue.value_type == BSON_TYPE_NULL &&
					operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL)
				{
					/* $lte: null - skip range optimization (go through normal path)
					 * that skips ComparePartial and uses runtime recheck
					 */
					break;
				}

				if (element->maxElement.pathLength == 0)
				{
					element->maxElement = argElement;
					element->isMaxInclusive = operator->indexStrategy ==
											  BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL;
					element->maxClause = iclause;
				}
				else if (element->maxElement.pathLength != argElement.pathLength ||
						 strncmp(element->maxElement.path, argElement.path,
								 argElement.pathLength) != 0)
				{
					element->isInvalidCandidateForRange = true;
				}
				else if (CompareBsonValueAndType(
							 &element->maxElement.bsonValue, &argElement.bsonValue,
							 &isComparisonInvalidIgnore) > 0)
				{
					element->maxElement = argElement;
					element->isMaxInclusive = operator->indexStrategy ==
											  BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL;
					element->maxClause = iclause;
				}

				break;
			}

			default:
			{
				break;
			}
		}
	}

	for (int i = 0; i < INDEX_MAX_KEYS; i++)
	{
		if (rangeElements[i].isInvalidCandidateForRange)
		{
			continue;
		}

		if (rangeElements[i].minElement.bsonValue.value_type == BSON_TYPE_EOD ||
			rangeElements[i].maxElement.bsonValue.value_type == BSON_TYPE_EOD)
		{
			continue;
		}

		if (rangeElements[i].minElement.pathLength !=
			rangeElements[i].maxElement.pathLength ||
			strncmp(rangeElements[i].minElement.path, rangeElements[i].maxElement.path,
					rangeElements[i].minElement.pathLength) != 0)
		{
			continue;
		}

		OpExpr *expr = (OpExpr *) rangeElements[i].minClause->rinfo->clause;

		pgbson_writer clauseWriter;
		pgbson_writer childWriter;
		PgbsonWriterInit(&clauseWriter);
		PgbsonWriterStartDocument(&clauseWriter, rangeElements[i].minElement.path,
								  rangeElements[i].minElement.pathLength,
								  &childWriter);

		PgbsonWriterAppendValue(&childWriter, "min", 3,
								&rangeElements[i].minElement.bsonValue);
		PgbsonWriterAppendValue(&childWriter, "max", 3,
								&rangeElements[i].maxElement.bsonValue);
		PgbsonWriterAppendBool(&childWriter, "minInclusive", 12,
							   rangeElements[i].isMinInclusive);
		PgbsonWriterAppendBool(&childWriter, "maxInclusive", 12,
							   rangeElements[i].isMaxInclusive);
		PgbsonWriterEndDocument(&clauseWriter, &childWriter);


		Const *bsonConst = makeConst(BsonTypeId(), -1, InvalidOid, -1, PointerGetDatum(
										 PgbsonWriterGetPgbson(&clauseWriter)), false,
									 false);

		OpExpr *opExpr = (OpExpr *) make_opclause(BsonRangeMatchOperatorOid(), BOOLOID,
												  false,
												  linitial(expr->args),
												  (Expr *) bsonConst, InvalidOid,
												  InvalidOid);
		opExpr->opfuncid = BsonRangeMatchFunctionId();
		rangeElements[i].minClause->rinfo->clause = (Expr *) opExpr;
		rangeElements[i].minClause->indexquals = list_make1(
			rangeElements[i].minClause->rinfo);
		rangeElements[i].maxClause->rinfo->clause = (Expr *) opExpr;
		indexClauses = list_delete_ptr(indexClauses, rangeElements[i].maxClause);
	}

	return indexClauses;
}


IndexPath *
TrimIndexRestrictInfoForBtreePath(PlannerInfo *root, IndexPath *indexPath,
								  bool *hasNonIdClauses)
{
	List *clauseRestrictInfos = NIL;
	List *objectIdClauses = NIL;
	ListCell *cell;
	bool hasOtherClauses = false;
	foreach(cell, indexPath->indexclauses)
	{
		IndexClause *clause = lfirst(cell);
		clauseRestrictInfos = lappend(clauseRestrictInfos, clause->rinfo);
		if (clause->indexcol == 1)
		{
			objectIdClauses = lappend(objectIdClauses, clause->rinfo->clause);
		}
	}

	/* Now walk the btree index restrict info for a match */
	List *restrictInfosToRemove = NIL;
	List *additionalIndexClauses = NIL;
	foreach(cell, indexPath->indexinfo->indrestrictinfo)
	{
		RestrictInfo *rinfo = lfirst(cell);
		if (list_member(clauseRestrictInfos, rinfo))
		{
			continue;
		}

		/*
		 * Strip ##= (BsonIndexBoundsEqual) ScalarArrayOpExpr entries from
		 * indrestrictinfo.  When the equivalent object_id = ANY(...) has
		 * already been pushed as an IndexClause, keeping the ##= entry
		 * causes PG to emit it as a redundant Filter in the plan.
		 */
		if (IsA(rinfo->clause, ScalarArrayOpExpr) &&
			IsScalarArrayOpExprTrimmable((ScalarArrayOpExpr *) rinfo->clause))
		{
			restrictInfosToRemove = lappend(restrictInfosToRemove, rinfo);
			continue;
		}

		/* Trim the reservoir sample marker qual if present. */
		if (IsA(rinfo->clause, FuncExpr))
		{
			FuncExpr *funcExpr = (FuncExpr *) rinfo->clause;
			if (funcExpr->funcid == BsonRangeMatchFunctionId())
			{
				if (IsBsonRangeArgsForReservoirSample(funcExpr->args))
				{
					restrictInfosToRemove = lappend(restrictInfosToRemove, rinfo);
					continue;
				}
			}
		}

		if (!IsA(rinfo->clause, OpExpr))
		{
			hasOtherClauses = true;
			continue;
		}

		OpExpr *clauseExpr = (OpExpr *) rinfo->clause;
		if (list_length(clauseExpr->args) != 2)
		{
			hasOtherClauses = true;
			continue;
		}

		if (!IsA(linitial(clauseExpr->args), Var) ||
			(castNode(Var, linitial(clauseExpr->args))->varattno !=
			 DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER) ||
			!IsA(lsecond(clauseExpr->args), Const))
		{
			hasOtherClauses = true;
			continue;
		}

		Var *firstVar = linitial(clauseExpr->args);
		Const *secondConst = lsecond(clauseExpr->args);
		pgbson *qual = DatumGetPgBson(secondConst->constvalue);

		pgbsonelement qualElement;
		const char *collation = PgbsonToSinglePgbsonElementWithCollation(qual,
																		 &qualElement);
		if (collation != NULL)
		{
			hasOtherClauses = true;
			continue;
		}

		if (qualElement.pathLength != 3 || strcmp(qualElement.path, "_id") != 0)
		{
			hasOtherClauses = true;
			continue;
		}

		const MongoIndexOperatorInfo *indexOp = GetMongoIndexOperatorByPostgresOperatorId(
			clauseExpr->opno);

		Expr *primaryKeyExpr = NULL;
		Expr *secondaryKeyExpr = NULL;
		if (!GetBtreeIndexBoundQuals(indexOp->indexStrategy, &qualElement.bsonValue,
									 firstVar->varno, &primaryKeyExpr, &secondaryKeyExpr))
		{
			hasOtherClauses = true;
			continue;
		}

		additionalIndexClauses = lappend(additionalIndexClauses, primaryKeyExpr);
		if (secondaryKeyExpr != NULL)
		{
			additionalIndexClauses = lappend(additionalIndexClauses, secondaryKeyExpr);
		}

		restrictInfosToRemove = lappend(restrictInfosToRemove, rinfo);
	}

	list_free(clauseRestrictInfos);
	if (list_length(additionalIndexClauses) == 0 &&
		list_length(restrictInfosToRemove) == 0)
	{
		*hasNonIdClauses = hasOtherClauses;
		return indexPath;
	}

	IndexPath *indexPathCopy = palloc(sizeof(IndexPath));
	memcpy(indexPathCopy, indexPath, sizeof(IndexPath));

	IndexOptInfo *indexInfoCopy = palloc(sizeof(IndexOptInfo));
	memcpy(indexInfoCopy, indexPath->indexinfo, sizeof(IndexOptInfo));
	indexInfoCopy->indrestrictinfo = list_difference_ptr(indexInfoCopy->indrestrictinfo,
														 restrictInfosToRemove);
	indexPathCopy->indexinfo = indexInfoCopy;

	List *origList = indexPathCopy->indexclauses;
	foreach(cell, additionalIndexClauses)
	{
		Expr *clause = lfirst(cell);
		if (list_member(objectIdClauses, clause))
		{
			continue;
		}

		RestrictInfo *additionalRestrictInfo =
			make_simple_restrictinfo(root, clause);
		IndexClause *singleIndexClause = makeNode(IndexClause);
		singleIndexClause->rinfo = additionalRestrictInfo;
		singleIndexClause->indexquals = list_make1(additionalRestrictInfo);
		singleIndexClause->lossy = false;
		singleIndexClause->indexcol = 1;
		singleIndexClause->indexcols = NIL;

		if (origList == indexPathCopy->indexclauses)
		{
			origList = list_copy(indexPathCopy->indexclauses);
		}

		origList = lappend(origList, singleIndexClause);
	}

	indexPathCopy->indexclauses = origList;
	*hasNonIdClauses = hasOtherClauses;
	return indexPathCopy;
}


/*
 * This function walks all the necessary qualifiers in a query Plan "Path"
 * Note that this currently replaces all the bson_dollar_<op> function calls
 * in the bitmapquals (which are used to display Recheck Conditions in EXPLAIN).
 * This way the Recheck conditions are consistent with the operator clauses pushed
 * to the index. This ensures that recheck conditions are also treated as equivalent
 * to the main index clauses. For more details see create_bitmap_scan_plan()
 */
static Path *
ReplaceFunctionOperatorsInPlanPath(PlannerInfo *root, RelOptInfo *rel, Path *path,
								   PlanParentType parentType,
								   ReplaceExtensionFunctionContext *context)
{
	check_stack_depth();
	CHECK_FOR_INTERRUPTS();

	if (IsA(path, BitmapOrPath))
	{
		BitmapOrPath *orPath = (BitmapOrPath *) path;
		ReplaceExtensionFunctionOperatorsInPaths(root, rel, orPath->bitmapquals,
												 PARENTTYPE_INVALID, context);
	}
	else if (IsA(path, BitmapAndPath))
	{
		BitmapAndPath *andPath = (BitmapAndPath *) path;
		ReplaceExtensionFunctionOperatorsInPaths(root, rel, andPath->bitmapquals,
												 PARENTTYPE_INVALID,
												 context);
		path = OptimizeBitmapQualsForBitmapAnd(andPath, context);
	}
	else if (IsA(path, BitmapHeapPath))
	{
		BitmapHeapPath *heapPath = (BitmapHeapPath *) path;
		heapPath->bitmapqual = ReplaceFunctionOperatorsInPlanPath(root, rel,
																  heapPath->bitmapqual,
																  PARENTTYPE_BITMAPHEAP,
																  context);
	}
	else if (IsA(path, CustomPath) &&
			 (EnablePrimaryKeyCursorScan ||
			  EnableDynamicCursors))
	{
		CustomPath *customPath = (CustomPath *) path;
		ReplaceExtensionFunctionOperatorsInPaths(root, rel,
												 customPath->custom_paths,
												 PARENTTYPE_NONE, context);
	}
	else if (IsA(path, IndexPath))
	{
		IndexPath *indexPath = (IndexPath *) path;

		/* Ignore primary key lookup paths parented in a bitmap scan:
		 * This can happen because a RUM index lookup can produce a 0 cost query as well
		 * and Postgres picks both and does a BitmapAnd - instead rely on a top level index path.
		 */
		bool isPrimaryKeyIndexPath = false;
		if (IsBtreePrimaryKeyIndex(indexPath->indexinfo) &&
			list_length(indexPath->indexclauses) > 1 &&
			parentType != PARENTTYPE_INVALID)
		{
			context->primaryKeyLookupPath = indexPath;
			isPrimaryKeyIndexPath = true;
		}

		const VectorIndexDefinition *vectorDefinition = NULL;
		if (indexPath->indexorderbys != NIL)
		{
			/* Only check for vector when there's an order by */
			vectorDefinition = GetVectorIndexDefinitionByIndexAmOid(
				indexPath->indexinfo->relam);
		}

		if (indexPath->indexinfo->indrestrictinfo != NIL && rel->baserestrictinfo == NIL)
		{
			indexPath->indexinfo->indrestrictinfo = NIL;
		}

		if (vectorDefinition != NULL)
		{
			context->hasVectorSearchQuery = true;
			context->queryDataForVectorSearch.VectorAccessMethodOid =
				indexPath->indexinfo->relam;

			/*
			 * For vector search, we also need to extract the search parameter from the wrap function.
			 * ApiCatalogSchemaName.bson_search_param(document, '{ "nProbes": 4 }'::ApiCatalogSchemaName.bson)
			 */
			ExtractAndSetSearchParamterFromWrapFunction(indexPath, context);

			if (EnableVectorForceIndexPushdown)
			{
				context->forceIndexQueryOpData.type = ForceIndexOpType_VectorSearch;
				context->forceIndexQueryOpData.path = indexPath;
			}
		}
		else if (indexPath->indexinfo->relam == GIST_AM_OID &&
				 list_length(indexPath->indexorderbys) == 1)
		{
			/* Specific to geonear: Check if the geonear query is pushed to index */
			Expr *orderByExpr = linitial(indexPath->indexorderbys);
			if (IsA(orderByExpr, OpExpr) && ((OpExpr *) orderByExpr)->opno ==
				BsonGeonearDistanceOperatorId())
			{
				context->forceIndexQueryOpData.type = ForceIndexOpType_GeoNear;
				context->forceIndexQueryOpData.path = indexPath;
			}
		}
		else
		{
			/* RUM/GIST indexes */
			ListCell *indexPathCell;
			foreach(indexPathCell, indexPath->indexclauses)
			{
				IndexClause *iclause = (IndexClause *) lfirst(indexPathCell);
				RestrictInfo *rinfo = iclause->rinfo;
				ReplaceExtensionFunctionContext childContext = { 0 };
				childContext.inputData = context->inputData;
				childContext.forceIndexQueryOpData = context->forceIndexQueryOpData;
				bool trimClauses = false;
				rinfo->clause = ProcessRestrictionInfoAndRewriteFuncExpr(
					rinfo->clause,
					&childContext, trimClauses);
			}

			if (BsonIndexAmRequiresRangeOptimization(indexPath->indexinfo->relam,
													 indexPath->indexinfo->opfamily[0]))
			{
				indexPath->indexclauses = OptimizeIndexExpressionsForRange(
					indexPath->indexclauses);
			}
		}

		indexPath = OptimizeIndexPathForFilters(indexPath, context);

		/* For btree indexscans ensure that we trim alternate quals */
		if (isPrimaryKeyIndexPath && indexPath->path.pathtype != T_IndexOnlyScan)
		{
			bool hasOtherQualsIgnore = false;
			path = (Path *) TrimIndexRestrictInfoForBtreePath(root, indexPath,
															  &hasOtherQualsIgnore);
		}
	}

	return path;
}


/* Given an expression object, rewrites the function as an equivalent
 * OpExpr. If it's a Bool Expr (AND, NOT, OR) evaluates the inner FuncExpr
 * and replaces them with the OpExpr equivalents.
 */
Expr *
ProcessRestrictionInfoAndRewriteFuncExpr(Expr *clause,
										 ReplaceExtensionFunctionContext *context,
										 bool trimClauses)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	/* These are unresolved functions from the index planning */
	if (IsA(clause, FuncExpr) || IsA(clause, OpExpr))
	{
		List *args;
		const MongoIndexOperatorInfo *operator = GetMongoIndexQueryOperatorFromNode(
			(Node *) clause, &args);
		if (operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_TEXT)
		{
			/*
			 * For text indexes, we inject a noop filter that does nothing, but tracks
			 * the serialization details of the index. This is then later used in $meta
			 * queries to get the rank
			 */
			if (context->forceIndexQueryOpData.type == ForceIndexOpType_None)
			{
				context->forceIndexQueryOpData.type = ForceIndexOpType_Text;
			}

			if (context->forceIndexQueryOpData.type != ForceIndexOpType_Text)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg(
									"Text index pushdown is not supported for this query")));
			}

			QueryTextIndexData *textIndexData =
				(QueryTextIndexData *) context->forceIndexQueryOpData.opExtraState;

			if (textIndexData != NULL && textIndexData->indexOptions != NULL)
			{
				/* TODO: Make TextIndex force use the index path if available
				 * Today this isn't guaranteed if there's another path picked
				 * e.g. ORDER BY object_id.
				 */
				context->inputData.isRuntimeTextScan = true;
				OpExpr *expr = GetOpExprClauseFromIndexOperator(
					operator, linitial(args), lsecond(args),
					textIndexData->indexOptions);
				Expr *finalExpr = (Expr *) GetFuncExprForTextWithIndexOptions(
					expr->args, textIndexData->indexOptions,
					context->inputData.isRuntimeTextScan,
					textIndexData);
				if (finalExpr != NULL)
				{
					return finalExpr;
				}
			}
		}
		else if (operator->indexStrategy != BSON_INDEX_STRATEGY_INVALID)
		{
			return (Expr *)
				   GetOpExprClauseFromIndexOperator(operator, linitial(args), lsecond(
														args),
													NULL);
		}
		else if (IsA(clause, FuncExpr))
		{
			FuncExpr *funcExpr = (FuncExpr *) clause;
			if (trimClauses && IsFuncExprTrimmable(funcExpr))
			{
				/* Trim these */
				return NULL;
			}

			if (trimClauses && funcExpr->funcid == BsonRangeMatchFunctionId())
			{
				/* Trim the reservoir sample marker qual if present. */
				if (IsBsonRangeArgsForReservoirSample(funcExpr->args))
				{
					return NULL;
				}
			}

			if (funcExpr->funcid == BsonFullScanFunctionOid())
			{
				Expr *firstArg = linitial(funcExpr->args);
				Expr *secondArg = lsecond(funcExpr->args);
				if (!IsA(secondArg, Const))
				{
					return clause;
				}

				Const *secondConst = (Const *) secondArg;

				/* Use the sort direction from the spec */
				int querySortDirection = 0;
				return CreateKnownFullScanExpr(
					secondConst->constvalue,
					firstArg, querySortDirection);
			}

			/* TODO(object_id_funcs): Make this more generalizable
			 * Also TODO: Int he indexrestrictinfo of the btree index, leave the funcExpr as is
			 * so that it can evaluate on object_id to support things like IX only SCAN
			 */
			if (IsClusterVersionAtleast(DocDB_V0, 112, 1) &&
				EnableObjectIdFuncExprConversion &&
				funcExpr->funcid == BsonRegexObjectIdMatchFunctionId())
			{
				operator = GetMongoIndexOperatorInfoByPostgresFuncId(
					BsonRegexMatchFunctionId());
				return (Expr *)
					   GetOpExprClauseFromIndexOperator(operator, linitial(args), lthird(
															args),
														NULL);
			}

			/* Delegate to extended index AM rewrite hook if available */
			if (EnableExtendedIndexes &&
				context->forceIndexQueryOpData.type == ForceIndexOpType_ExtendedIndex &&
				context->forceIndexQueryOpData.opExtraState != NULL)
			{
				QueryExtendedIndexContext *amContext =
					(QueryExtendedIndexContext *)
					context->forceIndexQueryOpData.opExtraState;
				if (amContext->indexAmEntry != NULL &&
					amContext->indexAmEntry->query_index_path_support_funcs != NULL)
				{
					QueryIndexPathSupportFuncs *support_funcs =
						amContext->indexAmEntry->query_index_path_support_funcs;
					Expr *rewritten =
						support_funcs->rewriteFuncExprFunc(funcExpr, context,
														   trimClauses);

					if (rewritten != (Expr *) funcExpr)
					{
						return rewritten;
					}
				}
			}
		}
	}
	else if (IsA(clause, NullTest))
	{
		NullTest *nullTest = (NullTest *) clause;
		CheckNullTestForGeoSpatialForcePushdown(context, nullTest);
	}
	else if (IsA(clause, ScalarArrayOpExpr))
	{
		if (context->inputData.isShardQuery && trimClauses)
		{
			if (IsScalarArrayOpExprTrimmable((ScalarArrayOpExpr *) clause))
			{
				return NULL;
			}
		}
	}
	else if (IsA(clause, BoolExpr))
	{
		BoolExpr *boolExpr = (BoolExpr *) clause;
		List *processedBoolArgs = NIL;
		ListCell *boolArgsCell;

		/* Evaluate args of the Boolean expression for FuncExprs */
		foreach(boolArgsCell, boolExpr->args)
		{
			Expr *innerExpr = (Expr *) lfirst(boolArgsCell);
			Expr *processedExpr = ProcessRestrictionInfoAndRewriteFuncExpr(
				innerExpr, context, trimClauses);
			if (processedExpr != NULL)
			{
				processedBoolArgs = lappend(processedBoolArgs,
											processedExpr);
			}
		}

		if (list_length(processedBoolArgs) == 0)
		{
			return NULL;
		}
		else if (list_length(processedBoolArgs) == 1 &&
				 boolExpr->boolop != NOT_EXPR)
		{
			/* If there's only one argument for $and/$or, return it */
			return (Expr *) linitial(processedBoolArgs);
		}

		boolExpr->args = processedBoolArgs;
	}

	return clause;
}


/*
 * Given a Mongo Index operator and a FuncExpr/OpExpr args that were constructed in the
 * query planner, along with the index options for an index, constructs an opExpr that is
 * appropriate for that index.
 * For regular operators this means converting to an operator that is used by that index
 * For TEXT this uses the language and weights that are in the index options to generate an
 * appropriate TSQuery.
 */
OpExpr *
GetOpExprClauseFromIndexOperator(const MongoIndexOperatorInfo *operator,
								 Expr *firstArgExpr, Expr *secondArg,
								 bytea *indexOptions)
{
	/* the index is valid for this qualifier - convert to opexpr */
	Oid operatorId = GetMongoQueryOperatorOid(operator);
	if (!OidIsValid(operatorId))
	{
		ereport(ERROR, (errmsg("<bson> %s <bson> operator not defined",
							   operator->postgresOperatorName)));
	}

	if (operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_TEXT)
	{
		/* for $text, we convert the input query into a 'tsvector' @@ 'tsquery' */
		Node *firstArg = (Node *) firstArgExpr;
		Node *bsonOperand = (Node *) secondArg;

		if (!IsA(bsonOperand, Const))
		{
			ereport(ERROR, (errmsg("Expecting a constant value for the text query")));
		}

		Const *operand = (Const *) bsonOperand;

		Assert(operand->consttype == BsonTypeId());
		pgbson *bsonValue = DatumGetPgBson(operand->constvalue);
		pgbsonelement element;
		PgbsonToSinglePgbsonElement(bsonValue, &element);

		Datum result = BsonTextGenerateTSQuery(&element.bsonValue, indexOptions);
		operand = makeConst(TSQUERYOID, -1, InvalidOid, -1, result,
							false, false);
		return (OpExpr *) make_opclause(operatorId, BOOLOID, false,
										(Expr *) firstArg,
										(Expr *) operand, InvalidOid, InvalidOid);
	}
	else
	{
		/* construct document <operator> <value> expression */
		Node *firstArg = (Node *) firstArgExpr;
		Node *operand = (Node *) secondArg;

		Expr *operandExpr;
		if (IsA(operand, Const))
		{
			Const *constOp = (Const *) operand;
			constOp = copyObject(constOp);
			constOp->consttype = BsonTypeId();
			operandExpr = (Expr *) constOp;
		}
		else if (IsA(operand, Var))
		{
			Var *varOp = (Var *) operand;
			varOp = copyObject(varOp);
			varOp->vartype = BsonTypeId();
			operandExpr = (Expr *) varOp;
		}
		else if (IsA(operand, Param))
		{
			Param *paramOp = (Param *) operand;
			paramOp = copyObject(paramOp);
			paramOp->paramtype = BsonTypeId();
			operandExpr = (Expr *) paramOp;
		}
		else
		{
			operandExpr = (Expr *) operand;
		}

		return (OpExpr *) make_opclause(operatorId, BOOLOID, false,
										(Expr *) firstArg,
										operandExpr, InvalidOid, InvalidOid);
	}
}


Path *
OptimizeAndTrimBitmapQualsForBitmapAnd(BitmapAndPath *andPath, uint64_t collectionId)
{
	ListCell *cell;
	foreach(cell, andPath->bitmapquals)
	{
		Path *path = (Path *) lfirst(cell);
		if (IsA(path, IndexPath))
		{
			IndexPath *indexPath = (IndexPath *) path;

			if (indexPath->indexinfo->relam != BTREE_AM_OID ||
				list_length(indexPath->indexclauses) != 1)
			{
				/* Skip any non Btree and cases where there are more index
				 * clauses.
				 */
				continue;
			}

			IndexClause *clause = linitial(indexPath->indexclauses);
			if (clause->indexcol == 0 &&
				IsOpExprShardKeyForUnshardedCollections(clause->rinfo->clause,
														collectionId))
			{
				/* The index path is a single restrict info on the shard_key_value = 'collectionid'
				 * This index path can be removed.
				 */
				andPath->bitmapquals = foreach_delete_current(andPath->bitmapquals, cell);
				continue;
			}
		}
	}

	if (list_length(andPath->bitmapquals) == 1)
	{
		return (Path *) linitial(andPath->bitmapquals);
	}

	return (Path *) andPath;
}


/*
 * In the scenario where we have a BitmapAnd of [ A AND B ]
 * if any of the nested IndexPaths are for shard_key_value = 'collid'
 * if this is true, then it's for an unsharded collection so we should remove
 * this qual.
 */
static Path *
OptimizeBitmapQualsForBitmapAnd(BitmapAndPath *andPath,
								ReplaceExtensionFunctionContext *context)
{
	if (!context->inputData.isShardQuery ||
		context->inputData.collectionId == 0)
	{
		return (Path *) andPath;
	}

	return OptimizeAndTrimBitmapQualsForBitmapAnd(andPath,
												  context->inputData.collectionId);
}


static IndexPath *
OptimizeIndexPathForFilters(IndexPath *indexPath,
							ReplaceExtensionFunctionContext *context)
{
	/* For cases of partial filter expressions the base restrict info is "copied" into the index exprs
	 * so in this case we need to do the restrictinfo changes here too.
	 * see check_index_predicates on indxpath.c.
	 */
	if (indexPath->indexinfo->indpred == NIL)
	{
		return indexPath;
	}

	indexPath->indexinfo->indrestrictinfo =
		ReplaceExtensionFunctionOperatorsInRestrictionPaths(
			indexPath->indexinfo->indrestrictinfo, context);

	/*
	 * If there's a consideration of a bitmap path,
	 * then the PFE can get added as a bitmap qual.
	 * In order to ensure we don't get extra runtime filters,
	 * ensure the structure of the filters on the indexOptInfo
	 * is the same as the one in the index quals.
	 * Do this on a copy of the indexoptinfo to not modify the
	 * one on the base index (in case there's other index paths etc
	 * depending on it).
	 */
	IndexOptInfo *copiedInfo = palloc(sizeof(IndexOptInfo));
	memcpy(copiedInfo, indexPath->indexinfo, sizeof(IndexOptInfo));
	List *processedPred = NIL;
	ListCell *singleCell;
	foreach(singleCell, copiedInfo->indpred)
	{
		Expr *predExpr = (Expr *) lfirst(singleCell);
		if (!IsA(predExpr, OpExpr))
		{
			predExpr = copyObject(predExpr);
		}

		bool trimClauses = true;
		Expr *expr = ProcessRestrictionInfoAndRewriteFuncExpr(predExpr,
															  context, trimClauses);
		if (expr != NULL)
		{
			processedPred = lappend(processedPred, expr);
		}
	}

	copiedInfo->indpred = processedPred;
	indexPath->indexinfo = copiedInfo;

	return indexPath;
}


/*
 * There maybe index paths created if any other applicable index is found
 * cheaper than the geospatial indexes. For geonear force index pushdown
 * we only consider all the geospatial indexes
 */
static List *
UpdateIndexListForGeonear(List *existingIndex,
						  ReplaceExtensionFunctionContext *context)
{
	List *newIndexesListForGeonear = NIL;
	ListCell *indexCell;
	foreach(indexCell, existingIndex)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, indexCell);
		if (index->relam == GIST_AM_OID && index->ncolumns > 0 &&
			(index->opfamily[0] == BsonGistGeographyOperatorFamily() ||
			 index->opfamily[0] == BsonGistGeometryOperatorFamily()))
		{
			newIndexesListForGeonear = lappend(newIndexesListForGeonear, index);
		}
	}
	return newIndexesListForGeonear;
}


/*
 * Pushed the text index query to runtime with index options if
 * no index path can be created
 */
static bool
PushTextQueryToRuntime(PlannerInfo *root, RelOptInfo *rel,
					   ReplaceExtensionFunctionContext *context,
					   MatchIndexPath matchIndexPath)
{
	QueryTextIndexData *textIndexData =
		(QueryTextIndexData *) context->forceIndexQueryOpData.opExtraState;
	if (textIndexData != NULL && textIndexData->indexOptions != NULL)
	{
		context->inputData.isRuntimeTextScan = true;
		return true;
	}
	return false;
}


/*
 * This method checks if the geonear query is eligible for using an alternate
 * index based on the type of query and then creates the index path for with
 * updated index quals again
 */
static bool
TryUseAlternateIndexGeonear(PlannerInfo *root, RelOptInfo *rel,
							ReplaceExtensionFunctionContext *context,
							MatchIndexPath matchIndexPath)
{
	OpExpr *geoNearOpExpr = (OpExpr *) context->forceIndexQueryOpData.opExtraState;
	if (geoNearOpExpr == NULL)
	{
		return false;
	}

	GeonearRequest *request;
	List *_2dIndexList = NIL;
	List *_2dsphereIndexList = NIL;
	GetAllGeoIndexesFromRelIndexList(rel->indexlist, &_2dIndexList,
									 &_2dsphereIndexList);

	if (CanGeonearQueryUseAlternateIndex(geoNearOpExpr, &request))
	{
		char *keyToUse = request->key;
		bool useSphericalIndex = true;
		bool isEmptyKey = strlen(request->key) == 0;
		if (isEmptyKey)
		{
			keyToUse =
				CheckGeonearEmptyKeyCanUseIndex(request, _2dIndexList,
												_2dsphereIndexList,
												&useSphericalIndex);
		}
		UpdateGeoNearQueryTreeToUseAlternateIndex(root, rel, geoNearOpExpr, keyToUse,
												  useSphericalIndex, isEmptyKey);
	}
	else
	{
		/* No index pushdown possible for geonear just error out */
		ThrowGeoNearUnableToFindIndex();
	}

	/* Because we have updated the quals to make use of index which could not be considered
	 * earlier as the indpred don't match and the sort_pathkeys are different, so we need
	 * to make sure that the sort_pathkey are constructed and index predicates are validated with the new quals.
	 */
	root->sort_pathkeys = make_pathkeys_for_sortclauses(root,
														root->parse->sortClause,
														root->parse->targetList);

	/*
	 * Make the query_pathkeys same as sort_pathkeys because we are only intereseted in making
	 * the index path for the geonear sort clause.
	 *
	 * create_index_paths will use the query_pathkeys to match the index with order by clause
	 * and generate the index path
	 */
	root->query_pathkeys = root->sort_pathkeys;

	/* `check_index_predicates` will set the indpred for indexes based on new quals and also
	 * sets indrestrictinfo which is all the quals less the ones that are implicitly implied by the index predicate.
	 * So for creating this we need to used the original restrictinfo list,
	 * we can safely use that because we updated the quals in place.
	 */
	check_index_predicates(root, rel);

	/* Try to create the index paths again with only the quals needed
	 * so that all the other indexes are ignored.
	 */
	rel->pathlist = NIL;
	rel->partial_pathlist = NIL;

	create_index_paths(root, rel);

	Path *matchedPath =
		FindIndexPathForQueryOperator(rel, rel->pathlist,
									  context, matchIndexPath,
									  context->forceIndexQueryOpData.opExtraState);
	if (matchedPath != NULL)
	{
		/* Discard any other path */
		rel->pathlist = list_make1(matchedPath);
		ReplaceExtensionFunctionOperatorsInPaths(root, rel, rel->pathlist,
												 PARENTTYPE_NONE, context);
		return true;
	}
	return false;
}


/*
 * We need to use all the available indexes for text queries as
 * these can be used in OR clauses. And BitmapOrPath requires
 * the indexes in all the OR arms to be present otherwise it can't
 * create a BitmapOrPath.
 * e.g. {$or [{$text: ..., a: 2}, {other: 1}]}. This needs to have
 * an index on `other` so that this text query can be pushed to the index.
 *
 * more info at generate_bitmap_or_paths
 */
static List *
UpdateIndexListForText(List *existingIndex, ReplaceExtensionFunctionContext *context)
{
	ListCell *indexCell;
	bool isValidTextIndexFound = false;
	foreach(indexCell, existingIndex)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, indexCell);
		if (IsBsonRegularIndexAm(index->relam) &&
			index->nkeycolumns > 0)
		{
			for (int i = 0; i < index->nkeycolumns; i++)
			{
				if (IsTextPathOpFamilyOid(index->relam, index->opfamily[i]))
				{
					isValidTextIndexFound = true;
					QueryTextIndexData *textIndexData =
						(QueryTextIndexData *) context->forceIndexQueryOpData.opExtraState;
					if (textIndexData == NULL)
					{
						textIndexData = palloc0(sizeof(QueryTextIndexData));
						context->forceIndexQueryOpData.opExtraState =
							(void *) textIndexData;
					}
					textIndexData->indexOptions = index->opclassoptions[i];

					break;
				}
			}
		}
	}

	if (!isValidTextIndexFound)
	{
		ThrowNoTextIndexFound();
	}

	return existingIndex;
}


/*
 * This today checks BitmapHeapPath, BitmapOrPath, BitmapAndPath and IndexPath
 * and returns true if it has an index path which matches the
 * query operator based on `matchIndexPath` function.
 */
static bool
IsMatchingPathForQueryOperator(RelOptInfo *rel, Path *path,
							   ReplaceExtensionFunctionContext *context,
							   MatchIndexPath matchIndexPath,
							   void *matchContext)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	if (IsA(path, BitmapHeapPath))
	{
		BitmapHeapPath *bitmapHeapPath = (BitmapHeapPath *) path;
		return IsMatchingPathForQueryOperator(rel, bitmapHeapPath->bitmapqual,
											  context, matchIndexPath, matchContext);
	}
	else if (IsA(path, BitmapOrPath))
	{
		BitmapOrPath *bitmapOrPath = (BitmapOrPath *) path;
		if (FindIndexPathForQueryOperator(rel, bitmapOrPath->bitmapquals, context,
										  matchIndexPath, matchContext) != NULL)
		{
			return true;
		}
		return false;
	}
	else if (IsA(path, BitmapAndPath))
	{
		BitmapAndPath *bitmapAndPath = (BitmapAndPath *) path;
		if (FindIndexPathForQueryOperator(rel, bitmapAndPath->bitmapquals, context,
										  matchIndexPath, matchContext) != NULL)
		{
			return true;
		}
		return false;
	}
	else if (IsA(path, IndexPath))
	{
		IndexPath *indexPath = (IndexPath *) path;
		if (matchIndexPath(indexPath, matchContext))
		{
			return true;
		}
		return false;
	}
	return false;
}


/*
 * Checks the newly constructed pathlist to see if the query operator that needs index are
 * pushed to the right index and returns the topLevel path which includes the indexpath for
 * the operator
 *
 * Returns a NULL path in case no index path was found
 */
static Path *
FindIndexPathForQueryOperator(RelOptInfo *rel, List *pathList,
							  ReplaceExtensionFunctionContext *context,
							  MatchIndexPath matchIndexPath,
							  void *matchContext)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	if (list_length(pathList) == 0)
	{
		return NULL;
	}
	ListCell *cell;
	foreach(cell, pathList)
	{
		Path *path = (Path *) lfirst(cell);
		if (IsMatchingPathForQueryOperator(rel, path, context, matchIndexPath,
										   matchContext))
		{
			return path;
		}
	}
	return NULL;
}


/*
 * Matches the index path for $geoNear query and checks if the index path
 * has a predicate which equals to geonear operator left side arguments which
 * is basically the predicate qual to match to the index
 */
static bool
MatchIndexPathForGeonear(IndexPath *indexPath, void *matchContext)
{
	if (indexPath->indexinfo->relam == GIST_AM_OID &&
		indexPath->indexinfo->nkeycolumns > 0 &&
		(indexPath->indexinfo->opfamily[0] == BsonGistGeographyOperatorFamily() ||
		 indexPath->indexinfo->opfamily[0] == BsonGistGeometryOperatorFamily()))
	{
		OpExpr *geoNearOpExpr = (OpExpr *) matchContext;
		if (geoNearOpExpr == NULL)
		{
			return false;
		}

		if (equal(linitial(geoNearOpExpr->args),
				  linitial(indexPath->indexinfo->indexprs)))
		{
			return true;
		}
	}
	return false;
}


/*
 * This function just performs a pointer equality for two index
 * paths provided
 */
static bool
MatchIndexPathEquals(IndexPath *path, void *matchContext)
{
	Node *matchedIndexPath = (Node *) matchContext;

	if (!IsA(matchedIndexPath, IndexPath))
	{
		return false;
	}

	return path == (IndexPath *) matchedIndexPath;
}


/*
 * Enables/disables the force index pushdown for geonear query based on the configuruation
 * setting `enableIndexForGeonear` or checks if the geonear order by clauses are really present
 * in the query.
 */
static bool
EnableGeoNearForceIndexPushdown(PlannerInfo *root,
								ReplaceExtensionFunctionContext *context)
{
	if (EnableGeonearForceIndexPushdown)
	{
		/* Geonear with no geonear operator (other geo operators) should not force geo index */
		return TryFindGeoNearOpExpr(root, context);
	}

	return false;
}


static bool
DefaultTrueForceIndexPushdown(PlannerInfo *root, ReplaceExtensionFunctionContext *context)
{
	return true;
}


static bool
DefaultFalseForceIndexPushdown(PlannerInfo *root,
							   ReplaceExtensionFunctionContext *context)
{
	return false;
}


/*
 * Matches the indexPath for $text query. It just checks if the index used
 * is a text index, as there can only be at max one text index for a collection.
 */
static bool
MatchIndexPathForText(IndexPath *indexPath, void *matchContext)
{
	if (IsBsonRegularIndexAm(indexPath->indexinfo->relam) &&
		indexPath->indexinfo->ncolumns > 0)
	{
		for (int ind = 0; ind < indexPath->indexinfo->ncolumns; ind++)
		{
			if (IsTextPathOpFamilyOid(indexPath->indexinfo->relam,
									  indexPath->indexinfo->opfamily[ind]))
			{
				return true;
			}
		}
	}
	return false;
}


pg_attribute_noreturn()
static void
ThrowNoTextIndexFound()
{
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INDEXNOTFOUND),
					errmsg("A text index is necessary to perform a $text query.")));
}


static void
ThrowNoVectorIndexFound(void)
{
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INDEXNOTFOUND),
					errmsg("vector index required for $search query during pushdown")));
}


static bool
MatchIndexPathForVector(IndexPath *indexPath, void *matchContext)
{
	const VectorIndexDefinition *def = GetVectorIndexDefinitionByIndexAmOid(
		indexPath->indexinfo->relam);
	return def != NULL;
}


static List *
UpdateIndexListForVector(List *existingIndex,
						 ReplaceExtensionFunctionContext *context)
{
	/* Trim all indexes except vector indexes for the purposes of planning */
	List *newIndexesListForVector = NIL;
	ListCell *indexCell;
	foreach(indexCell, existingIndex)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, indexCell);
		const VectorIndexDefinition *def = GetVectorIndexDefinitionByIndexAmOid(
			index->relam);
		if (def != NULL)
		{
			newIndexesListForVector = lappend(newIndexesListForVector, index);
		}
	}
	return newIndexesListForVector;
}


static List *
UpdateIndexListForIndexHint(List *existingIndex,
							ReplaceExtensionFunctionContext *context)
{
	/* Trim all indexes except those that match the hint */
	const IndexHintMatchContext *hintContext = (const
												IndexHintMatchContext *) context->
											   forceIndexQueryOpData.opExtraState;
	List *newIndexesListForHint = NIL;
	ListCell *indexCell;
	foreach(indexCell, existingIndex)
	{
		bool useLibPq = false;
		IndexOptInfo *index = lfirst_node(IndexOptInfo, indexCell);
		const char *docdbIndexName = ExtensionIndexOidGetIndexName(index->indexoid,
																   useLibPq);
		if (docdbIndexName == NULL)
		{
			continue;
		}

		if (strcmp(docdbIndexName, hintContext->documentDBIndexName) == 0)
		{
			newIndexesListForHint = lappend(newIndexesListForHint, index);
		}
	}

	return newIndexesListForHint;
}


static bool
MatchIndexPathForIndexHint(IndexPath *path, void *matchContext)
{
	const IndexHintMatchContext *context = (const IndexHintMatchContext *) matchContext;
	bool useLibPq = false;
	const char *docdbIndexName = ExtensionIndexOidGetIndexName(path->indexinfo->indexoid,
															   useLibPq);

	if (docdbIndexName == NULL)
	{
		return false;
	}

	/*
	 * Given that we force this index down we update the cost for it to be 0.
	 * In theory this is not needed since this is the only path available.
	 * However, this raised an issue where for RUM, we set the cost to INFINITY.
	 * In explain this is logged as cost: Infinity (without quotes) which breaks
	 * some Json parsers. To not have that happen for selected paths, we explicitly
	 * also set the costs to 0.
	 */
	bool isMatch = (strcmp(docdbIndexName, context->documentDBIndexName) == 0);
	if (isMatch)
	{
		path->indextotalcost = 0;
		path->path.total_cost = 0;
		path->path.startup_cost = 0;
	}

	return isMatch;
}


static bool
TryUseAlternateIndexForIndexHint(PlannerInfo *root, RelOptInfo *rel,
								 ReplaceExtensionFunctionContext *context,
								 MatchIndexPath matchIndexPath)
{
	IndexHintMatchContext *hintContext =
		(IndexHintMatchContext *) context->forceIndexQueryOpData.opExtraState;

	IndexOptInfo *matchedInfo = NULL;
	if (list_length(rel->indexlist) < 1)
	{
		return false;
	}

	matchedInfo = linitial(rel->indexlist);

	/* Non composite op classes do not support fullscan operators */
	const char *firstIndexPath = NULL;

	if (matchedInfo->unique && matchedInfo->nkeycolumns == 2 &&
		matchedInfo->relam == BTREE_AM_OID)
	{
		/* This will be the primary key Btree create an empty scan on it */
		IndexPath *newPath = create_index_path(root, matchedInfo, NIL, NIL, NIL, NIL,
											   ForwardScanDirection, false, NULL, 1,
											   false);
		add_path(rel, (Path *) newPath);
		return true;
	}

	int indexCol = 0;
	bool isHashedIndex = false;
	bool isWildCardIndex = false;
	if (IsBsonRegularIndexAm(matchedInfo->relam))
	{
		bytea *opClassOptions = matchedInfo->opclassoptions[0];
		if (IsUniqueCheckOpFamilyOid(matchedInfo->relam, matchedInfo->opfamily[0]))
		{
			/* For unique indexes, the first column is the shard key constraint */
			opClassOptions = matchedInfo->opclassoptions[1];
			indexCol = 1;
		}

		isHashedIndex = IsHashedPathOpFamilyOid(
			matchedInfo->relam, matchedInfo->opfamily[indexCol]);

		if (opClassOptions != NULL)
		{
			firstIndexPath = GetFirstPathFromIndexOptionsIfApplicable(
				opClassOptions, &isWildCardIndex);
		}
	}

	if (firstIndexPath == NULL || isWildCardIndex)
	{
		/* For hashed indexes, we don't support pushing down a full scan
		 * TODO: Support that. But in the interim for this unsupported index thunk to
		 * SeqScan.
		 * TODO: Should we do this for all unsupported cases (e.g. geospatial)
		 */
		if (isHashedIndex)
		{
			Path *seqscan = create_seqscan_path(root, rel, NULL, 0);
			add_path(rel, seqscan);
			return true;
		}

		return false;
	}

	/* For Sparse indexes with hint, we create an { exists: true } clause */
	OpExpr *scanClause;
	if (hintContext->isSparse)
	{
		scanClause = CreateExistsTrueOpExpr(
			hintContext->documentExpr,
			firstIndexPath, strlen(firstIndexPath));
	}
	else
	{
		int32_t orderByScanDirectionNone = 0;
		scanClause = CreateFullScanOpExpr(
			hintContext->documentExpr,
			firstIndexPath, strlen(firstIndexPath), orderByScanDirectionNone);
	}

	RestrictInfo *fullScanRestrictInfo =
		make_simple_restrictinfo(root, (Expr *) scanClause);
	IndexClause *singleIndexClause = makeNode(IndexClause);
	singleIndexClause->rinfo = fullScanRestrictInfo;
	singleIndexClause->indexquals = list_make1(fullScanRestrictInfo);
	singleIndexClause->lossy = false;
	singleIndexClause->indexcol = indexCol;
	singleIndexClause->indexcols = NIL;

	List *indexClauses = list_make1(singleIndexClause);
	IndexPath *newPath = create_index_path(root, matchedInfo, indexClauses, NIL, NIL, NIL,
										   ForwardScanDirection, false, NULL, 1,
										   false);

	/* See comment as well in MatchIndexPathForIndexHint */
	newPath->indextotalcost = 0;
	newPath->path.total_cost = 0;
	newPath->path.startup_cost = 0;
	add_path(rel, (Path *) newPath);
	return true;
}


static void
ThrowIndexHintUnableToFindIndex(void)
{
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNABLETOFINDINDEX),
					errmsg(
						"index specified by index hint is not found or invalid for the filters")));
}


static List *
UpdateIndexListForPrimaryKeyLookup(List *existingIndex,
								   ReplaceExtensionFunctionContext *context)
{
	/* This is done in the alternate path scenario */
	return NIL;
}


static bool
MatchIndexPathForPrimaryKeyLookup(IndexPath *path, void *matchContext)
{
	/* TODO: Can we do better here */
	return false;
}


/*
 * TryUseAlternateIndexForPrimaryKeyLookup is the "always succeeds" fallback for
 * primary key pushdown. Called when ForceIndexForQueryOperators could not find a
 * matching btree PK path via create_index_paths + MatchIndexPathForPrimaryKeyLookup.
 *
 * It manually constructs a zero-cost btree IndexPath on (shard_key_value, object_id):
 *  - If an existing PK IndexPath was found during WalkPathsForIndexOperations
 *    (primaryKeyLookupPath), it reuses that path and appends the object_id clause
 *    if missing.
 *  - Otherwise, builds a fresh IndexPath with both shard_key and object_id clauses.
 *
 * Costs are forced to zero so this path always wins in the planner's comparison.
 * For point equality on _id, cardinality is set to 1.
 *
 * After creating the path, removes redundant runtime _id filters from
 * baserestrictinfo to avoid double evaluation:
 *  - For _id equality: removes BsonEqualMatchRuntime if values match.
 *  - For _id $in: removes BsonInMatch if the ScalarArrayOpExpr array matches
 *    (via InMatchIsEquvalentTo).
 */
static bool
TryUseAlternateIndexForPrimaryKeyLookup(PlannerInfo *root, RelOptInfo *rel,
										ReplaceExtensionFunctionContext *indexContext,
										MatchIndexPath matchIndexPath)
{
	PrimaryKeyLookupContext *context =
		(PrimaryKeyLookupContext *) indexContext->forceIndexQueryOpData.opExtraState;

	IndexOptInfo *primaryKeyInfo = GetPrimaryKeyIndexOptInfo(rel);
	if (primaryKeyInfo == NULL)
	{
		return false;
	}

	IndexClause *objectIdClause =
		BuildPointReadIndexClause(context->objectId.restrictInfo, 1);

	IndexPath *path = NULL;
	if (context->primaryKeyLookupPath != NULL &&
		IsA(context->primaryKeyLookupPath, IndexPath))
	{
		path = (IndexPath *) context->primaryKeyLookupPath;

		bool indexPathHasEquality = false;
		ListCell *clauseCell;
		foreach(clauseCell, path->indexclauses)
		{
			IndexClause *clause = (IndexClause *) lfirst(clauseCell);
			if (clause->rinfo == context->objectId.restrictInfo)
			{
				indexPathHasEquality = true;
				break;
			}
		}

		if (!indexPathHasEquality)
		{
			path->indexclauses = lappend(path->indexclauses, objectIdClause);
		}
	}
	else
	{
		IndexClause *shardKeyClause =
			BuildPointReadIndexClause(context->shardKeyQualExpr, 0);
		List *clauses = list_make2(shardKeyClause, objectIdClause);
		List *orderbys = NIL;
		List *orderbyCols = NIL;
		List *pathKeys = NIL;
		bool indexOnly = false;
		Relids outerRelids = bms_copy(rel->lateral_relids);

		outerRelids = bms_add_members(outerRelids,
									  context->objectId.restrictInfo->clause_relids);
		if (context->shardKeyQualExpr->clause_relids)
		{
			outerRelids = bms_add_members(outerRelids,
										  context->shardKeyQualExpr->clause_relids);
		}

		outerRelids = bms_del_member(outerRelids, rel->relid);

#if PG_VERSION_NUM < 160000

		/* Enforce convention that outerRelids is exactly NULL if empty */
		if (bms_is_empty(outerRelids))
		{
			outerRelids = NULL;
		}
#endif

		double loopCount = 1;
		bool partialPath = false;
		path = create_index_path(root, primaryKeyInfo, clauses, orderbys,
								 orderbyCols, pathKeys,
								 ForwardScanDirection, indexOnly,
								 outerRelids,
								 loopCount, partialPath);
	}

	path->indextotalcost = 0;
	path->path.startup_cost = 0;
	path->path.total_cost = 0;

	/* Set cardinality for primary key lookup */
	if (context->objectId.isPrimaryKeyEquality)
	{
		path->path.rows = 1;
	}

	add_path(rel, (Path *) path);

	/* Trim the runtime expr if available */
	ListCell *runtimeCell;
	if (context->objectId.equalityBsonValue.value_type != BSON_TYPE_EOD)
	{
		foreach(runtimeCell, context->runtimeEqualityRestrictionData)
		{
			RuntimePrimaryKeyRestrictionData *equalityRestrictionData =
				(RuntimePrimaryKeyRestrictionData *) lfirst(runtimeCell);
			if (equalityRestrictionData->restrictInfo != NULL &&
				context->objectId.equalityBsonValue.value_type != BSON_TYPE_EOD &&
				BsonValueEquals(&context->objectId.equalityBsonValue,
								&equalityRestrictionData->value))
			{
				rel->baserestrictinfo = list_delete_ptr(rel->baserestrictinfo,
														equalityRestrictionData->
														restrictInfo);
			}
		}
	}
	else if (IsA(context->objectId.restrictInfo->clause, ScalarArrayOpExpr))
	{
		foreach(runtimeCell, context->runtimeDollarInRestrictionData)
		{
			RuntimePrimaryKeyRestrictionData *equalityRestrictionData =
				(RuntimePrimaryKeyRestrictionData *) lfirst(runtimeCell);
			if (equalityRestrictionData->restrictInfo != NULL &&
				IsA(context->objectId.restrictInfo->clause, ScalarArrayOpExpr) &&
				InMatchIsEquvalentTo(
					(ScalarArrayOpExpr *) context->objectId.restrictInfo->clause,
					&equalityRestrictionData->value))
			{
				rel->baserestrictinfo = list_delete_ptr(rel->baserestrictinfo,
														equalityRestrictionData->
														restrictInfo);
			}
		}
	}

	list_free_deep(context->runtimeDollarInRestrictionData);
	list_free_deep(context->runtimeEqualityRestrictionData);
	return true;
}


static void
PrimaryKeyLookupUnableToFindIndex(void)
{
	/* Do nothing and fall back to current behavior/logic */
}


static List *
UpdateIndexListForExtendedIndex(List *existingIndex,
								ReplaceExtensionFunctionContext *context)
{
	if (!EnableExtendedIndexes)
	{
		return existingIndex;
	}

	if (context->forceIndexQueryOpData.type == ForceIndexOpType_ExtendedIndex &&
		context->forceIndexQueryOpData.opExtraState != NULL)
	{
		QueryExtendedIndexContext *amContext =
			(QueryExtendedIndexContext *) context->forceIndexQueryOpData.opExtraState;
		if (amContext->indexAmEntry != NULL &&
			amContext->indexAmEntry->query_index_path_support_funcs != NULL)
		{
			ForceIndexSupportFuncs *supportFuncs =
				amContext->indexAmEntry->query_index_path_support_funcs->
				forceIndexSupportFuncs;

			return supportFuncs->updateIndexes(existingIndex, context);
		}
	}
	return existingIndex;
}


static bool
MatchIndexPathForExtendedIndex(IndexPath *path, void *matchContext)
{
	if (!EnableExtendedIndexes)
	{
		return false;
	}

	if (matchContext != NULL)
	{
		QueryExtendedIndexContext *amContext =
			(QueryExtendedIndexContext *) matchContext;
		if (amContext->indexAmEntry != NULL &&
			amContext->indexAmEntry->query_index_path_support_funcs != NULL)
		{
			ForceIndexSupportFuncs *supportFuncs =
				amContext->indexAmEntry->query_index_path_support_funcs->
				forceIndexSupportFuncs;

			return supportFuncs->matchIndexPath(path, matchContext);
		}
	}
	return false;
}


static bool
TryUseAlternateIndexForExtendedIndex(PlannerInfo *root, RelOptInfo *rel,
									 ReplaceExtensionFunctionContext *context,
									 MatchIndexPath matchIndexPath)
{
	if (!EnableExtendedIndexes)
	{
		return false;
	}

	if (context->forceIndexQueryOpData.type == ForceIndexOpType_ExtendedIndex &&
		context->forceIndexQueryOpData.opExtraState != NULL)
	{
		QueryExtendedIndexContext *amContext =
			(QueryExtendedIndexContext *) context->forceIndexQueryOpData.opExtraState;
		if (amContext->indexAmEntry != NULL &&
			amContext->indexAmEntry->query_index_path_support_funcs != NULL)
		{
			ForceIndexSupportFuncs *supportFuncs =
				amContext->indexAmEntry->query_index_path_support_funcs->
				forceIndexSupportFuncs;

			return supportFuncs->alternatePath(root, rel, context, matchIndexPath);
		}
	}
	return false;
}


static void
ThrowNoExtendedIndexFound(void)
{
	if (!EnableExtendedIndexes)
	{
		return;
	}

	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INDEXNOTFOUND),
					errmsg(
						"Extended index required for this query but no index found.")));
}


static bool
EnableExtendedIndexForceIndexPushdown(PlannerInfo *root,
									  ReplaceExtensionFunctionContext *context)
{
	if (!EnableExtendedIndexes)
	{
		return false;
	}

	if (context->forceIndexQueryOpData.type == ForceIndexOpType_ExtendedIndex &&
		context->forceIndexQueryOpData.opExtraState != NULL)
	{
		QueryExtendedIndexContext *amContext =
			(QueryExtendedIndexContext *) context->forceIndexQueryOpData.opExtraState;
		if (amContext->indexAmEntry != NULL &&
			amContext->indexAmEntry->query_index_path_support_funcs != NULL)
		{
			ForceIndexSupportFuncs *supportFuncs =
				amContext->indexAmEntry->query_index_path_support_funcs->
				forceIndexSupportFuncs;

			return supportFuncs->enableForceIndexPushdown(root, context);
		}
	}

	return false;
}


static bool
IsSupportedElemMatchExpr(Node *elemMatchExpr, bytea *options,
						 const MongoIndexOperatorInfo **targetOperator,
						 List **innerOpArgs, pgbsonelement *innerQueryElement)
{
	List *innerArgs;
	const MongoIndexOperatorInfo *innerOperator = GetMongoIndexQueryOperatorFromNode(
		elemMatchExpr,
		&innerArgs);
	if (innerOperator == NULL ||
		innerOperator->indexStrategy == BSON_INDEX_STRATEGY_INVALID)
	{
		/* This is not a valid operator for elemMatch */
		return false;
	}

	if (innerOperator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_ELEMMATCH ||
		IsNegationStrategy(innerOperator->indexStrategy))
	{
		/* We don't support negation strategies for nested elemMatch
		 * TODO(Composite): Can we do this safely?
		 */
		return false;
	}

	Node *operand = lsecond(innerArgs);
	Datum innerQueryValue = ((Const *) operand)->constvalue;

	/* Check if the index is valid for the function. The inner Const BSON encodes
	 * any collation alongside the qualifier element, so use it as the single source
	 * of truth rather than relying on a separately-passed collation.
	 */
	pgbsonelement queryElement;
	const char *innerCollation = PgbsonToSinglePgbsonElementWithCollation(
		DatumGetPgBson(innerQueryValue), &queryElement);

	if (!ValidateIndexForQualifierElement(options, &queryElement,
										  innerCollation, innerOperator->indexStrategy))
	{
		return false;
	}

	/* Since $eq can fail to traverse array of array paths, elemMatch pushdown cannot handle
	 * this since we need to skip the recheck.
	 * TODO: If we can get the recheck skipped here, we can support this here too.
	 */
	StringView queryPath = {
		.string = queryElement.path,
		.length = queryElement.pathLength
	};
	if (PathHasArrayIndexElements(&queryPath))
	{
		/* We don't support array index elements in elemMatch */
		return false;
	}

	if (innerOperator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_TEXT)
	{
		return false;
	}

	*targetOperator = innerOperator;
	*innerOpArgs = innerArgs;
	*innerQueryElement = queryElement;
	return true;
}


static void
WalkExprAndAddSupportedElemMatchExprs(List *clauses, bytea *options,
									  IndexElemmatchState *elemMatchState, const
									  char *topLevelPath)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	ListCell *elemMatchCell;
	foreach(elemMatchCell, clauses)
	{
		Node *elemMatchExpr = (Node *) lfirst(elemMatchCell);

		if (IsA(elemMatchCell, BoolExpr))
		{
			BoolExpr *boolExpr = (BoolExpr *) elemMatchExpr;
			if (boolExpr->boolop != AND_EXPR)
			{
				/* We only support $elemMatch with AND expressions */
				continue;
			}

			WalkExprAndAddSupportedElemMatchExprs(
				boolExpr->args, options, elemMatchState, topLevelPath);
			continue;
		}


		List *innerArgs = NIL;
		const MongoIndexOperatorInfo *innerOperator;
		pgbsonelement queryElement;
		if (!IsSupportedElemMatchExpr(elemMatchExpr, options, &innerOperator, &innerArgs,
									  &queryElement))
		{
			continue;
		}

		/* GetOrCreate the path level state */
		ListCell *cell;
		IndexElemMatchPathState *pathState = NULL;
		foreach(cell, elemMatchState->pathStates)
		{
			IndexElemMatchPathState *currentState = lfirst(cell);
			if (currentState->indexPathLength == queryElement.pathLength &&
				strncmp(queryElement.path, currentState->indexPath,
						currentState->indexPathLength) == 0)
			{
				pathState = currentState;
				break;
			}
		}

		if (pathState == NULL)
		{
			/* Not found - build a new one and add it in */
			pathState = palloc0(sizeof(IndexElemMatchPathState));
			pathState->indexPath = queryElement.path;
			pathState->indexPathLength = queryElement.pathLength;
			pathState->isTopLevel = strcmp(topLevelPath, queryElement.path) == 0;
			elemMatchState->pathStates = lappend(elemMatchState->pathStates, pathState);
		}

		IndexElemMatchSingleOp *singleOp = palloc0(sizeof(IndexElemMatchSingleOp));
		singleOp->op = innerOperator->indexStrategy;
		singleOp->value = queryElement.bsonValue;

		pathState->singleOps = lappend(pathState->singleOps, singleOp);
	}
}


static Expr *
GetElemMatchIndexPushdownOperator(Expr *documentExpr, pgbsonelement *queryElement)
{
	/* In this path, we write the elemMatch as a simple $elemMatch opExpr
	 * with a opExpr format:
	 * "path": { "elemMatchIndexOp": [ { "op": INDEX_STRATEGY, "value": BSON } ] }
	 */
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	pgbson_writer elemMatchWriter;
	PgbsonWriterStartDocument(&writer, queryElement->path, queryElement->pathLength,
							  &elemMatchWriter);
	PgbsonWriterAppendValue(&elemMatchWriter, "elemMatchIndexOp", 16,
							&queryElement->bsonValue);
	PgbsonWriterEndDocument(&writer, &elemMatchWriter);

	Const *bsonConst = makeConst(BsonTypeId(), -1, InvalidOid, -1, PointerGetDatum(
									 PgbsonWriterGetPgbson(&writer)), false,
								 false);
	return (Expr *) make_opclause(BsonRangeMatchOperatorOid(), BOOLOID, false,
								  documentExpr, (Expr *) bsonConst, InvalidOid,
								  InvalidOid);
}


static Expr *
ProcessElemMatchOperator(bytea *options, Datum queryValue, const
						 MongoIndexOperatorInfo *operator, List *args)
{
	pgbson *queryBson = DatumGetPgBson(queryValue);
	pgbsonelement argElement = { 0 };
	const char *queryCollation = PgbsonToSinglePgbsonElementWithCollation(queryBson,
																		  &argElement);


	BsonQueryOperatorContext context = { 0 };
	BsonQueryOperatorContextCommonBuilder(&context);
	context.documentExpr = linitial(args);
	context.collationString = queryCollation;

	/* Convert the pgbson query into a query AST that processes bson */
	Expr *expr = CreateQualForBsonExpression(&argElement.bsonValue,
											 argElement.path, &context);

	/* Get the underlying list of expressions that are AND-ed */
	List *clauses = make_ands_implicit(expr);

	IndexElemmatchState elemMatchState = { 0 };

	WalkExprAndAddSupportedElemMatchExprs(clauses, options, &elemMatchState,
										  argElement.path);

	if (elemMatchState.pathStates == NIL)
	{
		return NULL;
	}

	ListCell *cell;

	List *overallQuals = NIL;
	foreach(cell, elemMatchState.pathStates)
	{
		IndexElemMatchPathState *pathState = lfirst(cell);
		ListCell *innerCell;

		pgbson_writer writer;
		PgbsonWriterInit(&writer);
		pgbson_array_writer arrayWriter;
		PgbsonWriterStartArray(&writer, "", 0, &arrayWriter);

		foreach(innerCell, pathState->singleOps)
		{
			IndexElemMatchSingleOp *singleOp = lfirst(innerCell);

			pgbson_writer qualWriter;
			PgbsonArrayWriterStartDocument(&arrayWriter, &qualWriter);
			PgbsonWriterAppendInt32(&qualWriter, "op", 2, singleOp->op);
			PgbsonWriterAppendValue(&qualWriter, "value", 5, &singleOp->value);
			PgbsonWriterAppendBool(&qualWriter, "isTopLevel", 10, pathState->isTopLevel);
			PgbsonArrayWriterEndDocument(&arrayWriter, &qualWriter);
		}

		pgbsonelement queryElement;
		queryElement.path = pathState->indexPath;
		queryElement.pathLength = pathState->indexPathLength;
		queryElement.bsonValue = PgbsonArrayWriterGetValue(&arrayWriter);
		Expr *result = GetElemMatchIndexPushdownOperator(context.documentExpr,
														 &queryElement);
		PgbsonWriterFree(&writer);
		list_free_deep(pathState->singleOps);
		pathState->singleOps = NIL;
		overallQuals = lappend(overallQuals, result);
	}

	list_free_deep(elemMatchState.pathStates);
	return make_ands_explicit(overallQuals);
}


static OpExpr *
CreateExistsTrueOpExpr(Expr *documentExpr, const char *sourcePath,
					   uint32_t sourcePathLength)
{
	/* If the index is valid for the function, convert it to an OpExpr for a
	 * $exists true.
	 */
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	bson_value_t minKey = { 0 };
	minKey.value_type = BSON_TYPE_MINKEY;
	PgbsonWriterAppendValue(&writer, sourcePath, sourcePathLength, &minKey);
	Const *bsonConst = makeConst(BsonTypeId(), -1, InvalidOid, -1, PointerGetDatum(
									 PgbsonWriterGetPgbson(&writer)), false,
								 false);

	const MongoIndexOperatorInfo *info = GetMongoIndexOperatorInfoByPostgresFuncId(
		BsonGreaterThanEqualMatchIndexFunctionId());
	OpExpr *opExpr = (OpExpr *) make_opclause(GetMongoQueryOperatorOid(info), BOOLOID,
											  false,
											  documentExpr,
											  (Expr *) bsonConst, InvalidOid,
											  InvalidOid);
	opExpr->opfuncid = BsonGreaterThanEqualMatchIndexFunctionId();
	return opExpr;
}


OpExpr *
CreateFullScanOpExpr(Expr *documentExpr, const char *sourcePath, uint32_t
					 sourcePathLength, int32_t orderByDirection)
{
	/* If the index is valid for the function, convert it to an OpExpr for a
	 * $range full scan.
	 */
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	pgbson_writer rangeWriter;
	PgbsonWriterStartDocument(&writer, sourcePath, sourcePathLength,
							  &rangeWriter);
	if (orderByDirection == 0)
	{
		PgbsonWriterAppendBool(&rangeWriter, "fullScan", 8, true);
	}
	else
	{
		PgbsonWriterAppendInt32(&rangeWriter, "orderByScan", 11, orderByDirection);
	}

	PgbsonWriterEndDocument(&writer, &rangeWriter);

	Const *bsonConst = makeConst(BsonTypeId(), -1, InvalidOid, -1, PointerGetDatum(
									 PgbsonWriterGetPgbson(&writer)), false,
								 false);
	OpExpr *opExpr = (OpExpr *) make_opclause(BsonRangeMatchOperatorOid(), BOOLOID,
											  false,
											  documentExpr,
											  (Expr *) bsonConst, InvalidOid,
											  InvalidOid);
	opExpr->opfuncid = BsonRangeMatchFunctionId();
	return opExpr;
}


bool
GetBtreeIndexBoundQuals(BsonIndexStrategy strategy, const bson_value_t *queryValue, Index
						varno, Expr **firstBound, Expr **secondBound)
{
	switch (strategy)
	{
		case BSON_INDEX_STRATEGY_DOLLAR_EQUAL:
		{
			*firstBound = MakeSimpleIdExpr(queryValue, varno, BsonEqualOperatorId());
			*secondBound = NULL;
			return true;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER:
		{
			*firstBound = MakeSimpleIdExpr(queryValue, varno,
										   BsonGreaterThanOperatorId());
			*secondBound = MakeUpperBoundIdExpr(queryValue, varno);
			return true;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL:
		{
			*firstBound = MakeSimpleIdExpr(queryValue, varno,
										   BsonGreaterThanEqualOperatorId());
			*secondBound = MakeUpperBoundIdExpr(queryValue, varno);
			return true;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS:
		{
			*firstBound = MakeSimpleIdExpr(queryValue, varno, BsonLessThanOperatorId());
			*secondBound = MakeLowerBoundIdExpr(queryValue, varno);
			return true;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL:
		{
			*firstBound = MakeSimpleIdExpr(queryValue, varno,
										   BsonLessThanEqualOperatorId());
			*secondBound = MakeLowerBoundIdExpr(queryValue, varno);
			return true;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_IN:
		{
			if (queryValue->value_type != BSON_TYPE_ARRAY)
			{
				return false;
			}

			List *inArgs = NIL;
			bson_iter_t inQualsIter;
			BsonValueInitIterator(queryValue, &inQualsIter);


			/* Get the $in values */
			while (bson_iter_next(&inQualsIter))
			{
				inArgs = lappend(inArgs, MakeBsonConst(BsonValueToDocumentPgbson(
														   bson_iter_value(
															   &inQualsIter))));
			}

			if (inArgs != NIL)
			{
				/* Create an IN clause, in SQL this is
				 * a "ANY ( bson[] )" expression.
				 */
				ScalarArrayOpExpr *inOperator = makeNode(ScalarArrayOpExpr);
				inOperator->useOr = true;
				inOperator->opno = BsonEqualOperatorId();
				inOperator->opfuncid = BsonEqualFunctionOid();

				/* First arg is the object_id var */
				AttrNumber documentIdAttnum = 2;
				Var *documentIdVar = makeVar(varno,
											 documentIdAttnum,
											 BsonTypeId(), -1,
											 InvalidOid, 0);

				/* Second arg is an ArrayExpr containing the documents */
				ArrayExpr *arrayExpr = makeNode(ArrayExpr);
				arrayExpr->array_typeid = GetBsonArrayTypeOid();
				arrayExpr->element_typeid = BsonTypeId();
				arrayExpr->multidims = false;
				arrayExpr->elements = inArgs;
				inOperator->args = list_make2(documentIdVar, arrayExpr);

				*firstBound = (Expr *) inOperator;
				*secondBound = NULL;
				return true;
			}
		}

		default:
			return false;
	}

	return false;
}


/*
 * When querying a table with no filters and an orderby, there is a full scan
 * filter applied that allows for index pushdowns. If this is the first key
 * of a composite index, allow the pushdown to support cases like
 * SELECT document from table order by a asc
 */
static Expr *
ProcessFullScanForOrderBy(SupportRequestIndexCondition *req, List *args)
{
	Node *operand = lsecond(args);
	if (!IsA(operand, Const))
	{
		return NULL;
	}

	/* Try to get the index options we serialized for the index.
	 * If one doesn't exist, we can't handle push downs of this clause */
	bytea *options = req->index->opclassoptions[req->indexcol];
	if (options == NULL)
	{
		return NULL;
	}

	Oid operatorFamily = req->index->opfamily[req->indexcol];
	Datum queryValue = ((Const *) operand)->constvalue;

	if (!IsCompositeOpFamilyOid(req->index->relam, operatorFamily))
	{
		return NULL;
	}

	pgbsonelement sortElement;
	const char *queryCollation = PgbsonToSinglePgbsonElementWithCollation(
		DatumGetPgBson(queryValue), &sortElement);
	if (!IsQueryCollationCompatibleWithIndex(queryCollation, options))
	{
		return NULL;
	}

	if (!ValidateIndexForQualifierValue(options, queryValue,
										BSON_INDEX_STRATEGY_DOLLAR_ORDERBY))
	{
		return NULL;
	}

	int8_t sortDirection;
	GetCompositeOpClassColumnNumber(sortElement.path, options,
									&sortDirection);

	int32_t querySortDirection = BsonValueAsInt32(&sortElement.bsonValue);
	bool indexCanOrder = false;
	bool indexSupportsReverseSort = GetIndexSupportsBackwardsScan(req->index->relam,
																  &indexCanOrder);
	if (querySortDirection != sortDirection && !indexSupportsReverseSort)
	{
		return NULL;
	}

	if (!indexCanOrder)
	{
		return NULL;
	}

	return CreateKnownFullScanExpr(queryValue, linitial(args), querySortDirection);
}


static Expr *
CreateKnownFullScanExpr(Datum queryValue, Expr *documentExpr, int sortDirection)
{
	/* If the index is valid for the function, convert it to an OpExpr for a
	 * $range full scan.
	 */
	pgbsonelement sourceElement;
	PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(queryValue),
											 &sourceElement);

	if (sortDirection == 0)
	{
		sortDirection = BsonValueAsInt32(&sourceElement.bsonValue);
	}

	return (Expr *) CreateFullScanOpExpr(documentExpr, sourceElement.path,
										 sourceElement.pathLength, sortDirection);
}


static bool
ExtractExprsForObjectIdFunction(FuncExpr *expr, pgbsonelement *queryElement,
								Var **objectIdVar,
								Var **documentVar, Datum *queryValue)
{
	if (list_length(expr->args) != 3)
	{
		return false;
	}

	Expr *documentExpr = linitial(expr->args);
	Expr *objectIdExpr = lsecond(expr->args);
	Expr *filterExpr = lthird(expr->args);
	if (IsA(documentExpr, RelabelType))
	{
		documentExpr = ((RelabelType *) documentExpr)->arg;
	}

	if (IsA(objectIdExpr, RelabelType))
	{
		objectIdExpr = ((RelabelType *) objectIdExpr)->arg;
	}

	if (IsA(filterExpr, RelabelType))
	{
		filterExpr = ((RelabelType *) filterExpr)->arg;
	}

	if (!IsA(filterExpr, Const) || !IsA(objectIdExpr, Var) || !IsA(documentExpr, Var))
	{
		return false;
	}

	Const *exprConst = (Const *) filterExpr;
	*objectIdVar = (Var *) objectIdExpr;
	*documentVar = (Var *) documentExpr;
	if (exprConst->constisnull)
	{
		return false;
	}

	pgbson *queryBson = DatumGetPgBson(exprConst->constvalue);
	const char *collation = PgbsonToSinglePgbsonElementWithCollation(queryBson,
																	 queryElement);
	if (IsCollationApplicable(collation))
	{
		return false;
	}

	if (queryElement->pathLength != 3 || strncmp(queryElement->path, "_id", 3) != 0)
	{
		return false;
	}

	*queryValue = exprConst->constvalue;
	return true;
}


static Expr *
HandleRegexBtreeIdPushdown(const bson_value_t *filter, int varno)
{
	/* A regex match on _id: regex bounds as needed */
	const char *regex, *options;
	if (filter->value_type == BSON_TYPE_REGEX)
	{
		regex = filter->value.v_regex.regex;
		options = filter->value.v_regex.options;
	}
	else if (filter->value_type == BSON_TYPE_UTF8)
	{
		regex = filter->value.v_utf8.str;
		options = "";
	}
	else
	{
		return NULL;
	}

	/* Per commands_common.c _id cannot be a $regex type. consequently,
	 * We can simply have the bounds be string values and not worry about equality
	 * on regex.
	 */
	bson_value_t lowerBound = { 0 }, upperBound = { 0 };
	bool lowerBoundInclusive = false, upperBoundInclusive = false;
	GetBoundsForRegex(regex, options, &lowerBound, &lowerBoundInclusive, &upperBound,
					  &upperBoundInclusive);

	Expr *lowerBoundExpr = MakeSimpleIdExpr(&lowerBound, varno,
											lowerBoundInclusive ?
											BsonGreaterThanEqualOperatorId() :
											BsonGreaterThanOperatorId());
	Expr *upperBoundExpr = MakeSimpleIdExpr(&upperBound, varno,
											upperBoundInclusive ?
											BsonLessThanEqualOperatorId() :
											BsonLessThanOperatorId());

	/* Now inject clauses for the regex operator based on the bounds formed */
	return (Expr *) list_make2(lowerBoundExpr, upperBoundExpr);
}


static Expr *
HandleSupportRequestForBtreeObjectIdCondition(SupportRequestIndexCondition *req)
{
	if (!IsClusterVersionAtleast(DocDB_V0, 112, 1))
	{
		return NULL;
	}

	FuncExpr *regexFuncExpr = (FuncExpr *) req->node;

	pgbsonelement queryElement;
	Var *objectIdVar, *documentVar;
	Datum queryValue;
	if (!ExtractExprsForObjectIdFunction(regexFuncExpr, &queryElement, &objectIdVar,
										 &documentVar, &queryValue))
	{
		return NULL;
	}

	/* Assume not lossy, operators can override this.*/
	req->lossy = false;

	const MongoIndexOperatorInfo *operator =
		GetObjectIdMongoIndexOperatorByPostgresFuncId(req->funcid);
	Expr *lowerBound = NULL;
	Expr *upperBound = NULL;

	if (GetBtreeIndexBoundQuals(operator->indexStrategy, &queryElement.bsonValue,
								objectIdVar->varno, &lowerBound, &upperBound))
	{
		return upperBound != NULL ? (Expr *) list_make2(lowerBound, upperBound) :
			   lowerBound;
	}

	if (operator->indexStrategy == BSON_INDEX_STRATEGY_DOLLAR_REGEX)
	{
		req->lossy = true;
		return HandleRegexBtreeIdPushdown(&queryElement.bsonValue, objectIdVar->varno);
	}

	return NULL;
}


static Expr *
HandleSupportRequestForRegularObjectIdCondition(SupportRequestIndexCondition *req)
{
	if (!IsClusterVersionAtleast(DocDB_V0, 112, 1))
	{
		return NULL;
	}

	bytea *options = req->index->opclassoptions[req->indexcol];
	if (options == NULL)
	{
		return NULL;
	}

	if (!IsA(req->node, FuncExpr))
	{
		return NULL;
	}

	pgbsonelement queryElement;
	Var *objectIdVar, *documentVar;
	Datum queryValue;
	FuncExpr *funcExpr = (FuncExpr *) req->node;
	if (!ExtractExprsForObjectIdFunction(funcExpr,
										 &queryElement, &objectIdVar, &documentVar,
										 &queryValue))
	{
		return NULL;
	}

	/* Check if the index is valid for the function */
	const MongoIndexOperatorInfo *operator =
		GetObjectIdMongoIndexOperatorByPostgresFuncId(req->funcid);

	if (operator->indexStrategy == BSON_INDEX_STRATEGY_INVALID)
	{
		return NULL;
	}

	if (!ValidateIndexForQualifierValue(options, queryValue,
										operator->indexStrategy))
	{
		return NULL;
	}

	Expr *filterConst = lthird(funcExpr->args);
	Expr *finalExpression =
		(Expr *) GetOpExprClauseFromIndexOperator(operator, (Expr *) documentVar,
												  (Expr *) filterConst, options);
	return finalExpression;
}
