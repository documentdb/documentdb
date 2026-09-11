/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 *-------------------------------------------------------------------------
 */

/*
 * These roles separate access to the command surface from native table
 * privileges. The read-write-any-database role composes both baseline roles
 * because write operations can also require reads.
 */
DO
$do$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
				   WHERE rolname = 'documentdb_rbac_api_access_role') THEN
		CREATE ROLE documentdb_rbac_api_access_role NOLOGIN;
	END IF;

	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
				   WHERE rolname = 'documentdb_rbac_baseline_read_role') THEN
		CREATE ROLE documentdb_rbac_baseline_read_role NOLOGIN;
	END IF;

	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
				   WHERE rolname = 'documentdb_rbac_baseline_write_role') THEN
		CREATE ROLE documentdb_rbac_baseline_write_role NOLOGIN;
	END IF;

	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
				   WHERE rolname = 'documentdb_rbac_readwrite_anydb_role') THEN
		CREATE ROLE documentdb_rbac_readwrite_anydb_role NOLOGIN;
	END IF;
END
$do$;

GRANT USAGE ON SCHEMA
		__API_SCHEMA__,
		__API_SCHEMA_V2__,
		__API_SCHEMA_INTERNAL__,
		__API_SCHEMA_INTERNAL_V2__,
		__API_CATALOG_SCHEMA__,
		__API_CATALOG_SCHEMA_V2__,
		__CORE_SCHEMA_V2__,
		__API_DATA_SCHEMA__
	TO documentdb_rbac_api_access_role,
	   documentdb_rbac_baseline_read_role,
	   documentdb_rbac_baseline_write_role;

GRANT SELECT ON ALL TABLES IN SCHEMA __API_DATA_SCHEMA__
	TO documentdb_rbac_baseline_read_role;

GRANT SELECT,INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA __API_DATA_SCHEMA__
	TO documentdb_rbac_baseline_write_role;

GRANT documentdb_rbac_api_access_role,
	  documentdb_rbac_baseline_read_role,
	  documentdb_rbac_baseline_write_role
	TO documentdb_rbac_readwrite_anydb_role;

GRANT documentdb_rbac_readwrite_anydb_role,
	  documentdb_rbac_api_access_role,
	  documentdb_rbac_baseline_read_role,
	  documentdb_rbac_baseline_write_role
	TO __API_ADMIN_ROLE__ WITH ADMIN OPTION;
