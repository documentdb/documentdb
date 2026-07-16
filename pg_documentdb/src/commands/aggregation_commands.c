/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/aggregation_cursors.c
 *
 * Implementation of the cursor based operations for aggregation/find queries.
 * This wraps around the query
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <funcapi.h>
#include <common/pg_prng.h>
#include <executor/executor.h>
#include <utils/varlena.h>
#include <access/xact.h>
#include <storage/proc.h>
#include <utils/backend_status.h>
#include <utils/lsyscache.h>
#include <utils/array.h>

#include <metadata/metadata_cache.h>
#include <utils/documentdb_errors.h>
#include <utils/feature_counter.h>
#include "utils/version_utils.h"
#include <io/bson_core.h>
#include <commands/cursor_private.h>
#include "commands/parse_error.h"
#include <aggregation/bson_aggregation_pipeline.h>
#include "aggregation/aggregation_commands.h"
#include "infrastructure/cursor_store.h"
#include <utils/query_utils.h>
#include <utils/guc_utils.h>
#include "metadata/collection.h"
#include "api_hooks.h"


extern bool UseFileBasedPersistedCursors;
extern bool EnableDelayedHoldPortal;
extern bool EnableDynamicCursors;
extern bool EnableTailableCursorMaxAwaitTime;
extern int DefaultTailableCursorMaxAwaitTimeMs;
extern bool EnablePGPrngCursorId;
extern bool ReportParallelPlanInCursorContinuation;

/* --------------------------------------------------------- */
/* Data types */
/* --------------------------------------------------------- */


static const int64_t CursorAcceptableBitsMask = 0x1FFFFFFFFFFFFF;

static const int64_t NoMaxAwaitTimeMs = 0;

static uint32_t current_cursor_count = 0;

/*
 * Enum for the type of cursor for this query.
 */
typedef enum CursorKind
{
	/*
	 * The cursor is a streaming cursor.
	 */
	CursorKind_Streaming = 1,

	/*
	 * The cursor is a hold-portal persisted cursor (a backend cursor held open
	 * across getMore calls).
	 */
	CursorKind_Persisted = 2,

	/*
	 * The cursor is a tailable cursor.
	 */
	CursorKind_Tailable = 3,

	/*
	 * The cursor was a dynamic query that was determined to be
	 * streaming capable.
	 */
	CursorKind_DynamicStreaming = 4,

	/*
	 * Unified getMore dispatch kind for remote dynamic cursors. The coordinator
	 * dispatches the drain to the worker and forwards the page; the worker
	 * self-selects streaming vs file from the opaque continuation content and
	 * reports its own granular feature counters.
	 */
	CursorKind_DynamicRemote = 5,

	/*
	 * The cursor is a file-based persisted cursor whose results were
	 * materialized to a worker-side file and are resumed from that file state on
	 * each getMore.
	 */
	CursorKind_PersistedFile = 6,
} CursorKind;


/*
 * The type of query command provided
 */
typedef enum QueryKind
{
	/*
	 * The user query is a 'find' query.
	 */
	QueryKind_Find = 1,

	/*
	 * The user query is a 'aggregate' query.
	 */
	QueryKind_Aggregate = 2,

	/*
	 * The user query is a 'listCollections' query.
	 */
	QueryKind_ListCollections = 3,

	/*
	 * The user query is a 'listIndexes' query.
	 */
	QueryKind_ListIndexes = 4,
} QueryKind;


/*
 * Cursor related info for the subsequent pages of a find/aggregate request (getMore)
 */
typedef struct
{
	/*
	 * Whether the first request was streamable or persisted
	 */
	CursorKind cursorKind;

	/*
	 * CursorId associated with this query.
	 */
	int64_t cursorId;

	/*
	 * The persisted cursor name in postgres.
	 */
	const char *cursorName;

	/*
	 * The query spec for a streamable cursor.
	 */
	pgbson *querySpec;

	/*
	 * The original query's query kind (find/aggregate)
	 */
	QueryKind queryKind;

	/*
	 * The current page's cursor info.
	 */
	QueryData queryData;

	/*
	 * The cursor state for the current page if using
	 * file based persisted cursors.
	 */
	bytea *cursorFileState;

	/*
	 * cursor state for dynamic streaming cursors. For remote dynamic cursors this
	 * holds the opaque worker continuation ("wc") passed straight back to the
	 * worker on getMore.
	 */
	pgbson *dynamicCursorState;

	/*
	 * Distributed table OID for remote dynamic streaming cursors.
	 * Used to route the pushdown UDF to the correct worker.
	 */
	Oid distributedTableOid;

	/*
	 * numIterations parsed from the continuation's "numIters" field.
	 * Tracked across getMore pages for diagnostic purposes.
	 */
	int32_t numIterations;
} QueryGetMoreInfo;

typedef struct LocalFirstPageResult
{
	pgbson *resultDocument;
	pgbson *continuationDoc;
	bool persistConnection;
	int64_t cursorId;
} LocalFirstPageResult;

/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */

static void ParseGetMoreSpec(text **database, pgbson *getMoreSpec, pgbson *cursorSpec,
							 QueryGetMoreInfo *getMoreInfo, bool setStatementTimeout);

static pgbson * BuildStreamingContinuationDocument(HTAB *cursorMap, pgbson *querySpec,
												   int64_t cursorId, QueryKind queryKind,
												   TimeSystemVariables *
												   timeSystemVariables,
												   int numIterations);
static pgbson * BuildTailableContinuationDocument(pgbson *continuationDoc,
												  pgbson *querySpec,
												  int64_t cursorId, QueryKind queryKind,
												  TimeSystemVariables *
												  timeSystemVariables,
												  int numIterations);

static pgbson * BuildDynamicStreamingContinuationDocument(int64_t cursorId, QueryKind
														  queryKind,
														  pgbson *querySpec, int
														  numIterations,
														  pgbson *continuationDoc,
														  TimeSystemVariables *
														  timeSystemVariables);

static pgbson * BuildPersistedContinuationDocument(const char *cursorName, int64_t
												   cursorId, QueryKind queryKind,
												   TimeSystemVariables *
												   timeSystemVariables,
												   int numIterations,
												   bool hasParallelPlan);

static pgbson * BuildPersistedFileContinuationDocument(const char *cursorName, int64_t
													   cursorId, QueryKind queryKind,
													   TimeSystemVariables *
													   timeSystemVariables,
													   int numIterations,
													   bytea *continuationState,
													   bool hasParallelPlan);

static Datum HandleRemoteUnshardedFirstPage(text *database, pgbson *querySpec,
											int64_t cursorId, QueryData *queryData,
											QueryKind queryKind,
											MongoCollection *collection);
static Datum HandleLocalFirstPageRequest(text *database, pgbson *querySpec,
										 int64_t cursorId, QueryData *queryData,
										 QueryKind queryKind, Query *query);
static bool CanDispatchRemoteUnshardedFirstPage(MongoCollection *collection);

static int64_t GenerateCursorId(int64_t inputValue);

static void ReportCursorTopologyFeatureUsage(CursorTopology topology);

static Query * GenerateCursorQueryForKind(text *database, pgbson *querySpec,
										  QueryData *queryData, QueryKind queryKind,
										  CursorParamKind cursorParamKind,
										  bool setStatementTimeout);

/*
 * Result of a remote worker drain page. The worker returns the batch already
 * materialized in outbound cursor-page shape (pageBson, with cursor.id = 0),
 * so the coordinator forwards it without re-serializing the batch.
 */
typedef struct RemoteCursorPageResult
{
	/* Full cursor page { cursor: { id, ns, firstBatch|nextBatch }, ok }. */
	pgbson *pageBson;

	/* Worker page state: 0 = drained, non-zero = remote dynamic cursor has more. */
	int32 cursorType;

	/* Opaque worker continuation (NULL when drained). */
	pgbson *continuation;
} RemoteCursorPageResult;

static RemoteCursorPageResult DrainRemoteCursorPage(text *database,
													QueryKind queryKind,
													pgbson *querySpec,
													pgbson *workerContinuation,
													int batchSize,
													MongoCollection *collection);

static void PatchCursorPageId(pgbson *pageBson, int64_t cursorId);
static Datum FormCursorResultDatum(pgbson *cursorPage, pgbson *continuation,
								   bool persistConnection, int64_t cursorId,
								   TupleDesc tupleDesc);

static pgbson * BuildRemoteCursorContinuationDocument(int64_t cursorId,
													  QueryKind queryKind,
													  pgbson *querySpec,
													  int numIterations,
													  pgbson *workerContinuation,
													  Oid distributedTableOid,
													  TimeSystemVariables *
													  timeSystemVariables);


/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

PG_FUNCTION_INFO_V1(command_aggregate_cursor_first_page);
PG_FUNCTION_INFO_V1(command_find_cursor_first_page);
PG_FUNCTION_INFO_V1(command_count_query);
PG_FUNCTION_INFO_V1(command_distinct_query);
PG_FUNCTION_INFO_V1(command_cursor_get_more);
PG_FUNCTION_INFO_V1(command_list_collections_cursor_first_page);
PG_FUNCTION_INFO_V1(command_list_indexes_cursor_first_page);
PG_FUNCTION_INFO_V1(command_delete_cursors);
PG_FUNCTION_INFO_V1(command_cursor_dynamic_drain_page);

/*
 * Parses an aggregate spec and creates a query, executes it and returns the first page
 * along with the cursor information associated with the aggregate query.
 */
Datum
command_aggregate_cursor_first_page(PG_FUNCTION_ARGS)
{
	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *aggregationSpec = PG_GETARG_PGBSON(1);
	int64_t cursorId = PG_ARGISNULL(2) ? 0 : PG_GETARG_INT64(2);

	Datum response = aggregate_cursor_first_page(database, aggregationSpec, cursorId);

	PG_RETURN_DATUM(response);
}


/*
 * Returns true when a remote-unsharded collection's first-page cursor request
 * may be dispatched to the worker drain UDF.
 *
 * The dispatch routes the query to a worker over a distributed connection, which
 * cannot be performed once the backend has already been assigned a distributed
 * transaction id. Mirror TryGetCollectionShardTable's guard and skip remote
 * dispatch inside an explicit transaction block (unless local-shard execution is
 * being forced) so we fall back to the transaction-block-safe local cursor path.
 */
inline static bool
CanDispatchRemoteUnshardedFirstPage(MongoCollection *collection)
{
	return EnableDynamicCursors && collection != NULL && collection->isShardRemote &&
		   collection->shardKey == NULL && IsClusterVersionAtleast(DocDB_V0, 112, 2);
}


