/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/authorization/test_authorization.c
 *
 * Example/test code for authorization privilege extraction
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "fmgr.h"
#include "authorization.h"
#include "io/bson_core.h"

/*
 * Example test function that demonstrates how to use the privilege extraction
 *
 * Usage:
 *   SELECT documentdb_test_privilege_extraction('{ "find": "users", "$db": "test" }');
 */
PG_FUNCTION_INFO_V1(documentdb_test_privilege_extraction);

Datum
documentdb_test_privilege_extraction(PG_FUNCTION_ARGS)
{
	pgbson *command_spec;
	ResourcePrivilegesSet *privilege_set;
	StringInfoData result;
	int i;

	if (PG_ARGISNULL(0))
	{
		PG_RETURN_NULL();
	}

	command_spec = PG_GETARG_PGBSON(0);

	/* Extract privileges */
	privilege_set = get_required_resource_privileges_for_cmd(command_spec);

	if (privilege_set == NULL)
	{
		PG_RETURN_TEXT_P(cstring_to_text(
							 "Cannot determine privileges statically for this command"));
	}

	/* Build result string */
	initStringInfo(&result);
	appendStringInfo(&result, "Required privileges:\n");

	for (i = 0; i < privilege_set->count; i++)
	{
		ResourcePrivileges *item = privilege_set->items[i];
		int j;

		appendStringInfo(&result, "  Resource: db=%s, collection=%s\n",
						 item->resource.database,
						 item->resource.collection[0] ? item->resource.collection : "*");

		appendStringInfo(&result, "  Privileges: ");

		/* List all privileges in the set */
		bool first = true;
		for (j = 0; j < PRIV_MAX; j++)
		{
			if (privilege_set_has(&item->privileges, j))
			{
				const char *priv_name = privilege_action_to_string(j);
				if (priv_name != NULL)
				{
					if (!first)
					{
						appendStringInfo(&result, ", ");
					}
					appendStringInfo(&result, "%s", priv_name);
					first = false;
				}
			}
		}

		appendStringInfo(&result, "\n");
	}

	/* Clean up */
	resource_privileges_set_free(privilege_set);

	PG_RETURN_TEXT_P(cstring_to_text(result.data));
}
