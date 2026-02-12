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