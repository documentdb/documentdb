/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/storage_utils.c
 *
 * Utilities that provide physical storage related metrics and information.
 *
 *-------------------------------------------------------------------------
 */


#include "utils/storage_utils.h"

#include "api_hooks.h"
#include "commands/diagnostic_commands_common.h"
#include "io/bson_core.h"
#include "io/bsonvalue_utils.h"
#include "utils/documentdb_errors.h"
#include "utils/guc_utils.h"
#include "utils/query_utils.h"
#include "utils/version_utils.h"
#include "metadata/metadata_cache.h"

/* Keys used to ship the per-node bloat estimate back to the coordinator. */
#define BloatBytesKey "bloat_bytes"
#define TableBytesKey "table_bytes"

/* Keys used to ship the per-node storage sizes back to the coordinator. */
#define TotalRelationSizeKey "total_rel_size"
#define TotalRelationSizeKeyLength 14
#define TotalTableSizeKey "total_tbl_size"
#define TotalTableSizeKeyLength 14

/*
 * Spec fields understood by get_storage_stats_worker. Each one selects a group
 * of metrics to collect, so a caller that needs a new metric adds a field here
 * rather than a new worker function.
 */
#define BloatEstimateSpecKey "bloatEstimate"
#define PhysicalSizeSpecKey "physicalSize"

/* Metrics a caller can ask get_storage_stats_worker for. */
typedef enum StorageStatsRequest
{
	StorageStatsRequest_None = 0x0,

	/* Bloat and table size derived from planner statistics. */
	StorageStatsRequest_BloatEstimate = 0x1,

	/* Exact on-disk size measured from the relation files. */
	StorageStatsRequest_PhysicalSize = 0x2,
} StorageStatsRequest;

static List * RunStorageStatsWorkerOnAllNodes(uint64 collectionId,
											  StorageStatsRequest request);
static StorageStatsRequest ParseStorageStatsSpec(pgbson *spec);
static void AppendCollectionBloatEstimate(pgbson_writer *writer,
										  MongoCollection *collection,
										  ArrayType *shardNames);
static void AppendCollectionPhysicalSize(pgbson_writer *writer, ArrayType *shardOids);
static CollectionBloatStats MergeBloatStatsBsons(List *workerBsons);
static CollectionStorageSize MergeStorageSizeBsons(List *workerBsons);

PG_FUNCTION_INFO_V1(get_bloat_stats_worker);
PG_FUNCTION_INFO_V1(get_storage_stats_worker);


/*
 * Legacy per node bloat estimate entry point.
 *
 * Superseded by get_storage_stats_worker, which collects the same numbers
 * through its spec. It is retained because it is part of an already released
 * schema and is still what a node that has not been upgraded yet exposes.
 */
Datum
get_bloat_stats_worker(PG_FUNCTION_ARGS)
{
	uint64 collectionId = PG_GETARG_INT64(0);

	MongoCollection *collection = GetMongoCollectionByColId(collectionId,
															AccessShareLock);

	if (collection == NULL)
	{
		/* The collection was dropped concurrently -- there is nothing to estimate. */
		PG_RETURN_POINTER(PgbsonInitEmpty());
	}

	ArrayType *shardNames = NULL;
	ArrayType *shardOids = NULL;
	if (!GetMongoCollectionShardOidsAndNames(collection, &shardOids, &shardNames))
	{
		PG_RETURN_POINTER(PgbsonInitEmpty());
	}

	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	AppendCollectionBloatEstimate(&writer, collection, shardNames);

	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&writer));
}


/*
 * Collects the storage metrics named in the spec for the shards of a collection
 * that live on the current node.
 *
 * The spec is a bson of boolean flags rather than a fixed argument list so that
 * a caller needing an additional metric extends this one worker instead of
 * adding another worker function and another schema upgrade.
 */
