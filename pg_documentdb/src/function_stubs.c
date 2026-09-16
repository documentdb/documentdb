/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/function_stubs.c
 *
 * Function stubs for renamed/deprecated C functions.
 * When renaming/removing C functions, old extension upgrade scripts will cease to work.
 * In order to maintain compatibility, we add stubs of the renamed/deprecated functions
 * and map from the old to the new functions here.
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <fmgr.h>


PG_FUNCTION_INFO_V1(delete_expired_rows_for_index);
PG_FUNCTION_INFO_V1(bson_min_max_final);
PG_FUNCTION_INFO_V1(bson_max_transition);
PG_FUNCTION_INFO_V1(bson_min_transition);
PG_FUNCTION_INFO_V1(bson_min_combine);
PG_FUNCTION_INFO_V1(bson_max_combine);
PG_FUNCTION_INFO_V1(bson_first_transition_on_sorted);
PG_FUNCTION_INFO_V1(bson_last_transition_on_sorted);
PG_FUNCTION_INFO_V1(bson_first_last_final_on_sorted);

Datum
delete_expired_rows_for_index(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"delete_expired_rows_for_index is deprecated and should not be called."));
}


Datum
bson_min_max_final(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_min_max_final is deprecated and should not be called."));
}


Datum
bson_max_transition(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_max_transition is deprecated and should not be called."));
}


Datum
bson_min_transition(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_min_transition is deprecated and should not be called."));
}


Datum
bson_min_combine(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_min_combine is deprecated and should not be called."));
}


Datum
bson_max_combine(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_max_combine is deprecated and should not be called."));
}


Datum
bson_first_transition_on_sorted(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_first_transition_on_sorted is deprecated and should not be called."));
}


Datum
bson_last_transition_on_sorted(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_last_transition_on_sorted is deprecated and should not be called."));
}


Datum
bson_first_last_final_on_sorted(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"bson_first_last_final_on_sorted is deprecated and should not be called."));
}
