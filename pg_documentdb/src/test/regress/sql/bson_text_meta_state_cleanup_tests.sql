SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 27120000;
SET documentdb.next_collection_index_id TO 27120000;

SELECT documentdb_api.create_collection('text_meta_state_db', 'docs');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'text_meta_state_db',
    '{ "createIndexes": "docs", "indexes": [ { "key": { "content": "text" }, "name": "content_text" } ] }',
    TRUE);

SELECT documentdb_api.insert_one(
    'text_meta_state_db',
    'docs',
    '{ "_id": 1, "content": "cat dog", "zero": 0 }');

-- Proof that a { $meta: "textScore" } sort no longer depends on the backend
-- global state that the leak repro below exploits. The sort is generated as an
-- explicit order-by function, __API_SCHEMA_INTERNAL_V2__.bson_orderby_meta,
-- which carries the index options and the text query as its own arguments
-- instead of reading them from a per-backend global. The query generator emits
-- the function with NULL placeholders for those two arguments, and the planner
-- fills them in when it matches the text index.
SELECT documentdb_api.create_collection('text_meta_state_db', 'ordered');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'text_meta_state_db',
    '{ "createIndexes": "ordered", "indexes": [ { "key": { "content": "text" }, "name": "content_text" } ] }',
    TRUE);

SELECT documentdb_api.insert_one('text_meta_state_db', 'ordered', '{ "_id": 10, "content": "quick" }');
SELECT documentdb_api.insert_one('text_meta_state_db', 'ordered', '{ "_id": 11, "content": "quick quick" }');
SELECT documentdb_api.insert_one('text_meta_state_db', 'ordered', '{ "_id": 12, "content": "quick quick quick" }');
SELECT documentdb_api.insert_one('text_meta_state_db', 'ordered', '{ "_id": 13, "content": "slow" }');

-- The rewritten SQL shows the ORDER BY is generated as bson_orderby_meta with
-- NULL placeholders for the index options and text query.
SELECT documentdb_api_internal.bson_get_rewritten_sql(
    'text_meta_state_db',
    '{ "aggregate": "ordered", "pipeline": [
        { "$match": { "$text": { "$search": "quick" } } },
        { "$sort": { "score": { "$meta": "textScore" } } }
    ], "cursor": {} }'::documentdb_core.bson);

-- The planned query contains the bson_orderby_meta order-by (the sort was routed
-- off the backend global onto the explicit order-by function).
SELECT documentdb_test_helpers.explain_plan_contains(
    $cmd$ SELECT document FROM bson_aggregation_pipeline('text_meta_state_db',
        '{ "aggregate": "ordered", "pipeline": [
            { "$match": { "$text": { "$search": "quick" } } },
            { "$sort": { "score": { "$meta": "textScore" } } }
        ] }') $cmd$,
    'bson_orderby_meta') AS uses_bson_orderby_meta;

-- The planner resolved the placeholders: neither the index options (bytea) nor
-- the text query (tsquery) argument is left NULL in the plan.
SELECT documentdb_test_helpers.explain_plan_contains(
    $cmd$ SELECT document FROM bson_aggregation_pipeline('text_meta_state_db',
        '{ "aggregate": "ordered", "pipeline": [
            { "$match": { "$text": { "$search": "quick" } } },
            { "$sort": { "score": { "$meta": "textScore" } } }
        ] }') $cmd$,
    'NULL::bytea') AS index_options_left_null;

SELECT documentdb_test_helpers.explain_plan_contains(
    $cmd$ SELECT document FROM bson_aggregation_pipeline('text_meta_state_db',
        '{ "aggregate": "ordered", "pipeline": [
            { "$match": { "$text": { "$search": "quick" } } },
            { "$sort": { "score": { "$meta": "textScore" } } }
        ] }') $cmd$,
    'NULL::tsquery') AS query_left_null;

-- End to end: the sort returns documents ordered by descending text score. If
-- the planner had not resolved the arguments the order-by would raise error
-- 40218 ("text score metadata unavailable") at execution instead.
SELECT document
FROM bson_aggregation_pipeline(
    'text_meta_state_db',
    '{ "aggregate": "ordered", "pipeline": [
        { "$match": { "$text": { "$search": "quick" } } },
        { "$sort": { "score": { "$meta": "textScore" } } },
        { "$project": { "content": 1, "score": { "$meta": "textScore" } } }
    ] }');

-- Regression guard for the text-query state leak. A text query registers
-- per-statement state that a backend-global pointer refers to for the duration
-- of execution. That pointer is cleared when the custom scan finishes cleanly.
-- Here the statement aborts mid-execution (runtime divide-by-zero in the
-- projection), so the scan's own cleanup never runs and, without the fix, the
-- global would keep pointing at the aborted statement's per-query memory, which
-- is then freed on abort. The transaction abort callback now clears the pointer,
-- so the dangling reference cannot survive the aborted statement.
SELECT document
FROM bson_aggregation_pipeline(
    'text_meta_state_db',
    '{ "aggregate": "docs", "pipeline": [
        { "$match": { "$text": { "$search": "cat" } } },
        { "$project": { "value": { "$divide": [1, "$zero"] } } }
    ] }');

-- Churn to reuse the aborted statement's freed per-query memory. Before the fix
-- this turned a stale-but-intact read into a wild-pointer read; with the pointer
-- cleared on abort it has no effect on the query below.
SELECT count(*) FROM (SELECT md5(g::text) FROM generate_series(1, 50000) g) t;

-- A later statement with no text predicate asks for text-score metadata. Because
-- the abort callback cleared the global, the read finds no text query state and
-- returns the "text score metadata unavailable" error (40218) instead of
-- dereferencing freed memory. Before the fix this crashed the backend (SIGSEGV),
-- or under AddressSanitizer reported a heap-use-after-free at
-- bson_text_gin.c EvaluateMetaTextScore.
SELECT document
FROM bson_aggregation_pipeline(
    'text_meta_state_db',
    '{ "aggregate": "docs", "pipeline": [
        { "$project": { "score": { "$meta": "textScore" } } }
    ] }');

-- Same leak, but the aborting text scan runs inside a subtransaction: a PL/pgSQL
-- block with an EXCEPTION handler catches the runtime divide-by-zero, so only the
-- subtransaction aborts while the outer transaction keeps running. The scan's own
-- cleanup still never runs, so the subtransaction abort callback must clear the
-- global pointer just like the top-level abort path.
DO $$
BEGIN
    PERFORM document
    FROM bson_aggregation_pipeline(
        'text_meta_state_db',
        '{ "aggregate": "docs", "pipeline": [
            { "$match": { "$text": { "$search": "cat" } } },
            { "$project": { "value": { "$divide": [1, "$zero"] } } }
        ] }');
EXCEPTION WHEN OTHERS THEN
    -- Swallow the runtime error; the subtransaction has already aborted.
    NULL;
END $$;

-- Churn to reuse the aborted subtransaction's freed per-query memory.
SELECT count(*) FROM (SELECT md5(g::text) FROM generate_series(1, 50000) g) t;

-- A later statement with no text predicate asks for text-score metadata. With the
-- subtransaction abort callback clearing the global, the read finds no text query
-- state and returns 40218 instead of dereferencing freed memory.
SELECT document
FROM bson_aggregation_pipeline(
    'text_meta_state_db',
    '{ "aggregate": "docs", "pipeline": [
        { "$project": { "score": { "$meta": "textScore" } } }
    ] }');

SELECT documentdb_api.drop_collection('text_meta_state_db', 'docs');
