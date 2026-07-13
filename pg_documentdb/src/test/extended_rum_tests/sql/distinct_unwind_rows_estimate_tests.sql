SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal,public;

-- ============================================================
-- Row-estimate correctness for the distinct-unwind planner support
-- function attached to bson_distinct_unwind.
--
-- The support function derives the set-returning function's per-call row
-- estimate from the selectivity of the unwound path holding an array
-- (a type-bracketed "path >= []" comparison) and the selectivity of the path
-- being null (an equality against null):
--
--   rows = (1 - s - n) * 1 + n * 0 + s * DEFAULT
--
-- where s is the array selectivity, n the null selectivity, and DEFAULT is the
-- documentdb.distinct_unwind_default_rows GUC (default 10). A null (or absent)
-- path expands into no rows. When the feature flag is off, or statistics are
-- unavailable, the estimate stays at DEFAULT, preserving the previous behavior.
--
-- These tests assert the *behavior* (relative comparisons of the parsed
-- per-call expansion factor) rather than absolute cost/row numbers, so they
-- are deterministic across environments and PostgreSQL versions.
-- ============================================================

-- Ensure database 'db' exists so the system sentinel collection does not
-- consume a test collection id when running in standalone mode.
SELECT documentdb_api.insert_one('db', 'duw_sentinel', '{ "_id": 0 }');
SELECT documentdb_api.drop_collection('db', 'duw_sentinel');

-- Set the collection/index id base once for the whole test (must be a
-- multiple of 100). The collections created below take sequential ids from
-- this base.
SET documentdb.next_collection_id TO 91000;
SET documentdb.next_collection_index_id TO 91000;

-- Sparse arrays: 90% of docs hold a scalar "a", 10% hold an array "a".
SELECT COUNT(documentdb_api.insert_one('db', 'duw_sparse',
    format('{ "_id": %s, "a": %s }', i, i)::documentdb_core.bson))
FROM generate_series(1, 90) AS i;
SELECT COUNT(documentdb_api.insert_one('db', 'duw_sparse',
    format('{ "_id": %s, "a": [1, 2, 3] }', i)::documentdb_core.bson))
FROM generate_series(91, 100) AS i;

-- Dense arrays: every doc holds an array "a".
SELECT COUNT(documentdb_api.insert_one('db', 'duw_dense',
    format('{ "_id": %s, "a": [1, 2, 3] }', i)::documentdb_core.bson))
FROM generate_series(1, 100) AS i;

-- Null baseline: 10% of docs hold an array "a", the remaining 90% hold a
-- scalar "a" (no nulls). Same array density as the null-heavy collection
-- below, but every non-array doc contributes a row.
SELECT COUNT(documentdb_api.insert_one('db', 'duw_null_none',
    format('{ "_id": %s, "a": [1, 2, 3] }', i)::documentdb_core.bson))
FROM generate_series(1, 10) AS i;
SELECT COUNT(documentdb_api.insert_one('db', 'duw_null_none',
    format('{ "_id": %s, "a": %s }', i, i)::documentdb_core.bson))
FROM generate_series(11, 100) AS i;

-- Null heavy: 10% of docs hold an array "a" (same as the baseline), but the
-- remaining 90% hold an explicit null "a". A null path expands into no rows,
-- so the estimate must fall below the null-free baseline of identical array
-- density.
SELECT COUNT(documentdb_api.insert_one('db', 'duw_null_heavy',
    format('{ "_id": %s, "a": [1, 2, 3] }', i)::documentdb_core.bson))
FROM generate_series(1, 10) AS i;
SELECT COUNT(documentdb_api.insert_one('db', 'duw_null_heavy',
    format('{ "_id": %s, "a": null }', i)::documentdb_core.bson))
FROM generate_series(11, 100) AS i;

-- Full ANALYZE (the tables are well under the sample size) so the planner
-- statistics are exact and the estimates are deterministic.
ANALYZE;

SET documentdb.enableCompositeIndexPlanner TO on;

-- Helper: parse the per-call expansion factor of the ProjectSet node that
-- evaluates bson_distinct_unwind (ProjectSet rows / input rows) from the
-- JSON explain of a distinct command. The flag and planner GUCs are set on
-- every call so repeated invocations within a single statement do not leak
-- settings into one another.
CREATE OR REPLACE FUNCTION pg_temp.unwind_percall(coll text, key text, flag boolean)
RETURNS numeric
LANGUAGE plpgsql
AS $fn$
DECLARE
    explainJson jsonb;
    projectRows numeric;
    inputRows numeric;
    spec text;
