/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * include/utils/documentdb_conversion_codes.h
 *
 * Utilities for converting backend errors to wire protocol errors.
 *
 *-------------------------------------------------------------------------
 */

#ifndef DOCUMENTDB_CONVERSION_CODES_H
#define DOCUMENTDB_CONVERSION_CODES_H

#include <postgres.h>

int32 ConvertDocumentDBErrorToWireError(int32 sqlState);

#endif