Datum
aggregate_cursor_first_page(text *database, pgbson *aggregationSpec,
							int64_t cursorId)
{
	ReportFeatureUsage(FEATURE_COMMAND_AGG_CURSOR_FIRST_PAGE);

	CursorParamKind cursorParamKind = EnableDynamicCursors ? CursorParamKind_Dynamic :
									  CursorParamKind_Streaming;
	bool setStatementTimeout = true;
	QueryData queryData = GenerateFirstPageQueryData();

	/*
	 * Parse the spec, extract the pipeline stages, and look up the collection
	 * without generating the query yet, so we can branch to remote dispatch (and
	 * skip the otherwise-discarded local query generation) for remote-unsharded
	 * collections.
	 */
	MongoCollection *collection = NULL;
	AggregationQueryPlan *plan = ParseAggregationQueryAndLookupCollection(
		database, aggregationSpec, &queryData, cursorParamKind,
		setStatementTimeout, &collection);

	/* We can't support dynamic cursors for tailable cursors as tailable cursors do their own remote dispatch management. */
	if (queryData.cursorKind != QueryCursorType_Tailable &&
		CanDispatchRemoteUnshardedFirstPage(collection))
	{
		/*
		 * SetCursorTopology (normally run inside ApplyParsedAggregationQuery) is
		 * skipped on this path, so set the remote-unsharded topology explicitly.
		 * namespaceName was already populated by
		 * ParseAggregationQueryAndLookupCollection.
		 */
		queryData.cursorTopology = CursorTopology_RemoteUnsharded;
		return HandleRemoteUnshardedFirstPage(database, aggregationSpec, cursorId,
											  &queryData, QueryKind_Aggregate,
											  collection);
	}

	Query *query = ApplyParsedAggregationQuery(plan);

	return HandleLocalFirstPageRequest(database, aggregationSpec, cursorId,
									   &queryData, QueryKind_Aggregate, query);
}


/*
 * Parses an find spec and creates a query, executes it and returns the first page
 * along with the cursor information associated with the find query.
 */
Datum
command_find_cursor_first_page(PG_FUNCTION_ARGS)
{
	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *findSpec = PG_GETARG_PGBSON(1);
	int64_t cursorId = PG_ARGISNULL(2) ? 0 : PG_GETARG_INT64(2);

	Datum response = find_cursor_first_page(database, findSpec, cursorId);
	PG_RETURN_DATUM(response);
}


Datum
find_cursor_first_page(text *database, pgbson *findSpec, int64_t cursorId)
{
	ReportFeatureUsage(FEATURE_COMMAND_FIND_CURSOR_FIRST_PAGE);

	/* Parse the find spec for the purposes of query execution */
	QueryData queryData = GenerateFirstPageQueryData();
	CursorParamKind cursorParams = EnableDynamicCursors ? CursorParamKind_Dynamic :
								   CursorParamKind_Streaming;
	bool setStatementTimeout = true;

	/*
	 * Parse the spec and look up the collection without generating the query yet,
	 * so we can branch to remote dispatch (and skip the otherwise-discarded local
	 * query generation) for remote-unsharded collections.
	 */
	MongoCollection *collection = NULL;
	FindQueryPlan *plan = ParseFindQueryAndLookupCollection(
		database, findSpec, &queryData, setStatementTimeout,
		&collection);

	if (CanDispatchRemoteUnshardedFirstPage(collection))
	{
		/*
		 * SetCursorTopology (normally run inside ApplyFindSpec) is skipped on this
		 * path, so set the remote-unsharded topology explicitly. namespaceName was
		 * already populated by ParseFindQueryAndLookupCollection.
		 */
		queryData.cursorTopology = CursorTopology_RemoteUnsharded;
		return HandleRemoteUnshardedFirstPage(database, findSpec, cursorId,
											  &queryData, QueryKind_Find,
											  collection);
	}

	Query *query = ApplyParsedFindQuery(plan, cursorParams);

	return HandleLocalFirstPageRequest(database, findSpec, cursorId, &queryData,
									   QueryKind_Find, query);
}


/*
 * Parses a listCollections spec and creates a query, executes it and returns the first page
 * along with the cursor information associated with the listCollections query.
 */
Datum
command_list_collections_cursor_first_page(PG_FUNCTION_ARGS)
{
	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *listCollectionsSpec = PG_GETARG_PGBSON(1);

	Datum response = list_collections_first_page(database, listCollectionsSpec);
	PG_RETURN_DATUM(response);
}


Datum
list_collections_first_page(text *database, pgbson *listCollectionsSpec)
{
	ReportFeatureUsage(FEATURE_COMMAND_LIST_COLLECTIONS_CURSOR_FIRST_PAGE);

	QueryData queryData = GenerateFirstPageQueryData();
	bool setStatementTimeout = true;
	Query *query = GenerateListCollectionsQuery(database, listCollectionsSpec, &queryData,
												setStatementTimeout);

	/* TODO: Remove these restrictions */
	queryData.cursorKind = QueryCursorType_SingleBatch;
	queryData.batchSize = INT_MAX;

	int64_t cursorId = 0;
	Datum response = HandleLocalFirstPageRequest(
		database, listCollectionsSpec, cursorId, &queryData,
		QueryKind_ListCollections, query);
	return response;
}


/*
 * Parses a listIndexes spec and creates a query, executes it and returns the first page
 * along with the cursor information associated with the listIndexes query.
 */
Datum
command_list_indexes_cursor_first_page(PG_FUNCTION_ARGS)
{
	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *listIndexesSpec = PG_GETARG_PGBSON(1);

	Datum response = list_indexes_first_page(database, listIndexesSpec);
	PG_RETURN_DATUM(response);
}


Datum
list_indexes_first_page(text *database, pgbson *listIndexesSpec)
{
	ReportFeatureUsage(FEATURE_COMMAND_LIST_INDEXES_CURSOR_FIRST_PAGE);

	QueryData queryData = GenerateFirstPageQueryData();
	bool setStatementTimeout = true;
	Query *query = GenerateListIndexesQuery(database, listIndexesSpec, &queryData,
											setStatementTimeout);

	/* TODO: Remove these restrictions */
	queryData.cursorKind = QueryCursorType_SingleBatch;
	queryData.batchSize = INT_MAX;

	int64_t cursorId = 0;
	Datum response = HandleLocalFirstPageRequest(
		database, listIndexesSpec, cursorId, &queryData,
		QueryKind_ListIndexes, query);
	return response;
}


/*
 * Generates the underlying query for a cursor request based on the query kind
 * (find or aggregate). The caller is responsible for populating queryData (time
 * system variables, cursor state, etc.) before calling. Centralizes the
 * find-vs-aggregate dispatch shared across first-page, getMore, and the remote
 * worker drain paths.
 */
static Query *
GenerateCursorQueryForKind(text *database, pgbson *querySpec, QueryData *queryData,
						   QueryKind queryKind, CursorParamKind cursorParamKind,
						   bool setStatementTimeout)
{
	switch (queryKind)
	{
		case QueryKind_Find:
		{
			return GenerateFindQuery(database, querySpec, queryData,
									 cursorParamKind, setStatementTimeout);
		}

		case QueryKind_Aggregate:
		{
			return GenerateAggregationQuery(database, querySpec, queryData,
											cursorParamKind, setStatementTimeout);
		}

		default:
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Unsupported query kind for cursor: %d",
								   (int) queryKind)));
			pg_unreachable();
		}
	}
}


/*
 * Parses a getMore spec and a continuation cursor spec, extracts the query
 * associated with it executes it and returns the next page
 * along with the cursor information associated with the original query.
 */
Datum
command_cursor_get_more(PG_FUNCTION_ARGS)
{
	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *getMoreSpec = PG_GETARG_PGBSON(1);
	pgbson *cursorSpec = PG_GETARG_PGBSON(2);

	/* See sql/udfs/commands_crud/query_cursors_aggregate--latest.sql */
	AttrNumber maxOutAttrNum = 2;
	Datum responseDatum = aggregation_cursor_get_more(database, getMoreSpec,
													  cursorSpec, maxOutAttrNum);
	PG_RETURN_DATUM(responseDatum);
}


/*
 * Drains one getMore page for a cursor whose state lives locally on this node:
 * a hold-portal persisted cursor (CursorKind_Persisted), a file-based persisted
 * cursor (CursorKind_PersistedFile), or a (legacy or dynamic) streaming cursor
 * (CursorKind_Streaming / CursorKind_DynamicStreaming). Writes the page rows
 * into arrayWriter and returns the continuation document for the next getMore
 * (NULL when fully drained, with *queryFullyDrained set accordingly).
 *
 * This is shared by the coordinator getMore path (aggregation_cursor_get_more)
 * and the worker drain UDF (command_cursor_dynamic_drain_page) so both run the
 * identical local-cursor machinery. The remote-dynamic and tailable kinds are
 * special (re-dispatch / post-batch resume token) and are handled inline by the
 * coordinator rather than here.
 *
 * useFileBasedCursors selects whether file-based persisted cursors are allowed:
 * the session GUC on the coordinator, the coordinator-supplied option on the
 * worker (whose session GUC is not authoritative). isWorker selects the
 * worker-specific getMore feature counters.
 */
static pgbson *
DrainLocalCursorGetMorePage(text *database, pgbson *cursorSpec,
							QueryGetMoreInfo *getMoreInfo,
							pgbson_array_writer *arrayWriter,
							uint32_t accumulatedSize, bool useFileBasedCursors,
							bool isWorker, bool *queryFullyDrained)
{
	pgbson *continuationDoc = NULL;

	switch (getMoreInfo->cursorKind)
	{
		case CursorKind_PersistedFile:
		{
			if (isWorker)
			{
				ReportFeatureUsage(
					FEATURE_CURSOR_TYPE_DYNAMIC_REMOTE_WORKER_GETMORE_FILE);
			}

			int numIterations = 0;
			bool hasParallelPlan = false;
			getMoreInfo->cursorFileState = DrainPersistedFileCursor(
				getMoreInfo->cursorName, getMoreInfo->queryData.batchSize,
				&numIterations, accumulatedSize, arrayWriter,
				getMoreInfo->cursorFileState, useFileBasedCursors);
			*queryFullyDrained = getMoreInfo->cursorFileState == NULL;
			continuationDoc = *queryFullyDrained ? NULL :
							  BuildPersistedFileContinuationDocument(
				getMoreInfo->cursorName, getMoreInfo->cursorId,
				getMoreInfo->queryKind,
				&getMoreInfo->queryData.timeSystemVariables, numIterations,
				getMoreInfo->cursorFileState, hasParallelPlan);
			break;
		}

		case CursorKind_Persisted:
		{
			int numIterations = 0;
			bool hasParallelPlan = false;
			*queryFullyDrained = DrainPersistedCursor(
				getMoreInfo->cursorName, getMoreInfo->queryData.batchSize,
				&numIterations, accumulatedSize, arrayWriter);
			continuationDoc = *queryFullyDrained ? NULL :
							  BuildPersistedContinuationDocument(
				getMoreInfo->cursorName, getMoreInfo->cursorId,
				getMoreInfo->queryKind,
				&getMoreInfo->queryData.timeSystemVariables, numIterations,
				hasParallelPlan);
			break;
		}

		case CursorKind_Streaming:
		{
			QueryData queryData = { 0 };
			queryData.timeSystemVariables =
				getMoreInfo->queryData.timeSystemVariables;

			bool setStatementTimeout = false;
			Query *query = GenerateCursorQueryForKind(
				database, getMoreInfo->querySpec, &queryData,
				getMoreInfo->queryKind, CursorParamKind_Streaming,
				setStatementTimeout);

			ReportCursorTopologyFeatureUsage(queryData.cursorTopology);

			HTAB *cursorMap = CreateCursorHashSet();
			BuildContinuationMap(cursorSpec, cursorMap);

			int numIterations = 0;
			*queryFullyDrained = DrainStreamingQuery(
				cursorMap, query, getMoreInfo->queryData.batchSize,
				&numIterations, accumulatedSize, arrayWriter);
			continuationDoc = *queryFullyDrained ? NULL :
							  BuildStreamingContinuationDocument(
				cursorMap, getMoreInfo->querySpec, getMoreInfo->cursorId,
				getMoreInfo->queryKind,
				&getMoreInfo->queryData.timeSystemVariables, numIterations);
			hash_destroy(cursorMap);
			break;
		}

		case CursorKind_DynamicStreaming:
		{
			QueryData queryData = { 0 };
			queryData.timeSystemVariables =
				getMoreInfo->queryData.timeSystemVariables;
			queryData.cursorStateConst = getMoreInfo->dynamicCursorState;

			bool setStatementTimeout = false;
			Query *query = GenerateCursorQueryForKind(
				database, getMoreInfo->querySpec, &queryData,
				getMoreInfo->queryKind, CursorParamKind_Dynamic,
				setStatementTimeout);

			bool isDynamicStreaming = false;
			QueryCursorPlanResult *planResult =
				PlanDynamicQueryAndDetermineCursorType(query, &isDynamicStreaming);
			if (!isDynamicStreaming)
			{
				ereport(ERROR, (errmsg(
									"Query started as a streaming, but became persistent. This is unexpected")));
			}

			if (isWorker)
			{
				ReportFeatureUsage(
					FEATURE_CURSOR_TYPE_DYNAMIC_REMOTE_WORKER_GETMORE_STREAMING);
			}
			else
			{
				ReportCursorTopologyFeatureUsage(queryData.cursorTopology);
				ReportFeatureUsage(FEATURE_CURSOR_TYPE_DYNAMIC_STREAMING);
			}

			pgbson *sourceDoc = getMoreInfo->dynamicCursorState;
			pgbson *innerDoc = DrainDynamicStreamingCursor(
				planResult, getMoreInfo->queryData.batchSize, sourceDoc,
				arrayWriter, accumulatedSize);

			if (innerDoc == NULL)
			{
				*queryFullyDrained = true;
				continuationDoc = NULL;
			}
			else
			{
				*queryFullyDrained = false;
				continuationDoc = BuildDynamicStreamingContinuationDocument(
					getMoreInfo->cursorId, getMoreInfo->queryKind,
					getMoreInfo->querySpec, 1, innerDoc,
					&getMoreInfo->queryData.timeSystemVariables);
			}
			break;
		}

		default:
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Unsupported local cursor kind %d for getMore",
								   (int) getMoreInfo->cursorKind)));
			pg_unreachable();
		}
	}

	return continuationDoc;
}


