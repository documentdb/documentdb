/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/explain/documentdb_explain.c
 *
 * Base Implementation and Definitions for explain for documentdb.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <utils/lsyscache.h>
#include <nodes/extensible.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <tcop/tcopprot.h>
#include <utils/snapmgr.h>
#include <access/relscan.h>
#include <parser/parsetree.h>
#include <utils/rel.h>
#include <catalog/pg_am.h>
#include <access/skey.h>
#include <nodes/execnodes.h>
#include <utils/jsonb.h>

#include "io/bson_core.h"
#include "commands/commands_common.h"
#include "commands/parse_error.h"
#include "utils/queryenvironment.h"
#include "aggregation/bson_aggregation_pipeline.h"
#include "planner/mongo_query_operator.h"
#include "metadata/metadata_cache.h"
#include "planner/documentdb_planner.h"
#include "index_am/index_am_utils.h"
#include "index_am/documentdb_rum.h"
#include "explain/documentdb_explain.h"
#include "utils/query_utils.h"
#include "utils/documentdb_pg_compatibility.h"

typedef enum ExplainVerbosity
{
	ExplainVerbosity_Invalid = 0,
	ExplainVerbosity_QueryPlanner,
	ExplainVerbosity_ExecutionStats,
	ExplainVerbosity_AllPlansExecution,
	ExplainVerbosity_AllShardsQueryPlanner,
	ExplainVerbosity_AllShardsExecution,
} ExplainVerbosity;

typedef enum ExplainKind
{
	ExplainKind_Find = 0,
	ExplainKind_Aggregate,
	ExplainKind_Count,
	ExplainKind_Distinct,
} ExplainKind;

typedef struct ExplainInputData
{
	text *databaseName;
	pgbson *command;
	ExplainVerbosity verbosity;
} ExplainInputData;

typedef struct DocumentDBExplainState
{
	instr_time planningTime;
	BufferUsage planningBuffers;
	double totalTime;
	pgbson *queryPlanBson;
	pgbson *executionStatsBson;
	const char *requestNamespace;
} DocumentDBExplainState;

DocumentDBExplainStageHook explain_stage_hook = NULL;

PG_FUNCTION_INFO_V1(documentdb_explain);

ExplainInputData * ParseExplainSpec(pgbson *explainSpec);
static Query * CreateQueryFromQuerySpec(ExplainInputData *data, bool addCursorParams,
										QueryData *queryData, ExplainKind *explainKind);
static DocumentDBExplainState * GenerateAndExecutePlan(Query *query, QueryData *queryData,
													   ExplainVerbosity verbosity);
static void WriteExplainExecutionOutput(DocumentDBExplainState *state,
										QueryDesc *queryDesc,
										ExplainVerbosity verbosity);
static void WriteExplainPlannerOutput(DocumentDBExplainState *state, QueryDesc *queryDesc,
									  ExplainVerbosity verbosity);
static void WriteQuals(pgbson_writer *writer, List *quals);
static char * GetPlanStageName(PlanState *planState, const char **wrapperStageName);
static void WriteStageCore(pgbson_writer *writer, QueryDesc *queryDesc,
						   PlanState *planState,
						   void (*stageWriteFunc)(pgbson_writer *, const char *,
												  QueryDesc *, PlanState *));

Datum
documentdb_explain(PG_FUNCTION_ARGS)
{
	pgbson *explainSpec = PG_GETARG_PGBSON_PACKED(0);
	bool addCursorParams = PG_GETARG_BOOL(1);
	ExplainInputData *data = ParseExplainSpec(explainSpec);

	QueryData queryData = GenerateFirstPageQueryData();

	/* Next, generate the query from the spec */
	ExplainKind explainKind;
	Query *query = CreateQueryFromQuerySpec(data, addCursorParams, &queryData,
											&explainKind);

	/* Now generate & execute plan in explain mode. This is similar to what Postgres
	 * does in explain.c
	 */
	DocumentDBExplainState *state = GenerateAndExecutePlan(query, &queryData,
														   data->verbosity);

	pgbson_writer finalWriter;
	PgbsonWriterInit(&finalWriter);
	PgbsonWriterAppendDouble(&finalWriter, "explainVersion", -1, 2.0);
	PgbsonWriterAppendDocument(&finalWriter, "queryPlanner", -1, state->queryPlanBson);

	if (state->executionStatsBson != NULL)
	{
		PgbsonWriterAppendDocument(&finalWriter, "executionStats", -1,
								   state->executionStatsBson);
	}

	PgbsonWriterAppendDouble(&finalWriter, "ok", 2, 1.0);
	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&finalWriter));
}


static ExplainVerbosity
ParseExplainVerbosity(const char *verbosityStr)
{
	if (strcmp(verbosityStr, "queryPlanner") == 0)
	{
		return ExplainVerbosity_QueryPlanner;
	}
	else if (strcmp(verbosityStr, "executionStats") == 0)
	{
		return ExplainVerbosity_ExecutionStats;
	}
	else if (strcmp(verbosityStr, "allPlansExecution") == 0)
	{
		return ExplainVerbosity_AllPlansExecution;
	}
	else if (strcmp(verbosityStr, "allShardsQueryPlanner") == 0)
	{
		return ExplainVerbosity_AllShardsQueryPlanner;
	}
	else if (strcmp(verbosityStr, "allShardsExecution") == 0)
	{
		return ExplainVerbosity_AllShardsExecution;
	}
	else
	{
		ereport(ERROR, (errmsg("Invalid verbosity option for explain: %s",
							   verbosityStr)));
	}
}


