
SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET documentdb.next_collection_id TO 86100;
SET documentdb.next_collection_index_id TO 86100;
SET documentdb.forceDisableSeqScan TO on;

-- Insert test data with string _id values for regex testing
SELECT COUNT(*) FROM (
    SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll',
        FORMAT('{ "_id": "str_%s", "a": %s }', g, g)::bson)
    FROM generate_series(1, 20) g
) i;

-- Also insert some non-string _id values to verify type filtering
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll', '{ "_id": 100, "a": 100 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll', '{ "_id": true, "a": 200 }');

-- Also insert some specific string _ids for pattern matching
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll', '{ "_id": "abc_one", "a": 21 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll', '{ "_id": "abc_two", "a": 22 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll', '{ "_id": "abd_three", "a": 23 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll', '{ "_id": "xyz_four", "a": 24 }');

-- Insert documents where _id is itself a BSON regex type.
-- These all fail because _id cannot be a regex type.
-- NOTE: If this contract ever changes to allow regex _id values, the btree and RUM
-- index pushdown logic for $regex on _id must be updated accordingly, since it
-- currently assumes _id values are never regex types when computing index bounds.
-- These regex _ids match patterns used in test queries
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll',
    '{ "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } }, "a": 30 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll',
    '{ "_id": { "$regularExpression": { "pattern": "str_1", "options": "i" } }, "a": 31 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll',
    '{ "_id": { "$regularExpression": { "pattern": "xyz", "options": "" } }, "a": 32 }');

-- These regex _ids do NOT match patterns used in test queries
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll',
    '{ "_id": { "$regularExpression": { "pattern": "^zzz", "options": "" } }, "a": 33 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_coll',
    '{ "_id": { "$regularExpression": { "pattern": "nomatch", "options": "s" } }, "a": 34 }');

-- =============================================
-- Section 1: Result verification - anchored prefix regex on _id
-- =============================================

-- ^str_ should match all str_* _ids
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^str_" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^str_" } } }');

-- ^abc should match abc_one, abc_two
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" } } }');

-- ^abc_ should match abc_one, abc_two (but not abd_three)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc_" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc_" } } }');

-- ^xyz should match xyz_four
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^xyz" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^xyz" } } }');

-- =============================================
-- Section 2: Result verification - non-anchored regex on _id
-- =============================================

-- non-anchored: "one" should match abc_one
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "one" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "one" } } }');

-- non-anchored: "str" should match all str_* ids
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "str" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "str" } } }');

-- =============================================
-- Section 3: Result verification - regex via $regularExpression (regex type)
-- =============================================

-- Regex type (BSON regex) with anchored prefix
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } } }');

-- Regex type without anchor
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "four", "options": "" } } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "four", "options": "" } } } }');

-- Regex type with case-insensitive option
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^ABC", "options": "i" } } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^ABC", "options": "i" } } } }');

-- =============================================
-- Section 4: Result verification - regex via bson_build_document ($regex operator form)
-- =============================================

-- Using bson_build_document to construct $regex operator with anchored prefix
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    bson_build_document('find', 'regex_id_coll'::text,
        'filter', bson_build_document('_id',
            bson_build_document('$regex', '^abc'::text))::bson,
        'sort', '{ "_id": 1 }'::bson)::bson);
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    bson_build_document('find', 'regex_id_coll'::text,
        'filter', bson_build_document('_id',
            bson_build_document('$regex', '^abc'::text))::bson)::bson);

-- Using bson_build_document to construct $regex operator without anchor
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    bson_build_document('find', 'regex_id_coll'::text,
        'filter', bson_build_document('_id',
            bson_build_document('$regex', 'three'::text))::bson,
        'sort', '{ "_id": 1 }'::bson)::bson);
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    bson_build_document('find', 'regex_id_coll'::text,
        'filter', bson_build_document('_id',
            bson_build_document('$regex', 'three'::text))::bson)::bson);

-- =============================================
-- Section 5: Combined regex on _id with other filters
-- =============================================

-- regex on _id combined with equality on another field
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" }, "a": 21 }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" }, "a": 21 } }');

-- regex on _id combined with $gt on another field
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^str_1" }, "a": { "$gt": 15 } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^str_1" }, "a": { "$gt": 15 } } }');

