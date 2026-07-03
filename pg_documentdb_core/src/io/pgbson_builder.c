/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/io/pgbson_builder.c
 *
 * Zero-copy pgbson builder.
 *
 * Records a sequence of append operations into an internal op log while
 * incrementally tracking the running byte size of every currently open
 * document. PgbsonBuilderFinalize performs a single palloc of the exact
 * final size and a single linear emit pass to produce the pgbson.
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <utils/memutils.h>
#include <utils/timestamp.h>

#define PRIVATE_PGBSON_H
#include "io/pgbson.h"
#include "io/pgbson_builder.h"
#undef PRIVATE_PGBSON_H

#include "utils/documentdb_errors.h"
#include "utils/documentdb_pg_compatibility.h"


/* --------------------------------------------------------- */
/* BSON constants                                            */
/* --------------------------------------------------------- */

/*
 * Returns the uint64 byte size of a BSON element header (type tag byte +
 * key bytes + NUL terminator). uint64 return type guarantees that any
 * subsequent size arithmetic performed by callers is done in 64-bit and
 * therefore cannot silently wrap a 32-bit accumulator — the caller's
 * overflow check against MAX_BSON_DOCUMENT_SIZE remains authoritative.
 */
#define BSON_ELEMENT_HEADER_SIZE(keyLength) \
	((uint64_t) 1 + (uint64_t) (keyLength) + (uint64_t) 1)

/*
 * Hard upper bound on any BSON document this builder will produce,
 * matching the wire-protocol maximum (16 MiB). All payload accumulation
 * is checked against this limit so 32-bit size arithmetic cannot wrap
 * and produce an undersized allocation in Finalize. We enforce the bound
 * locally instead of relying on caller-imposed limits so this module
 * remains safe as call sites evolve.
 */
#define MAX_BSON_DOCUMENT_SIZE (16 * 1024 * 1024)

/*
 * BSON wire-format type tags come from libbson's bson_type_t enum (see
 * <bson/bson-types.h>, included transitively via io/pgbson.h). The enum
 * values are defined to equal the on-the-wire byte, so we can pass them
 * straight through to the uint8_t typeTag field with no remapping.
 */

/* Initial capacities for the dynamic arrays inside pgbson_builder. */
#define INITIAL_OP_CAPACITY 16
#define INITIAL_STACK_CAPACITY 4

/*
 * Default capacity of a newly allocated key-arena chunk. Large enough to
 * hold ~50 decimal uint32 keys without re-allocating; oversized keys get
 * their own dedicated chunk via the max(defaultCap, requested) rule.
 */
#define KEY_ARENA_CHUNK_SIZE 512


/* --------------------------------------------------------- */
/* Op descriptors                                            */
/* --------------------------------------------------------- */

typedef enum
{
	OP_UTF8,
	OP_INT32,
	OP_INT64,
	OP_DOUBLE,
	OP_BOOL,
	OP_NULL,
	OP_DATETIME,
	OP_DOCUMENT,        /* embed raw bytes from an existing pgbson */
	OP_CONCAT_BYTES,    /* splice inner elements of a foreign BSON doc */
	OP_BSON_VALUE,      /* generic bson_value_t payload emit */
	OP_START_DOCUMENT,  /* begin nested sub-document or sub-array */
	OP_END_DOCUMENT     /* end nested sub-document or sub-array */
} pgbson_builder_op_kind_t;

/*
 * `kind` and `typeTag` are stored 1-byte per op so each op record stays
 * 32 bytes — a builder may record millions of ops, and widening these
 * fields to a full enum (typically 4 bytes in C pre-C23) would inflate
 * working-set memory noticeably. We keep the enum declarations (the
 * local op-kind enum and libbson's bson_type_t) for symbolic names and
 * -Wswitch exhaustiveness, expose the enum types at function boundaries
 * so callers can't swap a kind for a type tag, and use these storage
 * typedefs at the struct fields. The static assertions pin the contract:
 * if a future op or BSON type pushes the value range past 0xFF the
 * build will fail here instead of silently truncating at the assignment
 * site.
 */
typedef uint8_t pgbson_builder_op_kind;
StaticAssertDecl((unsigned int) OP_END_DOCUMENT <= UINT8_MAX,
				 "pgbson_builder_op_kind_t values must fit in uint8_t storage");

typedef uint8_t pgbson_builder_type_tag;
StaticAssertDecl((unsigned int) BSON_TYPE_MINKEY <= UINT8_MAX,
				 "bson_type_t values must fit in uint8_t storage");

/*
 * A single recorded operation. Key/value pointers are borrowed references
 * that must outlive the builder until Finalize.
 */
struct pgbson_builder_op
{
	pgbson_builder_op_kind kind;
	pgbson_builder_type_tag typeTag;    /* BSON type byte; unused for OP_END_DOCUMENT */
	const char *path;
	uint32_t pathLength;

	union
	{
		/* OP_UTF8 */
		struct
		{
			const char *data;
			uint32_t length;    /* excludes NUL terminator */
		}
		utf8;

		/*
		 * OP_DOCUMENT: bytes/size point at the full body of an existing
		 * BSON doc (size header + elements + trailing NUL); copied verbatim
		 * after the element header during emit.
		 *
		 * OP_CONCAT_BYTES: bytes/size are pre-adjusted to the inner payload
		 * of a foreign BSON doc (i.e., pointing past the 4-byte size header
		 * and excluding the trailing NUL); copied verbatim at current offset
		 * during emit with no surrounding element header.
		 */
		struct
		{
			const uint8_t *bytes;
			uint32_t size;
		}
		doc;

		/* OP_START_DOCUMENT: filled in by the matching END_DOCUMENT. */
		uint32_t childTotalSize;

		/*
		 * OP_BSON_VALUE: borrowed pointer to a bson_value_t whose payload
		 * is emitted directly as the element value. The struct itself
		 * must outlive the builder; so must every variable-length buffer
		 * it points at (utf8/binary/regex/code/...). For iterator-based
		 * callers the builder copies the 40-byte value record into its
		 * own arena so only the underlying raw BSON bytes need to stay
		 * alive — see PgbsonBuilderAppendIter.
		 */
		const bson_value_t *bsonValue;

		int32_t i32;
		int64 i64;      /* OP_INT64 / OP_DATETIME (ms since Unix epoch) */
		double d;
		bool b;
	}
	v;
};


/*
 * Chunk of palloc'd storage for auto-generated array-element keys.
 *
 * Array keys ("0", "1", ...) are stored by pointer in the op descriptors,
 * so their backing memory must have stable addresses across subsequent
 * op-array growth. We therefore allocate keys out of a singly-linked
 * list of chunks whose bodies are never realloc'd.
 *
 * Chunks are popped en masse when the enclosing PostgreSQL memory
 * context is reset; no per-builder free is required.
 */
struct pgbson_builder_key_chunk
{
	struct pgbson_builder_key_chunk *next;
	uint32_t used;
	uint32_t cap;
	char data[FLEXIBLE_ARRAY_MEMBER];
};


/* Sentinel marking a stack frame that is a document, not an array. */
#define ARRAY_INDEX_NONE UINT32_MAX


/* --------------------------------------------------------- */
/* Dynamic array helpers                                     */
/* --------------------------------------------------------- */

/*
 * Raise ERROR when a builder operation would produce a BSON document
 * larger than the wire-protocol maximum. Extracted into a pg_noinline
 * helper so the hot paths in AddElementSize and friends stay small and
 * branch-predictable, and so every overflow/limit breach produces
 * identical caller-visible behaviour.
 */
static pg_noinline void
pg_attribute_noreturn()
ThrowDocumentTooLarge(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_DOCUMENTDB_BSONOBJECTTOOLARGE),
			 errmsg("BSON document would exceed the maximum allowed size "
					"of %d bytes", MAX_BSON_DOCUMENT_SIZE)));
}


