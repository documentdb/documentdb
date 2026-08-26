/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/schema_validation.c
 *
 * Implementation of schema validation.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include "utils/feature_counter.h"
#include "operators/bson_expr_eval.h"
#include "schema_validation/schema_validation.h"
#include "metadata/collection.h"
#include "utils/documentdb_errors.h"
#include "utils/fmgr_utils.h"
#include "utils/version_utils.h"

extern bool EnableSchemaValidation;
PG_FUNCTION_INFO_V1(command_schema_validation_against_update);

/*
 * command_schema_validation_against_update validates source_document/target_document against a schema validator while updating
 * select __API_SCHEMA_INTERNAL__.schema_validation_against_update(validator, target_document, source_document, is_moderate);
 * @param validator: The schema validator BSON document.
 * @param target_document: Updated document.
 * @param source_document: The document to be updated.
 * @param is_moderate: If false, only validate newDocument against the schema validator. if true, validate document if newDocument does not match the schema validator.
 * @return: true if the documents passes schema validation.
 */
Datum
command_schema_validation_against_update(PG_FUNCTION_ARGS)
{
	if (!EnableSchemaValidation)
	{
		PG_RETURN_BOOL(true);
	}

	pgbson *validator = NULL;

	if (IsClusterVersionAtleast(DocDB_V0, 114, 0))
	{
		/* New version: directly get pgbson */
		validator = PG_GETARG_MAYBE_NULL_PGBSON(0);
	}
	else
	{
		/* Old version: convert bytea to pgbson */
		bytea *byteaValidator = PG_GETARG_BYTEA_P(0);
		validator = CastByteaToPgbson(byteaValidator);
	}

	if (validator == NULL)
	{
		PG_RETURN_BOOL(true);
	}


	SchemaValidationCache *cache = NULL;
	int argPosition = 0;
	SetCachedFunctionState(cache, SchemaValidationCache, argPosition,
						   PopulateSchemaValidationCache, validator);

	if (cache == NULL)
	{
		cache = palloc0(sizeof(SchemaValidationCache));
		PopulateSchemaValidationCache(cache, validator);
	}

	if (cache->evalState == NULL)
	{
		PG_RETURN_BOOL(true);
	}

	pgbson *targetDocument = PG_GETARG_PGBSON(1);
	bool isModerate = PG_GETARG_BOOL(3);

	if (!isModerate)
	{
		bson_value_t newDocumentValue = ConvertPgbsonToBsonValue(targetDocument);
		ValidateSchemaOnDocumentInsert(cache->evalState, &newDocumentValue,
									   FAILED_VALIDATION_ERROR_MSG);
	}
	else
	{
		pgbson *sourceDocument = PG_GETARG_MAYBE_NULL_PGBSON(2);
		ValidateSchemaOnDocumentUpdate(ValidationLevel_Moderate, cache->evalState,
									   sourceDocument, targetDocument,
									   FAILED_VALIDATION_ERROR_MSG);
	}

	PG_RETURN_BOOL(true);
}


/*
 * PopulateSchemaValidationCache - Initializes a schema validation cache entry.
 *
 * Designed to be used as the populate callback for SetCachedFunctionState.
 * All allocations are made in CurrentMemoryContext, which the macro sets to
 * fn_mcxt before invoking this function. Do not call directly unless the
 * appropriate memory context is already active.
 *
 * @param cache: The cache entry to populate (already allocated by the caller)
 * @param validator: The schema validator BSON document
 */
void
PopulateSchemaValidationCache(SchemaValidationCache *cache, pgbson *validator)
{
	cache->evalState = PrepareForSchemaValidation(validator, CurrentMemoryContext);
}


/*
 * Prepare for schema validation.
 * If schema validation is not enabled, or the collection does not have a schema
 * validator, return NULL.
 * Otherwise, return the expression evaluation state for the schema validator.
 */
ExprEvalState *
PrepareForSchemaValidation(pgbson *schemaValidationInfo, MemoryContext memoryContext)
{
	bson_value_t validatorBsonValue = ConvertPgbsonToBsonValue(
		schemaValidationInfo);
	if (validatorBsonValue.value_type == BSON_TYPE_NULL ||
		validatorBsonValue.value_type == BSON_TYPE_EOD)
	{
		return NULL;
	}

	bool hasOperatorRestrictions = true;
	return GetExpressionEvalStateForBsonInput(
		&validatorBsonValue,
		memoryContext, hasOperatorRestrictions);
}


/*
 * Validate a document against the schema validator.
 * Only if validation action is set to error, we validate document and throw an error if the document does not match the schema validator.
 * If the validation action is set to warn, we do nothing and would not call this function.
 */
void
ValidateSchemaOnDocumentInsert(ExprEvalState *evalState, const bson_value_t *document,
							   const char *errMsg)
{
	bool matched = EvalBooleanExpressionAgainstBson(evalState, document);
	if (!matched)
	{
		/* todo: additional information about the cause of the failure */
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_DOCUMENTFAILEDVALIDATION),
						errmsg("%s", errMsg)));
	}
}


/*
 * Validate documents with the schema validator during updates.
 * If validationAction is 'warn', skip validation.
 * Validation Levels:
 *  - strict: The target document must fully comply with the schema.
 *  - moderate: The target document need not comply if the source document does not match the schema.
 */
void
ValidateSchemaOnDocumentUpdate(ValidationLevels validationLevel,
							   ExprEvalState *evalState,
							   const pgbson *sourceDocument,
							   const pgbson *targetDocument,
							   const char *errMsg)
{
	bson_value_t targetDocumentValue = ConvertPgbsonToBsonValue(targetDocument);
	bool matched = EvalBooleanExpressionAgainstBson(evalState, &targetDocumentValue);
	if (!matched)
	{
		if (validationLevel == ValidationLevel_Strict)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_DOCUMENTFAILEDVALIDATION),
							errmsg("%s", errMsg)));
		}
		else if (sourceDocument != NULL && validationLevel == ValidationLevel_Moderate)
		{
			bson_value_t sourceDocumentValue = ConvertPgbsonToBsonValue(sourceDocument);
			matched = EvalBooleanExpressionAgainstBson(evalState, &sourceDocumentValue);

			if (matched)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_DOCUMENTFAILEDVALIDATION),
								errmsg("%s", errMsg)));
			}
		}
	}
}
