/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/metadata/replica_set_fields.c
 *
 * Implementation of replica set metadata functions.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <nodes/parsenodes.h>

#include "api_hooks.h"

/* Function exports for SQL callable functions */
PG_FUNCTION_INFO_V1(get_replica_set_fields);

/*
 * get_replica_set_fields
 * 
 * PostgreSQL callable function that returns replica set fields as a single BSON document.
 * This function acts as a PostgreSQL interface that delegates to the hook system.
 */
Datum
get_replica_set_fields(PG_FUNCTION_ARGS)
{
	Datum result = GetReplicaSetFields();
	
	if (result == (Datum) 0)
	{
		PG_RETURN_NULL();
	}
	
	return result;
}
