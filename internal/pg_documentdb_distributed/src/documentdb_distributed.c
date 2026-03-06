/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/documentdb_distributed.c
 *
 * Initialization of the shared library.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <bson.h>
#include <utils/guc.h>
#include <access/xact.h>
#include <utils/version_utils.h>
#include "bson_init.h"
#include "distributed_hooks.h"
#include "documentdb_distributed_init.h"

extern bool SkipDocumentDBLoad;

PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1(test_bson_distributed_mem_vtable_uses_palloc);

void _PG_init(void);
void _PG_fini(void);

/*
 * DocumentDBDistributed_InstallBsonMemVTablesLocal sets the libbson memory vtable
 * for pg_documentdb_distributed.so's own statically-linked copy of libbson.
 *
 * This MUST be a non-inline exported function so that service shared object can
 * call it to set this .so's vtable (since service code is the real _PG_init
 * entry point and pg_documentdb's _PG_init is skipped via SkipDocumentDBLoad).
 */
void
DocumentDBDistributed_InstallBsonMemVTablesLocal(void)
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
							"pg_documentdb_distributed can only be loaded via shared_preload_libraries. "
							"Add pg_documentdb_distributed to shared_preload_libraries configuration "
							"variable in postgresql.conf in coordinator and workers. "
							"Note that pg_documentdb_distributed should be placed right after citus and pg_documentdb.")));
	}

	DocumentDBDistributed_InstallBsonMemVTablesLocal();

	InitializeDocumentDBDistributedHooks();
	InitDocumentDBDistributedConfigurations("documentdb_distributed");
	MarkGUCPrefixReserved("documentdb_distributed");
}


/*
 * test_bson_distributed_mem_vtable_uses_palloc verifies that libbson
 * allocations in pg_documentdb_distributed.so go through palloc.
 * See BsonMemVTableSelfTest() in bson_init.h for the shared logic.
 */
Datum
test_bson_distributed_mem_vtable_uses_palloc(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(BsonMemVTableSelfTest());
}


/*
 * _PG_fini is called before the extension is reloaded.
 */
void
_PG_fini(void)
{ }