Datum
get_storage_stats_worker(PG_FUNCTION_ARGS)
{
	uint64 collectionId = PG_GETARG_INT64(0);
	pgbson *spec = PG_GETARG_PGBSON(1);

	StorageStatsRequest request = ParseStorageStatsSpec(spec);

	if (request == StorageStatsRequest_None)
	{
		PG_RETURN_POINTER(PgbsonInitEmpty());
	}

	/*
	 * The bloat estimate reads planner statistics and so wants a stable
	 * relation, but the physical size is read from the fork files, and there is
	 * no snapshot or statistic for that to be out of sync with.
	 * GetPostgresRelationSizes() goes through pg_total_relation_size(), which
	 * opens each relation under its own AccessShareLock and closes it again
	 * within the call, covering the only genuinely unsafe window: a
	 * concurrently dropped relation is reported as NULL rather than measured
	 * through a stale relfilenode.
	 *
	 * Taking a lock for a physical size only request would actively break
	 * compact(), which samples this either side of a VACUUM issued over a
	 * separate libpq connection (see PerformCompactOperation) while its own
	 * transaction is still open. A lock taken through the metadata cache lives
	 * until that transaction ends, so an AccessShareLock on the relation the
	 * VACUUM needs AccessExclusiveLock on would stall it, and the stall would
	 * never resolve: this backend is waiting on a socket rather than on a lock,
	 * so the deadlock detector finds no cycle and cancels nothing.
	 * ValidateLocksAndCheckAccess() hand-rolls its lock and unlock for the same
	 * reason.
	 *
	 * Two physical size samples are deliberately not consistent with each
	 * other. The VACUUM rewrites the relation between them, which is the
	 * measurement, and concurrent writers may grow it; the caller treats a
	 * relation that did not shrink as zero bytes freed.
	 */
	LOCKMODE lockMode = (request & StorageStatsRequest_BloatEstimate) != 0 ?
						AccessShareLock : NoLock;

	MongoCollection *collection = GetMongoCollectionByColId(collectionId, lockMode);

	if (collection == NULL)
	{
		/* The collection was dropped concurrently -- there is nothing to report. */
		PG_RETURN_POINTER(PgbsonInitEmpty());
	}

	ArrayType *shardNames = NULL;
	ArrayType *shardOids = NULL;
	if (!GetMongoCollectionShardOidsAndNames(collection, &shardOids, &shardNames))
	{
		/* No shard of this collection lives on this node. */
		PG_RETURN_POINTER(PgbsonInitEmpty());
	}

	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	if ((request & StorageStatsRequest_BloatEstimate) != 0)
	{
		AppendCollectionBloatEstimate(&writer, collection, shardNames);
	}

	if ((request & StorageStatsRequest_PhysicalSize) != 0)
	{
		AppendCollectionPhysicalSize(&writer, shardOids);
	}

	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&writer));
}


/*
 * Reads the boolean metric flags out of a get_storage_stats_worker spec.
 * Unknown fields are ignored so that a newer coordinator asking an older node
 * for a metric it does not know about degrades to the metrics it does.
 */
static StorageStatsRequest
ParseStorageStatsSpec(pgbson *spec)
{
	StorageStatsRequest request = StorageStatsRequest_None;

	bson_iter_t specIter;
	PgbsonInitIterator(spec, &specIter);
	while (bson_iter_next(&specIter))
	{
		const char *key = bson_iter_key(&specIter);

		if (strcmp(key, BloatEstimateSpecKey) == 0 &&
			BsonValueAsBool(bson_iter_value(&specIter)))
		{
			request |= StorageStatsRequest_BloatEstimate;
		}
		else if (strcmp(key, PhysicalSizeSpecKey) == 0 &&
				 BsonValueAsBool(bson_iter_value(&specIter)))
		{
			request |= StorageStatsRequest_PhysicalSize;
		}
	}

	return request;
}


/*
 * Quickly estimates the bloat of a collection table and writes it to the worker
 * response. This can be +/- 20% off, but provides a good enough estimate for
 * the collection.
 * For more details refer: https://github.com/pgexperts/pgx_scripts/blob/master/bloat/table_bloat_check.sql
 */