Datum
aggregation_cursor_get_more(text *database, pgbson *getMoreSpec,
							pgbson *cursorSpec, AttrNumber maxResponseAttributeNumber)
{
	ReportFeatureUsage(FEATURE_COMMAND_GET_MORE);

	TupleDesc tupleDesc = ConstructCursorResultTupleDesc(maxResponseAttributeNumber);

	QueryGetMoreInfo getMoreInfo = { 0 };
	bool getMoreSetStatementTimeout = true;
	ParseGetMoreSpec(&database, getMoreSpec, cursorSpec, &getMoreInfo,
					 getMoreSetStatementTimeout);

	pgbson_writer writer;
	pgbson_writer cursorDoc;
	pgbson_array_writer arrayWriter;

	/* min bson size is 5 (see IsPgbsonEmptyDocument) */
	uint32_t accumulatedSize = 5;

	/* Write the preamble for the cursor response */
	bool isFirstPage = false;
	SetupCursorPagePreamble(&writer, &cursorDoc, &arrayWriter,
							getMoreInfo.queryData.namespaceName,
							isFirstPage,
							&accumulatedSize);

	bool queryFullyDrained;
	pgbson *continuationDoc;
	pgbson *postBatchResumeToken = NULL;
	int64_t maxAwaitTimeMS = NoMaxAwaitTimeMs;
	switch (getMoreInfo.cursorKind)
	{
		case CursorKind_PersistedFile:
		case CursorKind_Persisted:
		case CursorKind_Streaming:
		case CursorKind_DynamicStreaming:
		{
			/*
			 * These cursor kinds keep their state locally on the coordinator;
			 * the shared drainer runs the page drain and builds the next
			 * continuation. Remote-dynamic and tailable are handled below.
			 */
			bool isWorker = false;
			continuationDoc = DrainLocalCursorGetMorePage(
				database, cursorSpec, &getMoreInfo, &arrayWriter,
				accumulatedSize, UseFileBasedPersistedCursors, isWorker,
				&queryFullyDrained);
			break;
		}

		case CursorKind_DynamicRemote:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TYPE_DYNAMIC_REMOTE_GETMORE);

			pgbson *rmQuerySpec = getMoreInfo.querySpec != NULL ?
								  getMoreInfo.querySpec : PgbsonInitEmpty();

			/*
			 * Pass the opaque worker continuation ("wc") straight back; the worker
			 * self-selects streaming vs file from its content (a "qf" file-state
			 * key implies a file cursor). The distributed table OID stored in the
			 * continuation is the collection's relation OID, so recover the
			 * collection to form the shard source table name.
			 */
			bool requireShardTable = false;
			MongoCollection *remoteCollection = GetMongoCollectionByRelationOid(
				getMoreInfo.distributedTableOid, requireShardTable);
			if (remoteCollection == NULL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_QUERYPLANKILLED),
								errmsg("Could not resolve distributed table %s for "
									   "remote cursor",
									   getMoreInfo.queryData.namespaceName)));
			}

			RemoteCursorPageResult page = DrainRemoteCursorPage(
				database,
				getMoreInfo.queryKind,
				rmQuerySpec,
				getMoreInfo.dynamicCursorState,
				getMoreInfo.queryData.batchSize,
				remoteCollection);

			pgbson *remoteContinuation = NULL;
			if (page.cursorType != 0 && page.continuation != NULL)
			{
				PatchCursorPageId(page.pageBson, getMoreInfo.cursorId);
				remoteContinuation = BuildRemoteCursorContinuationDocument(
					getMoreInfo.cursorId,
					getMoreInfo.queryKind,
					rmQuerySpec,
					getMoreInfo.numIterations + 1,
					page.continuation,
					getMoreInfo.distributedTableOid,
					&getMoreInfo.queryData.timeSystemVariables);
			}

			return FormCursorResultDatum(page.pageBson, remoteContinuation, false,
										 getMoreInfo.cursorId, tupleDesc);
		}

		case CursorKind_Tailable:
		{
			Query *query;

			/* In a getMore the query itself is known to be tailable, we don't need to do
			 * any cursor handling since the stage would output the fact that it's tailable as part of parsing.
			 */
			CursorParamKind cursorParams = CursorParamKind_Persistent;
			QueryData queryData = { 0 };
			queryData.timeSystemVariables = getMoreInfo.queryData.timeSystemVariables;

			bool setStatementTimeout = false;
			query = GenerateAggregationQuery(database,
											 getMoreInfo.querySpec, &queryData,
											 cursorParams, setStatementTimeout);
			ReportCursorTopologyFeatureUsage(queryData.cursorTopology);

			/* Extract the continuation sub-document from the full cursorSpec */
			pgbson *tailableCursorSpec = NULL;
			bson_iter_t cursorSpecIter;
			if (PgbsonInitIteratorAtPath(cursorSpec, "continuation",
										 &cursorSpecIter))
			{
				tailableCursorSpec = PgbsonInitFromDocumentBsonValue(
					bson_iter_value(&cursorSpecIter));
			}

			int numIterations = 0;
			postBatchResumeToken = DrainTailableQuery(tailableCursorSpec, query,
													  getMoreInfo.queryData.batchSize,
													  &numIterations,
													  accumulatedSize, &arrayWriter);
			continuationDoc = BuildTailableContinuationDocument(postBatchResumeToken,
																getMoreInfo.querySpec,
																getMoreInfo.cursorId,
																getMoreInfo.queryKind,
																&getMoreInfo.queryData.
																timeSystemVariables,
																numIterations);
			if (tailableCursorSpec != NULL)
			{
				pfree(tailableCursorSpec);
			}

			/*
			 * For tailable cursors with an empty batch, we return maxAwaitTimeMS
			 * so the gateway knows how long to poll.
			 * When data is present (numIterations > 0), we leave it at 0
			 * so the gateway returns the response immediately.
			 *
			 * When EnableTailableCursorMaxAwaitTime is off, we force the hint to
			 * 0 so the gateway polling loop never engages — even if a v2 caller
			 * provided a column for it in the result tuple.
			 */
			if (!EnableTailableCursorMaxAwaitTime)
			{
				maxAwaitTimeMS = NoMaxAwaitTimeMs;
			}
			else
			{
				maxAwaitTimeMS = getMoreInfo.queryData.maxAwaitTimeMS;
				if (numIterations > 0)
				{
					/* Data returned, so no need to wait */
					maxAwaitTimeMS = NoMaxAwaitTimeMs;
				}
				else if (maxAwaitTimeMS <= 0)
				{
					/* Empty batch, wait for default if not specified */
					maxAwaitTimeMS = DefaultTailableCursorMaxAwaitTimeMs;
				}
			}
			break;
		}

		default:
		{
			Assert(false);
			pg_unreachable();
		}
	}

	bool persistConnection = false;

	/*
	 * Pass maxAwaitTimeMS to the result tuple. Only tailable cursors
	 * (CursorKind_Tailable) set this to a non-zero value; for all other
	 * cursor kinds it remains 0.  FormFinalCursorResultTuple writes it into
	 * values[4] only when the TupleDesc has > 4 attributes (i.e. the V2
	 * SQL function is in use).
	 */
	int64_t cursorId = FinishWriteCursorPage(&cursorDoc, &arrayWriter, &writer,
											 getMoreInfo.cursorId, continuationDoc,
											 persistConnection, postBatchResumeToken);
	pgbson *resultDocument = PgbsonWriterGetPgbson(&writer);
	Datum responseDatum = FormFinalCursorResultTuple(resultDocument, continuationDoc,
													 persistConnection,
													 cursorId, maxAwaitTimeMS, tupleDesc);
	return responseDatum;
}


/*
 * Runs a Distinct query with a given spec against
 * the backend.
 */
Datum
command_distinct_query(PG_FUNCTION_ARGS)
{
	ReportFeatureUsage(FEATURE_COMMAND_DISTINCT);

	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *distinctSpec = PG_GETARG_PGBSON(1);

	bool setStatementTimeout = true;
	Query *query = GenerateDistinctQuery(database, distinctSpec, setStatementTimeout);

	pgbson *response = DrainSingleResultQuery(query);

	if (response == NULL)
	{
		pgbson_writer defaultWriter;
		PgbsonWriterInit(&defaultWriter);
		PgbsonWriterAppendEmptyArray(&defaultWriter, "values", 6);
		PgbsonWriterAppendDouble(&defaultWriter, "ok", 2, 1);
		response = PgbsonWriterGetPgbson(&defaultWriter);
	}

	PG_RETURN_POINTER(response);
}


/*
 * Runs a Count query with a given spec against
 * the backend.
 */
Datum
command_count_query(PG_FUNCTION_ARGS)
{
	ReportFeatureUsage(FEATURE_COMMAND_COUNT);

	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *countSpec = PG_GETARG_PGBSON(1);

	bool setStatementTimeout = true;
	Query *query = GenerateCountQuery(database, countSpec, setStatementTimeout);

	pgbson *response = DrainSingleResultQuery(query);
	if (response == NULL)
	{
		/* Generate default response */
		pgbson_writer defaultWriter;
		PgbsonWriterInit(&defaultWriter);
		PgbsonWriterAppendInt32(&defaultWriter, "n", 1, 0);
		PgbsonWriterAppendDouble(&defaultWriter, "ok", 2, 1);
		response = PgbsonWriterGetPgbson(&defaultWriter);
	}

	PG_RETURN_POINTER(response);
}


