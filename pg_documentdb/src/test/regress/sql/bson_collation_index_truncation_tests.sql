SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 2200;
SET documentdb.next_collection_index_id TO 2200;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET enable_seqscan TO OFF;

-- Use a small truncation limit to make testing practical
SET documentdb.indexTermLimitOverride TO 50;

-- Declare helper for inspecting generated index terms
CREATE OR REPLACE FUNCTION documentdb_test_helpers.gin_bson_get_composite_path_generated_terms(document documentdb_core.bson, pathSpec text, termLimit int4, addMetadata bool, wildcardIndex int4 = -1)
    RETURNS SETOF documentdb_core.bson LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT AS '$libdir/pg_documentdb',
$$gin_bson_get_composite_path_generated_terms$$;


-- ======================================================================
-- SECTION 1: Setup — index with collation and truncation enabled
-- ======================================================================

-- Base strings: 60 chars (fits under 100-byte limit after overhead)
-- Long strings: 150+ chars (exceeds limit, will be truncated)

-- Short strings that fit within the index term limit
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 1, "a": "short_string"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 2, "a": "Short_String"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 3, "a": "another_short"}', NULL);

-- Strings that share a common prefix but differ BEFORE the truncation point
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 10, "a": "medium_prefix_string_alpha_end"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 11, "a": "medium_prefix_string_beta_end"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll', '{"_id": 12, "a": "Medium_Prefix_String_Alpha_End"}', NULL);

-- Long strings that WILL be truncated — identical up to truncation point, differ after
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 20, "a": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 21, "a": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB"}', NULL);
SELECT documentdb_api.insert_one('trunc_db','trunc_coll',
  '{"_id": 22, "a": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA"}', NULL);

-- Long strings that differ right AT the truncation boundary
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

-- Create index with collation and truncation (via indexTermLimitOverride GUC)
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

-- Long string: SHOULD be truncated (exceeds 100 byte limit)
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
-- SECTION 3: $eq on long (truncated) strings — identical prefix
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

-- 3.3: $eq case-insensitive — long truncated string
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
-- SECTION 4: $eq on strings that differ AT the truncation boundary
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
-- SECTION 5: $eq on strings that differ in the middle (before truncation)
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
-- SECTION 6: $gt, $gte on truncated strings
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

-- 6.3: $gt on long truncated string — should work correctly despite truncation
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.4: $gte on long truncated string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6.5: $gt on boundary string — correctness with truncation at boundary
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

-- 6.7: $gt on prefix_match string — differs before truncation point
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 6b: $lt, $lte on truncated strings
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

-- 6b.3: $lt on long truncated string — should work correctly despite truncation
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.4: $lte on long truncated string
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 6b.5: $lt on boundary string — correctness with truncation at boundary
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

-- 6b.7: $lt on prefix_match string — differs before truncation point
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$lt": "prefix_match_BBBB_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 7: $and combinations with truncated strings
-- ======================================================================

-- 7.1: $and $eq + $gt — truncated $eq with short $gt
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "$and": [
    { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } },
    { "a": { "$gt": "short_string" } }
  ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "$and": [     { "a": { "$eq": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_BBBB" } },     { "a": { "$gt": "short_string" } }   ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 7.2: Implicit $and — $gte + $lte range spanning truncated strings
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
-- SECTION 9: Collation mismatch with truncated index — should NOT use index
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

-- 9.3: $gt no collation on truncated string — should NOT use collated index
SELECT document FROM bson_aggregation_find('trunc_db',
  '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db',   '{ "find": "trunc_coll", "filter": { "a": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 10: $ne on truncated strings
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

-- 10.3: $ne truncated string — index used, recheck expected due to truncation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.4: $ne truncated string case-insensitive — excludes case variants
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.5: $ne on numeric value — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": 12345 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": 12345 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.6: $ne null with truncated index
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 10.7: $ne mismatched collation — index should NOT be used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "short_string" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);

-- 10.8: $ne on boundary string — truncation boundary correctness
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.9: $ne on prefix_match string — differs before truncation point
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$ne": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.10: $ne + $gt combo on short strings
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "$and": [ { "a": { "$ne": "short_string" } }, { "a": { "$gt": "another_short" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- SECTION 11: $not $gt on truncated strings
-- ======================================================================

-- 11.1: $not $gt short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.2: $not $gt "SHORT_STRING" case-insensitive — ≤ short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.3: $not $gt truncated string — recheck expected due to truncation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.4: $not $gt truncated string case-insensitive — includes both case variants (≤ at strength-1)
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.5: $not $gt boundary string — truncation boundary correctness
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11.6: $not $gt prefix_match string — differs in middle before truncation point
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.7: $not $gt numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": 10000 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.8: $not $gt mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 11b: $not $gte on truncated strings
-- ======================================================================

-- 11b.1: $not $gte short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.2: $not $gte "SHORT_STRING" case-insensitive — < short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.3: $not $gte truncated string — recheck expected due to truncation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.4: $not $gte truncated string case-insensitive
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.5: $not $gte boundary string — truncation boundary correctness
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 11b.6: $not $gte prefix_match string — differs in middle before truncation point
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.7: $not $gte numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": 12345 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.8: $not $gte mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$gte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 12: $not $lt on truncated strings
-- ======================================================================

-- 12.1: $not $lt short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.2: $not $lt "SHORT_STRING" case-insensitive — ≥ short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.3: $not $lt truncated string — recheck expected due to truncation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.4: $not $lt truncated string case-insensitive
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.5: $not $lt boundary string — truncation boundary correctness
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12.6: $not $lt prefix_match string — differs in middle before truncation point
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.7: $not $lt numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": 10000 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.8: $not $lt mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lt": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- SECTION 12b: $not $lte on truncated strings
-- ======================================================================

-- 12b.1: $not $lte short string with matching collation — index used
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.2: $not $lte "SHORT_STRING" case-insensitive — > short_string at strength-1
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "SHORT_STRING" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.3: $not $lte truncated string — recheck expected due to truncation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "this_is_a_long_string_that_will_definitely_exceed_the_index_term_truncation_limit_and_the_difference_is_at_the_very_end_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.4: $not $lte truncated string case-insensitive
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "This_Is_A_Long_String_That_Will_Definitely_Exceed_The_Index_Term_Truncation_Limit_And_The_Difference_Is_At_The_Very_End_AAAA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.5: $not $lte boundary string — truncation boundary correctness
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "boundary_test_string_padded_to_reach_exactly_near_the_truncation_point_XXXX_alpha_suffix_after_cut" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- 12b.6: $not $lte prefix_match string — differs in middle before truncation point
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "prefix_match_AAAA_then_a_very_long_tail_that_pushes_past_truncation_limit_significantly_and_keeps_going_until_end" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.7: $not $lte numeric — not affected by truncation or collation
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": 12345 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.8: $not $lte mismatched collation — index should NOT be used for string
SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('trunc_db', '{ "find": "trunc_coll", "filter": { "a": { "$not": { "$lte": "short_string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }')
$cmd$);


-- ======================================================================
-- Cleanup
-- ======================================================================

RESET documentdb.indexTermLimitOverride;
RESET documentdb.enableExtendedExplainPlans;
RESET enable_seqscan;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb_core.enableCollation;
