/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/aggregation/bson_aggregation_config_queries.c
 *
 * Implementation of the backend query generation for queries targetting
 * the config database.
 *
 *-------------------------------------------------------------------------
 */


#include <postgres.h>
#include <float.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <access/table.h>
#include <catalog/pg_class.h>
#include <parser/parse_node.h>
#include <nodes/makefuncs.h>
#include <nodes/params.h>
#include <utils/builtins.h>
#include <utils/fmgroids.h>
#include <utils/lsyscache.h>
#include <catalog/namespace.h>
#include <parser/parse_relation.h>

#include "io/bson_core.h"
#include "metadata/metadata_cache.h"
#include "aggregation/bson_aggregation_pipeline.h"
#include "aggregation/bson_aggregation_pipeline_private.h"
#include "api_hooks.h"
#include "rbac_hooks.h"
#include "utils/version_utils.h"

extern bool EnableAdminDatabaseQueries;

static Query * GenerateVersionQuery(AggregationPipelineBuildContext *context);
static Query * GenerateDatabasesQuery(AggregationPipelineBuildContext *context);
static Query * GenerateCollectionsQuery(AggregationPipelineBuildContext *context);
static Query * GenerateChunksQuery(AggregationPipelineBuildContext *context);
static Query * GenerateShardsQuery(AggregationPipelineBuildContext *context);
static Query * GenerateSettingsQuery(AggregationPipelineBuildContext *context);

static Query * GenerateRolesQuery(AggregationPipelineBuildContext *context);
static Query * GenerateUsersQuery(AggregationPipelineBuildContext *context);
static SQLValueFunction * MakeCurrentUserNameExpr(void);
static Expr * MakeCurrentUserTextExpr(void);
static Expr * MakeIsCurrentUserMemberOfRoleExpr(Expr *roleName);
static ParseNamespaceItem * AddCallerCheckedRte(ParseState *parseState, const
												char *schemaName, const
												char *relationName,
												const char *aliasName);
static ParseNamespaceItem * AddOwnerCheckedRte(ParseState *parseState, const
											   char *schemaName, const char *relationName,
											   const char *aliasName);
static ParseNamespaceItem * AddRelationRte(ParseState *parseState, const char *schemaName,
										   const char *relationName,
										   const char *aliasName, Oid *relationOwner);
static CoerceViaIO * CoerceNameToText(Expr *nameExpr);
static CoerceViaIO * CoerceTextToName(Expr *textExpr);
static JoinExpr * MakeUsersJoin(ParseState *parseState, JoinType joinType,
								ParseNamespaceItem *leftItem,
								ParseNamespaceItem *rightItem, Node *left,
								Node *right, Expr *quals,
								ParseNamespaceItem **joinItem);
static void AppendUsersJoinColumns(ParseNamespaceItem *sourceItem,
								   Index nullingRelationId, List **columnNames,
								   List **columnVars, List **columnNumbers,
								   ParseNamespaceColumn *joinColumns,
								   int *joinColumnIndex);

/*
 * Sets the RTE of a table in the Config database.
 */
Query *
GenerateConfigDatabaseQuery(AggregationPipelineBuildContext *context)
{
	if (StringViewEqualsCString(&context->collectionNameView, "version"))
	{
		return GenerateVersionQuery(context);
	}
	else if (StringViewEqualsCString(&context->collectionNameView, "databases"))
	{
		context->requiresPersistentCursor = true;
		return GenerateDatabasesQuery(context);
	}
	else if (StringViewEqualsCString(&context->collectionNameView, "collections"))
	{
		context->requiresPersistentCursor = true;
		return GenerateCollectionsQuery(context);
	}
	else if (StringViewEqualsCString(&context->collectionNameView, "chunks"))
	{
		context->requiresPersistentCursor = true;
		return GenerateChunksQuery(context);
	}
	else if (StringViewEqualsCString(&context->collectionNameView, "settings"))
	{
		context->requiresPersistentCursor = true;
		return GenerateSettingsQuery(context);
	}
	else if (StringViewEqualsCString(&context->collectionNameView, "_shards"))
	{
		/* TODO: We can't enable this on shards because there's a dependency */
		/* on the "host" which requires a connection string. Once we can pass */
		/* the MX connection string - reconsider adding this back. */
		context->requiresPersistentCursor = true;
		return GenerateShardsQuery(context);
	}
	else
	{
		return NULL;
	}
}


Query *
GenerateAdminDatabaseQuery(AggregationPipelineBuildContext *context)
{
	if (!EnableAdminDatabaseQueries)
	{
		return NULL;
	}
	else if (StringViewEqualsCString(&context->collectionNameView, "system.roles") &&
			 IsClusterVersionAtleast(DocDB_V0, 116, 0))
	{
		context->requiresPersistentCursor = true;
		return GenerateRolesQuery(context);
	}
	else if (StringViewEqualsCString(&context->collectionNameView, "system.users") &&
			 IsClusterVersionAtleast(DocDB_V0, 116, 0))
	{
		context->requiresPersistentCursor = true;
		return GenerateUsersQuery(context);
	}
	else
	{
		return NULL;
	}
}


/*
 * Generates a query that mimics the output of config.versions
 */
static Query *
GenerateVersionQuery(AggregationPipelineBuildContext *context)
{
	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;
	context->mongoCollection = NULL;

	query->rtable = NIL;

	/* Create an empty jointree structure */
	query->jointree = makeNode(FromExpr);

	/* Create the projector. We only project the NULL::bson in this type of query */
	pgbson_writer versionsWriter;
	PgbsonWriterInit(&versionsWriter);
	PgbsonWriterAppendBool(&versionsWriter, "shardingEnabled", 15, true);

	Const *documentEntry = MakeBsonConst(PgbsonWriterGetPgbson(&versionsWriter));
	TargetEntry *baseTargetEntry = makeTargetEntry((Expr *) documentEntry, 1, "document",
												   false);
	query->targetList = list_make1(baseTargetEntry);
	context->requiresPersistentCursor = true;

	query = MigrateQueryToSubQuery(query, context);
	return query;
}


