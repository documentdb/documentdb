-- Copyright (c) Microsoft Corporation. All rights reserved.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog;
SET documentdb.next_collection_id TO 3200;
SET documentdb.next_collection_index_id TO 3200;

SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enablePerCollectionPlannerStatistics TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enablePerPathMultiKeySortPushdown TO on;
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO on;

CREATE FUNCTION pg_temp.find_relation_plan(
    database_name text,
    command_spec text,
    relation_name text,
    stats_flag boolean)
RETURNS TABLE(index_name text, estimated_rows bigint)
LANGUAGE plpgsql
AS $fn$
DECLARE
    explain_plan jsonb;
BEGIN
    PERFORM set_config(
        'documentdb.enable_elem_match_selectivity_from_stats',
        CASE WHEN stats_flag THEN 'on' ELSE 'off' END,
        true);

    EXECUTE format(
        'EXPLAIN (FORMAT JSON) SELECT document FROM documentdb_api_catalog.bson_aggregation_find(%L, %L::documentdb_core.bson)',
        database_name,
        command_spec)
    INTO explain_plan;

    RETURN QUERY
    WITH RECURSIVE plan_nodes(node) AS
    (
        SELECT explain_plan->0->'Plan'
        UNION ALL
        SELECT child
        FROM plan_nodes
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(plan_nodes.node->'Plans', '[]'::jsonb)) AS child
    )
    SELECT node->>'Index Name',
           (node->>'Plan Rows')::bigint
    FROM plan_nodes
    WHERE node->>'Relation Name' = relation_name
    LIMIT 1;
END;
$fn$;

SHOW documentdb.enable_elem_match_selectivity_from_stats;
SHOW documentdb.enable_elem_match_selectivity_lower_bound;
SHOW documentdb.enable_array_bson_stats_with_planner_statistics;

SELECT documentdb_api.create_collection('elem_match_selectivity', 'scalar_values');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'elem_match_selectivity',
    '{ "createIndexes": "scalar_values", "indexes": [ { "key": { "values": 1 }, "name": "values_1" } ] }',
    TRUE);

SELECT COUNT(documentdb_api.insert_one(
    'elem_match_selectivity',
    'scalar_values',
    FORMAT(
        '{ "_id": %s, "values": [ %s, %s ], "padding": "%s" }',
        value,
        value,
        value + 10000,
        repeat('x', 1200))::bson))
FROM generate_series(1, 1000) AS value;

ANALYZE documentdb_data.documents_3201;

SET enable_indexscan TO off;
SET enable_bitmapscan TO off;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100, "$lt": 1000 } } } }',
    'documents_3201',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100, "$lt": 1000 } } } }',
    'documents_3201',
    false);

SELECT COUNT(*)
FROM
(
    SELECT document
    FROM bson_aggregation_find(
        'elem_match_selectivity',
        '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100, "$lt": 1000 } } } }')
) results;

SET documentdb.enable_array_bson_stats_with_planner_statistics TO on;
ANALYZE documentdb_data.documents_3201;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100, "$lt": 1000 } } } }',
    'documents_3201',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100, "$lt": 1000 } } } }',
    'documents_3201',
    false);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100 } } } }',
    'documents_3201',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100 } } } }',
    'documents_3201',
    false);

SELECT COUNT(*)
FROM
(
    SELECT document
    FROM bson_aggregation_find(
        'elem_match_selectivity',
        '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$gt": 100 } } } }')
) results;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$lt": 1000 } } } }',
    'documents_3201',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$lt": 1000 } } } }',
    'documents_3201',
    false);

SELECT COUNT(*)
FROM
(
    SELECT document
    FROM bson_aggregation_find(
        'elem_match_selectivity',
        '{ "find": "scalar_values", "filter": { "values": { "$elemMatch": { "$lt": 1000 } } } }')
) results;

RESET documentdb.enable_array_bson_stats_with_planner_statistics;

RESET enable_bitmapscan;
RESET enable_indexscan;

SELECT documentdb_api.create_collection('elem_match_selectivity', 'nested_predicates');
SELECT documentdb_test_helpers.drop_primary_key(
    'elem_match_selectivity',
    'nested_predicates');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'elem_match_selectivity',
    '{ "createIndexes": "nested_predicates", "indexes": [ { "key": { "tenantId": 1, "active": 1, "status": 1, "steps.assignees.userId": 1, "steps.assignees.status": 1, "steps.assignees.active": 1, "label": 1 }, "name": "idx_all_predicates", "enableOrderedIndex": true } ] }',
    TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'elem_match_selectivity',
    '{ "createIndexes": "nested_predicates", "indexes": [ { "key": { "tenantId": 1, "steps.assignees.userId": 1, "steps.assignees.status": 1, "steps.assignees.active": 1, "steps.assignees.updatedAt": -1 }, "name": "idx_nested_predicates", "enableOrderedIndex": true } ] }',
    TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'elem_match_selectivity',
    '{ "createIndexes": "nested_predicates", "indexes": [ { "key": { "tenantId": 1, "active": 1, "status": 1, "createdAt": -1 }, "name": "idx_top_level_predicates", "enableOrderedIndex": true } ] }',
    TRUE);

