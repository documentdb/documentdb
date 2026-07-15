/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/aggregation/bson_aggregation_search.h
 *
 * Exports for the search operators, parsed options, and related definitions of the $search stage
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_AGGREGATION_SEARCH_H
#define BSON_AGGREGATION_SEARCH_H

#include <nodes/parsenodes.h>

#include "io/bson_core.h"
#include "utils/feature_counter.h"
#include "aggregation/bson_aggregation_pipeline.h"
#include "aggregation/bson_aggregation_pipeline_private.h"

/* metadata field names */
#define SEARCH_METADATA_FIELD_NAME "__cosmos_meta__"
#define SEARCH_METADATA_FIELD_NAME_STR_LEN 15
#define SEARCH_METADATA_SCORE_FIELD_NAME "score"
#define SEARCH_METADATA_SCORE_FIELD_NAME_STR_LEN 5

/* Enums to represent all search operator types for the $search stage. */
typedef enum DocumentDBSearchOperatorType
{
	SEARCH_OPERATOR_COSMOS_SEARCH = 0,
	SEARCH_OPERATOR_KNN_BETA,

	/* Represents any operator provided by extension layers */
	SEARCH_OPERATOR_EXTENDED,

	/* Sentinel for invalid/unrecognized operators */
	MAX_SEARCH_OPERATOR,
} DocumentDBSearchOperatorType;

#define INVALID_SEARCH_OPERATOR_TYPE MAX_SEARCH_OPERATOR
#define INVALID_SEARCH_OPERATOR_FEATURE_TYPE MAX_FEATURE_INDEX

typedef struct DocumentDBSearchOptions DocumentDBSearchOptions;

typedef Query *(*MutateQueryForSearchOperatorFunc)(const bson_value_t *existingValue,
												   DocumentDBSearchOptions *searchOptions,
												   Query *query,
												   AggregationPipelineBuildContext *
												   context);

/*
 * The definition of a search operator, which includes the operator name (e.g. "cosmosSearch"),
 * the operator type, the function that will mutate the query for this operator,
 * and the feature counter type to be used with this operator.
 */
typedef struct DocumentDBSearchOperatorDef
{
	/* operator key (e.g. "cosmosSearch", "knnBeta") */
	const char *operatorName;

	/* operator type enum */
	DocumentDBSearchOperatorType operatorType;

	/* The function that will modify the query for this search operator */
	MutateQueryForSearchOperatorFunc mutateFunc;

	/*
	 * Feature counter type to be used with the search operator
	 */
	FeatureType featureType;
} DocumentDBSearchOperatorDef;

/* Count types for search options */
typedef enum DocumentDBSearchCountType
{
	SEARCH_COUNT_TYPE_LOWER_BOUND = 0,
	SEARCH_COUNT_TYPE_TOTAL,
} DocumentDBSearchCountType;

/* Options for search count */
typedef struct DocumentDBSearchCountOptions
{
	DocumentDBSearchCountType countType;
	int32_t threshold;
} DocumentDBSearchCountOptions;

/*
 * Parsed options for the $search stage
 */
typedef struct DocumentDBSearchOptions
{
	/* The search operator specification document */
	bson_value_t operatorSpecBson;

	/* The search operator definition */
	const DocumentDBSearchOperatorDef *searchOperator;

	/* The name of the index to use for the search */
	const char *indexName;

	/* The number of results to return */
	DocumentDBSearchCountOptions countOptions;

	bool scoreDetailsRequested;

	bool returnStoredSource;
} DocumentDBSearchOptions;


const DocumentDBSearchOperatorDef * GetSearchOperatorDefByName(const char *key);

Query * HandleSearchOperatorCosmos(const bson_value_t *existingValue,
								   DocumentDBSearchOptions *searchOptions,
								   Query *query,
								   AggregationPipelineBuildContext *context);


Query * HandleSearchOperatorKnnBeta(const bson_value_t *existingValue,
									DocumentDBSearchOptions *searchOptions,
									Query *query,
									AggregationPipelineBuildContext *context);

#endif
