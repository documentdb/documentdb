SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_api_internal, documentdb_core, public;
SET documentdb.next_collection_id TO 1700;
SET documentdb.next_collection_index_id TO 1700;

set documentdb.enableExtendedExplainPlans to on;

-- Scenario 1.
-- validate that truncated entries get rechecked when we're not doing extended compare Partial
SELECT COUNT(documentdb_api.insert_one('rumget_db', 'rumget_coll',  FORMAT('{ "_id": %s, "a": "%s" }', i, repeat('a', 3500) || i)::bson)) FROM generate_series(1, 100) AS i;
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db', '{ "createIndexes": "rumget_coll", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', TRUE);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text)) $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }') $cmd$);

-- now try with the guc off
set documentdb.enablePartialMatchHasRecheck to off;
set documentdb_rum.forcerumorderedindexscan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text)) $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db', 
        '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }') $cmd$);

reset documentdb.enablePartialMatchHasRecheck;
reset documentdb_rum.forcerumorderedindexscan;

-- Scenario 2.
-- Validate that queries work correctly with enableIndexPathKeySummarization turned off
SET documentdb.enableIndexPathKeySummarization TO off;

-- basic equality query should still return correct results
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_coll", "filter": { "a": "aaaa30" }, "hint": "a_1" }');

SELECT document FROM bson_aggregation_find('rumget_db',
    bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text));

-- regex query should also work
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }');

-- explain should still show index usage
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        bson_build_document('find', 'rumget_coll'::text, 'filter', bson_build_document('a', repeat('a', 3500) || '30'), 'hint', 'a_1'::text)) $cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        '{ "find": "rumget_coll", "filter": { "a": { "$regex": "30$", "$options": "" }}, "hint": "a_1" }') $cmd$);

-- Scenario 3.
-- Validate multi-key TID deduplication with enableIndexPathKeySummarization off.
-- A document with an array field matches multiple index entries. When a query
-- has multiple conditions that match different array elements, the document
-- should be returned exactly once (TIDs must be deduplicated).
SELECT documentdb_api.insert_one('rumget_db', 'rumget_multikey',
    '{ "_id": 1, "a": [3, 5, 6] }');
SELECT documentdb_api.insert_one('rumget_db', 'rumget_multikey',
    '{ "_id": 2, "a": [10, 20] }');
SELECT documentdb_api.insert_one('rumget_db', 'rumget_multikey',
    '{ "_id": 3, "a": 7 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db',
    '{ "createIndexes": "rumget_multikey", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', TRUE);

-- $gt: 5 matches element 6, $lt: 4 matches element 3 => doc _id:1 matches, returned once
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } } }');

-- same query with hint to force index usage
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }');

-- verify explain shows index scan and correct row count (1 row, not duplicated)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }') $cmd$);

-- force ordered index scan and verify explain with multi-key deduplication
SET documentdb_rum.forcerumorderedindexscan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }') $cmd$);

SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 5, "$lt": 4 } }, "hint": "a_1" }');

RESET documentdb_rum.forcerumorderedindexscan;

-- additional multi-key queries for coverage
-- $gte: 6 matches element 6, $lte: 5 matches elements 3 and 5 => doc _id:1
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gte": 6, "$lte": 5 } }, "hint": "a_1" }');

-- $gt: 9 matches 10 and 20, $lt: 15 matches 10 => doc _id:2 returned once
SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_multikey", "filter": { "a": { "$gt": 9, "$lt": 15 } }, "hint": "a_1" }');

RESET documentdb.enableIndexPathKeySummarization;

-- Scenario 4.
-- An ordered-any physical scan must retain regular query semantics when the
-- operator itself does not require a particular scan direction.
SELECT documentdb_api.insert_one('rumget_db', 'rumget_ordered_any_multikey',
    '{ "_id": 1, "a": [5] }');
SELECT documentdb_api.insert_one('rumget_db', 'rumget_ordered_any_multikey',
    '{ "_id": 2, "a": [3, 7] }');