ExplainInputData *
ParseExplainSpec(pgbson *explainSpec)
{
	ExplainInputData *data = (ExplainInputData *) palloc0(sizeof(ExplainInputData));
	bson_iter_t explainIter;
	PgbsonInitIterator(explainSpec, &explainIter);

	while (bson_iter_next(&explainIter))
	{
		const char *fieldName = bson_iter_key(&explainIter);
		if (strcmp(fieldName, "explain") == 0)
		{
			EnsureTopLevelFieldType("explain", &explainIter, BSON_TYPE_DOCUMENT);
			data->command = PgbsonInitFromDocumentBsonValue(bson_iter_value(
																&explainIter));
		}
		else if (strcmp(fieldName, "verbosity") == 0)
		{
			EnsureTopLevelFieldType("verbosity", &explainIter, BSON_TYPE_UTF8);
			data->verbosity = ParseExplainVerbosity(bson_iter_utf8(&explainIter, NULL));
		}
		else if (strcmp(fieldName, "$db") == 0)
		{
			EnsureTopLevelFieldType("$db", &explainIter, BSON_TYPE_UTF8);
			data->databaseName = cstring_to_text(bson_iter_utf8(&explainIter, NULL));
		}
		else if (IsCommonSpecIgnoredField(fieldName))
		{
			/* Ignore common spec fields that are not needed for explain. */
			continue;
		}
		else
		{
			ereport(ERROR, (errmsg("Invalid field in explain spec: %s", fieldName)));
		}
	}

	if (data->command == NULL)
	{
		ereport(ERROR, (errmsg("Missing required field 'explain' in explain spec")));
	}

	if (data->verbosity == ExplainVerbosity_Invalid)
	{
		ereport(ERROR, (errmsg("Missing or invalid 'verbosity' field in explain spec")));
	}

	if (data->databaseName == NULL)
	{
		ereport(ERROR, (errmsg("Missing required field '$db' in explain spec")));
	}

	return data;
}


static Query *
CreateQueryFromQuerySpec(ExplainInputData *data, bool addCursorParams,
						 QueryData *queryData, ExplainKind *explainKind)
{
	/* Get the command from the explain spec first */
	bool setStatementTimeout = false;
	bson_iter_t commandIter;
	if (PgbsonInitIteratorAtPath(data->command, "find", &commandIter))
	{
		/* It's a find command - generate find query */
		*explainKind = ExplainKind_Find;
		return GenerateFindQuery(data->databaseName, data->command, queryData,
								 addCursorParams, setStatementTimeout);
	}
	else if (PgbsonInitIteratorAtPath(data->command, "aggregate", &commandIter))
	{
		/* It's an aggregate command - generate aggregate query */
		*explainKind = ExplainKind_Aggregate;
		return GenerateAggregationQuery(data->databaseName, data->command, queryData,
										addCursorParams, setStatementTimeout);
	}
	else if (PgbsonInitIteratorAtPath(data->command, "count", &commandIter))
	{
		/* It's a count command - generate count query */
		*explainKind = ExplainKind_Count;
		return GenerateCountQuery(data->databaseName, data->command, setStatementTimeout);
	}
	else if (PgbsonInitIteratorAtPath(data->command, "distinct", &commandIter))
	{
		/* It's a distinct command - generate distinct query */
		*explainKind = ExplainKind_Distinct;
		return GenerateDistinctQuery(data->databaseName, data->command,
									 setStatementTimeout);
	}
	else
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg(
							"Unsupported command for explain: only find, aggregate, count, and distinct are supported")));
	}
}


static double
elapsed_time(instr_time *starttime)
{
	instr_time endtime;

	INSTR_TIME_SET_CURRENT(endtime);
	INSTR_TIME_SUBTRACT(endtime, *starttime);
	return INSTR_TIME_GET_DOUBLE(endtime);
}


static void
RunPlannedStatement(PlannedStmt *plannedstmt, char *queryString, ParamListInfo params,
					bool analyze, DocumentDBExplainState *state, ExplainVerbosity
					verbosity)
{
	DestReceiver *dest;
	QueryDesc *queryDesc;
	instr_time starttime;
	int eflags;
	int instrument_option = 0;
	QueryEnvironment *queryEnv = create_queryEnv();

	state->totalTime = 0;

	if (analyze)
	{
		instrument_option |= INSTRUMENT_TIMER;
		instrument_option |= INSTRUMENT_ROWS;
	}

	instrument_option |= INSTRUMENT_BUFFERS;
	instrument_option |= INSTRUMENT_WAL;

	/*
	 * We always collect timing for the entire statement, even when node-level
	 * timing is off, so we don't look at es->timing here.  (We could skip
	 * this if !es->summary, but it's hardly worth the complication.)
	 */
	INSTR_TIME_SET_CURRENT(starttime);

	/*
	 * Use a snapshot with an updated command ID to ensure this query sees
	 * results of any previously executed queries.
	 */
	PushCopiedSnapshot(GetActiveSnapshot());
	UpdateActiveSnapshotCommandId();

	dest = None_Receiver;

	/* Create a QueryDesc for the query */
	queryDesc = CreateQueryDesc(plannedstmt, queryString,
								GetActiveSnapshot(), InvalidSnapshot,
								dest, params, queryEnv, instrument_option);

	/* Select execution options */
	if (analyze)
	{
		eflags = 0;             /* default run-to-completion flags */
	}
	else
	{
		eflags = EXEC_FLAG_EXPLAIN_ONLY;
	}

	/* call ExecutorStart to prepare the plan for execution */
	ExecutorStart(queryDesc, eflags);

	WriteExplainPlannerOutput(state, queryDesc, verbosity);

	/* Execute the plan for statistics if asked for */
	if (analyze)
	{
		ScanDirection dir = ForwardScanDirection;

		/* run the plan */
		ExecutorRun_Compat(queryDesc, dir, 0, true);

		/* run cleanup too */
		ExecutorFinish(queryDesc);

		/* We can't run ExecutorEnd 'till we're done printing the stats... */
		state->totalTime += elapsed_time(&starttime);

		/* write out the explain of the plan itself */
		WriteExplainExecutionOutput(state, queryDesc, verbosity);
	}

	/*
	 * Close down the query and free resources.  Include time for this in the
	 * total execution time (although it should be pretty minimal).
	 */
	INSTR_TIME_SET_CURRENT(starttime);

	ExecutorEnd(queryDesc);

	FreeQueryDesc(queryDesc);

	PopActiveSnapshot();

	/* We need a CCI just in case query expanded to multiple plans */
	if (analyze)
	{
		CommandCounterIncrement();
	}

	state->totalTime += elapsed_time(&starttime);
}