/*
 * Mimics the output of the config.databases collection.
 */
static Query *
GenerateDatabasesQuery(AggregationPipelineBuildContext *context)
{
	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;

	RangeTblEntry *rte = makeNode(RangeTblEntry);

	/* Match spec for ApiCatalogSchemaName.collections function */
	List *colNames = list_concat(list_make3(makeString("database_name"), makeString(
												"collection_name"), makeString(
												"collection_id")),
								 list_make3(makeString("shard_key"), makeString(
												"collection_uuid"), makeString(
												"view_definition")));
	rte->rtekind = RTE_RELATION;
	rte->alias = rte->eref = makeAlias("collection", colNames);
	rte->lateral = false;
	rte->inFromCl = true;
	rte->relkind = RELKIND_RELATION;
	rte->functions = NIL;
	rte->inh = true;
	rte->rellockmode = AccessShareLock;

	RangeVar *rangeVar = makeRangeVar(ApiCatalogSchemaName, "collections", -1);
	rte->relid = RangeVarGetRelid(rangeVar, AccessShareLock, false);

#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permInfo = addRTEPermissionInfo(&query->rteperminfos, rte);
	permInfo->requiredPerms = ACL_SELECT;
#else
	rte->requiredPerms = ACL_SELECT;
#endif
	query->rtable = list_make1(rte);

	/* Now register the RTE in the "FROM" clause with a single filter on shard_key not null */
	NullTest *nullTest = makeNode(NullTest);
	nullTest->argisrow = false;
	nullTest->nulltesttype = IS_NOT_NULL;
	nullTest->arg = (Expr *) makeVar(1, 4, BsonTypeId(), -1, InvalidOid, 0);

	RangeTblRef *rtr = makeNode(RangeTblRef);
	rtr->rtindex = 1;
	query->jointree = makeFromExpr(list_make1(rtr), (Node *) nullTest);
	UpdateJoinTreeForCollectionsQuery(query->jointree, query->rtable);

	/* Add a row_get_bson to make it a single bson document */
	Var *rowExpr = makeVar(1, 0, ApiCatalogCollectionsTypeOid(), -1, InvalidOid, 0);
	FuncExpr *funcExpr = makeFuncExpr(RowGetBsonFunctionOid(), BsonTypeId(),
									  list_make1(rowExpr), InvalidOid, InvalidOid,
									  COERCE_EXPLICIT_CALL);
	TargetEntry *baseTargetEntry = makeTargetEntry((Expr *) funcExpr, 1, "document",
												   false);
	query->targetList = list_make1(baseTargetEntry);

	/* Move to a subquery */
	query = MigrateQueryToSubQuery(query, context);

	/* Now group by database_name */
	pgbson_writer groupWriter;
	PgbsonWriterInit(&groupWriter);
	PgbsonWriterAppendUtf8(&groupWriter, "_id", 3, "$database_name");
	pgbson *groupSpec = PgbsonWriterGetPgbson(&groupWriter);
	bson_value_t groupValue = ConvertPgbsonToBsonValue(groupSpec);
	query = HandleGroup(&groupValue, query, context);
	query = MigrateQueryToSubQuery(query, context);

	pgbson_writer projectionSpec;
	PgbsonWriterInit(&projectionSpec);
	PgbsonWriterAppendBool(&projectionSpec, "partitioned", 11, true);

	pgbson *spec = PgbsonWriterGetPgbson(&projectionSpec);
	bson_value_t projectionValue = ConvertPgbsonToBsonValue(spec);

	/* no use for *WithLet or *WithLetAndCollation projection functions here, so we set them to NULL */
	Oid (*addFieldsWithLetFuncOid) (void) = NULL;
	Oid (*addFieldsWithLetAndCollationFuncOid) (void) = NULL;

	query = HandleSimpleProjectionStage(
		&projectionValue, query, context, "$addFields", BsonDollarAddFieldsFunctionOid(),
		addFieldsWithLetFuncOid, addFieldsWithLetAndCollationFuncOid);

	return query;
}


/*
 * Mimics the output of the config.collections collection.
 */
