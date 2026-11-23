/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * include/documentdb_distributed_init.h
 *
 * The implementation for shard colocation for documentdb with citus.
 *
 *-------------------------------------------------------------------------
 */
#ifndef DOCUMENTDB_DISTRIBUTED_INIT_H
#define DOCUMENTDB_DISTRIBUTED_INIT_H

void InitDocumentDBDistributedConfigurations(const char *prefix);
void DocumentDBDistributed_InstallBsonMemVTablesLocal(void);
PGDLLEXPORT const char * GetDocumentDBDistributedBinaryVersion(void);

#endif
