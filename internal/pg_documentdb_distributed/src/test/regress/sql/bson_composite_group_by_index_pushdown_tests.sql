SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 860000;
SET documentdb.next_collection_id TO 8600;
SET documentdb.next_collection_index_id TO 8600;

-- enableGroupByDistinctScan and enableDistinctScanForGroupFirst are enabled by
-- default starting in v116. Pin them off here so this suite keeps exercising the
-- non-distinct-scan plan shapes. Remove these pins when the flags are retired.
SET documentdb.enableGroupByDistinctScan TO off;
SET documentdb.enableDistinctScanForGroupFirst TO off;


-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

set documentdb.defaultUseCompositeOpClass to on;
set documentdb.enableGroupByCompoundIdIndexPushdown to on;
set documentdb_core.enableWriteDocumentsInRepath to on;
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'group_idx_db', '{ "createIndexes": "group_push", "indexes": [ { "name": "a_1", "key": { "a": 1 } }, { "name": "b_c_1", "key": { "b": 1, "c": 1 } } ] }', TRUE);

SELECT COUNT(documentdb_api.insert_one('group_idx_db', 'group_push', bson_build_document('_id', i, 'a', i % 100, 'b', i % 10, 'c', i) )) FROM generate_series(1, 1000) AS i;

ANALYZE documentdb_data.documents_8601;

set enable_seqscan to off;
set enable_bitmapscan to off;

-- push basic group to the index.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- works with filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "a": { "$exists": true } } }, { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');

-- works with suffix filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

-- equality with group suffix works.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": 10 } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }');


---------------------------------------------------------------------------------------------------
-- accumulator coverage: $push and $addToSet
-- covered field: the plan should use an Index Only Scan
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "items": { "$push": "$a" } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "items": { "$addToSet": "$a" } } } ] }');

-- uncovered accumulator field: $push/$addToSet reference $b which is not in a_1;
-- the plan should fall back to a regular Index Scan.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "items": { "$push": "$b" } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "items": { "$addToSet": "$b" } } } ] }');

---------------------------------------------------------------------------------------------------
-- system-variable accumulator: $$ROOT references the full document, so the plan should not use IOS.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "r": { "$first": "$$ROOT" } } } ] }');

---------------------------------------------------------------------------------------------------
-- single-field document _id pushdown
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b" }, "count": { "$sum": 1 } } } ] }');

-- single-field document _id accumulator coverage: $push and $addToSet
-- covered field: accumulator references field in a_1 index → Index Only Scan
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "items": { "$push": "$a" } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "items": { "$addToSet": "$a" } } } ] }');

-- uncovered accumulator field: $b is not in a_1 → Index Scan
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "items": { "$push": "$b" } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "items": { "$addToSet": "$b" } } } ] }');

-- multi-field document _id pushdown
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-- multi-field with non-indexed field in _id
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "d": "$d" }, "total": { "$sum": "$a" } } } ] }');

-- same with filters
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');

-- multi-field with nested document path
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "total": { "$sum": "$a" } } } ] }');

-- multi-field with multiple accumulators
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 }, "maxA": { "$max": "$a" } } } ] }');

---------------------------------------------------------------------------------------------------
-- compound document _id accumulator coverage: $push and $addToSet
-- covered field: all _id and accumulator fields in b_c_1 index → Index Only Scan
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "items": { "$push": "$b" } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "items": { "$addToSet": "$c" } } } ] }');

-- uncovered accumulator field: $push/$addToSet reference $a which is not in b_c_1;
-- the plan should fall back to a regular Index Scan.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "items": { "$push": "$a" } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "items": { "$addToSet": "$a" } } } ] }');

-----------------------------------------------------------------------------------------------------
-- EDGE CASE: no accumulators at all
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" } } } ] }');

-- EDGE CASE: many accumulators
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "cnt": { "$sum": 1 }, "mx": { "$max": "$a" }, "mn": { "$min": "$a" }, "av": { "$avg": "$a" } } } ] }');