SELECT COUNT(documentdb_api.insert_one(
    'elem_match_selectivity',
    'nested_predicates',
    FORMAT(
        '{ "_id": %s, "tenantId": "tenant-abc-001", "active": 1, "status": 1, "steps": [ { "assignees": [ { "userId": "%s", "status": 4, "active": 1, "updatedAt": "20260101120000" } ] } ], "label": "entry-name", "createdAt": "20260101120000", "padding": "%s" }',
        value,
        CASE WHEN value <= 10 THEN 'user-xyz-001' ELSE 'user-other' END,
        repeat('x', 1200))::bson))
FROM generate_series(1, 1000) AS value;

ANALYZE documentdb_data.documents_3202;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_predicates", "filter": { "tenantId": { "$in": [ "tenant-abc-001", "tenant-abc-002" ] }, "active": 1, "status": { "$in": [ 1, 2, 3 ] }, "steps.assignees": { "$elemMatch": { "userId": "user-xyz-001", "status": 4, "active": 1 } } } }',
    'documents_3202',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_predicates", "filter": { "tenantId": { "$in": [ "tenant-abc-001", "tenant-abc-002" ] }, "active": 1, "status": { "$in": [ 1, 2, 3 ] }, "steps.assignees": { "$elemMatch": { "userId": "user-xyz-001", "status": 4, "active": 1 } } } }',
    'documents_3202',
    false);

SELECT documentdb_api.create_collection('elem_match_selectivity', 'nested_operator_shapes');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'elem_match_selectivity',
    '{ "createIndexes": "nested_operator_shapes", "indexes": [ { "key": { "items.score": 1 }, "name": "items_score_1" }, { "key": { "items.code": 1 }, "name": "items_code_1" } ] }',
    TRUE);

SELECT COUNT(documentdb_api.insert_one(
    'elem_match_selectivity',
    'nested_operator_shapes',
    FORMAT(
        '{ "_id": %s, "items": [ { "score": %s, "code": "%s" } ], "padding": "%s" }',
        value,
        value,
        CASE WHEN value <= 25 THEN FORMAT('target-%s', value)
             ELSE FORMAT('other-%s', value) END,
        repeat('x', 1200))::bson))
FROM generate_series(1, 1000) AS value;

ANALYZE documentdb_data.documents_3203;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "code": "target-1" } } } }',
    'documents_3203',
    true);

SET documentdb.enable_elem_match_selectivity_lower_bound TO off;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "code": "target-1" } } } }',
    'documents_3203',
    true);

SELECT COUNT(*)
FROM
(
    SELECT document
    FROM bson_aggregation_find(
        'elem_match_selectivity',
        '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "code": "target-1" } } } }')
) results;

SET documentdb.enable_elem_match_selectivity_lower_bound TO on;

SET enable_indexscan TO off;
SET enable_bitmapscan TO off;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "score": { "$gte": 101, "$lt": 201 } } } } }',
    'documents_3203',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "score": { "$gte": 101, "$lt": 201 } } } } }',
    'documents_3203',
    false);

SELECT COUNT(*)
FROM
(
    SELECT document
    FROM bson_aggregation_find(
        'elem_match_selectivity',
        '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "score": { "$gte": 101, "$lt": 201 } } } } }')
) results;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "score": { "$gt": 100, "$lte": 200 } } } } }',
    'documents_3203',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "score": { "$gt": 100, "$lte": 200 } } } } }',
    'documents_3203',
    false);

SELECT COUNT(*)
FROM
(
    SELECT document
    FROM bson_aggregation_find(
        'elem_match_selectivity',
        '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "score": { "$gt": 100, "$lte": 200 } } } } }')
) results;

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "code": { "$regex": "^target-" } } } } }',
    'documents_3203',
    true);

SELECT * FROM pg_temp.find_relation_plan(
    'elem_match_selectivity',
    '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "code": { "$regex": "^target-" } } } } }',
    'documents_3203',
    false);

SELECT COUNT(*)
FROM
(
    SELECT document
    FROM bson_aggregation_find(
        'elem_match_selectivity',
        '{ "find": "nested_operator_shapes", "filter": { "items": { "$elemMatch": { "code": { "$regex": "^target-" } } } } }')
) results;

RESET enable_bitmapscan;
RESET enable_indexscan;

SELECT documentdb_api.drop_collection(
    'elem_match_selectivity',
    'nested_operator_shapes');
SELECT documentdb_api.drop_collection(
    'elem_match_selectivity',
    'nested_predicates');
SELECT documentdb_api.drop_collection(
    'elem_match_selectivity',
    'scalar_values');

RESET documentdb.enable_composite_reduced_correlated_bounds_planning;
RESET documentdb.enable_elem_match_selectivity_lower_bound;
RESET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath;
RESET documentdb.enablePerPathMultiKeySortPushdown;
RESET documentdb.enableIndexMetadataGlobalTracking;
RESET documentdb.enable_array_bson_stats_with_planner_statistics;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enableCompositeIndexPlanner;
