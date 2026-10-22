/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/vector/vector_common.h
 *
 * Common definitions for vector indexes.
 *
 *-------------------------------------------------------------------------
 */
#ifndef VECTOR_COMMON__H
#define VECTOR_COMMON__H

/* pgvector VECTOR_MAX_DIM: 16000 */
/* dimensions for type vector cannot exceed 16000 */
#define VECTOR_MAX_DIMENSIONS 16000
#define VECTOR_MAX_DIMENSIONS_NON_COMPRESSED 2000
#define VECTOR_MAX_DIMENSIONS_HALF_COMPRESSED 4000
#define VECTOR_MAX_DIMENSIONS_PQ_COMPRESSED VECTOR_MAX_DIMENSIONS

/* ivfflat parameters */
#define IVFFLAT_DEFAULT_NPROBES 1
#define IVFFLAT_MIN_NPROBES 1
#define IVFFLAT_MAX_NPROBES 32768

#define IVFFLAT_DEFAULT_LISTS 100
#define IVFFLAT_MIN_LISTS 1
#define IVFFLAT_MAX_LISTS 32768

#define VECTOR_PARAMETER_NAME_IVF_NPROBES "nProbes"
#define VECTOR_PARAMETER_NAME_IVF_NPROBES_STR_LEN 7
#define VECTOR_PARAMETER_NAME_IVF_NLISTS "numLists"

/* hnsw parameters */
#define HNSW_DEFAULT_M 16
#define HNSW_MIN_M 2
#define HNSW_MAX_M 100

#define HNSW_DEFAULT_EF_CONSTRUCTION 64
#define HNSW_MIN_EF_CONSTRUCTION 4
#define HNSW_MAX_EF_CONSTRUCTION 1000

#define HNSW_DEFAULT_EF_SEARCH 40
#define HNSW_MIN_EF_SEARCH 1
#define HNSW_MAX_EF_SEARCH 1000

#define VECTOR_PARAMETER_NAME_HNSW_M "m"
#define VECTOR_PARAMETER_NAME_HNSW_EF_CONSTRUCTION "efConstruction"
#define VECTOR_PARAMETER_NAME_HNSW_EF_SEARCH "efSearch"
#define VECTOR_PARAMETER_NAME_HNSW_EF_SEARCH_STR_LEN 8

/* Search parameter name for iterative scan mode */
#define VECTOR_PARAMETER_NAME_ITERATIVE_SCAN "iterativeScan"
#define VECTOR_PARAMETER_NAME_ITERATIVE_SCAN_STR_LEN 13

/*
 * Marker/value key stamped onto the vector search param bson whenever
 * an explicit filterMode embeds a user filter directly into the vector
 * search query's WHERE clause. Its value is the resolved
 * VectorSearchFilterMode enum stored as an int32, which the planner (see
 * custom_query_scan.c) honors for this query. This lets the value survive
 * across the query-build/plan boundary as part of the bson_search_param()
 * argument. Mirrors the user-facing 'filterMode' vector search option (see
 * VectorSearchFilterMode in vector_spec.h), which is parsed from the string
 * VECTOR_FILTER_MODE_VALUE_* constants below.
 */
#define VECTOR_PARAMETER_NAME_FILTER_MODE "filterMode"
#define VECTOR_PARAMETER_NAME_FILTER_MODE_STR_LEN 10

#define VECTOR_FILTER_MODE_VALUE_APPROXIMATE "approximate"
#define VECTOR_FILTER_MODE_VALUE_EXACT "exact"
#define VECTOR_FILTER_MODE_VALUE_AUTO_SELECT "autoSelect"

/* dynamic calculation of nprobes or efSearch depending on collection size */
#define VECTOR_SEARCH_SMALL_COLLECTION_ROWS 10000

/*
 * ApiGucPrefix.enableVectorHNSWIndex GUC determines vector indexes
 * and queries are enabled in documentdb_api or not.
 */
extern bool EnableVectorHNSWIndex;

/*
 * GUC to enable vector pre-filtering feature for vector search.
 * This is disabled by default.
 */
extern bool EnableVectorPreFilter;
extern bool EnableVectorPreFilterV2;

/*
 * GUC to set the iterative scan mode for pre-filtering
 */
extern int VectorPreFilterIterativeScanMode;

/*
 * Selectivity threshold for filterMode 'autoSelect'. Estimates at or below
 * max(this fraction, 1/default_statistics_target) use the filter path;
 * larger estimates use the vector path. The default is 0.01 (1 percent),
 * with a range of 0 to 1. Zero does not bypass the statistics floor.
 */
extern double VectorAutoFilterSelectivityThreshold;

/*
 * GUC to enable vector compression feature for vector search.
 */
extern bool EnableVectorCompressionHalf;
extern bool EnableVectorCompressionPQ;

/*
 * GUC to enable vector search default search parameter calculation.
 */
extern bool EnableVectorCalculateDefaultSearchParameter;

#endif
