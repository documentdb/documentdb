-- Creating new schemas
CREATE SCHEMA documentdb_api_v2;
REVOKE ALL ON SCHEMA documentdb_api_v2 FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA documentdb_api_v2 REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
GRANT USAGE ON SCHEMA documentdb_api_v2 to __API_ADMIN_ROLE_V2__, __API_READONLY_ROLE__, __API_BG_WORKER_ROLE__;

CREATE SCHEMA documentdb_api_internal_admin;
GRANT USAGE ON SCHEMA documentdb_api_internal_admin to __API_ADMIN_ROLE_V2__;

CREATE SCHEMA documentdb_api_internal_readwrite;
GRANT USAGE ON SCHEMA documentdb_api_internal_readwrite to __API_ADMIN_ROLE_V2__;

CREATE SCHEMA documentdb_api_internal_readonly;
GRANT USAGE ON SCHEMA documentdb_api_internal_readonly to __API_ADMIN_ROLE_V2__, __API_READONLY_ROLE__;

CREATE SCHEMA documentdb_api_internal_bgworker;
GRANT USAGE ON SCHEMA documentdb_api_internal_bgworker to __API_BG_WORKER_ROLE__;