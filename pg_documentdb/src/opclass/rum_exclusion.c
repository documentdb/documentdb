/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/opclass/rum_exclusion.c
 *
 * Rum implementations for indexing of the shard key based term for the purposes
 * of unique index via exclusion constraints.
 *
 * When building unique indexes, Citus requires (and we honor that) to have the distribution
 * column (shard_key_value) in the exclusion constraint. If we create an exclusion constraint
 * the defacto mode is to create it as EXCLUDE WITH (shard_key_value, [remaining columns]...)
 *
 * The problem with this is that GIN's composite index is actually just N indexes put together.
 * Consequently, the insert of a document in say, an unsharded collection, will scan the shard_key_value
 * for equality (which is all documents) and independently scan for the remaining columns (typically 1)
 * and intersect the results. With a large number of documents, the first scan can become very large making
 * insert performance degrade over time.
 *
 * Instead of this, we opt to create the index has a composite term ROW(shard_key_value, document), [remaining columns]
 * Where the first entry is inserted into the index as a custom term. The format of the term is a 16 byte value with:
 * byte[0..7]: shard_key_value as-is
 * byte[8..15]: hash of the unique term.
 *
 * This way, there is entropy of terms with determinism on the first term, that preserves the shard_key_value with full
 * fidelity (avoiding hash collisions on the shard key being hashed).
 * This also ensures that the following scenario:
 * { "a": 5, "shard_key": 1 } and { "a": [ 5, 6, 7 ], "shard_key": 1 }
 * wil violate the unique constraint as we would generate the terms as [ HASH{1}, HASH{5}] for the first document
 * and [ HASH{1}, HASH{5}], [ HASH{1}, HASH{6}], [ HASH{1}, HASH{7}] which would cause the first term to violate
 * the unique constraint. On an insert path, we look up those specific terms such as [ HASH{1}, HASH{5}] which have low
 * cardinality and making inserts significantly faster.
 *
 * See also: https://www.postgresql.org/docs/current/gin-extensibility.html
 * See also: https://github.com/postgrespro/rum
 *
 *-------------------------------------------------------------------------
 */


#include <postgres.h>
#include <fmgr.h>
#include <utils/builtins.h>
#include <access/stratnum.h>
#include <access/reloptions.h>
#include <catalog/pg_type.h>
#include <utils/uuid.h>
#include <executor/executor.h>
#include <utils/typcache.h>

#include "io/bson_core.h"
#include "io/bson_hash.h"
#include "query/bson_compare.h"
#include "utils/documentdb_errors.h"
#include "utils/version_utils.h"
#include "utils/hashset_utils.h"
#include "opclass/bson_gin_private.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "metadata/metadata_cache.h"
#include "index_am/documentdb_rum_opclass.h"
#include "utils/feature_counter.h"

/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */

extern int DefaultUniqueIndexKeyhashOverride;
extern bool EnableUniqueNullMissingEquivalence;

static pgbson * GetShardKeyAndDocument(HeapTupleHeader input, int64_t *shardKey);
static IndexTraverseOption GetExclusionIndexTraverseOption(void *contextOptions,
														   const char *currentPath,
														   uint32_t currentPathLength,
														   bson_type_t bsonType,
														   int32_t *pathIndex);
static void GenerateTermsForExclusion(pgbson *document, int64_t shardKey,
									  GenerateTermsContext *context,
									  GinEntryPathData *pathData,
									  bool generateRootTerm);
static void ValidateExclusionPathSpec(const char *prefix);

/*
 * A path written into a unique shard document, whether it holds a null
 * equivalent term, and (when probing) whether one of its terms matched.
 */
typedef struct UniqueShardDocumentPath
{
	StringView path;
	bool hasNullTerm;
	bool hasTermMatch;
} UniqueShardDocumentPath;

typedef struct UniqueShardDocumentPaths
{
	UniqueShardDocumentPath paths[INDEX_MAX_KEYS];
	int32_t numPaths;
} UniqueShardDocumentPaths;

static bool ProcessUniqueShardDocumentKeysNew(pgbson *uniqueShardDocument,
											  int64_t *shardKeyComparison,
											  HTAB *termsHashSet, HASHACTION hashAction,
											  UniqueShardDocumentPaths *documentPaths);
static HTAB * GetUniqueShardDocumentTermsHTABNew(pgbson *uniqueShardDocument,
												 int64_t *shardKeyValue,
												 UniqueShardDocumentPaths *documentPaths);
static bool AreUniqueShardDocumentPathsConflicting(UniqueShardDocumentPaths *leftPaths,
												   UniqueShardDocumentPaths *rightPaths);

typedef struct IndexBounds
{
	int32_t minIndex;
	int32_t maxIndex;
	int32_t numTerms;
} IndexBounds;

typedef struct IndexBoundsWithLength
{
	IndexBounds *indexBounds;
	int32_t length;
	bool isCompositeHash;
} IndexBoundsWithLength;

typedef struct
{
	pgbsonelement element;
	const char *collationString;
} UniqueIndexTermHashEntry;

typedef struct
{
	uint64_t shardKeyValue;
	int32_t numTerms;
	int32_t numPaths;
	const char *collation;
} UniqueShardDocumentMetadata;

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */
PG_FUNCTION_INFO_V1(gin_bson_exclusion_extract_value);
PG_FUNCTION_INFO_V1(gin_bson_exclusion_extract_query);
PG_FUNCTION_INFO_V1(gin_bson_exclusion_pre_consistent);
PG_FUNCTION_INFO_V1(gin_bson_exclusion_consistent);
PG_FUNCTION_INFO_V1(gin_bson_exclusion_options);
PG_FUNCTION_INFO_V1(bson_unique_exclusion_index_equal);
PG_FUNCTION_INFO_V1(generate_unique_shard_document);
PG_FUNCTION_INFO_V1(bson_unique_shard_path_equal);
PG_FUNCTION_INFO_V1(gin_bson_unique_shard_extract_value);
PG_FUNCTION_INFO_V1(gin_bson_unique_shard_extract_query);
PG_FUNCTION_INFO_V1(gin_bson_unique_shard_pre_consistent);
PG_FUNCTION_INFO_V1(gin_bson_unique_shard_consistent);
PG_FUNCTION_INFO_V1(bson_unique_shard_path_index_equal);
PG_FUNCTION_INFO_V1(bson_unique_index_term_equal);
PG_FUNCTION_INFO_V1(bson_unique_shard_path_options);
PG_FUNCTION_INFO_V1(gin_bson_unique_shard_rum_config);

