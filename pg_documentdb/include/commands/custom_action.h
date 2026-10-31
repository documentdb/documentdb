/* Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 */

#ifndef DOCUMENTDB_CUSTOM_ACTION_H
#define DOCUMENTDB_CUSTOM_ACTION_H

#include "io/bson_core.h"

typedef pgbson *(*CustomActionFunction)(pgbson *spec);

void RegisterCustomAction(const char *actionName, CustomActionFunction function);
Datum documentdb_custom_action(PG_FUNCTION_ARGS);

#endif
