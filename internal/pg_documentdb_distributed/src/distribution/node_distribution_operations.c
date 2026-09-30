/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License.
 * SPDX-License-Identifier: MIT
 *
 * src/distribution/node_distribution_operations.c
 *
 * Implementation of scenarios that require distribution on a per node basis.
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <utils/builtins.h>
#include <utils/timestamp.h>
#include <nodes/makefuncs.h>
#include <catalog/namespace.h>
#include <utils/lsyscache.h>
#include <utils/regproc.h>

#include "utils/query_utils.h"
#include "utils/documentdb_errors.h"
#include "utils/error_utils.h"
#include "io/bson_core.h"
#include "metadata/metadata_cache.h"
#include "node_distributed_operations.h"
#include "api_hooks.h"
#include "utils/hashset_utils.h"
#include "utils/string_view.h"


static ArrayType *
ChooseShardNamesForTable(const char *distributedTableName)
{
	const char *query =
		"WITH r1 AS (SELECT MIN($1 || '_' || sh.shardid) AS shardName FROM pg_dist_shard sh JOIN pg_dist_placement pl "
		" on pl.shardid = sh.shardid WHERE logicalrelid = $1::regclass GROUP by groupid) "
		" SELECT ARRAY_AGG(r1.shardName) FROM r1";

	int nargs = 1;
	Oid argTypes[1] = { TEXTOID };
	Datum argValues[1] = { CStringGetTextDatum(distributedTableName) };
	bool isReadOnly = true;
	bool isNull = true;
	Datum result = ExtensionExecuteQueryWithArgsViaSPI(query, nargs, argTypes, argValues,
													   NULL, isReadOnly, SPI_OK_SELECT,
													   &isNull);

	if (isNull)
	{
		return NULL;
	}

	return DatumGetArrayTypeP(result);
}


bool
IsSingleNodeCluster(void)
{
	bool readOnly = true;
	bool isNull = false;
	Datum result = ExtensionExecuteQueryViaSPI(
		"SELECT COUNT(*)::int4 FROM pg_dist_node "
		"WHERE nodecluster = 'default' AND noderole = 'primary' AND isactive",
		readOnly, SPI_OK_SELECT, &isNull);

	if (isNull)
	{
		ereport(ERROR, (errmsg(
							"could not determine the number of active primary nodes")));
	}

	return DatumGetInt32(result) <= 1;
}


static ArrayType *
GetTablesNamesPerNode(void)
{
	/* Implementation to find nodes without placement for the shards
	 * TODO: we can just exclude the changes table by oid directly whenever we migrate
	 * the legacy retry distributed table to the per-node local retry table to avoid doing the starts_with
	 * expensive check and the JOIN with pg_class.
	 */
	const char *query =
		"WITH r1 AS (SELECT dn.groupid AS groupid, MIN(sh.logicalrelid::regclass::text) FILTER (WHERE replicationfactor != -1 "
		"AND relation.relnamespace = $1 AND starts_with(relation.relname, 'documents_')) AS table_ids "
		"FROM pg_dist_node dn LEFT OUTER JOIN pg_dist_placement pl on dn.groupid = pl.groupid JOIN pg_dist_shard sh "
		"ON pl.shardid = sh.shardid JOIN pg_dist_partition pt on pt.logicalrelid = sh.logicalrelid "
		"JOIN pg_dist_colocation cl on pt.colocationid = cl.colocationid JOIN pg_class relation on relation.oid = sh.logicalrelid GROUP BY dn.groupid) "
		"SELECT array_agg(table_ids ORDER BY groupid) FROM r1;";

	int nargs = 1;
	Oid argTypes[1] = { OIDOID };
	Datum argValues[1] = { ObjectIdGetDatum(ApiDataNamespaceOid()) };
	bool isReadOnly = true;
	bool isNull = true;
	Datum result = ExtensionExecuteQueryWithArgsViaSPI(query, nargs, argTypes, argValues,
													   NULL, isReadOnly, SPI_OK_SELECT,
													   &isNull);

	if (isNull)
	{
		return NULL;
	}

	return DatumGetArrayTypeP(result);
}