static Query *
GenerateCollectionsQuery(AggregationPipelineBuildContext *context)
{
	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;

	RangeTblEntry *rte = makeNode(RangeTblEntry);

	/* Match spec for ApiCatalogSchemaName.collections function */
	List *colNames = list_concat(list_make3(makeString("database_name"), makeString(
												"collection_name"), makeString(
												"collection_id")),
								 list_make3(makeString("shard_key"), makeString(
												"collection_uuid"), makeString(
												"view_definition")));
	rte->rtekind = RTE_RELATION;
	rte->alias = rte->eref = makeAlias("collection", colNames);
	rte->lateral = false;
	rte->inFromCl = true;
	rte->relkind = RELKIND_RELATION;
	rte->functions = NIL;
	rte->inh = true;
	rte->rellockmode = AccessShareLock;

	RangeVar *rangeVar = makeRangeVar(ApiCatalogSchemaName, "collections", -1);
	rte->relid = RangeVarGetRelid(rangeVar, AccessShareLock, false);

#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permInfo = addRTEPermissionInfo(&query->rteperminfos, rte);
	permInfo->requiredPerms = ACL_SELECT;
#else
	rte->requiredPerms = ACL_SELECT;
#endif
	query->rtable = list_make1(rte);

	/* Now register the RTE in the "FROM" clause with a single filter on shard_key not null */
	NullTest *nullTest = makeNode(NullTest);
	nullTest->argisrow = false;
	nullTest->nulltesttype = IS_NOT_NULL;
	nullTest->arg = (Expr *) makeVar(1, 4, BsonTypeId(), -1, InvalidOid, 0);

	RangeTblRef *rtr = makeNode(RangeTblRef);
	rtr->rtindex = 1;
	query->jointree = makeFromExpr(list_make1(rtr), (Node *) nullTest);
	UpdateJoinTreeForCollectionsQuery(query->jointree, query->rtable);

	/* Add a row_get_bson to make it a single bson document */
	Var *rowExpr = makeVar(1, 0, ApiCatalogCollectionsTypeOid(), -1, InvalidOid, 0);
	FuncExpr *funcExpr = makeFuncExpr(RowGetBsonFunctionOid(), BsonTypeId(),
									  list_make1(rowExpr), InvalidOid, InvalidOid,
									  COERCE_EXPLICIT_CALL);
	TargetEntry *baseTargetEntry = makeTargetEntry((Expr *) funcExpr, 1, "document",
												   false);
	query->targetList = list_make1(baseTargetEntry);

	/* Modify the output to match the config.collections output */
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	pgbson_writer childWriter;
	PgbsonWriterStartDocument(&writer, "_id", 3, &childWriter);

	pgbson_array_writer childArray;
	PgbsonWriterStartArray(&childWriter, "$concat", 7, &childArray);
	PgbsonArrayWriterWriteUtf8(&childArray, "$database_name");
	PgbsonArrayWriterWriteUtf8(&childArray, ".");
	PgbsonArrayWriterWriteUtf8(&childArray, "$collection_name");
	PgbsonWriterEndArray(&childWriter, &childArray);
	PgbsonWriterEndDocument(&writer, &childWriter);

	PgbsonWriterAppendUtf8(&writer, "key", 3, "$shard_key");

	/* Since we use $project, use $literal since bools and numbers need to be escaped */
	pgbson_writer expressionWriter;
	PgbsonWriterStartDocument(&writer, "noBalance", 9, &expressionWriter);
	PgbsonWriterAppendBool(&expressionWriter, "$literal", -1, true);
	PgbsonWriterEndDocument(&writer, &expressionWriter);

	pgbson *spec = PgbsonWriterGetPgbson(&writer);
	bson_value_t projectionValue = ConvertPgbsonToBsonValue(spec);

	/* no use for *WithLet or *WithLetAndCollation projection functions here, so we set them to NULL */
	Oid (*addFieldsWithLetFuncOid) (void) = NULL;
	Oid (*addFieldsWithLetAndCollationFuncOid) (void) = NULL;

	query = HandleSimpleProjectionStage(
		&projectionValue, query, context, "$project", BsonDollarProjectFunctionOid(),
		addFieldsWithLetFuncOid, addFieldsWithLetAndCollationFuncOid);

	return query;
}


/* Simulates the output of the config.chunks table */
static Query *
GenerateChunksQuery(AggregationPipelineBuildContext *context)
{
	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;

	RangeTblEntry *rte = makeNode(RangeTblEntry);

	/* Match spec for ApiCatalogSchemaName.collections function */
	List *colNames = list_concat(list_make3(makeString("database_name"), makeString(
												"collection_name"), makeString(
												"collection_id")),
								 list_make3(makeString("shard_key"), makeString(
												"collection_uuid"), makeString(
												"view_definition")));
	rte->rtekind = RTE_RELATION;
	rte->alias = rte->eref = makeAlias("collection", colNames);
	rte->lateral = false;
	rte->inFromCl = true;
	rte->relkind = RELKIND_RELATION;
	rte->functions = NIL;
	rte->inh = true;
	rte->rellockmode = AccessShareLock;

	RangeVar *rangeVar = makeRangeVar(ApiCatalogSchemaName, "collections", -1);
	rte->relid = RangeVarGetRelid(rangeVar, AccessShareLock, false);

#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permInfo = addRTEPermissionInfo(&query->rteperminfos, rte);
	permInfo->requiredPerms = ACL_SELECT;
#else
	rte->requiredPerms = ACL_SELECT;
#endif
	query->rtable = list_make1(rte);

	/* Now register the RTE in the "FROM" clause with a single filter on shard_key not null */
	NullTest *nullTest = makeNode(NullTest);
	nullTest->argisrow = false;
	nullTest->nulltesttype = IS_NOT_NULL;
	nullTest->arg = (Expr *) makeVar(1, 4, BsonTypeId(), -1, InvalidOid, 0);

	RangeTblRef *rtr = makeNode(RangeTblRef);
	rtr->rtindex = 1;
	query->jointree = makeFromExpr(list_make1(rtr), (Node *) nullTest);
	UpdateJoinTreeForCollectionsQuery(query->jointree, query->rtable);

	/* Add a row_get_bson to make it a single bson document */
	Var *rowExpr = makeVar(1, 0, ApiCatalogCollectionsTypeOid(), -1, InvalidOid, 0);
	FuncExpr *funcExpr = makeFuncExpr(RowGetBsonFunctionOid(), BsonTypeId(),
									  list_make1(rowExpr), InvalidOid, InvalidOid,
									  COERCE_EXPLICIT_CALL);
	TargetEntry *baseTargetEntry = makeTargetEntry((Expr *) funcExpr, 1, "document",
												   false);
	query->targetList = list_make1(baseTargetEntry);

	/* Modify the output to match the config.chunks output */
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	pgbson_writer childWriter;
	PgbsonWriterStartDocument(&writer, "ns", 2, &childWriter);

	pgbson_array_writer childArray;
	PgbsonWriterStartArray(&childWriter, "$concat", 7, &childArray);
	PgbsonArrayWriterWriteUtf8(&childArray, "$database_name");
	PgbsonArrayWriterWriteUtf8(&childArray, ".");
	PgbsonArrayWriterWriteUtf8(&childArray, "$collection_name");
	PgbsonWriterEndArray(&childWriter, &childArray);
	PgbsonWriterEndDocument(&writer, &childWriter);

	PgbsonWriterAppendUtf8(&writer, "shard", 5, "defaultShard");

	/* Since we use $project, use $literal since bools and numbers need to be escaped */
	pgbson_writer expressionWriter;
	PgbsonWriterStartDocument(&writer, "min", 3, &expressionWriter);
	PgbsonWriterAppendInt64(&expressionWriter, "$literal", -1, LONG_MIN);
	PgbsonWriterEndDocument(&writer, &expressionWriter);

	PgbsonWriterStartDocument(&writer, "max", 3, &expressionWriter);
	PgbsonWriterAppendInt64(&expressionWriter, "$literal", -1, LONG_MAX);
	PgbsonWriterEndDocument(&writer, &expressionWriter);

	pgbson *spec = PgbsonWriterGetPgbson(&writer);
	bson_value_t projectionValue = ConvertPgbsonToBsonValue(spec);

	/* no use for *WithLet or *WithLetAndCollation projection functions here, so we set them to NULL */
	Oid (*projectWithLetFuncOid) (void) = NULL;
	Oid (*projectWithLetAndCollationFuncOid) (void) = NULL;

	query = HandleSimpleProjectionStage(
		&projectionValue, query, context, "$project", BsonDollarProjectFunctionOid(),
		projectWithLetFuncOid, projectWithLetAndCollationFuncOid);

	return MutateChunksQueryForDistribution(query);
}


