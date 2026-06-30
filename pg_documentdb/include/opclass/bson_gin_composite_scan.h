/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/opclass/bson_gin_index_mgmt.h
 *
 * Common declarations of the bson index management methods.
 *
 *-------------------------------------------------------------------------
 */

 #ifndef BSON_GIN_COMPOSITE_SCAN_H
 #define BSON_GIN_COMPOSITE_SCAN_H

 #include <access/skey.h>

struct IndexPath;
bool GetEqualityRangePredicatesForIndexPath(struct IndexPath *indexPath, void *options,
											bool equalityPrefixes[INDEX_MAX_KEYS], bool
											nonEqualityPrefixes[INDEX_MAX_KEYS]);
bool CompositePathHasFirstColumnSpecified(IndexPath *indexPath);
char *SerializeBoundsStringForExplain(bytea * entry, void *extraData, PG_FUNCTION_ARGS,
									  List **rawPathBounds, const char **minBounds);

Datum FormCompositeDatumFromQuals(List *indexQuals, bool isMultiKey,
								  bool hasCorrelatedReducedTerm,
								  bool supportsOperatorOrderedScans,
								  uint32_t multiKeyBitMask);
char * SerializeCompositeIndexKeyForExplain(bytea *entry);

void DecodeCompositeOpClassQueryMetadata(void *options, uint64_t opclassMetadata,
										 bool *hasMultiKey, uint32_t *multiKeyPathBitmask,
										 bool *hasCorrelatedReducedTerms,
										 bool *hasTruncation);
void DecodeCompositeOpClassMetadata(void *options, uint64_t opclassMetadata,
									bool *hasMultiKey, uint32_t *multiKeyBitMask,
									List **multiKeyPerPathList,
									bool *hasCorrelatedReducedTerms, bool *hasTruncation,
									List **truncatedPerPathList);
void SerializeCompositeIndexKeyForExplainToWriter(bytea *entry, pgbson_writer *writer);
bool ModifyScanKeysForCompositeScan(ScanKey scankey, int nscankeys, ScanKey
									targetScanKey, bool hasArrayKeys, bool
									hasCorrelatedReducedTerms,
									bool supportsOrderedOperatorScans,
									uint32_t multiKeyBitMask);

int32_t GetScanTypeForScanDirection(ScanDirection scanDirection);
ScanDirection GetOrderByScanDirectionFromDatum(bytea *opClassoptions, Datum orderByDatum);
 #endif