/*
 * Runs the preconsistent function for the exclusion operator class
 * Since the index is full fidelity and we only support =
 * we just trust the index.
 */
Datum
gin_bson_exclusion_pre_consistent(PG_FUNCTION_ARGS)
{
	bool *recheck = (bool *) PG_GETARG_POINTER(5);
	*recheck = false;
	PG_RETURN_BOOL(true);
}


/*
 * Runs the consistent function for the exclusion operator class
 * Since the index is full fidelity and we only support =
 * we just trust the index.
 */
Datum
gin_bson_exclusion_consistent(PG_FUNCTION_ARGS)
{
	/* we always trust the index */
	bool *recheck = (bool *) PG_GETARG_POINTER(5);
	*recheck = false;
	PG_RETURN_BOOL(true);
}


/*
 * Extracts the value given an input record.
 * We extract terms as per the regular index, and then convert
 * the generated term into a 16 byte UUID. The UUID will have the form:
 * [byte 0..7]: shard_key_value
 * [byte 8..15]: hash of the term
 */
Datum
gin_bson_exclusion_extract_value(PG_FUNCTION_ARGS)
{
	HeapTupleHeader input = PG_GETARG_HEAPTUPLEHEADER(0);
	int32 *nentries = (int32 *) PG_GETARG_POINTER(1);

	if (!PG_HAS_OPCLASS_OPTIONS())
	{
		ereport(ERROR, (errmsg("Index does not have options")));
	}

	BsonGinSinglePathOptions *options =
		(BsonGinSinglePathOptions *) PG_GET_OPCLASS_OPTIONS();

	int64_t shardKey;
	pgbson *document = GetShardKeyAndDocument(input, &shardKey);
	GenerateTermsContext context = { 0 };
	GinEntryPathData pathData = { 0 };
	context.options = options;
	pathData.termMetadata = GetIndexTermMetadata(options);
	bool generateRootTerm = true;
	GenerateTermsForExclusion(document, shardKey, &context, &pathData, generateRootTerm);
	*nentries = pathData.terms.index;

	PG_FREE_IF_COPY(input, 0);
	PG_RETURN_POINTER(pathData.terms.entries);
}


/*
 * Given a query on an record extracts the term to be queried.
 * Since we only support equality, we just return the output of
 * extract_value as-is.
 */
Datum
gin_bson_exclusion_extract_query(PG_FUNCTION_ARGS)
{
	HeapTupleHeader input = PG_GETARG_HEAPTUPLEHEADER(0);
	int32 *nentries = (int32 *) PG_GETARG_POINTER(1);
	StrategyNumber strategy = PG_GETARG_UINT16(2);

	if (strategy != BTEqualStrategyNumber)
	{
		ereport(ERROR, errmsg("Invalid strategy number %d", strategy));
	}


	if (!PG_HAS_OPCLASS_OPTIONS())
	{
		ereport(ERROR, (errmsg("Index does not have options")));
	}

	BsonGinSinglePathOptions *options =
		(BsonGinSinglePathOptions *) PG_GET_OPCLASS_OPTIONS();

	int64_t shardKey;
	pgbson *document = GetShardKeyAndDocument(input, &shardKey);

	GenerateTermsContext context = { 0 };
	GinEntryPathData pathData = { 0 };
	context.options = options;
	bool generateRootTerm = false;
	pathData.termMetadata = GetIndexTermMetadata(options);
	GenerateTermsForExclusion(document, shardKey, &context, &pathData, generateRootTerm);
	*nentries = pathData.terms.index;

	PG_FREE_IF_COPY(input, 0);
	PG_RETURN_POINTER(pathData.terms.entries);
}


/*
 * gin_bson_exclusion_options sets up the option specification for single field exclusion hash terms
 * This initializes the structure that is used by the Index AM to process user specified
 * options on how to handle documents with the index.
 */
Datum
gin_bson_exclusion_options(PG_FUNCTION_ARGS)
{
	local_relopts *relopts = (local_relopts *) PG_GETARG_POINTER(0);

	init_local_reloptions(relopts, sizeof(BsonGinExclusionHashOptions));

	/* add an option that has a default value of single path and accepts *one* value
	 *  This is used later to key off whether it's a single path or multi-key wildcard index options */
	add_local_int_reloption(relopts, "optionsType",
							"The type of the options struct.",
							IndexOptionsType_UniqueShardKey, /* default value */
							IndexOptionsType_UniqueShardKey, /* min */
							IndexOptionsType_UniqueShardKey, /* max */
							offsetof(BsonGinExclusionHashOptions, base.type));
	add_local_int_reloption(relopts, "version",
							"The version of the options struct.",
							IndexOptionsVersion_V0,         /* default value */
							IndexOptionsVersion_V0,         /* min */
							IndexOptionsVersion_V0,         /* max */
							offsetof(BsonGinExclusionHashOptions, base.version));
	add_local_string_reloption(relopts, "path",
							   "Prefix path for the index",
							   NULL, &ValidateExclusionPathSpec, &FillSinglePathSpec,
							   offsetof(BsonGinExclusionHashOptions, path));
	add_local_string_reloption(relopts, "indexname",
							   "[deprecated] The mongo specific name for the index",
							   NULL, NULL, &FillDeprecatedStringSpec,
							   offsetof(BsonGinExclusionHashOptions,
										base.intOption_deprecated));
	add_local_int_reloption(relopts, "indextermsize",
							"[deprecated] The index term size limit for truncation",
							-1, /* default value */
							-1, /* min */
							-1, /* max: shard key index terms shouldn't be truncated. */
							offsetof(BsonGinExclusionHashOptions,
									 base.intOption_deprecated));
	add_local_int_reloption(relopts, "ts",
							"[deprecated] The index term size limit for truncation.",
							-1, /* default value */
							-1, /* min */
							INT32_MAX, /* max */
							offsetof(BsonGinExclusionHashOptions,
									 base.intOption_deprecated));

	PG_RETURN_VOID();
}


/*
 * Empty function that implements equality on the shard_key_value_and_document
 * We would never use this as we only use this in the push down of equality to the
 * exclusion constraint index.
 */
Datum
bson_unique_exclusion_index_equal(PG_FUNCTION_ARGS)
{
	ereport(ERROR, errmsg(
				"Unique exclusion index equal should only be an operator pushed to the index."));
}


