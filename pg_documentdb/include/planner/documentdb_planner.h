/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/planner/documentdb_planner.h
 *
 * The pg_documentdb planner hook function.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_PLANNER_H
#define DOCUMENTDB_PLANNER_H


#include "postgres.h"
#include <access/xlog.h>

#include <optimizer/planner.h>
#include <optimizer/paths.h>
#if PG_VERSION_NUM >= 190000
#include <optimizer/pathnode.h>
#endif
#include <commands/explain.h>
#include <parser/analyze.h>
#if PG_VERSION_NUM >= 180000
#include <commands/explain_state.h>
#endif
#include <optimizer/plancat.h>


/*
 * Hook for plugins to rewrite SQL statement on worker once it is identified as a
 * shard request.
 */
typedef bool (*node_worker_stmt_rewrite_hook_type) (PlannerInfo *root,
													RelOptInfo *rel,
													Index rti,
													RangeTblEntry *rte,
													TargetEntry *entry);
extern PGDLLIMPORT node_worker_stmt_rewrite_hook_type node_worker_stmt_rewrite_hook;

extern planner_hook_type ExtensionPreviousPlannerHook;
extern set_rel_pathlist_hook_type ExtensionPreviousSetRelPathlistHook;
extern post_parse_analyze_hook_type ExtensionPreviousPostParseAnalyzeHook;
extern explain_get_index_name_hook_type ExtensionPreviousIndexNameHook;
#if PG_VERSION_NUM >= 190000
extern build_simple_rel_hook_type ExtensionPreviousBuildSimpleRelHook;
#else
extern get_relation_info_hook_type ExtensionPreviousGetRelationInfoHook;
#endif
extern ExplainOneQuery_hook_type ExtensionPreviousExplainOneQueryHook;
extern bool SimulateRecoveryState;
extern bool DocumentDBPGReadOnlyForDiskFull;


#if PG_VERSION_NUM >= 190000
PlannedStmt * DocumentDBApiPlanner(Query *parse, const char *queryString,
								   int cursorOptions, ParamListInfo boundParams,
								   ExplainState *es);
#else
PlannedStmt * DocumentDBApiPlanner(Query *parse, const char *queryString,
								   int cursorOptions, ParamListInfo boundParams);
#endif
void DocumentDBApiExplainOneQuery(Query *query, int cursorOptions, IntoClause *into,
								  ExplainState *es, const char *queryString,
								  ParamListInfo params, QueryEnvironment *queryEnv);
void ExtensionRelPathlistHook(PlannerInfo *root, RelOptInfo *rel, Index rti,
							  RangeTblEntry *rte);

#if PG_VERSION_NUM >= 190000
void DocumentDBPostParseAnalyzeHook(ParseState *pstate, Query *query,
									const JumbleState *jstate);
void ExtensionBuildSimpleRelHook(PlannerInfo *root, RelOptInfo *rel,
								 RangeTblEntry *rte);
#else
void DocumentDBPostParseAnalyzeHook(ParseState *pstate, Query *query,
									JumbleState *jstate);
void ExtensionGetRelationInfoHook(PlannerInfo *root, Oid relationObjectId,
								  bool inhparent, RelOptInfo *rel);
#endif
bool IsDocumentDbCollectionBasedRTE(RangeTblEntry *rte);
bool IsResolvableDocumentDbCollectionBasedRTE(RangeTblEntry *rte,
											  ParamListInfo boundParams);
const char * ExtensionExplainGetIndexName(Oid indexId);
Const * GetConstParamValue(Node *param, ParamListInfo boundParams);

const char * ExtensionIndexOidGetIndexName(Oid indexId, bool useLibPq);
const char * GetDocumentDBIndexNameFromPostgresIndex(const char *pgIndexName, bool
													 useLibPq);
const char * ExtensionIndexOidGetIndexKey(Oid indexId, bool useLibPq);

/* Method that throws an error if we're trying to execute a write command and the
 * current database is in recovery mode (read-only mode). */
static inline void
ThrowIfWriteCommandNotAllowed(void)
{
	if (RecoveryInProgress() || SimulateRecoveryState)
	{
		ereport(ERROR, (errcode(ERRCODE_READ_ONLY_SQL_TRANSACTION), errmsg(
							"Can't execute write operation, the database is in recovery and waiting for the standby node to be promoted.")));
	}

	if (DocumentDBPGReadOnlyForDiskFull)
	{
		/*
		 *  We want to throw `ERRCODE_DISK_FULL` from backend when the disk is say `90% full` as opposed to waiting
		 *  for the disk to be `100% full`. Marlin runs a background task that monitors the disk and
		 *  sets a config `ApiGucPrefix.IsPgReadOnlyForDiskFull = true`, the postgres process then reads the config
		 *  and stores it in the `DocumentDBPGReadOnlyForDiskFull` variable. Marlin also set the postgres config
		 *  `default_transaction_read_only = on` which makes postgres throw `ERRCODE_READ_ONLY_SQL_TRANSACTION`
		 *  for any operation that can update data.
		 *
		 *  ToMongoError() utility in PostgresMongoResultExtensions.cs (aka gateway) then converts the Postgres
		 *  error to appropriate Mongo Client error code and error message.
		 */
		ereport(ERROR, (errcode(ERRCODE_DISK_FULL), errmsg(
							"Can't execute write operation, The database disk is full")));
	}
}


#endif
