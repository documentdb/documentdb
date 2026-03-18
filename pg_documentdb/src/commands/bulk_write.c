/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/bulk_write.c
 *
 * Implements the bulkWrite command that allows performing multiple
 * insert, update, and delete operations across multiple namespaces in a
 * single request.
 *
 * Phase 1: Command surface definition only.
 *          Full implementation is work-in-progress.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"
#include "access/xact.h"

#include "utils/documentdb_errors.h"
#include "utils/feature_counter.h"

PG_FUNCTION_INFO_V1(command_bulkWrite);


/*
 * command_bulkWrite implements the bulkWrite command which allows performing
 * multiple insert, update, and delete operations on multiple namespaces in
 * a single request.
 *
 * This is a Phase 1 stub: the command surface and SQL procedure are defined,
 * but execution is not yet implemented.
 */
Datum
command_bulkWrite(PG_FUNCTION_ARGS)
{
	ReportFeatureUsage(FEATURE_COMMAND_BULKWRITE);

	bool isTopLevel = true;
	if (IsInTransactionBlock(isTopLevel))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg(
							"the bulkwrite procedure cannot be used in transactions.")));
	}

	if (PG_ARGISNULL(0))
	{
		ereport(ERROR, (errmsg("bulkWrite request document must not be NULL")));
	}

	ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
					errmsg("bulkWrite is not yet implemented")));

	PG_RETURN_NULL();
}
