/*-------------------------------------------------------------------------
 *
 * pg_documentdb_rum_dedup.h
 *	  Exported definitions for RUM index deduplication.
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 2006-2022, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */

#ifndef __PG_DOCUMENTDB_RUM_DEDUP_H__
#define __PG_DOCUMENTDB_RUM_DEDUP_H__

typedef void *(*CreateIndexArrayTrackerState)(void);
typedef bool (*IndexArrayTrackerAdd)(void *state, ItemPointer item);
typedef void (*FreeIndexArrayTrackerState)(void *);

/*
 * Adapter struct that provides function pointers to allow
 * for extensibility in managing index array state for index scans.
 * The current requirements on the interface is to provide an abstraction
 * that can be used to deduplicate array entries in the index scan.
 */
typedef struct RumIndexArrayStateFuncs
{
	/* Create opaque state to manage entries in this specific index scan */
	CreateIndexArrayTrackerState createState;

	/* Add an item to the index scan and return whether or not it is new or existing */
	IndexArrayTrackerAdd addItem;

	/* Frees the temporary state used for the adding of items */
	FreeIndexArrayTrackerState freeState;
} RumIndexArrayStateFuncs;


#endif