-- EDGE CASE: accumulator references grouped field (was the original bug)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } } ] }');

-- EDGE CASE: GUC off - should NOT decompose
SET documentdb.enableGroupByCompoundIdIndexPushdown TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }');
SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;

-----------------------------------------------------------------------------------------------------
-- these don't work:
-- does not work with inequality prefix
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": { "$exists": true } } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }');

-- $$variable expression in _id field should not decompose.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "offset": "$$myVar" }, "count": { "$sum": 1 } } } ], "let": { "myVar": 42 } }');

BEGIN;
set citus.enable_local_execution to off;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local enable_seqscan to off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "offset": "$$myVar" }, "count": { "$sum": 1 } } } ], "let": { "myVar": 42 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } } ] }');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "max_b": { "$max": "$b" }, "sum_c": { "$sum": "$c" } } } ] }');
ROLLBACK;

-- insert an array breaks pushdown
SELECT documentdb_api.insert_one('group_idx_db', 'group_push', '{ "_id": 1001, "a": [ 1, 2, 3 ], "b": [ 1, 2, 3 ], "c": 1 }' );

-- can no longer push down.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }');

TRUNCATE documentdb_data.documents_8601;
SELECT COUNT(documentdb_api.insert_one('group_idx_db', 'group_push', bson_build_document('_id', i, 'a', i % 100, 'b', i % 10, 'c', i) )) FROM generate_series(1, 1000) AS i;

-----------------------------------------------------------------------------------------------------
-- Group by $_id (the document's own _id field)
-----------------------------------------------------------------------------------------------------

-- basic group by $_id with constant accumulator
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$_id", "total": { "$sum": 1 } } } ] }');

-- group by $_id with field accumulator
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$_id", "total": { "$sum": "$a" } } } ] }');

-- group by $_id with multiple accumulators
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$_id", "cnt": { "$sum": 1 }, "mx": { "$max": "$a" }, "mn": { "$min": "$b" } } } ] }');

-----------------------------------------------------------------------------------------------------
-- Document _id with $_id as a sub-field
-----------------------------------------------------------------------------------------------------

-- single-field document _id wrapping $_id
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "docId": "$_id" }, "count": { "$sum": 1 } } } ] }');

-- composite document _id mixing $_id and another field
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "docId": "$_id", "a": "$a" }, "count": { "$sum": 1 } } } ] }');

-- composite document _id mixing $_id and indexed fields
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "docId": "$_id", "b": "$b", "c": "$c" }, "total": { "$sum": "$a" } } } ] }');

-----------------------------------------------------------------------------------------------------
-- Compound index with _id as prefix: index on { _id: 1, a: 1 }
-----------------------------------------------------------------------------------------------------

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'group_idx_db', '{ "createIndexes": "group_push", "indexes": [ { "name": "id_a_1", "key": { "_id": 1, "a": 1 } } ] }', TRUE);

-- group by $_id should be able to use the _id+a compound index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$_id", "total": { "$sum": 1 } } } ] }');

-- group by $_id with accumulator on the suffix field "a"
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$_id", "total": { "$sum": "$a" } } } ] }');

-- compound document _id with both fields from the _id+a index
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "docId": "$_id", "a": "$a" }, "count": { "$sum": 1 } } } ] }');

-- group by $a alone — _id+a index can still help if _id prefix is covered
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }');

-----------------------------------------------------------------------------------------------------
-- shard and try again
SELECT documentdb_api.shard_collection('{ "shardCollection": "group_idx_db.group_push", "key": { "_id": "hashed" } }');

-- the ones that work should work
BEGIN;
set local enable_seqscan to off;
set enable_bitmapscan to off;
set citus.enable_local_execution to off;
set local enable_hashagg to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }')$$);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }')$$);

-- works with filters
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "a": { "$exists": true } } }, { "$group": { "_id": "$a", "count": { "$sum": 1 } } } ] }')$$);