static void
AppendCollectionBloatEstimate(pgbson_writer *writer, MongoCollection *collection,
							  ArrayType *shardNames)
{
	StringInfo bloatEstimateQuery = makeStringInfo();
	appendStringInfo(bloatEstimateQuery,
					 "WITH constants AS ("
					 "   SELECT %d::numeric AS bs, 23::numeric AS hdr, 8::numeric AS ma"
					 "),",
					 BLCKSZ);

	appendStringInfo(bloatEstimateQuery,
					 "null_headers AS ("
					 "   SELECT "
					 "   hdr+1+(sum(case when null_frac <> 0 THEN 1 else 0 END)/8) as nullhdr, "
					 "   SUM((1-null_frac)*avg_width) as datawidth, "
					 "   MAX(null_frac) as maxfracsum,"
					 "   schemaname, tablename, hdr, ma, bs "
					 "   FROM pg_stats CROSS JOIN constants "
					 "   WHERE schemaname = %s"
					 "   AND tablename = ANY ($1)"
					 "   GROUP BY schemaname, tablename, hdr, ma, bs ), ",
					 quote_literal_cstr(ApiDataSchemaName));

	appendStringInfo(bloatEstimateQuery,
					 " data_headers AS ( "
					 "   SELECT "
					 "   ma, bs, hdr, schemaname, tablename, "
					 "   (datawidth+(hdr+ma-(case when hdr%%ma=0 THEN ma ELSE hdr%%ma END)))::numeric AS datahdr, "
					 "   (maxfracsum*(nullhdr+ma-(case when nullhdr%%ma=0 THEN ma ELSE nullhdr%%ma END))) AS nullhdr2 "
					 "   FROM null_headers "
					 "),"
					 "table_estimates AS ( "
					 "   SELECT schemaname, tablename, bs, "
					 "   reltuples::numeric as est_rows, relpages * bs as table_bytes, "
					 "   CEIL((reltuples* "
					 "       (datahdr + nullhdr2 + 4 + ma - "
					 "        (CASE WHEN datahdr%%ma=0 "
					 "            THEN ma ELSE datahdr%%ma END)"
					 "        )/(bs-20))) * bs AS expected_bytes, "
					 "   reltoastrelid "
					 "   FROM data_headers "
					 "   JOIN pg_class ON tablename = relname "
					 "   JOIN pg_namespace ON relnamespace = pg_namespace.oid "
					 "   AND schemaname = nspname "
					 "   WHERE pg_class.relkind = 'r' "
					 "),"
					 "estimates_with_toast AS ( "
					 "   SELECT schemaname, tablename, "
					 "        TRUE as can_estimate,"
					 "        est_rows,"
					 "        table_bytes + ( coalesce(toast.relpages, 0) * bs ) as table_bytes,"
					 "        expected_bytes + ( ceil( coalesce(toast.reltuples, 0) / 4 ) * bs ) as expected_bytes"
					 "    FROM table_estimates LEFT OUTER JOIN pg_class as toast"
					 "        ON table_estimates.reltoastrelid = toast.oid"
					 "            AND toast.relkind = 't'"
					 "),"
					 "table_estimates_plus AS ("
					 "    SELECT current_database() as databasename,"
					 "            schemaname, tablename, can_estimate, "
					 "            est_rows,"
					 "            CASE WHEN table_bytes > 0"
					 "                THEN table_bytes::NUMERIC"
					 "                ELSE NULL::NUMERIC END"
					 "                AS table_bytes,"
					 "            CASE WHEN expected_bytes > 0 "
					 "                THEN expected_bytes::NUMERIC"
					 "                ELSE NULL::NUMERIC END"
					 "                    AS expected_bytes,"
					 "            CASE WHEN expected_bytes > 0 AND table_bytes > 0"
					 "                AND expected_bytes <= table_bytes"
					 "                THEN (table_bytes - expected_bytes)::NUMERIC"
					 "                ELSE 0::NUMERIC END AS bloat_bytes"
					 "    FROM estimates_with_toast"
					 "),"
					 "bloat_data AS ("
					 "    select current_database() as databasename,"
					 "        schemaname, tablename, can_estimate, "
					 "        round(bloat_bytes*100/table_bytes) as pct_bloat,"
					 "        bloat_bytes,"
					 "        table_bytes, expected_bytes, est_rows"
					 "    FROM table_estimates_plus"
					 "),"
					 "projectBloat AS ("
					 "   SELECT "
					 "   SUM(bloat_bytes::int8) as bloat_bytes,"
					 "   SUM(table_bytes::int8) as table_bytes "
					 "   FROM bloat_data"
					 ")"
					 " SELECT %s.row_get_bson(projectBloat) FROM projectBloat",
					 CoreSchemaNameV2);

	int argCount = 1;
	char argNulls[1] = { ' ' };
	Oid argTypes[1] = { TEXTARRAYOID };
	Datum argValues[1] = { PointerGetDatum(shardNames) };
	bool readOnly = true;

	Datum resultDatum[1] = { 0 };
	bool isNulls[1] = { false };
	int numResults = 1;
	RunMultiValueQueryWithNestedDistribution(bloatEstimateQuery->data, argCount, argTypes,
											 argValues,
											 argNulls,
											 readOnly, SPI_OK_SELECT, resultDatum,
											 isNulls, numResults);

	if (isNulls[0])
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg(
							"Unable to retrieve bloat statistics for the specified collection %lu",
							collection->collectionId)));
	}

	PgbsonWriterConcat(writer, DatumGetPgBson(resultDatum[0]));
}


