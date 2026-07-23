/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/customscan/bson_tid_dedup_scan.h
 *
 * CustomScan that sits on top of an order-preserving subplan (e.g. a
 * MergeAppend over per-branch ordered index scans) and drops rows whose heap
 * TID has already been emitted. Used to make a sort-merge over a multi-key
 * index correct: a single document can satisfy more than one merged branch, so
 * without de-duplication the MergeAppend would return it once per branch.
 *
 *-------------------------------------------------------------------------
 */

#ifndef BSON_TID_DEDUP_SCAN_H
#define BSON_TID_DEDUP_SCAN_H

#include <postgres.h>
#include <nodes/pathnodes.h>

/*
 * Wrap subpath in a TID de-dup CustomScan path. The wrapper preserves subpath's
 * pathkeys (it streams rows through in order, only dropping duplicates), so the
 * requested sort order and any LIMIT short-circuit above it are retained.
 */
Path * WrapPathWithTidDedup(Path *subpath);

#endif /* BSON_TID_DEDUP_SCAN_H */