SELECT documentdb_api.insert_one('rumget_db', 'rumget_ordered_any_multikey',
    '{ "_id": 3, "a": [-1, -2] }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db',
    '{ "createIndexes": "rumget_ordered_any_multikey", "indexes": [ { "key": { "a": 1 }, "name": "a_1" } ] }', TRUE);
SELECT documentdb_api.shard_collection('rumget_db', 'rumget_ordered_any_multikey',
    '{ "_id": "hashed" }', false);

SET documentdb_rum.forcerumorderedindexscan TO on;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('rumget_db',
        '{ "find": "rumget_ordered_any_multikey", "filter": { "a": { "$gt": 4, "$lt": 6 } }, "hint": "a_1" }') $cmd$);

SELECT document FROM bson_aggregation_find('rumget_db',
    '{ "find": "rumget_ordered_any_multikey", "filter": { "a": { "$gt": 4, "$lt": 6 } }, "hint": "a_1" }');

RESET documentdb_rum.forcerumorderedindexscan;

-- Scenario 5.
-- A singleton left posting-tree leaf can contain a dead TID while its right
-- sibling still contains visible equality matches.
SELECT documentdb_api.create_collection('rumget_db', 'rumget_singleton_left_leaf');

SELECT collection_id AS singleton_leaf_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'rumget_db'
  AND collection_name = 'rumget_singleton_left_leaf' \gset

SELECT FORMAT(
    'ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off)',
    :singleton_leaf_collection_id) \gexec

SELECT COUNT(documentdb_api.insert_one(
    'rumget_db',
    'rumget_singleton_left_leaf',
    FORMAT('{ "_id": %s, "a": 5 }', i)::bson))
FROM generate_series(1, 4500) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rumget_db',
    '{ "createIndexes": "rumget_singleton_left_leaf", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }',
    TRUE);

SELECT index_id AS singleton_leaf_index_id,
       FORMAT('documentdb_data.documents_rum_index_%s', index_id) AS singleton_leaf_index_name
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = :singleton_leaf_collection_id
  AND (index_spec).index_name = 'a_1' \gset

SELECT documentdb_api.delete(
    'rumget_db',
    '{ "delete": "rumget_singleton_left_leaf", "deletes": [ { "q": { "_id": { "$lte": 2250 } }, "limit": 0 } ] }');

CALL documentdb_test_helpers.wait_for_vacuum_horizon();

SELECT FORMAT(
    'VACUUM (INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON, PARALLEL 0) documentdb_data.documents_%s',
    :singleton_leaf_collection_id) \gexec

WITH pages AS
(
    SELECT documentdb_api_internal.documentdb_rum_page_get_stats(
               public.get_raw_page(:'singleton_leaf_index_name', page_number)) AS page_stats
    FROM generate_series(
        1,
        (pg_relation_size(:'singleton_leaf_index_name'::regclass) /
         current_setting('block_size')::integer)::integer - 1) AS page_number
)
SELECT COUNT(*) FILTER (
           WHERE page_stats->>'flagsStr' = 'DATA') = 1 AS has_posting_tree_root,
       COUNT(*) FILTER (
           WHERE page_stats->>'flagsStr' = 'LEAF|DATA') = 2 AS has_two_leaf_pages,
       COUNT(*) FILTER (
           WHERE page_stats->>'flagsStr' = 'LEAF|DATA'
             AND (page_stats->>'nEntries')::integer = 1
             AND page_stats->>'leftLink' IS NULL
             AND page_stats->>'rightLink' IS NOT NULL) = 1 AS has_singleton_left_leaf,
       COUNT(*) FILTER (
           WHERE page_stats->>'flagsStr' = 'LEAF|DATA'
             AND (page_stats->>'nEntries')::integer > 1
             AND page_stats->>'leftLink' IS NOT NULL
             AND page_stats->>'rightLink' IS NULL) = 1 AS has_populated_right_leaf
FROM pages;

SELECT documentdb_api.delete(
    'rumget_db',
    '{ "delete": "rumget_singleton_left_leaf", "deletes": [ { "q": { "_id": 2251 }, "limit": 1 } ] }');

