-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 2200;
SET documentdb.next_collection_index_id TO 2200;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET enable_seqscan TO OFF;
SET documentdb.fail_on_collated_index_term_truncation TO on;

-- Stored and queried collated values fit the index limit.
-- Explicit term-generation checks below use a smaller 50-byte limit.
SET documentdb.indexTermLimitOverride TO 200;

-- Declare helper for inspecting generated index terms
CREATE OR REPLACE FUNCTION documentdb_test_helpers.gin_bson_get_composite_path_generated_terms(document documentdb_core.bson, pathSpec text, termLimit int4, addMetadata bool, wildcardIndex int4 = -1)
    RETURNS SETOF documentdb_core.bson LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT AS '$libdir/pg_documentdb',
$$gin_bson_get_composite_path_generated_terms$$;


-- ======================================================================
-- SECTION 1: Setup with complete collated index entries
-- ======================================================================

-- Short strings that fit within the index term limit
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 1, "a": "short_string"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 2, "a": "Short_String"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 3, "a": "another_short"}', NULL);

-- Strings with a shared prefix and distinct suffixes
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 10, "a": "medium_prefix_string_alpha_end"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 11, "a": "medium_prefix_string_beta_end"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 12, "a": "Medium_Prefix_String_Alpha_End"}', NULL);

-- Long strings share a prefix and differ at the end.
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 20, "a": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 21, "a": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 22, "a": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA"}', NULL);

-- Long strings that differ after a shared prefix
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 30, "a": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 31, "a": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix_after_cut"}', NULL);

-- Long strings with same prefix, differ in middle, then identical tail
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 40, "a": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 41, "a": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end"}', NULL);

-- Numeric and null values (should not be affected by collation truncation)
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 50, "a": 12345}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 51, "a": null}', NULL);

-- Building with the write guard enabled verifies that stored entries are complete.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'trunc_db',
  '{
    "createIndexes": "trunc_coll",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1_trunc",
      "collation": {"locale": "en", "strength": 1},
      "enableCompositeTerm": true
    }]
  }',
  TRUE
);

SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page('trunc_db', '{"listIndexes": "trunc_coll"}');

-- Inspect generated terms to verify truncation behavior
-- Short string: should NOT be truncated
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms(
  '{"a": "short_string"}', '["a"]', 50, true);

-- Long string: truncated by the explicit 50-byte helper limit
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms(
  '{"a": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA"}',
  '["a"]', 50, true);

-- Two long strings that differ only after truncation point: should produce identical truncated terms
SELECT * FROM documentdb_test_helpers.gin_bson_get_composite_path_generated_terms(
  '{"a": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB"}',
  '["a"]', 50, true);


-- ======================================================================
-- SECTION 2: $eq on short (non-truncated) strings
-- ======================================================================

-- 2.1: $eq exact match — short string — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 2.2: $eq case-insensitive — short string — should match both cases
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "SHORT_STRING" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "SHORT_STRING" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 3: $eq on long strings with a shared prefix
-- ======================================================================

-- 3.1: $eq for long string — returns both case-insensitive matches
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.2: $eq for the other long string — should return only that doc
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.3: Case-insensitive $eq on a long string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "THIS_IS_A_LONG_STRING_THAT_WILL_DEFINITELY_EXCEED_THE_INDEX_TERM_TRUNCATION_LIMIT_AND_THE_DIFFERENCE_IS_AT_THE_VERY_END_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "THIS_IS_A_LONG_STRING_THAT_WILL_DEFINITELY_EXCEED_THE_INDEX_TERM_TRUNCATION_LIMIT_AND_THE_DIFFERENCE_IS_AT_THE_VERY_END_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 3.4: $eq for a long string that does NOT exist — should return nothing
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_CCCC" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_CCCC" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 4: $eq on long strings with distinct suffixes
-- ======================================================================

-- 4.1: $eq for boundary string — alpha suffix
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 4.2: $eq for boundary string — beta suffix
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 5: $eq on strings that differ in the middle
-- ======================================================================

-- 5.1: $eq prefix_match_AAAA — should return only _id: 40
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 5.2: $eq prefix_match_BBBB — should return only _id: 41
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$eq": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$eq": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 6: $gt, $gte on long strings
-- ======================================================================

