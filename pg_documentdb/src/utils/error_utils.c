/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/utils/error_utils.c
 *
 * Utilities for throwing the DocumentDB errors from SQL functions
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <fmgr.h>
#include <utils/builtins.h>
#include "commands/commands_common.h"
#include "utils/documentdb_errors.h"
#include "utils/version_utils.h"
#include "utils/error_utils.h"
#include "utils/documentdb_pg_compatibility.h"

format_log_hook unredacted_log_emit_hook = NULL;

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

PG_FUNCTION_INFO_V1(command_convert_mongo_error_to_postgres);
PG_FUNCTION_INFO_V1(command_throw_mongo_error);
PG_FUNCTION_INFO_V1(test_try_get_wire_error_code);

/*
 * test_try_get_wire_error_code is a test-only function that returns the wire
 * error code for a SQLSTATE, or NULL when the response requires translation.
 */
Datum
test_try_get_wire_error_code(PG_FUNCTION_ARGS)
{
	char *sqlState = text_to_cstring(PG_GETARG_TEXT_PP(0));
	if (strlen(sqlState) != 5)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("SQLSTATE must contain five characters")));
	}

	int errorCode = MAKE_SQLSTATE(sqlState[0], sqlState[1], sqlState[2], sqlState[3],
								  sqlState[4]);
	int wireErrorCode;
	if (!TryGetWireErrorCode(errorCode, &wireErrorCode))
	{
		PG_RETURN_NULL();
	}

	PG_RETURN_INT32(wireErrorCode);
}


/*
 * This method is useful in cases where the error codes can't be thrown from SQL directly
 * Postgres imposes a restriction on error codes to not use lower case letters or special
 * characters and only allows usage of [A-Z0-9] characters but today the range of DocumentDB error
 * codes consider all the combination and if such error code is thrown directly from SQL,
 * then it results in `unrecognized error`.
 *
 * e.g.: f100Y (Namespace not sharded error with code 118)
 *
 * This function is useful in those scenarios and its UDF should be called as:
 *
 * PERFORM ApiInternalSchema.throw_mongo_error(118, 'Collection x.y is not sharded.');
 *
 * [Deprecated] : starting 1.22
 * [Update] : starting 1.22, this function is deprecated and should not be used.
 * and return the deprecated error.
 */
pg_noreturn Datum
command_throw_mongo_error(PG_FUNCTION_ARGS)
{
	ereport(ERROR, (errcode(ERRCODE_WARNING_DEPRECATED_FEATURE),
					errmsg("command_throw_mongo_error function is deprecated now")));
}


/*
 * This method prints the 5 character Postgres error code for the given mongo error code.
 *
 * [Deprecated] : starting 1.22
 * Update: now the 5 character for an error can be easily found from documentdb_errors.h
 */
Datum
command_convert_mongo_error_to_postgres(PG_FUNCTION_ARGS)
{
	ereport(ERROR, (errcode(ERRCODE_WARNING_DEPRECATED_FEATURE),
					errmsg("command_convert_mongo_error_to_postgres "
						   "function is deprecated now")));
}