SET documentdb_rum.forcerumorderedindexscan TO on;

SELECT plan
FROM documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'rumget_db',
        '{ "find": "rumget_singleton_left_leaf", "filter": { "a": 5 }, "projection": { "_id": 1 }, "hint": "a_1", "limit": 1 }') $cmd$)
    AS explain_output(plan)
WHERE plan NOT LIKE '%eligibleDeadItems:%';

SELECT document FROM bson_aggregation_find(
    'rumget_db',
    '{ "find": "rumget_singleton_left_leaf", "filter": { "a": 5 }, "projection": { "_id": 1 }, "hint": "a_1", "limit": 1 }');

RESET documentdb_rum.forcerumorderedindexscan;

-- Per-path truncation uses the global fallback beyond the first six paths.
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb_rum.forcerumorderedindexscan TO off;
SET documentdb.max_non_ordered_term_scan_threshold TO 0;
SET documentdb.indexTermLimitOverride TO 200;
SELECT documentdb_api.insert_one('rumget_db', 'truncated_paths',
    format('{"_id":1,"a":1,"b":"keep","c":1,"d":1,"e":1,"f":1,"g":"%s"}',
    repeat('a', 120) || '1')::bson);
SELECT documentdb_api.insert_one('rumget_db', 'truncated_paths',
    format('{"_id":2,"a":1,"b":"keep","c":1,"d":1,"e":1,"f":1,"g":"%s"}',
    repeat('a', 120) || '2')::bson);
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db',
    '{"createIndexes":"truncated_paths","indexes":[{"key":{"a":1,"b":1,"c":1,"d":1,"e":1,"f":1,"g":1},"name":"all_paths"}]}', true);
SELECT format('{"find":"truncated_paths","filter":{"g":"%s"},"projection":{"_id":1},"hint":"all_paths"}',
    repeat('a', 120) || '2') AS seventh_path_query \gset

-- Only path seven is truncated, so the tracked mask is zero.
SELECT document FROM bson_aggregation_find('rumget_db', :'seventh_path_query'::bson);

-- A known truncated path must not suppress the fallback for path seven.
SELECT documentdb_api.insert_one('rumget_db', 'truncated_paths',
    format('{"_id":3,"a":"%s","b":"keep","c":1,"d":1,"e":1,"f":1,"g":"%s"}',
    repeat('x', 120), repeat('a', 120) || '3')::bson);
SELECT document FROM bson_aggregation_find('rumget_db', :'seventh_path_query'::bson);
SELECT plan FROM documentdb_test_helpers.run_explain_and_trim(format($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumget_db', %L::bson)
$cmd$, :'seventh_path_query')) AS explain_output(plan)
WHERE plan LIKE '%scanType:%' OR plan LIKE '%truncatedPaths:%'
    OR plan LIKE '%Rows Removed by Index Recheck:%';

-- The sixth path is the final path represented by the tracked mask.
SELECT documentdb_api.insert_one('rumget_db', 'truncated_paths',
    format('{"_id":4,"a":1,"b":"keep","c":1,"d":1,"e":1,"f":"%s","g":1}',
    repeat('b', 120) || '4')::bson);
SELECT documentdb_api.insert_one('rumget_db', 'truncated_paths',
    format('{"_id":5,"a":1,"b":"keep","c":1,"d":1,"e":1,"f":"%s","g":1}',
    repeat('b', 120) || '5')::bson);
SELECT format('{"find":"truncated_paths","filter":{"f":"%s"},"projection":{"_id":1},"hint":"all_paths"}',
    repeat('b', 120) || '5') AS sixth_path_query \gset
SELECT document FROM bson_aggregation_find('rumget_db', :'sixth_path_query'::bson);

-- Matching on an untruncated path remains exact despite other truncated paths.
BEGIN;
SET LOCAL track_functions TO 'all';
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"truncated_paths","filter":{"b":{"$regex":"^keep$"}},"projection":{"_id":1},"hint":"all_paths","sort":{"_id":1}}');
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) AS regex_heap_rechecks
FROM pg_proc
WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_regex';