static Query *
GenerateShardsQuery(AggregationPipelineBuildContext *context)
{
	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;
	context->mongoCollection = NULL;

	query->rtable = NIL;

	/* Create an empty jointree structure */
	query->jointree = makeNode(FromExpr);

	/* Create the projector. We only project the NULL::bson in this type of query */
	pgbson_writer shardsWriter;
	PgbsonWriterInit(&shardsWriter);
	PgbsonWriterAppendUtf8(&shardsWriter, "_id", 3, "defaultShard");

	Const *documentEntry = MakeBsonConst(PgbsonWriterGetPgbson(&shardsWriter));
	TargetEntry *baseTargetEntry = makeTargetEntry((Expr *) documentEntry, 1, "document",
												   false);
	query->targetList = list_make1(baseTargetEntry);
	context->requiresPersistentCursor = true;

	query = MigrateQueryToSubQuery(query, context);
	return MutateShardsQueryForDistribution(query);
}


static Query *
GenerateSettingsQuery(AggregationPipelineBuildContext *context)
{
	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;
	context->mongoCollection = NULL;

	List *valuesList = NIL;

	/* { _id: balancer, stopped: true } */
	pgbson_writer balancerWriter;
	PgbsonWriterInit(&balancerWriter);
	PgbsonWriterAppendUtf8(&balancerWriter, "_id", 3, "balancer");
	PgbsonWriterAppendBool(&balancerWriter, "stopped", 7, true);
	valuesList = lappend(valuesList, list_make1(MakeBsonConst(PgbsonWriterGetPgbson(
																  &balancerWriter))));

	/* { _id: autosplit, enabled: false } */
	pgbson_writer autosplitWriter;
	PgbsonWriterInit(&autosplitWriter);
	PgbsonWriterAppendUtf8(&autosplitWriter, "_id", 3, "autosplit");
	PgbsonWriterAppendBool(&autosplitWriter, "enabled", 7, false);
	valuesList = lappend(valuesList, list_make1(MakeBsonConst(PgbsonWriterGetPgbson(
																  &autosplitWriter))));

	RangeTblEntry *valuesRte = makeNode(RangeTblEntry);
	valuesRte->rtekind = RTE_VALUES;
	valuesRte->alias = valuesRte->eref = makeAlias("values", list_make1(makeString(
																			"document")));
	valuesRte->lateral = false;
	valuesRte->values_lists = valuesList;
	valuesRte->inh = false;
	valuesRte->inFromCl = true;

	valuesRte->coltypes = list_make1_oid(INT8OID);
	valuesRte->coltypmods = list_make1_int(-1);
	valuesRte->colcollations = list_make1_oid(InvalidOid);
	query->rtable = list_make1(valuesRte);

	query->jointree = makeNode(FromExpr);
	RangeTblRef *valuesRteRef = makeNode(RangeTblRef);
	valuesRteRef->rtindex = 1;
	query->jointree->fromlist = list_make1(valuesRteRef);

	/* Point to the values RTE */
	Var *documentEntry = makeVar(1, 1, BsonTypeId(), -1, InvalidOid, 0);
	TargetEntry *baseTargetEntry = makeTargetEntry((Expr *) documentEntry, 1, "document",
												   false);
	query->targetList = list_make1(baseTargetEntry);
	context->requiresPersistentCursor = true;

	return query;
}


