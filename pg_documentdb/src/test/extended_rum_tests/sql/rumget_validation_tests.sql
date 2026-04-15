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