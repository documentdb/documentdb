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
#include "parser/parsetree.h"
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
#include "schema_validation/schema_validation.h"
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
	UpdateParameter_Validator,

	/* Always add all the parameters before this */
	UpdateParameter_Max
} UpdateParameterName;

typedef enum UpdateBaseTableVar
{
	UpdateBaseTableVar_SelfItemPointer,
	UpdateBaseTableVar_TableOid,
	UpdateBaseTableVar_ShardKey,
	UpdateBaseTableVar_ObjectId,
	UpdateBaseTableVar_Document,

	/* Always add all the base table vars before this */
	UpdateBaseTableVar_Max
} UpdateBaseTableVar;

/* Every query built here references the collection table at this range table index. */
#define UPDATE_BASE_TABLE_RTINDEX 1

/*
 * Base table VARs and column permissions are tracked per query: each Query owns
 * its range table and permission info, so VARs are never shared across queries.
 */
typedef struct UpdateQueryVars
{
	Query *query;
	Var *vars[UpdateBaseTableVar_Max];
} UpdateQueryVars;

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

	List *schemaValidationCTEs;
	Expr *matchedCount;

	/* Parameter bindings shared by all queries in the update query tree */
	List *bindings;
	Expr *parameters[UpdateParameter_Max];
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
static Var * UpdateRelationVar(UpdateQueryVars *queryVars, UpdateBaseTableVar column);
static Var * UpdateCteTargetVar(Index relation, TargetEntry *entry);
static Expr * BuildUpdateQuals(UpdateAstContext *context, UpdateQueryVars *queryVars);
static Expr * BuildDocumentTransformation(UpdateAstContext *context,
										  UpdateQueryVars *queryVars);
static CommonTableExpr * MakeUpdateCte(const char *name, Query *query);
static Index AddUpdateCteReference(Query *query, CommonTableExpr *cte, Index levelsUp);
static Aggref * BuildUpdateAggregate(const char *name, Expr *argument);
static Query * BuildUpdateManySourceQuery(Query *update);
static void ApplySchemaValidationToUpdateMany(UpdateAstContext *context,
											  UpdateQueryVars *updateVars);
static Query * BuildUpdateManyResultQuery(UpdateAstContext *context,
										  UpdateQueryVars *updateVars);
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

	/* Match the legacy validation path, which does not use commutative writes. */
	bool commutativeWrites = spec->collection->shardKey != NULL &&
							 EnableCommutativeUpdateMany &&
							 context.schemaValidationCTEs == NIL;
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
 * Build matching and transformation once, then layer validation and result counts
 * over the same UPDATE rather than maintaining independent query shapes.
 */
