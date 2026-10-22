-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 28971000;
SET documentdb.next_collection_index_id TO 28971000;
SET documentdb.enablePerCollectionPlannerStatistics TO off;
SET documentdb.enablePlannerStatisticsNewCollections TO off;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET documentdb.useFileBasedPersistedCursors TO off;
SET documentdb.reportParallelPlanInCursorContinuation TO on;
SET documentdb.enable_non_dynamic_cursor_parallel_plans TO off;
SET documentdb_core.enableCollation TO on;

-- Incompressible payloads live in TOAST, leaving a small heap beside a wide index.
SELECT count(documentdb_api.insert_one('parallel_cursor_db', 'parallel_toast',
    jsonb_build_object('_id', i, 'tag', i % 100, 'items', jsonb_build_array(1, 2),
        'label', 'MATCH',
        'padding', (SELECT string_agg(md5((i * 256 + j)::text), '')
                    FROM generate_series(1, 256) AS payload(j)))::text::documentdb_core.bson))
FROM generate_series(1, 5000) AS documents(i);
SELECT documentdb_api_internal.create_indexes_non_concurrently('parallel_cursor_db',
    '{"createIndexes":"parallel_toast","indexes":[{"key":{"tag":1,"padding":1},"name":"tag_padding"}]}', true);
SELECT documentdb_api.compact('{"compact":"parallel_toast","$db":"parallel_cursor_db","mode":"updateStats"}');

SELECT NOT current_setting('documentdb.enablePerCollectionPlannerStatistics')::boolean AS cluster_stats_disabled,
       (options ->> 'statsEnabled') IS DISTINCT FROM 'true' AS collection_stats_disabled
FROM documentdb_api_catalog.collections
WHERE database_name = 'parallel_cursor_db' AND collection_name = 'parallel_toast';
SELECT pg_relation_size(c.reltoastrelid) > pg_relation_size(c.oid) AS toasted_documents,
       (SELECT max(pg_relation_size(indexrelid)) FROM pg_index WHERE indrelid = c.oid)
           > pg_relation_size(c.oid) AS wide_index
FROM pg_class AS c
WHERE c.oid = (
    SELECT format('documentdb_data.documents_%s', collection_id)::regclass
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'parallel_cursor_db' AND collection_name = 'parallel_toast'
);

-- Make parallel paths eligible for this small fixture without disabling indexes
-- or sequential scans.
SET max_parallel_workers_per_gather TO 2;
SET min_parallel_table_scan_size TO 0;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
\set aggregate_command '{"aggregate":"parallel_toast","pipeline":[{"$match":{"tag":1}},{"$unwind":"$items"},{"$group":{"_id":"$tag","count":{"$sum":1}}}],"cursor":{"batchSize":0}}'

-- Without statistics, the default-on guard preserves the selective index path.
SET documentdb.enable_dynamic_cursor_parallel_plans TO on;
SELECT documentdb_test_helpers.explain_plan_contains(
           format('SELECT document FROM bson_aggregation_pipeline(%L, %L)',
               'parallel_cursor_db', :'aggregate_command'), 'Parallel Seq Scan') AS parallel_seq_scan,
       documentdb_test_helpers.explain_plan_contains(
           format('SELECT document FROM bson_aggregation_pipeline(%L, %L)',
               'parallel_cursor_db', :'aggregate_command'), 'Bitmap Index Scan on tag_padding') AS selective_index;
SELECT fp.persistConnection,
       COALESCE((fp.continuation ->> 'pp')::boolean, false) AS parallel_plan,
       (fp.continuation ->> 'qp')::boolean AS persistent,
       gm.continuation IS NULL AS fully_drained,
       bson_dollar_project(gm.cursorPage, '{"batch":"$cursor.nextBatch"}') AS result
FROM documentdb_api.aggregate_cursor_first_page('parallel_cursor_db', :'aggregate_command', 28971000) AS fp
CROSS JOIN LATERAL documentdb_api.cursor_get_more('parallel_cursor_db',
    '{"getMore":{"$numberLong":"28971000"},"collection":"parallel_toast","batchSize":10}', fp.continuation) AS gm;

-- The escape hatch restores the original no-statistics parallel plan.
SET documentdb.enable_skip_parallel_plans_without_stats TO off;
SELECT documentdb_test_helpers.explain_plan_contains(
           format('SELECT document FROM bson_aggregation_pipeline(%L, %L)',
               'parallel_cursor_db', :'aggregate_command'), 'Parallel Seq Scan') AS parallel_seq_scan,
       documentdb_test_helpers.explain_plan_contains(
           format('SELECT document FROM bson_aggregation_pipeline(%L, %L)',
               'parallel_cursor_db', :'aggregate_command'), 'Bitmap Index Scan on tag_padding') AS selective_index;