Datum
bson_unique_shard_path_index_equal(PG_FUNCTION_ARGS)
{
	/* We trust the index for the recheck here */
	PG_RETURN_BOOL(true);
}


/*
 * bson_unique_index_equal is a dummy function that is used by the runtime to represent a unique index comparison.
 * The operator is unused as it is always pushed into the RUM index for index evaluation.
 * Note we can't use bson_equal (which does a field by field semantic equality), nor dollar_equal since it expects
 * document @= filter (which is not the behavior seen for unique indexes). We need a custom commutative operator
 * that allows for index pushdown for unique.
 */
Datum
bson_unique_index_term_equal(PG_FUNCTION_ARGS)
{
	/* In this case, we presume that the index is correct (for recheck purposes) */
	PG_RETURN_BOOL(true);
}


Datum
generate_unique_shard_document(PG_FUNCTION_ARGS)
{
	pgbson *document = PG_GETARG_PGBSON_PACKED(0);
	int64_t shardKeyValue = PG_GETARG_INT64(1);
	pgbson *projectionSpec = PG_GETARG_PGBSON_PACKED(2);

	bool sparse = PG_GETARG_BOOL(3);
	bool generateCompositeTerms = PG_NARGS() > 4 ? PG_GETARG_BOOL(4) : false;
	text *collation = PG_NARGS() > 5 ? PG_GETARG_TEXT_PP(5) : NULL;

	Datum *termArray[INDEX_MAX_KEYS] = { 0 };
	int32_t numTermArray[INDEX_MAX_KEYS] = { 0 };
	StringView pathArray[INDEX_MAX_KEYS] = { 0 };

	/* Next, write out the terms generated per path these will be used by the op-class to
	 * generate the collision resistant hash.
	 */
	int32_t numTerms = 0;
	int32_t indexColumn = 0;
	bson_iter_t specIter;
	PgbsonInitIterator(projectionSpec, &specIter);
	while (bson_iter_next(&specIter))
	{
		StringView pathIter = bson_iter_key_string_view(&specIter);

		uint32_t requiredLength = sizeof(BsonGinSinglePathOptions) + 5 + pathIter.length;
		if (collation != NULL)
		{
			requiredLength += 5 + VARSIZE_ANY_EXHDR(collation);
		}

		char *buffer = palloc0(requiredLength);
		BsonGinSinglePathOptions *singlePathOptions = (BsonGinSinglePathOptions *) buffer;
		singlePathOptions->isWildcard = false;
		singlePathOptions->generateNotFoundTerm = !sparse;
		singlePathOptions->base.indexTermTruncateLimit = INT32_MAX;
		singlePathOptions->base.type = IndexOptionsType_SinglePath;
		singlePathOptions->base.version = IndexOptionsVersion_V0;

		singlePathOptions->base.collation = 0;
		singlePathOptions->path = sizeof(BsonGinSinglePathOptions);
		char *pathPrefix = buffer + sizeof(BsonGinSinglePathOptions);
		uint32_t pathLength = pathIter.length;
		memcpy(pathPrefix, &pathLength, sizeof(uint32_t));
		pathPrefix += 4;
		memcpy(pathPrefix, pathIter.string, pathIter.length);
		pathPrefix += pathIter.length + 1;
		if (collation != NULL)
		{
			singlePathOptions->base.collation = sizeof(BsonGinSinglePathOptions) + 5 +
												pathIter.length;                                        /* offset to collation string */
			uint32_t collationLength = VARSIZE_ANY_EXHDR(collation);
			memcpy(pathPrefix, &collationLength, sizeof(uint32_t));
			pathPrefix += 4;
			memcpy(pathPrefix, VARDATA_ANY(collation), collationLength);
		}

		GenerateTermsContext context = { 0 };
		GinEntryPathData pathData = { 0 };
		context.options = singlePathOptions;
		bool generateRootTerm = false;
		pathData.termMetadata = GetIndexTermMetadata(singlePathOptions);
		context.traverseOptionsFunc = &GetSinglePathIndexTraverseOption;

		if (generateCompositeTerms)
		{
			pathData.generatePathBasedUndefinedTerms =
				singlePathOptions->generateNotFoundTerm;
			context.generateNotFoundTerm = false;
		}
		else
		{
			context.generateNotFoundTerm = singlePathOptions->generateNotFoundTerm;
		}

		GenerateTerms(document, &context, &pathData, generateRootTerm);

		if (indexColumn >= INDEX_MAX_KEYS)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"Cannot have more than 32 columns in the composite index extraction")));
		}

		if (pathData.terms.index == 0 && sparse)
		{
			continue;
		}

		numTermArray[indexColumn] = pathData.terms.index;
		termArray[indexColumn] = pathData.terms.entries;
		pathArray[indexColumn] = pathIter;
		indexColumn++;

		/* Calculate total terms */
		numTerms += pathData.terms.index;
	}

	/* This is similar to a projection - except we also add in the shard key value */
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt64(&writer, "$shard_key_value", 16, shardKeyValue);

	/* Add optional fields here so that the required paths can be validated after */
	if (collation != NULL)
	{
		bson_value_t collationValue = { 0 };
		collationValue.value_type = BSON_TYPE_UTF8;
		collationValue.value.v_utf8.str = VARDATA_ANY(collation);
		collationValue.value.v_utf8.len = VARSIZE_ANY_EXHDR(collation);
		PgbsonWriterAppendValue(&writer, "$collation", 10, &collationValue);
	}

	PgbsonWriterAppendInt32(&writer, "$numTerms", 9, numTerms);
	PgbsonWriterAppendInt32(&writer, "$numPaths", 9, indexColumn);


	for (int32_t i = 0; i < indexColumn; i++)
	{
		if (termArray[i] == 0)
		{
			continue;
		}

		pgbson_array_writer singleTerm;
		PgbsonWriterStartArray(&writer, pathArray[i].string, pathArray[i].length,
							   &singleTerm);

		/* Now write it out in asc order */
		for (int32_t j = 0; j < numTermArray[i]; j++)
		{
			Datum entry = termArray[i][j];
			bytea *termBson = DatumGetByteaPP(entry);
			BsonIndexTerm indexTerm;
			InitializeBsonIndexTerm(termBson, &indexTerm);
			if (IsIndexTermMetadata(&indexTerm))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg(
									"Unexpected - found metadata term in index build for unique_shard_document"),
								errdetail_log(
									"Unexpected - found metadata term in index build for unique_shard_document")));
			}

			PgbsonArrayWriterWriteValue(&singleTerm, &indexTerm.element.bsonValue);
		}

		PgbsonWriterEndArray(&writer, &singleTerm);
	}

	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&writer));
}


