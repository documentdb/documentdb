/*-------------------------------------------------------------------------
 *
 * include/utils/utf8_utils.h
 *
 * utf8 utility functions from pg_wchar.hfor versions earlier than PG 17, which added some of these functions natively.
 *
 * Portions Copyright (c) Microsoft Corporation.  All rights reserved.
 * Portions Copyright (c) 2015-2022, Postgres Professional
 * Portions Copyright (c) 1996-2016, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#ifndef UTF8_UTILS_H
#define UTF8_UTILS_H

#include <postgres.h>
#include <stdbool.h>
#include <mb/pg_wchar.h>

#define UTF8_MAX_CODEPOINT 0x10FFFF
#define UTF8_AFTER_UTF16_SURROGATE 0xE000

#define UTF8_MAX_1BYTE_CODEPOINT 0x7F
#define UTF8_MAX_2BYTE_CODEPOINT 0x7FF
#define UTF8_MAX_3BYTE_CODEPOINT 0xFFFF


static inline bool
is_utf8_continuation_byte(pg_wchar c)
{
	return (c & 0xC0) == 0x80;
}


#if PG_VERSION_NUM < 170000

/*
 * Number of bytes needed to represent the given char in UTF8.
 * This function was grabbed from pg_wchar.h
 * https://github.com/postgres/postgres/blob/ae58189a4d523f0156ebe30f4534180555669e88/src/include/mb/pg_wchar.h#L622-L633
 */
static inline int
unicode_utf8len(pg_wchar c)
{
	if (c <= UTF8_MAX_1BYTE_CODEPOINT)
	{
		return 1;
	}
	else if (c <= UTF8_MAX_2BYTE_CODEPOINT)
	{
		return 2;
	}
	else if (c <= UTF8_MAX_3BYTE_CODEPOINT)
	{
		return 3;
	}
	else
	{
		return 4;
	}
}


#endif
#endif /* UTF8_UTILS_H */
