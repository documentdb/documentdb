/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/pg_documentdb_core.c
 *
 * Initialization of the shared library.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <utils/guc.h>

#include "bson_init.h"

PG_MODULE_MAGIC;

void _PG_init(void);
void _PG_fini(void);

bool SkipDocumentDBCoreLoad = false;

/*
 * DocumentDBCore_InstallBsonMemVTablesLocal sets the libbson memory vtable
 * for pg_documentdb_core.so's own statically-linked copy of libbson.
 *
 * This MUST be a non-inline exported function so that service.so can
 * call it to set this .so's vtable (since service.c is the real _PG_init
 * entry point and pg_documentdb's _PG_init is skipped via SkipDocumentDBLoad).
 */
void
DocumentDBCore_InstallBsonMemVTablesLocal(void)
{
	InstallBsonMemVTablesLocal();
}


/*
 * _PG_init gets called when the extension is loaded.
 */
void
_PG_init(void)
{
	if (SkipDocumentDBCoreLoad)
	{
		return;
	}

	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"pg_documentdb_core can only be loaded via shared_preload_libraries. "
							"Add pg_documentdb_core to shared_preload_libraries configuration "
							"variable in postgresql.conf.")));
	}

	DocumentDBCore_InstallBsonMemVTablesLocal();

	InitDocumentDBCoreConfigurations("documentdb_core");

	MarkGUCPrefixReserved("documentdb_core");
	ereport(LOG, (errmsg("Initialized documentdb_core extension")));
}


/*
 * _PG_fini is called before the extension is reloaded.
 */
void
_PG_fini(void)
{ }
