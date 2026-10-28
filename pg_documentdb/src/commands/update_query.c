/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * Native UPDATE construction and execution for update-all operations.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/sysattr.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/namespace.h"
#include "catalog/pg_aggregate.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/optimizer.h"
#include "parser/parse_func.h"
#include "parser/parse_relation.h"
#include "tcop/pquery.h"
#include "tcop/tcopprot.h"
#include "tcop/utility.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/portal.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include "api_hooks.h"
#include "commands/commands_common.h"
#include "commands/update_query.h"
#include "metadata/metadata_cache.h"
#include "query/query_operator.h"
#include "utils/docdb_make_funcs.h"
#include "utils/documentdb_pg_compatibility.h"
#include "utils/guc_utils.h"
#include "utils/version_utils.h"

typedef enum UpdateParameterName
{
	UpdateParameter_Query,
	UpdateParameter_Update,
	UpdateParameter_ArrayFilters,
	UpdateParameter_Variables,
	UpdateParameter_Collation,

	/* Always add all the parameters before this */
	UpdateParameter_Max
} UpdateParameterName;

typedef enum UpdateBaseTableVar
{
	UpdateBaseTableVar_SelfItemPointer,
	UpdateBaseTableVar_TableOid,
	UpdateBaseTableVar_ShardKey,
	UpdateBaseTableVar_Document,

	/* Always add all the base table vars before this */
	UpdateBaseTableVar_Max
} UpdateBaseTableVar;

typedef struct UpdateAstContext
{
	const UpdateAllQuerySpec *spec;
	pgbson *queryDocument;
	pgbson *variables;

	/*
	 * Below context specifies how we should construct and execute the update query.
	 */
	bool applyCollation;
	bool useVariableSpecOrCollationArgs;
	bool useCommutativeWrites;
	bool useDirectUpdate;

	/* Query AST and related structures, base table VARs for multiple references
	 * parameter bindings for the update query etc
	 */
	List *bindings;
	Expr *parameters[UpdateParameter_Max];
	Query *baseTableVarQuery;
	Var *baseTableVars[UpdateBaseTableVar_Max];
} UpdateAstContext;

extern bool EnableUpdateManyWorkerPushdown;
extern bool EnableCommutativeUpdateMany;
extern int NumBsonDocumentsUpdated;

static Query * BuildUpdateManyQueryAst(UpdateAstContext *context);
static Expr * UpdateParameter(UpdateAstContext *context, UpdateParameterName name);
static Query * MakeQueryNode(CmdType commandType);
static void AddUpdateRelation(Query *query, const UpdateAllQuerySpec *spec);
static void PopulateUpdateRelation(Query *query, Relation relation, const
								   char *tableName);
static Var * UpdateRelationVar(Query *query, UpdateAstContext *context,
							   UpdateBaseTableVar column);
static Var * UpdateCteTargetVar(Index relation, TargetEntry *entry);
static Expr * BuildUpdateQuals(UpdateAstContext *context, Query *query);
static Expr * BuildDocumentTransformation(UpdateAstContext *context, Query *query);
static CommonTableExpr * MakeUpdateCte(const char *name, Query *query);
static Index AddUpdateCteReference(Query *query, CommonTableExpr *cte, Index levelsUp);
static Aggref * BuildUpdateAggregate(const char *name, Expr *argument);
static Query * BuildBaseUpdateManyQuery(UpdateAstContext *context);
static Query * BuildUpdateManyResultQuery(UpdateAstContext *context, Query *update);
static uint64 ExecuteUpdateManyQueryAst(Query *query, ParamListInfo params,
										bool commutativeWrites);


/*
 * Native execution owns no SQL templates or prepared-plan keys. Keep the legacy
 * fallback at the caller, before planning or executing any part of the write.
 */
