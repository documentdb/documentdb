-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

SET documentdb.next_collection_id TO 21400;
SET documentdb.next_collection_index_id TO 21400;

-- ================================================================
-- $group over a $sort whose trailing key opposes the index direction.
--
-- The group keys form an ascending prefix of the composite index, so the
-- operator class resolves the index bounds to a forward scan. The trailing
-- descending sort key drives that same physical index scan backward. A single
-- index scan cannot satisfy both, so the operator class and the physical index
-- disagree on the search mode.
--
-- forceDisableSeqScan pins the index plan: with default page costs the planner
-- prefers a sequential scan plus a sort, which never reaches the conflict.
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
--    This is the failing shape.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "grp_mixed_dir", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": -1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "latest": { "$first": "$$ROOT" } } }
    ], "cursor": {} }');

-- ----------------------------------------------------------------
-- 2. Same shape with a single-field group key. The conflict does not
--    depend on the group key being compound.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "grp_mixed_dir", "pipeline": [
        { "$sort": { "a": 1, "c": -1 } },
        { "$group": { "_id": { "a": "$a" }, "latest": { "$first": "$$ROOT" } } }
    ], "cursor": {} }');

-- ----------------------------------------------------------------
-- 3. Control: the sort direction matches the index throughout, so the
--    operator class and the physical scan agree.
-- ----------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "grp_mixed_dir", "pipeline": [
        { "$sort": { "a": 1, "b": 1, "c": 1 } },
        { "$group": { "_id": { "a": "$a", "b": "$b" }, "latest": { "$first": "$c" } } }
    ], "cursor": {} }');

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
