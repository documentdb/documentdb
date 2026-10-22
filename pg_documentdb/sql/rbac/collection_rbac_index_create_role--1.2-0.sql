/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * Licensed under the MIT License.
 * SPDX-License-Identifier: MIT
 *
 *-------------------------------------------------------------------------
 */

/*
 * Privileged index creation is entered through a restricted security-definer
 * function. This role is the only non-administrator role allowed to invoke
 * that function, keeping collection creation and index creation as separate
 * privilege boundaries.
 */
DO
$do$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
				   WHERE rolname = 'documentdb_rbac_api_index_create_role') THEN
		CREATE ROLE documentdb_rbac_api_index_create_role NOLOGIN;
	END IF;
END
$do$;

GRANT documentdb_rbac_api_access_role
	TO documentdb_rbac_api_index_create_role;

/*
 * Index creation alters relations owned by the collection owner role,
 * including setting statistics targets after creating unique indexes.
 */
GRANT documentdb_rbac_api_collection_owner_role
	TO documentdb_rbac_api_index_create_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON __API_CATALOG_SCHEMA__.collection_indexes
	TO documentdb_rbac_api_index_create_role;

GRANT USAGE ON SEQUENCE __API_CATALOG_SCHEMA__.collection_indexes_index_id_seq
	TO documentdb_rbac_api_index_create_role;

GRANT documentdb_rbac_api_index_create_role
	TO __API_ADMIN_ROLE__;