static DocumentDBExplainState *
GenerateAndExecutePlan(Query *query, QueryData *queryData, ExplainVerbosity verbosity)
{
	PlannedStmt *plan;
	instr_time planstart;
	BufferUsage bufusage_start;
	DocumentDBExplainState *state = (DocumentDBExplainState *) palloc0(
		sizeof(DocumentDBExplainState));

	state->requestNamespace = queryData->namespaceName;
	bufusage_start = pgBufferUsage;
	INSTR_TIME_SET_CURRENT(planstart);

	/* plan the query */
	int cursorOptions = CURSOR_OPT_PARALLEL_OK;
	char *queryString = "";
	ParamListInfo params = NULL;
	plan = pg_plan_query(query, queryString, cursorOptions, params);

	INSTR_TIME_SET_CURRENT(state->planningTime);
	INSTR_TIME_SUBTRACT(state->planningTime, planstart);

	/* calc differences of buffer counters. */
	memset(&state->planningBuffers, 0, sizeof(BufferUsage));
	BufferUsageAccumDiff(&state->planningBuffers, &pgBufferUsage, &bufusage_start);

	/* run it (if needed) and produce output */
	bool analyze = verbosity != ExplainVerbosity_QueryPlanner && verbosity !=
				   ExplainVerbosity_AllShardsQueryPlanner;
	RunPlannedStatement(plan, queryString, params, analyze, state, verbosity);
	return state;
}


static void
WriterSingleQual(pgbson_writer *writer, Expr *qual)
{
	List *args;
	const MongoQueryOperator *operator = GetMongoQueryOperatorFromIndexOrRuntimeExpr(
		(Node *) qual, &args);

	if (list_length(args) != 2 || operator->operatorType == QUERY_OPERATOR_UNKNOWN)
	{
		/* Check if it's for the shard_key_value or object_id */
		if (IsA(qual, OpExpr))
		{
			OpExpr *opExpr = (OpExpr *) qual;
			if (IsA(linitial(opExpr->args), Var))
			{
				Var *firstVar = (Var *) linitial(opExpr->args);
				if (firstVar->varno == INDEX_VAR &&
					firstVar->varattno ==
					DOCUMENT_DATA_TABLE_SHARD_KEY_VALUE_VAR_ATTR_NUMBER &&
					firstVar->vartype == INT8OID)
				{
					return;
				}
				else if (firstVar->varno == INDEX_VAR &&
						 firstVar->varattno ==
						 DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER &&
						 firstVar->vartype == BsonTypeId())
				{
					/* Object_Id qual - write as object_id filter */
					Expr *secondArg = lsecond(opExpr->args);
					if (IsA(secondArg, Const))
					{
						Const *secondConst = (Const *) secondArg;
						pgbsonelement secondElement;
						PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(
																	 secondConst->
																	 constvalue),
																 &secondElement);

						const char *operatorName = "$unknown";
						if (opExpr->opno == BsonEqualOperatorId())
						{
							operatorName = "$eq";
						}
						else if (opExpr->opno == BsonLessThanOperatorId())
						{
							operatorName = "$lt";
						}
						else if (opExpr->opno == BsonLessThanEqualOperatorId())
						{
							operatorName = "$lte";
						}
						else if (opExpr->opno == BsonGreaterThanOperatorId())
						{
							operatorName = "$gt";
						}
						else if (opExpr->opno == BsonGreaterThanEqualOperatorId())
						{
							operatorName = "$gte";
						}

						pgbson_writer idFilterWriter;
						PgbsonWriterStartDocument(writer, "_id", -1, &idFilterWriter);
						PgbsonWriterAppendValue(&idFilterWriter, operatorName, -1,
												&secondElement.bsonValue);
						PgbsonWriterEndDocument(writer, &idFilterWriter);
						return;
					}
					else
					{
						PgbsonWriterAppendUtf8(writer, "_id", -1, "unknown-filter");
						return;
					}
				}
			}
		}

		PgbsonWriterAppendBool(writer, "$unknownOperator", -1, true);
		return;
	}

	const char *operatorName = operator->mongoOperatorName;
	Expr *secondArg = lsecond(args);
	if (!IsA(secondArg, Const))
	{
		PgbsonWriterAppendDocument(writer, operatorName, -1, PgbsonInitEmpty());
		return;
	}

	Const *secondConst = (Const *) secondArg;
	pgbsonelement secondElement;
	PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(secondConst->constvalue),
											 &secondElement);

	pgbson_writer innerQualWriter;
	PgbsonWriterStartDocument(writer, secondElement.path, secondElement.pathLength,
							  &innerQualWriter);
	PgbsonWriterAppendValue(&innerQualWriter, operatorName, -1, &secondElement.bsonValue);
	PgbsonWriterEndDocument(writer, &innerQualWriter);
}


static void
WriteBoolExpr(pgbson_array_writer *writer, BoolExpr *boolExpr)
{
	ListCell *argCell;
	foreach(argCell, boolExpr->args)
	{
		Expr *innerArg = (Expr *) lfirst(argCell);

		pgbson_writer branchWriter;
		PgbsonArrayWriterStartDocument(writer, &branchWriter);
		WriteQuals(&branchWriter, list_make1(innerArg));
		PgbsonArrayWriterEndDocument(writer, &branchWriter);
	}
}


static void
WriteQuals(pgbson_writer *writer, List *quals)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	ListCell *qualCell;
	foreach(qualCell, quals)
	{
		Expr *qual = (Expr *) lfirst(qualCell);

		if (IsA(qual, BoolExpr))
		{
			BoolExpr *boolExpr = (BoolExpr *) qual;
			switch (boolExpr->boolop)
			{
				case AND_EXPR:
				{
					pgbson_array_writer andWriter;
					PgbsonWriterStartArray(writer, "$and", -1, &andWriter);
					WriteBoolExpr(&andWriter, boolExpr);
					PgbsonWriterEndArray(writer, &andWriter);
					break;
				}

				case OR_EXPR:
				{
					pgbson_array_writer orWriter;
					PgbsonWriterStartArray(writer, "$or", -1, &orWriter);
					WriteBoolExpr(&orWriter, boolExpr);
					PgbsonWriterEndArray(writer, &orWriter);
					break;
				}

				case NOT_EXPR:
				{
					pgbson_writer notWriter;
					PgbsonWriterStartDocument(writer, "$not", -1, &notWriter);
					WriterSingleQual(&notWriter, linitial(boolExpr->args));
					PgbsonWriterEndDocument(writer, &notWriter);
					break;
				}

				default:
					ereport(ERROR, (errmsg("Unsupported boolean operator in qual: %d",
										   boolExpr->boolop)));
			}
		}
		else
		{
			WriterSingleQual(writer, qual);
		}
	}
}


