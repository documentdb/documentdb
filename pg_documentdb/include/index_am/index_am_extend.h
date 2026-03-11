/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/index_am/index_am_extend.h
 *
 * Common declarations for extended index access method utilities.
 *
 *-------------------------------------------------------------------------
 */

#ifndef INDEX_AM_EXTEND_H
#define INDEX_AM_EXTEND_H

#include <postgres.h>
#include <utils/rel.h>
#include "index_am/index_am_exports.h"
#include "commands/create_indexes.h"
#include "opclass/bson_index_support.h"

#define EXTENDED_INDEX_SPEC_FLAG_FIELD_NAME "isExtendedIndex"
#define EXTENDED_INDEX_SPEC_FLAG_FIELD_NAME_LENGTH 15

extern bool EnableExtendedIndexes;

/*
 * Options parsed from the index creation command for an extended index access method.
 * AmIndexCreationOptions is passed to various extensibility functions to create the index.
 */
typedef struct AmIndexCreationOptions
{
	/* Name of the index */
	char *indexName;

	/* The specific options parsed by the index access method */
	void *options;
} AmIndexCreationOptions;

typedef char *(*GenerateIndexCreationColumnsFunc)(AmIndexCreationOptions *amIndexOptions);

typedef char *(*GenerateIndexCreationWithOptionsFunc)(
	AmIndexCreationOptions *amIndexOptions);

typedef char *(*GenerateIndexCreationPartialPredicatesFunc)(
	AmIndexCreationOptions *amIndexOptions);

typedef char *(*GenerateIndexCreationCmdFunc)(uint64 collectionId,
											  int indexId,
											  bool concurrently,
											  bool isTempCollection,
											  IndexDef *indexDef);

typedef void (*AppendIndexAMOptionToIndexSpecFunc)(pgbson_writer *indexOptionsWriter,
												   AmIndexCreationOptions *amIndexOptions);

typedef bool (*IsExtendedAMIndexSpecFunc)(const pgbson *indexSpecDocument);

typedef CreateIndexesArg (*MakeCreationArgFromSpecFunc)(const char *databaseName,
														const char *collectionName,
														const pgbson *indexSpecDocument,
														bool
														buildAsUniqueForPrepareUnique);

typedef struct CreateIndexesSupportFuncs
{
	/* Set the creation command name for this index AM */
	const char *create_index_cmd_name;

	/* Function to generate the index creation columns for sql command */
	GenerateIndexCreationColumnsFunc generateIndexCreationColumnsFunc;

	/* Optional Function to generate the index creation options for sql command */
	GenerateIndexCreationWithOptionsFunc generateIndexCreationWithOptionsFunc;

	/* Optional Function to generate the partial index predicates */
	GenerateIndexCreationPartialPredicatesFunc generateIndexCreationPartialPredicatesFunc;

	/* Function to append index options to indexSpec.indexOptions */
	AppendIndexAMOptionToIndexSpecFunc append_index_option_to_index_spec_func;

	/* Function to check whether the index spec is of this extended AM index type */
	IsExtendedAMIndexSpecFunc is_extended_am_index_spec_func;
} CreateIndexesSupportFuncs;

bool IsExtendedIndexAm(Oid indexAm);
bool IsExtendedIndexAmByName(const char *amName);

#endif