-- works with suffix filters
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "c": { "$exists": true } } }, { "$group": { "_id": "$b", "count": { "$sum": 1 } } } ] }')$$);

-- equality with group suffix works.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "b": 10 } }, { "$group": { "_id": "$c", "count": { "$sum": 1 } } } ] }')$$);

---------------------------------------------------------------------------------------------------
-- single-field document _id pushdown (sharded)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "a": "$a" }, "count": { "$sum": 1 } } } ] }')$$);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b" }, "count": { "$sum": 1 } } } ] }')$$);

-- multi-field document _id pushdown (sharded)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "$c" }, "count": { "$sum": 1 } } } ] }')$$);

---------------------------------------------------------------------------------------------------
-- dotted path: _id fields use dotted paths.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "x": "$b.nested", "y": "$c.nested" }, "count": { "$sum": 1 } } } ] }')$$);

-- expression in _id field: not a simple $path, should NOT decompose
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": { "$add": ["$b", 1] }, "c": "$c" }, "count": { "$sum": 1 } } } ] }')$$);

-- mixed: one field is $path, one is constant expression, should NOT decompose
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "b": "$b", "c": "constant" }, "count": { "$sum": 1 } } } ] }')$$);

---------------------------------------------------------------------------------------------------
-- sharded: group by $_id tests
---------------------------------------------------------------------------------------------------

-- sharded: scalar $_id with constant accumulator
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$_id", "total": { "$sum": 1 } } } ] }')$$);

-- sharded: scalar $_id with field accumulator
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": "$_id", "total": { "$sum": "$a" } } } ] }')$$);

-- sharded: single-field doc _id wrapping $_id
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "docId": "$_id" }, "count": { "$sum": 1 } } } ] }')$$);

-- sharded: composite doc _id mixing $_id and another field
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": { "docId": "$_id", "a": "$a" }, "count": { "$sum": 1 } } } ] }')$$);

-- sharded: $_id with $match filter
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$match": { "a": { "$lt": 5 } } }, { "$group": { "_id": "$_id", "total": { "$sum": 1 } } } ] }')$$);

ROLLBACK;

---------------------------------------------------------------------------------------------------
-- scalar-aggregate index pushdown (constant _id, e.g. _id: null) sanity on the
-- sharded group_push collection.  A constant _id plan shape is
-- PG-version-specific, so this focuses on cross-shard correctness: the pushdown
-- must return the same aggregate as the non-pushdown scan.
---------------------------------------------------------------------------------------------------
BEGIN;
set local citus.enable_local_execution to off;
set local enable_seqscan to off;
set local enable_bitmapscan to off;

-- pushdown ON: aggregate the whole (sharded) collection into one group via the
-- covering index (a = i % 100 over 1..1000 -> total 49500, cnt 1000).
set local documentdb.enable_scalar_aggregate_index_pushdown to on;
SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": null, "total": { "$sum": "$a" }, "cnt": { "$sum": 1 } } } ] }');

-- EXPLAIN coverage: the full sharded plan shows the pushdown engaged on every
-- shard -- a per-shard GroupAggregate fed by an Index Only Scan on a_1 with the
-- fullScan index condition.  A constant _id emits a shard-level
-- "Group Key: '{ "" : null }'" line on PG15 but not PG16, so that one line is
-- filtered out to keep a single baseline across supported versions; WITH
-- ORDINALITY preserves the plan-line order.
SELECT plan_line
FROM documentdb_distributed_test_helpers.run_explain_and_trim($$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('group_idx_db', '{ "aggregate": "group_push", "pipeline": [ { "$group": { "_id": null, "total": { "$sum": "$a" } } } ] }')$$) WITH ORDINALITY AS t(plan_line, ord)
WHERE plan_line NOT LIKE '%Group Key: ''{ "" : null }''%'
ORDER BY ord;
ROLLBACK;
