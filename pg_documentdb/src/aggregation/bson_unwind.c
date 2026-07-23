/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/bson/bson_unwind.c
 *
 * Implementation of the $unwind operator.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>

#include <nodes/makefuncs.h>
#include <nodes/supportnodes.h>
#include <optimizer/pathnode.h>

#include "aggregation/bson_project.h"
#include "aggregation/bson_projection_tree.h"
#include "io/bson_set_returning_functions.h"
#include "io/bson_traversal.h"
#include "metadata/metadata_cache.h"
#include "opclass/bson_index_support.h"
#include "planner/mongo_query_operator.h"
#include "query/bson_dollar_selectivity.h"
#include "utils/string_view.h"

/*
 * Default row estimate for bson_distinct_unwind for a document whose unwound
 * path holds an array. Driven by the documentdb.distinct_unwind_default_rows
 * GUC (see system_configs.c); the extern below binds to that variable.
 */
extern int DistinctUnwindDefaultRows;

/*
 * Feature flag gating whether the distinct-unwind support function derives its
 * row estimate from statistics of the unwound path. Defined in
 * feature_flag_configs.c.
 */
extern bool EnableDistinctUnwindRowsFromStatistics;

/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */

/* Traversal state for distinct passed into TraverseBson
 * Holds the tuplestore and descriptor that will be used to dump
 * the tuples from the current document.
 */
typedef struct DistinctTraverseState
{
	Tuplestorestate *tupleStore;
	TupleDesc tupleDescriptor;
} DistinctTraverseState;


static pgbson * BsonUnwindElement(pgbson *document, char *path, char *indexFieldName,
								  long index, const bson_value_t *element);
static pgbson * BsonUnwindEmptyArray(pgbson *document, char *path, char *indexFieldName);
static Datum BsonUnwindArray(PG_FUNCTION_ARGS, Tuplestorestate *tupleState,
							 TupleDesc *tupleDescriptor,
							 char *path, char *indexFieldName, bool
							 preserveNullAndEmpty);
static bool DistinctContinueProcessIntermediateArray(void *state, const
													 bson_value_t *value, bool
													 isArrayIndexSearch);
static void DistinctSetTraverseResult(void *state, TraverseBsonResult result);
static bool DistinctVisitArrayField(pgbsonelement *element, const
									StringView *traversePath, int
									arrayIndex, void *state);
static bool DistinctVisitTopLevelField(pgbsonelement *element, const
									   StringView *traversePath, void *state);

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

PG_FUNCTION_INFO_V1(bson_dollar_unwind);
PG_FUNCTION_INFO_V1(bson_dollar_unwind_with_options);
PG_FUNCTION_INFO_V1(bson_distinct_unwind);
PG_FUNCTION_INFO_V1(bson_distinct_unwind_support);
PG_FUNCTION_INFO_V1(bson_lookup_unwind);

/*
 * bson_dollar_unwind_with_options takes:
 * 1) a bson document
 * 2) A bson document of the form:
 *      { $unwind: {
 *          path: "$a.b",
 *          [optional] preserveNullAndEmptyArrays: bool,
 *          [optional] includeArrayIndex: string
 *      }}
 */
Datum
bson_dollar_unwind_with_options(PG_FUNCTION_ARGS)
{
	pgbson *spec = PG_GETARG_PGBSON_PACKED(1);

	char *path = NULL;
	bool preserveNullAndEmpty = false;
	char *indexFieldName = NULL;

	bson_iter_t specIter;
	PgbsonInitIterator(spec, &specIter);
	while (bson_iter_next(&specIter))
	{
		if (strcmp(bson_iter_key(&specIter), "path") == 0)
		{
			const bson_value_t *pathValue = bson_iter_value(&specIter);
			if (pathValue->value_type != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg(
									"$unwind path must be a text value")));
			}

			path = pathValue->value.v_utf8.str;
		}
		else if (strcmp(bson_iter_key(&specIter), "preserveNullAndEmptyArrays") == 0)
		{
			const bson_value_t *preserveNullAndEmptyValue = bson_iter_value(&specIter);
			if (preserveNullAndEmptyValue->value_type != BSON_TYPE_BOOL)
			{
				ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg(
									"$unwind preserveNullAndEmptyArrays must be a bool value")));
			}
			preserveNullAndEmpty = preserveNullAndEmptyValue->value.v_bool;
		}
		else if (strcmp(bson_iter_key(&specIter), "includeArrayIndex") == 0)
		{
			const bson_value_t *arrayIndex = bson_iter_value(&specIter);
			if (arrayIndex->value_type != BSON_TYPE_UTF8)
			{
				ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg(
									"$unwind includeArrayIndex must be a text value")));
			}
			indexFieldName = arrayIndex->value.v_utf8.str;
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg(
								"option not recognized during unwind stage")));
		}
	}

	if (path == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg(
							"$unwind requires a path")));
	}

	TupleDesc descriptor;
	Tuplestorestate *tupleStore = SetupBsonTuplestore(fcinfo, &descriptor);

	return BsonUnwindArray(fcinfo, tupleStore, &descriptor, path, indexFieldName,
						   preserveNullAndEmpty);
}