Datum
bson_unique_shard_path_equal(PG_FUNCTION_ARGS)
{
	/*
	 * Logging for testing purposes. We need to assert that we recheck the index when there's a hash collision and the
	 * terms are truncated.
	 */
	ereport(DEBUG1, (errmsg("Executing unique index runtime recheck.")));

	pgbson *left = PG_GETARG_PGBSON_PACKED(0);
	pgbson *right = PG_GETARG_PGBSON_PACKED(1);


	/* Build HTAB with every pair of { <path> : <term> } and collect the paths */
	int64_t leftShardKey = 0;
	UniqueShardDocumentPaths leftPaths = { 0 };
	HTAB *leftHashTable = GetUniqueShardDocumentTermsHTABNew(left, &leftShardKey,
															 &leftPaths);

	/*
	 * Iterate through pgbson on the right to check if every path (key) has
	 * a term match on the left, then reconcile paths present on only one side.
	 */
	int64_t rightShardKey = 0;
	UniqueShardDocumentPaths rightPaths = { 0 };
	bool uniquenessConflict = ProcessUniqueShardDocumentKeysNew(right, &rightShardKey,
																leftHashTable, HASH_FIND,
																&rightPaths) &&
							  (!EnableUniqueNullMissingEquivalence ||
							   AreUniqueShardDocumentPathsConflicting(&leftPaths,
																	  &rightPaths));

	hash_destroy(leftHashTable);
	PG_FREE_IF_COPY(left, 0);
	PG_FREE_IF_COPY(right, 1);

	if (leftShardKey != rightShardKey)
	{
		if (uniquenessConflict)
		{
			/*
			 * The terms matched, so this would have been a uniqueness conflict,
			 * but the documents live on different shard key values, so it is
			 * suppressed. Track how often this happens.
			 */
			ReportFeatureUsage(FEATURE_UNIQUE_SHARD_KEY_MISMATCH_SUPPRESSED_CONFLICT);
		}

		uniquenessConflict = false;
	}

	PG_RETURN_BOOL(uniquenessConflict);
}


static Datum *
GenerateNonCompositeHashTerms(bson_iter_t *specIter, uint32_t numTerms,
							  uint32_t numPaths, int64_t shardKeyValue,
							  int32_t *nentries, Pointer **extraData)
{
	Datum *indexEntries = palloc0(sizeof(Datum) * numTerms);
	IndexBounds *pathMap = NULL;
	if (extraData != NULL)
	{
		pathMap = palloc0(sizeof(IndexBounds) * numPaths);
		IndexBoundsWithLength *boundsWithLength = palloc0(sizeof(IndexBoundsWithLength) *
														  numTerms);

		IndexBoundsWithLength singleBounds = { 0 };
		singleBounds.length = numPaths;
		singleBounds.indexBounds = pathMap;
		singleBounds.isCompositeHash = false;
		for (uint32_t i = 0; i < numTerms; i++)
		{
			boundsWithLength[i] = singleBounds;
		}

		*extraData = (Pointer *) boundsWithLength;
	}

	uint32_t index = 0;
	uint32_t pathIndex = 0;
	while (bson_iter_next(specIter))
	{
		if (pathIndex >= numPaths)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("numPaths specified was >= indexPaths encountered"),
							errdetail_log(
								"numPaths specified %d was >= indexPaths %d encountered",
								numPaths,
								pathIndex)));
		}

		const char *key = bson_iter_key(specIter);

		if (!BSON_ITER_HOLDS_ARRAY(specIter))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"term values to generate for a given key should be an array")));
		}

		bson_value_t pathValue = { 0 };
		pathValue.value_type = BSON_TYPE_UTF8;
		pathValue.value.v_utf8.len = strlen(key);
		pathValue.value.v_utf8.str = (char *) key;
		int64_t keyhash = BsonValueHash(&pathValue, 0);

		if (pathMap != NULL)
		{
			pathMap[pathIndex].minIndex = index;
		}

		bson_iter_t arrayIter;
		bson_iter_recurse(specIter, &arrayIter);
		while (bson_iter_next(&arrayIter))
		{
			const bson_value_t *indexTerm = bson_iter_value(&arrayIter);

			/* We store the term in a uuid as it is a cheap way to store
			 * 16 bytes without the length prefix overhead that bytea
			 * has. This will reduce the overall index term size for this term */
			pg_uuid_t *uuid = palloc(sizeof(pg_uuid_t));
			int64_t *firstBytes = (int64_t *) &uuid->data[0];
			*firstBytes = shardKeyValue;
			int64_t *lastBytes = (int64_t *) &uuid->data[8];

			/*
			 * Hash the value.
			 * We check the GUC in order to force a hash collision.
			 * This is only used for testing and should not be set in production.
			 */
			const char *collationString = NULL;
			*lastBytes = DefaultUniqueIndexKeyhashOverride > 0 ?
						 (uint64_t) DefaultUniqueIndexKeyhashOverride :
						 HashBsonValueComparableExtended(indexTerm, keyhash,
														 collationString);

			if (index > numTerms)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg(
									"Invalid number of terms specified. Specified %d terms but found at least %d terms",
									numTerms, index),
								errdetail_log(
									"Invalid number of terms specified. Specified %d terms but found at least %d terms",
									numTerms, index)));
			}

			indexEntries[index] = PointerGetDatum(uuid);
			index++;
		}

		if (pathMap != NULL)
		{
			pathMap[pathIndex].maxIndex = index;
		}

		pathIndex++;
	}

	*nentries = numTerms;
	return indexEntries;
}


