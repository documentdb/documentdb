/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/opclass/bson_gin_composite.h
 *
 * Exports for the composite index term and index management.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_GIN_COMPOSITE_H
#define BSON_GIN_COMPOSITE_H

Datum * GenerateCompositeTermsFromIndexSpec(pgbson *document, pgbson *keySpec,
											uint32_t *numTerms);

#endif
