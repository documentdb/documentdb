SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog;
SET documentdb.next_collection_id TO 8890000;
SET documentdb.next_collection_index_id TO 8890000;

-- Regression coverage for _id btree range-selectivity estimation. A closed _id
-- range (e.g. $gte/$lt, or a $regex prefix that lowers to a string range) is
-- pushed to the _id_ btree as matching object_id lower/upper bound quals. When
-- native btree statistics are available these bounds must be combined into a
-- single range estimate (hibound + lobound - 1) instead of being multiplied as
-- independent clauses, which otherwise badly overestimates mid-range filters.
--
-- The check reads the selectivity reported for the _id_ index by the extended
-- EXPLAIN output and classifies it into a stable bucket, so the assertion does
-- not depend on the exact histogram-derived float (which can wobble across runs
-- and PostgreSQL versions).

SELECT documentdb_api.create_collection('btree_range_sel_db', 'id_range');

-- 100 documents with _id = 1 .. 100.
SELECT COUNT(documentdb_api.insert_one('btree_range_sel_db', 'id_range',
    bson_build_document('_id'::text, i))) FROM generate_series(1, 100) i;

ANALYZE documentdb_data.documents_8890001;

CREATE SCHEMA bson_btree_range_selectivity_tests;

CREATE FUNCTION bson_btree_range_selectivity_tests.classify_id_index_selectivity(
    p_filter text, p_stats_enabled boolean) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
    v_row text;
    v_selectivity numeric := NULL;
BEGIN
    -- Force the _id_ index scan so the extended cost line is emitted, and toggle
    -- native btree selectivity for the duration of this call only.
    PERFORM set_config('enable_seqscan', 'off', true);
    PERFORM set_config('documentdb.enableExtendedExplainPlans', 'on', true);
    PERFORM set_config('documentdb.enableExplainScanIndexCosts', 'on', true);
    PERFORM set_config('documentdb_core.enableBsonSelectivityFromBtreeStats',
                       CASE WHEN p_stats_enabled THEN 'on' ELSE 'off' END, true);

    FOR v_row IN
        EXECUTE format(
            $q$EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_find(%L, %L)$q$,
            'btree_range_sel_db',
            format('{ "find": "id_range", "filter": %s }', p_filter))
    LOOP
        -- The _id_ extended cost line is the only one reporting index entries.
        IF v_row ~ 'estimated total index entries=' THEN
            v_selectivity := (regexp_match(v_row, 'selectivity=([0-9.eE+-]+)'))[1]::numeric;
            EXIT;
        END IF;
    END LOOP;

    IF v_selectivity IS NULL THEN
        RAISE EXCEPTION 'Did not find _id_ index selectivity for filter: %', p_filter;
    END IF;

    RETURN CASE
        WHEN v_selectivity <= 0.001 THEN 'default multiply (no stats)'
        WHEN v_selectivity <= 0.15  THEN 'range merged (stats)'
        WHEN v_selectivity <= 0.45  THEN 'independent multiply (stats)'
        ELSE 'single bound (> 0.45)'
    END;
END;
$fn$;

-- A mid-range _id filter matches 10 of 100 documents (true selectivity 0.10).
-- Mid-range is required: near the start of the key domain, merging and
-- multiplying nearly coincide and would not distinguish the two.

-- Without native btree statistics the bounds fall back to the default per-clause
-- estimate and multiply to a near-zero selectivity.
SELECT bson_btree_range_selectivity_tests.classify_id_index_selectivity(
    '{ "_id": { "$gte": 45, "$lt": 55 } }', false) AS mid_range_no_stats;

-- With native btree statistics the matching lower/upper bounds are merged into a
-- range, giving a selectivity close to the true 0.10 rather than the ~0.30
-- independent-multiply overestimate.
SELECT bson_btree_range_selectivity_tests.classify_id_index_selectivity(
    '{ "_id": { "$gte": 45, "$lt": 55 } }', true) AS mid_range_with_stats;

-- A single-sided bound has nothing to merge, so it reports the real per-bound
-- selectivity (~0.57). Contrasting this with the two-sided result confirms the
-- two-sided value comes from merging the bounds, not from a constant estimate.
SELECT bson_btree_range_selectivity_tests.classify_id_index_selectivity(
    '{ "_id": { "$gte": 45 } }', true) AS single_bound_with_stats;

-- The merged estimate bucket is stable across repeated planning.
SELECT g AS run,
       bson_btree_range_selectivity_tests.classify_id_index_selectivity(
           '{ "_id": { "$gte": 45, "$lt": 55 } }', true) AS mid_range_with_stats
FROM generate_series(1, 3) g;

SELECT documentdb_api.drop_collection('btree_range_sel_db', 'id_range');
DROP FUNCTION bson_btree_range_selectivity_tests.classify_id_index_selectivity(text, boolean);
DROP SCHEMA bson_btree_range_selectivity_tests;
