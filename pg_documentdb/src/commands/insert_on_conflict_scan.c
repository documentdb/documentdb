/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 *
 * src/commands/insert_on_conflict_scan.c
 *
 * Learns an arbiter from a duplicate batch failure, adds conflict handling to
 * direct insert plans, and records skipped input positions for write errors.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <catalog/pg_constraint.h>
#include <catalog/pg_class.h>
#include <executor/executor.h>
#include <nodes/extensible.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <utils/lsyscache.h>
#include <utils/rel.h>
#include <utils/reltrigger.h>

#include "commands/insert_on_conflict_scan.h"

typedef struct InsertConflictCaptureScanState
{
	/* Executor state for this CustomScan node. */
	CustomScanState customScanState;

	/* Original input plan that supplies rows to ModifyTable. */
	PlanState *childPlanState;

	/* Zero-based index for the next input; the previous input is nextInputIndex - 1. */
	int nextInputIndex;

	/* Last observed es_processed value, used to classify the previous input. */
	uint64 lastSeenEsProcessed;

	/* Zero-based input positions that did not increment es_processed. */
	List *skippedIndexes;
} InsertConflictCaptureScanState;

static bool IsInsertConflictHandlingSafe(Oid relationOid);
static Plan * WrapPlanWithInsertConflictCaptureScan(Plan *childPlan);
static Node * InsertConflictCaptureCreateScanState(CustomScan *customScan);
static void InsertConflictCaptureBeginScan(CustomScanState *node, EState *estate,
										   int eflags);
static TupleTableSlot * InsertConflictCaptureExecScan(CustomScanState *node);
static void InsertConflictCaptureEndScan(CustomScanState *node);
static void InsertConflictCaptureReScan(CustomScanState *node);

static const CustomScanMethods InsertConflictCaptureScanMethods = {
	.CustomName = "DocumentDBApiInsertConflictCapture",
	.CreateCustomScanState = InsertConflictCaptureCreateScanState,
};

static const CustomExecMethods InsertConflictCaptureExecMethods = {
	.CustomName = "DocumentDBApiInsertConflictCapture",
	.BeginCustomScan = InsertConflictCaptureBeginScan,
	.ExecCustomScan = InsertConflictCaptureExecScan,
	.EndCustomScan = InsertConflictCaptureEndScan,
	.ReScanCustomScan = InsertConflictCaptureReScan,
};


static bool
IsInsertConflictHandlingSafe(Oid relationOid)
{
	Relation relation = RelationIdGetRelation(relationOid);
	if (relation == NULL)
	{
		return false;
	}

	TriggerDesc *triggerDesc = relation->trigdesc;
	bool isSafe = relation->rd_rel->relkind == RELKIND_RELATION &&
				  (triggerDesc == NULL ||
				   (!triggerDesc->trig_insert_before_row &&
					!triggerDesc->trig_insert_instead_row));
	RelationClose(relation);
	return isSafe;
}


/*
 * Resolves the first duplicate constraint to the physical arbiter used by
 * ON CONFLICT and caches its logical name for subsequent write errors.
 */
void
TrySetInsertConflictState(InsertConflictState *conflictState, ErrorData *errorData,
						  Oid shardOid, MemoryContext targetContext,
						  HTAB **indexNameCache)
{
	if (conflictState->isValid || shardOid == InvalidOid ||
		(errorData->sqlerrcode != ERRCODE_EXCLUSION_VIOLATION &&
		 errorData->sqlerrcode != ERRCODE_UNIQUE_VIOLATION) ||
		errorData->constraint_name == NULL)
	{
		return;
	}

	/*
	 * Row-suppressing triggers also leave es_processed unchanged, making them
	 * indistinguishable from rows skipped by conflict handling.
	 */
	if (!IsInsertConflictHandlingSafe(shardOid))
	{
		return;
	}

	/*
	 * Constraint-backed indexes report a constraint name, while standalone
	 * unique indexes report their relation name.
	 */

	bool missing_ok = true;
	Oid constraintOid = get_relation_constraint_oid(shardOid,
													errorData->constraint_name,
													missing_ok);
	Oid arbiterIndexOid = constraintOid == InvalidOid ?
						  get_relname_relid(errorData->constraint_name,
											get_rel_namespace(shardOid)) :
						  get_constraint_index(constraintOid);
	if (arbiterIndexOid == InvalidOid)
	{
		return;
	}

	Relation indexRelation = RelationIdGetRelation(arbiterIndexOid);
	if (indexRelation == NULL || indexRelation->rd_index == NULL ||
		indexRelation->rd_index->indrelid != shardOid ||
		!indexRelation->rd_index->indimmediate)
	{
		if (indexRelation != NULL)
		{
			RelationClose(indexRelation);
		}
		return;
	}

	const char *postgresIndexName = RelationGetRelationName(indexRelation);
	const char *resolvedIndexName = GetIndexNameWithCache(
		postgresIndexName, targetContext, indexNameCache);

	RelationClose(indexRelation);

	if (resolvedIndexName == NULL)
	{
		return;
	}

	MemoryContext oldContext = MemoryContextSwitchTo(targetContext);
	char *indexName = pstrdup(resolvedIndexName);
	MemoryContextSwitchTo(oldContext);

	conflictState->arbiterIndexOid = arbiterIndexOid;
	conflictState->indexName = indexName;
	conflictState->isValid = true;
}