UpdateAllMatchingDocsResult
PerformUpdateAll(const UpdateAllQuerySpec *spec)
{
	if (UpdateQueryHasFlag(spec, UPDATE_QUERY_FLAG_HAS_OBJECT_ID) &&
		!UpdateQueryHasFlag(spec, UPDATE_QUERY_FLAG_HAS_NON_ID_FILTERS))
	{
		/* This is unexpected ! */
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
				 errmsg("object-ID-only updates must use legacy execution")));
	}

	UpdateAstContext context = { 0 };
	context.spec = spec;
	context.queryDocument = PgbsonInitFromDocumentBsonValue(spec->updateParams->query);
	context.applyCollation = IsCollationApplicable(spec->updateParams->collationString);

	if (spec->updateParams->variableSpec != NULL &&
		spec->updateParams->variableSpec->value_type == BSON_TYPE_DOCUMENT)
	{
		context.variables = PgbsonInitFromDocumentBsonValue(
			spec->updateParams->variableSpec);
	}
	else if (context.applyCollation)
	{
		context.variables = PgbsonInitEmpty();
	}

	context.useVariableSpecOrCollationArgs = context.variables != NULL ||
											 context.applyCollation;

	Query *query = BuildUpdateManyQueryAst(&context);

	/* Add the all the parameters that are referenced in the query AST */
	ParamListInfo params = makeParamList(list_length(context.bindings));
	int index = 0;
	ListCell *cell;
	foreach(cell, context.bindings)
	{
		params->params[index++] = *((ParamExternData *) lfirst(cell));
	}

	if (spec->collection->shardTableName[0] != '\0')
	{
		/* Reset the Documents Update counter before executing the update on the local shard */
		NumBsonDocumentsUpdated = 0;
	}

	bool commutativeWrites = spec->collection->shardKey != NULL &&
							 EnableCommutativeUpdateMany;
	uint64 processed = ExecuteUpdateManyQueryAst(query, params, commutativeWrites);

	UpdateAllMatchingDocsResult result = { 0 };
	if (context.useDirectUpdate)
	{
		result.matchedDocs = processed;
		result.rowsUpdated = NumBsonDocumentsUpdated;
	}
	else if (processed > 0)
	{
		bool isNull = false;
		Datum matched = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
									  1, &isNull);
		if (isNull)
		{
			ereport(ERROR,
					(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
					 errmsg("native update matched count must not be null")));
		}
		result.matchedDocs = DatumGetUInt64(matched);
		Datum modified = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
									   2, &isNull);
		result.rowsUpdated = isNull ? 0 : DatumGetUInt64(modified);
	}
	return result;
}


/*
 * Build one UPDATE shape, adding the result-count wrapper only when the direct
 * worker path cannot supply matched and modified counts.
 */
static Query *
BuildUpdateManyQueryAst(UpdateAstContext *context)
{
	const UpdateAllQuerySpec *spec = context->spec;
	bool isLocalShard = spec->collection->shardTableName[0] != '\0';

	Query *update = BuildBaseUpdateManyQuery(context);

	/* whether we have enough information to run this as a direct update on this shard. */
	context->useDirectUpdate = isLocalShard && EnableUpdateManyWorkerPushdown;
	if (context->useDirectUpdate)
	{
		return update;
	}
	return BuildUpdateManyResultQuery(context, update);
}


/*
 * Allocate bindings by semantic name. The original query remains bound to the
 * document transformation even though matching is expanded during construction.
 */
static Expr *
UpdateParameter(UpdateAstContext *context, UpdateParameterName name)
{
	if (context->parameters[name] == NULL)
	{
		const UpdateAllQuerySpec *spec = context->spec;
		pgbson *bson = NULL;
		Oid type = BsonTypeId();
		Datum value = (Datum) 0;
		bool isNull = false;
		bool relabelBson = false;
		switch (name)
		{
			case UpdateParameter_Query:
			{
				bson = context->queryDocument;
				break;
			}

			case UpdateParameter_Update:
			{
				bson = BsonValueToDocumentPgbson(spec->updateParams->update);
				type = BYTEAOID;
				relabelBson = true;
				break;
			}

			case UpdateParameter_ArrayFilters:
			{
				bson = spec->updateParams->arrayFilters == NULL ? NULL :
					   BsonValueToDocumentPgbson(spec->updateParams->arrayFilters);
				type = BYTEAOID;
				isNull = bson == NULL;
				relabelBson = true;
				break;
			}

			case UpdateParameter_Variables:
			{
				bson = context->variables;
				isNull = bson == NULL;
				break;
			}

			case UpdateParameter_Collation:
			{
				type = TEXTOID;
				value = CStringGetTextDatum(context->applyCollation ?
											spec->updateParams->collationString : "");
				break;
			}

			default:
				ereport(ERROR,
						(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						 errmsg("unrecognized update parameter")));
		}
		if (bson != NULL)
		{
			value = type == BYTEAOID ? PointerGetDatum(CastPgbsonToBytea(bson)) :
					PointerGetDatum(bson);
		}
		ParamExternData *binding = palloc0(sizeof(ParamExternData));
		binding->ptype = type;
		binding->value = value;
		binding->isnull = isNull;
		binding->pflags = PARAM_FLAG_CONST;
		context->bindings = lappend(context->bindings, binding);

		Param *parameter = makeNode(Param);
		parameter->paramkind = PARAM_EXTERN;
		parameter->paramid = list_length(context->bindings);
		parameter->paramtype = type;
		parameter->paramtypmod = -1;
		parameter->paramcollid = get_typcollation(type);
		parameter->location = -1;
		context->parameters[name] = relabelBson ?
									(Expr *) makeRelabelType((Expr *) parameter,
															 BsonTypeId(), -1, InvalidOid,
															 COERCE_EXPLICIT_CAST) :
									(Expr *) parameter;
	}

	/* Each occurrence must own its node because planning can mutate it. */
	return copyObject(context->parameters[name]);
}