/*
 * Measures the physical on-disk size of the given shards and writes it to the
 * worker response.
 *
 * Unlike the bloat estimate this reads the actual relation files instead of
 * planner statistics, so it is both cheap and exact. Sampling it either side of
 * a VACUUM is what lets the coordinator report the space that was really
 * reclaimed rather than an estimate that can be off by double digit percentages.
 */
static void
AppendCollectionPhysicalSize(pgbson_writer *writer, ArrayType *shardOids)
{
	CollectionStorageSize storageSize = GetPostgresRelationSizes(shardOids);

	if (storageSize.nullStats)
	{
		return;
	}

	PgbsonWriterAppendInt64(writer, TotalRelationSizeKey, TotalRelationSizeKeyLength,
							(int64) storageSize.totalRelationSize);
	PgbsonWriterAppendInt64(writer, TotalTableSizeKey, TotalTableSizeKeyLength,
							(int64) storageSize.totalTableSize);
}


/*
 * Reads the exact on-disk size of the given relations on the current node.
 *
 * The sizes are read from the relation files rather than from planner
 * statistics, so they are accurate at the moment of the call and can be
 * differenced across an operation. nullStats is set when no size could be
 * determined, which happens when the relations were dropped concurrently.
 */
CollectionStorageSize
GetPostgresRelationSizes(ArrayType *relationIds)
{
	CollectionStorageSize storageSize;
	memset(&storageSize, 0, sizeof(CollectionStorageSize));
	storageSize.nullStats = true;

	const char *sizeQuery =
		"SELECT SUM(pg_catalog.pg_total_relation_size(r))::int8,"
		" SUM(pg_catalog.pg_table_size(r))::int8 FROM unnest($1) r";

	int argCount = 1;
	Oid argTypes[1] = { OIDARRAYOID };
	Datum argValues[1] = { PointerGetDatum(relationIds) };
	char *argNulls = NULL;
	bool readOnly = true;

	Datum resultDatums[2] = { 0 };
	bool isNulls[2] = { false, false };
	int numResults = 2;
	ExtensionExecuteMultiValueQueryWithArgsViaSPI(sizeQuery, argCount, argTypes,
												  argValues, argNulls, readOnly,
												  SPI_OK_SELECT, resultDatums, isNulls,
												  numResults);

	if (isNulls[0] || isNulls[1])
	{
		return storageSize;
	}

	storageSize.nullStats = false;
	storageSize.totalRelationSize = DatumGetInt64(resultDatums[0]);
	storageSize.totalTableSize = DatumGetInt64(resultDatums[1]);

	return storageSize;
}


/*
 * Gets the bloat stats for a given collectionId across all shards.
 */
CollectionBloatStats
GetCollectionBloatEstimate(uint64 collectionId)
{
	if (!IsClusterVersionAtleast(DocDB_V1, 0, 0))
	{
		/*
		 * get_storage_stats_worker only exists once every node has been
		 * upgraded. During a rolling upgrade fall back to the worker that the
		 * lagging nodes still expose.
		 */
		int numValues = 1;
		Datum values[1] = { UInt64GetDatum(collectionId) };
		Oid types[1] = { INT8OID };
		List *legacyBsons = RunQueryOnAllServerNodes("BloatStats", values, types,
													 numValues,
													 get_bloat_stats_worker,
													 ApiInternalSchemaNameV2,
													 "get_bloat_stats_worker");
		return MergeBloatStatsBsons(legacyBsons);
	}

	List *workerBsons = RunStorageStatsWorkerOnAllNodes(collectionId,
														StorageStatsRequest_BloatEstimate);
	return MergeBloatStatsBsons(workerBsons);
}