/*
 * Builds the duplicate error suppressed by ON CONFLICT DO NOTHING for one
 * skipped input.
 */
WriteError *
BuildInsertConflictWriteError(int writeErrorIndex,
							  const InsertConflictState *conflictState)
{
	WriteError *writeError = palloc0(sizeof(WriteError));

	writeError->index = writeErrorIndex;
	writeError->code = ERRCODE_DOCUMENTDB_DUPLICATEKEY;
	writeError->errmsg = psprintf("Duplicate key violation on the requested collection: "
								  "Index '%s'", conflictState->indexName);

	return writeError;
}


/*
 * Changes a direct insert plan to use ON CONFLICT DO NOTHING for the learned
 * arbiter and optionally wraps its input to capture which rows PostgreSQL skips.
 */
void
ModifyInsertPlanWithOnConflict(PlannedStmt *stmt, Oid arbiterIndexOid,
							   bool captureSkippedIndexes)
{
	ModifyTable *modifyTable;

	if (stmt->planTree == NULL || !IsA(stmt->planTree, ModifyTable))
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("expected an insert ModifyTable plan")));
	}

	modifyTable = castNode(ModifyTable, stmt->planTree);
	if (modifyTable->operation != CMD_INSERT)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("expected an insert operation")));
	}

	if (arbiterIndexOid == InvalidOid)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("cannot configure conflict handling without an arbiter index")));
	}

	modifyTable->onConflictAction = ONCONFLICT_NOTHING;

	/*
	 * The learned arbiter intentionally determines the reported duplicate if
	 * one input conflicts with multiple arbiter indexes.
	 */
	modifyTable->arbiterIndexes = list_make1_oid(arbiterIndexOid);
	if (captureSkippedIndexes)
	{
		modifyTable->plan.lefttree = WrapPlanWithInsertConflictCaptureScan(
			modifyTable->plan.lefttree);
	}
}


/*
 * Copies skipped positions into the caller's context before executor teardown
 * releases the CustomScan state.
 */
List *
CopyInsertConflictSkippedIndexes(PlanState *modifyTableState,
								 MemoryContext targetContext)
{
	PlanState *capturePlanState = outerPlanState(modifyTableState);
	if (capturePlanState == NULL || !IsA(capturePlanState, CustomScanState) ||
		((CustomScanState *) capturePlanState)->methods !=
		&InsertConflictCaptureExecMethods)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("insert conflict capture scan is not available")));
	}

	InsertConflictCaptureScanState *captureState =
		(InsertConflictCaptureScanState *) capturePlanState;
	MemoryContext oldContext = MemoryContextSwitchTo(targetContext);
	List *skippedIndexes = list_copy(captureState->skippedIndexes);
	MemoryContextSwitchTo(oldContext);

	return skippedIndexes;
}


/*
 * Adds a pass-through CustomScan that infers each input's outcome from the
 * command's processed-row count when ModifyTable requests its next input.
 */
