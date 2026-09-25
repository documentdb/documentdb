-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

SET documentdb.next_collection_id TO 21400;
SET documentdb.next_collection_index_id TO 21400;

-- ================================================================
-- $group over a $sort whose trailing key opposes the index direction.
--
-- Group-key bounds must agree with the physical index scan selected for the
-- trailing sort key, including when it requires a backward scan.
-- forceDisableSeqScan keeps these cases on index paths.
--
-- $group does not guarantee result order. Materialize each grouping pipeline
-- before sorting its output so normalization cannot change the plan under test.
-- ================================================================

SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.forceDisableSeqScan TO on;

SELECT COUNT(documentdb_api.insert_one('db', 'grp_mixed_dir', bson_build_document(
    '_id', i,
    'a', concat('a_', (i % 4)::text),
    'b', concat('b_', (i % 3)::text),
    'c', i
))) FROM generate_series(1, 400) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{ "createIndexes": "grp_mixed_dir", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "enableCompositeTerm": true, "name": "idx_a_b_c" } ] }',
    true);

ANALYZE;

-- ----------------------------------------------------------------
-- 1. Ascending prefix group keys with a descending trailing sort key.
-- ----------------------------------------------------------------
WITH result AS MATERIALIZED (
    SELECT document FROM bson_aggregation_pipeline('db',
        '{ "aggregate": "grp_mixed_dir", "pipeline": [
            { "$sort": { "a": 1, "b": 1, "c": -1 } },
            { "$group": { "_id": { "a": "$a", "b": "$b" }, "latest": { "$first": "$$ROOT" } } }
        ], "cursor": {} }')
)
SELECT document FROM result ORDER BY document;

-- ----------------------------------------------------------------
-- 2. Same shape with a single-field group key.
-- ----------------------------------------------------------------
WITH result AS MATERIALIZED (
    SELECT document FROM bson_aggregation_pipeline('db',
        '{ "aggregate": "grp_mixed_dir", "pipeline": [
            { "$sort": { "a": 1, "c": -1 } },
            { "$group": { "_id": { "a": "$a" }, "latest": { "$first": "$$ROOT" } } }
        ], "cursor": {} }')
)
SELECT document FROM result ORDER BY document;

-- ----------------------------------------------------------------
-- 3. Control: the sort direction matches the index throughout, so the
--    operator class and the physical scan agree.
-- ----------------------------------------------------------------
WITH result AS MATERIALIZED (
    SELECT document FROM bson_aggregation_pipeline('db',
        '{ "aggregate": "grp_mixed_dir", "pipeline": [
            { "$sort": { "a": 1, "b": 1, "c": 1 } },
            { "$group": { "_id": { "a": "$a", "b": "$b" }, "latest": { "$first": "$c" } } }
        ], "cursor": {} }')
)
SELECT document FROM result ORDER BY document;

-- ----------------------------------------------------------------
-- 4. Control: the descending trailing key on its own is fine without
--    $group, which pins the conflict to the group-key bounds rather
--    than to the descending sort by itself.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "grp_mixed_dir", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": -1 } },
        { "$limit": 3 },
        { "$project": { "_id": 1 } }
    ], "cursor": {} }');

RESET documentdb.forceDisableSeqScan;

-- Cleanup
SELECT documentdb_api.drop_collection('db', 'grp_mixed_dir');
