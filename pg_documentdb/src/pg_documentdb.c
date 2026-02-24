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
PG_FUNCTION_INFO_V1(test_bson_mem_vtable_uses_palloc);

void _PG_init(void);
void _PG_fini(void);
static void UseRBACCompliantSchemas(void);

bool SkipDocumentDBLoad = false;
extern bool EnableRbacCompliantSchemas;
extern char *ApiSchemaName;
extern char *ApiSchemaNameV2;


/*
 * DocumentDB_InstallBsonMemVTablesLocal sets the libbson memory vtable
 * for pg_documentdb.so's own statically-linked copy of libbson.
 *
 * This MUST be a non-inline exported function so that service shared object can
 * call it to set this .so's vtable (since service code is the real _PG_init
 * entry point and pg_documentdb's _PG_init is skipped via SkipDocumentDBLoad).
 */
void
DocumentDB_InstallBsonMemVTablesLocal(void)
{
	InstallBsonMemVTablesLocal();
}


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

	DocumentDB_InstallBsonMemVTablesLocal();

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
 * test_bson_mem_vtable_uses_palloc verifies that libbson allocations in
 * this .so go through palloc.  The actual test logic lives in
 * BsonMemVTableSelfTest() in bson_init.h so every .so tests its own
 * statically-linked libbson copy without duplicating code.
 */
Datum
test_bson_mem_vtable_uses_palloc(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(BsonMemVTableSelfTest());
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
