/* Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 */

#ifndef DOCUMENTDB_WRITABLE_CONTRIB_COLLECTION_H
#define DOCUMENTDB_WRITABLE_CONTRIB_COLLECTION_H

#include "metadata/collection.h"
#include "utils/string_view.h"

extern bool EnableWritableContribCollections;

/* Registration is limited to shared preload and exact admin.system.contrib.* names. */
void RegisterWritableContribCollection(const MongoCollectionName *name);
bool IsRegisteredWritableContribCollection(const StringView *databaseName,
										   const StringView *collectionName);

#endif
