/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/commands/write_commands.h
 *
 * Exports for generating write command queries.
 *
 *-------------------------------------------------------------------------
 */
#ifndef WRITE_COMMANDS_H
#define WRITE_COMMANDS_H

#include <postgres.h>

#include "io/bson_core.h"


Query * GenerateUpdateQuery(text *database, pgbson *updateSpec,
							bool setStatementTimeout);
Query * GenerateDeleteQuery(text *database, pgbson *deleteSpec,
							bool setStatementTimeout);
Query * GenerateFindAndModifyQuery(text *database, pgbson *findAndModifySpec,
								   bool setStatementTimeout);

#endif
