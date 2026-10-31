/* Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 */

#include <postgres.h>
#include <miscadmin.h>
#include <parser/parse_node.h>

#include "io/bson_core.h"
#include "aggregation/bson_aggregation_pipeline.h"
#include "aggregation/bson_aggregation_pipeline_private.h"
#include "aggregation/extensible_metadata_view.h"
#include "metadata/collection.h"
#include "utils/documentdb_errors.h"

#define MAX_EXTENSIBLE_METADATA_VIEWS 20

extern bool EnableExtensibleMetadataViews;

static const StringView SystemPrefix = {
	.string = "system.",
	.length = 7
};

static ExtensibleMetadataViewDefinition
	ExtensibleMetadataViews[MAX_EXTENSIBLE_METADATA_VIEWS];
static int ExtensibleMetadataViewCount = 0;

static const ExtensibleMetadataViewDefinition * FindExtensibleMetadataView(const
																		   StringView *
																		   databaseName,
																		   const
																		   StringView *
																		   collectionName);

/*
 * Backends inherit an immutable catalog from shared preload initialization.
 */
void
RegisterExtensibleMetadataView(const ExtensibleMetadataViewDefinition *definition)
{
	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"Metadata views can only be registered during shared_preload_libraries")));
	}

	if (definition == NULL ||
		definition->name.databaseName[0] == '\0' ||
		definition->name.collectionName[0] == '\0' ||
		definition->function == NULL)
	{
		ereport(ERROR, (errmsg("Invalid metadata view definition")));
	}

	StringView databaseView = CreateStringViewFromString(definition->name.databaseName);
	StringView collectionView = CreateStringViewFromString(
		definition->name.collectionName);
	if (!StringViewEqualsCString(&databaseView, "admin") ||
		!StringViewStartsWithStringView(&collectionView, &SystemPrefix) ||
		collectionView.length == SystemPrefix.length)
	{
		ereport(ERROR, (errmsg(
							"Extensible metadata views must use the admin database and a nonempty system.* collection name")));
	}

	if (StringViewEqualsCString(&collectionView, "system.dbSentinel"))
	{
		ereport(ERROR, (errmsg(
							"Cannot register reserved collection \"system.dbSentinel\" as a metadata view")));
	}

	if (FindBuiltinMetadataView(&databaseView, &collectionView) != NULL ||
		FindExtensibleMetadataView(&databaseView, &collectionView) != NULL)
	{
		ereport(ERROR, (errmsg("Metadata view \"%s.%s\" is already registered",
							   definition->name.databaseName,
							   definition->name.collectionName)));
	}

	ValidateCollectionNameForUnauthorizedSystemNs(definition->name.collectionName,
												  StringViewGetTextDatum(&databaseView));

	if (ExtensibleMetadataViewCount >= MAX_EXTENSIBLE_METADATA_VIEWS)
	{
		ereport(ERROR, (errmsg("Cannot register more than %d metadata views",
							   MAX_EXTENSIBLE_METADATA_VIEWS)));
	}

	ExtensibleMetadataViews[ExtensibleMetadataViewCount++] = *definition;
}


Query *
GenerateExtensibleMetadataViewQuery(const StringView *databaseName,
									AggregationPipelineBuildContext *context)
{
	const ExtensibleMetadataViewDefinition *view = FindExtensibleMetadataView(
		databaseName, &context->collectionNameView);
	if (view == NULL)
	{
		return NULL;
	}

	context->requiresPersistentCursor = context->requiresPersistentCursor ||
										view->requiresPersistentCursor;
	Query *query = view->function(context);
	if (query == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg("Metadata view \"%s.%s\" is not supported",
							   view->name.databaseName, view->name.collectionName)));
	}

	return query;
}


bool
IsRegisteredExtensibleMetadataView(const StringView *databaseName,
								   const StringView *collectionName)
{
	if (!EnableExtensibleMetadataViews)
	{
		return false;
	}

	return FindExtensibleMetadataView(databaseName, collectionName) != NULL;
}


static const ExtensibleMetadataViewDefinition *
FindExtensibleMetadataView(const StringView *databaseName, const
						   StringView *collectionName)
{
	if (!StringViewEqualsCString(databaseName, "admin"))
	{
		return NULL;
	}

	for (int i = 0; i < ExtensibleMetadataViewCount; i++)
	{
		const ExtensibleMetadataViewDefinition *view = &ExtensibleMetadataViews[i];
		if (StringViewEqualsCString(collectionName, view->name.collectionName))
		{
			return view;
		}
	}

	return NULL;
}
