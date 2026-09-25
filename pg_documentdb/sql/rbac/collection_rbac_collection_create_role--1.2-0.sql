/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 *-------------------------------------------------------------------------
 */

/*
 * Writing to a namespace that does not exist yet has to bring that namespace
 * into existence, which needs rights the role holding "insert" does not carry.
 * This group role is where those rights are collected, and the creation runs
 * as it.
 *
 * It is deliberately not the role that ends up owning what it creates. What it
 * creates is handed to the collection owner role, which carries none of these
 * rights, so holding a created table gives nothing back.
 *
 * Membership in it confers no access to any collection's data, and which
 * namespaces a member may actually create is still decided by the collection
 * privileges the role was granted, which is checked before the creation path
 * is entered.
 */
DO
$do$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
				   WHERE rolname = 'documentdb_rbac_api_collection_create_role') THEN
		CREATE ROLE documentdb_rbac_api_collection_create_role NOLOGIN;
	END IF;
END
$do$;

/*
 * Creating a collection also reaches the command surface, so this role
 * composes the access role rather than restating its grants.
 */
GRANT documentdb_rbac_api_access_role
	TO documentdb_rbac_api_collection_create_role;

/*
 * What it creates is handed to the owner role, and handing a table on needs
 * membership in the role it is handed to. The later steps of the creation act
 * on the table after that, which needs the rights of its owner, and membership
 * supplies those too.
 */
GRANT documentdb_rbac_api_collection_owner_role
	TO documentdb_rbac_api_collection_create_role;

/*
 * The rights a namespace write needs in order to bring that namespace into
 * existence. These are the rights the role holding "insert" does not carry,
 * collected here so that the creation runs with them and neither the caller
 * nor the role left owning the result holds them.
 */
GRANT USAGE, CREATE ON SCHEMA __API_DATA_SCHEMA__
	TO documentdb_rbac_api_collection_create_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON __API_CATALOG_SCHEMA__.collections
	TO documentdb_rbac_api_collection_create_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON __API_CATALOG_SCHEMA__.collection_indexes
	TO documentdb_rbac_api_collection_create_role;

GRANT USAGE ON SEQUENCE __API_CATALOG_SCHEMA__.collections_collection_id_seq
	TO documentdb_rbac_api_collection_create_role;

GRANT USAGE ON SEQUENCE __API_CATALOG_SCHEMA__.collection_indexes_index_id_seq
	TO documentdb_rbac_api_collection_create_role;

/*
 * The administrator holds it with the admin option so that it can be handed
 * on to the roles that are allowed to create collections, and so that the
 * administrator remains in control of what the creation path can reach.
 */
GRANT documentdb_rbac_api_collection_create_role
	TO __API_ADMIN_ROLE__ WITH ADMIN OPTION;
