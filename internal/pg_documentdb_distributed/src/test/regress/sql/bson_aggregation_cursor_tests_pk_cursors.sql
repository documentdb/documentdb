SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, public;
SET documentdb.next_collection_id TO 400;
SET documentdb.next_collection_index_id TO 400;
SET citus.next_shard_id TO 40000;

set documentdb.enablePrimaryKeyCursorScan to on;
set documentdb.enableCursorPlanBeforeRestrictionPathUpdate to off;

-- insert 10 documents - but insert the _id as reverse order of insertion order (so that TID and insert order do not match)
DO $$
DECLARE i int;
BEGIN
FOR i IN 1..10 LOOP
PERFORM documentdb_api.insert_one('pkcursordb', 'aggregation_cursor_pk', FORMAT('{ "_id": %s, "sk": %s, "a": "%s", "c": [ %s "d" ] }',  10-i , mod(i, 2), repeat('Sample', 10), repeat('"' || repeat('a', 10) || '", ', 5))::documentdb_core.bson);
END LOOP;
END;
$$;

PREPARE drain_find_query(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation FROM find_cursor_first_page(database => 'pkcursordb', commandSpec => $1, cursorId => 534)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation FROM cte, cursor_get_more(database => 'pkcursordb', getMoreSpec => $2, continuationSpec => cte.continuation) gm
            WHERE cte.continuation IS NOT NULL
    )
    SELECT * FROM cte);

PREPARE drain_find_query_continuation(bson, bson) AS
    (WITH RECURSIVE cte AS (
        SELECT cursorPage, continuation FROM find_cursor_first_page(database => 'pkcursordb', commandSpec => $1, cursorId => 534)
        UNION ALL
        SELECT gm.cursorPage, gm.continuation FROM cte, cursor_get_more(database => 'pkcursordb', getMoreSpec => $2, continuationSpec => cte.continuation) gm
            WHERE cte.continuation IS NOT NULL
    )
    SELECT bson_dollar_project(cursorPage, '{"firstBatchLength": { "$size": { "$ifNull": ["$cursor.firstBatch", []]}}, "nextBatchLength": { "$size": { "$ifNull": ["$cursor.nextBatch", []]}}}'), continuation FROM cte);

-- Validates that every string in expected_index_conds appears as a substring of
-- an "Index Cond:" line and every string in expected_filters appears as a
-- substring of a "Filter:" line in the EXPLAIN output.
CREATE OR REPLACE FUNCTION check_explain_index_and_filter(
    explain_lines text[],
    expected_index_conds text[] DEFAULT NULL,
    expected_filters text[] DEFAULT NULL
) RETURNS boolean AS $$
DECLARE
    line text;
    cond text;
    index_cond_line text := '';
    filter_line text := '';
    has_custom_scan boolean := false;
    has_continuation boolean := false;
    pg_major int;
    saop_cond text := 'collection.object_id = ANY (';
BEGIN
    pg_major := current_setting('server_version_num')::int / 10000;
    IF pg_major <= 16 THEN
        expected_filters := array_append(COALESCE(expected_filters, '{}'), saop_cond);
    ELSE
        expected_index_conds := array_append(COALESCE(expected_index_conds, '{}'), saop_cond);
    END IF;

    FOREACH line IN ARRAY explain_lines LOOP
        IF trim(line) LIKE 'Index Cond:%' THEN
            index_cond_line := line;
        ELSIF trim(line) LIKE 'Filter:%' THEN
            filter_line := line;
        END IF;
        IF position('Custom Scan (DocumentDBApiScan)' IN line) > 0 THEN
            has_custom_scan := true;
        END IF;
        IF position('Continuation: { "table_name" : "documents_403_40020"' IN line) > 0 THEN
            has_continuation := true;
        END IF;
    END LOOP;

    IF NOT has_custom_scan OR NOT has_continuation THEN
        RAISE NOTICE 'FAIL: has_custom_scan=%, has_continuation=%', has_custom_scan, has_continuation;
        RETURN false;
    END IF;

    IF expected_index_conds IS NOT NULL THEN
        FOREACH cond IN ARRAY expected_index_conds LOOP
            IF position(cond IN index_cond_line) = 0 THEN
                RAISE NOTICE 'FAIL index_cond: looking for "%" in "%"', cond, index_cond_line;
                RETURN false;
            END IF;
        END LOOP;
    END IF;

    IF expected_filters IS NOT NULL THEN
        FOREACH cond IN ARRAY expected_filters LOOP
            IF position(cond IN filter_line) = 0 THEN
                RAISE NOTICE 'FAIL filter: looking for "%" in "%"', cond, filter_line;
                RETURN false;
            END IF;
        END LOOP;
    END IF;

    RETURN true;