static Query *
BuildUpdateManyQueryAst(UpdateAstContext *context)
{
	const UpdateAllQuerySpec *spec = context->spec;
	bool isLocalShard = spec->collection->shardTableName[0] != '\0';
	bool validate = EnableSchemaValidation && spec->schemaValidator != NULL;

	Query *update = MakeQueryNode(CMD_UPDATE);
	AddUpdateRelation(update, spec);
	UpdateQueryVars updateVars = { .query = update };

	if (validate)
	{
		/* Matching and transformation are built in the validated source query. */
		ApplySchemaValidationToUpdateMany(context, &updateVars);
		return BuildUpdateManyResultQuery(context, &updateVars);
	}

	update->targetList = list_make1(makeTargetEntry(
										BuildDocumentTransformation(context, &updateVars),
										DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER,
										"document", false));
	update->jointree->quals = (Node *) BuildUpdateQuals(context, &updateVars);

	/* whether we have enough information to run this as a direct update on this shard. */
	context->useDirectUpdate = isLocalShard && EnableUpdateManyWorkerPushdown;
	if (context->useDirectUpdate)
	{
		return update;
	}
	return BuildUpdateManyResultQuery(context, &updateVars);
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

			case UpdateParameter_Validator:
			{
				bson = spec->schemaValidator;
				type = BsonTypeId();
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
	query->resultRelation = UPDATE_BASE_TABLE_RTINDEX;
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
	reference->rtindex = UPDATE_BASE_TABLE_RTINDEX;
	query->jointree->fromlist = list_make1(reference);
}


/*
 * Gets a VAR for the specified base table column of the query owning queryVars,
 * and records the column read in that query's permission info.
 */
static Var *
UpdateRelationVar(UpdateQueryVars *queryVars, UpdateBaseTableVar column)
{
	Query *query = queryVars->query;
	if (query == NULL || list_length(query->rtable) < UPDATE_BASE_TABLE_RTINDEX)
	{
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
				 errmsg("update query tree has no base table for column references")));
	}

	/* Each occurrence must own its node because planning can mutate it. */
	if (queryVars->vars[column] != NULL)
	{
		return copyObject(queryVars->vars[column]);
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

		case UpdateBaseTableVar_ObjectId:
		{
			attribute = DOCUMENT_DATA_TABLE_OBJECT_ID_VAR_ATTR_NUMBER;
			break;
		}

		default:
			ereport(ERROR,
					(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
					 errmsg("unrecognized update column	for query tree generation")));
	}
	RangeTblEntry *rte = rt_fetch(UPDATE_BASE_TABLE_RTINDEX, query->rtable);
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
	Index levelsUp = 0;
	queryVars->vars[column] = makeVar(UPDATE_BASE_TABLE_RTINDEX, attribute, type,
									  typmod, collation, levelsUp);
	return copyObject(queryVars->vars[column]);
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
BuildUpdateQuals(UpdateAstContext *context, UpdateQueryVars *queryVars)
{
	Query *query = queryVars->query;
	BsonQueryOperatorContext queryContext;
	memset(&queryContext, 0, sizeof(BsonQueryOperatorContext));

	queryContext.documentExpr = (Expr *) UpdateRelationVar(queryVars,
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
	RangeTblEntry *rte = rt_fetch(UPDATE_BASE_TABLE_RTINDEX, query->rtable);
#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permissions = list_nth(query->rteperminfos,
											  rte->perminfoindex - 1);
#else
	RangeTblEntry *permissions = rte;
#endif
	pull_varattnos((Node *) qual, UPDATE_BASE_TABLE_RTINDEX, &permissions->selectedCols);
	return qual;
}


/*
 * Builds the document transformation expression for the UPDATE query.
 * SET document = COALESCE(update_bson_document(...), document)
 */