-- 6.1: $gt on short string — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$gt": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$gt": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.2: $gte on short string — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$gte": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$gte": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.3: $gt on a long string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.4: $gte on a long string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.5: $gt on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.6: $gte on boundary string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.7: $gt on strings with distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 6b: $lt, $lte on long strings
-- ======================================================================

-- 6b.1: $lt on short string — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$lt": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$lt": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.2: $lte on short string — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$lte": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$lte": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.3: $lt on a long string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.4: $lte on a long string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.5: $lt on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.6: $lte on boundary string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.7: $lt on strings with distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 7: $and combinations with long strings
-- ======================================================================

-- 7.1: $and combining a long $eq value and a short $gt value
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "$and": [
    { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } },
    { "a": { "$gt": "short_string" } }
  ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "$and": [     { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } },     { "a": { "$gt": "short_string" } }   ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.2: Implicit $and with a $gte and $lte range across long strings
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gte": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end", "$lte": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gte": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end", "$lte": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.3: $and $eq + $gte — both short strings
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "$and": [
    { "a": { "$eq": "short_string" } },
    { "a": { "$gte": "another_short" } }
  ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "$and": [     { "a": { "$eq": "short_string" } },     { "a": { "$gte": "another_short" } }   ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 8: Non-string types are not affected by truncation+collation
-- ======================================================================

-- 8.1: $eq on numeric — index SHOULD be used regardless of truncation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": 12345 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": 12345 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.2: $gt on numeric — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$gt": 10000 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$gt": 10000 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 8.3: $eq on null — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 9: A collation mismatch must not use the collated index
-- ======================================================================

-- 9.1: $eq no collation — should NOT use collated index
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "short_string" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "short_string" } }, "sort": { "_id": 1 } }')
$cmd$);

-- 9.2: $eq different locale — should NOT use collated index
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$eq": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 9.3: $gt without collation must not use the collated index
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 10: $ne on long strings
-- ======================================================================

-- 10.1: $ne short string with matching collation — index used, no recheck needed
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.2: $ne "SHORT_STRING" case-insensitive — excludes both "short_string" and "Short_String"
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "SHORT_STRING" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "SHORT_STRING" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.3: $ne on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.4: Case-insensitive $ne excludes both case variants
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.5: $ne on numeric value — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": 12345 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": 12345 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.6: $ne null with a collated index
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.7: $ne mismatched collation — index should NOT be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 10.8: $ne on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.9: $ne on strings with distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.10: $ne + $gt combo on short strings
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "$and": [ { "a": { "$ne": "short_string" } }, { "a": { "$gt": "another_short" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- SECTION 11: $not $gt on long strings
-- ======================================================================

-- 11.1: $not $gt short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.2: $not $gt "SHORT_STRING" case-insensitive — ≤ short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.3: $not $gt on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.4: Case-insensitive $not $gt includes both case variants
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.5: $not $gt on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.6: $not $gt on strings with distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.7: $not $gt numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": 10000 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.8: $not $gt mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 11b: $not $gte on long strings
-- ======================================================================

-- 11b.1: $not $gte short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.2: $not $gte "SHORT_STRING" case-insensitive — < short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.3: $not $gte on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.4: Case-insensitive $not $gte on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.5: $not $gte on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.6: $not $gte on strings with distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.7: $not $gte numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": 12345 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.8: $not $gte mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 12: $not $lt on long strings
-- ======================================================================

-- 12.1: $not $lt short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.2: $not $lt "SHORT_STRING" case-insensitive — ≥ short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.3: $not $lt on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.4: Case-insensitive $not $lt on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.5: $not $lt on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.6: $not $lt on strings with distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.7: $not $lt numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": 10000 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.8: $not $lt mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 12b: $not $lte on long strings
-- ======================================================================

-- 12b.1: $not $lte short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.2: $not $lte "SHORT_STRING" case-insensitive — > short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.3: $not $lte on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.4: Case-insensitive $not $lte on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.5: $not $lte on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.6: $not $lte on strings with distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.7: $not $lte numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": 12345 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.8: $not $lte mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 13: $elemMatch with long values and collation
-- ======================================================================

SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch', '{"_id": 1, "tags": ["short", "Short", "SHORT"]}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch', '{"_id": 2, "tags": ["another_short", "ANOTHER_SHORT"]}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch',
  '{"_id": 3, "tags": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB"]}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch',
  '{"_id": 4, "tags": ["short", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA"]}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch',
  '{"_id": 5, "tags": ["This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_AAAA"]}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch',
  '{"_id": 6, "tags": ["boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix", "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix"]}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch', '{"_id": 7, "tags": [42, null, "short"]}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch', '{"_id": 8, "tags": []}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch', '{"_id": 9, "other": "value"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_elemmatch',
  '{"_id": 10, "tags": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB"]}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'trunc_db',
  '{
    "createIndexes": "trunc_elemmatch",
    "indexes": [{
      "key": {"tags": 1},
      "name": "idx_tags_en_s1_trunc",
      "collation": {"locale": "en", "strength": 1},
      "enableCompositeTerm": true
    }]
  }',
  TRUE
);

-- 13.1: $elemMatch $eq on short string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "short" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "short" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.2: $elemMatch $eq on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.3: RECHECK FALSE-POSITIVE TEST
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.4: $elemMatch $gt on a long string with a shared prefix
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.5: $elemMatch $lt on long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.6: $elemMatch $eq on boundary string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.7: $elemMatch with a range across long strings
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA", "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA", "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.8: $elemMatch $ne on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.9: $elemMatch $not $gt on long strings
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$not": { "$gt": "short" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$not": { "$gt": "short" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.10: $elemMatch with non-string type
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": 42 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": 42 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.11: $elemMatch with a mismatched collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "short" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "short" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 13.12: $elemMatch with degenerate range ($gte/$lte same value) on short string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "short", "$lte": "short" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "short", "$lte": "short" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.13: $elemMatch $eq without collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "short" } } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$eq": "short" } } }, "sort": { "_id": 1 } }')
$cmd$);

