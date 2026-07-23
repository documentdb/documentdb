/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/index_am/index_am_metadata.c
 *
 * Debug and inspection helpers for index AM state.
 *
 *-------------------------------------------------------------------------
 */


#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <access/relation.h>
#include <nodes/pathnodes.h>
#include <port/pg_bitutils.h>
#include <utils/rel.h>

#include "io/bson_core.h"
#include "index_am/index_am_utils.h"
#include "opclass/bson_gin_composite_scan.h"
#include "opclass/bson_gin_index_mgmt.h"


/*
 * Reads composite-index opclass metadata. Returns Full with *info fully
 * populated when the metadata blob is available, Partial with only
 * info->isMultiKey set as a fallback, or None if neither can be read.
 */
CompositeOpClassMetadataReadResult
TryGetCompositeOpClassMetadataInfo(Oid indexOid, LOCKMODE lockmode,
								   CompositeOpClassMetadataInfo *info)
{
	Relation indexRel = try_relation_open(indexOid, lockmode);
	if (indexRel == NULL)
	{
		return CompositeOpClassMetadataReadResult_None;
	}

	CompositeOpClassMetadataReadResult result = CompositeOpClassMetadataReadResult_None;

	bool supportsOrderedOperatorScans = false;
	PGFunction multiKeyStatusFunc = NULL;
	PGFunction getOpclassMetadataFunc = NULL;

	if (GetCompositeOpClassWithProps(indexRel, &supportsOrderedOperatorScans,
									 &multiKeyStatusFunc, &getOpclassMetadataFunc))
	{
		BsonGinCompositePathOptions *opts =
			(indexRel->rd_opcoptions != NULL && indexRel->rd_opcoptions[0] != NULL) ?
			(BsonGinCompositePathOptions *) indexRel->rd_opcoptions[0] : NULL;

		bool hasBlobMetadata = getOpclassMetadataFunc != NULL && opts != NULL &&
							   opts->enableMetadataBasedTracking;

		if (hasBlobMetadata)
		{
			uint64 blob = DatumGetUInt64(DirectFunctionCall1(getOpclassMetadataFunc,
															 PointerGetDatum(indexRel)));

			bool isMultiKey = false;
			uint32_t multiKeyPathBitmask = 0;
			bool hasCorrelatedReducedTerms = false;
			bool hasTruncation = false;
			uint32_t truncatedPathBitmask = 0;
			DecodeCompositeOpClassQueryMetadata(opts, blob, &isMultiKey,
												&multiKeyPathBitmask,
												&hasCorrelatedReducedTerms,
												&hasTruncation,
												&truncatedPathBitmask);

			info->rawBlob = blob;
			info->isMultiKey = isMultiKey;
			info->multiKeyPathBitMask = multiKeyPathBitmask;
			info->multiKeyPathCount = pg_popcount32(multiKeyPathBitmask);
			info->hasCorrelatedReducedTerms = hasCorrelatedReducedTerms;
			info->hasTruncation = hasTruncation;
			info->trackedTruncatedPathCount = pg_popcount32(truncatedPathBitmask);

			result = CompositeOpClassMetadataReadResult_Full;
		}
		else if (multiKeyStatusFunc != NULL)
		{
			/*
			 * No blob available; fall back to the metapage multi-key status so
			 * telemetry still surfaces isMultiKey. The richer fields stay at
			 * their zero defaults.
			 */
			info->isMultiKey = DatumGetBool(DirectFunctionCall1(multiKeyStatusFunc,
																PointerGetDatum(
																	indexRel)));

			result = CompositeOpClassMetadataReadResult_Partial;
		}
	}

	relation_close(indexRel, lockmode);
	return result;
}
