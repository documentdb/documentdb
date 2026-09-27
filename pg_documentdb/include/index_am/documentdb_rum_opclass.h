/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/index_am/documentdb_rum_opclass.h
 *
 * Rum opclass definitions for the documentdb extension.
 *
 *-------------------------------------------------------------------------
 */

 #ifndef DOCUMENTDB_RUM_OPCLASS_H
 #define DOCUMENTDB_RUM_OPCLASS_H

 #include "postgres.h"
 #include "access/stratnum.h"
 #include "access/sdir.h"


/* CodeSync: pg_documentdb_rum.h */
#define RUM_SEARCH_MODE_ORDERED 4
#define RUM_SEARCH_MODE_ORDERED_REVERSE 5
#define RUM_SEARCH_MODE_DEFAULT_TRUE 7

#define MAX_STRATEGIES (8)
PGDLLIMPORT typedef struct RumConfig
{
	Oid addInfoTypeOid;

	struct
	{
		StrategyNumber strategy;
		ScanDirection direction;
	}       strategyInfo[MAX_STRATEGIES];

	bool skipGenerateEmptyEntries;
	bool compareFunctionHasRecheck;
	bool enableOpClassMetadataStorage;
	bool enableHighKeyOptimization;
}   RumConfig;

 #endif /* DOCUMENTDB_RUM_OPCLASS_H */