-- 13.14: $elemMatch $type: "string" on a collated index
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$type": "string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$type": "string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.15: $elemMatch $exists: true on a collated index
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$exists": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$exists": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.16: $elemMatch combining $gte, $lte, and $ne on long strings
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA", "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB", "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA", "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_BBBB", "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.17: $elemMatch $not: {$eq} on a long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$not": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$not": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 13.18: $elemMatch with an empty range across long strings
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA", "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_elemmatch", "filter": { "tags": { "$elemMatch": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA", "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 14: $in on long strings
-- ======================================================================

-- 14.1: $in with short strings — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["short_string", "another_short"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["short_string", "another_short"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 14.2: $in case-insensitive short strings — "SHORT_STRING" matches short_string + Short_String
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["SHORT_STRING"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 14.3: Long membership operands preserve exact matches.
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 14.4: Case-insensitive $in matches both AAAA case variants
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 14.5: Case-insensitive $in with an uppercase long string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["THIS_IS_A_LONG_STRING_THAT_WILL_DEFINITELY_EXCEED_THE_INDEX_TERM_TRUNCATION_LIMIT_AND_THE_DIFFERENCE_IS_AT_THE_VERY_END_AAAA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 14.6: $in with long strings that have distinct suffixes
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut", "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix_after_cut"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut", "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_beta_suffix_after_cut"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 14.7: $in with strings that have distinct prefixes
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 14.8: $in mixed short + long + numeric + null
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["short_string", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA", 12345, null] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["short_string", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA", 12345, null] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 14.9: $in with no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["short_string"] } }, "sort": { "_id": 1 } }')
$cmd$);

-- 14.10: $in with mismatched collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["short_string"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 14.11: multi-element $in non-string with mismatched collation — index NOT used
--        (array is collation-aware regardless of element types)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": [12345, null] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }')
$cmd$);

-- 14.12: $in with a nonexistent long string returns no matches
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$in": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_CCCC"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- SECTION 15: $nin on long strings
-- ======================================================================