END;
$$ LANGUAGE plpgsql;

-- create an index to force non HOT path
SELECT documentdb_api_internal.create_indexes_non_concurrently('pkcursordb', '{"createIndexes": "aggregation_cursor_pk", "indexes": [{"key": {"a": 1}, "name": "a_1" }]}', TRUE);

-- create a streaming cursor (that doesn't drain)
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk", "batchSize": 5 }', cursorId => 4294967294);

SELECT * FROM firstPageResponse;

-- now drain it
SELECT continuation AS r1_continuation FROM firstPageResponse \gset
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation FROM
    cursor_get_more(database => 'pkcursordb', getMoreSpec => '{ "collection": "aggregation_cursor_pk", "getMore": 4294967294, "batchSize": 6 }', continuationSpec => :'r1_continuation');

-- drain with batchsize of 1 - continuation _ids should increase until it drains: uses pk scan continuation tokens
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 1 }');

-- drain with batchsize of 1 - with the GUC disabled, it should be returned in reverse (TID) order
set documentdb.enablePrimaryKeyCursorScan to off;
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 1 }');

set documentdb.enablePrimaryKeyCursorScan to on;

-- the query honors filters in continuations.
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 3, "$lt": 8 }}, "batchSize": 1 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 1 }');

-- if a query picks a pk index scan on the first page, the second page is guaranteed to pick it:
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk",  "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 3, "$lt": 8 }}, "batchSize": 2 }', cursorId => 4294967294);

SELECT * FROM firstPageResponse;

-- disable these to ensure we pick seqscan as the default path.
set enable_indexscan to off;
set enable_bitmapscan to off;

-- now drain it partially
SELECT continuation AS r1_continuation FROM firstPageResponse \gset
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation FROM
    cursor_get_more(database => 'pkcursordb', getMoreSpec => '{ "collection": "aggregation_cursor_pk", "getMore": 4294967294, "batchSize": 1 }', continuationSpec => :'r1_continuation');

-- drain it fully
SELECT bson_dollar_project(cursorpage, '{ "cursor.nextBatch._id": 1, "cursor.id": 1 }'), continuation FROM
    cursor_get_more(database => 'pkcursordb', getMoreSpec => '{ "collection": "aggregation_cursor_pk", "getMore": 4294967294, "batchSize": 5 }', continuationSpec => :'r1_continuation');

-- explain the first query (should be an index scan on the pk index)
set documentdb.enableCursorsOnAggregationQueryRewrite to on;
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 3, "$lt": 8 }}, "batchSize": 1 }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "batchSize": 1 }');

-- the getmore should still work and use the _id index
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk", "batchSize": 1 }', :'r1_continuation');

set enable_indexscan to on;
set enable_bitmapscan to on;
set enable_seqscan to off;

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 3, "$lt": 8 }}, "batchSize": 1 }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "batchSize": 1 }');

-- the getmore should still work and use the _id index
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk", "batchSize": 1 }', :'r1_continuation');


-- shard the collection
SELECT documentdb_api.shard_collection('{ "shardCollection": "pkcursordb.aggregation_cursor_pk", "key": { "_id": "hashed" }, "numInitialChunks": 3 }');

-- now this walks in order of shard-key THEN _id.
BEGIN;
set local enable_seqscan to on;
set local enable_indexscan to off;
set local enable_bitmapscan to off;
set local documentdb.enablePrimaryKeyCursorScan to on;
set local citus.max_adaptive_executor_pool_size to 1;
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 2 }');

-- continues to work with filters
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 2, "$lt": 8 } }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 2 }');
ROLLBACK;

BEGIN;
set local documentdb.enablePrimaryKeyCursorScan to on;
set local citus.max_adaptive_executor_pool_size to 1;
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 2 }');

-- continues to work with filters
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": 2, "$lt": 8 } }, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 2 }');
EXECUTE drain_find_query('{ "find": "aggregation_cursor_pk", "projection": { "_id": 1 }, "filter": {"sk": {"$exists": true}}, "batchSize": 2 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk", "batchSize": 2 }');
ROLLBACK;