-- =============================================
-- Section 6: EXPLAIN plans - Btree pushdown verification
-- The btree index on (shard_key_value, object_id) should show
-- regex bounds pushed to btree index scans
-- =============================================
SET documentdb.enableExtendedExplainPlans TO on;

-- Disable bitmap scans for btree EXPLAIN stability across PG versions (PG18 may prefer bitmap)
BEGIN;
SET LOCAL enable_bitmapscan TO off;

-- Anchored prefix: should show btree pushdown with range bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);

-- Non-anchored: should still pushdown (with wider bounds)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "one" } } }')
$cmd$);

-- Anchored prefix with metacharacter: ^str[io] should extract prefix "str"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^str[io]" } } }')
$cmd$);

-- Regex type (BSON regex) with anchored prefix - btree pushdown
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } } }')
$cmd$);

-- Regex type without anchor - btree pushdown
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "one", "options": "" } } } }')
$cmd$);

-- Regex type with options "i" (case-insensitive) - should show wider bounds (no prefix optimization)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^ABC", "options": "i" } } } }')
$cmd$);

-- Regex with option "s" (dotAll) - "s" does not affect prefix extraction, so pushdown
-- should still produce narrow bounds like the no-options case
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "s" } } } }')
$cmd$);

-- Regex with options "si" (dotAll + case-insensitive) - "i" prevents prefix optimization
-- so bounds should be wide despite the anchor, same as "i" alone
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "si" } } } }')
$cmd$);

ROLLBACK;

-- =============================================
-- Section 7: EXPLAIN plans - RUM index pushdown verification
-- Create a secondary RUM index and check regex pushdown
-- =============================================

SELECT documentdb_api_internal.create_indexes_non_concurrently('regexIdDb',
    '{ "createIndexes": "regex_id_coll", "indexes": [ { "key": { "a": 1, "_id": 1 }, "name": "idx_a_id" } ]}', true);

-- Combined _id regex and a field filter to exercise both index paths
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" }, "a": { "$gt": 20 } } }')
$cmd$);

-- =============================================
-- Section 8: Composite RUM index with _id for regex pushdown
-- Create a collection with a composite RUM index containing _id
-- =============================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('regexIdDb',
    '{ "createIndexes": "regex_id_rum_coll", "indexes": [ { "key": { "b": 1, "_id": 1 }, "name": "idx_b_id_rum" } ]}', true);

SELECT COUNT(*) FROM (
    SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_rum_coll',
        FORMAT('{ "_id": "rum_%s", "b": %s }', g, g)::bson)
    FROM generate_series(1, 10) g
) i;

SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_rum_coll', '{ "_id": "abc_one", "b": 11 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_rum_coll', '{ "_id": "abc_two", "b": 12 }');
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_rum_coll', '{ "_id": "abd_three", "b": 13 }');

-- Result verification with RUM-indexed collection using hint to force RUM index
-- Without hint, _id-only regex queries prefer the btree _id_ index.
-- Use hint to verify regex pushdown works on the composite RUM index.
-- Disable bitmap scans for EXPLAIN stability across PG versions (PG18 may prefer bitmap)
BEGIN;
SET LOCAL enable_bitmapscan TO off;

SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "_id": { "$regex": "^abc" } }, "sort": { "_id": 1 }, "hint": "idx_b_id_rum" }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "_id": { "$regex": "^abc" } }, "hint": "idx_b_id_rum" }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "_id": { "$regex": "^rum_" } }, "sort": { "_id": 1 }, "hint": "idx_b_id_rum" }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "_id": { "$regex": "^rum_" } }, "hint": "idx_b_id_rum" }');

-- Combined b + _id regex to exercise the composite RUM index { b: 1, _id: 1 }
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "^abc" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "^abc" } } }');

-- Combined b + _id regex with $regularExpression type on composite RUM
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gte": 1 }, "_id": { "$regularExpression": { "pattern": "^rum_", "options": "" } } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gte": 1 }, "_id": { "$regularExpression": { "pattern": "^rum_", "options": "" } } } }');

-- Combined b + non-anchored _id regex on composite RUM
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "three" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "three" } } }');

ROLLBACK;

-- Disable bitmap scans for RUM EXPLAIN stability across PG versions (PG18 may prefer bitmap)
BEGIN;
SET LOCAL enable_bitmapscan TO off;

-- EXPLAIN for RUM index with hint to force regex pushdown on composite RUM
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "_id": { "$regex": "^abc" } }, "hint": "idx_b_id_rum" }')
$cmd$);