static void
WriteSingleStage(pgbson_writer *writer, const char *stageName, QueryDesc *queryDesc,
				 PlanState *planState,
				 void (*stageWriteFunc)(pgbson_writer *, const char *, QueryDesc *,
										PlanState *))
{
	PgbsonWriterAppendUtf8(writer, "stage", -1, stageName);
	stageWriteFunc(writer, stageName, queryDesc, planState);

	List *childPlans = NIL;
	ListCell *lc;
	foreach(lc, planState->initPlan)
	{
		SubPlanState *subPlanState = (SubPlanState *) lfirst(lc);
		childPlans = lappend(childPlans, subPlanState->planstate);
	}

	if (planState->lefttree)
	{
		childPlans = lappend(childPlans, planState->lefttree);
	}

	if (planState->righttree)
	{
		childPlans = lappend(childPlans, planState->righttree);
	}

	foreach(lc, planState->subPlan)
	{
		SubPlanState *subPlanState = (SubPlanState *) lfirst(lc);
		childPlans = lappend(childPlans, subPlanState->planstate);
	}


	/* special child plans */
	switch (nodeTag(planState->plan))
	{
		case T_Append:
		{
			for (int i = 0; i < ((AppendState *) planState)->as_nplans; i++)
			{
				PlanState *childPlan = ((AppendState *) planState)->appendplans[i];
				childPlans = lappend(childPlans, childPlan);
			}

			break;
		}

		case T_MergeAppend:
		{
			for (int i = 0; i < ((MergeAppendState *) planState)->ms_nplans; i++)
			{
				PlanState *childPlan = ((MergeAppendState *) planState)->mergeplans[i];
				childPlans = lappend(childPlans, childPlan);
			}

			break;
		}

		case T_BitmapAnd:
		{
			for (int i = 0; i < ((BitmapAndState *) planState)->nplans; i++)
			{
				PlanState *childPlan = ((BitmapAndState *) planState)->bitmapplans[i];
				childPlans = lappend(childPlans, childPlan);
			}

			break;
		}

		case T_BitmapOr:
		{
			for (int i = 0; i < ((BitmapOrState *) planState)->nplans; i++)
			{
				PlanState *childPlan = ((BitmapOrState *) planState)->bitmapplans[i];
				childPlans = lappend(childPlans, childPlan);
			}

			break;
		}

		case T_SubqueryScan:
		{
			childPlans = lappend(childPlans, ((SubqueryScanState *) planState)->subplan);
			break;
		}

		case T_CustomScan:
		{
			childPlans = list_concat(childPlans,
									 ((CustomScanState *) planState)->custom_ps);
			break;
		}

		default:
		{
			break;
		}
	}

	if (list_length(childPlans) == 1)
	{
		PlanState *childPlan = (PlanState *) linitial(childPlans);
		pgbson_writer childWriter;
		PgbsonWriterStartDocument(writer, "inputStage", -1, &childWriter);
		WriteStageCore(&childWriter, queryDesc, childPlan, stageWriteFunc);
		PgbsonWriterEndDocument(writer, &childWriter);
		list_free(childPlans);
	}
	else if (list_length(childPlans) > 1)
	{
		pgbson_array_writer childArrayWriter;
		PgbsonWriterStartArray(writer, "inputStages", -1, &childArrayWriter);
		foreach(lc, childPlans)
		{
			PlanState *childPlan = (PlanState *) lfirst(lc);
			pgbson_writer childWriter;
			PgbsonArrayWriterStartDocument(&childArrayWriter, &childWriter);
			WriteStageCore(&childWriter, queryDesc, childPlan, stageWriteFunc);
			PgbsonArrayWriterEndDocument(&childArrayWriter, &childWriter);
		}
		PgbsonWriterEndArray(writer, &childArrayWriter);
		list_free(childPlans);
	}
}


static void
WriteStageCore(pgbson_writer *writer, QueryDesc *queryDesc, PlanState *planState,
			   void (*stageWriteFunc)(pgbson_writer *, const char *, QueryDesc *,
									  PlanState *))
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	if (explain_stage_hook &&
		explain_stage_hook(writer, queryDesc, planState, stageWriteFunc))
	{
		return;
	}

	const char *wrapperStageName = NULL;
	const char *stageName = GetPlanStageName(planState, &wrapperStageName);

	if (wrapperStageName)
	{
		PgbsonWriterAppendUtf8(writer, "stage", -1, wrapperStageName);

		pgbson_writer innerStageWriter;
		PgbsonWriterStartDocument(writer, "inputStage", -1, &innerStageWriter);
		WriteSingleStage(&innerStageWriter, stageName, queryDesc, planState,
						 stageWriteFunc);
		PgbsonWriterEndDocument(writer, &innerStageWriter);
	}
	else
	{
		WriteSingleStage(writer, stageName, queryDesc, planState, stageWriteFunc);
	}
}


inline static Oid
GetIndexAmOid(IndexScanDescData *scanDesc, Oid indexOid)
{
	Oid indexAmOid;
	if (scanDesc)
	{
		indexAmOid = scanDesc->indexRelation->rd_rel->relam;
	}
	else
	{
		Relation rel = RelationIdGetRelation(indexOid);
		if (rel == NULL)
		{
			ereport(ERROR, (errmsg("Could not open relation for index OID: %d",
								   indexOid)));
		}

		indexAmOid = rel->rd_rel->relam;
		RelationClose(rel);
	}

	return indexAmOid;
}


inline static bool
IsIndexScanPrimaryKeyCollScan(IndexScanDescData *scanDesc, Oid indexOid, List *indexQual)
{
	bool isBtreeIndex = GetIndexAmOid(scanDesc, indexOid) == BTREE_AM_OID;
	return isBtreeIndex && list_length(indexQual) == 1 &&
		   IsA(linitial(indexQual), OpExpr) &&
		   ((OpExpr *) linitial(indexQual))->opno == BigintEqualOperatorId();
}