static Datum *
GenerateCompositeHashTerms(bson_iter_t *specIter, uint32_t numTerms,
						   uint32_t numPaths, int64_t shardKeyValue,
						   int32_t *nentries, Pointer **extraData)
{
	int64_t *indexHashes = palloc0(sizeof(int64_t) * numTerms);
	IndexBounds *pathMap = palloc0(sizeof(IndexBounds) * numPaths);

	uint32_t index = 0;
	uint32_t pathIndex = 0;
	while (bson_iter_next(specIter))
	{
		if (pathIndex >= numPaths)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("numPaths specified was >= indexPaths encountered"),
							errdetail_log(
								"numPaths specified %d was >= indexPaths %d encountered",
								numPaths,
								pathIndex)));
		}

		const char *key = bson_iter_key(specIter);

		if (!BSON_ITER_HOLDS_ARRAY(specIter))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"term values to generate for a given key should be an array")));
		}

		bson_value_t pathValue = { 0 };
		pathValue.value_type = BSON_TYPE_UTF8;
		pathValue.value.v_utf8.len = strlen(key);
		pathValue.value.v_utf8.str = (char *) key;
		int64_t keyhash = BsonValueHash(&pathValue, 0);

		pathMap[pathIndex].minIndex = index;
		bson_iter_t arrayIter;
		bson_iter_recurse(specIter, &arrayIter);
		while (bson_iter_next(&arrayIter))
		{
			const bson_value_t *indexTerm = bson_iter_value(&arrayIter);

			/*
			 * Hash the value.
			 * We check the GUC in order to force a hash collision.
			 * This is only used for testing and should not be set in production.
			 */
			const char *collationString = NULL;
			uint64_t hash = DefaultUniqueIndexKeyhashOverride > 0 ?
							(uint64_t) DefaultUniqueIndexKeyhashOverride :
							HashBsonValueComparableExtended(indexTerm, keyhash,
															collationString);

			if (index > numTerms)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
								errmsg(
									"Invalid number of terms specified. Specified %d terms but found at least %d terms",
									numTerms, index),
								errdetail_log(
									"Invalid number of terms specified. Specified %d terms but found at least %d terms",
									numTerms, index)));
			}

			indexHashes[index] = hash;
			index++;
		}

		pathMap[pathIndex].maxIndex = index;
		pathIndex++;
	}

	if (numPaths == 0)
	{
		*nentries = 0;
		return NULL;
	}

	/* Now we have indexhashes populated with all the hashes per term
	 * We also have the path map.
	 */
	int totalCompositeTermCount = 1;
	for (uint32 i = 0; i < numPaths; i++)
	{
		pathMap[i].numTerms = pathMap[i].maxIndex - pathMap[i].minIndex;
		if (pathMap[i].numTerms == 0)
		{
			ereport(ERROR, (errmsg("Unexpected - should not have 0 terms for path %u",
								   i)));
		}

		totalCompositeTermCount = totalCompositeTermCount * pathMap[i].numTerms;
	}

	Datum *indexTerms = palloc(sizeof(Datum) * totalCompositeTermCount);
	for (int i = 0; i < totalCompositeTermCount; i++)
	{
		int termIndex = i;
		int64_t termHash = 0;
		for (uint32_t j = 0; j < numPaths; j++)
		{
			int32_t currentIndex = termIndex % pathMap[j].numTerms;
			termIndex = termIndex / pathMap[j].numTerms;

			/* access the hash */
			int64_t current = indexHashes[currentIndex + pathMap[j].minIndex];

			/* Combine hashes */
			termHash = (int64_t) hash_combine64((uint64) termHash, (uint64) current);
		}

		pg_uuid_t *uuid = palloc(sizeof(pg_uuid_t));
		int64_t *firstBytes = (int64_t *) &uuid->data[0];
		*firstBytes = shardKeyValue;
		int64_t *lastBytes = (int64_t *) &uuid->data[8];
		*lastBytes = termHash;
		indexTerms[i] = UUIDPGetDatum(uuid);
	}

	if (extraData != NULL)
	{
		IndexBoundsWithLength *boundsWithLength = palloc0(sizeof(IndexBoundsWithLength) *
														  totalCompositeTermCount);

		IndexBoundsWithLength singleBounds = { 0 };
		singleBounds.length = numPaths;
		singleBounds.indexBounds = pathMap;
		singleBounds.isCompositeHash = true;
		for (int i = 0; i < totalCompositeTermCount; i++)
		{
			boundsWithLength[i] = singleBounds;
		}

		*extraData = (Pointer *) boundsWithLength;
	}

	pfree(indexHashes);
	*nentries = totalCompositeTermCount;
	return indexTerms;
}


static bool
TryGetOptionalCollectionId(const BsonShardPathExclusionOptions *options,
						   int64_t *collectionId)
{
	const char *pathDefinition = GET_STRING_RELOPTION(options, optionalCollectionId);
	if (pathDefinition == NULL)
	{
		*collectionId = 0;
		return false;
	}
	else
	{
		memcpy(collectionId, pathDefinition, sizeof(uint64_t));
		return true;
	}
}


static void
ParseUniqueShardMetadata(bson_iter_t *specIter, UniqueShardDocumentMetadata *metadata)
{
	int numRequiredFlags = 0;
	while (bson_iter_next(specIter))
	{
		const char *key = bson_iter_key(specIter);
		if (strcmp(key, "$shard_key_value") == 0)
		{
			numRequiredFlags++;
			metadata->shardKeyValue = bson_iter_int64(specIter);
		}
		else if (strcmp(key, "$numTerms") == 0)
		{
			numRequiredFlags++;
			metadata->numTerms = bson_iter_int32(specIter);
		}
		else if (strcmp(key, "$numPaths") == 0)
		{
			/* This is the last known metadata path */
			numRequiredFlags++;
			metadata->numPaths = bson_iter_int32(specIter);
			break;
		}
		else if (strcmp(key, "$collation") == 0)
		{
			metadata->collation = bson_iter_utf8(specIter, NULL);
		}
	}

	if (numRequiredFlags < 3)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Missing required fields for unique shard key path"),
						errdetail_log(
							"Required fields: $shard_key_value=%ld, $numTerms=%d, $numPaths=%d",
							metadata->shardKeyValue, metadata->numTerms,
							metadata->numPaths)));
	}
}


static Datum *
ExtractUniqueShardTermsFromInput(pgbson *input, int32_t *nentries, Pointer **extraData,
								 BsonShardPathExclusionOptions *options,
								 int32 *searchMode)
{
	bson_iter_t specIter;
	UniqueShardDocumentMetadata metadata = { 0 };
	PgbsonInitIterator(input, &specIter);
	ParseUniqueShardMetadata(&specIter, &metadata);

	int64_t optionalCollectionId = 0;
	if (TryGetOptionalCollectionId(options, &optionalCollectionId) &&
		(uint64_t) optionalCollectionId == metadata.shardKeyValue)
	{
		/*
		 * A sparse unique document with no terms is missing every indexed path and
		 * must never conflict, so it generates no entries and matches nothing. This
		 * has to precede the optional key short circuit below: matching everything
		 * there would defer the conflict decision to the path column, which still
		 * generates terms for the missing paths.
		 * Unsharded collection and we're matching the collection id, skip generating hash
		 * terms.
		 */
		if (searchMode && metadata.numTerms > 0)
		{
			*searchMode = RUM_SEARCH_MODE_DEFAULT_TRUE;
		}

		*nentries = 0;
		return NULL;
	}

	if (metadata.collation != NULL)
	{
		/* We do not support collation for unique indexes for sharded collections.
		 * TODO: Add support for this.
		 */
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("Collation is not supported for unique shard key path")));
	}

	if (options->enableCompositeHashGeneration)
	{
		return GenerateCompositeHashTerms(&specIter, metadata.numTerms, metadata.numPaths,
										  metadata.shardKeyValue,
										  nentries, extraData);
	}
	else
	{
		return GenerateNonCompositeHashTerms(&specIter, metadata.numTerms,
											 metadata.numPaths, metadata.shardKeyValue,
											 nentries, extraData);
	}
}


