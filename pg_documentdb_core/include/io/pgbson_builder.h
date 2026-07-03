/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/io/pgbson_builder.h
 *
 * Zero-copy pgbson builder.
 *
 * Builds a BSON document by recording append operations. Each Append/Start/End
 * call appends a small operation descriptor and incrementally updates the
 * running size of every currently open document. No BSON bytes are produced
 * until PgbsonBuilderFinalize is called, which performs a single palloc of
 * the exact final size and a single linear emit pass.
 *
 * This removes the two-pass pattern of the old API (call one set of
 * estimator functions to size the buffer, then call a parallel set of
 * writer functions to produce it) and eliminates the memcpy overhead of
 * the standard pgbson_writer's final bson_t -> pgbson conversion.
 *
 * IMPORTANT: key and value pointers passed to the Append* functions are
 * stored by reference, not copied, and are dereferenced during
 * PgbsonBuilderFinalize. The caller is responsible for keeping the backing
 * storage alive (and unchanged) until Finalize returns. String literals,
 * palloc'd buffers that outlive the builder, and stable pgbson *'s are all
 * fine; values on transient stack frames or scratch buffers that may be
 * overwritten before Finalize are not.
 *
 *-------------------------------------------------------------------------
 */

#ifndef PRIVATE_PGBSON_H
#error Do not import this header file. Import bson_core.h instead
#endif

#ifndef PG_BSON_BUILDER_H
#define PG_BSON_BUILDER_H

#include <datatype/timestamp.h>


/* Opaque op descriptor; defined in the implementation file. */
typedef struct pgbson_builder_op pgbson_builder_op;

/* Opaque key-arena chunk; defined in the implementation file. */
typedef struct pgbson_builder_key_chunk pgbson_builder_key_chunk;


/*
 * Builder state.
 *
 * Callers should treat all fields as opaque and only interact through the
 * PgbsonBuilder* functions.
 */
typedef struct
{
	/* Recorded operations, in emit order. */
	pgbson_builder_op *ops;
	uint32_t opCount;
	uint32_t opCapacity;

	/*
	 * Stack of currently open containers (documents or arrays). Entry 0
	 * is always the root document. Each subsequent entry is a container
	 * opened by PgbsonBuilderStartDocument/StartArray and not yet closed.
	 *
	 *   openOpIndex[i]    -- index into ops[] of the START_DOCUMENT op
	 *                        that opened this container (unused for root).
	 *   payloadSize[i]    -- running sum of element bytes inside this
	 *                        container, excluding its own 4-byte size
	 *                        header and trailing NUL terminator.
	 *   arrayIndex[i]     -- for array frames, the next index to assign
	 *                        to an array element; UINT32_MAX for document
	 *                        frames (including the root).
	 */
	uint32_t *openOpIndex;
	uint32_t *payloadSize;
	uint32_t *arrayIndex;
	uint32_t stackDepth;
	uint32_t stackCapacity;

	/*
	 * Singly-linked list of key-string chunks. Used to hold decimal
	 * representations of auto-generated array indices whose pointers
	 * need to stay stable across op-array growth. Chunks are never
	 * realloc'd after allocation.
	 */
	pgbson_builder_key_chunk *keyArena;
} pgbson_builder;


/* Lifecycle. */
void PgbsonBuilderInit(pgbson_builder *builder);
pgbson * PgbsonBuilderFinalize(pgbson_builder *builder);

/*
 * Variant of PgbsonBuilderInit that pre-sizes the internal op array and
 * stack so callers with high-confidence prior knowledge of their final
 * op count and/or nesting depth can skip the dynamic-growth repallocs.
 *
 * Use only when the hints are well-grounded (e.g., a fixed-shape struct
 * with a known field count). For the common case where the final op
 * count is not known up-front, prefer PgbsonBuilderInit — its lazy
 * allocation + amortised doubling growth is already cheap.
 *
 * Hint semantics:
 *   - opCapacityHint == 0      -- lazy ops alloc on first append (same
 *                                 as PgbsonBuilderInit).
 *   - opCapacityHint > 0       -- eagerly palloc room for that many ops;
 *                                 dynamic doubling kicks in if exceeded.
 *   - stackCapacityHint == 0   -- default INITIAL_STACK_CAPACITY frames
 *                                 (same as PgbsonBuilderInit).
 *   - stackCapacityHint > 0    -- pre-grow the stack to fit at least
 *                                 that many frames before any push.
 *
 * A wrong-low hint costs nothing (the dynamic-growth path picks up where
 * the hint runs out); a wrong-high hint wastes memory until Finalize.
 *
 * The default Init hot path and all subsequent Append* / Start / End
 * code paths are byte-identical to a build without this function:
 * callers that never invoke PgbsonBuilderInitWithHints pay zero cost.
 */
void PgbsonBuilderInitWithHints(pgbson_builder *builder,
								uint32_t opCapacityHint,
								uint32_t stackCapacityHint);

/*
 * Returns the exact size in bytes the final pgbson will occupy (including
 * the 4-byte document size header and trailing NUL). Safe to call at any
 * point, including while sub-documents are still open; in that case the
 * returned size assumes all currently open sub-documents will be closed
 * immediately.
 */
uint32_t PgbsonBuilderGetBsonSize(const pgbson_builder *builder);

/* Scalar appenders. */
void PgbsonBuilderAppendUtf8(pgbson_builder *builder, const char *path,
							 uint32_t pathLength, const char *value);