static char *
GetPlanStageName(PlanState *planState, const char **wrapperStageName)
{
	switch (nodeTag(planState))
	{
		case T_SeqScanState:
		{
			return "COLLSCAN";
		}

		case T_FunctionScanState:
		{
			FunctionScanState *functionScanState = (FunctionScanState *) planState;
			FunctionScan *funcScan = (FunctionScan *) functionScanState->ss.ps.plan;
			if (list_length(funcScan->functions) == 1)
			{
				RangeTblFunction *rteFunc = (RangeTblFunction *) linitial(
					funcScan->functions);
				if (IsA(rteFunc->funcexpr, FuncExpr) &&
					((FuncExpr *) rteFunc->funcexpr)->funcid ==
					BsonEmptyDataTableFunctionId())
				{
					return "EOF";
				}
			}

			break;
		}

		case T_BitmapHeapScanState:
		{
			return "FETCH";
		}

		case T_LimitState:
		{
			LimitState *limitState = (LimitState *) planState;
			if (limitState->limitCount != NULL)
			{
				return "LIMIT";
			}
			if (limitState->limitOffset != NULL)
			{
				return "SKIP";
			}

			break;
		}

		case T_SubqueryScanState:
		{
			/* TODO: This is many more cases */
			return "PROJECTION_SIMPLE";
		}

		case T_ResultState:
		{
			return "PROJECTION_SIMPLE";
		}

		case T_IncrementalSortState:
		case T_SortState:
		{
			return "SORT";
		}

		case T_BitmapAnd:
		{
			return "AND";
		}

		case T_BitmapOr:
		{
			return "OR";
		}

		case T_BitmapIndexScanState:
		{
			BitmapIndexScanState *bitmapIndexScanState =
				(BitmapIndexScanState *) planState;

			IndexScanDescData *indexScanDesc = bitmapIndexScanState->biss_ScanDesc;
			BitmapIndexScan *plan = (BitmapIndexScan *) bitmapIndexScanState->ss.ps.plan;
			bool isPrimaryKeyCollScan = IsIndexScanPrimaryKeyCollScan(
				indexScanDesc, plan->indexid, plan->indexqual);
			if (isPrimaryKeyCollScan)
			{
				return "COLLSCAN";
			}
			return "IXSCAN";
		}

		case T_IndexOnlyScanState:
		{
			IndexOnlyScanState *indexOnlyScanState = (IndexOnlyScanState *) planState;
			IndexOnlyScan *plan = (IndexOnlyScan *) indexOnlyScanState->ss.ps.plan;
			bool isPrimaryKeyCollScan = IsIndexScanPrimaryKeyCollScan(
				indexOnlyScanState->ioss_ScanDesc,
				plan->indexid, plan->indexqual);
			if (isPrimaryKeyCollScan)
			{
				return "COLLSCAN";
			}

			return "IXSCAN";
		}

		case T_IndexScanState:
		{
			/* We only return IXSCAN if it's not btree, and it has > 1 qual on the btree */
			IndexScanState *indexScanState = (IndexScanState *) planState;
			IndexScan *plan = (IndexScan *) indexScanState->ss.ps.plan;
			bool isPrimaryKeyCollScan = IsIndexScanPrimaryKeyCollScan(
				indexScanState->iss_ScanDesc,
				plan->indexid, plan->indexqual);
			if (isPrimaryKeyCollScan)
			{
				return "COLLSCAN";
			}

			/*
			 * Since this is not an IXONLYSCAN, we wrap it in a FETCH stage
			 * to indicate that we're loading documents in the runtime
			 */
			*wrapperStageName = "FETCH";
			return "IXSCAN";
		}

		case T_CustomScanState:
		{
			CustomScanState *customScanState = (CustomScanState *) planState;
			CustomScan *customScan = (CustomScan *) customScanState->ss.ps.plan;

			elog(NOTICE, "CustomScan type %s", customScan->methods->CustomName);
			break;
		}

		default:
		{
			break;
		}
	}

	elog(NOTICE, "Unknown plan node type: %d", nodeTag(planState));
	return "UNKNOWN";
}


static const char *
GetNamespaceNameFromCollectionIdWithLibPq(uint64 collectionId)
{
	return ExtensionExecuteQueryOnLocalhostViaLibPQ(
		psprintf(
			"SELECT database_name || '.' || collection_name FROM %s.collections WHERE collection_id = %lu",
			ApiCatalogSchemaName, collectionId));
}


static void
WriteMongoNamespaceName(pgbson_writer *writer, QueryDesc *queryDesc, PlanState *planState)
{
	switch (nodeTag(planState->plan))
	{
		case T_SeqScan:
		case T_SampleScan:
		case T_BitmapHeapScan:
		case T_TidScan:
		case T_TidRangeScan:
		case T_SubqueryScan:
		case T_FunctionScan:
		case T_TableFuncScan:
		case T_ValuesScan:
		case T_CteScan:
		case T_WorkTableScan:
		case T_IndexScan:
		{
			Scan *scan = (Scan *) planState->plan;
			if (scan->scanrelid > 0)
			{
				RangeTblEntry *rte = rt_fetch(scan->scanrelid,
											  queryDesc->plannedstmt->rtable);
				if (rte->rtekind == RTE_RELATION)
				{
					bool requireShardTable = false;

					uint64 collectionId;
					if (TryGetCollectionIdByRelationOid(rte->relid, &collectionId,
														requireShardTable))
					{
						const char *namespaceName =
							GetNamespaceNameFromCollectionIdWithLibPq(collectionId);
						if (namespaceName)
						{
							PgbsonWriterAppendUtf8(writer, "ns", 2, namespaceName);
						}
					}
				}
			}

			break;
		}

		default:
		{
			break;
		}
	}
}


static void
WriteIndexOrderBy(pgbson_writer *writer, List *indexOrderBy, Oid indexAm, ScanDirection
				  indexorderdir)
{
	ListCell *orderByCell;
	foreach(orderByCell, indexOrderBy)
	{
		Expr *indexOrder = (Expr *) lfirst(orderByCell);

		if (IsA(indexOrder, Var) && indexAm == BTREE_AM_OID)
		{
			/* order by could by by object_id */
			Var *var = (Var *) indexOrder;
			if (var->varno == INDEX_VAR &&
				var->varattno == DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER)
			{
				PgbsonWriterAppendInt32(writer, "_id", 3, ScanDirectionIsForward(
											indexorderdir) ? 1 : -1);
			}
		}
		else if (IsA(indexOrder, OpExpr))
		{
			OpExpr *opExpr = (OpExpr *) indexOrder;
			if (opExpr->opno == BsonOrderByIndexOperatorId() ||
				opExpr->opno == BsonOrderByReverseIndexOperatorId())
			{
				Expr *orderArg = lsecond(opExpr->args);
				if (IsA(orderArg, Const))
				{
					Const *orderConst = (Const *) orderArg;
					pgbsonelement orderElement;
					PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(
																 orderConst->constvalue),
															 &orderElement);
					PgbsonWriterAppendValue(writer, orderElement.path,
											orderElement.pathLength,
											&orderElement.bsonValue);
				}
			}
		}
	}
}