static Query *
GenerateRolesQuery(AggregationPipelineBuildContext *context)
{
	/* The system.roles collection is a collection that just maps into
	 * the catalog roles table and mutates the spec.
	 */
	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;
	context->mongoCollection = NULL;

	RangeTblEntry *rte = makeNode(RangeTblEntry);

	List *colNames = list_make3(makeString(""), makeString("role_bson"),
								makeString("role_name"));
	rte->rtekind = RTE_RELATION;
	rte->alias = rte->eref = makeAlias("roles", colNames);
	rte->lateral = false;
	rte->inFromCl = true;
	rte->relkind = RELKIND_RELATION;
	rte->functions = NIL;
	rte->inh = true;
	rte->rellockmode = AccessShareLock;

	RangeVar *rangeVar = makeRangeVar(ApiCatalogSchemaName, "roles", -1);
	rte->relid = RangeVarGetRelid(rangeVar, AccessShareLock, false);

#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permInfo = addRTEPermissionInfo(&query->rteperminfos, rte);
	permInfo->requiredPerms = ACL_SELECT;
#else
	rte->requiredPerms = ACL_SELECT;
#endif
	query->rtable = list_make1(rte);

	RangeTblRef *rtr = makeNode(RangeTblRef);
	rtr->rtindex = 1;
	query->jointree = makeFromExpr(list_make1(rtr), NULL);

	AttrNumber roleNameAttributeNumber = get_attnum(rte->relid, "role_name");
	Var *roleName = makeVar(1, roleNameAttributeNumber, TEXTOID, -1,
							DEFAULT_COLLATION_OID, 0);
	Expr *roleMembershipQual = MakeIsCurrentUserMemberOfRoleExpr(
		(Expr *) roleName);

	bool missingOk = true;
	if (OidIsValid(get_role_oid(ApiRootRole, missingOk)))
	{
		Expr *rootMembershipQual = MakeIsCurrentUserMemberOfRoleExpr(
			(Expr *) MakeTextConst(ApiRootRole, strlen(ApiRootRole)));
		roleMembershipQual = (Expr *) makeBoolExpr(
			OR_EXPR, list_make2(rootMembershipQual, roleMembershipQual), -1);
	}

	query->jointree->quals = (Node *) roleMembershipQual;

	/* Add a var to get the role_spec to make it a single bson document */
	Var *rowExpr = makeVar(1, 2, BsonTypeId(), -1, InvalidOid, 0);
	TargetEntry *baseTargetEntry = makeTargetEntry((Expr *) rowExpr, 1, "document",
												   false);
	query->targetList = list_make1(baseTargetEntry);

	/* Modify the output to match the system.roles output */
	pgbson_writer topLevelwriter;
	PgbsonWriterInit(&topLevelwriter);

	pgbson_writer writer;
	PgbsonWriterStartDocument(&topLevelwriter, "newRoot", 7, &writer);

	pgbson_writer childWriter;
	PgbsonWriterStartDocument(&writer, "_id", 3, &childWriter);

	pgbson_array_writer childArray;
	PgbsonWriterStartArray(&childWriter, "$concat", 7, &childArray);
	PgbsonArrayWriterWriteUtf8(&childArray, "admin");
	PgbsonArrayWriterWriteUtf8(&childArray, ".");
	PgbsonArrayWriterWriteUtf8(&childArray, "$createRole");
	PgbsonWriterEndArray(&childWriter, &childArray);
	PgbsonWriterEndDocument(&writer, &childWriter);

	PgbsonWriterAppendUtf8(&writer, "role", 4, "$createRole");
	PgbsonWriterAppendUtf8(&writer, "db", 2, "admin");

	PgbsonWriterAppendUtf8(&writer, "privileges", 10, "$privileges");
	PgbsonWriterAppendUtf8(&writer, "roles", 5, "$roles");

	PgbsonWriterEndDocument(&topLevelwriter, &writer);

	pgbson *spec = PgbsonWriterGetPgbson(&topLevelwriter);
	bson_value_t projectionValue = ConvertPgbsonToBsonValue(spec);

	/* no use for *WithLet or *WithLetAndCollation projection functions here, so we set them to NULL */
	Oid (*addFieldsWithLetFuncOid) (void) = NULL;
	Oid (*addFieldsWithLetAndCollationFuncOid) (void) = NULL;

	query = HandleSimpleProjectionStage(
		&projectionValue, query, context, "$replaceRoot",
		BsonDollarReplaceRootFunctionOid(),
		addFieldsWithLetFuncOid, addFieldsWithLetAndCollationFuncOid);

	return query;
}