/*
 * Reserve the next slot in the op log and return a pointer to it.
 *
 * Lazily allocates the op array on first use so a builder that is
 * initialised but never appended to pays no allocation cost. On overflow,
 * doubles the capacity via repalloc — amortising growth to O(1) per append
 * and keeping the array contiguous so the Finalize emit pass remains a
 * single linear scan over ops[0..opCount).
 *
 * Capacity doubling is guarded against uint32 wraparound: a builder whose
 * input is bounded by MAX_BSON_DOCUMENT_SIZE cannot reach that threshold
 * in practice, but the explicit check keeps the allocator invariants
 * intact if call sites ever change.
 *
 * The returned pointer is valid only until the next call to ReserveOp on
 * the same builder (a subsequent repalloc may move the backing array).
 * Callers therefore populate each op fully before requesting another.
 */
static inline pgbson_builder_op *
ReserveOp(pgbson_builder *builder)
{
	if (unlikely(builder->ops == NULL))
	{
		builder->opCapacity = INITIAL_OP_CAPACITY;
		builder->ops = (pgbson_builder_op *)
					   palloc(sizeof(pgbson_builder_op) * builder->opCapacity);
	}
	else if (unlikely(builder->opCount == builder->opCapacity))
	{
		if (unlikely(builder->opCapacity > UINT32_MAX / 2 ||
					 builder->opCapacity > (uint32_t) (MaxAllocSize /
													   sizeof(pgbson_builder_op) / 2)))
		{
			ThrowDocumentTooLarge();
		}
		builder->opCapacity *= 2;
		builder->ops = (pgbson_builder_op *)
					   repalloc(builder->ops,
								sizeof(pgbson_builder_op) * builder->opCapacity);
	}

	return &builder->ops[builder->opCount++];
}


/*
 * Grow the open-document stack (openOpIndex[] and payloadSize[]) so it can
 * hold at least `needed` frames.
 *
 * The two parallel arrays are grown in lockstep because every stack frame
 * needs both: openOpIndex[i] locates the START_DOCUMENT op whose size
 * header must be patched at EndDocument time, and payloadSize[i] tracks
 * the running byte count inside that document so Finalize can size the
 * final buffer exactly.
 *
 * Uses doubling growth from a small initial capacity (INITIAL_STACK_
 * CAPACITY) because realistic BSON nesting depth is tiny — the common
 * case never repallocs.
 */
static inline void
EnsureStackCapacity(pgbson_builder *builder, uint32_t needed)
{
	if (likely(needed <= builder->stackCapacity))
	{
		return;
	}

	uint32_t newCap = builder->stackCapacity ? builder->stackCapacity :
					  INITIAL_STACK_CAPACITY;
	while (newCap < needed)
	{
		if (unlikely(newCap > UINT32_MAX / 2))
		{
			ThrowDocumentTooLarge();
		}
		newCap *= 2;
	}

	if (builder->openOpIndex == NULL)
	{
		builder->openOpIndex = (uint32_t *) palloc(sizeof(uint32_t) * newCap);
		builder->payloadSize = (uint32_t *) palloc(sizeof(uint32_t) * newCap);
		builder->arrayIndex = (uint32_t *) palloc(sizeof(uint32_t) * newCap);
	}
	else
	{
		builder->openOpIndex = (uint32_t *) repalloc(builder->openOpIndex,
													 sizeof(uint32_t) * newCap);
		builder->payloadSize = (uint32_t *) repalloc(builder->payloadSize,
													 sizeof(uint32_t) * newCap);
		builder->arrayIndex = (uint32_t *) repalloc(builder->arrayIndex,
													sizeof(uint32_t) * newCap);
	}
	builder->stackCapacity = newCap;
}


/* --------------------------------------------------------- */
/* Key arena for auto-generated array keys                   */
/* --------------------------------------------------------- */

/*
 * Reserve `nbytes` contiguous bytes in the key arena and return a stable
 * pointer to them.
 *
 * The arena is a singly-linked list of palloc'd chunks that are never
 * resized — once a key is written, its pointer remains valid for the
 * entire lifetime of the builder. This is what lets array-element op
 * records safely store a borrowed `path` pointer into arena storage even
 * though the op array itself may be repalloc'd and relocated by later
 * appends.
 *
 * A fresh chunk of KEY_ARENA_CHUNK_SIZE is allocated on first use or
 * whenever the current head chunk cannot satisfy the request; requests
 * larger than the default get a dedicated chunk sized to fit.
 */
static inline char *
ReserveKeyBytes(pgbson_builder *builder, uint32_t nbytes)
{
	pgbson_builder_key_chunk *head = builder->keyArena;
	if (head == NULL || head->used + nbytes > head->cap)
	{
		uint32_t cap = nbytes > KEY_ARENA_CHUNK_SIZE ?
					   nbytes : KEY_ARENA_CHUNK_SIZE;
		pgbson_builder_key_chunk *fresh = (pgbson_builder_key_chunk *)
										  palloc(offsetof(
													 pgbson_builder_key_chunk,
													 data) + cap);
		fresh->next = head;
		fresh->used = 0;
		fresh->cap = cap;
		builder->keyArena = fresh;
		head = fresh;
	}
	char *p = head->data + head->used;
	head->used += nbytes;
	return p;
}


/*
 * Format `value` as a decimal ASCII string (no NUL) into `buf` and
 * return its length. `buf` must be at least 10 bytes (max length of a
 * decimal uint32). Used to generate BSON array keys "0", "1", "2", ...
 * without pulling in printf machinery on the hot path.
 */
static inline uint32_t
FormatUint32Decimal(uint32_t value, char *buf)
{
	if (value == 0)
	{
		buf[0] = '0';
		return 1;
	}

	char tmp[10];
	uint32_t n = 0;
	while (value > 0)
	{
		tmp[n++] = (char) ('0' + (value % 10));
		value /= 10;
	}

	/* Reverse into caller's buffer. */
	for (uint32_t i = 0; i < n; i++)
	{
		buf[i] = tmp[n - 1 - i];
	}
	return n;
}


/*
 * Assert the top-of-stack frame is an array and return the decimal key
 * for the next array element, bumping the frame's next-index counter.
 *
 * The returned pointer is owned by the key arena and stable for the
 * lifetime of the builder, matching the borrowed-key contract the op
 * descriptors rely on.
 */
static inline void
ResolveArrayElementKey(pgbson_builder *builder, const char **outPath,
					   uint32_t *outPathLength)
{
	Assert(builder->stackDepth > 0);
	uint32_t top = builder->stackDepth - 1;
	if (unlikely(builder->arrayIndex[top] == ARRAY_INDEX_NONE))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("PgbsonBuilder array-element call issued while "
							   "top-of-stack frame is a document")));
	}

	char *keyBuf = ReserveKeyBytes(builder, 10);
	uint32_t keyLen = FormatUint32Decimal(builder->arrayIndex[top], keyBuf);

	/* Release unused tail back to the arena so the next key packs tightly. */
	builder->keyArena->used -= (10 - keyLen);

	builder->arrayIndex[top]++;

	*outPath = keyBuf;
	*outPathLength = keyLen;
}


/*
 * Issue ERROR when a regular (explicit-key) Append or StartDocument
 * call is made while the open container is an array. Runtime-checked
 * (not a debug-only assert) so callers see clear diagnostics in release
 * builds.
 */
static inline void
EnsureTopIsDocument(pgbson_builder *builder)
{
	Assert(builder->stackDepth > 0);
	if (unlikely(builder->arrayIndex[builder->stackDepth - 1] != ARRAY_INDEX_NONE))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("PgbsonBuilder document-element call issued "
							   "while top-of-stack frame is an array")));
	}
}


/*
 * Issue ERROR when an Array* call is made while the open container is a
 * document. Mirrors EnsureTopIsDocument for the opposite direction.
 */
static inline void
EnsureTopIsArray(pgbson_builder *builder)
{
	Assert(builder->stackDepth > 0);
	if (unlikely(builder->arrayIndex[builder->stackDepth - 1] == ARRAY_INDEX_NONE))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("PgbsonBuilder array-element call issued while "
							   "top-of-stack frame is a document")));
	}
}