-- A truncated untracked path still needs full-document regex evaluation.
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"truncated_paths","filter":{"g":{"$regex":"2$"}},"projection":{"_id":1},"hint":"all_paths"}');
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) AS regex_heap_rechecks
FROM pg_proc
WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_regex';
COMMIT;

-- Variable bounds must retain truncation rechecks in each generated query term.
SELECT format('{"find":"truncated_paths","filter":{"g":{"$in":["%s","%s"]}},"projection":{"_id":1},"hint":"all_paths","sort":{"_id":1}}',
    repeat('a', 120) || '2', repeat('a', 120) || '3') AS variable_path_query \gset
SELECT document FROM bson_aggregation_find('rumget_db', :'variable_path_query'::bson);
SELECT plan FROM documentdb_test_helpers.run_explain_and_trim(format($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumget_db', %L::bson)
$cmd$, :'variable_path_query')) AS explain_output(plan)
WHERE plan LIKE '%scanType:%' OR plan LIKE '%Rows Removed by Index Recheck:%';

BEGIN;
SET LOCAL track_functions TO 'all';
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) AS in_calls_before
FROM pg_proc
WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_in' \gset
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"truncated_paths","filter":{"b":{"$in":[{"$regularExpression":{"pattern":"^keep$","options":""}},"absent"]}},"projection":{"_id":1},"hint":"all_paths","sort":{"_id":1}}');
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) - :in_calls_before AS in_heap_rechecks
FROM pg_proc
WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_in';
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"truncated_paths","filter":{"g":{"$in":[{"$regularExpression":{"pattern":"2$","options":""}},"absent"]}},"projection":{"_id":1},"hint":"all_paths"}');
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) - :in_calls_before AS in_heap_rechecks
FROM pg_proc
WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_in';
COMMIT;

-- The final tracked path also needs rechecks for an untruncated regex bound.
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"truncated_paths","filter":{"f":{"$regex":"5$"}},"projection":{"_id":1},"hint":"all_paths"}');

-- Recheck colliding truncated terms before applying range bounds or aggregation.
SELECT format('{"find":"truncated_paths","filter":{"g":{"$gt":"%s","$lt":"%s"}},"projection":{"_id":1},"hint":"all_paths"}',
    repeat('a', 120) || '2', repeat('a', 120) || '4') AS bounded_path_query \gset
SELECT document FROM bson_aggregation_find('rumget_db', :'bounded_path_query'::bson);
SELECT format('{"aggregate":"truncated_paths","pipeline":[{"$match":{"g":"%s"}},{"$group":{"_id":"$b","n":{"$sum":1}}}],"hint":"all_paths"}',
    repeat('a', 120) || '2') AS grouped_path_query \gset
SELECT document FROM bson_aggregation_pipeline('rumget_db', :'grouped_path_query'::bson);

-- Bitmap scans must also use metadata-backed full-value rechecks.
SELECT documentdb_api.insert_one('rumget_db', 'truncated_paths',
    format('{"_id":6,"a":"%s","b":"drop","c":1,"d":1,"e":1,"f":1,"g":1}',
    repeat('x', 120) || 'other')::bson);
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SET LOCAL enable_bitmapscan TO on;
SELECT format('{"find":"truncated_paths","filter":{"a":"%s"},"projection":{"_id":1}}',
    repeat('x', 120)) AS bitmap_path_query \gset
SELECT document FROM bson_aggregation_find('rumget_db', :'bitmap_path_query'::bson);
SELECT plan FROM documentdb_test_helpers.run_explain_and_trim(format($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumget_db', %L::bson)
$cmd$, :'bitmap_path_query')) AS explain_output(plan)
WHERE plan LIKE '%Bitmap%' OR plan LIKE '%Rows Removed by Index Recheck:%';
COMMIT;