static Query *
GenerateUsersQuery(AggregationPipelineBuildContext *context)
{
	context->mongoCollection = NULL;

	ParseState *parseState = make_parsestate(NULL);

	/*
	 * A normal query against pg_roles is rewritten before planning. PostgreSQL
	 * retains the original view RTE for caller permission checks, then checks
	 * the rewritten backing-relation RTEs as the view owner. This query is
	 * generated after view rewriting, so directly adding pg_roles to its
	 * jointree would leave the view unexpanded and fail during planning.
	 *
	 * Reproduce the rewrite permission model explicitly. The two unscanned
	 * pg_roles RTEs represent the two view references in the original query
	 * and require the invoking user to have SELECT on that view. The two
	 * pg_authid RTEs are the corresponding rewritten backing relations, so
	 * those alone are checked as their relation owner. pg_auth_members and
	 * the roles catalog are direct relations in the original query and must
	 * remain caller-checked. Keeping this distinction is important:
	 * owner-checking every relation would grant more access than the original
	 * query, while caller-checking pg_authid would make pg_roles unusable by
	 * otherwise authorized non-owners.
	 */
	ParseNamespaceItem *usersViewPermissionItem =
		AddCallerCheckedRte(parseState, "pg_catalog", "pg_roles",
							"users_view_permission_check");
	usersViewPermissionItem->p_rte->inFromCl = false;
	ParseNamespaceItem *parentViewPermissionItem =
		AddCallerCheckedRte(parseState, "pg_catalog", "pg_roles",
							"parent_view_permission_check");
	parentViewPermissionItem->p_rte->inFromCl = false;

	ParseNamespaceItem *usersItem = AddOwnerCheckedRte(
		parseState, "pg_catalog", "pg_authid", "users");
	ParseNamespaceItem *membersItem = AddCallerCheckedRte(
		parseState, "pg_catalog", "pg_auth_members", "members");
	ParseNamespaceItem *parentItem = AddOwnerCheckedRte(
		parseState, "pg_catalog", "pg_authid", "parent");
	ParseNamespaceItem *customRolesItem = AddCallerCheckedRte(
		parseState, ApiCatalogSchemaName, "roles", "custom_roles");

	AttrNumber usersOidAttnum = get_attnum(usersItem->p_rte->relid, "oid");
	AttrNumber usersNameAttnum = get_attnum(usersItem->p_rte->relid, "rolname");
	AttrNumber usersCanLoginAttnum = get_attnum(usersItem->p_rte->relid, "rolcanlogin");
	AttrNumber memberAttnum = get_attnum(membersItem->p_rte->relid, "member");
	AttrNumber roleIdAttnum = get_attnum(membersItem->p_rte->relid, "roleid");
	AttrNumber adminOptionAttnum = get_attnum(membersItem->p_rte->relid, "admin_option");
	AttrNumber parentOidAttnum = get_attnum(parentItem->p_rte->relid, "oid");
	AttrNumber parentNameAttnum = get_attnum(parentItem->p_rte->relid, "rolname");
	AttrNumber customRoleNameAttnum = get_attnum(customRolesItem->p_rte->relid,
												 "role_name");

	Var *usersOid = makeVar(usersItem->p_rtindex, usersOidAttnum, OIDOID, -1,
							InvalidOid, 0);
	Var *usersName = makeVar(usersItem->p_rtindex, usersNameAttnum, NAMEOID, -1,
							 DEFAULT_COLLATION_OID, 0);
	Var *usersCanLogin = makeVar(usersItem->p_rtindex, usersCanLoginAttnum, BOOLOID,
								 -1, InvalidOid, 0);
	Var *member = makeVar(membersItem->p_rtindex, memberAttnum, OIDOID, -1,
						  InvalidOid, 0);
	Var *roleId = makeVar(membersItem->p_rtindex, roleIdAttnum, OIDOID, -1,
						  InvalidOid, 0);
	Var *adminOption = makeVar(membersItem->p_rtindex, adminOptionAttnum, BOOLOID, -1,
							   InvalidOid, 0);
	Var *parentOid = makeVar(parentItem->p_rtindex, parentOidAttnum, OIDOID, -1,
							 InvalidOid, 0);
	Var *parentName = makeVar(parentItem->p_rtindex, parentNameAttnum, NAMEOID, -1,
							  DEFAULT_COLLATION_OID, 0);
	Var *customRoleName = makeVar(customRolesItem->p_rtindex, customRoleNameAttnum,
								  TEXTOID, -1, DEFAULT_COLLATION_OID, 0);

	Oid oidEqualityOperator = OpernameGetOprid(list_make1(makeString("=")), OIDOID,
											   OIDOID);
	Expr *userMembershipQual = make_opclause(oidEqualityOperator, BOOLOID, false,
											 (Expr *) member, (Expr *) usersOid,
											 InvalidOid, InvalidOid);
	Expr *parentMembershipQual = make_opclause(oidEqualityOperator, BOOLOID, false,
											   (Expr *) roleId, (Expr *) parentOid,
											   InvalidOid, InvalidOid);

	CoerceViaIO *parentNameText = CoerceNameToText((Expr *) parentName);
	Expr *customRoleQual = make_opclause(TextEqualOperatorId(), BOOLOID, false,
										 (Expr *) parentNameText,
										 (Expr *) customRoleName,
										 InvalidOid, DEFAULT_COLLATION_OID);

	RangeTblRef *usersRef = makeNode(RangeTblRef);
	usersRef->rtindex = usersItem->p_rtindex;
	RangeTblRef *membersRef = makeNode(RangeTblRef);
	membersRef->rtindex = membersItem->p_rtindex;
	RangeTblRef *parentRef = makeNode(RangeTblRef);
	parentRef->rtindex = parentItem->p_rtindex;
	RangeTblRef *customRolesRef = makeNode(RangeTblRef);
	customRolesRef->rtindex = customRolesItem->p_rtindex;

	ParseNamespaceItem *membershipItem;
	JoinExpr *membershipJoin = MakeUsersJoin(
		parseState, JOIN_INNER, usersItem, membersItem, (Node *) usersRef,
		(Node *) membersRef, userMembershipQual, &membershipItem);
	ParseNamespaceItem *parentJoinItem;
	JoinExpr *parentJoin = MakeUsersJoin(parseState, JOIN_INNER, membershipItem,
										 parentItem, (Node *) membershipJoin,
										 (Node *) parentRef,
										 parentMembershipQual, &parentJoinItem);
	JoinExpr *customRolesJoin = MakeUsersJoin(
		parseState, JOIN_LEFT, parentJoinItem, customRolesItem,
		(Node *) parentJoin, (Node *) customRolesRef, customRoleQual, NULL);

	Expr *currentUserQual = make_opclause(
		TextEqualOperatorId(), BOOLOID, false,
		(Expr *) CoerceNameToText((Expr *) copyObject(usersName)),
		MakeCurrentUserTextExpr(), InvalidOid, DEFAULT_COLLATION_OID);

	Var *nullableCustomRoleName = copyObject(customRoleName);
#if PG_VERSION_NUM >= 160000
	nullableCustomRoleName->varnullingrels =
		bms_make_singleton(customRolesJoin->rtindex);
#endif
	NullTest *customRoleExists = makeNode(NullTest);
	customRoleExists->arg = (Expr *) nullableCustomRoleName;
	customRoleExists->nulltesttype = IS_NOT_NULL;
	customRoleExists->argisrow = false;

	Expr *nonAdministrativeMembershipQual = (Expr *) makeBoolExpr(
		NOT_EXPR, list_make1(adminOption), -1);
	List *usersQuals = list_make2(customRoleExists, nonAdministrativeMembershipQual);
	bool missingOk = true;
	if (OidIsValid(get_role_oid(ApiRootRole, missingOk)))
	{
		Expr *rootMembershipQual = MakeIsCurrentUserMemberOfRoleExpr(
			(Expr *) MakeTextConst(ApiRootRole, strlen(ApiRootRole)));
		currentUserQual = (Expr *) makeBoolExpr(
			OR_EXPR, list_make2(rootMembershipQual, currentUserQual), -1);
	}

	usersQuals = lappend(usersQuals, currentUserQual);

	if (IsClusterVersionAtleast(DocDB_V0, 117, 3))
	{
		usersQuals = lappend(usersQuals, usersCanLogin);

		CoerceViaIO *usersNameText = CoerceNameToText((Expr *) usersName);
		Expr *isReservedUser = (Expr *) makeFuncExpr(
			IsReservedUserFunctionId(), BOOLOID,
			list_make1(usersNameText), InvalidOid, InvalidOid,
			COERCE_EXPLICIT_CALL);
		usersQuals = lappend(
			usersQuals,
			makeBoolExpr(NOT_EXPR, list_make1(isReservedUser), -1));
	}

	Query *query = makeNode(Query);
	query->commandType = CMD_SELECT;
	query->querySource = QSRC_ORIGINAL;
	query->canSetTag = true;
	query->rtable = parseState->p_rtable;
#if PG_VERSION_NUM >= 160000
	query->rteperminfos = parseState->p_rteperminfos;
#endif
	query->jointree = makeFromExpr(list_make1(customRolesJoin),
								   (Node *) make_ands_explicit(usersQuals));

	List *buildDocumentArgs = list_make4(
		MakeTextConst("user_name", 9), CoerceNameToText((Expr *) usersName),
		MakeTextConst("roles", 5), copyObject(parentNameText));
	FuncExpr *buildDocument = makeFuncExpr(
		BsonBuildDocumentFunctionOid(), BsonTypeId(), buildDocumentArgs,
		InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);
	query->targetList = list_make1(makeTargetEntry((Expr *) buildDocument, 1, "document",
												   false));

	free_parsestate(parseState);

	query = MigrateQueryToSubQuery(query, context);

	pgbson_writer groupWriter;
	PgbsonWriterInit(&groupWriter);

	pgbson_writer idWriter;
	PgbsonWriterStartDocument(&groupWriter, "_id", 3, &idWriter);
	pgbson_array_writer concatWriter;
	PgbsonWriterStartArray(&idWriter, "$concat", 7, &concatWriter);
	PgbsonArrayWriterWriteUtf8(&concatWriter, "admin.");
	PgbsonArrayWriterWriteUtf8(&concatWriter, "$user_name");
	PgbsonWriterEndArray(&idWriter, &concatWriter);
	PgbsonWriterEndDocument(&groupWriter, &idWriter);

	pgbson_writer userWriter;
	PgbsonWriterStartDocument(&groupWriter, "user", 4, &userWriter);
	PgbsonWriterAppendUtf8(&userWriter, "$first", 6, "$user_name");
	PgbsonWriterEndDocument(&groupWriter, &userWriter);

	pgbson_writer databaseWriter;
	PgbsonWriterStartDocument(&groupWriter, "db", 2, &databaseWriter);
	PgbsonWriterAppendUtf8(&databaseWriter, "$first", 6, "admin");
	PgbsonWriterEndDocument(&groupWriter, &databaseWriter);

	pgbson_writer rolesWriter;
	PgbsonWriterStartDocument(&groupWriter, "roles", 5, &rolesWriter);
	pgbson_writer pushWriter;
	PgbsonWriterStartDocument(&rolesWriter, "$push", 5, &pushWriter);
	PgbsonWriterAppendUtf8(&pushWriter, "db", 2, "admin");
	PgbsonWriterAppendUtf8(&pushWriter, "role", 4, "$roles");
	PgbsonWriterEndDocument(&rolesWriter, &pushWriter);
	PgbsonWriterEndDocument(&groupWriter, &rolesWriter);

	pgbson *groupSpec = PgbsonWriterGetPgbson(&groupWriter);
	bson_value_t groupValue = ConvertPgbsonToBsonValue(groupSpec);

	query = HandleGroup(&groupValue, query, context);

	return query;
}


