setup
{
    CREATE SCHEMA isolation_schema;
}

teardown
{
	SELECT 1;
}

session "s1"

step "s1-begin"
{
    -- schema version should match binary version
    WITH cte AS (SELECT extversion as v FROM pg_extension WHERE extname = 'documentdb') SELECT documentdb_api.binary_version() LIKE REPLACE(v, '-', '.') FROM cte;
}

permutation "s1-begin"