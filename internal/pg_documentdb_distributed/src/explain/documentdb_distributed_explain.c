/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/explain/documentdb_distributed_explain.c
 *
 * Base Implementation and Definitions for distributed explain for documentdb.
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
#include "distributed_hooks.h"


static bool DocumentDBDistributedExplain(pgbson_writer *writer, QueryDesc *queryDesc,
										 PlanState *planState,
										 void (*stageWriteFunc)(pgbson_writer *, const
																char *,
																QueryDesc *,
																PlanState *));

void
RegisterDistributedExplainStageHook()
{
	explain_stage_hook = DocumentDBDistributedExplain;
}


static bool
DocumentDBDistributedExplain(pgbson_writer *writer, QueryDesc *queryDesc,
							 PlanState *planState,
							 void (*stageWriteFunc)(pgbson_writer *, const char *,
													QueryDesc *, PlanState *))
{
	if (IsA(planState, CustomScanState))
	{
		CustomScanState *customScanState = (CustomScanState *) planState;
		if (strcmp(customScanState->methods->CustomName, "AdaptiveExecutorScan") == 0)
		{
			/* TODO: Handle this scenario for explain. */
			elog(NOTICE, "Handling custom distributed explain");
			return true;
		}
	}

	return false;
}