SELECT fp.persistConnection,
       COALESCE((fp.continuation ->> 'pp')::boolean, false) AS parallel_plan,
       (fp.continuation ->> 'qp')::boolean AS persistent,
       gm.continuation IS NULL AS fully_drained,
       bson_dollar_project(gm.cursorPage, '{"batch":"$cursor.nextBatch"}') AS result
FROM documentdb_api.aggregate_cursor_first_page('parallel_cursor_db', :'aggregate_command', 28971000) AS fp
CROSS JOIN LATERAL documentdb_api.cursor_get_more('parallel_cursor_db',
    '{"getMore":{"$numberLong":"28971000"},"collection":"parallel_toast","batchSize":10}', fp.continuation) AS gm;

RESET documentdb.enable_skip_parallel_plans_without_stats;

-- Enabling statistics globally is insufficient when the collection has none.
-- A case-insensitive residual match must retain its results on the serial path.
SET documentdb.enablePerCollectionPlannerStatistics TO on;
\set aggregate_command '{"aggregate":"parallel_toast","pipeline":[{"$match":{"tag":1,"label":"match"}},{"$unwind":"$items"},{"$group":{"_id":"$tag","count":{"$sum":1}}}],"collation":{"locale":"en","strength":2},"cursor":{"batchSize":0}}'
SELECT documentdb_test_helpers.explain_plan_contains(
           format('SELECT document FROM bson_aggregation_pipeline(%L, %L)',
               'parallel_cursor_db', :'aggregate_command'), 'Parallel Seq Scan') AS parallel_seq_scan;
SELECT fp.persistConnection,
       COALESCE((fp.continuation ->> 'pp')::boolean, false) AS parallel_plan,
       (fp.continuation ->> 'qp')::boolean AS persistent,
       gm.continuation IS NULL AS fully_drained,
       bson_dollar_project(gm.cursorPage, '{"batch":"$cursor.nextBatch"}') AS result
FROM documentdb_api.aggregate_cursor_first_page('parallel_cursor_db', :'aggregate_command', 28971000) AS fp
CROSS JOIN LATERAL documentdb_api.cursor_get_more('parallel_cursor_db',
    '{"getMore":{"$numberLong":"28971000"},"collection":"parallel_toast","batchSize":10}', fp.continuation) AS gm;

SELECT documentdb_api.coll_mod('parallel_cursor_db', 'parallel_toast',
    '{"collMod":"parallel_toast","enableStats":true}');
SELECT documentdb_api.compact('{"compact":"parallel_toast","$db":"parallel_cursor_db","mode":"updateStats"}');

-- With collection statistics, a broad predicate can still choose parallelism.
\set aggregate_command '{"aggregate":"parallel_toast","pipeline":[{"$match":{"tag":{"$gte":0},"label":"match"}},{"$unwind":"$items"},{"$group":{"_id":null,"count":{"$sum":1}}}],"collation":{"locale":"en","strength":2},"cursor":{"batchSize":0}}'
SELECT documentdb_test_helpers.explain_plan_contains(
           format('SELECT document FROM bson_aggregation_pipeline(%L, %L)',
               'parallel_cursor_db', :'aggregate_command'), 'Parallel Seq Scan') AS parallel_seq_scan;
SELECT fp.persistConnection,
       COALESCE((fp.continuation ->> 'pp')::boolean, false) AS parallel_plan,
       (fp.continuation ->> 'qp')::boolean AS persistent,
       gm.continuation IS NULL AS fully_drained,
       bson_dollar_project(gm.cursorPage, '{"batch":"$cursor.nextBatch"}') AS result
FROM documentdb_api.aggregate_cursor_first_page('parallel_cursor_db', :'aggregate_command', 28971000) AS fp
CROSS JOIN LATERAL documentdb_api.cursor_get_more('parallel_cursor_db',
    '{"getMore":{"$numberLong":"28971000"},"collection":"parallel_toast","batchSize":10}', fp.continuation) AS gm;

-- The dynamic parallel flag independently disables the statistics-backed plan.
SET documentdb.enable_dynamic_cursor_parallel_plans TO off;
SELECT documentdb_test_helpers.explain_plan_contains(
           format('SELECT document FROM bson_aggregation_pipeline(%L, %L)',
               'parallel_cursor_db', :'aggregate_command'), 'Parallel Seq Scan') AS parallel_seq_scan;