/*
 * Adds `elementSize` bytes to the payload of the currently open document
 * (the top of the stack).
 *
 * `elementSize` must cover the complete element as it will appear in the
 * final BSON: type byte + key + NUL + value bytes. Sub-document elements
 * are charged to the parent in two stages — the enclosing type+key+NUL
 * header is added here at StartDocument time, and the child's body
 * (size header + payload + trailing NUL) is added by EndDocument once
 * the final child size is known.
 *
 * The parameter is uint64 so that the per-call size computation at the
 * call site (header + value bytes) is always performed in 64-bit and
 * cannot wrap silently. The sum is then checked against
 * MAX_BSON_DOCUMENT_SIZE before being truncated back to the uint32
 * running counter — this is the single choke point that protects the
 * final palloc in Finalize from overflow-induced undersizing. We also
 * conservatively reserve the 5 bytes every enclosing document needs for
 * its own size header + trailing NUL, so a sub-document whose full
 * representation would exceed the limit is rejected here rather than at
 * EndDocument time.
 *
 * Keeping the running count incremental means PgbsonBuilderFinalize
 * knows the exact allocation size in O(1) with no re-walk of the op log.
 */
static inline void
AddElementSize(pgbson_builder *builder, uint64_t elementSize)
{
	Assert(builder->stackDepth > 0);

	uint64_t newPayload = (uint64_t)
						  builder->payloadSize[builder->stackDepth - 1] +
						  elementSize;

	/*
	 * Reserve the 5 bytes the enclosing document itself needs (size
	 * header + trailing NUL). This bounds every payload to
	 * MAX_BSON_DOCUMENT_SIZE - 5, which is the largest value for which
	 * payload + 5 still fits the BSON wire-protocol limit.
	 */
	if (unlikely(newPayload > (uint64_t) MAX_BSON_DOCUMENT_SIZE - 5))
	{
		ThrowDocumentTooLarge();
	}

	builder->payloadSize[builder->stackDepth - 1] = (uint32_t) newPayload;
}


/*
 * Reserve an op and initialise the fields every element op shares: kind,
 * type tag, and the (borrowed) key pointer + length.
 *
 * Centralising this avoids repeating four identical assignments in every
 * public Append* function and guarantees the kind/typeTag pair stays in
 * sync with the union variant chosen by the caller. The caller is then
 * responsible for filling in the type-specific `v.*` union field.
 *
 * The enclosing frame must be a document; callers targeting an open array
 * should go through the BeginArrayElementOp path instead so the key is
 * auto-generated from the frame's running index.
 */
static inline pgbson_builder_op *
BeginElementOp(pgbson_builder *builder, pgbson_builder_op_kind kind,
			   pgbson_builder_type_tag typeTag, const char *path,
			   uint32_t pathLength)
{
	EnsureTopIsDocument(builder);

	pgbson_builder_op *op = ReserveOp(builder);
	op->kind = kind;
	op->typeTag = typeTag;
	op->path = path;
	op->pathLength = pathLength;
	return op;
}


/*
 * Array-context counterpart of BeginElementOp. Generates the decimal
 * array key for the current position, bumps the index, and populates
 * the op's key fields so the subsequent type-specific write path is
 * identical to the document case.
 *
 * The enclosing frame must be an array; ResolveArrayElementKey errors if
 * it is not.
 */
static inline pgbson_builder_op *
BeginArrayElementOp(pgbson_builder *builder, pgbson_builder_op_kind kind,
					pgbson_builder_type_tag typeTag, uint32_t *outPathLength)
{
	const char *key;
	uint32_t keyLen;
	ResolveArrayElementKey(builder, &key, &keyLen);

	pgbson_builder_op *op = ReserveOp(builder);
	op->kind = kind;
	op->typeTag = typeTag;
	op->path = key;
	op->pathLength = keyLen;

	*outPathLength = keyLen;
	return op;
}


/* --------------------------------------------------------- */
/* Little-endian helpers for the emit pass                   */
/* --------------------------------------------------------- */

/*
 * Write `value` as a 4-byte little-endian integer at data[*offset] and
 * advance *offset by 4.
 *
 * BSON mandates little-endian on the wire regardless of host byte order,
 * so htole32 is required. memcpy is used rather than a direct store to
 * sidestep strict-aliasing and unaligned-access concerns — modern
 * compilers optimise the 4-byte memcpy to a single mov.
 */
static inline void
EmitInt32LE(uint8_t *data, uint32_t *offset, int32_t value)
{
	uint32_t le = htole32((uint32_t) value);
	memcpy(data + *offset, &le, 4);
	*offset += 4;
}


/*
 * 8-byte little-endian counterpart of EmitInt32LE. Used for INT64 values
 * and (reinterpreted) for BSON UTC datetime, which is a signed 64-bit
 * millisecond count in the wire format.
 */
static inline void
EmitInt64LE(uint8_t *data, uint32_t *offset, int64 value)
{
	uint64 le = htole64((uint64) value);
	memcpy(data + *offset, &le, 8);
	*offset += 8;
}


/*
 * Emit the common 3-part prefix of every BSON element: type tag byte,
 * the UTF-8 key bytes, then the NUL terminator that closes the key.
 *
 * Every non-END_DOCUMENT op's emit arm starts with this, so factoring it
 * out keeps the Finalize switch statement compact and ensures the header
 * layout is written identically for every element kind.
 */
static inline void
EmitElementHeader(uint8_t *data, uint32_t *offset, const pgbson_builder_op *op)
{
	data[(*offset)++] = op->typeTag;
	memcpy(data + *offset, op->path, op->pathLength);
	*offset += op->pathLength;
	data[(*offset)++] = '\0';
}


/* --------------------------------------------------------- */
/* Public API: lifecycle                                     */
/* --------------------------------------------------------- */

/*
 * Initialise a builder to the empty-document state.
 *
 * All dynamic arrays start NULL and are lazily allocated on first use —
 * a builder that is initialised but never appended to performs no
 * palloc until Finalize.
 *
 * The root document is represented by always-present stack frame 0.
 * Every subsequent StartDocument pushes a new frame; EndDocument pops it.
 * Keeping the root as a stack frame lets every Append* call use the same
 * `payloadSize[stackDepth - 1]` indexing without special-casing root.
 */
void
PgbsonBuilderInit(pgbson_builder *builder)
{
	builder->ops = NULL;
	builder->opCount = 0;
	builder->opCapacity = 0;

	builder->openOpIndex = NULL;
	builder->payloadSize = NULL;
	builder->arrayIndex = NULL;
	builder->stackDepth = 0;
	builder->stackCapacity = 0;

	builder->keyArena = NULL;

	/* Push the root document frame. */
	EnsureStackCapacity(builder, 1);
	builder->openOpIndex[0] = 0;    /* unused for root */
	builder->payloadSize[0] = 0;
	builder->arrayIndex[0] = ARRAY_INDEX_NONE;  /* root is a document */
	builder->stackDepth = 1;
}


/*
 * Opt-in variant of PgbsonBuilderInit that pre-sizes the op array and
 * stack from caller-provided hints. See the header for usage guidance.
 *
 * Implementation note: this calls PgbsonBuilderInit verbatim and then
 * adjusts capacities, so the default-Init hot path is byte-identical to
 * a build that doesn't reference this function. Callers who never
 * invoke PgbsonBuilderInitWithHints pay no cost — there is no extra
 * branch on the default path, no extra struct field, and no change to
 * ReserveOp / EnsureStackCapacity.
 *
 * For opCapacityHint we allocate exactly the requested size (not rounded
 * up). The dynamic doubling path in ReserveOp will still kick in if the
 * hint turns out to be too small.
 *
 * For stackCapacityHint we delegate to EnsureStackCapacity, which
 * doubles from the post-Init capacity (INITIAL_STACK_CAPACITY) until
 * the hint is reached. Stack growth is rare and the arrays are small,
 * so we accept the doubling rounding rather than duplicating the alloc
 * logic.
 */
void
PgbsonBuilderInitWithHints(pgbson_builder *builder,
						   uint32_t opCapacityHint,
						   uint32_t stackCapacityHint)
{
	PgbsonBuilderInit(builder);

	if (opCapacityHint > 0)
	{
		if (unlikely(opCapacityHint > (uint32_t) (MaxAllocSize /
												  sizeof(pgbson_builder_op))))
		{
			ThrowDocumentTooLarge();
		}
		builder->opCapacity = opCapacityHint;
		builder->ops = (pgbson_builder_op *)
					   palloc(sizeof(pgbson_builder_op) * opCapacityHint);
	}

	if (stackCapacityHint > builder->stackCapacity)
	{
		EnsureStackCapacity(builder, stackCapacityHint);
	}
}