-- A zero path mask is not unknown when the global truncation bit is clear.
SELECT documentdb_api.insert_one('rumget_db', 'untruncated_paths', '{"_id":1,"a":"keep","b":1}');
SELECT documentdb_api.insert_one('rumget_db', 'untruncated_paths', '{"_id":2,"a":"drop","b":2}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db',
    '{"createIndexes":"untruncated_paths","indexes":[{"key":{"a":1,"b":1},"name":"a_b"}]}', true);
SELECT plan FROM documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('rumget_db',
        '{"find":"untruncated_paths","filter":{"a":{"$regex":"keep$"}},"projection":{"_id":1},"hint":"a_b"}')
$cmd$) AS explain_output(plan)
WHERE plan LIKE '%hasTruncation:%' OR plan LIKE '%scanType:%';
BEGIN;
SET LOCAL track_functions TO 'all';
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) AS regex_calls_before
FROM pg_proc
WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_regex' \gset
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"untruncated_paths","filter":{"a":{"$regex":"keep$"}},"projection":{"_id":1},"hint":"a_b"}');
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) - :regex_calls_before AS regex_heap_rechecks
FROM pg_proc
WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_regex';
COMMIT;

-- Only the active null alternative needs a heap recheck on the array-bearing path.
SELECT documentdb_api.insert_one('rumget_db', 'saop_runtime_recheck', '{"_id":1,"a":[]}');
SELECT documentdb_api.insert_one('rumget_db', 'saop_runtime_recheck', '{"_id":2,"a":null}');
SELECT documentdb_api.insert_one('rumget_db', 'saop_runtime_recheck', '{"_id":3,"a":"z"}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db',
    '{"createIndexes":"saop_runtime_recheck","indexes":[{"key":{"a":1,"_id":1},"name":"null_asc"},{"key":{"a":-1,"_id":1},"name":"null_desc"},{"key":{"b":1,"a":1,"_id":1},"name":"scalar_path"}]}', true);
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('rumget_db',
    '{"createIndexes":"saop_runtime_recheck","indexes":[{"key":{"a":1,"_id":1},"name":"collated_asc","collation":{"locale":"en","strength":2}},{"key":{"a":-1,"_id":1},"name":"collated_desc","collation":{"locale":"en","strength":2}}]}', true);

SET documentdb.max_non_ordered_term_scan_threshold TO 1;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;
SET documentdb.enableIndexOnlyScanForFindProject TO off;
SET track_functions TO 'all';

CREATE TEMP TABLE bounds_recheck_results (
    label text, result_ids int[], expected_ids int[], heap_rechecks bigint);
DO $bounds_rechecks$
DECLARE
    comparable text; partial_recheck text; force_ordered text; direction text;
    q record; query_spec bson; result_ids int[]; calls_before bigint; calls_after bigint;
    plan_line text; has_index_scan boolean;
