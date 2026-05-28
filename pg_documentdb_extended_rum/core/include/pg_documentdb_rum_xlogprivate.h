/*-------------------------------------------------------------------------
 *
 * pg_documentdb_rum_xlogprivate.h
 *	Private declarations for XLog support for ex RUM indexes.
 *
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2021, Postgres Professional
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#ifndef __PG_DOCUMENTDB_RUM_XLOGPRIVATE_H__
#define __PG_DOCUMENTDB_RUM_XLOGPRIVATE_H__

#include "postgres.h"
#include "access/generic_xlog.h"
#include "miscadmin.h"
#include "access/xlog_internal.h"
#include "access/xlogutils.h"

/*
 * The format of the insertion record varies depending on the page type.
 * ginxlogInsert is the common part between all variants.
 *
 * Backup Blk 0: target page
 * Backup Blk 1: left child, if this insertion finishes an incomplete split
 */

#define XLOG_GIN_INSERT 0x20

typedef struct
{
	uint16 flags;               /* GIN_INSERT_ISLEAF and/or GIN_INSERT_ISDATA */

	/*
	 * FOLLOWS:
	 *
	 * 1. if not leaf page, block numbers of the left and right child pages
	 * whose split this insertion finishes, as BlockIdData[2] (beware of
	 * adding fields in this struct that would make them not 16-bit aligned)
	 *
	 * 2. a ginxlogInsertEntry or ginxlogRecompressDataLeaf struct, depending
	 * on tree type.
	 *
	 * NB: the below structs are only 16-bit aligned when appended to a
	 * ginxlogInsert struct! Beware of adding fields to them that require
	 * stricter alignment.
	 */
} ginxlogInsert;

typedef struct
{
	OffsetNumber offset;
	bool isDelete;
	IndexTupleData tuple;       /* variable length */
} ginxlogInsertEntry;


/*
 * Flags used in ginxlogInsert and ginxlogSplit records
 */
#define GIN_INSERT_ISDATA 0x01      /* for both insert and split records */
#define GIN_INSERT_ISLEAF 0x02      /* ditto */
#define GIN_SPLIT_ROOT 0x04         /* only for split records */

#endif
