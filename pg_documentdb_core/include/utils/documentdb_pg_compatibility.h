/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * include/utils/documentdb_pg_compatibility.h
 *
 * Utilities for PostgreSQL compatibility in DocumentDB
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_PG_COMPATIBILITY_H
#define DOCUMENTDB_PG_COMPATIBILITY_H

#if PG_VERSION_NUM >= 160000
#define PgProcAclCheckCompat(functionOid, roleId, mode) \
	object_aclcheck(ProcedureRelationId, functionOid, roleId, mode)
#else
#define PgProcAclCheckCompat(functionOid, roleId, mode) \
	pg_proc_aclcheck(functionOid, roleId, mode)
#endif

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
#define PortalRunCompat(portal, count, isTopLevel, runOnce, dest, altdest, completion) \
	((void) (runOnce), PortalRun(portal, count, isTopLevel, dest, altdest, completion))

#define SortPathKeyStrategy(pathKey) ((pathKey)->pk_cmptype)

#else
#define pg_noreturn pg_attribute_noreturn()
#define char_uint8_compat char

#define ExecutorRun_Compat(queryDesc, scanDirection, numRows, runOnce) \
	ExecutorRun(queryDesc, scanDirection, numRows, runOnce)
#define PortalRunCompat(portal, count, isTopLevel, runOnce, dest, altdest, completion) \
	PortalRun(portal, count, isTopLevel, runOnce, dest, altdest, completion)

#define SortPathKeyStrategy(pathKey) ((pathKey)->pk_strategy)

#endif
#if PG_VERSION_NUM >= 180000
#define AnalyzeDelayPointCompat() \
	vacuum_delay_point(true);
#else
#define AnalyzeDelayPointCompat() \
	vacuum_delay_point();
#endif

#endif
