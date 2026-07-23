/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/planner/selectivity.h
 *
 * Definitions for selectivity estimation of BSON operators.
 *
 *-------------------------------------------------------------------------
 */

#ifndef PG_DOCUMENTDB_CORE_SELECTIVITY_H
#define PG_DOCUMENTDB_CORE_SELECTIVITY_H

#include <postgres.h>

/*
 * Hook that lets a higher layer decide whether btree-based bson selectivity
 * estimation should be enabled, given the configured default GUC value.
 */
typedef bool (*ShouldEnableBtreeBsonSelectivityFromStatsFunc)(void);
extern ShouldEnableBtreeBsonSelectivityFromStatsFunc
	should_enable_btree_bson_selectivity_from_stats_hook;

#endif
