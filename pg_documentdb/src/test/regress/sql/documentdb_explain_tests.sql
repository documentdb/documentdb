SET search_path TO documentdb_api, documentdb_api_catalog,documentdb_core;
SET documentdb.next_collection_id TO 1300;
SET documentdb.next_collection_index_id TO 1300;

CREATE OR REPLACE FUNCTION documentdb_test_helpers.documentdb_explain(
    p_explain_spec bson,
    p_append_cursor_params boolean DEFAULT FALSE)
 RETURNS bson
 LANGUAGE c
 VOLATILE
AS 'pg_documentdb', $$documentdb_explain$$;


CREATE OR REPLACE FUNCTION documentdb_test_helpers.explain_and_mask_numbers(
    p_explain_spec bson,
    p_append_cursor_params boolean DEFAULT FALSE)
 RETURNS SETOF text AS $$
 DECLARE
     explain_result bson;
 BEGIN
    SELECT documentdb_test_helpers.documentdb_explain(p_explain_spec, p_append_cursor_params) INTO explain_result;

    SELECT regexp_replace(explain_result::text, '"startupCost" : { "\$numberDouble" : "[0-9eE\.]+" }', '"startupCost" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"totalCost" : { "\$numberDouble" : "[0-9eE\.]+" }', '"totalCost" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"executionStartAtTimeMillis" : { "\$numberDouble" : "[0-9eE\.]+" }', '"executionStartAtTimeMillis" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"executionTimeMillis" : { "\$numberDouble" : "[0-9eE\.]+" }', '"executionTimeMillis" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"numBlocksFromCache" : { "\$numberDouble" : "[0-9eE\.]+" }', '"numBlocksFromCache" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"numBlocksFromDisk" : { "\$numberDouble" : "[0-9eE\.]+" }', '"numBlocksFromDisk" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"ioReadTimeMillis" : { "\$numberDouble" : "[0-9eE\.]+" }', '"ioReadTimeMillis" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"totalDataSizeSortedBytesEstimate" : { "\$numberDouble" : "[0-9eE\.]+" }', '"totalDataSizeSortedBytesEstimate" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;
    SELECT regexp_replace(explain_result::text, '"estimatedTotalKeysExamined" : { "\$numberDouble" : "[0-9eE\.]+" }', '"estimatedTotalKeysExamined" : { "$numberDouble" : "0.0" }', 1, 0, 'g')::bson INTO explain_result;

    RETURN QUERY WITH r1 AS (SELECT explain_result AS explain_val),
        r2 AS (SELECT regexp_split_to_table(explain_val::text, ',') AS line from r1),
        r3 AS ( SELECT row_number() over () as rn, line FROM r2)
        SELECT STRING_AGG(line, ',' ORDER BY rn ASC) || ',' FROM r3 GROUP BY round(rn / 4);
 END;
 $$ LANGUAGE plpgsql;

-- basic invalid inputs on spec.
SELECT documentdb_test_helpers.documentdb_explain('{}'::bson);
SELECT documentdb_test_helpers.documentdb_explain('{ "$db": "expdb" }'::bson);
SELECT documentdb_test_helpers.documentdb_explain('{ "explain": { "find": "foo" } }'::bson);
SELECT documentdb_test_helpers.documentdb_explain('{ "explain": { "find": "foo" }, "$db": "expdb" }'::bson);
SELECT documentdb_test_helpers.documentdb_explain('{ "explain": { "find": "foo" }, "verbosity": "queryPlanner" }'::bson);
SELECT documentdb_test_helpers.documentdb_explain('{ "explain": { "find": "foo" },  "$db": "expdb", "verbosity": "queryPlannerInvalid" }'::bson);

-- test find (with multiple combos) on non-existent collection.
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent" }, "$db": "expdb", "verbosity": "queryPlanner" }'::bson);
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent" }, "$db": "expdb", "verbosity": "executionStats" }'::bson);
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent", "limit": 1 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent", "limit": 1, "skip": 1 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent", "sort": { "a": 1 }, "limit": 1, "skip": 1 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent", "filter": { "b": { "$gt": 1 } }, "sort": { "a": 1 }, "limit": 1, "skip": 1 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);

-- last one with all options
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent", "projection": { "c": 1 }, "filter": { "b": { "$gt": 1 } }, "sort": { "a": 1 }, "limit": 1, "skip": 1 }, "$db": "expdb", "verbosity": "queryPlanner" }'::bson);
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "nonexistent", "projection": { "c": 1 }, "filter": { "b": { "$gt": 1 } }, "sort": { "a": 1 }, "limit": 1, "skip": 1 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);

-- now do the same with a simple COLLSCAN (runtime scan) on a collection that exists.
SELECT documentdb_api.insert_one('expdb', 'coll1', '{ "_id": 1, "a": 1, "b": 2 }');
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "coll1", "projection": { "c": 1 }, "filter": { "b": { "$gt": 1 } }, "sort": { "a": 1 }, "limit": 1, "skip": 1 }, "$db": "expdb", "verbosity": "queryPlanner" }'::bson);
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "coll1", "projection": { "c": 1 }, "filter": { "b": { "$gt": 1 } }, "sort": { "a": 1 }, "limit": 1, "skip": 1 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);

-- sort on the index (_id index)
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "coll1", "projection": { "c": 1 }, "filter": { "_id": { "$gt": 1 } }, "sort": { "_id": -1 }, "limit": 2 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);

-- incremental sort on the index (_id index)
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "coll1", "projection": { "c": 1 }, "filter": { "_id": { "$gt": 1 } }, "sort": { "_id": 1, "b": 1 }, "limit": 2 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);

-- now do with a RUM index.
SELECT documentdb_api_internal.create_indexes_non_concurrently('expdb', '{ "createIndexes": "coll1", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1" } ] }'::bson, TRUE);

set enable_seqscan to off;
set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "coll1", "projection": { "c": 1 }, "filter": { "a": { "$gt": 1 }, "d": 1 }, "limit": 2 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);

-- cannot test sort pushdown here (or Idxos)
SELECT documentdb_test_helpers.explain_and_mask_numbers('{ "explain": { "find": "coll1", "projection": { "c": 1 }, "filter": { "a": { "$gt": 1 }, "d": 1 }, "sort": { "a": 1, "d": 1 }, "limit": 2 }, "$db": "expdb", "verbosity": "executionStats" }'::bson);