static SQLValueFunction *
MakeCurrentUserNameExpr(void)
{
	SQLValueFunction *currentUser = makeNode(SQLValueFunction);
	currentUser->op = SVFOP_CURRENT_USER;
	currentUser->type = NAMEOID;
	currentUser->typmod = -1;
	currentUser->location = -1;

	return currentUser;
}


static Expr *
MakeCurrentUserTextExpr(void)
{
	return (Expr *) CoerceNameToText((Expr *) MakeCurrentUserNameExpr());
}


static Expr *
MakeIsCurrentUserMemberOfRoleExpr(Expr *roleName)
{
	return (Expr *) makeFuncExpr(
		F_PG_HAS_ROLE_NAME_NAME_TEXT, BOOLOID,
		list_make3(MakeCurrentUserNameExpr(), CoerceTextToName(roleName),
				   MakeTextConst("MEMBER", 6)),
		InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);
}


static ParseNamespaceItem *
AddCallerCheckedRte(ParseState *parseState, const char *schemaName,
					const char *relationName, const char *aliasName)
{
	return AddRelationRte(parseState, schemaName, relationName, aliasName, NULL);
}


static ParseNamespaceItem *
AddOwnerCheckedRte(ParseState *parseState, const char *schemaName,
				   const char *relationName, const char *aliasName)
{
	Oid relationOwner = InvalidOid;
	ParseNamespaceItem *item = AddRelationRte(
		parseState, schemaName, relationName, aliasName, &relationOwner);
#if PG_VERSION_NUM >= 160000
	RTEPermissionInfo *permissionInfo = getRTEPermissionInfo(parseState->p_rteperminfos,
															 item->p_rte);
	permissionInfo->checkAsUser = relationOwner;
#else
	item->p_rte->checkAsUser = relationOwner;
#endif
	return item;
}


