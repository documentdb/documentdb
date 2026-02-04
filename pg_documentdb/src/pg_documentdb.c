/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/pg_documentdb.c
 *
 * Initialization of the shared library for the DocumentDB API.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <utils/guc.h>

#include "bson_init.h"
#include "utils/feature_counter.h"
#include "documentdb_api_init.h"
#include "index_am/roaring_bitmap_adapter.h"

PG_MODULE_MAGIC;

void _PG_init(void);
void _PG_fini(void);
static void UseRBACCompliantSchemas(void);

bool SkipDocumentDBLoad = false;
extern bool EnableRbacCompliantSchemas;
extern char *ApiSchemaName;
extern char *ApiSchemaNameV2;

/*
 * _PG_init gets called when the extension is loaded.
 */
void
_PG_init(void)
{
	if (SkipDocumentDBLoad)
	{
		return;
	}

	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"pg_documentdb can only be loaded via shared_preload_libraries"),
						errdetail_log(
							"Add pg_documentdb to shared_preload_libraries configuration "
							"variable in postgresql.conf. ")));
	}

	InstallBsonMemVTables();

	RegisterRoaringBitmapHooks();
	InitApiConfigurations("documentdb", "documentdb");
	InitializeSharedMemoryHooks();
	MarkGUCPrefixReserved("documentdb");

	InitializeBackgroundWorkerJobAllowedCommands();
	InitializeDocumentDBBackgroundWorker("pg_documentdb", "documentdb", "documentdb");
	RegisterDocumentDBBackgroundWorkerJobs();

	InstallDocumentDBApiPostgresHooks();

	/* Use RBAC compliant schemas based on GUC*/
	if (EnableRbacCompliantSchemas)
	{
		UseRBACCompliantSchemas();
	}

	ereport(LOG, (errmsg("Initialized pg_documentdb extension")));
}


/*
 * UseRBACCompliantSchemas sets up the schema name globals based on feature flags
 */
static void
UseRBACCompliantSchemas(void)
{
	ApiSchemaName = "documentdb_api_v2";
	ApiSchemaNameV2 = "documentdb_api_v2";
}


/*
 * _PG_fini is called before the extension is reloaded.
 */
void
_PG_fini(void)
{
	if (SkipDocumentDBLoad)
	{
		return;
	}

	UninstallDocumentDBApiPostgresHooks();
}
