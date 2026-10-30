/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/opclass/bson_subattr_support.c
 *
 * Planner support for PostgreSQL's SupportRequestSubattr: tells the
 * server which parts of a document update_bson_document may change, and
 * which part bson_extract_vector (vector indexes and their predicates)
 * reads, so that an UPDATE that cannot affect a vector index need not
 * evaluate it.
 *
 * The answers only let the server skip work it would otherwise do to
 * decide whether an update is heap-only (HOT); they never change that
 * decision.  But a wrong answer would leave an index without an entry for
 * a document, so every answer here must hold for every document, and
 * anything not understood is declined (NULL).
 *
 * Paths are dotted paths split into keys.  A numeric key may also name an
 * array element; the server treats any key that reads as an integer as
 * possibly every array position, so keys are reported as they are.
 *
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <nodes/supportnodes.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <optimizer/optimizer.h>
#include <utils/builtins.h>
#include <catalog/pg_type.h>

#include "io/bson_core.h"
#include "io/bsonvalue_utils.h"
#include "io/pgbsonelement.h"
#include "metadata/metadata_cache.h"
#include "update/bson_update.h"

PG_FUNCTION_INFO_V1(bson_subattr_support);

#ifdef DOCUMENTDB_HAVE_SUBATTR_SUPPORT

static SubattrPathElem *
MakeKeyElem(const char *key, int length)
{
	SubattrPathElem *elem = palloc0(sizeof(SubattrPathElem));
	elem->kind = SUBATTR_ELEM_KEY;
	elem->key = pnstrdup(key, length);
	return elem;
}


/*
 * Split a dotted path into keys, stopping before the first positional
 * component ("$", "$[]" or "$[<identifier>]"): what follows depends on the
 * document, so the path then names everything under its prefix.  Returns
 * false for a path that is not valid (an empty component), which the update
 * or query would reject at run time.
 */
static bool
DottedPathToKeys(const char *path, int length, List **keys)
{
	List *result = NIL;
	int start = 0;

	if (length == 0)
	{
		return false;
	}

	for (int i = 0; i <= length; i++)
	{
		if (i < length && path[i] != '.')
		{
			continue;
		}

		if (i == start)
		{
			return false;
		}

		if (path[start] == '$')
		{
			break;
		}

		result = lappend(result, MakeKeyElem(path + start, i - start));
		start = i + 1;
	}

	*keys = result;
	return true;
}


static bool
ContainsParamWalker(Node *node, void *context)
{
	if (node == NULL)
	{
		return false;
	}
	if (IsA(node, Param))
	{
		return true;
	}
	return expression_tree_walker(node, ContainsParamWalker, context);
}


/*
 * The bson value of an argument that is a constant, or an immutable
 * expression over constants (the implicit bytea-to-bson cast of a query
 * parameter, for example).  Returns NULL if it is neither, or is null.
 */
static pgbson *
GetConstantBsonArg(Node *arg)
{
	Node *node = arg;

	if (node == NULL)
	{
		return NULL;
	}

	if (!IsA(node, Const))
	{
		if (exprType(node) != BsonTypeId() ||
			contain_var_clause(node) ||
			contain_mutable_functions(node) ||
			ContainsParamWalker(node, NULL))
		{
			return NULL;
		}

		node = (Node *) evaluate_expr((Expr *) node, BsonTypeId(), -1,
									  InvalidOid);
		if (!IsA(node, Const))
		{
			return NULL;
		}
	}

	Const *constant = (Const *) node;
	if (constant->constisnull ||
		(constant->consttype != BsonTypeId() &&
		 constant->consttype != BsonQueryTypeId()))
	{
		return NULL;
	}

	return DatumGetPgBson(constant->constvalue);
}


/*
 * SUBATTR_READ for bson_extract_vector(document, 'path'::text): the value at
 * the path.  It finds the path with bson_iter_find_descendant, which takes
 * each component as a key (an array's keys are its positions) and does not
 * look through arrays the way a query does, so the path itself is all it
 * reads.
 *
 * bson_validate_geometry and bson_validate_geography (2d and 2dsphere
 * indexes) are not answered: they return the whole document, not the
 * value at the path.
 */