-- Non-anchored regex on RUM index with hint
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "_id": { "$regex": "rum" } }, "hint": "idx_b_id_rum" }')
$cmd$);

-- Regex type on RUM index with hint
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } }, "hint": "idx_b_id_rum" }')
$cmd$);

-- Combined b + _id regex EXPLAIN to show composite RUM pushdown
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "^abc" } } }')
$cmd$);

-- Combined b + non-anchored _id regex EXPLAIN on composite RUM
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "three" } } }')
$cmd$);

ROLLBACK;

-- =============================================
-- Section 9: Bitmap scan verification
-- Disable enable_indexscan to force bitmap scans and verify regex pushdown
-- =============================================
BEGIN;
SET LOCAL enable_indexscan TO off;

-- Btree bitmap scan with anchored prefix regex on _id
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);

-- Btree bitmap scan with non-anchored regex on _id
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "str" } } }')
$cmd$);

-- Btree bitmap scan with regex type ($regularExpression) on _id
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regularExpression": { "pattern": "^abc", "options": "" } } } }')
$cmd$);

-- RUM bitmap scan with hint on _id-only regex
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "b": { "$exists": true }, "_id": { "$regex": "^abc" } }, "hint": "idx_b_id_rum" }')
$cmd$);

-- RUM bitmap scan with combined b + _id regex
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "^abc" } } }')
$cmd$);

-- RUM bitmap scan with non-anchored _id regex and b filter
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_rum_coll", "filter": { "b": { "$gt": 10 }, "_id": { "$regex": "three" } } }')
$cmd$);

ROLLBACK;

-- =============================================
-- Section 10: Edge cases
-- =============================================

-- Empty regex should match all string _ids
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "" } } }');

-- ^$ should match only empty string _id (none in our data)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^$" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^$" } } }');

-- anchor only ^ matches all string _ids
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^" } } }');

-- ^nonexistent should match nothing
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^nonexistent" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^nonexistent" } } }');

-- =============================================
-- Section 11: Feature flag toggle
-- =============================================

-- Disable the feature flag and verify regex still works (just no pushdown optimization)
BEGIN;
SET LOCAL documentdb.enableObjectIdFuncExprConversion TO off;
SET LOCAL documentdb.forceDisableSeqScan TO off;
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('regexIdDb',
    '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" } } }');

-- EXPLAIN with feature flag off should show different plan (no object_id pushdown)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_coll", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);
ROLLBACK;


-- =============================================
-- Section 12: Selectivity-driven plan choice
-- With 10,000 string-_id rows and one matching row, the planner should
-- pick an Index Scan on the _id_ btree when the $regex predicate is
-- rewritten to bson_regex_object_id_match (selectivity ~= DEFAULT_INEQ_SEL).
-- With enableObjectIdFuncExprConversion off, the rewrite doesn't happen,
-- the predicate defaults to ~1.0 selectivity, and the planner picks
-- a Seq Scan instead.
-- =============================================
SELECT COUNT(*) FROM (
    SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_big',
        FORMAT('{ "_id": "row_%s", "a": %s }', g, g)::bson)
    FROM generate_series(1, 10000) g
) i;
-- One doc that matches the anchored prefix ^abc
SELECT documentdb_api.insert_one('regexIdDb', 'regex_id_big',
    '{ "_id": "abc_only", "a": 99999 }');
SELECT collection_id AS regex_id_big_id FROM documentdb_api_catalog.collections
    WHERE database_name = 'regexIdDb' AND collection_name = 'regex_id_big' \gset
ANALYZE documentdb_data.documents_:regex_id_big_id;

BEGIN;
SET LOCAL documentdb.forceDisableSeqScan TO off;

-- With the rewrite + selectivity fix: planner picks Index Scan on _id_
SET LOCAL documentdb.enableObjectIdFuncExprConversion TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_big", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);

-- Without the rewrite: predicate looks unselective, planner falls back to Seq Scan
SET LOCAL documentdb.enableObjectIdFuncExprConversion TO off;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regexIdDb',
        '{ "find": "regex_id_big", "filter": { "_id": { "$regex": "^abc" } } }')
$cmd$);
ROLLBACK;

RESET documentdb.enableExtendedExplainPlans;
RESET documentdb.forceDisableSeqScan;

SELECT documentdb_api.drop_collection('regexIdDb', 'regex_id_big');