/*
 * Creates a new Query node with given commandType.
 * The returned Query object is initialized with the basic components needed for an UPDATE operation.
 */
static Query *
MakeQueryNode(CmdType commandType)
{
	Query *query = makeNode(Query);
	query->commandType = commandType;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;
	query->jointree = makeFromExpr(NIL, NULL);
	return query;
}


/*
 * Adds the target relation for the UPDATE query.
 * This includes setting up the range table entry, result relation, and join tree.
 */
static void
AddUpdateRelation(Query *query, const UpdateAllQuerySpec *spec)
{
	const MongoCollection *collection = spec->collection;
	const char *tableName = collection->shardTableName[0] != '\0' ?
							collection->shardTableName : collection->tableName;

	/*
	 * TODO: populate shardOid consistently in all collection-cache paths when a
	 * local shard is found, then use that cached OID here.
	 */
	RangeVar *rangeVar = makeRangeVar(ApiDataSchemaName, pstrdup(tableName), -1);

	/*
	 * Native queries bypass parse analysis, which normally acquires this lock.
	 * The executor expects the target's write lock to be held already.
	 */
	Relation relation = table_openrv(rangeVar, RowExclusiveLock);
	PopulateUpdateRelation(query, relation, tableName);

	/* Hold the write lock through execution. */
	table_close(relation, NoLock);
}


static void
PopulateUpdateRelation(Query *query, Relation relation, const char *tableName)
{
	List *columnNames = NIL;
	for (int index = 0; index < RelationGetDescr(relation)->natts; index++)
	{
		Form_pg_attribute attribute = TupleDescAttr(RelationGetDescr(relation), index);
		columnNames = lappend(columnNames, makeString(pstrdup(
														  attribute->attisdropped ? "" :
														  NameStr(attribute->attname))));
	}

	RangeTblEntry *rte = makeNode(RangeTblEntry);
	rte->rtekind = RTE_RELATION;
	rte->relid = RelationGetRelid(relation);
	rte->relkind = relation->rd_rel->relkind;
	rte->rellockmode = RowExclusiveLock;
	rte->inh = true;
	rte->eref = makeAlias(pstrdup(tableName), columnNames);
	query->rtable = list_make1(rte);
	query->resultRelation = 1;
#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permissions = addRTEPermissionInfo(&query->rteperminfos, rte);
#else
	RangeTblEntry *permissions = rte;
#endif

	/*
	 * TODO: with EnableGranularRbac we should be able to do updateMany correctly in terms of perms
	 */
	permissions->requiredPerms = ACL_SELECT | ACL_UPDATE;
	permissions->updatedCols = bms_make_singleton(
		DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER -
		FirstLowInvalidHeapAttributeNumber);

	RangeTblRef *reference = makeNode(RangeTblRef);
	reference->rtindex = 1;
	query->jointree->fromlist = list_make1(reference);
}


/*
 * Gets the VAR nodes for the specified base table columns in the UPDATE query.
 * If the VAR is already created, it returns the existing VAR node.
 */