/*
 * Return the exact byte size the final pgbson will occupy (including the
 * 4-byte root size header and trailing NUL).
 *
 * Works at any point during building. If sub-documents are still open,
 * the returned size is what the document would be if every currently
 * open sub-document were closed immediately at this point — each open
 * frame above root contributes its payload plus its own 4-byte size
 * header and trailing NUL (the enclosing type+key+NUL was already
 * charged to the parent at StartDocument time).
 *
 * Useful for callers that want to pre-check against BSON's 16 MB
 * document limit before spending more work populating the builder.
 */
uint32_t
PgbsonBuilderGetBsonSize(const pgbson_builder *builder)
{
	/*
	 * Sum element payloads of every currently open frame; any frame above
	 * the root still needs its own 4-byte size header and trailing NUL
	 * to be materialized as a sub-document element of its parent. The
	 * enclosing element's type+key+NUL overhead has already been added to
	 * the parent's payloadSize at StartDocument time.
	 *
	 * The accumulator is uint64 so that summing many open frames — each
	 * individually bounded by MAX_BSON_DOCUMENT_SIZE — cannot wrap a
	 * 32-bit counter. Callers that want to enforce the BSON size limit
	 * should compare the returned value against MAX_BSON_DOCUMENT_SIZE
	 * directly; an over-limit intermediate result is still returned
	 * truncated to uint32 only once it is below the limit.
	 */
	uint64_t total = 0;
	for (uint32_t i = 0; i < builder->stackDepth; i++)
	{
		total += (uint64_t) builder->payloadSize[i];
		if (i > 0)
		{
			total += 4 + 1; /* sub-document size header + trailing NUL */
		}
	}

	/* Root document size header + trailing NUL. */
	total += 4 + 1;

	if (unlikely(total > (uint64_t) UINT32_MAX))
	{
		return UINT32_MAX;
	}
	return (uint32_t) total;
}


/* --------------------------------------------------------- */
/* Public API: scalar appenders                              */
/* --------------------------------------------------------- */

/*
 * Append a UTF-8 string element with an explicit byte length.
 *
 * The `value` buffer is stored by reference — only the pointer and length
 * are captured; no bytes are copied until Finalize. Callers must ensure
 * the storage backing `value` lives until PgbsonBuilderFinalize returns
 * and is not mutated in the meantime (see header file contract).
 *
 * BSON string wire layout: int32 byte length (includes trailing NUL) +
 * `valueLength` raw bytes + one NUL, hence the `4 + valueLength + 1`
 * size contribution beyond the element header.
 */
void
PgbsonBuilderAppendUtf8WithLength(pgbson_builder *builder, const char *path,
								  uint32_t pathLength,
								  const char *value, uint32_t valueLength)
{
	pgbson_builder_op *op = BeginElementOp(builder, OP_UTF8, BSON_TYPE_UTF8,
										   path, pathLength);
	op->v.utf8.data = value;
	op->v.utf8.length = valueLength;

	/* header + int32(len+1) + bytes + trailing NUL */
	AddElementSize(builder,
				   BSON_ELEMENT_HEADER_SIZE(pathLength) + 4 + valueLength + 1);
}


/*
 * Convenience overload for NUL-terminated C strings. Computes the byte
 * length once here and delegates to the WithLength form so the emit pass
 * does not need to recompute strlen.
 */
void
PgbsonBuilderAppendUtf8(pgbson_builder *builder, const char *path,
						uint32_t pathLength, const char *value)
{
	PgbsonBuilderAppendUtf8WithLength(builder, path, pathLength,
									  value, (uint32_t) strlen(value));
}


/*
 * Append a 32-bit integer element. The value is stored inline in the op
 * record (no external allocation) and emitted little-endian at Finalize.
 */
void
PgbsonBuilderAppendInt32(pgbson_builder *builder, const char *path,
						 uint32_t pathLength, int32_t value)
{
	pgbson_builder_op *op = BeginElementOp(builder, OP_INT32, BSON_TYPE_INT32,
										   path, pathLength);
	op->v.i32 = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 4);
}


/*
 * Append a 64-bit integer element. See AppendInt32 — same pattern, 8-byte
 * value instead of 4.
 */
void
PgbsonBuilderAppendInt64(pgbson_builder *builder, const char *path,
						 uint32_t pathLength, int64 value)
{
	pgbson_builder_op *op = BeginElementOp(builder, OP_INT64, BSON_TYPE_INT64,
										   path, pathLength);
	op->v.i64 = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 8);
}


/*
 * Append an IEEE-754 double element.
 *
 * BSON stores doubles as their raw 8-byte little-endian representation,
 * matching the host format on every platform documentdb supports, so the
 * value is emitted with a plain memcpy rather than going through a
 * separate byte-swap helper.
 */
void
PgbsonBuilderAppendDouble(pgbson_builder *builder, const char *path,
						  uint32_t pathLength, double value)
{
	pgbson_builder_op *op = BeginElementOp(builder, OP_DOUBLE, BSON_TYPE_DOUBLE,
										   path, pathLength);
	op->v.d = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 8);
}


/*
 * Append a boolean element. BSON encodes bool as a single byte (0x00 or
 * 0x01); the conversion to that wire form is deferred to the emit pass.
 */
void
PgbsonBuilderAppendBool(pgbson_builder *builder, const char *path,
						uint32_t pathLength, bool value)
{
	pgbson_builder_op *op = BeginElementOp(builder, OP_BOOL, BSON_TYPE_BOOL,
										   path, pathLength);
	op->v.b = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 1);
}


/*
 * Append a BSON null element. The BSON wire format for null is just the
 * element header (type + key + NUL) with no value body, so the size
 * contribution is only BSON_ELEMENT_HEADER_SIZE.
 */
void
PgbsonBuilderAppendNull(pgbson_builder *builder, const char *path,
						uint32_t pathLength)
{
	(void) BeginElementOp(builder, OP_NULL, BSON_TYPE_NULL, path, pathLength);
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength));
}


/*
 * Append a BSON UTC datetime element.
 *
 * The conversion from PostgreSQL's TimestampTz (microseconds since
 * 2000-01-01 UTC) to BSON's wire format (milliseconds since the Unix
 * epoch) is performed eagerly here rather than at emit time. This keeps
 * the emit pass free of timestamp-semantics code and avoids needing a
 * dedicated `timestamp` union variant — the already-converted int64 is
 * reused via OP_DATETIME, which shares its emit arm with OP_INT64.
 *
 * The negative-microsecond adjustment handles timestamps whose
 * fractional second is expressed as a negative microsecond remainder
 * (possible for pre-epoch times when `%` returns a negative result).
 */
void
PgbsonBuilderAppendDateTime(pgbson_builder *builder, const char *path,
							uint32_t pathLength, TimestampTz timestamp)
{
	/*
	 * Convert PostgreSQL TimestampTz (microseconds since 2000-01-01 UTC)
	 * to BSON UTC datetime (milliseconds since Unix epoch) at record time
	 * so the emit pass doesn't need to revisit timestamp semantics.
	 */
	time_t secondsSinceUnixEpoch = timestamptz_to_time_t(timestamp);
	int64 usecRem = timestamp % USECS_PER_SEC;
	if (usecRem < 0)
	{
		usecRem += USECS_PER_SEC;
		secondsSinceUnixEpoch -= 1;
	}
	Assert(usecRem >= 0 && usecRem < USECS_PER_SEC);
	int64 milliSinceUnixEpoch = ((int64) secondsSinceUnixEpoch) * 1000 +
								(usecRem / 1000);

	PgbsonBuilderAppendDateTimeMillis(builder, path, pathLength,
									  milliSinceUnixEpoch);
}


/*
 * Append a BSON UTC datetime element directly from the BSON wire format
 * (milliseconds since the Unix epoch). This is the natural entry point
 * when the source value is already in BSON datetime form — e.g. when
 * copying an element from a `bson_iter_t` via `bson_iter_date_time()` —
 * and avoids a needless round-trip through TimestampTz.
 */
void
PgbsonBuilderAppendDateTimeMillis(pgbson_builder *builder, const char *path,
								  uint32_t pathLength,
								  int64 millisSinceUnixEpoch)
{
	pgbson_builder_op *op = BeginElementOp(builder, OP_DATETIME,
										   BSON_TYPE_DATE_TIME,
										   path, pathLength);
	op->v.i64 = millisSinceUnixEpoch;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 8);
}