-- 15.1: $nin with short strings — index SHOULD be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["short_string", "another_short"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["short_string", "another_short"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 15.2: $nin "SHORT_STRING" case-insensitive — excludes short_string + Short_String
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["SHORT_STRING"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 15.3: $nin with long strings excludes both AAAA case variants
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 15.4: $nin with boundary strings
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 15.5: $nin mixed short + long + numeric — complex exclusion
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["short_string", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA", 12345] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["short_string", "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA", 12345] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 15.6: $nin with mismatched collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["short_string"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 15.7: $nin "zebra" (not in collection) — nothing excluded
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$nin": ["zebra"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- SECTION 16: Reject truncated values for collated indexes
-- ======================================================================

-- Use a smaller limit to exercise rejected writes and indexed reads.
SET documentdb.indexTermLimitOverride TO 50;

RESET documentdb.fail_on_collated_index_term_truncation;

SELECT current_setting('documentdb.fail_on_collated_index_term_truncation')::boolean
    AS fail_on_collated_index_term_truncation;

-- 16.1: Short collated values continue to build, write, and query through the index
SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    '{ "_id": 1, "a": "short" }',
    NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trunc_guard_db',
    '{
        "createIndexes": "collated_writes",
        "indexes": [{
            "key": { "a": 1 },
            "name": "collated_a_1",
            "collation": { "locale": "en", "strength": 1 },
            "enableCompositeTerm": true
        }]
    }',
    TRUE);

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    '{ "_id": 2, "a": "SHORT" }',
    NULL);

SELECT count(*) AS matching_documents
FROM (
    SELECT document
    FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "collated_writes",
            "filter": { "a": "short" },
            "collation": { "locale": "en", "strength": 1 }
        }')
) AS query_result;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "collated_writes",
            "filter": { "a": "short" },
            "collation": { "locale": "en", "strength": 1 }
        }')
$cmd$);

-- 16.2: Building a collated index over an oversized value fails without removing data
SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_build',
    format(
        '{ "_id": 10, "a": "%s" }',
        repeat('a', 80) || '-existing')::documentdb_core.bson,
    NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trunc_guard_db',
    '{
        "createIndexes": "collated_build",
        "indexes": [{
            "key": { "a": 1 },
            "name": "collated_build_a_1",
            "collation": { "locale": "en", "strength": 1 },
            "enableCompositeTerm": true
        }]
    }',
    TRUE);

SELECT document->'_id' AS id
FROM documentdb_api.collection('trunc_guard_db', 'collated_build');

-- 16.3: Oversized strings fail, while binary values remain supported
SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    format(
        '{ "_id": 3, "a": "%s" }',
        repeat('b', 80) || '-insert')::documentdb_core.bson,
    NULL)::text LIKE
        '%Cannot generate an index term of type ''string'' that requires truncation when the index has a non-simple collation%'
    AS rejected;

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    format(
        '{ "_id": 4, "a": { "$binary": { "base64": "%s", "subType": "00" } } }',
        repeat('QUFB', 20))::documentdb_core.bson,
    NULL) AS inserted;

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    '{ "_id": 6, "a": { "$binary": { "base64": "QUFB", "subType": "00" } } }',
    NULL) IS NOT NULL AS inserted;

SELECT count(*) AS binary_matches
FROM (
    SELECT document
    FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "collated_writes",
            "filter": {
                "a": {
                    "$binary": {
                        "base64": "QUFB",
                        "subType": "00"
                    }
                }
            },
            "collation": { "locale": "en", "strength": 1 }
        }')
) AS query_result;

SELECT count(*) AS document_count
FROM documentdb_api.collection('trunc_guard_db', 'collated_writes');

-- 16.4: Modifier, replacement, and upsert writes fail and preserve existing rows
SELECT NOT success AS rejected,
       result::text LIKE
           '%Cannot generate an index term of type ''string'' that requires truncation when the index has a non-simple collation%'
           AS has_expected_error
FROM documentdb_api.update(
    'trunc_guard_db',
    format(
        '{
            "update": "collated_writes",
            "updates": [{
                "q": { "_id": 1 },
                "u": { "$set": { "a": "%s" } }
            }]
        }',
        repeat('c', 80) || '-update')::documentdb_core.bson)
    AS update_result(result, success);

SELECT document
FROM bson_aggregation_find(
    'trunc_guard_db',
    '{ "find": "collated_writes", "filter": { "_id": 1 } }');

SELECT NOT success AS rejected,
       result::text LIKE
           '%Cannot generate an index term of type ''string'' that requires truncation when the index has a non-simple collation%'
           AS has_expected_error
FROM documentdb_api.update(
    'trunc_guard_db',
    format(
        '{
            "update": "collated_writes",
            "updates": [{
                "q": { "_id": 2 },
                "u": { "_id": 2, "a": "%s" }
            }]
        }',
        repeat('d', 80) || '-replacement')::documentdb_core.bson)
    AS update_result(result, success);

SELECT document
FROM bson_aggregation_find(
    'trunc_guard_db',
    '{ "find": "collated_writes", "filter": { "_id": 2 } }');