/*
 * bson_dollar_unwind takes:
 * 1) a bson document
 * 2) a dot notation field path to the purported array
 * 3) an optional text for an index field in the output
 * 4) a boolean indicating whether to preserve null and empty arrays
 */
Datum
bson_dollar_unwind(PG_FUNCTION_ARGS)
{
	char *indexFieldName = NULL;
	bool preserveNullAndEmpty = false;

	TupleDesc descriptor;
	Tuplestorestate *tupleStore = SetupBsonTuplestore(fcinfo, &descriptor);

	return BsonUnwindArray(fcinfo, tupleStore, &descriptor, text_to_cstring(
							   PG_GETARG_TEXT_PP(1)), indexFieldName,
						   preserveNullAndEmpty);
}


/*
 * Implements the unwind function for Distinct. Walks the document for the given
 * dotted path, and for every element that matches the path, adds it to the tuple store
 * for instance, given the document { "a": [ { "b": [ 1, 2, 3, 4] }, { "b": [ 2, 4 ] }, { "b": 1 }]} for the path
 * "a.b", will produce a tuple store with the elements [ 1, 2, 3, 4, 2, 4, 1 ].
 * This will then be passed through DISTINCT to reduce the array set.
 */
Datum
bson_distinct_unwind(PG_FUNCTION_ARGS)
{
	TupleDesc descriptor;
	Tuplestorestate *tupleStore = SetupBsonTuplestore(fcinfo, &descriptor);
	pgbson *document = PG_GETARG_PGBSON(0);
	char *path = text_to_cstring(PG_GETARG_TEXT_P(1));

	bson_iter_t documentIterator;
	PgbsonInitIterator(document, &documentIterator);
	TraverseBsonExecutionFuncs distinctExecutionFuncs =
	{
		.ContinueProcessIntermediateArray = DistinctContinueProcessIntermediateArray,
		.SetTraverseResult = DistinctSetTraverseResult,
		.VisitArrayField = DistinctVisitArrayField,
		.VisitTopLevelField = DistinctVisitTopLevelField,
		.SetIntermediateArrayIndex = NULL,
		.HandleIntermediateArrayPathNotFound = NULL,
		.SetIntermediateArrayStartEnd = NULL,
	};

	DistinctTraverseState traverseState =
	{
		.tupleDescriptor = descriptor,
		.tupleStore = tupleStore
	};

	TraverseBson(&documentIterator, path, &traverseState, &distinctExecutionFuncs);

	PG_RETURN_VOID();
}


/*
 * Planner support function shared by bson_distinct_unwind and the
 * distinct-exists filter (bson_dollar_distinct_exists).
 *
 * For bson_distinct_unwind it handles the SupportRequestRows request, returning
 * a row estimate that matches the function's declared prorows (preserving the
 * previous static behavior). When enable_distinct_unwind_rows_from_statistics is
 * set, it inspects the invoking FuncExpr and derives a statistics-based estimate
 * from the unwound field path.
 *
 * All other request types are delegated to HandleDistinctExistsSupportRequest,
 * which lowers a distinct-exists filter to a "path >= MinKey" comparison for
 * index pushdown and supplies matching selectivity and cost estimates. Requests
 * that neither path handles are declined by returning NULL, in which case the
 * planner falls back to the target function's defaults.
 */