static Var *
UpdateRelationVar(Query *query, UpdateAstContext *context, UpdateBaseTableVar column)
{
	if (context->baseTableVarQuery == NULL)
	{
		/* First time initialization for the base table VARs and query assignment */
		memset(context->baseTableVars, 0, sizeof(context->baseTableVars));
		context->baseTableVarQuery = query;
	}

	if (context->baseTableVarQuery != query)
	{
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
				 errmsg(
					 "Multiple base queries are not supported for update query tree generation")));
	}
	if (context->baseTableVars[column] != NULL)
	{
		return context->baseTableVars[column];
	}
	AttrNumber attribute;
	switch (column)
	{
		case UpdateBaseTableVar_SelfItemPointer:
		{
			attribute = SelfItemPointerAttributeNumber;
			break;
		}

		case UpdateBaseTableVar_TableOid:
		{
			attribute = TableOidAttributeNumber;
			break;
		}

		case UpdateBaseTableVar_ShardKey:
		{
			attribute = DOCUMENT_DATA_TABLE_SHARD_KEY_VALUE_VAR_ATTR_NUMBER;
			break;
		}

		case UpdateBaseTableVar_Document:
		{
			attribute = DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER;
			break;
		}

		default:
			ereport(ERROR,
					(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
					 errmsg("unrecognized update column	for query tree generation")));
	}
	RangeTblEntry *rte = linitial(query->rtable);
#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permissions = list_nth(query->rteperminfos,
											  rte->perminfoindex - 1);
#else
	RangeTblEntry *permissions = rte;
#endif
	permissions->selectedCols = bms_add_member(permissions->selectedCols,
											   attribute -
											   FirstLowInvalidHeapAttributeNumber);
	Oid type;
	int32 typmod;
	Oid collation;
	get_atttypetypmodcoll(rte->relid, attribute, &type, &typmod, &collation);
	context->baseTableVars[column] = makeVar(1, attribute, type, typmod, collation, 0);
	return context->baseTableVars[column];
}


/*
 * Creates a Var node for the target entry of the source CTE reference
 */
static Var *
UpdateCteTargetVar(Index relation, TargetEntry *entry)
{
	return makeVar(relation, entry->resno, exprType((Node *) entry->expr),
				   exprTypmod((Node *) entry->expr), exprCollation((Node *) entry->expr),
				   0);
}


/*
 * Match the original document using the same expansion as query operators.
 * The transformation retains all request parameters, so expansion cannot leave
 * unused bindings for distributed execution.
 */
static Expr *
BuildUpdateQuals(UpdateAstContext *context, Query *query)
{
	BsonQueryOperatorContext queryContext;
	memset(&queryContext, 0, sizeof(BsonQueryOperatorContext));

	queryContext.documentExpr = (Expr *) UpdateRelationVar(query, context,
														   UpdateBaseTableVar_Document);
	if (context->variables != NULL)
	{
		queryContext.variableContext = (Expr *) MakeBsonConst(context->variables);
	}
	if (context->applyCollation)
	{
		queryContext.collationString = context->spec->updateParams->collationString;
	}

	/* The target is a physical relation, not a parameterized collection RTE. */
	ParamListInfo boundParams = NULL;
	List *quals = CreateQualsForBsonQuery(context->queryDocument, &queryContext,
										  query, boundParams);
	UpdateQueryOperatorContextSortList(query, queryContext.sortClauses,
									   queryContext.targetEntries);
	Expr *qual = make_ands_explicit(quals);

	/* Key Vars introduced by expansion also require column read permissions. */
#if PG_VERSION_NUM >= 160000
	RangeTblEntry *rte = linitial(query->rtable);
	RTEPermissionInfo *permissions = list_nth(query->rteperminfos,
											  rte->perminfoindex - 1);
#else
	RangeTblEntry *permissions = linitial(query->rtable);
#endif
	pull_varattnos((Node *) qual, query->resultRelation, &permissions->selectedCols);
	return qual;
}


/*
 * Builds the document transformation expression for the UPDATE query.
 * SET document = COALESCE(update_bson_document(...), document)
 */
