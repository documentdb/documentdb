-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

-- Initialize the database before pinning IDs so standalone and suite runs agree.
SELECT documentdb_api.insert_one('db', 'np_gap_setup_sentinel', '{ "_id": 0 }');
SELECT documentdb_api.drop_collection('db', 'np_gap_setup_sentinel');

SET documentdb.next_collection_id TO 21500;
SET documentdb.next_collection_index_id TO 21500;

SET documentdb.enable_skip_sort_pushdown_for_non_point_equalities TO on;

-- ================================================================
-- Order-by pushdown across a gap column that carries a non-point equality.
--
-- For index (a, b, c) and sort (a, c), column b sits between two sorted
-- columns. Pushing the sort on c down is only sound when b is pinned to a
-- single index term, because c is ordered within a b term and not across b
-- terms.
--
-- An equality bound is not sufficient. Equality to null is served by the
-- range (MinKey, null] so that undefined terms match as well, which yields one
-- ordered run per term and leaves the concatenated scan output unsorted by c.
-- ProcessOrderByStatements must therefore reject the pushdown when
-- nonPointEqualityPrefixes is set for the gap column, not only when the column
-- lacks an equality.
--
-- forceDisableSeqScan and the explicit hint pin the index plan. Incremental
-- sort is disabled so the rejected-pushdown plan renders the same way on every
-- supported PostgreSQL version.
-- ================================================================

SET documentdb.defaultUseCompositeOpClass TO on;

-- ----------------------------------------------------------------
-- Equality to null on the gap column.
--
-- Documents 1 and 3 have no b, so they index under the undefined term;
-- documents 2 and 4 index under the null term. Undefined sorts before null,
-- so an unguarded pushdown emits c = 10, 30 followed by c = 5, 20.
-- ----------------------------------------------------------------
SELECT documentdb_api.insert_one('db', 'np_gap_null', '{ "_id": 1, "a": 1, "c": 10 }');
SELECT documentdb_api.insert_one('db', 'np_gap_null', '{ "_id": 2, "a": 1, "b": null, "c": 5 }');
SELECT documentdb_api.insert_one('db', 'np_gap_null', '{ "_id": 3, "a": 1, "c": 30 }');
SELECT documentdb_api.insert_one('db', 'np_gap_null', '{ "_id": 4, "a": 1, "b": null, "c": 20 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "np_gap_null", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "enableCompositeTerm": true, "name": "idx_a_b_c" } ] }',
    true);

SELECT collection_id AS null_cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'db' AND collection_name = 'np_gap_null' \gset
ANALYZE documentdb_data.documents_:null_cid;

BEGIN;
SET LOCAL documentdb.forceDisableSeqScan TO on;
SET LOCAL enable_incremental_sort TO off;

-- The index scan must carry an Order By on the a prefix only. The sort on c
-- has to be finished by a Sort node above the scan.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "np_gap_null", "filter": { "a": 1, "b": null }, "sort": { "a": 1, "c": 1 }, "hint": "idx_a_b_c" }')
$cmd$);

-- Must be ordered by c: _id 2, 1, 4, 3.
SELECT document FROM bson_aggregation_find('db',
    '{ "find": "np_gap_null", "filter": { "a": 1, "b": null }, "sort": { "a": 1, "c": 1 }, "hint": "idx_a_b_c" }');
COMMIT;

-- Same query without the index plan, as the reference ordering.
SELECT document FROM bson_aggregation_find('db',
    '{ "find": "np_gap_null", "filter": { "a": 1, "b": null }, "sort": { "a": 1, "c": 1 } }');

-- ----------------------------------------------------------------
-- Control: a single-point equality on the gap column pins b to one term, so
-- the sort on c is still pushed down and the ordering is correct.
-- ----------------------------------------------------------------
SELECT documentdb_api.insert_one('db', 'np_gap_point', '{ "_id": 1, "a": 1, "b": 7, "c": 30 }');
SELECT documentdb_api.insert_one('db', 'np_gap_point', '{ "_id": 2, "a": 1, "b": 7, "c": 10 }');
SELECT documentdb_api.insert_one('db', 'np_gap_point', '{ "_id": 3, "a": 1, "b": 8, "c": 20 }');
SELECT documentdb_api.insert_one('db', 'np_gap_point', '{ "_id": 4, "a": 1, "b": 7, "c": 5 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "np_gap_point", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "enableCompositeTerm": true, "name": "idx_a_b_c" } ] }',
    true);

SELECT collection_id AS point_cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'db' AND collection_name = 'np_gap_point' \gset
ANALYZE documentdb_data.documents_:point_cid;

BEGIN;
SET LOCAL documentdb.forceDisableSeqScan TO on;
SET LOCAL enable_incremental_sort TO off;

-- No Sort node: the index scan carries the order by on both a and c.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "np_gap_point", "filter": { "a": 1, "b": 7 }, "sort": { "a": 1, "c": 1 }, "hint": "idx_a_b_c" }')
$cmd$);

SELECT document FROM bson_aggregation_find('db',
    '{ "find": "np_gap_point", "filter": { "a": 1, "b": 7 }, "sort": { "a": 1, "c": 1 }, "hint": "idx_a_b_c" }');
COMMIT;

-- Cleanup
SELECT documentdb_api.drop_collection('db', 'np_gap_null');
SELECT documentdb_api.drop_collection('db', 'np_gap_point');