/*
 * Append an existing pgbson as a sub-document element.
 *
 * Records a pointer to the source document's BSON bytes (VARDATA_ANY)
 * plus their length. The bytes are copied into the final buffer in a
 * single memcpy during Finalize — no parsing, no re-serialisation. The
 * caller must keep `document` alive and unmodified until Finalize
 * returns.
 *
 * Use this for opaque pass-through of a pre-built BSON document. Use
 * StartDocument/EndDocument instead when building a new sub-document
 * field-by-field.
 */
void
PgbsonBuilderAppendDocument(pgbson_builder *builder, const char *path,
							uint32_t pathLength, const pgbson *document)
{
	uint32_t docSize = (uint32_t) VARSIZE_ANY_EXHDR(document);

	pgbson_builder_op *op = BeginElementOp(builder, OP_DOCUMENT,
										   BSON_TYPE_DOCUMENT,
										   path, pathLength);
	op->v.doc.bytes = (const uint8_t *) VARDATA_ANY(document);
	op->v.doc.size = docSize;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + docSize);
}


/* --------------------------------------------------------- */
/* Public API: generic bson_value_t appender                 */
/* --------------------------------------------------------- */

/*
 * Wire-format payload size (excluding the element header) for a single
 * bson_value_t. Closed-form per type — no walk over nested documents
 * required, because embedded document/array values carry their full byte
 * length in v_doc.data_len.
 */
static inline uint64_t
BsonValuePayloadSize(const bson_value_t *value)
{
	switch ((int) value->value_type)
	{
		case BSON_TYPE_DOUBLE:
		case BSON_TYPE_INT64:
		case BSON_TYPE_DATE_TIME:
		case BSON_TYPE_TIMESTAMP:
		{
			return 8;
		}

		case BSON_TYPE_INT32:
		{
			return 4;
		}

		case BSON_TYPE_BOOL:
		{
			return 1;
		}

		case BSON_TYPE_NULL:
		case BSON_TYPE_UNDEFINED:
		case BSON_TYPE_MINKEY:
		case BSON_TYPE_MAXKEY:
		{
			return 0;
		}

		case BSON_TYPE_OID:
		{
			return 12;
		}

		case BSON_TYPE_DECIMAL128:
		{
			return 16;
		}

		case BSON_TYPE_UTF8:
		{
			/* int32 length (incl NUL) + bytes + NUL */
			return (uint64_t) 4 + value->value.v_utf8.len + 1;
		}

		case BSON_TYPE_SYMBOL:
		{
			return (uint64_t) 4 + value->value.v_symbol.len + 1;
		}

		case BSON_TYPE_CODE:
		{
			return (uint64_t) 4 + value->value.v_code.code_len + 1;
		}

		case BSON_TYPE_CODEWSCOPE:
		{
			/* total int32 + string(int32 + code + NUL) + scope bytes */
			return (uint64_t) 4 + 4 +
				   value->value.v_codewscope.code_len + 1 +
				   value->value.v_codewscope.scope_len;
		}

		case BSON_TYPE_BINARY:
		{
			/* int32 length + subtype byte + bytes */
			return (uint64_t) 4 + 1 + value->value.v_binary.data_len;
		}

		case BSON_TYPE_REGEX:
		{
			/* two cstrings: regex NUL options NUL. Tolerate NULL safely. */
			size_t rlen = value->value.v_regex.regex
						  ? strlen(value->value.v_regex.regex) : 0;
			size_t olen = value->value.v_regex.options
						  ? strlen(value->value.v_regex.options) : 0;
			return (uint64_t) rlen + 1 + olen + 1;
		}

		case BSON_TYPE_DBPOINTER:
		{
			/* int32 coll-len + coll + NUL + 12-byte oid */
			return (uint64_t) 4 + value->value.v_dbpointer.collection_len + 1 + 12;
		}

		case BSON_TYPE_DOCUMENT:
		case BSON_TYPE_ARRAY:
		{
			/* v_doc.data_len already includes size header + trailing NUL */
			return (uint64_t) value->value.v_doc.data_len;
		}

		default:
			ereport(ERROR,
					(errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
					 errmsg("PgbsonBuilderAppendValue: unsupported bson "
							"value type 0x%02x",
							(unsigned) value->value_type)));
	}
}


/*
 * Emit the wire payload of a bson_value_t at data[*offset] and advance
 * *offset. The type tag and key have already been written by
 * EmitElementHeader. Fixed-width values are copied in a single memcpy;
 * string/blob variants memcpy their content and write the surrounding
 * length / NUL framing directly.
 */
static inline void
EmitBsonValuePayload(uint8_t *data, uint32_t *offset,
					 const bson_value_t *value)
{
	switch ((int) value->value_type)
	{
		case BSON_TYPE_DOUBLE:
		{
			memcpy(data + *offset, &value->value.v_double, 8);
			*offset += 8;
			break;
		}

		case BSON_TYPE_INT32:
		{
			EmitInt32LE(data, offset, value->value.v_int32);
			break;
		}

		case BSON_TYPE_INT64:
		{
			EmitInt64LE(data, offset, value->value.v_int64);
			break;
		}

		case BSON_TYPE_DATE_TIME:
		{
			EmitInt64LE(data, offset, value->value.v_datetime);
			break;
		}

		case BSON_TYPE_BOOL:
		{
			data[(*offset)++] = value->value.v_bool ? 0x01 : 0x00;
			break;
		}

		case BSON_TYPE_NULL:
		case BSON_TYPE_UNDEFINED:
		case BSON_TYPE_MINKEY:
		case BSON_TYPE_MAXKEY:
		{
			/* no payload bytes */
			break;
		}

		case BSON_TYPE_OID:
		{
			memcpy(data + *offset, &value->value.v_oid, 12);
			*offset += 12;
			break;
		}

		case BSON_TYPE_TIMESTAMP:
		{
			/* BSON wire order: increment first, then timestamp (both LE). */
			EmitInt32LE(data, offset, (int32_t) value->value.v_timestamp.increment);
			EmitInt32LE(data, offset, (int32_t) value->value.v_timestamp.timestamp);
			break;
		}

		case BSON_TYPE_DECIMAL128:
		{
			/*
			 * BSON wire format: 16 little-endian bytes — first the low
			 * 64 bits, then the high 64 bits. Write each half through
			 * htole64 so the output is correct regardless of host byte
			 * order.
			 */
			uint64 lo = htole64(value->value.v_decimal128.low);
			uint64 hi = htole64(value->value.v_decimal128.high);
			memcpy(data + *offset, &lo, 8);
			*offset += 8;
			memcpy(data + *offset, &hi, 8);
			*offset += 8;
			break;
		}

		case BSON_TYPE_UTF8:
		{
			uint32_t len = value->value.v_utf8.len;
			EmitInt32LE(data, offset, (int32_t) (len + 1));
			if (len > 0)
			{
				memcpy(data + *offset, value->value.v_utf8.str, len);
				*offset += len;
			}
			data[(*offset)++] = '\0';
			break;
		}

		case BSON_TYPE_SYMBOL:
		{
			uint32_t len = value->value.v_symbol.len;
			EmitInt32LE(data, offset, (int32_t) (len + 1));
			if (len > 0)
			{
				memcpy(data + *offset, value->value.v_symbol.symbol, len);
				*offset += len;
			}
			data[(*offset)++] = '\0';
			break;
		}

		case BSON_TYPE_CODE:
		{
			uint32_t len = value->value.v_code.code_len;
			EmitInt32LE(data, offset, (int32_t) (len + 1));
			if (len > 0)
			{
				memcpy(data + *offset, value->value.v_code.code, len);
				*offset += len;
			}
			data[(*offset)++] = '\0';
			break;
		}

		case BSON_TYPE_CODEWSCOPE:
		{
			uint32_t codeLen = value->value.v_codewscope.code_len;
			uint32_t scopeLen = value->value.v_codewscope.scope_len;
			uint32_t totalLen = (uint32_t) (4 + 4 + codeLen + 1 + scopeLen);

			EmitInt32LE(data, offset, (int32_t) totalLen);
			EmitInt32LE(data, offset, (int32_t) (codeLen + 1));
			if (codeLen > 0)
			{
				memcpy(data + *offset, value->value.v_codewscope.code,
					   codeLen);
				*offset += codeLen;
			}
			data[(*offset)++] = '\0';
			if (scopeLen > 0)
			{
				memcpy(data + *offset, value->value.v_codewscope.scope_data,
					   scopeLen);
				*offset += scopeLen;
			}
			break;
		}

		case BSON_TYPE_BINARY:
		{
			uint32_t len = value->value.v_binary.data_len;
			EmitInt32LE(data, offset, (int32_t) len);
			data[(*offset)++] = (uint8_t) value->value.v_binary.subtype;
			if (len > 0)
			{
				memcpy(data + *offset, value->value.v_binary.data, len);
				*offset += len;
			}
			break;
		}

		case BSON_TYPE_REGEX:
		{
			size_t rlen = value->value.v_regex.regex
						  ? strlen(value->value.v_regex.regex) : 0;
			size_t olen = value->value.v_regex.options
						  ? strlen(value->value.v_regex.options) : 0;
			if (rlen > 0)
			{
				memcpy(data + *offset, value->value.v_regex.regex, rlen);
				*offset += rlen;
			}
			data[(*offset)++] = '\0';
			if (olen > 0)
			{
				memcpy(data + *offset, value->value.v_regex.options, olen);
				*offset += olen;
			}
			data[(*offset)++] = '\0';
			break;
		}

		case BSON_TYPE_DBPOINTER:
		{
			uint32_t collLen = value->value.v_dbpointer.collection_len;
			EmitInt32LE(data, offset, (int32_t) (collLen + 1));
			if (collLen > 0)
			{
				memcpy(data + *offset, value->value.v_dbpointer.collection,
					   collLen);
				*offset += collLen;
			}
			data[(*offset)++] = '\0';
			memcpy(data + *offset, &value->value.v_dbpointer.oid, 12);
			*offset += 12;
			break;
		}

		case BSON_TYPE_DOCUMENT:
		case BSON_TYPE_ARRAY:
		{
			uint32_t len = value->value.v_doc.data_len;
			if (len > 0)
			{
				memcpy(data + *offset, value->value.v_doc.data, len);
				*offset += len;
			}
			break;
		}

		default:
		{
			/* Unreachable — BsonValuePayloadSize would have errored. */
			Assert(false);
			break;
		}
	}
}


