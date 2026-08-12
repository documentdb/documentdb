-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

-- A forced full-index scan must not replace the sort required across shards.
reset enable_sort;
reset documentdb_rum.forceRumOrderedIndexScan;
reset documentdb.forceDisableSeqScan;
set documentdb.enableExtendedExplainPlans to on;
SELECT documentdb_api.shard_collection('comp_ordind_db', 'forced_order_sharded', '{ "_id": "hashed" }', false);
SELECT documentdb_api.insert_one('comp_ordind_db', 'forced_order_sharded',
	FORMAT('{ "_id": %s, "a": %s }', id, value)::bson)
FROM (VALUES (1, 3), (2, 1), (3, 4), (4, 2), (5, 8), (6, 7), (7, 6), (8, 5)) AS docs(id, value);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
	'comp_ordind_db',
	'{ "createIndexes": "forced_order_sharded", "indexes": [ { "key": { "a": 1 }, "enableCompositeTerm": true, "name": "a_1" } ] }',
	true);
set documentdb_rum.forceRumOrderedIndexScan to on;
set documentdb.forceDisableSeqScan to on;
SELECT regexp_replace(
	regexp_replace(btrim(query_plan), 'documents_[0-9]+_[0-9]+', 'documents_x_x', 'g'),
	'\(actual rows=[0-9.]+ loops=[0-9]+\)', '(actual rows=xxx loops=xxx)', 'g') AS plan_line
FROM documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM bson_aggregation_find(
	'comp_ordind_db',
	'{ "find": "forced_order_sharded", "filter": {}, "projection": { "_id": 0, "a": 1 }, "sort": { "a": -1 }, "hint": { "a": 1 } }')
$cmd$) AS plan(query_plan)
WHERE query_plan ~ '^\s*Sort( \(actual rows=[0-9.]+ loops=[0-9]+\))?$'
	OR query_plan ~ '^\s*Task Count: 8$'
	OR query_plan ~ 'Index Scan using a_1'
	OR query_plan ~ 'Index Cond:.*orderByScan';
SELECT document FROM bson_aggregation_find(
	'comp_ordind_db',
	'{ "find": "forced_order_sharded", "filter": {}, "projection": { "_id": 0, "a": 1 }, "sort": { "a": -1 }, "hint": { "a": 1 } }');

-- Forced ordered scans must retain runtime rechecks for every regex predicate.
SELECT documentdb_api.insert_one(
	'comp_ordind_db',
	'forced_order_regex',
	'{ "_id": 1, "a": "prefix-middle-suffix" }');
SELECT documentdb_api.insert_one(
	'comp_ordind_db',
	'forced_order_regex',
	'{ "_id": 2, "a": "prefix-middle" }');
SELECT documentdb_api.insert_one(
	'comp_ordind_db',
	'forced_order_regex',
	'{ "_id": 3, "a": "middle-suffix" }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
	'comp_ordind_db',
	'{ "createIndexes": "forced_order_regex", "indexes": [ { "key": { "a": 1 }, "enableCompositeTerm": true, "name": "a_1" } ] }',
	true);
SELECT document FROM bson_aggregation_find(
	'comp_ordind_db',
	'{ "find": "forced_order_regex", "filter": { "$and": [ { "a": { "$regex": "^prefix" } }, { "a": { "$regex": "suffix$" } } ] }, "projection": { "_id": 1 }, "hint": { "a": 1 } }');

reset documentdb_rum.forceRumOrderedIndexScan;
reset documentdb.forceDisableSeqScan;
