/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/utils/documentdb_pg_compatibility.h
 *
 * Utilities for PostgreSQL compatibility in DocumentDB
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_PG_COMPATIBILITY_H
#define DOCUMENTDB_PG_COMPATIBILITY_H

#if PG_VERSION_NUM >= 190000
#define PgPlanQueryCompat(query, queryString, cursorOptions, boundParams) \
	pg_plan_query(query, queryString, cursorOptions, boundParams, NULL)
#else
#define PgPlanQueryCompat(query, queryString, cursorOptions, boundParams) \
	pg_plan_query(query, queryString, cursorOptions, boundParams)
#endif

#if PG_VERSION_NUM >= 180000
#define pg_attribute_noreturn() pg_noreturn
#define char_uint8_compat uint8
#define ExecutorRun_Compat(queryDesc, scanDirection, numRows, runOnce) \
	ExecutorRun(queryDesc, scanDirection, numRows)

#define SortPathKeyStrategy(pathKey) ((pathKey)->pk_cmptype)

#else
#define pg_noreturn pg_attribute_noreturn()
#define char_uint8_compat char

#define ExecutorRun_Compat(queryDesc, scanDirection, numRows, runOnce) \
	ExecutorRun(queryDesc, scanDirection, numRows, runOnce)

#define SortPathKeyStrategy(pathKey) ((pathKey)->pk_strategy)

#endif

#endif