BEGIN
    PERFORM set_config('documentdb.enableCompositeIndexPlanner', 'on', true);
    PERFORM set_config('documentdb.enable_distinct_unwind_rows_from_statistics',
                       CASE WHEN flag THEN 'on' ELSE 'off' END, true);

    spec := json_build_object('distinct', coll, 'key', key)::text;
    EXECUTE format(
        'EXPLAIN (COSTS ON, FORMAT JSON) SELECT document FROM documentdb_api_catalog.bson_aggregation_distinct(%L, %L::documentdb_core.bson)',
        'db', spec) INTO explainJson;

    SELECT (node->>'Plan Rows')::numeric,
           (node->'Plans'->0->>'Plan Rows')::numeric
    INTO projectRows, inputRows
    FROM jsonb_path_query(explainJson, 'strict $.**') AS node
    WHERE node->>'Node Type' = 'ProjectSet'
    LIMIT 1;

    RETURN round(projectRows / inputRows, 2);
END
$fn$;

-- ------------------------------------------------------------
-- Assertion 1: with the flag off the per-call estimate is the static
-- default (the documentdb.distinct_unwind_default_rows GUC) regardless of
-- array density -- the prior behavior.
-- ------------------------------------------------------------
SELECT pg_temp.unwind_percall('duw_sparse', 'a', false)
         = current_setting('documentdb.distinct_unwind_default_rows')::numeric
   AND pg_temp.unwind_percall('duw_dense', 'a', false)
         = current_setting('documentdb.distinct_unwind_default_rows')::numeric
   AND pg_temp.unwind_percall('duw_sparse', 'z', false)
         = current_setting('documentdb.distinct_unwind_default_rows')::numeric
  AS off_is_static_default;

-- ------------------------------------------------------------
-- Assertion 2: with the flag on a mostly-scalar path is estimated to expand
-- far less than the static default, because an array at the path is rare.
-- ------------------------------------------------------------
SELECT pg_temp.unwind_percall('duw_sparse', 'a', true)
     < pg_temp.unwind_percall('duw_sparse', 'a', false)
  AS sparse_reduced_below_default;

-- ------------------------------------------------------------
-- Assertion 3: with the flag on a path that always holds an array keeps
-- (approximately) the full default expansion, because the selectivity is
-- ~1. A small margin absorbs estimator noise across versions.
-- ------------------------------------------------------------
SELECT pg_temp.unwind_percall('duw_dense', 'a', true)
     >= pg_temp.unwind_percall('duw_dense', 'a', false) * 0.9
  AS dense_keeps_default;

-- ------------------------------------------------------------
-- Assertion 4: with the flag on a path that never holds an array collapses
-- toward the single-row floor (selectivity ~0) but never below one row.
-- ------------------------------------------------------------
SELECT pg_temp.unwind_percall('duw_sparse', 'z', true) >= 1
   AND pg_temp.unwind_percall('duw_sparse', 'z', true)
     < pg_temp.unwind_percall('duw_sparse', 'a', true)
  AS absent_collapses_to_floor;

-- ------------------------------------------------------------
-- Assertion 5: with the flag on the estimate grows monotonically with array
-- density: absent < sparse < dense.
-- ------------------------------------------------------------
SELECT pg_temp.unwind_percall('duw_sparse', 'z', true)
     < pg_temp.unwind_percall('duw_sparse', 'a', true)
   AND pg_temp.unwind_percall('duw_sparse', 'a', true)
     < pg_temp.unwind_percall('duw_dense', 'a', true)
  AS monotonic_in_density;

-- ------------------------------------------------------------
-- Assertion 6: with the flag on, a null-heavy path is estimated to expand
-- less than a null-free path of identical array density -- documents whose
-- path is null (or absent) contribute no rows.
-- ------------------------------------------------------------
SELECT pg_temp.unwind_percall('duw_null_heavy', 'a', true)
     < pg_temp.unwind_percall('duw_null_none', 'a', true)
  AS null_reduces_estimate;

DROP FUNCTION pg_temp.unwind_percall(text, text, boolean);
