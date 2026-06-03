/*-------------------------------------------------------------------------
 *
 * rum.h
 *	  Exported definitions for RUM index.
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 2006-2022, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */

#ifndef __DOCUMENTDB_RUM_EXPORTS_H__
#define __DOCUMENTDB_RUM_EXPORTS_H__

/* PG16 defined visibility for PGDLLEXPORT properly, for PG15, we need to set it */
#if PG_VERSION_NUM < 160000
#undef PGDLLEXPORT
#ifdef HAVE_VISIBILITY_ATTRIBUTE
#define PGDLLEXPORT __attribute__((visibility("default")))
#else
#define PGDLLEXPORT
#endif
#endif

/* globals */
typedef uint16 RumVacuumCycleId;

/*
 * searchMode settings for extractQueryFn.
 */
#define GIN_SEARCH_MODE_DEFAULT 0
#define GIN_SEARCH_MODE_INCLUDE_EMPTY 1
#define GIN_SEARCH_MODE_ALL 2
#define GIN_SEARCH_MODE_EVERYTHING 3        /* for internal use only */
#define RUM_SEARCH_MODE_ORDERED 4
#define RUM_SEARCH_MODE_ORDERED_REVERSE 5


/* RumConfig declaration */
#define MAX_STRATEGIES (8)
typedef struct RumConfig
{
	Oid addInfoTypeOid;

	struct
	{
		StrategyNumber strategy;
		ScanDirection direction;
	}       strategyInfo[MAX_STRATEGIES];

	bool skipGenerateEmptyEntries;
	bool compareFunctionHasRecheck;
}   RumConfig;


/* rumsharedmemutils.c */
extern void InitializeRumVacuumState(void);
extern RumVacuumCycleId rum_start_vacuum_cycle_id(Relation rel);
extern void rum_end_vacuum_cycle_id(Relation rel);
extern RumVacuumCycleId rum_vacuum_get_cycleId(Relation rel);

/* rumconfigs.c */
#define RUM_DEFAULT_FILL_FACTOR 50

#define UNREDACTED_RUM_LOG_CODE MAKE_SQLSTATE('R', 'Z', 'Z', 'Z', 'Z')
typedef int (*rum_format_log_hook)(const char *fmt, ...) pg_attribute_printf (1, 2);
extern PGDLLIMPORT rum_format_log_hook rum_unredacted_log_emit_hook;

#define errmsg_unredacted(...) \
	(rum_unredacted_log_emit_hook ? \
	 (*rum_unredacted_log_emit_hook)(__VA_ARGS__) : \
	 errmsg_internal(__VA_ARGS__))


#define elog_rum_unredacted(...) \
	ereport(LOG, (errcode(UNREDACTED_RUM_LOG_CODE), errhidecontext(true), \
				  errhidestmt(true), errmsg_unredacted( \
					  __VA_ARGS__)))


#ifdef RUM_BUILD_ONLY_CORE_RMGR
#define RMGR_PG_FUNCTION_INFO_V1(funcname) PG_FUNCTION_INFO_V1(builtin_rmgr_ ## funcname)
#define RMGR_PG_FUNCTION_DEF(funcname) \
	PGDLLEXPORT Datum builtin_rmgr_ ## funcname(PG_FUNCTION_ARGS)

#define RMGR_FUNC_EXPORT(rettype, funcname, ...) PGDLLEXPORT rettype \
	builtin_rmgr_ ## funcname(__VA_ARGS__)
#define RMGR_PREFIX_STR "builtin_rmgr_"
#define RMGR_SUFFIX_STR "_builtin_rmgr"
#else
#define RMGR_PG_FUNCTION_INFO_V1(funcname) PG_FUNCTION_INFO_V1(funcname)
#define RMGR_PG_FUNCTION_DEF(funcname) PGDLLEXPORT Datum funcname(PG_FUNCTION_ARGS)
#define RMGR_FUNC_EXPORT(rettype, funcname, ...) PGDLLEXPORT rettype funcname(__VA_ARGS__)
#define RMGR_PREFIX_STR ""
#define RMGR_SUFFIX_STR ""
#endif

#endif