static Plan *
WrapPlanWithInsertConflictCaptureScan(Plan *childPlan)
{
	Assert(childPlan != NULL && IsA(childPlan, ValuesScan));
	CustomScan *customScan = makeNode(CustomScan);
	customScan->methods = &InsertConflictCaptureScanMethods;
	customScan->scan.scanrelid = 0;
	customScan->scan.plan.startup_cost = childPlan->startup_cost;
	customScan->scan.plan.total_cost = childPlan->total_cost;
	customScan->scan.plan.plan_rows = childPlan->plan_rows;
	customScan->scan.plan.plan_width = childPlan->plan_width;
	customScan->custom_plans = list_make1(childPlan);
	customScan->custom_scan_tlist = copyObject(childPlan->targetlist);

	/* Project each child column through the CustomScan without changing it. */
	List *targetList = NIL;
	int scanAttributeNumber = 1;
	ListCell *cell;
	foreach(cell, childPlan->targetlist)
	{
		TargetEntry *childEntry = castNode(TargetEntry, lfirst(cell));
		Expr *childExpression = childEntry->expr;

		/* Scan tuple positions are consecutive; resno can skip dropped columns. */
		Var *scanVar = makeVar(INDEX_VAR, scanAttributeNumber,
							   exprType((Node *) childExpression),
							   exprTypmod((Node *) childExpression),
							   exprCollation((Node *) childExpression), 0);

		targetList = lappend(targetList,
							 makeTargetEntry((Expr *) scanVar,
											 childEntry->resno,
											 childEntry->resname == NULL
											 ? NULL
											 : pstrdup(childEntry->resname),
											 childEntry->resjunk));
		scanAttributeNumber++;
	}

	customScan->scan.plan.targetlist = targetList;
	return &customScan->scan.plan;
}


static Node *
InsertConflictCaptureCreateScanState(CustomScan *customScan)
{
	InsertConflictCaptureScanState *state =
		(InsertConflictCaptureScanState *) newNode(
			sizeof(InsertConflictCaptureScanState), T_CustomScanState);

	state->customScanState.methods = &InsertConflictCaptureExecMethods;
	return (Node *) state;
}


static void
InsertConflictCaptureBeginScan(CustomScanState *node, EState *estate, int eflags)
{
	InsertConflictCaptureScanState *state = (InsertConflictCaptureScanState *) node;
	CustomScan *customScan = castNode(CustomScan, node->ss.ps.plan);
	Plan *childPlan = linitial(customScan->custom_plans);

	/* CustomScan providers initialize children; custom_ps exposes them to EXPLAIN. */
	state->childPlanState = ExecInitNode(childPlan, estate, eflags);
	state->lastSeenEsProcessed = estate->es_processed;
	node->custom_ps = list_make1(state->childPlanState);
}


static TupleTableSlot *
InsertConflictCaptureExecScan(CustomScanState *node)
{
	InsertConflictCaptureScanState *state = (InsertConflictCaptureScanState *) node;

	/*
	 * A row's result is visible in es_processed on the next scan call.
	 * Classify the previous row here; the end-of-input call classifies the
	 * final row.
	 */
	if (state->nextInputIndex > 0)
	{
		uint64 currentEsProcessed = node->ss.ps.state->es_processed;
		if (currentEsProcessed == state->lastSeenEsProcessed)
		{
			state->skippedIndexes = lappend_int(state->skippedIndexes,
												state->nextInputIndex - 1);
		}
		else if (currentEsProcessed != state->lastSeenEsProcessed + 1)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("inconsistent insert processed-row count")));
		}
		state->lastSeenEsProcessed = currentEsProcessed;
	}

	TupleTableSlot *slot = ExecProcNode(state->childPlanState);
	if (!TupIsNull(slot))
	{
		state->nextInputIndex++;
	}
	return slot;
}


static void
InsertConflictCaptureEndScan(CustomScanState *node)
{
	InsertConflictCaptureScanState *state = (InsertConflictCaptureScanState *) node;

	if (state->childPlanState != NULL)
	{
		ExecEndNode(state->childPlanState);
		state->childPlanState = NULL;
	}
}


static void
InsertConflictCaptureReScan(CustomScanState *node)
{
	InsertConflictCaptureScanState *state = (InsertConflictCaptureScanState *) node;

	state->nextInputIndex = 0;
	state->lastSeenEsProcessed = node->ss.ps.state->es_processed;
	list_free(state->skippedIndexes);
	state->skippedIndexes = NIL;
	if (state->childPlanState != NULL)
	{
		ExecReScan(state->childPlanState);
	}
}