static void
LogIndexScanDetails(pgbson_writer *writer, Oid indexOid, ScanDirection indexorderdir,
					List *indexOrderBy, List *indexQuals, IndexScanDescData *scanDesc)
{
	const char *indexName = ExtensionExplainGetIndexName(indexOid);
	if (indexName)
	{
		PgbsonWriterAppendUtf8(writer, "indexName", -1, indexName);
	}

	PgbsonWriterAppendUtf8(writer, "direction", -1, ScanDirectionIsBackward(
							   indexorderdir) ? "Backward" : "Forward");

	if (indexOrderBy != NIL)
	{
		PgbsonWriterAppendBool(writer, "hasOrderBy", -1, true);
	}

	Oid indexAm = GetIndexAmOid(scanDesc, indexOid);
	if (IsBsonRegularIndexAm(indexAm))
	{
		/* A RUM style index for operators */
		Relation index_rel = index_open(indexOid, NoLock);
		if (IsCompositeOpClass(index_rel))
		{
			ExplainRawCompositeScanToWriter(index_rel, indexQuals, indexOrderBy,
											indexorderdir,
											writer);
		}
		index_close(index_rel, NoLock);
	}

	/* TODO: Vector search, geospatial indexes */
	pgbson_writer indexQualWriter;
	PgbsonWriterStartDocument(writer, "indexFilters", -1, &indexQualWriter);
	WriteQuals(&indexQualWriter, indexQuals);
	PgbsonWriterEndDocument(writer, &indexQualWriter);

	if (indexOrderBy != NIL)
	{
		pgbson_writer orderWriter;
		PgbsonWriterStartDocument(writer, "indexOrderBy", -1, &orderWriter);
		WriteIndexOrderBy(&orderWriter, indexOrderBy, indexAm, indexorderdir);
		PgbsonWriterEndDocument(writer, &orderWriter);
	}
}


static void
LogSortKeysCore(pgbson_writer *sortKeyWriter, Sort *plan, PlanState *leftTree,
				int startIndex, int numCols)
{
	for (int i = startIndex; i < startIndex + numCols; i++)
	{
		TargetEntry *entry = list_nth(plan->plan.targetlist, plan->sortColIdx[i] - 1);

		Expr *entryExpr = entry->expr;
		if (IsA(entry->expr, Var) && leftTree != NULL)
		{
			Var *var = (Var *) entry->expr;
			if (list_length(leftTree->plan->targetlist) >= var->varattno)
			{
				TargetEntry *subTargetEntry = list_nth(leftTree->plan->targetlist,
													   var->varattno - 1);
				entryExpr = subTargetEntry->expr;
			}
		}

		if (IsA(entryExpr, FuncExpr))
		{
			FuncExpr *funcExpr = (FuncExpr *) entryExpr;
			if (funcExpr->funcid == BsonOrderByFunctionOid())
			{
				Expr *secondExpr = lsecond(funcExpr->args);
				if (IsA(secondExpr, Const))
				{
					Const *secondConst = (Const *) secondExpr;
					pgbson *orderBson = DatumGetPgBson(secondConst->constvalue);
					pgbsonelement sortElement;
					PgbsonToSinglePgbsonElementWithCollation(orderBson, &sortElement);
					PgbsonWriterAppendValue(sortKeyWriter, sortElement.path,
											sortElement.pathLength,
											&sortElement.bsonValue);
					continue;
				}
			}
		}

		PgbsonWriterAppendInt32(sortKeyWriter, "unknown-sort-operator", -1, 0);
	}
}


static void
LogSortKeys(pgbson_writer *writer, Sort *plan, PlanState *leftTree, int numPresorted)
{
	if (plan->numCols > 0)
	{
		pgbson_writer sortKeyWriter;
		PgbsonWriterStartDocument(writer, "sortPattern", -1, &sortKeyWriter);
		LogSortKeysCore(&sortKeyWriter, plan, leftTree, 0, plan->numCols);
		PgbsonWriterEndDocument(writer, &sortKeyWriter);

		if (numPresorted > 0)
		{
			PgbsonWriterAppendInt32(writer, "numPresortedKeys", -1, numPresorted);
			pgbson_writer presortedKeyWriter;
			PgbsonWriterStartDocument(writer, "preSortedKeys", -1, &presortedKeyWriter);
			LogSortKeysCore(&presortedKeyWriter, plan, leftTree, 0, numPresorted);
			PgbsonWriterEndDocument(writer, &presortedKeyWriter);
		}
	}
}


static void
WriteProjectionState(PlanState *planState, pgbson_writer *writer)
{
	if (list_length(planState->plan->targetlist) == 0)
	{
		return;
	}

	FuncExpr *validProjection = NULL;
	Expr *projectionArg = NULL;
	ListCell *cell;
	foreach(cell, planState->plan->targetlist)
	{
		TargetEntry *targetEntry = (TargetEntry *) lfirst(cell);
		if (targetEntry->resjunk)
		{
			continue;
		}

		if (IsA(targetEntry->expr, FuncExpr))
		{
			FuncExpr *funcExpr = (FuncExpr *) targetEntry->expr;
			if (funcExpr->funcid == BsonDollarProjectFindFunctionOid() ||
				funcExpr->funcid == BsonDollarProjectFindWithLetFunctionOid())
			{
				validProjection = funcExpr;
				projectionArg = lsecond(funcExpr->args);
				break;
			}
		}
	}

	if (validProjection == NULL || projectionArg == NULL)
	{
		return;
	}

	if (IsA(projectionArg, Const))
	{
		Const *projectionConst = (Const *) projectionArg;
		pgbson *projectionBson = DatumGetPgBson(projectionConst->constvalue);
		PgbsonWriterAppendDocument(writer, "transformBy", -1, projectionBson);
	}
}


