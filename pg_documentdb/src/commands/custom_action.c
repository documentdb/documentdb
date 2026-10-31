/* Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 */

#include <postgres.h>
#include <miscadmin.h>
#include <utils/acl.h>
#include <utils/memutils.h>

#include "commands/commands_common.h"
#include "commands/custom_action.h"
#include "commands/parse_error.h"
#include "metadata/metadata_cache.h"
#include "utils/string_view.h"

#define MAX_CUSTOM_ACTIONS 20

typedef struct CustomAction
{
	const char *name;
	CustomActionFunction function;
} CustomAction;

typedef struct CustomActionArgs
{
	const char *actionName;
	StringView databaseName;
} CustomActionArgs;

static CustomAction CustomActions[MAX_CUSTOM_ACTIONS];
static int CustomActionCount = 0;

static CustomActionFunction FindCustomAction(const char *actionName);
static void ParseCustomActionSpec(pgbson *spec, CustomActionArgs *args);

PG_FUNCTION_INFO_V1(documentdb_custom_action);

/*
 * Backends inherit an immutable catalog from shared preload initialization.
 */
void
RegisterCustomAction(const char *actionName, CustomActionFunction function)
{
	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"Custom actions can only be registered during shared_preload_libraries")));
	}

	if (actionName == NULL || actionName[0] == '\0' || function == NULL)
	{
		ereport(ERROR, (errmsg("Invalid custom action definition")));
	}

	if (FindCustomAction(actionName) != NULL)
	{
		ereport(ERROR, (errmsg("Custom action \"%s\" is already registered",
							   actionName)));
	}

	if (CustomActionCount >= MAX_CUSTOM_ACTIONS)
	{
		ereport(ERROR, (errmsg("Cannot register more than %d custom actions",
							   MAX_CUSTOM_ACTIONS)));
	}

	CustomAction *action = &CustomActions[CustomActionCount];
	action->name = MemoryContextStrdup(TopMemoryContext, actionName);
	action->function = function;
	CustomActionCount++;
}


Datum
documentdb_custom_action(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg("customAction requires a command specification")));
	}

	if (!is_member_of_role(GetUserId(), get_role_oid(ApiAdminRole, false)))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNAUTHORIZED),
						errmsg("not authorized to execute customAction")));
	}

	pgbson *spec = PG_GETARG_PGBSON(0);
	CustomActionArgs args = { 0 };
	ParseCustomActionSpec(spec, &args);

	CustomActionFunction function = FindCustomAction(args.actionName);
	if (function == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTED),
						errmsg("customAction is not supported")));
	}

	pgbson *response = function(spec);
	if (response == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg("customAction returned no response")));
	}

	PG_RETURN_POINTER(response);
}


static CustomActionFunction
FindCustomAction(const char *actionName)
{
	for (int i = 0; i < CustomActionCount; i++)
	{
		CustomAction *action = &CustomActions[i];
		if (strcmp(action->name, actionName) == 0)
		{
			return action->function;
		}
	}

	return NULL;
}


static void
ParseCustomActionSpec(pgbson *spec, CustomActionArgs *args)
{
	bson_iter_t iter;
	PgbsonInitIterator(spec, &iter);
	while (bson_iter_next(&iter))
	{
		const char *key = bson_iter_key(&iter);
		if (strcmp(key, "customAction") == 0)
		{
			EnsureTopLevelFieldType(key, &iter, BSON_TYPE_UTF8);
			if (args->actionName != NULL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("customAction must be specified only once")));
			}

			uint32_t length;
			args->actionName = bson_iter_utf8(&iter, &length);
			if (memchr(args->actionName, '\0', length) != NULL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("customAction must not contain null bytes")));
			}
		}
		else if (strcmp(key, "$db") == 0)
		{
			EnsureTopLevelFieldType(key, &iter, BSON_TYPE_UTF8);
			uint32_t length;
			const char *databaseName = bson_iter_utf8(&iter, &length);
			ValidateNamespaceStringForEmbeddedNull(databaseName, length);
			if (args->databaseName.string != NULL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
								errmsg("$db must be specified only once")));
			}

			args->databaseName = CreateStringViewFromStringWithLength(databaseName,
																	  length);
		}
	}

	if (args->actionName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_FAILEDTOPARSE),
						errmsg("customAction is required")));
	}

	if (args->databaseName.string == NULL ||
		!StringViewEqualsCString(&args->databaseName, "admin"))
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
						errmsg(
							"customAction may only be run against the admin database")));
	}
}
