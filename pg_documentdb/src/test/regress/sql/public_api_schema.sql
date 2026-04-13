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

-- show roles and privileges per schema using has_function_privilege
SELECT n.nspname AS schema, proname,
       has_function_privilege('documentdb_readonly_role', p.oid, 'EXECUTE') AS readonly_role_has_exec,
       has_function_privilege('documentdb_readwrite_role', p.oid, 'EXECUTE') AS readwrite_role_has_exec,
       has_function_privilege('documentdb_admin_role', p.oid, 'EXECUTE') AS admin_role_has_exec,
       has_function_privilege('documentdb_api_find_role', p.oid, 'EXECUTE') AS find_role_has_exec,
       has_function_privilege('documentdb_api_insert_role', p.oid, 'EXECUTE') AS insert_role_has_exec,
       has_function_privilege('documentdb_api_update_role', p.oid, 'EXECUTE') AS update_role_has_exec,
       has_function_privilege('documentdb_api_remove_role', p.oid, 'EXECUTE') AS remove_role_has_exec
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'documentdb_api_v2' ORDER BY n.nspname, proname;

-- For internal schemas, check schema USAGE privileges per role (functions use default PUBLIC ACL,
-- so access is controlled at the schema level).
SELECT n.nspname AS schema, proname,
       has_schema_privilege('documentdb_readonly_role', n.nspname, 'USAGE') AS readonly_role_has_exec,
       has_schema_privilege('documentdb_readwrite_role', n.nspname, 'USAGE') AS readwrite_role_has_exec,
       has_schema_privilege('documentdb_admin_role', n.nspname, 'USAGE') AS admin_role_has_exec,
       has_schema_privilege('documentdb_api_find_role', n.nspname, 'USAGE') AS find_role_has_exec,
       has_schema_privilege('documentdb_api_insert_role', n.nspname, 'USAGE') AS insert_role_has_exec,
       has_schema_privilege('documentdb_api_update_role', n.nspname, 'USAGE') AS update_role_has_exec,
       has_schema_privilege('documentdb_api_remove_role', n.nspname, 'USAGE') AS remove_role_has_exec
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'documentdb_api_internal_readonly' ORDER BY n.nspname, proname;

SELECT n.nspname AS schema, proname,
       has_schema_privilege('documentdb_readonly_role', n.nspname, 'USAGE') AS readonly_role_has_exec,
       has_schema_privilege('documentdb_readwrite_role', n.nspname, 'USAGE') AS readwrite_role_has_exec,
       has_schema_privilege('documentdb_admin_role', n.nspname, 'USAGE') AS admin_role_has_exec,
       has_schema_privilege('documentdb_api_find_role', n.nspname, 'USAGE') AS find_role_has_exec,
       has_schema_privilege('documentdb_api_insert_role', n.nspname, 'USAGE') AS insert_role_has_exec,
       has_schema_privilege('documentdb_api_update_role', n.nspname, 'USAGE') AS update_role_has_exec,
       has_schema_privilege('documentdb_api_remove_role', n.nspname, 'USAGE') AS remove_role_has_exec
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'documentdb_api_internal_readwrite' ORDER BY n.nspname, proname;

SELECT n.nspname AS schema, proname,
       has_schema_privilege('documentdb_readonly_role', n.nspname, 'USAGE') AS readonly_role_has_exec,
       has_schema_privilege('documentdb_readwrite_role', n.nspname, 'USAGE') AS readwrite_role_has_exec,
       has_schema_privilege('documentdb_admin_role', n.nspname, 'USAGE') AS admin_role_has_exec,
       has_schema_privilege('documentdb_api_find_role', n.nspname, 'USAGE') AS find_role_has_exec,
       has_schema_privilege('documentdb_api_insert_role', n.nspname, 'USAGE') AS insert_role_has_exec,
       has_schema_privilege('documentdb_api_update_role', n.nspname, 'USAGE') AS update_role_has_exec,
       has_schema_privilege('documentdb_api_remove_role', n.nspname, 'USAGE') AS remove_role_has_exec
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'documentdb_api_internal_admin' ORDER BY n.nspname, proname;

SELECT n.nspname AS schema, proname,
       has_schema_privilege('documentdb_readonly_role', n.nspname, 'USAGE') AS readonly_role_has_exec,
       has_schema_privilege('documentdb_readwrite_role', n.nspname, 'USAGE') AS readwrite_role_has_exec,
       has_schema_privilege('documentdb_admin_role', n.nspname, 'USAGE') AS admin_role_has_exec,
       has_schema_privilege('documentdb_api_find_role', n.nspname, 'USAGE') AS find_role_has_exec,
       has_schema_privilege('documentdb_api_insert_role', n.nspname, 'USAGE') AS insert_role_has_exec,
       has_schema_privilege('documentdb_api_update_role', n.nspname, 'USAGE') AS update_role_has_exec,
       has_schema_privilege('documentdb_api_remove_role', n.nspname, 'USAGE') AS remove_role_has_exec
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'documentdb_api_internal_bgworker' ORDER BY n.nspname, proname;