/*
 * Gets the physical on-disk size of a collection summed across every node.
 */
CollectionStorageSize
GetCollectionStorageSize(uint64 collectionId)
{
	List *workerBsons = RunStorageStatsWorkerOnAllNodes(collectionId,
														StorageStatsRequest_PhysicalSize);
	return MergeStorageSizeBsons(workerBsons);
}


/*
 * Asks every node for the requested storage metrics of a collection and returns
 * the per node responses.
 */
static List *
RunStorageStatsWorkerOnAllNodes(uint64 collectionId, StorageStatsRequest request)
{
	pgbson_writer specWriter;
	PgbsonWriterInit(&specWriter);
	PgbsonWriterAppendBool(&specWriter, BloatEstimateSpecKey,
						   sizeof(BloatEstimateSpecKey) - 1,
						   (request & StorageStatsRequest_BloatEstimate) != 0);
	PgbsonWriterAppendBool(&specWriter, PhysicalSizeSpecKey,
						   sizeof(PhysicalSizeSpecKey) - 1,
						   (request & StorageStatsRequest_PhysicalSize) != 0);

	int numValues = 2;
	Datum values[2] = {
		UInt64GetDatum(collectionId),
		PointerGetDatum(PgbsonWriterGetPgbson(&specWriter))
	};
	Oid types[2] = { INT8OID, BsonTypeId() };

	return RunQueryOnAllServerNodes("StorageStats", values, types, numValues,
									get_storage_stats_worker, ApiInternalSchemaNameV2,
									"get_storage_stats_worker");
}


/*
 * Merges the per node storage sizes into a single CollectionStorageSize object.
 */
static CollectionStorageSize
MergeStorageSizeBsons(List *workerBsons)
{
	CollectionStorageSize storageSize;
	memset(&storageSize, 0, sizeof(CollectionStorageSize));
	storageSize.nullStats = true;

	ListCell *workerCell;
	foreach(workerCell, workerBsons)
	{
		pgbson *workerBson = lfirst(workerCell);
		bson_iter_t iter;
		PgbsonInitIterator(workerBson, &iter);
		while (bson_iter_next(&iter))
		{
			const char *key = bson_iter_key(&iter);
			const bson_value_t *value = bson_iter_value(&iter);

			if (strcmp(key, TotalRelationSizeKey) == 0)
			{
				/* At least one node reported a size, so the result is usable. */
				storageSize.nullStats = false;
				storageSize.totalRelationSize += BsonValueAsInt64(value);
			}
			else if (strcmp(key, TotalTableSizeKey) == 0)
			{
				storageSize.nullStats = false;
				storageSize.totalTableSize += BsonValueAsInt64(value);
			}
		}
	}

	return storageSize;
}


/*
 * Merges the bloat stats from all the workers into a single
 * CollectionBloatStats object.
 */
static CollectionBloatStats
MergeBloatStatsBsons(List *workerBsons)
{
	CollectionBloatStats bloatStats;
	memset(&bloatStats, 0, sizeof(CollectionBloatStats));
	bloatStats.nullStats = true;

	ListCell *workerCell;
	foreach(workerCell, workerBsons)
	{
		pgbson *workerBson = lfirst(workerCell);
		bson_iter_t iter;
		PgbsonInitIterator(workerBson, &iter);
		while (bson_iter_next(&iter))
		{
			const char *key = bson_iter_key(&iter);
			const bson_value_t *value = bson_iter_value(&iter);

			if (strcmp(key, BloatBytesKey) == 0)
			{
				/* At least one node reported an estimate, so the result is usable. */
				bloatStats.nullStats = false;
				bloatStats.estimatedBloatStorage += BsonValueAsInt64(value);
			}
			else if (strcmp(key, TableBytesKey) == 0)
			{
				bloatStats.nullStats = false;
				bloatStats.estimatedTableStorage += BsonValueAsInt64(value);
			}
		}
	}

	return bloatStats;
}