Datum
bson_distinct_unwind_support(PG_FUNCTION_ARGS)
{
	Node *supportRequest = (Node *) PG_GETARG_POINTER(0);

	if (IsA(supportRequest, SupportRequestRows))
	{
		SupportRequestRows *req = (SupportRequestRows *) supportRequest;
		double estimatedRows = (double) DistinctUnwindDefaultRows;

		if (EnableDistinctUnwindRowsFromStatistics &&
			req->node != NULL && IsA(req->node, FuncExpr))
		{
			FuncExpr *distinctUnwindExpr = (FuncExpr *) req->node;

			/*
			 * The support function is only attached to bson_distinct_unwind,
			 * but the invoking node could be a different function in principle
			 * (e.g. an inlined wrapper). If it is not bson_distinct_unwind,
			 * fall through to the default estimate below.
			 */
			if (distinctUnwindExpr->funcid == BsonDistinctUnwindFunctionOid() &&
				list_length(distinctUnwindExpr->args) == 2)
			{
				Node *documentArg = (Node *) linitial(distinctUnwindExpr->args);
				Node *pathArg = (Node *) lsecond(distinctUnwindExpr->args);
				if (req->root != NULL && IsA(documentArg, Var) &&
					IsA(pathArg, Const) && !((Const *) pathArg)->constisnull)
				{
					Var *documentVar = (Var *) documentArg;
					RelOptInfo *rel = find_base_rel(req->root, documentVar->varno);
					text *pathText =
						DatumGetTextPP(((Const *) pathArg)->constvalue);
					StringView unwindPath = CreateStringViewFromText(pathText);

					if (EnablePlannerCostSelectivityFromRelOptInfo(req->root, rel))
					{
						/*
						 * Estimate how often the unwound path holds an array via
						 * a type-bracketed "path >= []" comparison: only a field
						 * whose value is an array is expanded by the distinct
						 * unwind. This mirrors how an $exists filter is lowered
						 * to "path >= MinKey" (see CreateExistsTrueOpExpr), but
						 * brackets on the empty array instead. Absent statistics,
						 * a default selectivity of 1.0 leaves the estimate
						 * unchanged.
						 */
						pgbson_writer queryWriter;
						pgbson_array_writer arrayWriter;
						PgbsonWriterInit(&queryWriter);
						PgbsonWriterStartArray(&queryWriter, unwindPath.string,
											   unwindPath.length, &arrayWriter);
						PgbsonWriterEndArray(&queryWriter, &arrayWriter);

						Const *arrayBoundConst =
							makeConst(BsonTypeId(), -1, InvalidOid, -1,
									  PointerGetDatum(
										  PgbsonWriterGetPgbson(&queryWriter)),
									  false, false);

						const MongoIndexOperatorInfo *gteOperator =
							GetMongoIndexOperatorInfoByPostgresFuncId(
								BsonGreaterThanEqualMatchIndexFunctionId());
						List *selectivityArgs =
							list_make2(documentVar, arrayBoundConst);
						double arraySelectivity = GetDollarOperatorSelectivity(
							req->root, GetMongoQueryOperatorOid(gteOperator),
							selectivityArgs, InvalidOid, 0, 1.0);

						/*
						 * Estimate how often the unwound path is null via an
						 * equality against null. A document whose path is null
						 * (or, in the query semantics, absent) does not expand
						 * into a distinct value, so it contributes no rows.
						 * Absent statistics a default selectivity of 0.0 leaves
						 * the estimate unchanged.
						 */
						pgbson_writer nullQueryWriter;
						PgbsonWriterInit(&nullQueryWriter);
						PgbsonWriterAppendNull(&nullQueryWriter, unwindPath.string,
											   unwindPath.length);

						Const *nullBoundConst =
							makeConst(BsonTypeId(), -1, InvalidOid, -1,
									  PointerGetDatum(
										  PgbsonWriterGetPgbson(&nullQueryWriter)),
									  false, false);

						const MongoIndexOperatorInfo *eqOperator =
							GetMongoIndexOperatorInfoByPostgresFuncId(
								BsonEqualMatchIndexFunctionId());
						List *nullSelectivityArgs =
							list_make2(documentVar, nullBoundConst);
						double nullSelectivity = GetDollarOperatorSelectivity(
							req->root, GetMongoQueryOperatorOid(eqOperator),
							nullSelectivityArgs, InvalidOid, 0, 0.0);

						/*
						 * The unwind expands only documents whose path holds an
						 * array; a document with a non-null scalar at the path
						 * yields a single row, while a null (or absent) path
						 * yields none. Model the expected per-call output as a
						 * mixture of these populations, using the default
						 * expansion factor for the array case:
						 *
						 *   rows = (1 - s - n) * 1 + n * 0 + s * DEFAULT
						 *
						 * where s is the array selectivity and n the null
						 * selectivity. Absent statistics s defaults to 1.0 and n
						 * to 0.0, which leaves the estimate at DEFAULT and
						 * preserves the prior static behavior. Clamp the scalar
						 * population at zero (independent estimates can sum above
						 * one) and the total at a single row.
						 */
						double scalarSelectivity =
							Max(0.0, 1.0 - arraySelectivity - nullSelectivity);
						estimatedRows = Max(1.0,
											scalarSelectivity +
											arraySelectivity *
											(double) DistinctUnwindDefaultRows);
					}
				}
			}
		}

		req->rows = estimatedRows;
		PG_RETURN_POINTER(req);
	}

	/*
	 * The distinct-exists filter (bson_dollar_distinct_exists) shares this
	 * support function. Delegate its index-condition, selectivity and cost
	 * requests to the index support layer, which lowers it to a
	 * "path >= MinKey" comparison for index pushdown.
	 */
	PG_RETURN_POINTER(HandleDistinctExistsSupportRequest(supportRequest));
}