/*
 * BSON type tag to append for a given bson_value_t. Most types map 1:1
 * to a single wire byte; we centralise the mapping here so the Append
 * fast-path and the emit path cannot drift.
 */
static inline pgbson_builder_type_tag
BsonTypeTagForValueType(bson_type_t type)
{
	/*
	 * bson_type_t's enum values are defined to equal the BSON wire type
	 * byte, so we can cast directly. Undefined (0x06) is deprecated but
	 * still legal on the wire; we pass it through unchanged.
	 */
	return (pgbson_builder_type_tag) type;
}


/*
 * See header: append a BSON value by borrowed pointer. Scalars go
 * through typed fast paths (no extra op field to dispatch on); everything
 * else falls into a single generic op.
 */
void
PgbsonBuilderAppendValue(pgbson_builder *builder, const char *path,
						 uint32_t pathLength, const bson_value_t *value)
{
	switch ((int) value->value_type)
	{
		case BSON_TYPE_INT32:
		{
			PgbsonBuilderAppendInt32(builder, path, pathLength,
									 value->value.v_int32);
			return;
		}

		case BSON_TYPE_INT64:
		{
			PgbsonBuilderAppendInt64(builder, path, pathLength,
									 value->value.v_int64);
			return;
		}

		case BSON_TYPE_DOUBLE:
		{
			PgbsonBuilderAppendDouble(builder, path, pathLength,
									  value->value.v_double);
			return;
		}

		case BSON_TYPE_BOOL:
		{
			PgbsonBuilderAppendBool(builder, path, pathLength,
									value->value.v_bool);
			return;
		}

		case BSON_TYPE_NULL:
		{
			PgbsonBuilderAppendNull(builder, path, pathLength);
			return;
		}

		case BSON_TYPE_DATE_TIME:
		{
			PgbsonBuilderAppendDateTimeMillis(builder, path, pathLength,
											  value->value.v_datetime);
			return;
		}

		case BSON_TYPE_UTF8:
		{
			PgbsonBuilderAppendUtf8WithLength(builder, path, pathLength,
											  value->value.v_utf8.str,
											  value->value.v_utf8.len);
			return;
		}

		default:
		{
			break;
		}
	}

	/* Generic path: single op carrying the borrowed value pointer. */
	uint64_t payloadSize = BsonValuePayloadSize(value);

	pgbson_builder_op *op = BeginElementOp(builder, OP_BSON_VALUE,
										   BsonTypeTagForValueType(
											   value->value_type),
										   path, pathLength);
	op->v.bsonValue = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + payloadSize);
}


/*
 * See header: append the iterator's current element. The iterator's
 * bson_value_t lives on the caller's stack; we therefore copy the
 * ~40-byte struct into a palloc'd slot so the stored pointer remains
 * valid through Finalize. The variable-length bytes it points into
 * (iter->raw) are the caller's responsibility to keep alive, which is
 * the same contract every other Append* enforces.
 */
void
PgbsonBuilderAppendIter(pgbson_builder *builder, const char *path,
						uint32_t pathLength, const bson_iter_t *iter)
{
	const bson_value_t *stackValue = bson_iter_value((bson_iter_t *) iter);
	if (unlikely(stackValue == NULL))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("PgbsonBuilderAppendIter: iterator is not "
							   "positioned on a valid element")));
	}

	/*
	 * Scalar fast paths avoid any allocation — they only need the
	 * current stack copy long enough to read out the primitive value.
	 */
	switch ((int) stackValue->value_type)
	{
		case BSON_TYPE_INT32:
		case BSON_TYPE_INT64:
		case BSON_TYPE_DOUBLE:
		case BSON_TYPE_BOOL:
		case BSON_TYPE_NULL:
		case BSON_TYPE_DATE_TIME:
		case BSON_TYPE_UTF8:
		{
			PgbsonBuilderAppendValue(builder, path, pathLength, stackValue);
			return;
		}

		default:
		{
			break;
		}
	}

	bson_value_t *copy = (bson_value_t *) palloc(sizeof(bson_value_t));
	*copy = *stackValue;

	PgbsonBuilderAppendValue(builder, path, pathLength, copy);
}


/* --------------------------------------------------------- */
/* Public API: nested documents and arrays                   */
/* --------------------------------------------------------- */

/*
 * Push a new container stack frame after the opening START_DOCUMENT op
 * has been recorded and the enclosing element header has been charged
 * to the parent. Shared by StartDocument/StartArray and their array-
 * variant siblings — the only per-container difference is the initial
 * arrayIndex value, which selects the child's own element-keying mode.
 */
static inline void
PushContainerFrame(pgbson_builder *builder, uint32_t opIndex,
				   uint64_t elementHeaderSize, bool isArray)
{
	/* The element's header (type+key+NUL) already counts toward the parent. */
	AddElementSize(builder, elementHeaderSize);

	EnsureStackCapacity(builder, builder->stackDepth + 1);
	builder->openOpIndex[builder->stackDepth] = opIndex;
	builder->payloadSize[builder->stackDepth] = 0;
	builder->arrayIndex[builder->stackDepth] = isArray ? 0 : ARRAY_INDEX_NONE;
	builder->stackDepth++;
}


/*
 * Open a new sub-document under `path`. Subsequent Append* calls populate
 * it until the matching EndDocument.
 *
 * Two bookkeeping steps happen here:
 *   1. Emit the element header for the sub-document in the parent — the
 *      type byte, key, and key-terminator NUL. The 4-byte child size
 *      header that follows is NOT added to the parent payload yet; it is
 *      accounted for as part of the child's own `childTotalSize` when
 *      EndDocument closes the frame.
 *   2. Push a new open-doc stack frame. We remember the op index of this
 *      START_DOCUMENT op (`openOpIndex[stackDepth]`) so EndDocument can
 *      locate it and patch in the final child size after the payload is
 *      known.
 *
 * Nesting has no hard-coded depth limit — the stack grows on demand via
 * EnsureStackCapacity.
 */
