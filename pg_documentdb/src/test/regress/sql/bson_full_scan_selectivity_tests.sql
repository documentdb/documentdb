/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 * SPDX-License-Identifier: MIT
 *-------------------------------------------------------------------------
 */

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog;
SET documentdb.next_collection_id TO 8900000;
SET documentdb.next_collection_index_id TO 8900000;
SET documentdb.enablePlannerStatisticsNewCollections TO off;
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SET documentdb.enableCompositeIndexPlanner TO off;
SET documentdb_core.enableCollation TO on;

SELECT documentdb_api.create_collection('full_scan_selectivity_db', 'planner_rows');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'full_scan_selectivity_db',
    '{ "createIndexes": "planner_rows", "indexes": [ { "key": { "other": 1 }, "name": "other_1" } ] }',
    true);

SELECT COUNT(documentdb_api.insert_one(
    'full_scan_selectivity_db',
    'planner_rows',
    bson_build_document('_id', value, 'value', value,
        'label', CASE WHEN value % 2 = 0 THEN 'A' ELSE 'a' END)))
FROM generate_series(1, 90) AS value;

ANALYZE documentdb_data.documents_8900001;

CREATE SCHEMA bson_full_scan_selectivity_tests;

CREATE FUNCTION bson_full_scan_selectivity_tests.get_find_plan_rows(
    find_command bson DEFAULT '{ "find": "planner_rows", "projection": { "value": 1, "_id": 0 }, "sort": { "value": 1 } }')
RETURNS TABLE(estimated_rows bigint, analyzed_rows bigint, estimates_match boolean, total_cost numeric)
LANGUAGE plpgsql AS $fn$
DECLARE
    explain_plan jsonb;
    cost_plan jsonb;
BEGIN
    EXECUTE $query$
        EXPLAIN (FORMAT JSON)
        SELECT document
        FROM documentdb_api_catalog.bson_aggregation_find(
            'full_scan_selectivity_db',
            $1)
    $query$
    INTO explain_plan USING find_command;

    -- Isolate predicate cost from projection and sort costs, which vary with rows.
    EXECUTE $query$
        EXPLAIN (FORMAT JSON)
        SELECT document FROM documentdb_data.documents_8900001
        WHERE documentdb_api_internal.bson_dollar_fullscan(
            document, '{ "value": { "fullScan": true } }')
    $query$
    INTO cost_plan;

    RETURN QUERY
    WITH RECURSIVE plan_nodes(node) AS
    (
        SELECT explain_plan->0->'Plan'
        UNION ALL
        SELECT child
        FROM plan_nodes
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(plan_nodes.node->'Plans', '[]'::jsonb)) AS child
    ),
    row_estimates AS
    (
        SELECT (node->>'Plan Rows')::bigint AS estimated_rows
        FROM plan_nodes
        WHERE node->>'Relation Name' = 'documents_8900001'
    ),
    analyzed_table AS
    (
        SELECT reltuples::bigint AS analyzed_rows
        FROM pg_catalog.pg_class
        WHERE oid = 'documentdb_data.documents_8900001'::regclass
    )
    SELECT row_estimates.estimated_rows,
           analyzed_table.analyzed_rows,
           row_estimates.estimated_rows = analyzed_table.analyzed_rows,
           (cost_plan->0->'Plan'->>'Total Cost')::numeric
    FROM row_estimates
    CROSS JOIN analyzed_table;
END;
$fn$;

-- Without collection statistics or the composite-index planner, preserve
-- the legacy estimates and costs.
SHOW documentdb.enable_full_scan_cost_and_selectivity;
CREATE TEMP TABLE full_scan_plans AS
SELECT 'stats_off_flag_on' AS scenario, *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows();

\set collated_find '{ "find": "planner_rows", "projection": { "label": 1, "_id": 0 }, "sort": { "label": 1 }, "collation": { "locale": "en", "strength": 2 } }'
INSERT INTO full_scan_plans
SELECT 'stats_off_collated', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows(:'collated_find');

SET documentdb.enable_full_scan_cost_and_selectivity TO off;
INSERT INTO full_scan_plans
SELECT 'stats_off_flag_off', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows();
RESET documentdb.enable_full_scan_cost_and_selectivity;

-- The composite-index planner follows the existing cost/selectivity gate.
SET documentdb.enableCompositeIndexPlanner TO on;
INSERT INTO full_scan_plans
SELECT 'composite_on_without_stats', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows();
SET documentdb.enableCompositeIndexPlanner TO off;

SELECT documentdb_api.coll_mod('full_scan_selectivity_db', 'planner_rows',
    '{ "collMod": "planner_rows", "enableStats": true }');
ANALYZE documentdb_data.documents_8900001;

-- Collection statistics enable both overrides without the composite-index planner.
INSERT INTO full_scan_plans
SELECT 'stats_on_flag_on', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows();
INSERT INTO full_scan_plans
SELECT 'stats_on_collated', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows(:'collated_find');

SET documentdb.enable_full_scan_cost_and_selectivity TO off;
INSERT INTO full_scan_plans
SELECT 'stats_on_flag_off', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows();
RESET documentdb.enable_full_scan_cost_and_selectivity;

SET documentdb.enablePerCollectionPlannerStatistics TO off;
INSERT INTO full_scan_plans
SELECT 'stats_globally_off', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows();
RESET documentdb.enablePerCollectionPlannerStatistics;

SELECT documentdb_api.coll_mod('full_scan_selectivity_db', 'planner_rows',
    '{ "collMod": "planner_rows", "enableStats": false }');
INSERT INTO full_scan_plans
SELECT 'stats_disabled_again', *
FROM bson_full_scan_selectivity_tests.get_find_plan_rows();

SELECT scenario, estimated_rows, analyzed_rows, estimates_match
FROM full_scan_plans ORDER BY scenario;
SELECT enabled.total_cost = disabled.total_cost AS unchanged_cost_without_stats
FROM full_scan_plans enabled, full_scan_plans disabled
WHERE enabled.scenario = 'stats_off_flag_on' AND disabled.scenario = 'stats_off_flag_off';
SELECT enabled.total_cost < disabled.total_cost AS reduced_cost_with_stats
FROM full_scan_plans enabled, full_scan_plans disabled
WHERE enabled.scenario = 'stats_on_flag_on' AND disabled.scenario = 'stats_on_flag_off';
SELECT composite.total_cost = stats.total_cost AS same_cost_with_composite_planner
FROM full_scan_plans composite, full_scan_plans stats
WHERE composite.scenario = 'composite_on_without_stats' AND stats.scenario = 'stats_on_flag_on';
SELECT disabled.scenario, disabled.total_cost = baseline.total_cost AS legacy_cost
FROM full_scan_plans disabled, full_scan_plans baseline
WHERE disabled.scenario IN ('stats_globally_off', 'stats_disabled_again')
  AND baseline.scenario = 'stats_on_flag_off'
ORDER BY disabled.scenario;

DROP TABLE full_scan_plans;
SELECT documentdb_api.drop_collection('full_scan_selectivity_db', 'planner_rows');
DROP SCHEMA bson_full_scan_selectivity_tests CASCADE;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enableCompositeIndexPlanner;
RESET documentdb_core.enableCollation;