SELECT NOT success AS rejected,
       result::text LIKE
           '%Cannot generate an index term of type ''string'' that requires truncation when the index has a non-simple collation%'
           AS has_expected_error
FROM documentdb_api.update(
    'trunc_guard_db',
    format(
        '{
            "update": "collated_writes",
            "updates": [{
                "q": { "_id": 5 },
                "u": { "$set": { "a": "%s" } },
                "upsert": true
            }]
        }',
        repeat('e', 80) || '-upsert')::documentdb_core.bson)
    AS update_result(result, success);

SELECT count(*) AS document_count
FROM documentdb_api.collection('trunc_guard_db', 'collated_writes');

-- 16.5: Oversized collatable reads fail; binary reads remain supported
SELECT document FROM bson_aggregation_find(
    'trunc_guard_db',
    '{
        "find": "collated_writes",
        "filter": { "a": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff-missing" },
        "hint": "collated_a_1",
        "collation": { "locale": "en", "strength": 1 }
    }');

-- Ignorable marks would match a short stored value without the index term limit.
SELECT document FROM bson_aggregation_find(
    'trunc_guard_db',
    '{
        "find": "collated_writes",
        "filter": { "a": "\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301short" },
        "hint": "collated_a_1",
        "collation": { "locale": "en", "strength": 1 }
    }');

SELECT document FROM bson_aggregation_find(
    'trunc_guard_db',
    '{
        "find": "collated_writes",
        "filter": { "a": { "$in": [ "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ] } },
        "hint": "collated_a_1",
        "collation": { "locale": "en", "strength": 1 }
    }');

SELECT document FROM bson_aggregation_find(
    'trunc_guard_db',
    '{
        "find": "collated_writes",
        "filter": { "a": { "$gte": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" } },
        "hint": "collated_a_1",
        "collation": { "locale": "en", "strength": 1 }
    }');

SELECT count(*) AS truncated_binary_matches
FROM (
    SELECT document FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "collated_writes",
            "filter": { "a": { "$binary": { "base64": "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB", "subType": "00" } } },
            "hint": "collated_a_1",
            "collation": { "locale": "en", "strength": 1 }
        }')
) AS query_result;

-- A collection without a collated index still compares complete values.
SELECT documentdb_api.insert_one(
    'trunc_guard_db', 'runtime_only', '{ "_id": 1, "a": "short" }', NULL);
SELECT documentdb_api.insert_one(
    'trunc_guard_db', 'runtime_only', '{ "_id": 2, "a": "SHORT" }', NULL);

SET enable_seqscan TO ON;
SELECT count(*) AS runtime_matches
FROM (
    SELECT document FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "runtime_only",
            "filter": { "a": "\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301\u0301short" },
            "collation": { "locale": "en", "strength": 1 }
        }')
) AS query_result;
SELECT count(*) AS runtime_misses
FROM (
    SELECT document FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "runtime_only",
            "filter": { "a": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff-missing" },
            "collation": { "locale": "en", "strength": 1 }
        }')
) AS query_result;
SET enable_seqscan TO OFF;

-- Fully represented values continue to use compound collated indexes.
SELECT documentdb_api.insert_one(
    'trunc_guard_db', 'collated_compound', '{ "_id": 30, "a": "short", "b": 0 }', NULL);
SELECT documentdb_api.insert_one(
    'trunc_guard_db', 'collated_compound', '{ "_id": 31, "a": "SHORT", "b": 0 }', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trunc_guard_db',
    '{
        "createIndexes": "collated_compound",
        "indexes": [{
            "key": { "a": 1, "b": 1 },
            "name": "collated_a_b_1",
            "collation": { "locale": "en", "strength": 1 },
            "enableCompositeTerm": true
        }]
    }',
    TRUE);

SELECT count(*) AS compound_matches
FROM (
    SELECT document FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "collated_compound",
            "filter": { "a": "short", "b": 0 },
            "hint": "collated_a_b_1",
            "collation": { "locale": "en", "strength": 1 }
        }')
) AS query_result;

SELECT document FROM bson_aggregation_find(
    'trunc_guard_db',
    '{
        "find": "collated_compound",
        "filter": { "a": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "b": 0 },
        "hint": "collated_a_b_1",
        "collation": { "locale": "en", "strength": 1 }
    }');

-- Oversized document and nested array terms fail on writes and indexed reads.
SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    format(
        '{ "_id": 7, "a": { "nested": "%s" } }',
        repeat('k', 80))::documentdb_core.bson,
    NULL)::text LIKE
        '%Cannot generate an index term of type ''object'' that requires truncation when the index has a non-simple collation%'
    AS rejected_document;

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    format(
        '{ "_id": 8, "a": [ [ "%s" ] ] }',
        repeat('m', 80))::documentdb_core.bson,
    NULL)::text LIKE
        '%Cannot generate an index term of type ''array'' that requires truncation when the index has a non-simple collation%'
    AS rejected_array;

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    '{ "_id": 9, "a": { "x": 1 } }',
    NULL);

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_writes',
    '{ "_id": 10, "a": [ [ 1 ] ] }',
    NULL);

