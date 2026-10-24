SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 1200;
SET documentdb.next_collection_index_id TO 1200;

set documentdb.forceDisableSeqScan to on;

-- Create collection with a composite index for regex prefix bound testing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'regex_db', '{ "createIndexes": "regex_coll", "indexes": [ { "name": "idx_a_1_b_1", "key": { "a": 1, "b": 1 } } ] }', TRUE);

-- Insert test data with various string prefixes
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 1, "a": "string1", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 2, "a": "string2", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 3, "a": "string123", "b": false }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 4, "a": "strong", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 5, "a": "abc", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 6, "a": "abcd", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 7, "a": "abce", "b": false }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 8, "a": "xyz", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 9, "a": 123, "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 10, "a": true, "b": true }');

-- === Result verification tests ===

-- regex prefix: ^string should match string1, string2, string123
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string" } } }');

-- regex prefix: ^string1 should match string1, string123
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string1" } } }');

-- regex prefix with compound filter: ^str with b=true
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^str" }, "b": true } }');

-- regex without anchor (no optimization, but same correct results)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "string" } } }');

-- regex with anchor only, no literal prefix to extract: matches all strings
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^" } } }');

-- regex with meta character immediately after anchor (no prefix extraction)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^.*string" } } }');

-- regex with prefix before meta: ^abc. extracts prefix "abc"
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc." } } }');

-- regex with empty options string: optimization should still apply
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc", "$options": "" } } }');

-- regex with options "i": optimization disabled due to case-insensitive flag
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string", "$options": "i" } } }');

-- regex with single char prefix: ^s matches all s-prefixed strings
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^s" } } }');

-- negation via $nin with regex: should return non-matching docs (including non-string types)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$nin": [{ "$regularExpression": { "pattern": "^string", "options": "" } }] } } }');

-- regex with backslash escape: ^abc\\ stops prefix extraction at backslash
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc\\\\.d" } } }');

-- regex with character class after prefix: ^str[io] extracts prefix "str"
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^str[io]" } } }');

-- regex with quantifier after prefix: ^string+ extracts prefix "string" (+ is the meta char)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string+" } } }');

-- Add values for escape and alternation-specific behavior
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 15, "a": "abc|def", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 16, "a": "abc\\dog", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 17, "a": "abd123", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 18, "a": "ab5", "b": true }');

-- regex alternation after prefix: ^abc|xyz has unstable prefix due to unescaped |
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc|xyz" } } }');

-- escaped pipe is a literal and can contribute to the extracted prefix
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc\\|d" } } }');

-- escaped backslash literal should not break prefix extraction
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc\\\\d" } } }');

-- escaped class token like \d should not be treated as literal d in extracted prefix
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^ab\\d" } } }');

-- regex prefix: ^xyz exact single match
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^xyz" } } }');

-- regex prefix: ^nonexistent should return no results
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^nonexistent" } } }');

-- === Edge case tests ===

-- ^$ (end anchor immediately after start): no literal prefix extracted
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^$" } } }');

-- ^| (alternation right after anchor): no literal prefix
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^|abc" } } }');

-- ^( (group start right after anchor): no literal prefix
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^(string)" } } }');

-- Insert data with tilde (~, 0x7E) for boundary testing
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 11, "a": "~hello", "b": true }');

-- prefix ending with ~ (0x7E): upper bound increments to DEL (0x7F)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^~" } } }');

-- Insert data with DEL character (0x7F) for boundary testing
SELECT FORMAT('{ "_id": 12, "a": "abc%sdef", "b": true }', chr(127)) AS q1 \gset
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', :'q1'::bson);

-- prefix ending with 0x7F (DEL): upper bound increments to 0x80
SELECT FORMAT('{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc%s" } } }', chr(127)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', :'q1'::bson);

-- Insert data with multi-byte UTF-8 character for boundary testing
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 13, "a": "cafébar", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 14, "a": "cafêbar", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 19, "a": "mañana", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 20, "a": "maño", "b": true }');
SELECT FORMAT('{ "_id": 21, "a": "e%suro", "b": true }', chr(8364)) AS q1 \gset
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', :'q1'::bson);
SELECT FORMAT('{ "_id": 22, "a": "smile%s", "b": true }', chr(128512)) AS q1 \gset
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', :'q1'::bson);

-- multi-byte UTF-8 prefix: ^café - verifies byte-level increment handles multi-byte chars
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^café" } } }');

-- multi-byte UTF-8 inside prefix: ^mañan - verifies matching correctness with non-ASCII in prefix body
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^mañan" } } }');