Datum
command_delete_cursors(PG_FUNCTION_ARGS)
{
	ArrayType *cursorArray = PG_GETARG_ARRAYTYPE_P(0);

	Datum response = delete_cursors(cursorArray);
	PG_RETURN_DATUM(response);
}


inline static const char *
FormatCursorName(StringInfo cursorStringInfo, int64_t cursorId)
{
	resetStringInfo(cursorStringInfo);
	appendStringInfo(cursorStringInfo, "cursor_%ld", cursorId);
	return cursorStringInfo->data;
}


Datum
delete_cursors(ArrayType *cursorArray)
{
	Datum *cursorIds;
	bool *nulls;
	int nelems;
	if (!UseFileBasedPersistedCursors)
	{
		return PointerGetDatum(PgbsonInitEmpty());
	}

	deconstruct_array(cursorArray, INT8OID, sizeof(int64_t), true, TYPALIGN_INT,
					  &cursorIds, &nulls, &nelems);

	StringInfo cursorStringInfo = makeStringInfo();
	for (int i = 0; i < nelems; i++)
	{
		if (nulls[i])
		{
			continue;
		}

		int64_t cursorId = DatumGetInt64(cursorIds[i]);
		const char *cursorName = FormatCursorName(cursorStringInfo, cursorId);
		DeleteCursorFile(cursorName);
	}

	return PointerGetDatum(PgbsonInitEmpty());
}


Query *
GenerateGetMoreQuery(text *database, pgbson *getMoreSpec, pgbson *continuationSpec,
					 QueryData *queryData, bool setStatementTimeout)
{
	QueryGetMoreInfo getMoreInfo = { 0 };
	ParseGetMoreSpec(&database, getMoreSpec, continuationSpec, &getMoreInfo,
					 setStatementTimeout);

	switch (getMoreInfo.cursorKind)
	{
		case CursorKind_Streaming:
		case CursorKind_DynamicStreaming:
		{
			Query *query;
			pgbson *workerSpec;
			CursorParamKind cursorParamKind;
			if (getMoreInfo.cursorKind == CursorKind_Streaming)
			{
				HTAB *cursorMap = CreateCursorHashSet();
				BuildContinuationMap(continuationSpec, cursorMap);
				workerSpec = SerializeContinuationForWorker(cursorMap,
															getMoreInfo.queryData.
															batchSize);
				cursorParamKind = CursorParamKind_Streaming;
			}
			else
			{
				workerSpec = getMoreInfo.dynamicCursorState;
				cursorParamKind = CursorParamKind_Dynamic;

				if (workerSpec == NULL)
				{
					ereport(ERROR, (errmsg(
										"Dynamic getMore cursor state has no resume continuation state")));
				}
			}

			/* Some blank query data to pass to the generation. */
			QueryData queryData = { 0 };
			queryData.timeSystemVariables =
				getMoreInfo.queryData.timeSystemVariables;
			queryData.cursorStateConst = workerSpec;
			query = GenerateCursorQueryForKind(database, getMoreInfo.querySpec,
											   &queryData, getMoreInfo.queryKind,
											   cursorParamKind, setStatementTimeout);

			return query;
		}

		case CursorKind_Persisted:
		case CursorKind_PersistedFile:
		case CursorKind_Tailable:
		case CursorKind_DynamicRemote:
		default:
		{
			/* This path doesn't build a new query on getMore - thunk to just calling the getmore Func */
			return BuildAggregationCursorGetMoreQuery(database, getMoreSpec,
													  continuationSpec);
		}
	}
}


/*
 * Handles the first page of a persisted (non-streaming) cursor.
 *
 * A persisted cursor materializes its remaining results so that later getMore
 * requests can resume it. The backend storage backing the cursor depends on the
 * mode:
 *   - a file-based cursor: the overflow beyond the first page is spilled to an
 *     on-disk cursor file (see cursor_store.c), or
 *   - a held SPI portal: the query plan is kept open as a portal whose tuples
 *     are held across the transaction boundary.
 * This function plans/opens that storage, drains the first batch into
 * "arrayWriter", and - when the cursor is not exhausted on the first page -
 * builds and returns the continuation document used by getMore. It also assigns
 * the client-facing cursor id into "*cursorId" and reports, via the out
 * parameters, whether the query fully drained and whether the connection must
 * be kept (held portals are connection-bound).
 *
 * Cursor id assignment (the backend cursor/file is always named "cursor_<id>"
 * via FormatCursorName). The client-facing id is what is returned to the client
 * and what killCursors/delete_cursors later uses to locate the file, so for
 * file cursors the backend name must equal "cursor_<client id>":
 *
 *   Condition                                          | cursor id for cursor name
 *   ---------------------------------------------------+----------------------
 *   *cursorId != 0 (caller supplied, e.g. tests)       | the provided cursor id
 *   *cursorId == 0 && (file cursor || !delayed hold)   | a generated cursor id
 *   *cursorId == 0 && delayed hold portal cursor       | a backend-local id
 *
 * The last row is the delayed-hold-portal optimization: a portal cursor that
 * fully drains on the first page never pays for id generation and never holds
 * the portal, so its name uses a cheap backend-local id ((pid << 32) | counter)
 * and the client id is generated lazily only if the cursor persists. File
 * cursors opt out of that lazy id because the file name has to be derivable
 * from the client id for killCursors to remove it.
 */
static pgbson *
HandlePersistentCursorCore(int64_t *cursorId, QueryCursorPlanResult *planResult,
						   bool *queryFullyDrained, bool *persistConnection,
						   QueryData *queryData, pgbson_array_writer *arrayWriter,
						   QueryKind queryKind, uint32_t accumulatedSize,
						   bool useFileBasedCursors)
{
	/*
	 * A singleBatch request must be served by the single-batch path
	 * (CreateAndDrainSingleBatchQuery), which returns exactly one batch and
	 * closes the cursor. It must never reach this persistent path, which
	 * materializes a file cursor or a held portal that resumes across getMore
	 * calls - that would both violate singleBatch semantics and leak a cursor.
	 * The first-page dispatch routes QueryCursorType_SingleBatch to its own
	 * case, so observing that kind here indicates a routing regression.
	 */
	Assert(queryData->cursorKind != QueryCursorType_SingleBatch);

	current_cursor_count++;
	int64_t cursorIdForBackendCursor;
	int32_t numIterations = 0;

	/*
	 * isHoldCursor indicates the cursor must outlive the current transaction.
	 * IsInTransactionBlock() is true only inside an explicit BEGIN...COMMIT
	 * block, where the cursor lives within that transaction and a later getMore
	 * runs in the same transaction. Outside such a block (the common case) each
	 * command is its own transaction, so the cursor must be "held" - persisted
	 * to a file or a held portal - to survive until the next getMore.
	 */
	bool isTopLevel = true;
	bool isHoldCursor = !IsInTransactionBlock(isTopLevel);

	/*
	 * File-based persisted cursors are cleaned up by killCursors
	 * (delete_cursors), which rebuilds the cursor file name from the
	 * client-facing cursor id. Such files must therefore be named after that id
	 * (and not after a backend-local id), otherwise killCursors cannot locate
	 * the file to remove it.
	 */
	bool useHoldFileCursor = isHoldCursor && useFileBasedCursors;

	bool hasParallelPlan = false;
	if (ReportParallelPlanInCursorContinuation)
	{
		hasParallelPlan = PlanResultHasParallelPlan(planResult);
	}

	pgbson *continuationDoc = NULL;
	if (*cursorId != 0)
	{
		cursorIdForBackendCursor = *cursorId;
	}
	else if (!EnableDelayedHoldPortal || useHoldFileCursor)
	{
		/*
		 * Non-delayed hold portal eagerly assigns the client cursor id. Same
		 * for file-based cursor which needs its file named after that id so killCursors
		 * can find it.
		 */
		*cursorId = GenerateCursorId(*cursorId);
		cursorIdForBackendCursor = *cursorId;
	}
	else
	{
		/* The non-file portal path  where delay until we confirm we need
		 * continuation, we keep the lazy assignment and generate a cheaper
		 * local id until we have to.
		 */
		cursorIdForBackendCursor = (((int64_t) MyProcPid) << 32) |
								   current_cursor_count;
	}

	StringInfo cursorStringInfo = makeStringInfo();
	const char *cursorName = FormatCursorName(cursorStringInfo,
											  cursorIdForBackendCursor);

	*persistConnection = isHoldCursor;
	bool closeCursor = false;

	if (useHoldFileCursor)
	{
		*persistConnection = false;
		bytea *cursorFileState = CreateAndDrainPersistedQueryWithFiles(cursorName,
																	   planResult,
																	   queryData->
																	   batchSize,
																	   &numIterations,
																	   accumulatedSize,
																	   arrayWriter,
																	   closeCursor,
																	   useFileBasedCursors);
		*queryFullyDrained = cursorFileState == NULL;

		if (!*queryFullyDrained)
		{
			continuationDoc = BuildPersistedFileContinuationDocument(cursorName,
																	 *cursorId,
																	 queryKind,
																	 &queryData->
																	 timeSystemVariables,
																	 numIterations,
																	 cursorFileState,
																	 hasParallelPlan);
		}
		else
		{
			/* Fully drained on the first page; report a closed cursor. */
			*cursorId = 0;
			continuationDoc = NULL;
		}
	}
	else
	{
		*queryFullyDrained = CreateAndDrainPersistedQuery(cursorName, planResult,
														  queryData->batchSize,
														  &numIterations,
														  accumulatedSize,
														  arrayWriter,
														  isHoldCursor,
														  closeCursor);
		if (!*queryFullyDrained)
		{
			*cursorId = GenerateCursorId(*cursorId);
			continuationDoc = BuildPersistedContinuationDocument(cursorName,
																 *cursorId,
																 queryKind,
																 &queryData->
																 timeSystemVariables,
																 numIterations,
																 hasParallelPlan);
		}
		else
		{
			/* Fully drained on the first page; report a closed cursor. */
			*cursorId = 0;
			continuationDoc = NULL;
		}
	}

	return continuationDoc;
}


/*
 * Dispatches a remote-unsharded first-page request to the worker UDF and builds
 * the cursor response. The worker forces local execution GUCs, plans the query,
 * and decides whether to use a streaming or file-based cursor:
 *   - Streamable queries return a streaming continuation ("continuation" key).
 *   - Non-streamable queries (e.g., with a sort) materialise to a worker-side
 *     file and return the standard persisted-file continuation ("qf" file state).
 * The coordinator inspects the returned BSON to choose the cursor kind.
 */