void PgbsonBuilderAppendUtf8WithLength(pgbson_builder *builder, const char *path,
									   uint32_t pathLength,
									   const char *value, uint32_t valueLength);
void PgbsonBuilderAppendInt32(pgbson_builder *builder, const char *path,
							  uint32_t pathLength, int32_t value);
void PgbsonBuilderAppendInt64(pgbson_builder *builder, const char *path,
							  uint32_t pathLength, int64 value);
void PgbsonBuilderAppendDouble(pgbson_builder *builder, const char *path,
							   uint32_t pathLength, double value);
void PgbsonBuilderAppendBool(pgbson_builder *builder, const char *path,
							 uint32_t pathLength, bool value);
void PgbsonBuilderAppendNull(pgbson_builder *builder, const char *path,
							 uint32_t pathLength);
void PgbsonBuilderAppendDateTime(pgbson_builder *builder, const char *path,
								 uint32_t pathLength, TimestampTz timestamp);
void PgbsonBuilderAppendDateTimeMillis(pgbson_builder *builder, const char *path,
									   uint32_t pathLength,
									   int64 millisSinceUnixEpoch);

/*
 * Appends an existing pgbson as a sub-document. The raw BSON bytes of
 * `document` are copied into the final buffer during Finalize; `document`
 * must remain valid until then.
 */
void PgbsonBuilderAppendDocument(pgbson_builder *builder, const char *path,
								 uint32_t pathLength, const pgbson *document);

/*
 * Append a BSON value by pointer. Scalar types are forwarded to the
 * corresponding typed Append* fast path so they incur no extra overhead;
 * all other types (OID, binary, regex, symbol, code, code-with-scope,
 * dbpointer, decimal128, timestamp, embedded document/array, min/max/
 * undefined) are recorded as a single generic op that emits the wire
 * bytes directly during Finalize.
 *
 * `value` is stored by reference — neither the bson_value_t itself nor
 * the variable-length bytes it points at (utf8/binary/regex/code/...)
 * are copied. Callers must keep all of them alive, and unchanged, until
 * PgbsonBuilderFinalize returns.
 */
void PgbsonBuilderAppendValue(pgbson_builder *builder, const char *path,
							  uint32_t pathLength, const bson_value_t *value);

/*
 * Append the current element of a BSON iterator. The iterator's embedded
 * bson_value_t lives on the caller's stack, so this function copies it
 * into builder-owned storage before recording the op; the raw BSON bytes
 * the value points into (via iter->raw) must still outlive the builder.
 */
void PgbsonBuilderAppendIter(pgbson_builder *builder, const char *path,
							 uint32_t pathLength, const bson_iter_t *iter);

/*
 * Opens a new sub-document. Subsequent Append* calls populate it until a
 * matching PgbsonBuilderEndDocument call. Calls may be nested.
 */
void PgbsonBuilderStartDocument(pgbson_builder *builder, const char *path,
								uint32_t pathLength);
void PgbsonBuilderEndDocument(pgbson_builder *builder);

/*
 * Opens a new sub-array. Subsequent PgbsonBuilderArrayAppend / Array
 * StartDocument / StartArray calls populate it until a matching
 * PgbsonBuilderEndArray call. Calls may be nested. While an array is
 * the top-of-stack frame the only valid element-adding calls are the
 * PgbsonBuilderArray* family; regular Append / StartDocument calls
 * error out.
 */
void PgbsonBuilderStartArray(pgbson_builder *builder, const char *path,
							 uint32_t pathLength);
void PgbsonBuilderEndArray(pgbson_builder *builder);

/* Array-element appenders (keys are auto-generated as "0", "1", ...). */
void PgbsonBuilderArrayAppendUtf8(pgbson_builder *builder, const char *value);
void PgbsonBuilderArrayAppendUtf8WithLength(pgbson_builder *builder,
											const char *value,
											uint32_t valueLength);
void PgbsonBuilderArrayAppendInt32(pgbson_builder *builder, int32_t value);
void PgbsonBuilderArrayAppendInt64(pgbson_builder *builder, int64 value);
void PgbsonBuilderArrayAppendDouble(pgbson_builder *builder, double value);
void PgbsonBuilderArrayAppendBool(pgbson_builder *builder, bool value);
void PgbsonBuilderArrayAppendNull(pgbson_builder *builder);
void PgbsonBuilderArrayAppendDateTime(pgbson_builder *builder,
									  TimestampTz timestamp);
void PgbsonBuilderArrayAppendDocument(pgbson_builder *builder,
									  const pgbson *document);

/*
 * Open a new sub-document as the next element of the currently open
 * array, and a new sub-array as the next element respectively. Close
 * them with the matching PgbsonBuilderEndDocument / PgbsonBuilderEndArray.
 */
void PgbsonBuilderArrayStartDocument(pgbson_builder *builder);
void PgbsonBuilderArrayStartArray(pgbson_builder *builder);

/*
 * Splice the inner elements of a foreign BSON document into the currently
 * open container, at the same level. The input must be a complete BSON
 * document (starts with a 4-byte little-endian size header and ends with
 * a NUL terminator); only its interior element bytes are copied into the
 * final buffer during Finalize.
 *
 * The backing storage must outlive the builder until Finalize returns
 * (pointer is stored by reference, like the other Append* APIs).
 *
 * The currently open container must be a document, not an array.
 */
void PgbsonBuilderConcatBytes(pgbson_builder *builder, const uint8_t *bsonBytes,
							  uint32_t bsonBytesLength);
void PgbsonBuilderConcat(pgbson_builder *builder, const pgbson *document);

#endif