-- multi-byte UTF-8 ending prefix: ^mañ - verifies continuation-byte ending prefix handling
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^mañ" } } }');

-- multi-byte UTF-8 inside prefix with compound filter on b
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^mañan" }, "b": true } }');

-- 3-byte UTF-8 codepoint in prefix end: ^e€
SELECT FORMAT('{ "find": "regex_coll", "filter": { "a": { "$regex": "^e%s" } } }', chr(8364)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', :'q1'::bson);

-- 4-byte UTF-8 codepoint in prefix end: ^smile😀
SELECT FORMAT('{ "find": "regex_coll", "filter": { "a": { "$regex": "^smile%s" } } }', chr(128512)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', :'q1'::bson);

-- Insert long values to exercise index-term truncation behavior (~2.8KB term cap)
SELECT FORMAT('{ "_id": 23, "a": "%s", "b": true }', repeat('q', 3000) || 'bX') AS q1 \gset
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', :'q1'::bson);
SELECT FORMAT('{ "_id": 24, "a": "%s", "b": true }', repeat('q', 3000) || 'cX') AS q1 \gset
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', :'q1'::bson);

-- string truncation case: short regex prefix over long indexed strings (prefix not truncated)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "^q+" } }, "projection": { "_id": 1 } }');

-- regex truncation case: long anchored prefix (>2.8KB) with quantifier after the final byte
-- TODO: currently not supported using $regex type, should be supported with string as the argument. We currently don't support regex truncation.
SELECT FORMAT(
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "^%sb+" } }, "projection": { "_id": 1 } }',
    repeat('q', 3000)) AS q1 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', :'q1'::bson);

SELECT FORMAT('^%sb+', repeat('q', 3000)) AS large_regex1 \gset
SELECT FORMAT('^abc|%s', repeat('q', 3000)) AS large_regex2 \gset
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', bson_build_document('find', 'regex_coll'::text, 'filter', bson_build_document('a', bson_build_document('$regex', :'large_regex1'::text))::bson)::bson);
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', bson_build_document('find', 'regex_coll'::text, 'filter', bson_build_document('a', bson_build_document('$regex', :'large_regex2'::text))::bson)::bson);

-- === EXPLAIN plan tests showing index bounds ===
set documentdb.enableExtendedExplainPlans to on;

-- optimized: ^string should show tight bounds [string, strinh)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string" } } }')
$cmd$);

-- optimized: ^abc should show tight bounds [abc, abd)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc" } } }')
$cmd$);

-- optimized: ^s single char prefix bounds [s, t)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^s" } } }')
$cmd$);

-- optimized: ^xyz tight bounds [xyz, xy{) (z+1={)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^xyz" } } }')
$cmd$);

-- optimized with meta after prefix: ^str[io] should show bounds for "str"
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^str[io]" } } }')
$cmd$);

-- not optimized: no anchor, should show full UTF8 type bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "string" } } }')
$cmd$);

-- not optimized: options "i", should show full UTF8 type bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string", "$options": "i" } } }')
$cmd$);

-- not optimized: anchor only ^, should show full UTF8 type bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^" } } }')
$cmd$);

-- not optimized: meta right after anchor ^.*, should show full UTF8 type bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^.*" } } }')
$cmd$);

-- not optimized: ^$ (end anchor is meta), no prefix extracted
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^$" } } }')
$cmd$);

-- not optimized: ^| (alternation is meta), no prefix extracted
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^|abc" } } }')
$cmd$);

-- not optimized: ^( (group start is meta), no prefix extracted
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^(string)" } } }')
$cmd$);

-- not optimized: unescaped alternation after prefix prevents stable bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc|xyz" } } }')
$cmd$);

-- optimized: escaped pipe contributes to the prefix
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc\\|d" } } }')
$cmd$);

-- optimized: escaped backslash contributes to the prefix
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc\\\\\\\\d" } } }')
$cmd$);

-- escaped class token like \d keeps only the stable prefix before it
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^ab\\d" } } }')
$cmd$);

-- optimized: ^~ prefix ending with 0x7E, upper bound increments to DEL (0x7F)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^~" } } }')
$cmd$);

-- optimized: prefix ending with 0x7F (DEL), upper bound increments to U+0080
SELECT FORMAT('{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc%s" } } }', chr(127)) AS q1 \gset
SELECT documentdb_test_helpers.run_explain_and_trim(FORMAT($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '%s')
$cmd$, :'q1'::text));

