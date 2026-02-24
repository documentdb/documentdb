/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/bson_init.c
 *
 * Initialization of the shared library initialization for bson.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <miscadmin.h>
#include <utils/guc.h>
#include <bson.h>

#include "bson_init.h"


/* --------------------------------------------------------- */
/* GUCs and default values */
/* --------------------------------------------------------- */

/* GUC controlling whether or not we use the pretty printed version json representation for bson */
#define DEFAULT_BSON_TEXT_USE_JSON_REPRESENTATION false
bool BsonTextUseJsonRepresentation = DEFAULT_BSON_TEXT_USE_JSON_REPRESENTATION;

/* GUC deciding whether collation is support */
#define DEFAULT_ENABLE_COLLATION false
bool EnableCollation = DEFAULT_ENABLE_COLLATION;

#define DEFAULT_SKIP_BSON_ARRAY_TRAVERSE_OPTIMIZATION false
bool SkipBsonArrayTraverseOptimization = DEFAULT_SKIP_BSON_ARRAY_TRAVERSE_OPTIMIZATION;

/*
 * Initializes core configurations pertaining to documentdb core.
 */
void
InitDocumentDBCoreConfigurations(const char *prefix)
{
	DefineCustomBoolVariable(
		psprintf("%s.bsonUseEJson", prefix),
		gettext_noop(
			"Determines whether the bson text is printed as extended Json. Used mainly for test."),
		NULL, &BsonTextUseJsonRepresentation, DEFAULT_BSON_TEXT_USE_JSON_REPRESENTATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enableCollation", prefix),
		gettext_noop(
			"Determines whether collation is supported."),
		NULL, &EnableCollation,
		DEFAULT_ENABLE_COLLATION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.skipBsonArrayTraverseOptimization", prefix),
		gettext_noop(
			"Determines whether to skip the optimization for traversing arrays in bson documents."),
		NULL, &SkipBsonArrayTraverseOptimization,
		DEFAULT_SKIP_BSON_ARRAY_TRAVERSE_OPTIMIZATION,
		PGC_USERSET, 0, NULL, NULL, NULL);
}
