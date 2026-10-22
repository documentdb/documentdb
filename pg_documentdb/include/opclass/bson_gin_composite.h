/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * include/opclass/bson_gin_composite.h
 *
 * Exports for the composite index term and index management.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_GIN_COMPOSITE_H
#define BSON_GIN_COMPOSITE_H

#include <nodes/primnodes.h>

#include "opclass/bson_gin_index_mgmt.h"

typedef struct CompositeTermGenerationState CompositeTermGenerationState;

BsonGinCompositePathOptions * BuildCompositeOptionsFromIndexSpec(pgbson *keySpec, const
																 StringView *
																 collationStringView);
CompositeTermGenerationState * PrepareCompositeTermGeneration(
	BsonGinCompositePathOptions *options);
Datum * GenerateCompositeTermsFromOptions(pgbson *document,
										  CompositeTermGenerationState *state,
										  uint32_t *numTerms);

bool CompositeIndexExprCanRequireRuntimeRecheck(Expr *expr);

#endif