Datum
gin_bson_unique_shard_extract_value(PG_FUNCTION_ARGS)
{
	pgbson *input = PG_GETARG_PGBSON_PACKED(0);
	int32 *nentries = (int32 *) PG_GETARG_POINTER(1);

	Pointer **extraData = NULL;

	BsonShardPathExclusionOptions baseOptions = { 0 };
	BsonShardPathExclusionOptions *optionsPtr = &baseOptions;
	if (PG_HAS_OPCLASS_OPTIONS())
	{
		optionsPtr = (BsonShardPathExclusionOptions *) PG_GET_OPCLASS_OPTIONS();
	}

	int32 searchMode = RUM_SEARCH_MODE_DEFAULT_TRUE;
	Datum *indexEntries = ExtractUniqueShardTermsFromInput(input, nentries, extraData,
														   optionsPtr, &searchMode);
	PG_FREE_IF_COPY(input, 0);
	PG_RETURN_POINTER(indexEntries);
}


Datum
gin_bson_unique_shard_extract_query(PG_FUNCTION_ARGS)
{
	pgbson *input = PG_GETARG_PGBSON_PACKED(0);
	int32 *nentries = (int32 *) PG_GETARG_POINTER(1);
	StrategyNumber strategy = PG_GETARG_UINT16(2);
	Pointer **extraData = (Pointer **) PG_GETARG_POINTER(4);
	int32 *searchMode = (int32 *) (PG_NARGS() > 6 ? PG_GETARG_POINTER(6) : NULL);

	if (strategy != 1)
	{
		ereport(ERROR, errmsg("Invalid strategy number %d", strategy));
	}

	BsonShardPathExclusionOptions baseOptions = { 0 };
	BsonShardPathExclusionOptions *optionsPtr = &baseOptions;
	if (PG_HAS_OPCLASS_OPTIONS())
	{
		optionsPtr = (BsonShardPathExclusionOptions *) PG_GET_OPCLASS_OPTIONS();
	}

	Datum *indexEntries = ExtractUniqueShardTermsFromInput(input, nentries, extraData,
														   optionsPtr, searchMode);

	PG_FREE_IF_COPY(input, 0);
	PG_RETURN_POINTER(indexEntries);
}


Datum
gin_bson_unique_shard_pre_consistent(PG_FUNCTION_ARGS)
{
	bool *recheck = (bool *) PG_GETARG_POINTER(5);

	/* If we found a match it's a hash match so we need to recheck the runtime */
	*recheck = true;
	PG_RETURN_BOOL(true);
}


Datum
gin_bson_unique_shard_consistent(PG_FUNCTION_ARGS)
{
	bool *check = (bool *) PG_GETARG_POINTER(0);
	bool *recheck = (bool *) PG_GETARG_POINTER(5);
	Pointer *extra_data = (Pointer *) PG_GETARG_POINTER(4);

	IndexBoundsWithLength *boundsWithLength = (IndexBoundsWithLength *) extra_data;

	if (boundsWithLength->isCompositeHash)
	{
		/* The hash is now an exact match - recheck on the runtime */
		*recheck = true;
		PG_RETURN_BOOL(true);
	}

	for (int i = 0; i < boundsWithLength->length; i++)
	{
		IndexBounds bounds = boundsWithLength->indexBounds[i];
		bool columnMatched = false;
		for (int j = bounds.minIndex; j < bounds.maxIndex; j++)
		{
			if (check[j])
			{
				columnMatched = true;
				break;
			}
		}

		if (!columnMatched)
		{
			PG_RETURN_BOOL(false);
		}
	}

	/* If we found a match it's a hash match so we need to recheck the runtime */
	*recheck = true;
	PG_RETURN_BOOL(true);
}


/* Validates that the path specified when creating
 * the index is valid. */
static void
ValidateExclusionPathSpec(const char *prefix)
{
	if (prefix == NULL)
	{
		return;
	}

	int32_t stringLength = strlen(prefix);
	if (stringLength == 0)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE), errmsg(
							"Unique hash index path must not be empty")));
	}

	if (prefix[stringLength - 1] == '.')
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE), errmsg(
							"Unique hash path must not have a trailing '.'")));
	}
}


/*
 * Given the composite type shard_key_value_and_document, extracts the
 * shard_key_value and document pieces out of the composite type.
 */
static pgbson *
GetShardKeyAndDocument(HeapTupleHeader input, int64_t *shardKey)
{
	/* Extract data about the row. */
	HeapTupleHeader tupleHeader = input;

	bool isNull;
	Datum shardKeyDatum = GetAttributeByNum(tupleHeader, 1, &isNull);
	if (isNull)
	{
		ereport(ERROR, (errmsg("Shard_key_value should not be null")));
	}

	Datum documentDatum = GetAttributeByNum(tupleHeader, 2, &isNull);
	if (isNull)
	{
		ereport(ERROR, (errmsg("The document value must not be null")));
	}

	*shardKey = DatumGetInt64(shardKeyDatum);
	return DatumGetPgBsonPacked(documentDatum);
}


/*
 * Implements the logic that GenerateTerms needs to determine whether a path
 * should be indexed. Follows similar logic to the Single path index.
 */
static IndexTraverseOption
GetExclusionIndexTraverseOption(void *contextOptions,
								const char *currentPath,
								uint32_t currentPathLength,
								bson_type_t bsonType, int32_t *pathIndex)
{
	BsonGinExclusionHashOptions *option = (BsonGinExclusionHashOptions *) contextOptions;
	const char *indexPath;
	uint32_t indexPathLength;
	Get_Index_Path_Option(option, path, indexPath, indexPathLength);
	bool isWildcard = false;
	*pathIndex = 0;
	return GetSinglePathIndexTraverseOptionCore(indexPath, indexPathLength,
												currentPath, currentPathLength,
												isWildcard);
}