static void
WritePlanState(pgbson_writer *writer, const char *stageName, QueryDesc *queryDesc,
			   PlanState *planState)
{
	WriteMongoNamespaceName(writer, queryDesc, planState);

	PgbsonWriterAppendDouble(writer, "startupCost", -1, planState->plan->startup_cost);
	PgbsonWriterAppendDouble(writer, "totalCost", -1, planState->plan->total_cost);

	if (strcmp(stageName, "EOF") != 0)
	{
		/* For EOF stage, rows is always 0 and doesn't represent actual estimated rows, so we skip it to avoid confusion. */
		PgbsonWriterAppendDouble(writer, "estimatedTotalKeysExamined", -1,
								 planState->plan->plan_rows);
	}

	if (planState->plan->qual != NIL)
	{
		pgbson_writer qualWriter;
		PgbsonWriterStartDocument(writer, "filter", -1, &qualWriter);
		WriteQuals(&qualWriter, planState->plan->qual);
		PgbsonWriterEndDocument(writer, &qualWriter);
	}

	WriteProjectionState(planState, writer);

	/* per stage type planner output */
	switch (nodeTag(planState->plan))
	{
		case T_Limit:
		{
			LimitState *limitState = (LimitState *) planState;
			Limit *limitPlan = (Limit *) limitState->ps.plan;
			if (limitPlan->limitOffset != NULL &&
				IsA(limitPlan->limitOffset, Const))
			{
				Const *offsetConst = (Const *) limitPlan->limitOffset;
				PgbsonWriterAppendDouble(writer, "skipAmount", -1, DatumGetInt64(
											 offsetConst->constvalue));
			}

			if (limitPlan->limitCount != NULL &&
				IsA(limitPlan->limitCount, Const))
			{
				Const *countConst = (Const *) limitPlan->limitCount;
				PgbsonWriterAppendDouble(writer, "limitAmount", -1, DatumGetInt64(
											 countConst->constvalue));
			}

			break;
		}

		case T_IndexScan:
		{
			IndexScanState *indexScanState = (IndexScanState *) planState;
			IndexScan *plan = (IndexScan *) indexScanState->ss.ps.plan;

			LogIndexScanDetails(writer, plan->indexid, plan->indexorderdir,
								plan->indexorderby,
								plan->indexqual, indexScanState->iss_ScanDesc);
			break;
		}

		case T_IndexOnlyScan:
		{
			IndexOnlyScanState *indexOnlyScanState = (IndexOnlyScanState *) planState;
			IndexOnlyScan *plan = (IndexOnlyScan *) indexOnlyScanState->ss.ps.plan;
			LogIndexScanDetails(writer, plan->indexid, plan->indexorderdir,
								plan->indexorderby,
								plan->indexqual, indexOnlyScanState->ioss_ScanDesc);
			PgbsonWriterAppendBool(writer, "isIndexOnlyScan", -1, true);

			break;
		}

		case T_BitmapIndexScan:
		{
			BitmapIndexScanState *bitmapIndexScanState =
				(BitmapIndexScanState *) planState;
			BitmapIndexScan *plan = (BitmapIndexScan *) bitmapIndexScanState->ss.ps.plan;
			List *orderbyOps = NIL;
			LogIndexScanDetails(writer, plan->indexid, NoMovementScanDirection,
								orderbyOps, plan->indexqual,
								bitmapIndexScanState->biss_ScanDesc);
			PgbsonWriterAppendBool(writer, "isBitmap", -1, true);
			break;
		}

		case T_Sort:
		{
			SortState *sortState = (SortState *) planState;
			Sort *plan = (Sort *) sortState->ss.ps.plan;
			int numPresorted = 0;
			LogSortKeys(writer, plan, sortState->ss.ps.lefttree, numPresorted);
			break;
		}

		case T_IncrementalSort:
		{
			IncrementalSortState *sortState = (IncrementalSortState *) planState;
			IncrementalSort *plan = (IncrementalSort *) sortState->ss.ps.plan;
			LogSortKeys(writer, &plan->sort, sortState->ss.ps.lefttree,
						plan->nPresortedCols);
			break;
		}

		default:
		{
			break;
		}
	}
}


static void
WriteQueryPlanner(DocumentDBExplainState *state, QueryDesc *queryDesc,
				  pgbson_writer *writer)
{
	PgbsonWriterAppendUtf8(writer, "namespace", -1, state->requestNamespace);

	pgbson_writer winningPlanWriter;
	PgbsonWriterStartDocument(writer, "winningPlan", -1, &winningPlanWriter);
	WriteStageCore(&winningPlanWriter, queryDesc, queryDesc->planstate, WritePlanState);
	PgbsonWriterEndDocument(writer, &winningPlanWriter);
}


static void
WriteIndexExecutionStats(pgbson_writer *writer, IndexScanDescData *scanDesc,
						 Instrumentation *instrument)
{
	if (scanDesc == NULL)
	{
		return;
	}

	if (instrument->nfiltered2 > 0)
	{
		PgbsonWriterAppendDouble(writer, "totalDocsRemovedByIndexRecheck", -1,
								 instrument->nfiltered2);
	}

	Oid indexAm = GetIndexAmOid(scanDesc, scanDesc->indexRelation->rd_id);
	if (IsBsonRegularIndexAm(indexAm))
	{
		/* A RUM style index for operators */
		if (IsCompositeOpClass(scanDesc->indexRelation))
		{
			ExplainCompositeScanToWriter(scanDesc, writer);
		}
		else
		{
			ExplainRegularIndexScanToWriter(scanDesc, writer);
		}
	}
}


