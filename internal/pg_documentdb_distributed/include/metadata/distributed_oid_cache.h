/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/metadata/distributed_oid_cache.h
 *
 * Public API for OID caching that is local to the distributed extension.
 * The OSS core metadata cache (pg_documentdb/metadata_cache) is intentionally
 * Citus-agnostic; any OID that is meaningful only when a distribution layer
 * is loaded lives here instead.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DISTRIBUTED_OID_CACHE_H
#define DISTRIBUTED_OID_CACHE_H

#include <postgres.h>


/*
 * Oid of pg_catalog.worker_partial_agg(oid, anyelement), the partial-aggregate
 * wrapper Citus injects when pushing partial aggregation down to a shard.
 * Returns InvalidOid on Citus versions that do not expose this function.
 */
Oid CitusWorkerPartialAggregateFunctionOid(void);


/*
 * Oid of pg_catalog.worker_binary_partial_agg(oid, anyelement), the binary
 * variant of the partial-aggregate wrapper. Returns InvalidOid on Citus
 * versions that do not expose this function.
 */
Oid CitusWorkerBinaryPartialAggregateFunctionOid(void);

#endif