static Datum
HandleRemoteUnshardedFirstPage(text *database, pgbson *querySpec, int64_t cursorId,
							   QueryData *queryData, QueryKind queryKind,
							   MongoCollection *collection)
{
	/*
	 * The worker returns the first page already materialized in outbound
	 * cursor-page shape, so we forward it verbatim (patching cursor.id in place)
	 * and store the opaque worker continuation for getMore — without ever
	 * re-serializing the batch.
	 */
	RemoteCursorPageResult page = DrainRemoteCursorPage(
		database, queryKind, querySpec, PgbsonInitEmpty(),
		queryData->batchSize, collection);

	pgbson *continuationDoc = NULL;

	/*
	 * A singleBatch request (find "singleBatch": true / aggregate
	 * cursor.singleBatch) returns only the first batch and closes the cursor, so
	 * never expose a non-zero cursor id or a continuation even when the worker
	 * still has buffered rows. This mirrors the local first-page path's
	 * QueryCursorType_SingleBatch handling, which the remote-unsharded dispatch
	 * bypasses.
	 */
	bool isSingleBatch = queryData->cursorKind == QueryCursorType_SingleBatch;

	if (page.cursorType != 0 && page.continuation != NULL && !isSingleBatch)
	{
		ReportFeatureUsage(FEATURE_CURSOR_TYPE_DYNAMIC_REMOTE_FIRSTPAGE);
		cursorId = GenerateCursorId(cursorId);
		PatchCursorPageId(page.pageBson, cursorId);
		continuationDoc = BuildRemoteCursorContinuationDocument(
			cursorId, queryKind, querySpec, 1,
			page.continuation, collection->relationId,
			&queryData->timeSystemVariables);
	}
	else
	{
		/* Fully drained on the first page (or a singleBatch request). */
		cursorId = 0;
	}

	ReportCursorTopologyFeatureUsage(queryData->cursorTopology);

	AttrNumber maxOutAttrNum = 4;
	TupleDesc tupleDesc = ConstructCursorResultTupleDesc(maxOutAttrNum);
	bool persistConn = false;
	return FormCursorResultDatum(page.pageBson, continuationDoc, persistConn,
								 cursorId, tupleDesc);
}


/*
 * Given a pre-built query (for find/aggregate/list) handles the local cursor
 * request and builds a response for the first page.
 */
static LocalFirstPageResult
HandleLocalFirstPageRequestCore(text *database, pgbson *querySpec, int64_t cursorId,
								QueryData *queryData, QueryKind queryKind, Query *query,
								bool useFileBasedPersistentCursors)
{
	pgbson_writer writer;
	pgbson_writer cursorDoc;
	pgbson_array_writer arrayWriter;

	/* min bson size is 5 (see IsPgbsonEmptyDocument) */
	uint32_t accumulatedSize = 5;

	/* Write the preamble for the cursor response */
	bool isFirstPage = true;
	SetupCursorPagePreamble(&writer, &cursorDoc, &arrayWriter,
							queryData->namespaceName, isFirstPage,
							&accumulatedSize);

	/* now set up the query */
	int32_t numIterations = 0;
	bool queryFullyDrained;
	pgbson *continuationDoc;
	bool persistConnection = false;
	pgbson *postBatchResumeToken = NULL;
	switch (queryData->cursorKind)
	{
		case QueryCursorType_SingleBatch:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TYPE_SINGLE_BATCH);
			CreateAndDrainSingleBatchQuery("singleBatchCursor", query,
										   queryData->batchSize,
										   &numIterations,
										   accumulatedSize, &arrayWriter);
			queryFullyDrained = true;
			continuationDoc = NULL;
			cursorId = 0;
			break;
		}

		case QueryCursorType_Tailable:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TYPE_TAILABLE);

			pgbson *cursorSpec = NULL;
			postBatchResumeToken = DrainTailableQuery(cursorSpec,
													  query,
													  queryData->batchSize,
													  &numIterations,
													  accumulatedSize,
													  &arrayWriter);
			cursorId = GenerateCursorId(cursorId);
			continuationDoc = BuildTailableContinuationDocument(postBatchResumeToken,
																querySpec,
																cursorId, queryKind,
																&queryData->
																timeSystemVariables,
																numIterations);
			break;
		}

		case QueryCursorType_Streamable:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TYPE_STREAMING);

			Assert(queryData->cursorStateParamNumber == 1);
			HTAB *cursorMap = CreateCursorHashSet();
			queryFullyDrained = DrainStreamingQuery(cursorMap, query,
													queryData->batchSize,
													&numIterations, accumulatedSize,
													&arrayWriter);

			continuationDoc = NULL;
			if (!queryFullyDrained)
			{
				cursorId = GenerateCursorId(cursorId);
				continuationDoc = BuildStreamingContinuationDocument(cursorMap, querySpec,
																	 cursorId, queryKind,
																	 &queryData->
																	 timeSystemVariables,
																	 numIterations);
			}

			hash_destroy(cursorMap);
			break;
		}

		case QueryCursorType_Persistent:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TYPE_PERSISTENT);

			bool isTopLevel = true;
			bool isHoldCursor = !IsInTransactionBlock(isTopLevel);
			QueryCursorPlanResult *planResult = PlanForcedPersistentQuery(query,
																		  isHoldCursor);
			continuationDoc = HandlePersistentCursorCore(&cursorId, planResult,
														 &queryFullyDrained,
														 &persistConnection, queryData,
														 &arrayWriter, queryKind,
														 accumulatedSize,
														 useFileBasedPersistentCursors);
			break;
		}

		case QueryCursorType_PointRead:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TYPE_POINT_READ);

			if (queryData->batchSize < 1)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg(
									"Point read plan should have batch size >= 1, not %d",
									queryData->batchSize),
								errdetail_log(
									"Point read plan should have batch size >= 1, not %d",
									queryData->batchSize)));
			}

			CreateAndDrainPointReadQuery("pointReadCursor", query,
										 &numIterations,
										 accumulatedSize, &arrayWriter);
			queryFullyDrained = true;
			continuationDoc = NULL;
			break;
		}

		case QueryCursorType_Dynamic:
		{
			/* For dynamic queries, we first need to determine whether the query can be
			 * served as a streaming query or a persistent query.
			 * To do this, we first plan the query and get the streaming state.
			 */
			bool isDynamicStreaming = false;
			QueryCursorPlanResult *planResult = PlanDynamicQueryAndDetermineCursorType(
				query, &isDynamicStreaming);

			if (isDynamicStreaming)
			{
				ReportFeatureUsage(FEATURE_CURSOR_TYPE_DYNAMIC_STREAMING);
				persistConnection = false;

				pgbson *sourceDoc = PgbsonInitEmpty();
				pgbson *innerDoc = DrainDynamicStreamingCursor(planResult,
															   queryData->batchSize,
															   sourceDoc, &arrayWriter,
															   accumulatedSize);

				if (innerDoc == NULL)
				{
					queryFullyDrained = true;
					continuationDoc = NULL;
				}
				else
				{
					numIterations++;
					queryFullyDrained = false;
					cursorId = GenerateCursorId(cursorId);
					continuationDoc =
						BuildDynamicStreamingContinuationDocument(
							cursorId, queryKind, querySpec, numIterations,
							innerDoc, &queryData->timeSystemVariables);
				}
			}
			else
			{
				ReportFeatureUsage(FEATURE_CURSOR_TYPE_DYNAMIC_PERSISTENT);
				continuationDoc = HandlePersistentCursorCore(&cursorId, planResult,
															 &queryFullyDrained,
															 &persistConnection,
															 queryData, &arrayWriter,
															 queryKind, accumulatedSize,
															 useFileBasedPersistentCursors);
			}
			break;
		}

		default:
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Unknown query cursor kind detected - %d",
								   queryData->cursorKind)));
		}
	}

	/* Report cursor topology feature counter */
	ReportCursorTopologyFeatureUsage(queryData->cursorTopology);
	cursorId = FinishWriteCursorPage(&cursorDoc, &arrayWriter, &writer,
									 cursorId, continuationDoc,
									 persistConnection, postBatchResumeToken);
	pgbson *resultDocument = PgbsonWriterGetPgbson(&writer);
	LocalFirstPageResult firstPageResult =
	{
		.resultDocument = resultDocument,
		.continuationDoc = continuationDoc,
		.persistConnection = persistConnection,
		.cursorId = cursorId
	};
	return firstPageResult;
}


static Datum
HandleLocalFirstPageRequest(text *database, pgbson *querySpec, int64_t cursorId,
							QueryData *queryData, QueryKind queryKind, Query *query)
{
	/* See sql/udfs/commands_crud/query_cursors_aggregate--latest.sql */
	AttrNumber maxOutAttrNum = 4;
	TupleDesc tupleDesc = ConstructCursorResultTupleDesc(maxOutAttrNum);

	LocalFirstPageResult firstPageResult =
		HandleLocalFirstPageRequestCore(database, querySpec, cursorId, queryData,
										queryKind, query,
										UseFileBasedPersistedCursors);
	return FormFinalCursorResultTuple(firstPageResult.resultDocument,
									  firstPageResult.continuationDoc,
									  firstPageResult.persistConnection,
									  firstPageResult.cursorId, NoMaxAwaitTimeMs,
									  tupleDesc);
}


/*
 * Reports the feature counter for the given cursor topology.
 */
static void
ReportCursorTopologyFeatureUsage(CursorTopology topology)
{
	switch (topology)
	{
		case CursorTopology_LocalUnsharded:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TOPOLOGY_LOCAL_UNSHARDED);
			break;
		}

		case CursorTopology_RemoteUnsharded:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TOPOLOGY_REMOTE_UNSHARDED);
			break;
		}

		case CursorTopology_ShardedWithShardKeyEquality:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TOPOLOGY_SHARDED_WITH_SHARD_KEY_EQUALITY);
			break;
		}

		case CursorTopology_ShardedWithInOnShardKey:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TOPOLOGY_SHARDED_WITH_IN_ON_SHARD_KEY);
			break;
		}

		case CursorTopology_GeneralSharded:
		{
			ReportFeatureUsage(FEATURE_CURSOR_TOPOLOGY_GENERAL_SHARDED);
			break;
		}

		default:
		{
			break;
		}
	}
}


/*
 * Serializes a cursor document that can be reused by getMore for a streaming query.
 */
static pgbson *
BuildStreamingContinuationDocument(HTAB *cursorMap, pgbson *querySpec, int64_t cursorId,
								   QueryKind queryKind,
								   TimeSystemVariables *timeSystemVariables, int
								   numIterations)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt64(&writer, "qi", 2, cursorId);
	PgbsonWriterAppendBool(&writer, "qp", 2, false);

	PgbsonWriterAppendInt32(&writer, "qk", 2, (int) queryKind);

	/* Add the original query spec so that getMore can reuse it */
	/* For streaming cursor, save the query with "qc" key. */
	PgbsonWriterAppendDocument(&writer, "qc", 2, querySpec);

	SerializeContinuationsToWriter(&writer, cursorMap);

	/* In the response add the number of iterations (used in tests) */
	PgbsonWriterAppendInt32(&writer, "numIters", 8, numIterations);

	/* Add time system variables accordingly */
	if (timeSystemVariables != NULL && timeSystemVariables->nowValue.value_type !=
		BSON_TYPE_EOD)
	{
		PgbsonWriterAppendValue(&writer, "sn", 2, &timeSystemVariables->nowValue);
	}

	return PgbsonWriterGetPgbson(&writer);
}


/*
 * Serializes a cursor document that can be reused by getMore for a tailable query.
 */
