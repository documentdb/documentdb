/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/metadata/distributed_oid_cache.c
 *
 * OID cache for symbols owned by the distribution layer (Citus). Lives in
 * the distributed extension because the OSS core metadata cache must stay
 * Citus-agnostic. Lazy population on first access, invalidated on PROCOID
 * syscache events.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <miscadmin.h>
#include <catalog/pg_type.h>
#include <nodes/makefuncs.h>
#include <parser/parse_func.h>
#include <utils/inval.h>
#include <utils/syscache.h>

#include "metadata/distributed_oid_cache.h"


typedef enum DistributedOidCacheValidity
{
	DISTRIBUTED_OID_CACHE_INVALID,
	DISTRIBUTED_OID_CACHE_VALID,
} DistributedOidCacheValidity;


typedef struct DistributedOidCacheData
{
	Oid CitusWorkerPartialAggOid;
	Oid CitusWorkerBinaryPartialAggOid;
} DistributedOidCacheData;


static DistributedOidCacheValidity OidCacheValidity = DISTRIBUTED_OID_CACHE_INVALID;
static bool RegisteredCallback = false;
static DistributedOidCacheData OidCache = { 0 };


static void InitializeDistributedOidCache(void);
static void InvalidateDistributedOidCache(Datum arg, int cacheid, uint32 hashvalue);
static Oid LookupCitusPartialAggFunctionOid(const char *functionName);


Oid
CitusWorkerPartialAggregateFunctionOid(void)
{
	InitializeDistributedOidCache();

	if (OidCache.CitusWorkerPartialAggOid == InvalidOid)
	{
		OidCache.CitusWorkerPartialAggOid =
			LookupCitusPartialAggFunctionOid("worker_partial_agg");
	}

	return OidCache.CitusWorkerPartialAggOid;
}


Oid
CitusWorkerBinaryPartialAggregateFunctionOid(void)
{
	InitializeDistributedOidCache();

	if (OidCache.CitusWorkerBinaryPartialAggOid == InvalidOid)
	{
		OidCache.CitusWorkerBinaryPartialAggOid =
			LookupCitusPartialAggFunctionOid("worker_binary_partial_agg");
	}

	return OidCache.CitusWorkerBinaryPartialAggOid;
}


/*
 * Ensures the cache is in the VALID state and that the syscache invalidation
 * callback is installed exactly once for this backend.
 */
static void
InitializeDistributedOidCache(void)
{
	if (OidCacheValidity == DISTRIBUTED_OID_CACHE_VALID)
	{
		return;
	}

	if (!RegisteredCallback)
	{
		CacheRegisterSyscacheCallback(PROCOID, &InvalidateDistributedOidCache,
									  (Datum) 0);
		RegisteredCallback = true;
	}

	memset(&OidCache, 0, sizeof(DistributedOidCacheData));
	OidCacheValidity = DISTRIBUTED_OID_CACHE_VALID;
}


/*
 * PROCOID syscache invalidation callback. Marks the cache invalid so the
 * next getter re-initializes from the current catalog state.
 *
 * Signature is fixed by PG's SyscacheCallbackFunction typedef; arg/cacheid/
 * hashvalue are unused because we register a single callback for a single
 * cache and conservatively invalidate every entry on any pg_proc change.
 */
static void
InvalidateDistributedOidCache(Datum arg, int cacheid, uint32 hashvalue)
{
	OidCacheValidity = DISTRIBUTED_OID_CACHE_INVALID;
}


/*
 * Looks up a pg_catalog.<functionName>(oid, anyelement) function and returns
 * its Oid, or InvalidOid if the function is not defined in the current Citus
 * version.
 */
static Oid
LookupCitusPartialAggFunctionOid(const char *functionName)
{
	Oid argTypes[2] = { OIDOID, ANYELEMENTOID };
	List *qualifiedName = list_make2(makeString("pg_catalog"),
									 makeString(pstrdup(functionName)));
	bool missingOk = true;

	return LookupFuncName(qualifiedName, 2, argTypes, missingOk);
}