void
PgbsonBuilderStartDocument(pgbson_builder *builder, const char *path,
						   uint32_t pathLength)
{
	uint32_t opIndex = builder->opCount;
	pgbson_builder_op *op = BeginElementOp(builder, OP_START_DOCUMENT,
										   BSON_TYPE_DOCUMENT,
										   path, pathLength);
	op->v.childTotalSize = 0;       /* filled in at EndDocument */

	PushContainerFrame(builder, opIndex,
					   BSON_ELEMENT_HEADER_SIZE(pathLength),
					   false);
}


/*
 * Open a new sub-array under `path`.
 *
 * Wire-level, BSON arrays are ordinary documents whose element keys are
 * the decimal strings "0", "1", "2", ...; the only runtime difference is
 * the type tag on the enclosing element and the key-generation mode
 * stored in the child frame's arrayIndex. Everything else — size
 * tracking, nesting, Finalize emit — reuses the document path verbatim.
 */
void
PgbsonBuilderStartArray(pgbson_builder *builder, const char *path,
						uint32_t pathLength)
{
	uint32_t opIndex = builder->opCount;
	pgbson_builder_op *op = BeginElementOp(builder, OP_START_DOCUMENT,
										   BSON_TYPE_ARRAY,
										   path, pathLength);
	op->v.childTotalSize = 0;       /* filled in at EndArray */

	PushContainerFrame(builder, opIndex,
					   BSON_ELEMENT_HEADER_SIZE(pathLength),
					   true);
}


/*
 * Close the most recently opened container (sub-document or sub-array).
 *
 * Once the child's frame is about to be popped, its total byte size in
 * the final buffer is known: the running payload plus its own 4-byte
 * size header and trailing NUL. That total is:
 *   - written back into the child's START_DOCUMENT op (via the stashed
 *     op index) so the emit pass can produce the correct size header, and
 *   - added to the parent frame's payload so further Append* calls on the
 *     parent keep an accurate running size.
 *
 * A standalone OP_END_DOCUMENT op is also recorded so the emit pass has
 * a place to write the child's trailing NUL in document order without
 * having to re-scan.
 *
 * Errors out via ereport if called with no open container, rather than
 * asserting — the caller's mistake should be observable in release
 * builds, not silently corrupt the output.
 */
static void
CloseContainer(pgbson_builder *builder, bool expectArray)
{
	if (unlikely(builder->stackDepth <= 1))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("PgbsonBuilderEnd{Document,Array} called with "
							   "no open sub-container")));
	}

	uint32_t childIdx = builder->stackDepth - 1;
	bool childIsArray = builder->arrayIndex[childIdx] != ARRAY_INDEX_NONE;
	if (unlikely(childIsArray != expectArray))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("PgbsonBuilderEnd%s called with mismatched open "
							   "container type",
							   expectArray ? "Array" : "Document")));
	}

	uint32_t childPayload = builder->payloadSize[childIdx];

	/*
	 * The child container occupies its 4-byte size header + its element
	 * payload + its trailing NUL in the final buffer. Because every
	 * Append* call clamps each payload to MAX_BSON_DOCUMENT_SIZE - 5,
	 * this addition cannot wrap uint32.
	 */
	uint32_t childTotalSize = childPayload + 4 + 1;

	/* Patch the START_DOCUMENT op so the emit pass can write the size. */
	builder->ops[builder->openOpIndex[childIdx]].v.childTotalSize =
		childTotalSize;

	/* Record the END_DOCUMENT op; it emits the child's trailing NUL. */
	pgbson_builder_op *op = ReserveOp(builder);
	op->kind = OP_END_DOCUMENT;
	op->typeTag = 0;
	op->path = NULL;
	op->pathLength = 0;

	/*
	 * Pop the child frame and charge its full size to the parent. Route
	 * through AddElementSize so the parent payload is overflow-checked
	 * against MAX_BSON_DOCUMENT_SIZE the same way a scalar element would
	 * be.
	 */
	builder->stackDepth--;
	AddElementSize(builder, (uint64_t) childTotalSize);
}


void
PgbsonBuilderEndDocument(pgbson_builder *builder)
{
	CloseContainer(builder, false);
}


void
PgbsonBuilderEndArray(pgbson_builder *builder)
{
	CloseContainer(builder, true);
}


/* --------------------------------------------------------- */
/* Public API: array-element appenders                       */
/* --------------------------------------------------------- */

/*
 * Array-context UTF-8 appender.
 *
 * Same wire layout as PgbsonBuilderAppendUtf8WithLength, but the key is
 * the next decimal-encoded index of the open array frame instead of a
 * caller-supplied path. Implementation delegates to BeginArrayElementOp
 * so the scalar emit arm is shared with the document path.
 */
void
PgbsonBuilderArrayAppendUtf8WithLength(pgbson_builder *builder,
									   const char *value, uint32_t valueLength)
{
	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_UTF8,
												BSON_TYPE_UTF8, &pathLength);
	op->v.utf8.data = value;
	op->v.utf8.length = valueLength;

	/* header + int32(len+1) + bytes + trailing NUL */
	AddElementSize(builder,
				   BSON_ELEMENT_HEADER_SIZE(pathLength) + 4 + valueLength + 1);
}


void
PgbsonBuilderArrayAppendUtf8(pgbson_builder *builder, const char *value)
{
	PgbsonBuilderArrayAppendUtf8WithLength(builder, value,
										   (uint32_t) strlen(value));
}


void
PgbsonBuilderArrayAppendInt32(pgbson_builder *builder, int32_t value)
{
	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_INT32,
												BSON_TYPE_INT32, &pathLength);
	op->v.i32 = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 4);
}


void
PgbsonBuilderArrayAppendInt64(pgbson_builder *builder, int64 value)
{
	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_INT64,
												BSON_TYPE_INT64, &pathLength);
	op->v.i64 = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 8);
}


void
PgbsonBuilderArrayAppendDouble(pgbson_builder *builder, double value)
{
	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_DOUBLE,
												BSON_TYPE_DOUBLE, &pathLength);
	op->v.d = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 8);
}


void
PgbsonBuilderArrayAppendBool(pgbson_builder *builder, bool value)
{
	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_BOOL,
												BSON_TYPE_BOOL, &pathLength);
	op->v.b = value;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 1);
}


void
PgbsonBuilderArrayAppendNull(pgbson_builder *builder)
{
	uint32_t pathLength;
	(void) BeginArrayElementOp(builder, OP_NULL, BSON_TYPE_NULL, &pathLength);
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength));
}


void
PgbsonBuilderArrayAppendDateTime(pgbson_builder *builder, TimestampTz timestamp)
{
	/*
	 * Mirror the TimestampTz -> BSON UTC datetime conversion done by
	 * PgbsonBuilderAppendDateTime so the two code paths stay identical.
	 */
	time_t secondsSinceUnixEpoch = timestamptz_to_time_t(timestamp);
	int64 usecRem = timestamp % USECS_PER_SEC;
	if (usecRem < 0)
	{
		usecRem += USECS_PER_SEC;
		secondsSinceUnixEpoch -= 1;
	}
	Assert(usecRem >= 0 && usecRem < USECS_PER_SEC);
	int64 milliSinceUnixEpoch = ((int64) secondsSinceUnixEpoch) * 1000 +
								(usecRem / 1000);

	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_DATETIME,
												BSON_TYPE_DATE_TIME,
												&pathLength);
	op->v.i64 = milliSinceUnixEpoch;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + 8);
}


void
PgbsonBuilderArrayAppendDocument(pgbson_builder *builder, const pgbson *document)
{
	uint32_t docSize = (uint32_t) VARSIZE_ANY_EXHDR(document);

	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_DOCUMENT,
												BSON_TYPE_DOCUMENT,
												&pathLength);
	op->v.doc.bytes = (const uint8_t *) VARDATA_ANY(document);
	op->v.doc.size = docSize;
	AddElementSize(builder, BSON_ELEMENT_HEADER_SIZE(pathLength) + docSize);
}


/*
 * Open a new sub-document as the next element of the open array.
 * See PgbsonBuilderStartDocument — same mechanism, just with an
 * auto-generated key.
 */
