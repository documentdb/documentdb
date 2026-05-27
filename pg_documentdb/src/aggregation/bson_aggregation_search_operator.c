/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/aggregation/bson_aggregation_search_operator.c
 *
 * Implementation of the functions for handling the search operators
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <parser/parse_node.h>

#include "io/bson_core.h"
#include "commands/parse_error.h"
#include "api_hooks.h"
#include "api_hooks_def.h"
#include "utils/type_cache.h"
#include "aggregation/bson_aggregation_pipeline.h"
#include "aggregation/bson_aggregation_search.h"


/* --------------------------------------------------------- */
/* Data-types */
/* --------------------------------------------------------- */


/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */


static DocumentDBSearchOperatorDef InvalidSearchOperator = {
	.operatorName = NULL,
	.operatorType = INVALID_SEARCH_OPERATOR_TYPE,
	.mutateFunc = NULL,
	.featureType = INVALID_SEARCH_OPERATOR_FEATURE_TYPE,
};

/* Built-in search operators and their definitions. */
static const DocumentDBSearchOperatorDef SearchOperatorsList[] =
{
	{
		.operatorName = "cosmosSearch",
		.operatorType = SEARCH_OPERATOR_COSMOS_SEARCH,
		.mutateFunc = &HandleSearchOperatorCosmos,
		.featureType = FEATURE_SEARCH_OPERATOR_COSMOS_SEARCH,
	},
	{
		.operatorName = "knnBeta", /* deprecated operator, kept for backward compatibility */
		.operatorType = SEARCH_OPERATOR_KNN_BETA,
		.mutateFunc = &HandleSearchOperatorKnnBeta,
		.featureType = FEATURE_SEARCH_OPERATOR_KNN_BETA,
	},
};

static const int NumberOfBuiltinSearchOperators = sizeof(SearchOperatorsList) /
												  sizeof(DocumentDBSearchOperatorDef);


/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

const DocumentDBSearchOperatorDef *
GetSearchOperatorDefByName(const char *key)
{
	/* First check if the operator is one of the built-in operators */
	for (int i = 0; i < NumberOfBuiltinSearchOperators; i++)
	{
		if (strcmp(SearchOperatorsList[i].operatorName, key) == 0)
		{
			return &SearchOperatorsList[i];
		}
	}

	/* Fall back to hook for operators provided by extended index */
	if (extended_search_operator_def_by_name_hook != NULL)
	{
		const DocumentDBSearchOperatorDef *result =
			extended_search_operator_def_by_name_hook(key);
		if (result != NULL)
		{
			return result;
		}
	}

	return &InvalidSearchOperator;
}


/* --------------------------------------------------------- */
/* Private methods */
/* --------------------------------------------------------- */