SELECT count(*) AS document_count
FROM documentdb_api.collection('trunc_guard_db', 'collated_writes');

SELECT document FROM bson_aggregation_find(
    'trunc_guard_db',
    '{
        "find": "collated_writes",
        "filter": { "a": { "$eq": { "nested": "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk" } } },
        "hint": "collated_a_1",
        "collation": { "locale": "en", "strength": 1 }
    }');

SELECT document FROM bson_aggregation_find(
    'trunc_guard_db',
    '{
        "find": "collated_writes",
        "filter": { "a": { "$eq": [ [ "mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm" ] ] } },
        "hint": "collated_a_1",
        "collation": { "locale": "en", "strength": 1 }
    }');

-- 16.6: Non-collated indexes retain truncation and recheck behavior
SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'noncollated_truncation',
    format(
        '{ "_id": 20, "a": "%s" }',
        repeat('g', 80) || '-left')::documentdb_core.bson,
    NULL);

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'noncollated_truncation',
    format(
        '{ "_id": 21, "a": "%s" }',
        repeat('g', 80) || '-right')::documentdb_core.bson,
    NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trunc_guard_db',
    '{
        "createIndexes": "noncollated_truncation",
        "indexes": [{
            "key": { "a": 1 },
            "name": "noncollated_a_1",
            "enableCompositeTerm": true
        }]
    }',
    TRUE);

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'noncollated_truncation',
    format(
        '{ "_id": 22, "a": "%s" }',
        repeat('h', 80) || '-after-index')::documentdb_core.bson,
    NULL);

SELECT count(*) AS match_count
FROM (
    SELECT document
    FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "noncollated_truncation",
            "filter": {
                "a": "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg-left"
            }
        }')
) AS query_result;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "noncollated_truncation",
            "filter": {
                "a": "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg-left"
            }
        }')
$cmd$);

-- 16.7: Turning off the guard allows truncated writes and matching indexed reads.
SET documentdb.fail_on_collated_index_term_truncation TO off;

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_flag_off',
    format(
        '{ "_id": 30, "a": "%s" }',
        repeat('i', 80) || '-existing')::documentdb_core.bson,
    NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'trunc_guard_db',
    '{
        "createIndexes": "collated_flag_off",
        "indexes": [{
            "key": { "a": 1 },
            "name": "collated_flag_off_a_1",
            "collation": { "locale": "en", "strength": 1 },
            "enableCompositeTerm": true
        }]
    }',
    TRUE);

SELECT documentdb_api.insert_one(
    'trunc_guard_db',
    'collated_flag_off',
    format(
        '{ "_id": 31, "a": "%s" }',
        repeat('j', 80) || '-after-index')::documentdb_core.bson,
    NULL) IS NOT NULL AS inserted;

SELECT count(*) AS document_count
FROM documentdb_api.collection('trunc_guard_db', 'collated_flag_off');

SELECT count(*) AS disabled_guard_matches
FROM (
    SELECT document FROM bson_aggregation_find(
        'trunc_guard_db',
        '{
            "find": "collated_flag_off",
            "filter": { "a": "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii-existing" },
            "hint": "collated_flag_off_a_1",
            "collation": { "locale": "en", "strength": 1 }
        }')
) AS query_result;

-- ======================================================================
-- Cleanup
-- ======================================================================

RESET documentdb.indexTermLimitOverride;
RESET documentdb.enableExtendedExplainPlans;
RESET enable_seqscan;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.fail_on_collated_index_term_truncation;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb_core.enableCollation;
