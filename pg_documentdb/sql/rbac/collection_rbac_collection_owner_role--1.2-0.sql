/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 *-------------------------------------------------------------------------
 */

/*
 * A namespace brought into existence by a write is owned by this group role.
 *
 * It is deliberately minimal, and holds nothing beyond what owning those
 * tables needs. It cannot reach the catalogs that record collections, indexes
 * or privileges, and confers no access to any collection's data. The rights
 * the creation itself needs are held by the collection create role instead, so
 * a role that reaches this one by owning what was created gains none of them.
 *
 * Like the other roles here it is a group role and carries NOLOGIN. Nothing
 * authenticates as it.
 */
DO
$do$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
				   WHERE rolname = 'documentdb_rbac_api_collection_owner_role') THEN
		CREATE ROLE documentdb_rbac_api_collection_owner_role NOLOGIN;
	END IF;
END
$do$;

/*
 * Reaching a table it owns needs the schema that table lives in. CREATE is
 * required as well, and not because anything creates a table under this role:
 * handing a table to a role is only allowed when that role could have created
 * it there, so the handoff performed at the end of the creation path fails
 * without it.
 */
GRANT USAGE, CREATE ON SCHEMA __API_DATA_SCHEMA__
	TO documentdb_rbac_api_collection_owner_role;

/*
 * The administrator holds it with the admin option so that it remains in
 * control of what this role comes to own.
 */
GRANT documentdb_rbac_api_collection_owner_role
	TO __API_ADMIN_ROLE__ WITH ADMIN OPTION;