/*
 * Helper method that implements the core logic for extracting terms from a given document
 * and shard key. Walks the document and builds the index terms for both extract_query and
 * extract_value. Generates the term as per a single key index, and then builds the
 * Hash(shard_key, term) as the term to be returned for each generated term.
 */
static void
GenerateTermsForExclusion(pgbson *document,
						  int64_t shardKey,
						  GenerateTermsContext *context,
						  GinEntryPathData *pathData,
						  bool generateRootTerm)
{
	context->traverseOptionsFunc = &GetExclusionIndexTraverseOption;
	context->generateNotFoundTerm = true;
	GenerateTerms(document, context, pathData, generateRootTerm);

	/* Now walk the generated terms and replace them with the hash */
	for (int i = 0; i < pathData->terms.index; i++)
	{
		Datum entry = pathData->terms.entries[i];
		bytea *termBson = DatumGetByteaPP(entry);
		BsonIndexTerm indexTerm;
		InitializeBsonIndexTerm(termBson, &indexTerm);

		/* We store the term in a uuid as it is a cheap way to store
		 * 16 bytes without the length prefix overhead that bytea
		 * has. This will reduce the overall index term size for this term */
		pg_uuid_t *uuid = palloc(sizeof(pg_uuid_t));
		int64_t *firstBytes = (int64_t *) &uuid->data[0];
		*firstBytes = shardKey;
		int64_t *lastBytes = (int64_t *) &uuid->data[8];
		*lastBytes = BsonValueHash(&indexTerm.element.bsonValue, 0);
		pathData->terms.entries[i] = UUIDPGetDatum(uuid);
	}
}


/*
 * Utility function that iterates on all keys of a unique shard document and takes action
 * against a terms hash set. In case of a HASH_FIND action, this function also returns a
 * boolean indicating an uniqueness conflict. It also records each path and whether it
 * holds a null term so that paths present on only one side can be reconciled after.
 */
static bool
ProcessUniqueShardDocumentKeysNew(pgbson *uniqueShardDocument,
								  int64_t *shardKeyComparison,
								  HTAB *termsHashSet, HASHACTION hashAction,
								  UniqueShardDocumentPaths *documentPaths)
{
	bson_iter_t specIter;
	UniqueShardDocumentMetadata metadata = { 0 };
	PgbsonInitIterator(uniqueShardDocument, &specIter);
	ParseUniqueShardMetadata(&specIter, &metadata);

	*shardKeyComparison = metadata.shardKeyValue;
	documentPaths->numPaths = 0;
	while (bson_iter_next(&specIter))
	{
		/*
		 * This skips the loop until we reach the keys that contain arrays. These are the ones
		 * that store the terms we need to process.
		 */
		if (!BSON_ITER_HOLDS_ARRAY(&specIter))
		{
			continue;
		}

		if (documentPaths->numPaths >= INDEX_MAX_KEYS)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Unique shard document has more paths than "
								   "supported")));
		}

		UniqueShardDocumentPath *documentPath =
			&documentPaths->paths[documentPaths->numPaths++];
		documentPath->path = bson_iter_key_string_view(&specIter);
		documentPath->hasNullTerm = false;
		documentPath->hasTermMatch = false;

		bson_iter_t arrayIter;
		bson_iter_recurse(&specIter, &arrayIter);
		while (bson_iter_next(&arrayIter))
		{
			UniqueIndexTermHashEntry searchEntry = { 0 };
			searchEntry.element.path = documentPath->path.string;
			searchEntry.element.pathLength = documentPath->path.length;
			searchEntry.element.bsonValue = *bson_iter_value(&arrayIter);
			searchEntry.collationString = metadata.collation;

			if (searchEntry.element.bsonValue.value_type == BSON_TYPE_NULL ||
				searchEntry.element.bsonValue.value_type == BSON_TYPE_UNDEFINED)
			{
				documentPath->hasNullTerm = true;
			}

			/* Query hash table with given action. */
			bool found;
			hash_search(termsHashSet, &searchEntry, hashAction, &found);

			if (found && hashAction == HASH_FIND)
			{
				/* keyTerm pair on the document was found on the hash table. */
				documentPath->hasTermMatch = true;
				break;
			}
		}

		if (hashAction == HASH_FIND && !documentPath->hasTermMatch &&
			!(EnableUniqueNullMissingEquivalence && documentPath->hasNullTerm))
		{
			/*
			 * No term for this key was found on the hash table and the path cannot
			 * match a missing path on the left either, meaning the unique shard
			 * documents don't have a uniqueness conflict.
			 */
			return false;
		}
	}

	return true;
}


/*
 * Hash function for unique index term entries - hashes path + value.
 */
static uint32
UniqueIndexTermHashFunc(const void *obj, size_t objsize)
{
	const UniqueIndexTermHashEntry *hashEntry = obj;
	uint32 pathHash = hash_bytes((const unsigned char *) hashEntry->element.path,
								 (int) hashEntry->element.pathLength);

	return (uint32) HashBsonValueComparableExtended(&hashEntry->element.bsonValue,
													pathHash,
													hashEntry->collationString);
}


/*
 * Compare function for unique index term entries - compares path + value.
 */
static int
UniqueIndexTermCompareFunc(const void *obj1, const void *obj2, Size objsize)
{
	const UniqueIndexTermHashEntry *hashEntry1 = obj1;
	const UniqueIndexTermHashEntry *hashEntry2 = obj2;

	int minLength = Min(hashEntry1->element.pathLength, hashEntry2->element.pathLength);
	int result = strncmp(hashEntry1->element.path, hashEntry2->element.path, minLength);

	if (result != 0)
	{
		return result;
	}

	if (hashEntry1->element.pathLength != hashEntry2->element.pathLength)
	{
		return hashEntry1->element.pathLength - hashEntry2->element.pathLength;
	}

	bool isComparisonValidIgnore = false;
	return CompareBsonValueAndTypeWithCollation(&hashEntry1->element.bsonValue,
												&hashEntry2->element.bsonValue,
												&isComparisonValidIgnore,
												hashEntry1->collationString);
}


/*
 * Creates a hash table for unique index term comparison using path + value.
 */