void
PgbsonBuilderArrayStartDocument(pgbson_builder *builder)
{
	uint32_t opIndex = builder->opCount;
	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_START_DOCUMENT,
												BSON_TYPE_DOCUMENT,
												&pathLength);
	op->v.childTotalSize = 0;

	PushContainerFrame(builder, opIndex,
					   BSON_ELEMENT_HEADER_SIZE(pathLength),
					   false);
}


/*
 * Open a new sub-array as the next element of the open array.
 */
void
PgbsonBuilderArrayStartArray(pgbson_builder *builder)
{
	uint32_t opIndex = builder->opCount;
	uint32_t pathLength;
	pgbson_builder_op *op = BeginArrayElementOp(builder, OP_START_DOCUMENT,
												BSON_TYPE_ARRAY, &pathLength);
	op->v.childTotalSize = 0;

	PushContainerFrame(builder, opIndex,
					   BSON_ELEMENT_HEADER_SIZE(pathLength),
					   true);
}


/* --------------------------------------------------------- */
/* Public API: inline document concatenation                 */
/* --------------------------------------------------------- */

/*
 * Splice the inner elements of a foreign BSON document into the currently
 * open document, at the same level.
 *
 * Wire-level, a BSON document is `<int32 size><elements...><0x00>`. The
 * "inner" bytes are everything between those framing markers, so copying
 * them verbatim into our output appends each foreign element as if it had
 * been produced by an individual Append* call here — no per-element
 * parsing needed. This matches the semantics of the libbson-based
 * `PgbsonWriterConcatBytes` so callers can migrate without behaviour
 * changes.
 *
 * The input is validated lightly:
 *   - minimum length of 5 (smallest empty BSON doc is { }: `05 00 00 00 00`),
 *   - the little-endian int32 at offset 0 must equal `bsonBytesLength`,
 *   - the trailing byte must be NUL.
 * Anything else would mean the caller passed in corrupted BSON and
 * producing output from it would yield a malformed document downstream.
 *
 * The enclosing frame must be a document; splicing raw element bytes
 * into an array would bypass the per-element index counter and produce
 * a document with non-numeric array keys.
 */
void
PgbsonBuilderConcatBytes(pgbson_builder *builder, const uint8_t *bsonBytes,
						 uint32_t bsonBytesLength)
{
	EnsureTopIsDocument(builder);

	if (unlikely(bsonBytesLength < 5))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("PgbsonBuilderConcatBytes: input is shorter "
							   "than the minimum BSON document size")));
	}

	/* Verify the size header and trailing NUL so we never produce broken BSON. */
	uint32_t declaredSize;
	memcpy(&declaredSize, bsonBytes, 4);
	declaredSize = le32toh(declaredSize);
	if (unlikely(declaredSize != bsonBytesLength ||
				 bsonBytes[bsonBytesLength - 1] != 0x00))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("PgbsonBuilderConcatBytes: input is not a "
							   "well-formed BSON document")));
	}

	uint32_t innerSize = bsonBytesLength - 5; /* strip size header + NUL */

	/* Nothing to splice for an empty document — skip op record entirely. */
	if (innerSize == 0)
	{
		return;
	}

	pgbson_builder_op *op = ReserveOp(builder);
	op->kind = OP_CONCAT_BYTES;
	op->typeTag = 0;
	op->path = NULL;
	op->pathLength = 0;
	op->v.doc.bytes = bsonBytes + 4;    /* skip the size header */
	op->v.doc.size = innerSize;

	AddElementSize(builder, (uint64_t) innerSize);
}


void
PgbsonBuilderConcat(pgbson_builder *builder, const pgbson *document)
{
	PgbsonBuilderConcatBytes(builder,
							 (const uint8_t *) VARDATA_ANY(document),
							 (uint32_t) VARSIZE_ANY_EXHDR(document));
}


/* --------------------------------------------------------- */
/* Public API: finalize                                      */
/* --------------------------------------------------------- */

/*
 * Materialise the recorded op log into a freshly-allocated pgbson.
 *
 * Because every Append* call maintained the running root-document payload
 * size incrementally, the final byte size is known without re-walking
 * the ops. We therefore:
 *   1. palloc exactly VARHDRSZ + totalSize once.
 *   2. Write the root document size header.
 *   3. Walk the op log in order, dispatching on op->kind to emit each
 *      element's bytes directly into the output buffer. Sub-document
 *      size headers are taken from the childTotalSize field that
 *      EndDocument patched into the matching START_DOCUMENT op.
 *   4. Write the root trailing NUL.
 *
 * This is the core performance win over the standard pgbson_writer: one
 * palloc, one linear pass, no intermediate bson_t, no repalloc-on-grow,
 * and no final bson_t -> pgbson memcpy.
 *
 * Errors out if the caller did not balance Start/End pairs — continuing
 * would produce a BSON document missing size headers or NUL terminators.
 */
pgbson *
PgbsonBuilderFinalize(pgbson_builder *builder)
{
	if (unlikely(builder->stackDepth != 1))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("PgbsonBuilderFinalize called with %u "
							   "unclosed sub-document(s)",
							   builder->stackDepth - 1)));
	}

	uint32_t totalSize = builder->payloadSize[0] + 4 + 1;

	pgbson *result = (pgbson *) palloc(VARHDRSZ + totalSize);
	SET_VARSIZE(result, VARHDRSZ + totalSize);

	uint8_t *data = (uint8_t *) VARDATA(result);
	uint32_t offset = 0;

	/* Root document size header. */
	EmitInt32LE(data, &offset, (int32_t) totalSize);

	for (uint32_t i = 0; i < builder->opCount; i++)
	{
		const pgbson_builder_op *op = &builder->ops[i];

		switch ((pgbson_builder_op_kind_t) op->kind)
		{
			case OP_UTF8:
			{
				EmitElementHeader(data, &offset, op);
				EmitInt32LE(data, &offset, (int32_t) (op->v.utf8.length + 1));
				if (op->v.utf8.length > 0)
				{
					memcpy(data + offset, op->v.utf8.data, op->v.utf8.length);
					offset += op->v.utf8.length;
				}
				data[offset++] = '\0';
				break;
			}

			case OP_INT32:
			{
				EmitElementHeader(data, &offset, op);
				EmitInt32LE(data, &offset, op->v.i32);
				break;
			}

			case OP_INT64:
			case OP_DATETIME:
			{
				EmitElementHeader(data, &offset, op);
				EmitInt64LE(data, &offset, op->v.i64);
				break;
			}

			case OP_DOUBLE:
			{
				EmitElementHeader(data, &offset, op);
				memcpy(data + offset, &op->v.d, 8);
				offset += 8;
				break;
			}

			case OP_BOOL:
			{
				EmitElementHeader(data, &offset, op);
				data[offset++] = op->v.b ? 0x01 : 0x00;
				break;
			}

			case OP_NULL:
			{
				EmitElementHeader(data, &offset, op);
				break;
			}

			case OP_DOCUMENT:
			{
				EmitElementHeader(data, &offset, op);
				memcpy(data + offset, op->v.doc.bytes, op->v.doc.size);
				offset += op->v.doc.size;
				break;
			}

			case OP_CONCAT_BYTES:
			{
				/*
				 * Raw inner-element splice: no element header, no type
				 * tag, no key. The bytes have already been trimmed to
				 * exclude the foreign document's size header and
				 * trailing NUL, so a single memcpy appends them at the
				 * current offset as if they were produced by a sequence
				 * of Append* calls here.
				 */
				memcpy(data + offset, op->v.doc.bytes, op->v.doc.size);
				offset += op->v.doc.size;
				break;
			}

			case OP_BSON_VALUE:
			{
				EmitElementHeader(data, &offset, op);
				EmitBsonValuePayload(data, &offset, op->v.bsonValue);
				break;
			}

			case OP_START_DOCUMENT:
			{
				EmitElementHeader(data, &offset, op);
				EmitInt32LE(data, &offset, (int32_t) op->v.childTotalSize);
				break;
			}

			case OP_END_DOCUMENT:
			{
				data[offset++] = '\0';
				break;
			}
		}
	}

	/* Trailing NUL terminator for the root document. */
	data[offset++] = '\0';

	Assert(offset == totalSize);

	return result;
}