/*
 * Implements the unwind function for lookup. Walks the (bson_array_agg) result document for the given
 * path, and for every element adds it to the tuplestore.
 * e.g. { "result": [ { "_id": 1}, { "_id": 2 } ]}
 * returns
 * { "_id": 1}, { "_id": 2 }
 */
Datum
bson_lookup_unwind(PG_FUNCTION_ARGS)
{
	TupleDesc descriptor;
	Tuplestorestate *tupleStore = SetupBsonTuplestore(fcinfo, &descriptor);
	pgbson *document = PG_GETARG_PGBSON(0);
	char *path = text_to_cstring(PG_GETARG_TEXT_P(1));

	bson_iter_t documentIterator;
	if (PgbsonInitIteratorAtPath(document, path, &documentIterator))
	{
		bson_iter_t arrayIter;
		if (!BSON_ITER_HOLDS_ARRAY(&documentIterator) ||
			!bson_iter_recurse(&documentIterator, &arrayIter))
		{
			ereport(ERROR, (errmsg("Lookup unwind expecting field to contain an array")));
		}

		while (bson_iter_next(&arrayIter))
		{
			if (!BSON_ITER_HOLDS_DOCUMENT(&arrayIter))
			{
				ereport(ERROR, (errmsg(
									"Lookup unwind array expecting entries to contain documents")));
			}

			Datum values[1];
			bool nulls[1];

			values[0] = PointerGetDatum(PgbsonInitFromDocumentBsonValue(bson_iter_value(
																			&arrayIter)));
			nulls[0] = false;
			tuplestore_putvalues(tupleStore, descriptor, values, nulls);
		}
	}

	PG_RETURN_VOID();
}


/* --------------------------------------------------------- */
/* Private helper methods */
/* --------------------------------------------------------- */

/*
 * BsonUnwindArray is the internal implementation of $unwind as a set returning function
 *      path -> The path to be unwound
 *      indexFieldName -> optional string to add the index in the output document
 *      preserveNullAndEmpty -> whether to keep null and empty unwind values
 *
 *  PG_FUNCTION_ARGS contains the document
 */