static List *
ExecutePerNodeCommandCore(Oid nodeFunction, pgbson *nodeFunctionArg, bool readOnly,
						  const char *distributedTableName)
{
	ArrayType *chosenShards = ChooseShardNamesForTable(distributedTableName);
	if (chosenShards == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Failed to get shards for table"),
						errdetail_log(
							"Failed to get shard names for distributed table %s",
							distributedTableName)));
	}

	MemoryContext targetContext = CurrentMemoryContext;
	if (SPI_connect() != SPI_OK_CONNECT)
	{
		ereport(ERROR, (errmsg("could not connect to SPI manager")));
	}

	/* We build the query similar to update_worker and such where we have
	 * SELECT node_distributed_function(nodeFunction, nodeFunctionArg, 0, chosenShards, fullyQualified) FROM distributedTableName;
	 * Citus will apply distributed routing and send it to every shard. In the shard planner relpathlisthook, we'll rewrite
	 * the query to be
	 * SELECT node_distributed_function(nodeFunction, nodeFunctionArg, shardOid, chosenShards, fullyQualified);
	 *
	 * Then each shard will validate if it matches one of the chosenShards - if it does, then it runs nodeFunction,
	 * otherwise it noops.
	 * This ensures transactional processing of the command across all nodes that are hosting the shards, but each node runs
	 * the logic exactly once.
	 *
	 * We don't create an aggregate here so that we avoid any distributed planning overhead of aggregates.
	 * Allociate this string in the SPI context so it's freed on SPI_Finish().
	 */
	StringInfoData s;
	initStringInfo(&s);
	appendStringInfo(&s,
					 "SELECT %s.command_node_worker($1::oid, $2::%s.bson, 0, $3::text[], TRUE, $4::text) FROM %s",
					 ApiInternalSchemaNameV2, CoreSchemaNameV2, distributedTableName);

	/* Function OIDs are node-local; send a qualified signature for worker lookup. */
	int nargs = 4;
	Oid argTypes[4] = { OIDOID, BsonTypeId(), TEXTARRAYOID, TEXTOID };
	Datum argValues[4] = {
		ObjectIdGetDatum(nodeFunction),
		PointerGetDatum(nodeFunctionArg),
		PointerGetDatum(chosenShards),
		CStringGetTextDatum(format_procedure_qualified(nodeFunction))
	};
	char argNulls[4] = { ' ', ' ', ' ', ' ' };

	List *resultList = NIL;

	int tupleCountLimit = 0;
	if (SPI_execute_with_args(s.data, nargs, argTypes, argValues, argNulls,
							  readOnly, tupleCountLimit) != SPI_OK_SELECT)
	{
		ereport(ERROR, (errmsg("could not run SPI query")));
	}

	for (uint64 i = 0; i < SPI_processed && SPI_tuptable; i++)
	{
		AttrNumber attrNumber = 1;
		bool isNull = false;
		Datum resultDatum = SPI_getbinval(SPI_tuptable->vals[i],
										  SPI_tuptable->tupdesc, attrNumber, &isNull);
		if (isNull)
		{
			/* this shard did not process any responses*/
			continue;
		}

		pgbson *resultBson = DatumGetPgBson(resultDatum);
		MemoryContext oldContext = MemoryContextSwitchTo(targetContext);
		pgbson *copiedBson = CopyPgbsonIntoMemoryContext(resultBson, targetContext);
		resultList = lappend(resultList, copiedBson);
		MemoryContextSwitchTo(oldContext);
	}

	SPI_finish();

	return resultList;
}


List *
ExecutePerNodeCommand(Oid nodeFunction, pgbson *nodeFunctionArg, bool readOnly, const
					  char *distributedTableName, bool backFillCoordinator)
{
	if (IsSingleNodeCluster())
	{
		Datum result = OidFunctionCall1(nodeFunction, PointerGetDatum(nodeFunctionArg));
		return list_make1(DatumGetPgBson(result));
	}

	ArrayType *chosenTables = GetTablesNamesPerNode();
	if (chosenTables == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Failed to get shards for table per node"),
						errdetail_log(
							"Failed to get shard names for distributed table %s",
							distributedTableName)));
	}

	Datum *perNodeTables;
	bool *perNodeNulls;
	int numNodes = 0;
	deconstruct_array(chosenTables, TEXTOID, -1, false, TYPALIGN_INT, &perNodeTables,
					  &perNodeNulls, &numNodes);

	if (numNodes == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("No nodes found for distributed table"),
						errdetail_log(
							"No nodes found for distributed table %s",
							distributedTableName)));
	}

	HTAB *tableNames = CreateStringViewHashSet();

	List *finalResults = NIL;
	bool coordinatorHasNoPlacements = false;
	for (int i = 0; i < numNodes; i++)
	{
		if (perNodeNulls[i])
		{
			if (i == 0)
			{
				coordinatorHasNoPlacements = true;
			}
			else
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg("Node %d has no placements for distributed table",
									   i),
								errdetail_log(
									"Node %d has no placements for distributed table %s",
									i, distributedTableName)));
			}

			/* There is no table to dispatch over for this node. */
			continue;
		}

		text *tableName = DatumGetTextP(perNodeTables[i]);
		StringView tableNameView = CreateStringViewFromText(tableName);

		bool foundKey = false;
		hash_search(tableNames, &tableNameView, HASH_FIND, &foundKey);

		if (foundKey)
		{
			/* We already handled this node via this table, move on */
			continue;
		}

		hash_search(tableNames, &tableNameView, HASH_ENTER, &foundKey);

		char *tableNameCStr = text_to_cstring(tableName);
		List *nodeLevelResults = ExecutePerNodeCommandCore(nodeFunction, nodeFunctionArg,
														   readOnly, tableNameCStr);
		pfree(tableNameCStr);
		finalResults = list_concat(finalResults, nodeLevelResults);
	}

	pfree(perNodeTables);
	pfree(perNodeNulls);
	pfree(chosenTables);
	hash_destroy(tableNames);

	/* If requested, also run on the coordinator if it doesn't have shards for the table as the command_node_worker
	 * only runs on nodes with shards for the given table. We need to ensure metadata and system catalog are consistent in the coordinator
	 * specially for management operations like add node, rebalancing, etc. */
	if (backFillCoordinator && IsMetadataCoordinator() &&
		coordinatorHasNoPlacements)
	{
		Datum result = OidFunctionCall1(nodeFunction,
										PointerGetDatum(nodeFunctionArg));
		pgbson *resultBson = DatumGetPgBson(result);
		finalResults = lappend(finalResults, resultBson);
	}

	return finalResults;
}