-- we create a contrived scenario where we create _ids that are ~100b each and insert 1000 docs in there. This will ensure that
-- we have many pages to scan for the _id.
DO $$
DECLARE i int;
BEGIN
FOR i IN 1..1000 LOOP
PERFORM documentdb_api.insert_one('pkcursordb', 'aggregation_cursor_pk_sk2', FORMAT('{ "_id": "%s%s%s", "sk": "skval", "a": "aval", "c": [ "c", "d" ] }', CASE WHEN i >= 10 AND i < 100 THEN '0' WHEN i < 10 THEN '00' ELSE '' END, i, repeat('a', 100))::documentdb_core.bson);
END LOOP;
END;
$$;
DROP TABLE firstPageResponse;

CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002", "$lt": "015" } }, "batchSize": 2  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- run the query once, this also fills the buffers and validates the index qual
EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');

-- now rerun with buffers on (there should be no I/O but it should only load as many index pages as we want rows in the shared hit)
EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS ON, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');


-- let's shard and now test with different combinations where we the shard key is on the primary key index and where it is not, or a compound shard key with _id + another field.
SELECT documentdb_api.shard_collection('{ "shardCollection": "pkcursordb.aggregation_cursor_pk_sk2", "key": { "_id": "hashed" }, "numInitialChunks": 5 }');

BEGIN;
set citus.propagate_set_commands to 'local';
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;
set local citus.explain_analyze_sort_method to taskId;
set local documentdb.enablePrimaryKeyCursorScan to on;

-- shard key is _id so range queries should still do bitmap heap scan on the RUM index since we don't have a shard_key filter.
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002", "$lt": "015" } }, "batchSize": 2  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

SHOW documentdb.enablePrimaryKeyCursorScan;

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002", "$lt": "015" }}, "batchSize": 2 }');

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');

-- equality on another field that doesn't have an index should use pk index scan
EXECUTE drain_find_query_continuation('{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "sk": "skval" }, "batchSize": 1 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 500 }');

DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }') as cp, continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "sk": "skval" }, "batchSize": 3  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

SELECT cp, continuation FROM firstPageResponse;

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "sk": "skval" },  "batchSize": 1 }');

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');

-- TODO: optimization, $in on shard_key could also use primary key index.
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$in":  [ "003aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "002aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]} }, "batchSize": 1  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$in":  [ "003aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "002aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]}}, "batchSize": 1 }');

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');
END;

-- unshard and shard with a shard key that is not the primary key
SELECT documentdb_api.unshard_collection('{"unshardCollection": "pkcursordb.aggregation_cursor_pk_sk2" }');
SELECT documentdb_api.shard_collection('{ "shardCollection": "pkcursordb.aggregation_cursor_pk_sk2", "key": { "sk": "hashed" }, "numInitialChunks": 5 }');

BEGIN;
set citus.propagate_set_commands to 'local';
set local citus.max_adaptive_executor_pool_size to 1;
set local citus.enable_local_execution to off;
set local citus.explain_analyze_sort_method to taskId;
set local documentdb.enablePrimaryKeyCursorScan to on;

-- range queries on _id with shard_key equality should use pk index scan
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002" }, "sk": "skval" }, "batchSize": 2  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002" }, "sk": "skval" }, "batchSize": 2 }');

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');

-- test draining the query
EXECUTE drain_find_query_continuation('{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002" }, "sk": "skval" }, "batchSize": 1 }', '{ "getMore": { "$numberLong": "534" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 500 }');

-- TODO: optimization, range queries on _id + shard_key_filter should also use primary key index, it currently uses the RUM _id index with the @<> range operator.
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002", "$lt": "015" }, "sk": "skval" }, "batchSize": 2  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "_id": { "$gt": "002", "$lt": "015" }, "sk": "skval" }, "batchSize": 2 }');

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');

-- equality on the shard key since we don't have an index on it should do primary key scan
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "sk": "skval" }, "batchSize": 2  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "sk": "skval" }, "batchSize": 2 }');

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');

-- TODO: optimization, $in on shard_key could also use primary key index instead of bitmap scan on RUM.
DROP TABLE firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM
    find_cursor_first_page(database => 'pkcursordb', commandSpec => '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "sk": { "$in": [ "skval", "skval2", "skval3" ] } }, "batchSize": 2  }', cursorId => 4294967294);

SELECT continuation AS r1_continuation FROM firstPageResponse \gset

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('pkcursordb', '{ "find": "aggregation_cursor_pk_sk2", "projection": { "_id": 1 }, "filter": { "sk": { "$in": [ "skval", "skval2", "skval3" ] } }, "batchSize": 2 }');