static HTAB *
CreateUniqueIndexTermHashSet(void)
{
	HASHCTL hashInfo = CreateExtensionHashCTL(
		sizeof(UniqueIndexTermHashEntry),
		sizeof(UniqueIndexTermHashEntry),
		UniqueIndexTermCompareFunc,
		UniqueIndexTermHashFunc
		);
	HTAB *hashSet =
		hash_create("Unique Index Term Hash Table", 32, &hashInfo,
					DefaultExtensionHashFlags);

	return hashSet;
}


/*
 * Utility function that receives a unique shard document (i.e. document returned from the generate_unique_shard_document function),
 * inserts all terms in a hash table and returns it to the caller along with its paths.
 */
static HTAB *
GetUniqueShardDocumentTermsHTABNew(pgbson *uniqueShardDocument, int64_t *shardKeyValue,
								   UniqueShardDocumentPaths *documentPaths)
{
	HTAB *termsHashSet = CreateUniqueIndexTermHashSet();
	ProcessUniqueShardDocumentKeysNew(uniqueShardDocument, shardKeyValue,
									  termsHashSet, HASH_ENTER, documentPaths);
	return termsHashSet;
}


static int
CompareUniqueShardDocumentPath(const void *left, const void *right)
{
	const UniqueShardDocumentPath *leftPath = (const UniqueShardDocumentPath *) left;
	const UniqueShardDocumentPath *rightPath = (const UniqueShardDocumentPath *) right;
	return CompareStringView(&leftPath->path, &rightPath->path);
}


/*
 * Given the paths of the left and right unique shard documents, where every path
 * on the right has already been probed against the terms on the left, checks
 * whether the documents conflict.
 *
 * A sparse unique shard document omits the paths missing from the source
 * document. A missing path is the same key as a literal null, so a path present
 * on only one side matches only when that side holds a null term for it, which
 * keeps the check symmetric regardless of which document was inserted first. A
 * document missing every path is not indexed and never conflicts. Non sparse
 * documents always carry every path, so this reduces to a term match per path.
 */
static bool
AreUniqueShardDocumentPathsConflicting(UniqueShardDocumentPaths *leftPaths,
									   UniqueShardDocumentPaths *rightPaths)
{
	if (leftPaths->numPaths == 0 || rightPaths->numPaths == 0)
	{
		return false;
	}

	qsort(leftPaths->paths, leftPaths->numPaths, sizeof(UniqueShardDocumentPath),
		  CompareUniqueShardDocumentPath);
	qsort(rightPaths->paths, rightPaths->numPaths, sizeof(UniqueShardDocumentPath),
		  CompareUniqueShardDocumentPath);

	int32_t leftIndex = 0;
	int32_t rightIndex = 0;
	while (leftIndex < leftPaths->numPaths || rightIndex < rightPaths->numPaths)
	{
		int comparison;
		if (leftIndex >= leftPaths->numPaths)
		{
			comparison = 1;
		}
		else if (rightIndex >= rightPaths->numPaths)
		{
			comparison = -1;
		}
		else
		{
			comparison = CompareUniqueShardDocumentPath(&leftPaths->paths[leftIndex],
														&rightPaths->paths[rightIndex]);
		}

		if (comparison == 0)
		{
			/* Path on both sides: a right term must have matched a left term */
			if (!rightPaths->paths[rightIndex].hasTermMatch)
			{
				return false;
			}

			leftIndex++;
			rightIndex++;
		}
		else if (comparison < 0)
		{
			/* Path missing on the right: it matches only a null term on the left */
			if (!leftPaths->paths[leftIndex].hasNullTerm)
			{
				return false;
			}

			leftIndex++;
		}
		else
		{
			/* Path missing on the left: it matches only a null term on the right */
			if (!rightPaths->paths[rightIndex].hasNullTerm)
			{
				return false;
			}

			rightIndex++;
		}
	}

	return true;
}


Datum
gin_bson_unique_shard_rum_config(PG_FUNCTION_ARGS)
{
	RumConfig *config = (RumConfig *) PG_GETARG_POINTER(0);
	config->skipGenerateEmptyEntries = true;
	PG_RETURN_VOID();
}


static void
ValidateOptionalCollectionId(const char *prefix)
{
	if (prefix == NULL)
	{
		/* validate can be called with the default value NULL. */
		return;
	}

	int64_t collectionId = pg_strtoint64(prefix);
	if (collectionId < 1)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE), errmsg(
							"Optional collection id must be a valid positive int64")));
	}
}


static Size
FillOptionalCollectionId(const char *prefix, void *buffer)
{
	if (prefix == NULL)
	{
		return 0;
	}

	int64_t collectionId = pg_strtoint64(prefix);
	if (buffer != NULL)
	{
		char *collectionIdBuffer = (char *) &collectionId;
		memcpy(buffer, collectionIdBuffer, sizeof(collectionId));
	}

	return sizeof(collectionId) + 1;
}


Datum
bson_unique_shard_path_options(PG_FUNCTION_ARGS)
{
	local_relopts *relopts = (local_relopts *) PG_GETARG_POINTER(0);

	init_local_reloptions(relopts, sizeof(BsonShardPathExclusionOptions));

	/* add an option that has a default value of single path and accepts *one* value
	 *  This is used later to key off whether it's a single path or multi-key wildcard index options */
	add_local_int_reloption(relopts, "optionsType",
							"The type of the options struct.",
							IndexOptionsType_UniqueShardPath, /* default value */
							IndexOptionsType_UniqueShardPath, /* min */
							IndexOptionsType_UniqueShardPath, /* max */
							offsetof(BsonShardPathExclusionOptions, base.type));
	add_local_int_reloption(relopts, "version",
							"The version of the options struct.",
							IndexOptionsVersion_V0,         /* default value */
							IndexOptionsVersion_V0,         /* min */
							IndexOptionsVersion_V0,         /* max */
							offsetof(BsonShardPathExclusionOptions, base.version));

	add_local_bool_reloption(relopts, "cmp",
							 "Whether to generate composite based hash terms",
							 false,
							 offsetof(BsonShardPathExclusionOptions,
									  enableCompositeHashGeneration));

	/* This needs to be a string option since collection_id is an uint64 and
	 * and reloption can only be an int32. we can't use double since it may lose precision for uint64 values.
	 */
	add_local_string_reloption(relopts, "optsk",
							   "The optional collection id for the unique shard path",
							   NULL,
							   ValidateOptionalCollectionId,
							   FillOptionalCollectionId,
							   offsetof(BsonShardPathExclusionOptions,
										optionalCollectionId));

	PG_RETURN_VOID();
}