-- optimized: multi-byte UTF-8 prefix ^café with codepoint-aware upper bound
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^café" } } }')
$cmd$);

-- optimized: multi-byte UTF-8 ending prefix ^mañ with codepoint-aware upper bound
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^mañ" } } }')
$cmd$);

-- optimized: multi-byte UTF-8 inside prefix ^mañan with compound filter on b
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^mañan" }, "b": true } }')
$cmd$);

-- optimized: 3-byte UTF-8 codepoint in prefix end ^e€
SELECT FORMAT('{ "find": "regex_coll", "filter": { "a": { "$regex": "^e%s" } } }', chr(8364)) AS q1 \gset
SELECT documentdb_test_helpers.run_explain_and_trim(FORMAT($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '%s')
$cmd$, :'q1'::text));

-- optimized: 4-byte UTF-8 codepoint in prefix end ^smile😀
SELECT FORMAT('{ "find": "regex_coll", "filter": { "a": { "$regex": "^smile%s" } } }', chr(128512)) AS q1 \gset
SELECT documentdb_test_helpers.run_explain_and_trim(FORMAT($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '%s')
$cmd$, :'q1'::text));

-- === UTF-8 Codepoint Boundary Detection Tests ===
-- These tests verify the inline UTF-8 codepoint tracking optimization

-- Insert test data with various UTF-8 sequences
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 100, "a": "test世界", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 101, "a": "test世界abc", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 102, "a": "café😀", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 103, "a": "café😀test", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 104, "a": "éñ", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll', '{ "_id": 105, "a": "éñabc", "b": true }');

-- Test: Multiple consecutive UTF-8 chars at end of prefix ^test世界
-- Should correctly track to start of last codepoint (世界)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^test世界" } } }');

-- Test: UTF-8 followed by ASCII - should reset tracking and only find exact matches
-- ^test世界abc should match test世界abc exactly
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^test世界abc" } } }');

-- Test: Mixed 2-byte and 4-byte UTF-8 chars ^café😀  
-- Should correctly handle different UTF-8 byte lengths
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^café😀" } } }');

-- Test: Two consecutive 2-byte UTF-8 chars at end ^éñ
-- Should correctly identify start of last codepoint
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^éñ" } } }');

-- Test: UTF-8 at end followed by meta character - should extract UTF-8 prefix properly
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^éñ." } } }');

-- Explain plan verification: UTF-8 codepoint boundary optimization
-- Should show tight range bounds for UTF-8 strings ending with multi-byte chars
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) 
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^test世界" } } }')
$cmd$);

-- Explain plan: Mixed UTF-8 with trailing ASCII reset
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^éñtest" } } }')
$cmd$);

-- string truncation case: short regex prefix still uses tight ASCII bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find(
        'regex_db',
        '{ "find": "regex_coll", "filter": { "a": { "$regex": "^q+" } }, "projection": { "_id": 1 } }')
$cmd$);

-- negation via $nin: should show MINKEY/MAXKEY bounds
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$nin": [{ "$regularExpression": { "pattern": "^string", "options": "" } }] } } }')
$cmd$);

-- result verification for anchored prefix regex
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string" } } }');

-- regex truncation case: long anchored prefix
PREPARE large_prepare_regex1 AS
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', bson_build_document('find', 'regex_coll'::text, 'filter', bson_build_document('a', bson_build_document('$regex', :'large_regex1'::text))::bson)::bson);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    EXECUTE large_prepare_regex1
$cmd$);

PREPARE large_prepare_regex2 AS
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('regex_db', bson_build_document('find', 'regex_coll'::text, 'filter', bson_build_document('a', bson_build_document('$regex', :'large_regex2'::text))::bson)::bson);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    EXECUTE large_prepare_regex2
$cmd$);

-- Absolute start anchors use the same prefix bounds as ^, including on array elements.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db',
        '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Astring" } } }')
$cmd$);

SELECT documentdb_api.insert_one('regex_db', 'regex_coll',
    '{ "_id": 200, "a": ["other", "string_array"], "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll',
    '{ "_id": 201, "a": "other\nstring_line", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll',
    '{ "_id": 202, "a": "\\Astring_literal", "b": true }');
SELECT documentdb_api.insert_one('regex_db', 'regex_coll',
    '{ "_id": 203, "a": "STRING_upper", "b": true }');

SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Astring" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regularExpression": { "pattern": "\\Astring", "options": "ms" } }, "b": true }, "sort": { "_id": 1 } }');