static Expr *
BuildDocumentTransformation(UpdateAstContext *context, Query *query)
{
	Expr *variables = context->useVariableSpecOrCollationArgs ?
					  UpdateParameter(context, UpdateParameter_Variables) :
					  (Expr *) makeNullConst(BsonTypeId(), -1, InvalidOid);
	Expr *collation = context->useVariableSpecOrCollationArgs ?
					  UpdateParameter(context, UpdateParameter_Collation) :
					  (Expr *) makeNullConst(TEXTOID, -1, get_typcollation(TEXTOID));
	List *arguments = list_make5(UpdateRelationVar(query, context,
												   UpdateBaseTableVar_Document),
								 UpdateParameter(context, UpdateParameter_Update),
								 UpdateParameter(context, UpdateParameter_Query),
								 UpdateParameter(context, UpdateParameter_ArrayFilters),
								 variables);
	arguments = lappend(arguments, collation);
	Oid updateFunctionOid = UpdateBsonDocumentFunctionOid();
	if (IsClusterVersionAtleast(DocDB_V0, 111, 0) &&
		context->spec->collection->options.updateDescriptionEnabled)
	{
		/* Use the update_bson_document overload with update description */
		updateFunctionOid = UpdateBsonDocumentWithDescriptionFunctionOid();
		arguments = lappend(arguments, UpdateRelationVar(query, context,
														 UpdateBaseTableVar_SelfItemPointer));
		arguments = lappend(arguments, UpdateRelationVar(query, context,
														 UpdateBaseTableVar_TableOid));
	}

	FuncExpr *updateBsonFunc = makeFuncExpr(updateFunctionOid,
											BsonTypeId(), arguments, InvalidOid,
											InvalidOid,
											COERCE_EXPLICIT_CALL);
	CoalesceExpr *coalesce = makeNode(CoalesceExpr);
	coalesce->coalescetype = BsonTypeId();
	coalesce->args = list_make2(updateBsonFunc, UpdateRelationVar(query, context,
																  UpdateBaseTableVar_Document));
	coalesce->location = -1;
	return (Expr *) coalesce;
}


/*
 * Creates a Common Table Expression (CTE) for the given UPDATE query.
 * The CTE can be used to reference the updated rows in subsequent parts of the query.
 */
static CommonTableExpr *
MakeUpdateCte(const char *name, Query *query)
{
	CommonTableExpr *cte = makeNode(CommonTableExpr);
	cte->ctename = pstrdup(name);
	cte->ctematerialized = CTEMaterializeDefault;
	cte->ctequery = (Node *) query;
	cte->location = -1;
	query->canSetTag = false;
	List *outputs = query->commandType == CMD_SELECT ? query->targetList :
					query->returningList;
	ListCell *cell;
	foreach(cell, outputs)
	{
		TargetEntry *entry = lfirst(cell);
		if (entry->resjunk)
		{
			continue;
		}
		cte->ctecolnames = lappend(cte->ctecolnames, makeString(pstrdup(entry->resname)));
		cte->ctecoltypes = lappend_oid(cte->ctecoltypes, exprType((Node *) entry->expr));
		cte->ctecoltypmods = lappend_int(cte->ctecoltypmods, exprTypmod(
											 (Node *) entry->expr));
		cte->ctecolcollations = lappend_oid(cte->ctecolcollations,
											exprCollation((Node *) entry->expr));
	}
	return cte;
}


/*
 * Adds a reference to the given CTE in the specified query.
 * Returns the range table index of the added reference.
 */
static Index
AddUpdateCteReference(Query *query, CommonTableExpr *cte, Index levelsUp)
{
	RangeTblEntry *rte = makeNode(RangeTblEntry);
	rte->rtekind = RTE_CTE;
	rte->ctename = pstrdup(cte->ctename);
	rte->ctelevelsup = levelsUp;
	rte->inFromCl = true;
	rte->eref = makeAlias(pstrdup(cte->ctename), copyObject(cte->ctecolnames));
	rte->coltypes = list_copy(cte->ctecoltypes);
	rte->coltypmods = list_copy(cte->ctecoltypmods);
	rte->colcollations = list_copy(cte->ctecolcollations);
	query->rtable = lappend(query->rtable, rte);
	cte->cterefcount++;
	RangeTblRef *reference = makeNode(RangeTblRef);
	reference->rtindex = list_length(query->rtable);
	query->jointree->fromlist = lappend(query->jointree->fromlist, reference);
	return reference->rtindex;
}


/*
 * Update Aggregation builder used for creating the query structure for reporting matched and modified rows.
 */
static Aggref *
BuildUpdateAggregate(const char *name, Expr *argument)
{
	Oid argumentType = argument == NULL ? InvalidOid : exprType((Node *) argument);
	List *functionName = list_make2(makeString("pg_catalog"), makeString(pstrdup(name)));
	bool missingOk = false;
	Aggref *aggregate = makeNode(Aggref);
	aggregate->aggfnoid = LookupFuncName(functionName, argument == NULL ? 0 : 1,
										 &argumentType, missingOk);
	aggregate->aggtype = INT8OID;
	aggregate->aggtranstype = InvalidOid;
	aggregate->aggkind = AGGKIND_NORMAL;
	aggregate->aggsplit = AGGSPLIT_SIMPLE;
	aggregate->aggno = -1;
	aggregate->aggtransno = -1;
	aggregate->location = -1;
	aggregate->aggstar = argument == NULL;
	if (argument != NULL)
	{
		aggregate->aggargtypes = list_make1_oid(exprType((Node *) argument));
		aggregate->args = list_make1(makeTargetEntry(argument, 1, NULL, false));
	}
	return aggregate;
}


