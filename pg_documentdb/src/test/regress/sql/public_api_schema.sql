-- show all functions, procedures, aggregates and window aggregates exported in documentdb_api.
\df documentdb_api.*

\df documentdb_api_catalog.*

\df documentdb_api_internal.*

\df documentdb_data.*

-- Access methods + Operator families
\dA *documentdb*

\dAc *documentdb*

\dAf *documentdb*

\dX *documentdb*

-- This is last (Tables/indexes)
\d documentdb_api.*

\d documentdb_api_internal.*

\d documentdb_api_catalog.*

\d documentdb_data.*

-- show all functions, procedures, aggregates and window aggregates in documentdb_api_v2.
\df documentdb_api_v2.*

-- show all functions, procedures, aggregates and window aggregates in documentdb_api_internal_readonly.
\df documentdb_api_internal_readonly.*

-- show all functions, procedures, aggregates and window aggregates in documentdb_api_internal_readwrite.
\df documentdb_api_internal_readwrite.*

-- show all functions, procedures, aggregates and window aggregates in documentdb_api_internal_admin.
\df documentdb_api_internal_admin.*

-- show all functions, procedures, aggregates and window aggregates in documentdb_api_internal_bgworker.
\df documentdb_api_internal_bgworker.*

-- show roles and privileges for v2 schema, below tests intentionally obfuscate role privileges by replacing superuser role names with 'root' to make it easier to test and assert roles for different environments where superuser role names may vary.
SELECT n.nspname as schema, proname, regexp_replace(proacl::text, pg_get_userbyid(p.proowner), 'root', 'g') AS proacl FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'documentdb_api_v2' ORDER BY n.nspname, proname;
SELECT n.nspname as schema, proname, regexp_replace(proacl::text, pg_get_userbyid(p.proowner), 'root', 'g') AS proacl FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'documentdb_api_internal_readonly' ORDER BY n.nspname, proname;
SELECT n.nspname as schema, proname, regexp_replace(proacl::text, pg_get_userbyid(p.proowner), 'root', 'g') AS proacl FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'documentdb_api_internal_readwrite' ORDER BY n.nspname, proname;
SELECT n.nspname as schema, proname, regexp_replace(proacl::text, pg_get_userbyid(p.proowner), 'root', 'g') AS proacl FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'documentdb_api_internal_admin' ORDER BY n.nspname, proname;
SELECT n.nspname as schema, proname, regexp_replace(proacl::text, pg_get_userbyid(p.proowner), 'root', 'g') AS proacl FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'documentdb_api_internal_bgworker' ORDER BY n.nspname, proname;
