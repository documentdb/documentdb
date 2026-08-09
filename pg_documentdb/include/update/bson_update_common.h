/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/bson/bson_update_common.h
 *
 * Private and common declarations of functions for handling bson updates
 * Shared across update implementations.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_UPDATE_COMMON_H
#define BSON_UPDATE_COMMON_H

#include <utils/hsearch.h>
#include <storage/itemptr.h>

#include "io/bson_core.h"
#include "utils/documentdb_errors.h"
#include "utils/feature_counter.h"
#include "aggregation/bson_positional_query.h"

struct AggregationPipelineUpdateState;
struct BsonIntermediatePathNode;
typedef struct BsonUpdateTracker BsonUpdateTracker;

struct UpdateOperatorWriter;
struct UpdateSetValueState;
struct CurrentDocumentState;
struct BsonIntermediatePathNode;

#define BsonUpdateSourceIsValid(source) (source != NULL && \
										 source->tableOid != InvalidOid && \
										 ItemPointerIsValid(source->ctid))

/* Any positional metadata available during building the update spec for
 * target documents */
typedef struct PositionalUpdateSpec
{
	/* The input query spec - used when evaluating $ positional operators */
	const bson_value_t *querySpec;

	/* hashmap of char* to bson_value_t* */
	HTAB *arrayFilters;

	/* The processed positional query data from the original querySpec */
	BsonPositionalQueryData *processedQuerySpec;
} PositionalUpdateSpec;


/* The type of positional operator a node has */
typedef enum PositionalType
{
	/* It is not a positional update */
	PositionalType_None = 0,

	/* Matches the specified value $ path */
	PositionalType_QueryFilter,

	/* Corresponds to the $[identifier] path */
	PositionalType_ArrayFilter,

	/* Matches the $[] path */
	PositionalType_All
} PositionalType;


/* Actual update type based on the operators */
typedef enum CommandUpdateType
{
	CommandUpdateType_Invalid = 0,
	CommandUpdateType_Update,
	CommandUpdateType_Replacement
} CommandUpdateType;


typedef struct BsonUpdateSource
{
	/* Relation on which the update is being performed */
	Oid tableOid;

	/* Original item pointer before the update */
	ItemPointer ctid;
} BsonUpdateSource;


/* WriteUpdatedValuesFunc function takes an existing value in the current document,
 * applies the update mutation pertinent to that operator, and writes the updated
 * value to the writer
 */
typedef void (*WriteUpdatedValuesFunc)(const bson_value_t *existingValue,
									   struct UpdateOperatorWriter *writer,
									   const bson_value_t *updateValue,
									   void *updateNodeContext,
									   const struct UpdateSetValueState *setValueState,
									   const struct CurrentDocumentState *state);

/* OPERATOR DEFINITIONS
 * These types specify how to build operators and define all supported
 * update operators.
 */

/*
 * An optional function to retrieve operator specific state given a specific
 * updateSpec value.
 */
typedef void *(*UpdateOperatorGetFuncState)(const bson_value_t *tree);

/*
 * HandleUpdateOperatorUpdateBsonTree takes a specific update operator document
 * and constructs the update tree. The function is also given a pointer to the
 * function that will apply the update on the target document - this can be cached
 * into the tree so we don't need to look up this data again.
 */
typedef void (*HandleUpdateOperatorUpdateBsonTree)(struct BsonIntermediatePathNode *tree,
												   bson_iter_t *updateSpec,
												   WriteUpdatedValuesFunc updateFunc,
												   UpdateOperatorGetFuncState stateFunc,
												   const PositionalUpdateSpec *
												   positionalSpec,
												   bool isUpsert);

/* The declaration of the Mongo update operators */
typedef struct MongoUpdateOperatorSpec
{
	/* The name of the update operator e.g. $set */
	const char *operatorName;

	/* Function that handles parsing the update Spec for the operator
	 * and updates the tree with the set of paths being updated
	 */
	HandleUpdateOperatorUpdateBsonTree updateTreeFunc;

	/* Function that writes the updated values into the target writer
	 * for a given document
	 */
	WriteUpdatedValuesFunc updateWriterFunc;

	/* An optional function for retreiving state pertinent to the
	 * update node value */
	UpdateOperatorGetFuncState updateWriterGetState;

	/*
	 * Feature identifier of this operator for feature usage tracking
	 */
	FeatureType featureId;
} MongoUpdateOperatorSpec;

/* aggregation */

struct AggregationPipelineUpdateState * GetAggregationPipelineUpdateState(const
																		  bson_value_t *
																		  updateSpec,
																		  const
																		  bson_value_t *
																		  variableSpec,
																		  bool *
																		  isReplaceStagePresent);

pgbson * ProcessAggregationPipelineUpdate(pgbson *sourceDoc,
										  const struct AggregationPipelineUpdateState *
										  updateState,
										  bool isUpsert,
										  bool *isReplacement);


/* Update workflows */
void RegisterUpdateOperatorExtension(const MongoUpdateOperatorSpec *extensibleDefinition);

const struct BsonIntermediatePathNode * GetOperatorUpdateState(const
															   bson_value_t *updateSpec,
															   const bson_value_t *
															   querySpec,
															   const bson_value_t *
															   arrayFilters,
															   bool isUpsert);
pgbson * ProcessUpdateOperatorWithState(pgbson *sourceDoc,
										const struct BsonIntermediatePathNode *
										updateState,
										bool isUpsert,
										BsonUpdateTracker *updateDescription);


/*
 * Throws an error that the _id has been detected as changed in the process of updating the document.
 * Call it when UpdateType is OperatorUpdate and _id has changed.
 */
pg_noreturn inline static void
ThrowIdPathModifiedErrorForOperatorUpdate(void)
{
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_IMMUTABLEFIELD),
					errmsg(
						"Updating the path '_id' is not allowed because it would change the immutable field '_id'")));
}


/*
 * Throws an error that the path in the projection tree has a prior update requested that would conflict
 * with the update requested.
 */
pg_noreturn inline static void
ThrowPathConflictError(const char *requestedPath, const char *existingPath)
{
	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_CONFLICTINGUPDATEOPERATORS),
					errmsg(
						"Modifying the path '%s' will result in a conflict occurring at '%s'",
						requestedPath, existingPath)));
}


#endif