/*
 * Builds the base UPDATE query and returns it with document transformation and query filters applied.
 */
static Query *
BuildBaseUpdateManyQuery(UpdateAstContext *context)
{
	Query *update = MakeQueryNode(CMD_UPDATE);
	AddUpdateRelation(update, context->spec);
	update->targetList = list_make1(makeTargetEntry(
										BuildDocumentTransformation(context, update),
										DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER,
										"document", false));
	update->jointree->quals = (Node *) BuildUpdateQuals(context, update);
	return update;
}


/*
 * Augments the update query with a result query that includes matched and modified counts.
 */
static Query *
BuildUpdateManyResultQuery(UpdateAstContext *context, Query *update)
{
	/* This function reads transformation state, so it must stay in RETURNING. */
	Var *shardKeyVar = UpdateRelationVar(update, context,
										 UpdateBaseTableVar_ShardKey);
	FuncExpr *returned = makeFuncExpr(BsonUpdateReturnedValueFunctionOid(), INT4OID,
									  list_make1(shardKeyVar),
									  InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);

	TargetEntry *updated = makeTargetEntry((Expr *) returned, 1, "updated", false);
	update->returningList = list_make1(updated);

	CommonTableExpr *updateCte = MakeUpdateCte("u", update);
	Query *result = MakeQueryNode(CMD_SELECT);
	result->cteList = list_make1(updateCte);
	result->hasModifyingCTE = true;
	result->hasAggs = true;

	/* This is at the same level now */
	int levelsup = 0;
	Index source = AddUpdateCteReference(result, updateCte, levelsup);

	Expr *matchedCount = (Expr *) BuildUpdateAggregate("count", NULL);
	Expr *modifiedCount = (Expr *) BuildUpdateAggregate("sum",
														(Expr *) UpdateCteTargetVar(
															source, updated));
	result->targetList = list_make2(
		makeTargetEntry(matchedCount, 1, "total_count", false),
		makeTargetEntry(modifiedCount, 2, "sum", false));

	return result;
}


/*
 * Plan the final operation-owned query directly, preserving write-capable snapshots.
 * The fresh operation-owned tree is never put in the SQL prepared-plan cache.
 */
static uint64
ExecuteUpdateManyQueryAst(Query *query, ParamListInfo params, bool commutativeWrites)
{
	CmdType commandType = query->commandType;
	CommandTag commandTag = CreateCommandTag((Node *) query);
	int cursorOptions = CURSOR_OPT_NO_SCROLL | CURSOR_OPT_BINARY;
	int savedGUCLevel = commutativeWrites ? NewGUCNestLevel() : 0;
	MemoryContext callerContext = CurrentMemoryContext;
	uint64 processed = 0;

	if (commutativeWrites)
	{
		AllowCommutativeWritesInCurrentTransaction();
	}
	EnsurePortalSnapshotExists();
	PlannedStmt *plan = PgPlanQueryCompat(query, NULL, cursorOptions, params);
	Portal portal = CreateNewPortal();
	portal->visible = false;
	portal->cursorOptions = cursorOptions;
	PortalDefineQuery(portal, NULL, "", commandTag, list_make1(plan), NULL);

	CommandCounterIncrement();
	PushActiveSnapshot(GetTransactionSnapshot());
	PortalStart(portal, params, 0, GetActiveSnapshot());
	if (commandType == CMD_SELECT)
	{
		bool forward = true;
		SPI_cursor_fetch(portal, forward, FETCH_ALL);
		processed = SPI_processed;
	}
	else
	{
		QueryCompletion completion;
		bool isTopLevel = false;
		bool runOnce = true;
		InitializeQueryCompletion(&completion);
		PortalRunCompat(portal, FETCH_ALL, isTopLevel, runOnce,
						None_Receiver, None_Receiver, &completion);
		processed = completion.nprocessed;
	}
	MemoryContextSwitchTo(callerContext);
	SPI_cursor_close(portal);
	CommandCounterIncrement();
	PopActiveSnapshot();
	if (commutativeWrites)
	{
		RollbackGUCChange(savedGUCLevel);
	}

	/* Failed writes propagate to transaction cleanup; never replay through SQL. */
	return processed;
}