BEGIN
    FOREACH comparable IN ARRAY ARRAY['off', 'on'] LOOP
        PERFORM set_config('documentdb.enableComparableTerms', comparable, true);
        FOREACH partial_recheck IN ARRAY ARRAY['off', 'on'] LOOP
            PERFORM set_config('documentdb.enablePartialMatchHasRecheck', partial_recheck, true);
            FOREACH force_ordered IN ARRAY ARRAY['off', 'on'] LOOP
                PERFORM set_config('documentdb_rum.forcerumorderedindexscan', force_ordered, true);
                FOREACH direction IN ARRAY ARRAY['asc', 'desc'] LOOP
                    FOR q IN SELECT * FROM (VALUES
                        ('nullable_in', 'saop_runtime_recheck',
                            '{"a":{"$in":["z",null]}}', ARRAY[2,3], 'null_' || direction, ''),
                        ('scalar_path_in', 'saop_runtime_recheck',
                            '{"b":{"$in":["z",null]}}', ARRAY[1,2,3], 'scalar_path', ''),
                        ('collated_nullable_in', 'saop_runtime_recheck',
                            '{"a":{"$in":["Z",null]}}', ARRAY[2,3], 'collated_' || direction,
                            ',"collation":{"locale":"en","strength":2}'),
                        ('collated_limit', 'saop_runtime_recheck',
                            '{"a":{"$in":["Z",null]}}',
                            CASE direction WHEN 'asc' THEN ARRAY[2] ELSE ARRAY[3] END,
                            'collated_' || direction,
                            format(',"collation":{"locale":"en","strength":2},"sort":{"a":%s},"limit":1',
                                CASE direction WHEN 'asc' THEN 1 ELSE -1 END))
                    ) AS cases(label, collection_name, filter, expected_ids, index_name, extra_spec) LOOP
                        query_spec := format('{"find":"%s","filter":%s,"hint":"%s"%s}',
                            q.collection_name, q.filter, q.index_name, q.extra_spec)::bson;
                        has_index_scan := false;
                        FOR plan_line IN EXECUTE
                            'EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find($1, $2)'
                            USING 'rumget_db', query_spec LOOP
                            has_index_scan := has_index_scan OR
                                (plan_line LIKE '%Index Scan using%' AND
                                 position(q.index_name IN plan_line) > 0);
                        END LOOP;
                        IF NOT has_index_scan THEN
                            RAISE EXCEPTION 'Expected secondary index % for %', q.index_name, query_spec;
                        END IF;
                        SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0)
                            INTO calls_before FROM pg_proc
                            WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
                                AND proname = 'bson_dollar_in';
                        EXECUTE
                            'SELECT array_agg((d->>''_id'')::int ORDER BY (d->>''_id'')::int)
                             FROM (SELECT document AS d FROM bson_aggregation_find($1, $2)) AS results'
                            USING 'rumget_db', query_spec INTO result_ids;
                        SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0)
                            INTO calls_after FROM pg_proc
                            WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
                                AND proname = 'bson_dollar_in';
                        INSERT INTO bounds_recheck_results
                            VALUES (q.label, coalesce(result_ids, '{}'), q.expected_ids,
                                calls_after - calls_before);
                    END LOOP;
                END LOOP;
            END LOOP;
        END LOOP;
    END LOOP;
END
$bounds_rechecks$;
SELECT label, bool_and(result_ids = expected_ids) AS all_results_match,
    min(heap_rechecks) AS min_heap_rechecks, max(heap_rechecks) AS max_heap_rechecks
FROM bounds_recheck_results GROUP BY label ORDER BY label;
RESET track_functions;
RESET enable_seqscan;
RESET enable_bitmapscan;
RESET documentdb.enableIndexOnlyScanForFindProject;
RESET documentdb_core.enableCollation;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;

-- Ordered entry-level rechecks must ignore truncation on unrelated paths.
BEGIN;
SET LOCAL documentdb_rum.forcerumorderedindexscan TO on;
SET LOCAL documentdb.enablePartialMatchHasRecheck TO on;
SET LOCAL track_functions TO 'all';
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) AS ordered_regex_calls_before
FROM pg_proc WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_regex' \gset
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"truncated_paths","filter":{"b":{"$regex":"^keep$"}},"projection":{"_id":1},"hint":"all_paths","sort":{"_id":1}}');
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) - :ordered_regex_calls_before
    AS untruncated_path_heap_rechecks
FROM pg_proc WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_regex';
SELECT document FROM bson_aggregation_find('rumget_db',
    '{"find":"truncated_paths","filter":{"g":{"$regex":"2$"}},"projection":{"_id":1},"hint":"all_paths"}');
SELECT coalesce(sum(pg_stat_get_xact_function_calls(oid)), 0) - :ordered_regex_calls_before
    AS truncated_path_heap_rechecks
FROM pg_proc WHERE pronamespace = 'documentdb_api_catalog'::regnamespace
    AND proname = 'bson_dollar_regex';
COMMIT;

RESET documentdb.indexTermLimitOverride;
RESET documentdb.max_non_ordered_term_scan_threshold;
RESET documentdb_rum.forcerumorderedindexscan;
RESET documentdb.defaultUseCompositeOpClass;