static Datum
BsonUnwindArray(PG_FUNCTION_ARGS, Tuplestorestate *tupleStore, TupleDesc *tupleDescriptor,
				char *path, char *indexFieldName, bool
				preserveNullAndEmpty)
{
	pgbson *document = PG_GETARG_PGBSON_PACKED(0);

	/* Strip the $ prefix from the path */
	if (strlen(path) <= 1)
	{
		ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg(
							"$unwind path should have at least two characters")));
	}

	if (path[0] != '$')
	{
		ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg(
							"$unwind path must be prefixed by $")));
	}
	path = path + 1;

	/* Start the iterator at the provided path */
	bson_iter_t documentIterator;
	if (!PgbsonInitIteratorAtPath(document, path, &documentIterator))
	{
		/* No field was found, return no results on this document */
		if (preserveNullAndEmpty)
		{
			/* undefined elements are preserved */
			bson_value_t element;
			element.value_type = BSON_TYPE_EOD;
			Datum values[1];
			bool isNull = false;

			values[0] = PointerGetDatum(BsonUnwindElement(document,
														  path,
														  indexFieldName,
														  -1,
														  &element));
			tuplestore_putvalues(tupleStore, *tupleDescriptor, values, &isNull);
		}

		PG_FREE_IF_COPY(document, 0);
		PG_RETURN_VOID();
	}

	if (!BSON_ITER_HOLDS_ARRAY(&documentIterator))
	{
		if (!BSON_ITER_HOLDS_NULL(&documentIterator))
		{
			/* Single non-null elements are always preserved */
			Datum values[1];
			bool nulls[1];

			if (indexFieldName == NULL)
			{
				/* This is just the source doc */
				values[0] = PG_GETARG_DATUM(0);
			}
			else
			{
				const bson_value_t *element = bson_iter_value(&documentIterator);
				values[0] = PointerGetDatum(BsonUnwindElement(document,
															  path,
															  indexFieldName,
															  -1,
															  element));
			}

			nulls[0] = false;

			tuplestore_putvalues(tupleStore, *tupleDescriptor, values, nulls);
		}
		else if (preserveNullAndEmpty)
		{
			/* Nulls are persisted if the document is preserved in the output */
			bson_value_t element;
			element.value_type = BSON_TYPE_NULL;
			Datum values[1];
			bool isNull = false;

			values[0] = PointerGetDatum(BsonUnwindElement(document,
														  path,
														  indexFieldName,
														  -1,
														  &element));
			tuplestore_putvalues(tupleStore, *tupleDescriptor, values, &isNull);
		}

		PG_FREE_IF_COPY(document, 0);
		PG_RETURN_VOID();
	}

	bson_iter_t childIterator;

	/* If the target path is an array, recurse into it */
	bson_iter_recurse(&documentIterator, &childIterator);

	long index = 0;
	while (bson_iter_next(&childIterator))
	{
		/* Project normal array elements and single non-null elements */
		const bson_value_t *element = bson_iter_value(&childIterator);

		pgbson *result = BsonUnwindElement(document, path, indexFieldName, index,
										   element);

		Datum values[1];
		bool nulls[1];

		values[0] = PointerGetDatum(result);
		nulls[0] = false;
		tuplestore_putvalues(tupleStore, *tupleDescriptor, values, nulls);

		index++;
	}

	if (index == 0 && preserveNullAndEmpty)
	{
		Datum values[1];
		bool isNull = false;

		/* Empty arrays are removed if the document is preserved in the output */
		values[0] = PointerGetDatum(BsonUnwindEmptyArray(
										document, path,
										indexFieldName));
		tuplestore_putvalues(tupleStore, *tupleDescriptor, values, &isNull);
	}

	PG_FREE_IF_COPY(document, 0);
	PG_RETURN_VOID();
}


/*
 * BsonUnwindElement produces the output document when element
 * at the unwind target
 *    document -> source document
 *    path -> path being unwound
 *    indexFieldName -> optional name for the index field to be added
 *    element -> the value found at the unwind target
 */
static pgbson *
BsonUnwindElement(pgbson *document, char *path, char *indexFieldName, long index, const
				  bson_value_t *element)
{
	/*
	 *  Document:   {  "a" :  [ 1,  [1,2], { "c": "value"}, "x"] }
	 *  Unwind Spec: { "$unwind" : "a" }
	 *
	 *  Expected Result: {  "a" :  1}
	 *                   {  "a" :  [1,2] }
	 *                   {  "a" :  { "c": "value"} }
	 *                   {  "a" :  "x" }
	 *
	 *  This is achieved by performing AddFields() 4 times on the original source document
	 *  using the following 4 AddFields spec. Basically, we replace the array path with the
	 *  elements of the array.
	 *      1. {"addFields" : { "a" : 1}}
	 *      2. {"addFields" : { "a" : [1,2] }}
	 *      3. {"addFields" : { "a" : { "c": "value"} }}
	 *      4. {"addFields" : { "a" : "x" }}
	 *
	 *  We also, instruct the addFields spec to treat the elemnts to be the final value without
	 *  any need for recursive expression evaluation.
	 *
	 *  Note: All other fields in the document (not shown here) gets projected as it is.
	 *
	 */

	BsonIntermediatePathNode *root = MakeRootNode();

	/* unwound elements come from arrays in documents which will already be evaluated in a previous stage or directly from a collection, */
	/* so we can safely treat the values as constants and no need to pay the cost to parse them as expressions. */
	bool treatLeafDataAsConstant = true;
	ParseAggregationExpressionContext parseContext = { 0 };

	/* Create the node for unwound element */
	if (element->value_type != BSON_TYPE_EOD)
	{
		StringView pathView = CreateStringViewFromString(path);
		TraverseDottedPathAndAddLeafFieldNode(&pathView,
											  element,
											  root,
											  BsonDefaultCreateLeafNode,
											  treatLeafDataAsConstant,
											  &parseContext);
	}

	/* Create the node for the new indexField name */
	if (indexFieldName != NULL)
	{
		bson_value_t indexValue;
		memset(&indexValue, 0, sizeof(bson_value_t));
		if (index > -1)
		{
			indexValue.value_type = BSON_TYPE_INT64;
			indexValue.value.v_int64 = index;
		}
		else
		{
			indexValue.value_type = BSON_TYPE_NULL;
		}

		StringView indexFieldView = CreateStringViewFromString(indexFieldName);
		TraverseDottedPathAndAddLeafFieldNode(&indexFieldView,
											  &indexValue,
											  root,
											  BsonDefaultCreateLeafNode,
											  treatLeafDataAsConstant,
											  &parseContext);
	}

	pgbson_writer writer;
	bson_iter_t documentIterator;
	PgbsonWriterInit(&writer);
	PgbsonInitIterator(document, &documentIterator);
	bool projectNonMatchingField = true;
	ProjectDocumentState projectDocState = {
		.isPositionalAlreadyEvaluated = false,
		.parentDocument = document,
		.topLevelPendingProjectionState = NULL,
		.skipIntermediateArrayFields = false,
	};

	bool isInNestedArray = false;
	TraverseObjectAndAppendToWriter(&documentIterator, root, &writer,
									projectNonMatchingField,
									&projectDocState, isInNestedArray);
	return PgbsonWriterGetPgbson(&writer);
}