static pgbson *
BuildTailableContinuationDocument(pgbson *continuationDoc, pgbson *querySpec,
								  int64_t cursorId,
								  QueryKind queryKind,
								  TimeSystemVariables *timeSystemVariables,
								  int numIterations)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt64(&writer, "qi", 2, cursorId);
	PgbsonWriterAppendBool(&writer, "qp", 2, false);

	PgbsonWriterAppendInt32(&writer, "qk", 2, (int) queryKind);

	/* Add the original query spec so that getMore can reuse it */
	/* For tailable cursor, save the query with "qt" to differentiate from streaming query. */
	PgbsonWriterAppendDocument(&writer, "qt", 2, querySpec);

	/*
	 * continuationDoc may be NULL when the underlying tailable pipeline
	 * yields no rows (and therefore no resume token) on a given page.
	 */
	if (continuationDoc != NULL)
	{
		PgbsonWriterAppendDocument(&writer, "continuation", 12, continuationDoc);
	}

	/* In the response add the number of iterations (used in tests) */
	PgbsonWriterAppendInt32(&writer, "numIters", 8, numIterations);

	/* Add time system variables accordingly */
	if (timeSystemVariables != NULL && timeSystemVariables->nowValue.value_type !=
		BSON_TYPE_EOD)
	{
		PgbsonWriterAppendValue(&writer, "sn", 2, &timeSystemVariables->nowValue);
	}

	return PgbsonWriterGetPgbson(&writer);
}


static pgbson *
BuildDynamicStreamingContinuationDocument(int64_t cursorId, QueryKind queryKind,
										  pgbson *querySpec, int numIterations,
										  pgbson *continuationDoc,
										  TimeSystemVariables *timeSystemVariables)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt64(&writer, "qi", 2, cursorId);
	PgbsonWriterAppendBool(&writer, "qp", 2, false);

	PgbsonWriterAppendInt32(&writer, "qk", 2, (int) queryKind);

	/* Add the original query spec so that getMore can reuse it */
	/* For dynamic streaming cursor, save the query with "qd" key. */
	PgbsonWriterAppendDocument(&writer, "qd", 2, querySpec);

	PgbsonWriterAppendDocument(&writer, "dc", 2, continuationDoc);

	/* In the response add the number of iterations (used in tests) */
	PgbsonWriterAppendInt32(&writer, "numIters", 8, numIterations);

	/* Add time system variables accordingly */
	if (timeSystemVariables != NULL && timeSystemVariables->nowValue.value_type !=
		BSON_TYPE_EOD)
	{
		PgbsonWriterAppendValue(&writer, "sn", 2, &timeSystemVariables->nowValue);
	}

	return PgbsonWriterGetPgbson(&writer);
}


static pgbson *
BuildPersistedFileContinuationDocument(const char *cursorName, int64_t
									   cursorId, QueryKind queryKind,
									   TimeSystemVariables *
									   timeSystemVariables,
									   int numIterations,
									   bytea *continuationState,
									   bool hasParallelPlan)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt64(&writer, "qi", 2, cursorId);
	PgbsonWriterAppendBool(&writer, "qp", 2, true);

	/* Add the original query spec so that getMore can reuse it */
	PgbsonWriterAppendInt32(&writer, "qk", 2, (int) queryKind);
	PgbsonWriterAppendUtf8(&writer, "qn", 2, cursorName);

	bson_value_t continuationValue;
	continuationValue.value_type = BSON_TYPE_BINARY;
	continuationValue.value.v_binary.subtype = BSON_SUBTYPE_BINARY;
	continuationValue.value.v_binary.data = (uint8_t *) continuationState;
	continuationValue.value.v_binary.data_len = VARSIZE(continuationState);
	PgbsonWriterAppendValue(&writer, "qf", 2, &continuationValue);

	/* In the response add the number of iterations (used in tests) */
	PgbsonWriterAppendInt32(&writer, "numIters", 8, numIterations);

	/* Add time system variables accordingly */
	if (timeSystemVariables != NULL && timeSystemVariables->nowValue.value_type !=
		BSON_TYPE_EOD)
	{
		PgbsonWriterAppendValue(&writer, "sn", 2, &timeSystemVariables->nowValue);
	}

	if (hasParallelPlan)
	{
		PgbsonWriterAppendBool(&writer, "pp", 2, true);
	}

	return PgbsonWriterGetPgbson(&writer);
}


/*
 * Serializes a cursor document that can be reused by getMore for a persitent query.
 */
static pgbson *
BuildPersistedContinuationDocument(const char *cursorName, int64_t cursorId, QueryKind
								   queryKind, TimeSystemVariables *timeSystemVariables,
								   int numIterations, bool hasParallelPlan)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt64(&writer, "qi", 2, cursorId);
	PgbsonWriterAppendBool(&writer, "qp", 2, true);

	/* Add the original query spec so that getMore can reuse it */
	PgbsonWriterAppendInt32(&writer, "qk", 2, (int) queryKind);
	PgbsonWriterAppendUtf8(&writer, "qn", 2, cursorName);

	/* In the response add the number of iterations (used in tests) */
	PgbsonWriterAppendInt32(&writer, "numIters", 8, numIterations);

	/* Add time system variables accordingly */
	if (timeSystemVariables != NULL && timeSystemVariables->nowValue.value_type !=
		BSON_TYPE_EOD)
	{
		PgbsonWriterAppendValue(&writer, "sn", 2, &timeSystemVariables->nowValue);
	}

	if (hasParallelPlan)
	{
		PgbsonWriterAppendBool(&writer, "pp", 2, true);
	}

	return PgbsonWriterGetPgbson(&writer);
}


/*
 * Parses the serialized cursor spec of the prior iteration. This is the inverse
 * function of BuildStreamingContinuationDocument and BuildPersistedContinuationDocument
 */
static void
ParseCursorInputSpec(pgbson *cursorSpec, QueryGetMoreInfo *getMoreInfo)
{
	bson_iter_t cursorSpecIter;
	PgbsonInitIterator(cursorSpec, &cursorSpecIter);
	while (bson_iter_next(&cursorSpecIter))
	{
		const char *pathKey = bson_iter_key(&cursorSpecIter);
		switch (pathKey[0])
		{
			case 'q':
			{
				switch (pathKey[1])
				{
					/* qc: Legacy streaming cursor query */
					case 'c':
					{
						/* This is the query command */
						Assert(pathKey[2] == '\0');
						getMoreInfo->querySpec = PgbsonInitFromDocumentBsonValue(
							bson_iter_value(&cursorSpecIter));
						getMoreInfo->cursorKind = CursorKind_Streaming;
						continue;
					}

					/* qd: Local Dynamic streaming cursor query */
					case 'd':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->querySpec = PgbsonInitFromDocumentBsonValue(
							bson_iter_value(&cursorSpecIter));
						getMoreInfo->cursorKind = CursorKind_DynamicStreaming;
						continue;
					}

					/* qr: Remote Dynamic cursor query (streaming or file) */
					case 'r':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->querySpec = PgbsonInitFromDocumentBsonValue(
							bson_iter_value(&cursorSpecIter));
						getMoreInfo->cursorKind = CursorKind_DynamicRemote;
						continue;
					}

					/* qt: Tailable cursor query */
					case 't':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->querySpec = PgbsonInitFromDocumentBsonValue(
							bson_iter_value(&cursorSpecIter));
						getMoreInfo->cursorKind = CursorKind_Tailable;
						continue;
					}

					/* qn: Persisted cursor name */
					case 'n':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->cursorName = bson_iter_utf8(&cursorSpecIter, NULL);

						/*
						 * A file state ("qf") makes this a file-based persisted
						 * cursor. "qn" and "qf" can appear in either order, so only
						 * classify as a hold-portal persisted cursor when no file
						 * state has been seen; otherwise leave it as PersistedFile.
						 */
						if (getMoreInfo->cursorFileState == NULL)
						{
							getMoreInfo->cursorKind = CursorKind_Persisted;
						}
						continue;
					}

					/* qi: Query cursor id */
					case 'i':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->cursorId = bson_iter_int64(&cursorSpecIter);
						continue;
					}

					/* qk: Query cursor kind */
					case 'k':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->queryKind = (QueryKind) bson_iter_int32(
							&cursorSpecIter);
						continue;
					}

					/* qf: Query file state for the cursor */
					case 'f':
					{
						Assert(pathKey[2] == '\0');
						bson_subtype_t subtype;
						uint32_t binaryLength = 0;
						const uint8_t *binaryData = NULL;
						bson_iter_binary(&cursorSpecIter, &subtype,
										 &binaryLength, &binaryData);

						bytea *cursorState = palloc(binaryLength);
						memcpy(cursorState, binaryData, binaryLength);
						getMoreInfo->cursorFileState = cursorState;

						/* A file state is the defining signal of a file-based
						 * persisted cursor (independent of "qn" ordering). */
						getMoreInfo->cursorKind = CursorKind_PersistedFile;
						continue;
					}

					/* Continuation persistence - ignored */
					case 'p':
					{
						continue;
					}
				}

				continue;
			}

			case 'w':
			{
				/* wc — opaque worker continuation, passed straight back on getMore */
				if (pathKey[1] == 'c' && pathKey[2] == '\0')
				{
					getMoreInfo->dynamicCursorState = PgbsonInitFromDocumentBsonValue(
						bson_iter_value(&cursorSpecIter));
				}
				continue;
			}

			case 'd':
			{
				switch (pathKey[1])
				{
					/* dc — local dynamic-streaming cursor resume state */
					case 'c':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->dynamicCursorState =
							PgbsonInitFromDocumentBsonValue(
								bson_iter_value(&cursorSpecIter));
						continue;
					}

					/* Distributed relation OID for remote dynamic cursors */
					case 'r':
					{
						Assert(pathKey[2] == '\0');
						getMoreInfo->distributedTableOid =
							(Oid) bson_iter_int64(&cursorSpecIter);
						continue;
					}
				}

				continue;
			}

			/* numIters — page iteration counter stored in the continuation */
			case 'n':
			{
				if (strncmp(pathKey, "numIters", 8) == 0 && pathKey[8] == '\0')
				{
					getMoreInfo->numIterations = bson_iter_int32(&cursorSpecIter);
				}
				continue;
			}

			case 's':
			{
				switch (pathKey[1])
				{
					/* $$NOW time system variable (now)*/
					case 'n':
					{
						const bson_value_t *nowDateValue = bson_iter_value(
							&cursorSpecIter);
						getMoreInfo->queryData.timeSystemVariables.nowValue =
							*nowDateValue;
						continue;
					}
				}
				continue;
			}
		}
	}
}


/*
 * Parses the getMore spec and builds the necessary pipeline/query information from a cursor standpoint.
 */
static void
ParseGetMoreSpec(text **databaseName, pgbson *getMoreSpec, pgbson *cursorSpec,
				 QueryGetMoreInfo *getMoreInfo, bool setStatementTimeout)
{
	/* Default batchSize for getMore */
	getMoreInfo->queryData.batchSize = INT_MAX;

	ParseCursorInputSpec(cursorSpec, getMoreInfo);

	/* Parses the wire protocol getMore */
	bool isTailableCursor = (getMoreInfo->cursorKind == CursorKind_Tailable);
	int64_t cursorId = ParseGetMore(databaseName, getMoreSpec, &getMoreInfo->queryData,
									setStatementTimeout, isTailableCursor);
	if (cursorId != getMoreInfo->cursorId)
	{
		ereport(ERROR, (errmsg(
							"CursorID from GetMore does not match from cursor state, getMore: %ld, cursorState %ld",
							cursorId, getMoreInfo->cursorId)));
	}
}


/*
 * Creates a unique cursorId if one isn't provided.
 */