-- Only \A stays anchored to the entire string in multiline mode.
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "^string", "$options": "m" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Astring", "$options": "i" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\\\Astring" } }, "sort": { "_id": 1 } }');

-- Optional prefix characters and alternatives after metacharacters must not exclude matches.
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Aabcd?" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Aabcd*" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Aabcd{0}" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Aabc.*|xyz" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abcd?" } }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "^abc.*|xyz" } }, "sort": { "_id": 1 } }');

-- Compare tight bounds, option safety, empty prefixes, alternation, and escaped anchors.
SELECT pattern, options, documentdb_test_helpers.run_explain_and_trim(FORMAT($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db', %L)
$cmd$, bson_build_document('find', 'regex_coll'::text,
    'filter', bson_build_document('a',
        bson_build_document('$regex', pattern, '$options', options))::bson)::text))
FROM (VALUES
    ('\Astring', ''),
    ('\Astring', 'ms'),
    ('^string', 'm'),
    ('\Astring', 'i'),
    ('\Astring', 'x'),
    ('\A', ''),
    ('\Aabc|xyz', ''),
    ('\Aabc.*|xyz', ''),
    ('\Aabcd?', ''),
    ('\\Astring', ''),
    ('\Aabc\.d', '')
) AS cases(pattern, options);

-- Regex remains case-sensitive under a non-default command collation.
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.forceDisableSeqScan TO off;
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Astring" } }, "collation": { "locale": "en", "strength": 1 }, "sort": { "_id": 1 } }');
SELECT document FROM bson_aggregation_find('regex_db',
    '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Aabcd?" } }, "collation": { "locale": "en", "strength": 1 }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_find('regex_db',
        '{ "find": "regex_coll", "filter": { "a": { "$regex": "\\Astring" } }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
ROLLBACK;

-- Exercise optional literals through scalar, multikey, and primary-key bounds.
CREATE TEMP TABLE regex_prefix_documents (document jsonb);
INSERT INTO regex_prefix_documents
SELECT jsonb_build_object('_id', value, 'a', value, 'arr', jsonb_build_array('unrelated', value))
FROM unnest(ARRAY[
    '', 'a', 'ab', 'abc', 'abcd', 'abcdd', 'abce', 'abd', 'xyz', 'other',
    E'other\nabcd', 'ABCD', 'abc.', 'abc\', 'é', 'ê', 'éñ', 'é.',
    '€', '€x', '€y', '😀', '😀x', '😀y',
    'abcé', 'abc€', 'abc😀', 'b', 'abc|b', 'abc\|b', E'abc\034', 'abc<b'
]) AS values(value);
INSERT INTO regex_prefix_documents VALUES
    ('{"_id":"mixed_array","a":42,"arr":[null,42,"abc"]}'),
    ('{"_id":"null_value","a":null,"arr":null}'),
    ('{"_id":"empty_array","a":[],"arr":[]}'),
    ('{"_id":"missing_value"}');

SELECT documentdb_api_internal.create_indexes_non_concurrently('regex_db',
    '{ "createIndexes": "prefix_quantifiers", "indexes": [
        { "name": "prefix_a", "key": { "a": 1, "b": 1 } },
        { "name": "prefix_arr", "key": { "arr": 1, "b": 1 } }
    ] }', TRUE);
SELECT count(documentdb_api.insert_one('regex_db', 'prefix_quantifiers', document::text::bson))
FROM regex_prefix_documents;

CREATE TEMP TABLE regex_prefix_cases AS
SELECT anchor || suffix AS pattern, ''::text AS options
FROM unnest(ARRAY['^', '\A']) AS anchors(anchor)
CROSS JOIN unnest(ARRAY[
    'abcd?', 'abcd*', 'abcd??', 'abcd*+', 'abcd+', 'a?',
    'abc\.?', 'abc\\*', 'abcé?', 'abc€*', 'abc😀?',
    'éñ?', 'é\.?', '€x?', '😀x?', 'abcd?|xyz', 'abcd{0,1}',
    'abc(?#comment)?', 'éñ(?#comment)*', 'a(?#comment)?', 'abc(d)?',
    'abc\c\|b', 'abc\c|b', 'abc.*\|b', 'abc.*\\|b', 'abc.*\\\|b',
    'abc\\\|b', 'abc\\\c\|b', 'abc\x{5c}|b'
]) AS suffixes(suffix);
INSERT INTO regex_prefix_cases VALUES
    ('^abcd?', 'm'), ('\Aabcd?', 'm'), ('\Aabcd*', 's'),
    ('^abc\E?', ''), ('\Aabc\E*', ''),
    ('^abc\Q\E?', ''), ('\Aabc\Q\E*', ''),
    ('^abc\E{0,1}', ''), ('\Aéñ\Q\E\E?', ''),
    ('^abc\\\E?', ''), ('\Aabc\\E?', ''),
    ('^abc\Q.d\E?', ''), ('\Aabc\Q|b', '');