static bool
ReadOfVectorPath(SupportRequestSubattr *req)
{
	Node *pathArg = lsecond(req->args);
	List *keys;

	if (!IsA(pathArg, Const) || ((Const *) pathArg)->constisnull ||
		((Const *) pathArg)->consttype != TEXTOID)
	{
		return false;
	}

	text *pathText = DatumGetTextPP(((Const *) pathArg)->constvalue);
	if (!DottedPathToKeys(VARDATA_ANY(pathText), VARSIZE_ANY_EXHDR(pathText),
						  &keys))
	{
		return false;
	}

	req->source = 0;
	req->paths = list_make1(keys);
	req->subvalue = false;
	return true;
}


/*
 * Update operators whose value is { "<path>": <argument>, ... } and which
 * change the document only at or under each path.  $rename also changes
 * the path its argument names.  Other operators, including those
 * registered by extensions, are not understood.
 */
static const char *PathUpdateOperators[] = {
	"$set", "$inc", "$min", "$max", "$unset", "$push", "$pop", "$rename",
	"$setOnInsert", "$pullAll", "$addToSet", "$mul", "$bit", "$currentDate",
	"$pull"
};


/*
 * SUBATTR_MODIFY for update_bson_document(document, updateSpec, ...): the
 * paths an operator-style update spec may change.  Replacement documents
 * and aggregation pipeline updates may change anything, and are declined.
 */
static bool
ModifyOfUpdateSpec(SupportRequestSubattr *req)
{
	pgbson *wrappedSpec = GetConstantBsonArg(lsecond(req->args));
	pgbsonelement specElement;
	bson_iter_t opIter;
	List *paths = NIL;

	if (wrappedSpec == NULL)
	{
		return false;
	}

	/* update_bson_document takes the spec as { "": <spec> } */
	if (!TryGetSinglePgbsonElementFromPgbson(wrappedSpec, &specElement) ||
		specElement.bsonValue.value_type != BSON_TYPE_DOCUMENT ||
		DetermineUpdateType(&specElement.bsonValue) != UpdateType_Operator)
	{
		return false;
	}

	BsonValueInitIterator(&specElement.bsonValue, &opIter);
	while (bson_iter_next(&opIter))
	{
		const char *op = bson_iter_key(&opIter);
		bool known = false;
		bson_iter_t pathIter;

		for (size_t i = 0; i < lengthof(PathUpdateOperators); i++)
		{
			if (strcmp(op, PathUpdateOperators[i]) == 0)
			{
				known = true;
				break;
			}
		}

		if (!known || !BSON_ITER_HOLDS_DOCUMENT(&opIter) ||
			!bson_iter_recurse(&opIter, &pathIter))
		{
			return false;
		}

		while (bson_iter_next(&pathIter))
		{
			List *keys;
			StringView path = bson_iter_key_string_view(&pathIter);

			if (!DottedPathToKeys(path.string, path.length, &keys))
			{
				return false;
			}
			paths = lappend(paths, keys);

			if (strcmp(op, "$rename") == 0)
			{
				uint32_t targetLength;
				const char *target;

				if (!BSON_ITER_HOLDS_UTF8(&pathIter))
				{
					return false;
				}

				target = bson_iter_utf8(&pathIter, &targetLength);
				if (!DottedPathToKeys(target, targetLength, &keys))
				{
					return false;
				}
				paths = lappend(paths, keys);
			}
		}
	}

	if (paths == NIL)
	{
		return false;
	}

	req->source = 0;
	req->paths = paths;
	return true;
}


#endif


/*
 * bson_subattr_support: the support function of update_bson_document and
 * bson_extract_vector.  It answers only SupportRequestSubattr, and only on
 * servers that have it.
 */
Datum
bson_subattr_support(PG_FUNCTION_ARGS)
{
#ifdef DOCUMENTDB_HAVE_SUBATTR_SUPPORT
	Node *rawRequest = (Node *) PG_GETARG_POINTER(0);

	if (IsA(rawRequest, SupportRequestSubattr))
	{
		SupportRequestSubattr *req = (SupportRequestSubattr *) rawRequest;
		bool answered = false;

		if (req->kind == SUBATTR_MODIFY && list_length(req->args) >= 2)
		{
			answered = ModifyOfUpdateSpec(req);
		}
		else if (req->kind == SUBATTR_READ && list_length(req->args) == 2 &&
				 req->funcid == ApiCatalogBsonExtractVectorFunctionId())
		{
			answered = ReadOfVectorPath(req);
		}

		if (answered)
		{
			PG_RETURN_POINTER(req);
		}
	}
#endif

	PG_RETURN_POINTER(NULL);
}