EXPLAIN (VERBOSE OFF, COSTS OFF, BUFFERS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_sk2", "batchSize": 2 }', :'r1_continuation');
END;

-- Test: large $in filter  with pk cursor scan
-- Insert 100 documents with string _ids (a1..a100); the $in will reference random values from a1..a100
DO $$
DECLARE i int;
BEGIN
FOR i IN 1..100 LOOP
PERFORM documentdb_api.insert_one('pkcursordb', 'aggregation_cursor_pk_in', FORMAT('{ "_id": "a%s", "val": %s }', i, i)::documentdb_core.bson);
END LOOP;
END;
$$;

CREATE SCHEMA IF NOT EXISTS pm_temp_in;
-- helper: builds a find command spec with a $in filter of N values (a1, a2, ..., aN)
CREATE OR REPLACE FUNCTION pm_temp_in.make_in_find(n int, batch int) RETURNS documentdb_core.bson AS $$
SELECT FORMAT('{ "find": "aggregation_cursor_pk_in", "projection": { "_id": 1 }, "filter": { "_id": { "$in": [ %s ] } }, "limit": %s }',
    string_agg('"a' || v || '"', ', '), batch)::documentdb_core.bson
FROM generate_series(1, n) AS v;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pm_temp_in.make_in_continuation(n int, batch int) RETURNS documentdb_core.bson AS $$
SELECT FORMAT('{ "find": "aggregation_cursor_pk_in", "projection": { "_id": 1 }, "filter": { "_id": { "$in": [ %s ] } }, "batchSize": %s }',
    string_agg('"a' || v || '"', ', '), batch)::documentdb_core.bson
FROM generate_series(1, n) AS v;
$$ LANGUAGE sql;

-- first page: find with large $in (10 values), small batchSize to force cursor
DROP TABLE IF EXISTS firstPageResponse;
CREATE TEMP TABLE firstPageResponse AS
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid FROM 
    find_cursor_first_page(database => 'pkcursordb', commandSpec => pm_temp_in.make_in_continuation(10, 5), cursorId => 4294967294);

SELECT * FROM firstPageResponse;
SELECT continuation AS r1_continuation FROM firstPageResponse \gset

-- enablePrimaryKeyCursorScan = off, enableCursorPlanBeforeRestrictionPathUpdate = off
-- The explain below should show bitmap index scan
set documentdb.enablePrimaryKeyCursorScan to off;
set documentdb.enableCursorPlanBeforeRestrictionPathUpdate to off;

SELECT pm_temp_in.make_in_find(10, 5) AS in_spec \gset
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('pkcursordb', :'in_spec');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_in", "batchSize": 5 }', :'r1_continuation');

-- enablePrimaryKeyCursorScan = on, enableCursorPlanBeforeRestrictionPathUpdate = off
-- The explain below should show primary key scan, but $in is not pushed to the index so it will still filter a lot of rows
set documentdb.enablePrimaryKeyCursorScan to on;

SELECT pm_temp_in.make_in_find(10, 5) AS in_spec \gset

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('pkcursordb', :'in_spec');

-- On PG16 the SAOP (object_id = ANY) stays in Filter; on PG17 it moves to Index Cond.
-- Use check_explain_index_and_filter to verify version-invariant properties.
DO $check$
DECLARE
    lines text[];
    line text;
    cont text;
    result boolean;
BEGIN
    SELECT continuation::text INTO cont FROM firstPageResponse;
    FOR line IN EXECUTE format(
        'EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore(%L, %L, %L::bson)',
        'pkcursordb',
        '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_in", "batchSize": 5 }',
        cont
    ) LOOP
        lines := array_append(lines, line);
    END LOOP;
    SELECT check_explain_index_and_filter(
        lines,
        ARRAY['collection.shard_key_value = ''403''::bigint', 'ROW(collection.shard_key_value, collection.object_id) >'],
        ARRAY['documentdb_api_internal.cursor_state(collection.document, ''{ "']
    ) INTO result;
    RAISE NOTICE 'check_explain_index_and_filter: %', result;
END;
$check$;

-- enablePrimaryKeyCursorScan = on, enableCursorPlanBeforeRestrictionPathUpdate = on
-- The explain below should show primary key scan and the $in should be pushed down to the index
set documentdb.enableCursorPlanBeforeRestrictionPathUpdate to on;

SELECT pm_temp_in.make_in_find(10, 5) AS in_spec \gset


SELECT document FROM bson_aggregation_find('pkcursordb', :'in_spec');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('pkcursordb', :'in_spec');

SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_in", "batchSize": 5 }', :'r1_continuation');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_getmore('pkcursordb',
    '{ "getMore": { "$numberLong": "4294967294" }, "collection": "aggregation_cursor_pk_in", "batchSize": 5 }', :'r1_continuation');


set documentdb.enableCursorsOnAggregationQueryRewrite to off;