CREATE FUNCTION pg_temp.regex_prefix_runtime(filter_doc bson)
RETURNS text[]
LANGUAGE plpgsql
SET documentdb.forceDisableSeqScan = off
SET enable_indexscan = off
SET enable_bitmapscan = off
SET enable_seqscan = on
AS $fn$
DECLARE
    ids text[];
BEGIN
    SELECT coalesce(array_agg(document::text::jsonb->>'_id'
        ORDER BY (document::text::jsonb->>'_id') COLLATE "C"), ARRAY[]::text[])
    INTO ids
    FROM documentdb_api.collection('regex_db', 'prefix_quantifiers')
    WHERE document @@ filter_doc;
    RETURN ids;
END
$fn$;

CREATE FUNCTION pg_temp.regex_prefix_probe(pattern text, options text, field_name text)
RETURNS TABLE(bounds text, ids text[])
LANGUAGE plpgsql
SET enable_bitmapscan = on
AS $fn$
DECLARE
    filter_doc bson := bson_build_document(field_name,
        bson_build_document('$regex', pattern, '$options', options));
    index_name text := CASE field_name WHEN '_id' THEN '_id_' ELSE 'prefix_' || field_name END;
    command bson := bson_build_document('find', 'prefix_quantifiers'::text,
        'filter', filter_doc, 'hint', index_name);
    query text := format('SELECT document FROM bson_aggregation_find(''regex_db'', %L)', command);
    runtime_ids text[];
BEGIN
    PERFORM set_config('enable_bitmapscan', CASE WHEN field_name = '_id' THEN 'off' ELSE 'on' END, true);
    EXECUTE format('SELECT coalesce(array_agg(document::text::jsonb->>''_id''
        ORDER BY (document::text::jsonb->>''_id'') COLLATE "C"), ARRAY[]::text[])
        FROM (%s) AS matched', query)
    INTO ids;

    runtime_ids := pg_temp.regex_prefix_runtime(filter_doc);
    IF ids IS DISTINCT FROM runtime_ids THEN
        RAISE EXCEPTION 'Indexed/runtime mismatch: field %, pattern %, options %, indexed %, runtime %',
            field_name, pattern, options, ids, runtime_ids;
    END IF;

    SELECT trim(line) INTO STRICT bounds
    FROM documentdb_test_helpers.run_explain_and_trim('EXPLAIN (COSTS OFF) ' || query) AS plan(line)
    WHERE CASE WHEN field_name = '_id'
        THEN line LIKE '%Index Cond:%object_id%'
        ELSE line LIKE '%indexBounds:%' END;
    RETURN NEXT;
END
$fn$;

CREATE TEMP TABLE regex_prefix_results AS
SELECT pattern, options, field_name, bounds, ids
FROM regex_prefix_cases
CROSS JOIN unnest(ARRAY['a', 'arr', '_id']) AS fields(field_name)
CROSS JOIN LATERAL pg_temp.regex_prefix_probe(pattern, options, field_name);

SELECT field_name, options, count(*) AS cases_checked
FROM regex_prefix_results GROUP BY field_name, options ORDER BY field_name, options;

SELECT actual.field_name, actual.options,
    bool_and(split_part(actual.bounds, '], [', 1) = split_part(base.bounds, '], [', 1)) AS same_bounds
FROM regex_prefix_results AS actual
JOIN regex_prefix_results AS base USING (pattern, field_name)
WHERE base.options = '' AND
    (actual.options = 's' OR (actual.options = 'm' AND left(actual.pattern, 2) = '\A'))
GROUP BY actual.field_name, actual.options ORDER BY actual.field_name, actual.options;

-- Keep the detailed no-option bounds visible; all option combinations check results above.
SELECT pattern, field_name, bounds, cardinality(ids) AS matches
FROM regex_prefix_results WHERE options = '' ORDER BY pattern COLLATE "C", field_name;

DROP FUNCTION pg_temp.regex_prefix_probe(text, text, text);
DROP FUNCTION pg_temp.regex_prefix_runtime(bson);

reset documentdb.enableExtendedExplainPlans;
reset documentdb.forceDisableSeqScan;