/*
 * BsonUnwindEmptyArray produces the output document when an empty array is found
 * at the unwind target
 *    document -> source document
 *    path -> path being unwound
 *    indexFieldName -> optional name for the index field to be added
 */
static pgbson *
BsonUnwindEmptyArray(pgbson *document, char *path, char *indexFieldName)
{
	pgbson_writer projectSpecWriter;
	PgbsonWriterInit(&projectSpecWriter);

	bool value = false;
	PgbsonWriterAppendBool(&projectSpecWriter, path, strlen(path),
						   value);

	if (indexFieldName != NULL)
	{
		/* Single elements have null index */
		PgbsonWriterAppendNull(&projectSpecWriter, indexFieldName, strlen(
								   indexFieldName));
	}

	bson_iter_t projectSpec;
	PgbsonWriterGetIterator(&projectSpecWriter, &projectSpec);

	bool forceProjectId = true;
	bool allowInclusionExclusion = true;

	pgbson *variableSpec = NULL;
	const BsonProjectionQueryState *projectionState =
		GetProjectionStateForBsonProject(&projectSpec,
										 forceProjectId, allowInclusionExclusion,
										 variableSpec);
	return ProjectDocumentWithState(document, projectionState);
}


/*
 * Whether or not to process intermediate arrays encountered in traversal.
 * Always true for distinct.
 */
static bool
DistinctContinueProcessIntermediateArray(void *state, const bson_value_t *value,
										 bool isArrayIndexSearch)
{
	return true;
}


/*
 * Handles non-existent paths and type mismatches - ignored for Distinct.
 */
static void
DistinctSetTraverseResult(void *state, TraverseBsonResult result)
{ }


/*
 * Adds the current value to the tuple store inside the DistinctTraverseState.
 */
inline static void
AddToDistinctTupleStore(const bson_value_t *bsonValue,
						DistinctTraverseState *traverseState)
{
	Datum values[1];
	bool nulls[1];

	values[0] = PointerGetDatum(BsonValueToDocumentPgbson(bsonValue));
	nulls[0] = false;
	tuplestore_putvalues(traverseState->tupleStore, traverseState->tupleDescriptor,
						 values, nulls);
}


/*
 * Adds the current element of the array field to the tuple store.
 */
static bool
DistinctVisitArrayField(pgbsonelement *element, const StringView *traversePath, int
						arrayIndex, void *state)
{
	DistinctTraverseState *traverseState = (DistinctTraverseState *) state;
	AddToDistinctTupleStore(&element->bsonValue, traverseState);

	/* Continue traversing */
	return true;
}


/*
 * Adds the current top level field to the tuple store if and only if it's not an array.
 * Array fields are added by DistinctVisitArrayField instead.
 */
static bool
DistinctVisitTopLevelField(pgbsonelement *element, const StringView *traversePath,
						   void *state)
{
	if (element->bsonValue.value_type == BSON_TYPE_ARRAY)
	{
		/* Continue traversing */
		return true;
	}

	DistinctTraverseState *traverseState = (DistinctTraverseState *) state;
	AddToDistinctTupleStore(&element->bsonValue, traverseState);

	/* Continue traversing */
	return true;
}