static void
WriterExecutionStage(pgbson_writer *writer, const char *stageName, QueryDesc *queryDesc,
					 PlanState *planstate)
{
	CHECK_FOR_INTERRUPTS();
	check_stack_depth();

	if (!planstate->instrument)
	{
		ereport(ERROR, (errmsg("Instrumentation data not found for stage %s",
							   stageName)));
	}

	InstrEndLoop(planstate->instrument);
	double nloops = Max(planstate->instrument->nloops, 1);
	double startup_ms = 1000.0 * planstate->instrument->startup / nloops;
	double total_ms = 1000.0 * planstate->instrument->total / nloops;
	double rows = planstate->instrument->ntuples;
	PgbsonWriterAppendDouble(writer, "nReturned", -1, rows);
	PgbsonWriterAppendDouble(writer, "executionStartAtTimeMillis", -1, startup_ms);
	PgbsonWriterAppendDouble(writer, "executionTimeMillis", -1, total_ms);

	/* All the docs that went through this stage - docs returned + docs stripped by a filter */
	double totalDocsExamined = planstate->instrument->ntuples +
							   planstate->instrument->nfiltered1;

	if (planstate->instrument->nfiltered1 > 0)
	{
		PgbsonWriterAppendDouble(writer, "totalDocsRemovedByRuntimeFilters", -1,
								 planstate->instrument->nfiltered1);
	}

	/* Node specific data */
	switch (nodeTag(planstate))
	{
		case T_IndexScanState:
		{
			/* add the documents filtered by index recheck */
			IndexScanState *scanState = (IndexScanState *) planstate;
			totalDocsExamined += planstate->instrument->nfiltered2;
			WriteIndexExecutionStats(writer, scanState->iss_ScanDesc,
									 planstate->instrument);
			break;
		}

		case T_IndexOnlyScanState:
		{
			/* add the documents filtered by index recheck */
			totalDocsExamined += planstate->instrument->nfiltered2;
			IndexOnlyScanState *scanState = (IndexOnlyScanState *) planstate;
			WriteIndexExecutionStats(writer, scanState->ioss_ScanDesc,
									 planstate->instrument);

			/* HeapFetches show up as nTuples2 */
			PgbsonWriterAppendDouble(writer, "totalDocsAnalyzed", -1,
									 planstate->instrument->ntuples2);
			break;
		}

		case T_BitmapIndexScanState:
		{
			BitmapIndexScanState *scanState = (BitmapIndexScanState *) planstate;
			WriteIndexExecutionStats(writer, scanState->biss_ScanDesc,
									 planstate->instrument);
			break;
		}

		case T_BitmapHeapScanState:
		{
			/* add the documents filtered by index recheck */
			BitmapHeapScanState *scanState = (BitmapHeapScanState *) planstate;
			totalDocsExamined += planstate->instrument->nfiltered2;
			if (planstate->instrument->nfiltered2 > 0)
			{
				PgbsonWriterAppendDouble(writer, "totalDocsRemovedByIndexRecheck", -1,
										 planstate->instrument->nfiltered2);
			}

#if PG_VERSION_NUM >= 180000
			PgbsonWriterAppendDouble(writer, "exactBlocksRead", -1,
									 scanState->stats.exact_pages);
			PgbsonWriterAppendDouble(writer, "lossyBlocksRead", -1,
									 scanState->stats.lossy_pages);
#else
			PgbsonWriterAppendDouble(writer, "exactBlocksRead", -1,
									 scanState->exact_pages);
			PgbsonWriterAppendDouble(writer, "lossyBlocksRead", -1,
									 scanState->lossy_pages);
#endif
			break;
		}

		case T_SortState:
		{
			SortState *sortstate = (SortState *) planstate;
			if (sortstate->sort_Done && sortstate->tuplesortstate != NULL)
			{
				Tuplesortstate *state = (Tuplesortstate *) sortstate->tuplesortstate;
				TuplesortInstrumentation stats;
				const char *sortMethod;
				tuplesort_get_stats(state, &stats);
				sortMethod = tuplesort_method_name(stats.sortMethod);

				PgbsonWriterAppendUtf8(writer, "sortMethod", -1, sortMethod);
				if (stats.spaceType == SORT_SPACE_TYPE_DISK)
				{
					PgbsonWriterAppendBool(writer, "usedDisk", -1, true);
				}

				PgbsonWriterAppendInt64(writer, "totalDataSizeSortedBytesEstimate", -1,
										stats.spaceUsed);
			}

			break;
		}

		default:
		{
			break;
		}
	}

	PgbsonWriterAppendDouble(writer, "totalDocsExamined", -1, totalDocsExamined);

	if (planstate->instrument->need_bufusage)
	{
		PgbsonWriterAppendDouble(writer, "numBlocksFromCache", -1,
								 planstate->instrument->bufusage.shared_blks_hit);
		PgbsonWriterAppendDouble(writer, "numBlocksFromDisk", -1,
								 planstate->instrument->bufusage.shared_blks_read);
#if PG_VERSION_NUM >= 170000
		PgbsonWriterAppendDouble(writer, "ioReadTimeMillis", -1, INSTR_TIME_GET_MILLISEC(
									 planstate->instrument->bufusage.shared_blk_read_time));
#else
		PgbsonWriterAppendDouble(writer, "ioReadTimeMillis", -1, INSTR_TIME_GET_MILLISEC(
									 planstate->instrument->bufusage.blk_read_time));
#endif
	}
}


static void
WriteExecutionStats(DocumentDBExplainState *state, QueryDesc *queryDesc,
					pgbson_writer *writer)
{
	InstrEndLoop(queryDesc->planstate->instrument);
	PgbsonWriterAppendInt64(writer, "nReturned", -1,
							(int64_t) queryDesc->estate->es_processed);
	PgbsonWriterAppendDouble(writer, "executionTimeMillis", -1, state->totalTime * 1000);

	pgbson_writer stagesWriter;
	PgbsonWriterStartDocument(writer, "executionStages", -1, &stagesWriter);
	WriteStageCore(&stagesWriter, queryDesc, queryDesc->planstate, WriterExecutionStage);
	PgbsonWriterEndDocument(writer, &stagesWriter);
}


static void
WriteExplainPlannerOutput(DocumentDBExplainState *state, QueryDesc *queryDesc,
						  ExplainVerbosity verbosity)
{
	pgbson_writer queryPlanWriter;
	PgbsonWriterInit(&queryPlanWriter);
	WriteQueryPlanner(state, queryDesc, &queryPlanWriter);
	state->queryPlanBson = PgbsonWriterGetPgbson(&queryPlanWriter);
}


static void
WriteExplainExecutionOutput(DocumentDBExplainState *state, QueryDesc *queryDesc,
							ExplainVerbosity verbosity)
{
	state->executionStatsBson = NULL;
	if (verbosity != ExplainVerbosity_QueryPlanner && verbosity !=
		ExplainVerbosity_AllShardsQueryPlanner)
	{
		pgbson_writer executionStatsWriter;
		PgbsonWriterInit(&executionStatsWriter);
		WriteExecutionStats(state, queryDesc, &executionStatsWriter);
		state->executionStatsBson = PgbsonWriterGetPgbson(&executionStatsWriter);
	}
}
