/* Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 */

#ifndef DOCUMENTDB_EXTENSIBLE_METADATA_VIEW_H
#define DOCUMENTDB_EXTENSIBLE_METADATA_VIEW_H

#include <nodes/parsenodes.h>

#include "metadata/collection.h"
#include "utils/string_view.h"

typedef struct AggregationPipelineBuildContext AggregationPipelineBuildContext;

/* Callbacks return a SELECT query with a BSON column named document, or NULL if unsupported. */
typedef Query *(*ExtensibleMetadataViewFunction)(
	AggregationPipelineBuildContext *context);

typedef struct ExtensibleMetadataViewDefinition
{
	MongoCollectionName name;
	ExtensibleMetadataViewFunction function;
	bool requiresPersistentCursor;
} ExtensibleMetadataViewDefinition;

/* Registration is limited to admin.system.* namespaces with a nonempty suffix. */
void RegisterExtensibleMetadataView(const ExtensibleMetadataViewDefinition *definition);
bool IsRegisteredExtensibleMetadataView(const StringView *databaseName,
										const StringView *collectionName);
const ExtensibleMetadataViewDefinition * FindBuiltinMetadataView(const
																 StringView *databaseName,
																 const StringView *
																 collectionName);
Query * GenerateExtensibleMetadataViewQuery(const StringView *databaseName,
											AggregationPipelineBuildContext *context);

#endif