static ParseNamespaceItem *
AddRelationRte(ParseState *parseState, const char *schemaName,
			   const char *relationName, const char *aliasName,
			   Oid *relationOwner)
{
	RangeVar *rangeVar = makeRangeVar(pstrdup(schemaName), pstrdup(relationName), -1);
	Oid relationId = RangeVarGetRelid(rangeVar, AccessShareLock, false);
	Relation relation = table_open(relationId, NoLock);
	ParseNamespaceItem *item = addRangeTableEntryForRelation(
		parseState, relation, AccessShareLock, makeAlias(pstrdup(aliasName), NIL), false,
		true);

	if (relationOwner != NULL)
	{
		*relationOwner = RelationGetForm(relation)->relowner;
	}

	table_close(relation, NoLock);
	return item;
}


static CoerceViaIO *
CoerceNameToText(Expr *nameExpr)
{
	CoerceViaIO *coerce = makeNode(CoerceViaIO);
	coerce->arg = nameExpr;
	coerce->resulttype = TEXTOID;
	coerce->resultcollid = DEFAULT_COLLATION_OID;
	coerce->coerceformat = COERCE_EXPLICIT_CAST;
	coerce->location = -1;
	return coerce;
}


static CoerceViaIO *
CoerceTextToName(Expr *textExpr)
{
	CoerceViaIO *coerce = makeNode(CoerceViaIO);
	coerce->arg = textExpr;
	coerce->resulttype = NAMEOID;
	coerce->resultcollid = InvalidOid;
	coerce->coerceformat = COERCE_EXPLICIT_CAST;
	coerce->location = -1;
	return coerce;
}


static JoinExpr *
MakeUsersJoin(ParseState *parseState, JoinType joinType,
			  ParseNamespaceItem *leftItem, ParseNamespaceItem *rightItem,
			  Node *left, Node *right, Expr *quals,
			  ParseNamespaceItem **joinItem)
{
	JoinExpr *join = makeNode(JoinExpr);
	join->jointype = joinType;
	join->larg = left;
	join->rarg = right;
	join->quals = (Node *) quals;
	join->rtindex = list_length(parseState->p_rtable) + 1;

	int maximumColumns = list_length(leftItem->p_names->colnames) +
						 list_length(rightItem->p_names->colnames);
	ParseNamespaceColumn *joinColumns =
		palloc0(maximumColumns * sizeof(ParseNamespaceColumn));
	List *columnNames = NIL;
	List *columnVars = NIL;
	List *leftColumnNumbers = NIL;
	List *rightColumnNumbers = NIL;
	int joinColumnIndex = 0;

	AppendUsersJoinColumns(leftItem, 0, &columnNames, &columnVars,
						   &leftColumnNumbers, joinColumns, &joinColumnIndex);
	AppendUsersJoinColumns(rightItem,
						   joinType == JOIN_LEFT ? join->rtindex : 0,
						   &columnNames, &columnVars, &rightColumnNumbers,
						   joinColumns, &joinColumnIndex);

	ParseNamespaceItem *newJoinItem = addRangeTableEntryForJoin(
		parseState, columnNames, joinColumns, joinType, 0, columnVars,
		leftColumnNumbers, rightColumnNumbers, NULL, NULL, true);
	Assert(join->rtindex == newJoinItem->p_rtindex);
	if (joinItem != NULL)
	{
		*joinItem = newJoinItem;
	}
	return join;
}


static void
AppendUsersJoinColumns(ParseNamespaceItem *sourceItem, Index nullingRelationId,
					   List **columnNames,
					   List **columnVars, List **columnNumbers,
					   ParseNamespaceColumn *joinColumns,
					   int *joinColumnIndex)
{
	int attributeNumber = 0;
	ListCell *columnNameCell;
	foreach(columnNameCell, sourceItem->p_names->colnames)
	{
		attributeNumber++;
		String *columnName = lfirst(columnNameCell);
		if (strVal(columnName)[0] == '\0')
		{
			continue;
		}

		ParseNamespaceColumn *sourceColumn =
			sourceItem->p_nscolumns + attributeNumber - 1;
		Var *columnVar = makeVar(sourceColumn->p_varno,
								 sourceColumn->p_varattno,
								 sourceColumn->p_vartype,
								 sourceColumn->p_vartypmod,
								 sourceColumn->p_varcollid, 0);
		columnVar->varnosyn = sourceColumn->p_varnosyn;
		columnVar->varattnosyn = sourceColumn->p_varattnosyn;
#if PG_VERSION_NUM >= 180000
		columnVar->varreturningtype = sourceColumn->p_varreturningtype;
#endif
#if PG_VERSION_NUM >= 160000
		if (nullingRelationId != 0)
		{
			columnVar->varnullingrels = bms_make_singleton(nullingRelationId);
		}
#endif

		*columnNames = lappend(*columnNames, copyObject(columnName));
		*columnVars = lappend(*columnVars, columnVar);
		*columnNumbers = lappend_int(*columnNumbers, attributeNumber);
		joinColumns[*joinColumnIndex] = *sourceColumn;
		(*joinColumnIndex)++;
	}
}