static int64_t
GenerateCursorId(int64_t inputValue)
{
	if (inputValue != 0)
	{
		return inputValue;
	}

	/*
	 * 2^53-1 masks integer precision of IEEE 754 double precision floating
	 * point numbers. Works around issue with certain versions of the NodeJS
	 * driver.
	 *
	 * A cursor id only needs to be unique among live cursors so by default the
	 * fast non-cryptographic PRNG is sufficient instead of expensive
	 * pg_strong_random() which provides cryptographic unpredictability
	 * guarantees.	 */
	int64_t cursorId;
	if (EnablePGPrngCursorId)
	{
		cursorId = (int64_t) pg_prng_uint64(&pg_global_prng_state);
	}
	else
	{
		char cursorBuffer[8];

		/* This is the same logic UUID generation uses */
		if (!pg_strong_random(cursorBuffer, 8))
		{
			ereport(ERROR, (errmsg(
								"Failed to create a unique identifier for the cursor")));
		}

		cursorId = *(int64_t *) cursorBuffer;
	}

	return (cursorId & CursorAcceptableBitsMask);
}


/*
 * Builds the protocol-level continuation document for a remote dynamic cursor
 * (streaming or file). The worker continuation is stored verbatim under "wc"
 * (opaque to the coordinator; a file cursor carries a "qf" file-state key
 * inside it), "qr" carries the query spec (and signals the unified remote
 * dynamic kind on getMore), and "dr" the distributed table OID used to route
 * the getMore back to the worker.
 */
static pgbson *
BuildRemoteCursorContinuationDocument(int64_t cursorId, QueryKind queryKind,
									  pgbson *querySpec, int numIterations,
									  pgbson *workerContinuation,
									  Oid distributedTableOid,
									  TimeSystemVariables *timeSystemVariables)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt64(&writer, "qi", 2, cursorId);
	PgbsonWriterAppendBool(&writer, "qp", 2, false);
	PgbsonWriterAppendInt32(&writer, "qk", 2, (int) queryKind);

	/* "qr" carries the query spec and signals a remote dynamic cursor. */
	PgbsonWriterAppendDocument(&writer, "qr", 2, querySpec);

	/* Opaque worker continuation, stored verbatim and passed straight back. */
	if (workerContinuation != NULL)
	{
		PgbsonWriterAppendDocument(&writer, "wc", 2, workerContinuation);
	}

	/* Distributed table OID for routing on getMore. */
	PgbsonWriterAppendInt64(&writer, "dr", 2, (int64_t) distributedTableOid);

	PgbsonWriterAppendInt32(&writer, "numIters", 8, numIterations);

	if (timeSystemVariables != NULL && timeSystemVariables->nowValue.value_type !=
		BSON_TYPE_EOD)
	{
		PgbsonWriterAppendValue(&writer, "sn", 2, &timeSystemVariables->nowValue);
	}

	return PgbsonWriterGetPgbson(&writer);
}


/*
 * Issues the worker drain UDF as a normal shard query targeting the collection's
 * single shard (shard_key_value = collectionId for an unsharded collection), so
 * Citus routes it to the node where the shard is local. A planner hook rewrites
 * the shard scan into a function scan (see ProcessWorkerWriteQueryPath), so the
 * UDF runs exactly once regardless of shard row count — including on an empty
 * collection — and injects the local shard OID into p_shard_oid. The coordinator
 * passes an invalid OID placeholder. The UDF returns a bson[] array; its
 * elements are deconstructed here without a second pass over the batch.
 */
static RemoteCursorPageResult
DrainRemoteCursorPage(text *database, QueryKind queryKind,
					  pgbson *querySpec, pgbson *workerContinuation,
					  int batchSize, MongoCollection *collection)
{
	RemoteCursorPageResult result = { 0 };

	Oid drainFuncId = ApiCursorDynamicDrainPageFunctionId();
	if (!OidIsValid(drainFuncId))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("cursor_dynamic_drain_page function not found")));
	}

	if (collection == NULL || collection->tableName[0] == '\0')
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Could not resolve distributed table for remote "
							   "cursor")));
	}

	pgbson *effectiveQuerySpec = querySpec != NULL ? querySpec : PgbsonInitEmpty();
	pgbson *effectiveContinuation = workerContinuation != NULL ?
									workerContinuation : PgbsonInitEmpty();

	/*
	 * Forward-compatible options bag for the worker UDF.
	 *   "p_use_file_based_cursor": whether the worker may fall back to a
	 *     file-based persisted cursor for non-streamable queries.
	 *   "p_batch_size": preserves client-driven pagination — the worker prefers
	 *     the batchSize parsed from the query spec and falls back to this value
	 *     when the spec does not carry one (e.g. a file getMore, which is served
	 *     without re-parsing the spec).
	 *   "p_namespace": the "<database>.<collection>" cursor-page namespace,
	 *     computed once here from the collection metadata so the worker does not
	 *     re-derive it from the query spec on every page.
	 */
	const char *namespaceName = psprintf("%s.%s", collection->name.databaseName,
										 collection->name.collectionName);

	pgbson_writer extraWriter;
	PgbsonWriterInit(&extraWriter);
	PgbsonWriterAppendBool(&extraWriter, "p_use_file_based_cursor", 23, true);
	PgbsonWriterAppendInt32(&extraWriter, "p_batch_size", 12, batchSize);
	PgbsonWriterAppendUtf8(&extraWriter, "p_namespace", 11, namespaceName);
	pgbson *extraBson = PgbsonWriterGetPgbson(&extraWriter);

	/*
	 * Target the single shard via shard_key_value (= collectionId for an
	 * unsharded collection). The planner rewrites this shard scan into a function
	 * scan so the UDF runs exactly once even when the shard is empty.
	 */
	StringInfoData queryStr;
	initStringInfo(&queryStr);
	appendStringInfo(&queryStr,
					 "SELECT %s.cursor_dynamic_drain_page($1, $2, $3, $4, $5, $6) "
					 "FROM %s.%s WHERE shard_key_value = " UINT64_FORMAT,
					 ApiInternalSchemaNameV2,
					 quote_identifier(ApiDataSchemaName),
					 quote_identifier(collection->tableName),
					 collection->collectionId);

	int nargs = 6;
	Oid argTypes[6] = {
		TEXTOID, /* database name */
		BsonTypeId(), /* query spec */
		REGCLASSOID, /* shard OID (planner-injected; placeholder here) */
		BsonTypeId(), /* continuation */
		INT4OID, /* query kind */
		BsonTypeId() /* extra options bag */
	};
	Datum argValues[6] = {
		PointerGetDatum(database),
		PointerGetDatum(effectiveQuerySpec),
		ObjectIdGetDatum(InvalidOid),
		PointerGetDatum(effectiveContinuation),
		Int32GetDatum((int32) queryKind),
		PointerGetDatum(extraBson)
	};

	/*
	 * The database name is NULL when the caller supplied it only via "$db" in
	 * the command spec (the worker recovers it from the spec). Mark that
	 * argument as a SQL NULL rather than a non-null 0 Datum; otherwise the
	 * remote dispatch dereferences the 0 pointer while serializing the param.
	 */
	char argNulls[6] = {
		database != NULL ? ' ' : 'n', ' ', ' ', ' ', ' ', ' '
	};

	bool isNull = false;
	Datum resultDatum = ExtensionExecuteQueryWithArgsViaSPI(
		queryStr.data, nargs, argTypes, argValues, argNulls,
		true,   /* readOnly */
		SPI_OK_SELECT, &isNull);

	pfree(queryStr.data);

	/*
	 * The function-scan rewrite guarantees the UDF runs exactly once, so the
	 * query always returns a row. A NULL result means the planner rewrite did not
	 * run (e.g. the shard could not be routed) — a server bug.
	 */
	if (isNull)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("remote cursor drain returned no row; the shard scan "
							   "rewrite did not run")));
	}

	/*
	 * The drain UDF returns a bson[] array with fixed element positions:
	 *   [0] result_batch : the cursor page (outbound shape)
	 *   [1] continuation : opaque worker continuation (SQL NULL when drained)
	 *   [2] meta         : { "ct": <cursor type int> }
	 */
	ArrayType *resultArray = DatumGetArrayTypeP(resultDatum);
	Datum *elems = NULL;
	bool *elemNulls = NULL;
	int numElems = 0;
	deconstruct_array(resultArray, BsonTypeId(), -1, false, TYPALIGN_INT,
					  &elems, &elemNulls, &numElems);

	if (numElems != 3 && numElems != 2)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("remote cursor drain returned %d array elements, "
							   "expected 2 or 3 - this is a server bug", numElems)));
	}

	result.pageBson = DatumGetPgBson(elems[0]);
	pgbson *metaBson = DatumGetPgBson(elems[1]);
	bson_iter_t metaIter;
	if (PgbsonInitIteratorAtPath(metaBson, "ct", &metaIter))
	{
		result.cursorType = BsonValueAsInt32(bson_iter_value(&metaIter));
	}

	if (numElems == 3)
	{
		result.continuation = DatumGetPgBson(elems[2]);
	}

	return result;
}


/*
 * Overwrites the cursor.id placeholder (0) in a worker-built page with the
 * coordinator-assigned cursor id, in place — no re-serialization of the page.
 */
static void
PatchCursorPageId(pgbson *pageBson, int64_t cursorId)
{
	bson_iter_t pageIter;
	PgbsonInitIterator(pageBson, &pageIter);
	if (!bson_iter_find_descendant(&pageIter, "cursor.id", &pageIter))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Could not find cursor.id in worker cursor page. "
							   "This is a bug")));
	}

	bson_iter_overwrite_int64(&pageIter, cursorId);
}


/*
 * Forms the (cursorPage, continuation, persistConnection, cursorId) result tuple
 * for an already-finalized cursor page (used by the remote pass-through path,
 * mirroring FormFinalCursorResultTuple).
 */
static Datum
FormCursorResultDatum(pgbson *cursorPage, pgbson *continuation,
					  bool persistConnection, int64_t cursorId,
					  TupleDesc tupleDesc)
{
	Datum values[5];
	bool nulls[5];
	memset(values, 0, sizeof(values));
	memset(nulls, 0, sizeof(nulls));

	values[0] = PointerGetDatum(cursorPage);
	nulls[0] = false;
	values[1] = continuation != NULL ? PointerGetDatum(continuation) : (Datum) 0;
	nulls[1] = continuation == NULL;
	values[2] = BoolGetDatum(persistConnection);
	nulls[2] = false;
	values[3] = Int64GetDatum(cursorId);
	nulls[3] = false;

	/*
	 * A V2 getMore passes a 5-attribute tuple descriptor (maxAwaitTimeMS).
	 * The remote drain path never waits, so report 0. Mirrors
	 * FormFinalCursorResultTuple's handling of natts > 4.
	 */
	if (tupleDesc->natts > 4)
	{
		values[4] = Int64GetDatum(0);
		nulls[4] = false;
	}

	return HeapTupleGetDatum(heap_form_tuple(tupleDesc, values, nulls));
}


