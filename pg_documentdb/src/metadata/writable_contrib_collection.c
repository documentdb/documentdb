/* Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 */

#include <postgres.h>
#include <miscadmin.h>

#include "metadata/writable_contrib_collection.h"

#define MAX_WRITABLE_CONTRIB_COLLECTIONS 10

static const StringView ContribPrefix = {
	.string = "system.contrib.",
	.length = 15
};

static MongoCollectionName WritableContribCollections[MAX_WRITABLE_CONTRIB_COLLECTIONS];
static int WritableContribCollectionCount = 0;


void
RegisterWritableContribCollection(const MongoCollectionName *name)
{
	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"Writable contrib collections can only be registered during shared_preload_libraries")));
	}

	if (name == NULL ||
		memchr(name->databaseName, '\0', sizeof(name->databaseName)) == NULL ||
		memchr(name->collectionName, '\0', sizeof(name->collectionName)) == NULL)
	{
		ereport(ERROR, (errmsg("Invalid writable contrib collection name")));
	}

	StringView databaseView = CreateStringViewFromString(name->databaseName);
	StringView collectionView = CreateStringViewFromString(name->collectionName);
	if (!StringViewEqualsCString(&databaseView, "admin") ||
		!StringViewStartsWithStringView(&collectionView, &ContribPrefix) ||
		collectionView.length == ContribPrefix.length)
	{
		ereport(ERROR, (errmsg(
							"Writable contrib collections must use the admin database and a nonempty system.contrib.* collection name")));
	}

	if (IsRegisteredWritableContribCollection(&databaseView, &collectionView))
	{
		ereport(ERROR, (errmsg(
							"Writable contrib collection \"%s.%s\" is already registered",
							name->databaseName, name->collectionName)));
	}

	if (WritableContribCollectionCount >= MAX_WRITABLE_CONTRIB_COLLECTIONS)
	{
		ereport(ERROR, (errmsg(
							"Cannot register more than %d writable contrib collections",
							MAX_WRITABLE_CONTRIB_COLLECTIONS)));
	}

	WritableContribCollections[WritableContribCollectionCount++] = *name;
}


bool
IsRegisteredWritableContribCollection(const StringView *databaseName,
									  const StringView *collectionName)
{
	if (!StringViewEqualsCString(databaseName, "admin"))
	{
		return false;
	}

	for (int i = 0; i < WritableContribCollectionCount; i++)
	{
		if (StringViewEqualsCString(collectionName,
									WritableContribCollections[i].collectionName))
		{
			return true;
		}
	}

	return false;
}