static Expr *
BuildDocumentTransformation(UpdateAstContext *context, UpdateQueryVars *queryVars)
{
	Expr *variables = context->useVariableSpecOrCollationArgs ?
					  UpdateParameter(context, UpdateParameter_Variables) :
					  (Expr *) makeNullConst(BsonTypeId(), -1, InvalidOid);
	Expr *collation = context->useVariableSpecOrCollationArgs ?
					  UpdateParameter(context, UpdateParameter_Collation) :
					  (Expr *) makeNullConst(TEXTOID, -1, get_typcollation(TEXTOID));
	List *arguments = list_make5(UpdateRelationVar(queryVars,
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
		arguments = lappend(arguments, UpdateRelationVar(queryVars,
														 UpdateBaseTableVar_SelfItemPointer));
		arguments = lappend(arguments, UpdateRelationVar(queryVars,
														 UpdateBaseTableVar_TableOid));
	}

	FuncExpr *updateBsonFunc = makeFuncExpr(updateFunctionOid,
											BsonTypeId(), arguments, InvalidOid,
											InvalidOid,
											COERCE_EXPLICIT_CALL);
	CoalesceExpr *coalesce = makeNode(CoalesceExpr);
	coalesce->coalescetype = BsonTypeId();
	coalesce->args = list_make2(updateBsonFunc, UpdateRelationVar(queryVars,
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
 * Builds a SELECT over the UPDATE's target relation for validated updates. The
 * SELECT owns a copy of the range table and its own read-only permission info,
 * so its VARs and column permissions are tracked by a separate UpdateQueryVars.
 */
static Query *
BuildUpdateManySourceQuery(Query *update)
{
	if (list_length(update->rtable) != 1 ||
		update->resultRelation != UPDATE_BASE_TABLE_RTINDEX)
	{
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
				 errmsg("unexpected base query shape for update source query")));
	}

	Query *filtered = MakeQueryNode(CMD_SELECT);
	filtered->rtable = copyObject(update->rtable);
	RangeTblEntry *sourceRte = rt_fetch(UPDATE_BASE_TABLE_RTINDEX, filtered->rtable);
	sourceRte->rellockmode = AccessShareLock;
	sourceRte->inFromCl = true;
#if PG_VERSION_NUM >= 160000
	filtered->rteperminfos = copyObject(update->rteperminfos);
	RTEPermissionInfo *permissions = list_nth(filtered->rteperminfos,
											  sourceRte->perminfoindex - 1);
#else
	RangeTblEntry *permissions = sourceRte;
#endif
	permissions->requiredPerms = ACL_SELECT;
	permissions->selectedCols = NULL;
	permissions->updatedCols = NULL;

	RangeTblRef *reference = makeNode(RangeTblRef);
	reference->rtindex = UPDATE_BASE_TABLE_RTINDEX;
	filtered->jointree->fromlist = list_make1(reference);
	return filtered;
}


/*
 * Build matching and the new document in filtered_documents, validate its output
 * in v, then join back to the UPDATE by object ID and shard key.
 */
static void
ApplySchemaValidationToUpdateMany(UpdateAstContext *context, UpdateQueryVars *updateVars)
{
	Query *update = updateVars->query;
	UpdateQueryVars filteredVars = { .query = BuildUpdateManySourceQuery(update) };
	Query *filtered = filteredVars.query;

	TargetEntry *filteredObjectId = makeTargetEntry(
		(Expr *) UpdateRelationVar(&filteredVars, UpdateBaseTableVar_ObjectId),
		1, "object_id", false);
	TargetEntry *filteredShardKey = makeTargetEntry(
		(Expr *) UpdateRelationVar(&filteredVars, UpdateBaseTableVar_ShardKey),
		2, "shard_key_value", false);
	TargetEntry *filteredDocument = makeTargetEntry(
		(Expr *) UpdateRelationVar(&filteredVars, UpdateBaseTableVar_Document),
		3, "document", false);
	TargetEntry *newDocument = makeTargetEntry(
		BuildDocumentTransformation(context, &filteredVars), 4, "newdocument", false);
	filtered->targetList = list_make4(filteredObjectId, filteredShardKey,
									  filteredDocument, newDocument);

	/* Sort entries from matching are appended after the projected columns. */
	filtered->jointree->quals = (Node *) BuildUpdateQuals(context, &filteredVars);
	CommonTableExpr *filteredCte = MakeUpdateCte("filtered_documents", filtered);

	/* The result SELECT owns these CTEs; column Vars remain at query level zero. */
	Index cteLevelsUp = 1;
	Query *validation = MakeQueryNode(CMD_SELECT);
	Index source = AddUpdateCteReference(validation, filteredCte, cteLevelsUp);
	TargetEntry *validatedObjectId = makeTargetEntry(
		(Expr *) UpdateCteTargetVar(source, filteredObjectId), 1, "object_id", false);
	TargetEntry *validatedShardKey = makeTargetEntry(
		(Expr *) UpdateCteTargetVar(source, filteredShardKey), 2, "shard_key_value",
		false);
	TargetEntry *validatedDocument = makeTargetEntry(
		(Expr *) UpdateCteTargetVar(source, newDocument), 3, "newdocument", false);

	Expr *validator = UpdateParameter(context, UpdateParameter_Validator);
	bool moderate = context->spec->collection->schemaValidator.validationLevel ==
					ValidationLevel_Moderate;
	List *arguments = list_make4(validator, UpdateCteTargetVar(source, newDocument),
								 UpdateCteTargetVar(source, filteredDocument),
								 makeBoolConst(moderate, false));
	FuncExpr *validate = makeFuncExpr(
		SchemaValidationAgainstUpdateFunctionOid(), BOOLOID,
		arguments, InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);

	/* The volatile validator prevents inlining and must execute even if unused. */
	TargetEntry *validated = makeTargetEntry((Expr *) validate, 4,
											 "schema_validation_against_update", false);
	validation->targetList = list_make4(validatedObjectId, validatedShardKey,
										validatedDocument, validated);
	CommonTableExpr *validationCte = MakeUpdateCte("v", validation);

	source = AddUpdateCteReference(update, validationCte, cteLevelsUp);
	update->targetList = list_make1(makeTargetEntry(
										(Expr *) UpdateCteTargetVar(source,
																	validatedDocument),
										DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER,
										"document", false));

	bool returnsSet = false;
	Expr *objectIdJoin = make_opclause(BsonEqualOperatorId(), BOOLOID, returnsSet,
									   (Expr *) UpdateRelationVar(updateVars,
																  UpdateBaseTableVar_ObjectId),
									   (Expr *) UpdateCteTargetVar(source,
																   validatedObjectId),
									   InvalidOid, InvalidOid);
	Expr *shardKeyJoin = make_opclause(BigintEqualOperatorId(), BOOLOID, returnsSet,
									   (Expr *) UpdateRelationVar(updateVars,
																  UpdateBaseTableVar_ShardKey),
									   (Expr *) UpdateCteTargetVar(source,
																   validatedShardKey),
									   InvalidOid, InvalidOid);
	update->jointree->quals = (Node *) make_ands_explicit(list_make2(objectIdJoin,
																	 shardKeyJoin));

	Query *count = MakeQueryNode(CMD_SELECT);
	count->canSetTag = false;
	AddUpdateCteReference(count, filteredCte, cteLevelsUp);
	count->hasAggs = true;
	count->targetList = list_make1(makeTargetEntry(
									   (Expr *) BuildUpdateAggregate("count", NULL),
									   1, "count", false));
	SubLink *matched = makeNode(SubLink);
	matched->subLinkType = EXPR_SUBLINK;
	matched->subselect = (Node *) count;
	matched->location = -1;
	context->schemaValidationCTEs = list_make2(filteredCte, validationCte);
	context->matchedCount = (Expr *) matched;
}


/*
 * Augments the update query with a result query that includes matched and modified counts.
 */
static Query *
BuildUpdateManyResultQuery(UpdateAstContext *context, UpdateQueryVars *updateVars)
{
	Query *update = updateVars->query;

	/* This function reads transformation state, so it must stay in RETURNING. */
	Var *shardKeyVar = UpdateRelationVar(updateVars, UpdateBaseTableVar_ShardKey);
	FuncExpr *returned = makeFuncExpr(BsonUpdateReturnedValueFunctionOid(), INT4OID,
									  list_make1(shardKeyVar),
									  InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);

	TargetEntry *updated = makeTargetEntry((Expr *) returned, 1, "updated", false);
	update->returningList = list_make1(updated);

	CommonTableExpr *updateCte = MakeUpdateCte("u", update);
	Query *result = MakeQueryNode(CMD_SELECT);
	result->cteList = list_concat(context->schemaValidationCTEs, list_make1(updateCte));
	result->hasModifyingCTE = true;
	result->hasAggs = true;
	result->hasSubLinks = context->matchedCount != NULL;

	/* This is at the same level now */
	int levelsup = 0;
	Index source = AddUpdateCteReference(result, updateCte, levelsup);

	Expr *matchedCount = context->matchedCount == NULL ?
						 (Expr *) BuildUpdateAggregate("count", NULL) :
						 context->matchedCount;
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