/*
 * Worker-side UDF that runs the full dynamic cursor drain operation locally.
 * Generates the query, plans, executes with batch termination, extracts
 * continuation, and returns the result as a bson[] array.
 *
 * The coordinator issues this as a normal shard query
 *   SELECT <internal>.cursor_dynamic_drain_page(...) FROM <data>.documents_<id>
 *   WHERE shard_key_value = <id>;
 * A planner hook rewrites the shard scan into a function scan so the UDF runs
 * exactly once regardless of shard row count (so it still runs on an empty
 * collection), and injects the local shard OID into p_shard_oid.
 *
 * First page (empty continuation): plans a dynamic cursor; a streamable query
 * drains as a dynamic streaming cursor, a non-streamable one (e.g. with a sort)
 * falls back to a worker-side file. Either way the continuation is emitted as a
 * standard local cursor spec (a "qd"/"dc" dynamic-streaming spec, or a "qn"/"qf"
 * persisted-file spec).
 *
 * getMore (non-empty continuation): the continuation is a self-describing local
 * cursor spec, so the drain delegates to the shared DrainLocalCursorGetMorePage
 * — the same machinery the coordinator getMore uses.
 *
 * Arguments:
 *   $1 - database name (text)
 *   $2 - query spec (bson)
 *   $3 - shard OID (regclass; planner-injected, InvalidOid means rewrite missing)
 *   $4 - continuation (bson, empty for first page; a local cursor spec on getMore)
 *   $5 - query kind (int4: 1=find, 2=aggregate)
 *   $6 - extra options bag (bson, nullable; { "p_use_file_based_cursor": bool,
 *        "p_batch_size": int })
 *
 * Why the batch size is threaded in p_extra rather than read solely from the
 * query spec: the spec only yields a batch size on the paths that re-parse it.
 *   - getMore paths drain from the continuation (file state or streaming cursor
 *     state) and never re-parse the query spec, so they have no spec-derived
 *     batch size and rely on p_batch_size.
 *   - A getMore can override the original command's batchSize, but the spec
 *     stored in the continuation only carries the first-page batchSize, so the
 *     per-getMore value must be passed out-of-band via p_batch_size.
 * The effective batch size therefore prefers the spec-parsed value when present
 * and falls back to p_batch_size (then INT_MAX) otherwise.
 *
 * Returns: bson[] with fixed element positions [result_batch, continuation,
 *   meta] where result_batch is the full cursor page already in outbound shape
 *   { cursor: { id: 0, ns, firstBatch|nextBatch: [...] }, ok: 1.0 } (the
 *   coordinator patches cursor.id in place), continuation is the opaque worker
 *   continuation (SQL NULL when drained), and meta is { "ct": <int> } carrying
 *   the cursor type (0=drained / non-zero=has more data). A bson[] is used
 *   instead of a composite type to keep the UDF schema-independent.
 */
Datum
command_cursor_dynamic_drain_page(PG_FUNCTION_ARGS)
{
	text *database = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_P(0);
	pgbson *querySpec = PG_GETARG_PGBSON(1);
	Oid shardOid = PG_ARGISNULL(2) ? InvalidOid : PG_GETARG_OID(2);
	pgbson *continuation = PG_GETARG_PGBSON(3);
	int32 queryKindInt = PG_GETARG_INT32(4);

	/*
	 * The planner rewrites the shard scan of documents_<id> into a function scan
	 * and injects the local shard OID here. An invalid OID means the rewrite did
	 * not run (e.g. a direct call), which is a server bug.
	 */
	if (shardOid == InvalidOid)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Explicit shardOid must be set - this is a server bug"),
						errdetail_log(
							"Explicit shardOid must be set - this is a server bug")));
	}

	/*
	 * p_extra is a forward-compatible options bag. It carries:
	 *   "p_use_file_based_cursor": whether the worker may fall back to a
	 *     file-based persisted cursor when the query cannot be streamed
	 *     (defaults true when not provided);
	 *   "p_batch_size": the coordinator's effective page size, used to preserve
	 *     client-driven pagination when the query spec does not carry a batchSize
	 *     (e.g. a file getMore served without re-parsing the spec);
	 *   "p_namespace": the "<database>.<collection>" cursor-page namespace,
	 *     computed once by the coordinator from the collection metadata.
	 */
	bool useFileBasedCursor = true;
	int32 extraBatchSize = INT_MAX;
	const char *namespaceName = NULL;
	if (!PG_ARGISNULL(5))
	{
		pgbson *extra = PG_GETARG_PGBSON(5);
		bson_iter_t extraIter;
		if (PgbsonInitIteratorAtPath(extra, "p_use_file_based_cursor", &extraIter))
		{
			useFileBasedCursor = BsonValueAsBool(bson_iter_value(&extraIter));
		}
		if (PgbsonInitIteratorAtPath(extra, "p_batch_size", &extraIter))
		{
			int32 parsedBatchSize = BsonValueAsInt32(bson_iter_value(&extraIter));
			if (parsedBatchSize >= 0)
			{
				extraBatchSize = parsedBatchSize;
			}
		}
		if (PgbsonInitIteratorAtPath(extra, "p_namespace", &extraIter) &&
			BSON_ITER_HOLDS_UTF8(&extraIter))
		{
			uint32_t namespaceLength = 0;
			namespaceName = bson_iter_utf8(&extraIter, &namespaceLength);
		}
	}

	if (namespaceName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("p_namespace must be set in the cursor drain options "
							   "- this is a server bug")));
	}

	QueryKind queryKind = (QueryKind) queryKindInt;

	/*
	 * The effective batch size. The streaming / first-page paths prefer the
	 * batchSize parsed from the query spec during query generation and fall back
	 * to the coordinator-provided p_batch_size; the file getMore path (which does
	 * not re-parse the spec) uses p_batch_size directly.
	 */
	int32 batchSize = extraBatchSize;

	/*
	 * Time system variables (e.g. $$NOW) are evaluated locally on the worker and
	 * must stay stable for the lifetime of the cursor. On the first page the
	 * value is captured during query generation and serialized into the worker
	 * continuation ("wc" carries "sn"); on getMore it is restored from that
	 * continuation (ParseCursorInputSpec reads "sn") and re-propagated, so every
	 * page observes the same $$NOW.
	 */
	TimeSystemVariables timeVars = { 0 };

	/*
	 * Build the result page directly in outbound cursor-page shape so the
	 * coordinator can forward it without re-serializing the (potentially large)
	 * batch. The cursor id is a placeholder (0) the coordinator patches in place;
	 * the namespace was computed once by the coordinator and passed in p_extra.
	 * isFirstPage is true only on the initial page (empty continuation) — a
	 * streaming or file getMore carries a non-empty continuation and therefore
	 * writes "nextBatch".
	 */
	bool isFirstPage = IsPgbsonEmptyDocument(continuation);
	int32 cursorType = 0;            /* 0 = drained */
	pgbson *continuationOut = NULL;

	/*
	 * Nested distributed execution must be allowed because the outer dispatch is
	 * "a query on a shard"; without this, any inner access to a Citus-managed
	 * table (e.g. the catalog reference table) is rejected.
	 * AllowNestedDistributionInCurrentTransaction() is a no-op on single node
	 * and sets citus.allow_nested_distributed_execution in the distributed build.
	 *
	 * The worker honors file-based cursors via the coordinator-supplied
	 * useFileBasedCursor option (its session GUC is not authoritative), threaded
	 * directly into the shared cursor machinery below.
	 */
	AllowNestedDistributionInCurrentTransaction();

	pgbson *pageBson = NULL;
	if (!isFirstPage)
	{
		pgbson_writer topLevelWriter;
		pgbson_writer cursorDoc;
		pgbson_array_writer batchArrayWriter;
		uint32_t accumulatedSize = 5;
		SetupCursorPagePreamble(&topLevelWriter, &cursorDoc, &batchArrayWriter,
								namespaceName, isFirstPage, &accumulatedSize);

		/*
		 * getMore: the worker continuation is a self-describing local cursor spec
		 * (a "qd"/"dc" dynamic-streaming spec, or a "qn"/"qf" persisted-file
		 * spec). Parse it and run the same shared local-cursor drainer the
		 * coordinator uses, then forward the resulting continuation.
		 */
		QueryGetMoreInfo workerGetMore = { 0 };
		workerGetMore.queryKind = queryKind;
		workerGetMore.queryData.batchSize = batchSize;
		workerGetMore.queryData.timeSystemVariables = timeVars;
		ParseCursorInputSpec(continuation, &workerGetMore);

		bool isWorker = true;
		bool drained = false;
		continuationOut = DrainLocalCursorGetMorePage(
			database, continuation, &workerGetMore, &batchArrayWriter,
			accumulatedSize, useFileBasedCursor, isWorker, &drained);
		if (!drained)
		{
			/* Non-zero signals the coordinator that the cursor has more data. */
			cursorType = CursorKind_DynamicRemote;
		}

		/*
		 * Finalize the page envelope. The worker leaves cursor.id = 0; the
		 * coordinator patches it in place before returning the page on the wire.
		 */
		PgbsonWriterEndArray(&cursorDoc, &batchArrayWriter);
		PgbsonWriterEndDocument(&topLevelWriter, &cursorDoc);
		PgbsonWriterAppendDouble(&topLevelWriter, "ok", 2, 1);
		pageBson = PgbsonWriterGetPgbson(&topLevelWriter);
	}
	else
	{
		/*
		 * First page: plan the query as a dynamic cursor. Streamable queries
		 * drain as a dynamic streaming cursor; non-streamable queries (e.g. with
		 * a sort) fall back to a worker-side file. Either way the worker emits a
		 * standard local cursor spec as its continuation so getMore can resume
		 * via the shared drainer.
		 *
		 * The local-execution GUCs forced for this dispatch ensure inner SPI
		 * queries (catalog lookups, the shard scan) run locally within this
		 * worker process rather than acquiring a new distributed XID.
		 */
		QueryData queryData = GenerateFirstPageQueryData();
		queryData.timeSystemVariables = timeVars;
		queryData.cursorStateConst = NULL;

		bool setStatementTimeout = false;
		Query *dynQuery = GenerateCursorQueryForKind(database, querySpec, &queryData,
													 queryKind, CursorParamKind_Dynamic,
													 setStatementTimeout);

		int64_t cursorId = 0;
		bool useFileBasedPersistentCursors = useFileBasedCursor;
		LocalFirstPageResult firstPageResult =
			HandleLocalFirstPageRequestCore(database, querySpec, cursorId,
											&queryData, queryKind, dynQuery,
											useFileBasedPersistentCursors);
		pageBson = firstPageResult.resultDocument;
		continuationOut = firstPageResult.continuationDoc;
		if (continuationOut != NULL)
		{
			/* Non-zero signals the coordinator that the cursor has more data. */
			cursorType = CursorKind_DynamicRemote;
		}
	}

	/*
	 * Build the bson[] result with fixed element positions:
	 *   [0] result_batch : the page built above (never NULL)
	 *   [1] meta         : { "ct": <cursor type> } where 0 = drained and
	 *                      non-zero signals the coordinator the cursor has more.
	 *   [2] continuation : opaque worker continuation (SQL NULL when drained)
	 * Using a bson[] keeps the UDF schema-independent (no custom composite type).
	 */
	pgbson_writer metaWriter;
	PgbsonWriterInit(&metaWriter);
	PgbsonWriterAppendInt32(&metaWriter, "ct", 2, cursorType);
	pgbson *metaBson = PgbsonWriterGetPgbson(&metaWriter);

	Datum elems[3];
	elems[0] = PointerGetDatum(pageBson);
	elems[1] = PointerGetDatum(metaBson);
	int numElements = 2;
	if (continuationOut != NULL)
	{
		elems[2] = PointerGetDatum(continuationOut);
		numElements = 3;
	}

	ArrayType *resultArray = construct_array(elems, numElements, BsonTypeId(), -1, false,
											 TYPALIGN_INT);

	PG_RETURN_ARRAYTYPE_P(resultArray);
}