SELECT fp.persistConnection,
       COALESCE((fp.continuation ->> 'pp')::boolean, false) AS parallel_plan,
       (fp.continuation ->> 'qp')::boolean AS persistent,
       gm.continuation IS NULL AS fully_drained,
       bson_dollar_project(gm.cursorPage, '{"batch":"$cursor.nextBatch"}') AS result
FROM documentdb_api.aggregate_cursor_first_page('parallel_cursor_db', :'aggregate_command', 28971000) AS fp
CROSS JOIN LATERAL documentdb_api.cursor_get_more('parallel_cursor_db',
    '{"getMore":{"$numberLong":"28971000"},"collection":"parallel_toast","batchSize":10}', fp.continuation) AS gm;

-- Restore the no-statistics setup for the separate non-dynamic controls.
SET documentdb.enablePerCollectionPlannerStatistics TO off;

-- Non-dynamic file-backed cursors use the separate, default-on parallel flag.
-- A case-insensitive residual match must return the same rows in both modes.
SET documentdb.enableDynamicCursors TO off;
SET documentdb.useFileBasedPersistedCursors TO on;
\set aggregate_command '{"aggregate":"parallel_toast","pipeline":[{"$match":{"tag":1,"label":"match"}},{"$unwind":"$items"},{"$group":{"_id":"$tag","count":{"$sum":1}}}],"collation":{"locale":"en","strength":2},"cursor":{"batchSize":0}}'
RESET documentdb.enable_non_dynamic_cursor_parallel_plans;
SELECT NOT fp.persistConnection AS file_backed,
       COALESCE((fp.continuation ->> 'pp')::boolean, false) AS parallel_plan,
       gm.continuation IS NULL AS fully_drained,
       bson_dollar_project(gm.cursorPage, '{"batch":"$cursor.nextBatch"}') AS result
FROM documentdb_api.aggregate_cursor_first_page('parallel_cursor_db', :'aggregate_command', 28971000) AS fp
CROSS JOIN LATERAL documentdb_api.cursor_get_more('parallel_cursor_db',
    '{"getMore":{"$numberLong":"28971000"},"collection":"parallel_toast","batchSize":10}', fp.continuation) AS gm;

SET documentdb.enable_non_dynamic_cursor_parallel_plans TO off;
SELECT NOT fp.persistConnection AS file_backed,
       COALESCE((fp.continuation ->> 'pp')::boolean, false) AS parallel_plan,
       gm.continuation IS NULL AS fully_drained,
       bson_dollar_project(gm.cursorPage, '{"batch":"$cursor.nextBatch"}') AS result
FROM documentdb_api.aggregate_cursor_first_page('parallel_cursor_db', :'aggregate_command', 28971000) AS fp
CROSS JOIN LATERAL documentdb_api.cursor_get_more('parallel_cursor_db',
    '{"getMore":{"$numberLong":"28971000"},"collection":"parallel_toast","batchSize":10}', fp.continuation) AS gm;

-- Single-result and single-batch execution must also work with parallelism off.
SELECT documentdb_api.count_query('parallel_cursor_db',
    '{"count":"parallel_toast","query":{"tag":1,"label":"match"},"collation":{"locale":"en","strength":2}}');
SELECT fp.continuation IS NULL AS fully_drained, fp.cursorId = 0 AS closed,
       jsonb_array_length(bson_dollar_project(fp.cursorPage,
           '{"batch":"$cursor.firstBatch"}')::text::jsonb -> 'batch') AS rows
FROM documentdb_api.find_cursor_first_page('parallel_cursor_db',
    '{"find":"parallel_toast","filter":{"tag":1,"label":"match"},"projection":{"_id":1},"collation":{"locale":"en","strength":2},"singleBatch":true,"batchSize":100}') AS fp;

SELECT documentdb_api.drop_collection('parallel_cursor_db', 'parallel_toast');
\unset aggregate_command
RESET max_parallel_workers_per_gather;
RESET min_parallel_table_scan_size;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET documentdb.enable_dynamic_cursor_parallel_plans;
RESET documentdb.enable_non_dynamic_cursor_parallel_plans;
RESET documentdb_core.enableCollation;
RESET documentdb.reportParallelPlanInCursorContinuation;
RESET documentdb.useFileBasedPersistedCursors;
RESET documentdb.enableCursorsOnAggregationQueryRewrite;
RESET documentdb.enableDynamicCursors;
RESET documentdb.enableCompositeIndexPlanner;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enablePerCollectionPlannerStatistics;
