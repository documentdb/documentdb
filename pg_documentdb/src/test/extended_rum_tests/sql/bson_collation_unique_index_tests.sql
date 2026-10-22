-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.next_collection_id TO 791000;
SET documentdb.next_collection_index_id TO 791000;
SET documentdb_core.bsonUseEJson TO on;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableCompositeUniqueHash TO on;
SET documentdb.enable_composite_unique_optional_key TO on;
SET documentdb.enable_collated_unique_indexes TO on;

-- Ordered unique-index creation gates and idempotency
SELECT documentdb_api.create_collection('unique_collation_db', 'gates');
SET documentdb.enable_collated_unique_indexes TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "gates", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SET documentdb.enable_collated_unique_indexes TO on;
SET documentdb.enable_composite_unique_optional_key TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "gates", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SET documentdb.enable_composite_unique_optional_key TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "gates", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "gates", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);

SELECT * FROM documentdb_test_helpers.get_collection_indexes('unique_collation_db', 'gates')
ORDER BY index_id;

-- Collation attributes: equality, distinctions and canonical normalization
-- primary_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_primary_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 1 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_primary_case',
    '{ "_id": 1, "v": "cafe" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_primary_case',
    '{ "_id": 2, "v": "CAFE" }');
SELECT count(*) AS primary_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_primary_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_primary_case');

-- primary_accent
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_primary_accent", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 1 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_primary_accent',
    '{ "_id": 1, "v": "cafe" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_primary_accent',
    '{ "_id": 2, "v": "caf\u00e9" }');
SELECT count(*) AS primary_accent_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_primary_accent');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_primary_accent');

-- secondary_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_secondary_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_secondary_case',
    '{ "_id": 1, "v": "cafe" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_secondary_case',
    '{ "_id": 2, "v": "CAFE" }');
SELECT count(*) AS secondary_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_secondary_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_secondary_case');

-- secondary_accent
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_secondary_accent", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_secondary_accent',
    '{ "_id": 1, "v": "cafe" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_secondary_accent',
    '{ "_id": 2, "v": "caf\u00e9" }');
SELECT count(*) AS secondary_accent_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_secondary_accent');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_secondary_accent');

-- tertiary_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_tertiary_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_tertiary_case',
    '{ "_id": 1, "v": "cafe" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_tertiary_case',
    '{ "_id": 2, "v": "CAFE" }');
SELECT count(*) AS tertiary_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_tertiary_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_tertiary_case');

-- tertiary_accent
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_tertiary_accent", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_tertiary_accent',
    '{ "_id": 1, "v": "cafe" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_tertiary_accent',
    '{ "_id": 2, "v": "caf\u00e9" }');
SELECT count(*) AS tertiary_accent_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_tertiary_accent');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_tertiary_accent');

-- identical_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_identical_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 5 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_identical_case',
    '{ "_id": 1, "v": "a" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_identical_case',
    '{ "_id": 2, "v": "A" }');
SELECT count(*) AS identical_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_identical_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_identical_case');

-- case_level_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_case_level_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 1, "caseLevel": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_case_level_case',
    '{ "_id": 1, "v": "a" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_case_level_case',
    '{ "_id": 2, "v": "A" }');
SELECT count(*) AS case_level_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_case_level_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_case_level_case');

-- case_level_accent
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_case_level_accent", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 1, "caseLevel": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_case_level_accent',
    '{ "_id": 1, "v": "a" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_case_level_accent',
    '{ "_id": 2, "v": "\u00e1" }');
SELECT count(*) AS case_level_accent_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_case_level_accent');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_case_level_accent');

-- case_first_tertiary
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_case_first_tertiary", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3, "caseFirst": "upper" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_case_first_tertiary',
    '{ "_id": 1, "v": "a" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_case_first_tertiary',
    '{ "_id": 2, "v": "A" }');
SELECT count(*) AS case_first_tertiary_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_case_first_tertiary');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_case_first_tertiary');

-- numeric_leading_zero
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_numeric_leading_zero", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_leading_zero',
    '{ "_id": 1, "v": "item2" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_leading_zero',
    '{ "_id": 2, "v": "ITEM02" }');
SELECT count(*) AS numeric_leading_zero_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_numeric_leading_zero');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_numeric_leading_zero');

-- numeric_distinct
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_numeric_distinct", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_distinct',
    '{ "_id": 1, "v": "item2" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_distinct',
    '{ "_id": 2, "v": "item10" }');
SELECT count(*) AS numeric_distinct_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_numeric_distinct');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_numeric_distinct');

-- lexical_leading_zero
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_lexical_leading_zero", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2, "numericOrdering": false } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_lexical_leading_zero',
    '{ "_id": 1, "v": "item2" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_lexical_leading_zero',
    '{ "_id": 2, "v": "item02" }');
SELECT count(*) AS lexical_leading_zero_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_lexical_leading_zero');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_lexical_leading_zero');

-- numeric_sign
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_numeric_sign", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_sign',
    '{ "_id": 1, "v": "-2" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_sign',
    '{ "_id": 2, "v": "2" }');
SELECT count(*) AS numeric_sign_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_numeric_sign');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_numeric_sign');

-- numeric_decimal
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_numeric_decimal", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_decimal',
    '{ "_id": 1, "v": "2.1" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_numeric_decimal',
    '{ "_id": 2, "v": "2.10" }');
SELECT count(*) AS numeric_decimal_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_numeric_decimal');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_numeric_decimal');

-- shifted_punctuation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_shifted_punctuation", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3, "alternate": "shifted" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_shifted_punctuation',
    '{ "_id": 1, "v": "ab" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_shifted_punctuation',
    '{ "_id": 2, "v": "a-b" }');
SELECT count(*) AS shifted_punctuation_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_shifted_punctuation');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_shifted_punctuation');

-- quaternary_punctuation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_quaternary_punctuation", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 4, "alternate": "shifted" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_quaternary_punctuation',
    '{ "_id": 1, "v": "ab" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_quaternary_punctuation',
    '{ "_id": 2, "v": "a-b" }');
SELECT count(*) AS quaternary_punctuation_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_quaternary_punctuation');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_quaternary_punctuation');

-- non_ignorable_punctuation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_non_ignorable_punctuation", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3, "alternate": "non-ignorable" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_non_ignorable_punctuation',
    '{ "_id": 1, "v": "ab" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_non_ignorable_punctuation',
    '{ "_id": 2, "v": "a-b" }');
SELECT count(*) AS non_ignorable_punctuation_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_non_ignorable_punctuation');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_non_ignorable_punctuation');

-- shifted_space
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_shifted_space", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3, "alternate": "shifted", "maxVariable": "space" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_shifted_space',
    '{ "_id": 1, "v": "ab" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_shifted_space',
    '{ "_id": 2, "v": "a b" }');
SELECT count(*) AS shifted_space_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_shifted_space');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_shifted_space');

-- space_not_punctuation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_space_not_punctuation", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3, "alternate": "shifted", "maxVariable": "space" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_space_not_punctuation',
    '{ "_id": 1, "v": "ab" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_space_not_punctuation',
    '{ "_id": 2, "v": "a-b" }');
SELECT count(*) AS space_not_punctuation_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_space_not_punctuation');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_space_not_punctuation');

-- normalization
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_normalization", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3, "normalization": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_normalization',
    '{ "_id": 1, "v": "\u00e9" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_normalization',
    '{ "_id": 2, "v": "e\u0301" }');
SELECT count(*) AS normalization_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_normalization');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_normalization');

-- identical_normalization
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_identical_normalization", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 5, "normalization": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_identical_normalization',
    '{ "_id": 1, "v": "\u00e9" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_identical_normalization',
    '{ "_id": 2, "v": "e\u0301" }');
SELECT count(*) AS identical_normalization_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_identical_normalization');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_identical_normalization');

-- ignored_codepoint
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_ignored_codepoint", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_ignored_codepoint',
    '{ "_id": 1, "v": "ab" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_ignored_codepoint',
    '{ "_id": 2, "v": "a\u200bb" }');
SELECT count(*) AS ignored_codepoint_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_ignored_codepoint');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_ignored_codepoint');

-- identical_codepoint
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_identical_codepoint", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 5 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_identical_codepoint',
    '{ "_id": 1, "v": "ab" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_identical_codepoint',
    '{ "_id": 2, "v": "a\u200bb" }');
SELECT count(*) AS identical_codepoint_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_identical_codepoint');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_identical_codepoint');

-- turkish_dotted
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_turkish_dotted", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "tr", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_turkish_dotted',
    '{ "_id": 1, "v": "i" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_turkish_dotted',
    '{ "_id": 2, "v": "\u0130" }');
SELECT count(*) AS turkish_dotted_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_turkish_dotted');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_turkish_dotted');

-- turkish_dotless
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_turkish_dotless", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "tr", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_turkish_dotless',
    '{ "_id": 1, "v": "I" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_turkish_dotless',
    '{ "_id": 2, "v": "\u0131" }');
SELECT count(*) AS turkish_dotless_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_turkish_dotless');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_turkish_dotless');

-- turkish_two_classes
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_turkish_two_classes", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "tr", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_turkish_two_classes',
    '{ "_id": 1, "v": "i" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_turkish_two_classes',
    '{ "_id": 2, "v": "I" }');
SELECT count(*) AS turkish_two_classes_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_turkish_two_classes');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_turkish_two_classes');

-- german_primary
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_german_primary", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "de", "strength": 1 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_german_primary',
    '{ "_id": 1, "v": "strasse" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_german_primary',
    '{ "_id": 2, "v": "stra\u00dfe" }');
SELECT count(*) AS german_primary_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_german_primary');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_german_primary');

-- swedish_primary
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_swedish_primary", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "sv", "strength": 1 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_swedish_primary',
    '{ "_id": 1, "v": "a" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_swedish_primary',
    '{ "_id": 2, "v": "\u00e5" }');
SELECT count(*) AS swedish_primary_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_swedish_primary');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_swedish_primary');

-- french_backwards
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_french_backwards", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "fr", "strength": 2, "backwards": true } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_french_backwards',
    '{ "_id": 1, "v": "cot\u00e9" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_french_backwards',
    '{ "_id": 2, "v": "COT\u00c9" }');
SELECT count(*) AS french_backwards_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_french_backwards');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_french_backwards');

-- empty_string
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_empty_string", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_string',
    '{ "_id": 1, "v": "" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_string',
    '{ "_id": 2, "v": "" }');
SELECT count(*) AS empty_string_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_empty_string');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_empty_string');

-- empty_not_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_empty_not_null", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_not_null',
    '{ "_id": 1, "v": "" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_not_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS empty_not_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_empty_not_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_empty_not_null');

-- trailing_space
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_trailing_space", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_trailing_space',
    '{ "_id": 1, "v": "a" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_trailing_space',
    '{ "_id": 2, "v": "a " }');
SELECT count(*) AS trailing_space_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_trailing_space');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_trailing_space');

-- embedded_null_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_embedded_null_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_embedded_null_case',
    '{ "_id": 1, "v": "a\u0000b" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_embedded_null_case',
    '{ "_id": 2, "v": "A\u0000B" }');
SELECT count(*) AS embedded_null_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_embedded_null_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_embedded_null_case');

-- embedded_null_suffix
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_embedded_null_suffix", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_embedded_null_suffix',
    '{ "_id": 1, "v": "a\u0000b" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_embedded_null_suffix',
    '{ "_id": 2, "v": "a\u0000c" }');
SELECT count(*) AS embedded_null_suffix_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_embedded_null_suffix');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_embedded_null_suffix');

-- simple_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_simple_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "simple" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_case',
    '{ "_id": 1, "v": "a" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_case',
    '{ "_id": 2, "v": "A" }');
SELECT count(*) AS simple_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_simple_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_simple_case');

-- simple_exact
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_simple_exact", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "simple" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_exact',
    '{ "_id": 1, "v": "a" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_exact',
    '{ "_id": 2, "v": "a" }');
SELECT count(*) AS simple_exact_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_simple_exact');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_simple_exact');

-- BSON type fidelity and recursive string comparison
-- int_double
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_int_double", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_int_double',
    '{ "_id": 1, "v": 5 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_int_double',
    '{ "_id": 2, "v": { "$numberDouble": "5.0" } }');
SELECT count(*) AS int_double_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_int_double');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_int_double');

-- int_long
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_int_long", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_int_long',
    '{ "_id": 1, "v": 5 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_int_long',
    '{ "_id": 2, "v": { "$numberLong": "5" } }');
SELECT count(*) AS int_long_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_int_long');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_int_long');

-- int_decimal
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_int_decimal", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_int_decimal',
    '{ "_id": 1, "v": 5 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_int_decimal',
    '{ "_id": 2, "v": { "$numberDecimal": "5.00" } }');
SELECT count(*) AS int_decimal_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_int_decimal');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_int_decimal');

-- fraction_decimal_scale
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_fraction_decimal_scale", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_fraction_decimal_scale',
    '{ "_id": 1, "v": { "$numberDecimal": "1.25" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_fraction_decimal_scale',
    '{ "_id": 2, "v": { "$numberDecimal": "1.250" } }');
SELECT count(*) AS fraction_decimal_scale_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_fraction_decimal_scale');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_fraction_decimal_scale');

-- fraction_double_decimal
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_fraction_double_decimal", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_fraction_double_decimal',
    '{ "_id": 1, "v": { "$numberDouble": "1.25" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_fraction_double_decimal',
    '{ "_id": 2, "v": { "$numberDecimal": "1.25" } }');
SELECT count(*) AS fraction_double_decimal_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_fraction_double_decimal');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_fraction_double_decimal');

-- precision_not_rounded
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_precision_not_rounded", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_precision_not_rounded',
    '{ "_id": 1, "v": { "$numberLong": "9007199254740993" } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_precision_not_rounded',
    '{ "_id": 2, "v": { "$numberDouble": "9007199254740992" } }');
SELECT count(*) AS precision_not_rounded_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_precision_not_rounded');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_precision_not_rounded');

-- long_max_not_rounded
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_long_max_not_rounded", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_long_max_not_rounded',
    '{ "_id": 1, "v": { "$numberLong": "9223372036854775807" } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_long_max_not_rounded',
    '{ "_id": 2, "v": { "$numberDecimal": "9223372036854775806" } }');
SELECT count(*) AS long_max_not_rounded_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_long_max_not_rounded');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_long_max_not_rounded');

-- signed_zero
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_signed_zero", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_signed_zero',
    '{ "_id": 1, "v": { "$numberDouble": "-0.0" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_signed_zero',
    '{ "_id": 2, "v": { "$numberDecimal": "0" } }');
SELECT count(*) AS signed_zero_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_signed_zero');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_signed_zero');

-- nan
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_nan", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_nan',
    '{ "_id": 1, "v": { "$numberDouble": "NaN" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_nan',
    '{ "_id": 2, "v": { "$numberDecimal": "NaN" } }');
SELECT count(*) AS nan_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_nan');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_nan');

-- infinity
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_infinity", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_infinity',
    '{ "_id": 1, "v": { "$numberDouble": "Infinity" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_infinity',
    '{ "_id": 2, "v": { "$numberDecimal": "Infinity" } }');
SELECT count(*) AS infinity_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_infinity');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_infinity');

-- number_not_string
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_number_not_string", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_number_not_string',
    '{ "_id": 1, "v": 5 }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_number_not_string',
    '{ "_id": 2, "v": "5" }');
SELECT count(*) AS number_not_string_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_number_not_string');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_number_not_string');

-- boolean_not_number
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_boolean_not_number", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_boolean_not_number',
    '{ "_id": 1, "v": true }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_boolean_not_number',
    '{ "_id": 2, "v": 1 }');
SELECT count(*) AS boolean_not_number_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_boolean_not_number');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_boolean_not_number');

-- booleans
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_booleans", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_booleans',
    '{ "_id": 1, "v": true }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_booleans',
    '{ "_id": 2, "v": false }');
SELECT count(*) AS booleans_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_booleans');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_booleans');

-- boolean_exact
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_boolean_exact", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_boolean_exact',
    '{ "_id": 1, "v": true }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_boolean_exact',
    '{ "_id": 2, "v": true }');
SELECT count(*) AS boolean_exact_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_boolean_exact');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_boolean_exact');

-- object_id_exact
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_object_id_exact", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_id_exact',
    '{ "_id": 1, "v": { "$oid": "507f1f77bcf86cd799439011" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_id_exact',
    '{ "_id": 2, "v": { "$oid": "507f1f77bcf86cd799439011" } }');
SELECT count(*) AS object_id_exact_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_object_id_exact');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_object_id_exact');

-- date_exact
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_date_exact", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_date_exact',
    '{ "_id": 1, "v": { "$date": { "$numberLong": "42" } } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_date_exact',
    '{ "_id": 2, "v": { "$date": { "$numberLong": "42" } } }');
SELECT count(*) AS date_exact_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_date_exact');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_date_exact');

-- date_not_timestamp
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_date_not_timestamp", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_date_not_timestamp',
    '{ "_id": 1, "v": { "$date": { "$numberLong": "42" } } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_date_not_timestamp',
    '{ "_id": 2, "v": { "$timestamp": { "t": 42, "i": 0 } } }');
SELECT count(*) AS date_not_timestamp_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_date_not_timestamp');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_date_not_timestamp');

-- timestamp_increment
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_timestamp_increment", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_timestamp_increment',
    '{ "_id": 1, "v": { "$timestamp": { "t": 42, "i": 0 } } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_timestamp_increment',
    '{ "_id": 2, "v": { "$timestamp": { "t": 42, "i": 1 } } }');
SELECT count(*) AS timestamp_increment_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_timestamp_increment');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_timestamp_increment');

-- binary_not_collated
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_binary_not_collated", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_binary_not_collated',
    '{ "_id": 1, "v": { "$binary": { "base64": "YQ==", "subType": "00" } } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_binary_not_collated',
    '{ "_id": 2, "v": { "$binary": { "base64": "QQ==", "subType": "00" } } }');
SELECT count(*) AS binary_not_collated_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_binary_not_collated');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_binary_not_collated');

-- binary_subtype
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_binary_subtype", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_binary_subtype',
    '{ "_id": 1, "v": { "$binary": { "base64": "YQ==", "subType": "00" } } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_binary_subtype',
    '{ "_id": 2, "v": { "$binary": { "base64": "YQ==", "subType": "80" } } }');
SELECT count(*) AS binary_subtype_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_binary_subtype');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_binary_subtype');

-- regex_not_collated
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_regex_not_collated", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_regex_not_collated',
    '{ "_id": 1, "v": { "$regularExpression": { "pattern": "a", "options": "i" } } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_regex_not_collated',
    '{ "_id": 2, "v": { "$regularExpression": { "pattern": "A", "options": "i" } } }');
SELECT count(*) AS regex_not_collated_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_regex_not_collated');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_regex_not_collated');

-- regex_options
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_regex_options", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_regex_options',
    '{ "_id": 1, "v": { "$regularExpression": { "pattern": "a", "options": "i" } } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_regex_options',
    '{ "_id": 2, "v": { "$regularExpression": { "pattern": "a", "options": "" } } }');
SELECT count(*) AS regex_options_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_regex_options');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_regex_options');

-- code_not_collated
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_code_not_collated", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_code_not_collated',
    '{ "_id": 1, "v": { "$code": "return a;" } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_code_not_collated',
    '{ "_id": 2, "v": { "$code": "return A;" } }');
SELECT count(*) AS code_not_collated_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_code_not_collated');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_code_not_collated');

-- scope_not_collated
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_scope_not_collated", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_scope_not_collated',
    '{ "_id": 1, "v": { "$code": "return x;", "$scope": { "x": "a" } } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_scope_not_collated',
    '{ "_id": 2, "v": { "$code": "return x;", "$scope": { "x": "A" } } }');
SELECT count(*) AS scope_not_collated_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_scope_not_collated');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_scope_not_collated');

-- symbol_string
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_symbol_string", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_symbol_string',
    '{ "_id": 1, "v": { "$symbol": "a" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_symbol_string',
    '{ "_id": 2, "v": "A" }');
SELECT count(*) AS symbol_string_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_symbol_string');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_symbol_string');

-- symbol_symbol
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_symbol_symbol", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_symbol_symbol',
    '{ "_id": 1, "v": { "$symbol": "a" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_symbol_symbol',
    '{ "_id": 2, "v": { "$symbol": "A" } }');
SELECT count(*) AS symbol_symbol_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_symbol_symbol');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_symbol_symbol');

-- min_key
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_min_key", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_min_key',
    '{ "_id": 1, "v": { "$minKey": 1 } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_min_key',
    '{ "_id": 2, "v": { "$minKey": 1 } }');
SELECT count(*) AS min_key_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_min_key');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_min_key');

-- max_key
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_max_key", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_max_key',
    '{ "_id": 1, "v": { "$maxKey": 1 } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_max_key',
    '{ "_id": 2, "v": { "$maxKey": 1 } }');
SELECT count(*) AS max_key_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_max_key');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_max_key');

-- min_not_max
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_min_not_max", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_min_not_max',
    '{ "_id": 1, "v": { "$minKey": 1 } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_min_not_max',
    '{ "_id": 2, "v": { "$maxKey": 1 } }');
SELECT count(*) AS min_not_max_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_min_not_max');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_min_not_max');

-- object_value_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_object_value_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_value_case',
    '{ "_id": 1, "v": { "x": "a" } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_value_case',
    '{ "_id": 2, "v": { "x": "A" } }');
SELECT count(*) AS object_value_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_object_value_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_object_value_case');

-- object_field_name
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_object_field_name", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_field_name',
    '{ "_id": 1, "v": { "x": "a" } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_field_name',
    '{ "_id": 2, "v": { "X": "a" } }');
SELECT count(*) AS object_field_name_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_object_field_name');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_object_field_name');

-- object_field_order
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_object_field_order", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_field_order',
    '{ "_id": 1, "v": { "x": "a", "y": 1 } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_object_field_order',
    '{ "_id": 2, "v": { "y": 1, "x": "a" } }');
SELECT count(*) AS object_field_order_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_object_field_order');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_object_field_order');

-- deep_object
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_deep_object", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_deep_object',
    '{ "_id": 1, "v": { "x": { "y": [ "a", 1 ] } } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_deep_object',
    '{ "_id": 2, "v": { "x": { "y": [ "A", 1.0 ] } } }');
SELECT count(*) AS deep_object_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_deep_object');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_deep_object');

-- nested_array_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_nested_array_case", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_nested_array_case',
    '{ "_id": 1, "v": [ [ "a", "b" ] ] }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_nested_array_case',
    '{ "_id": 2, "v": [ [ "A", "B" ] ] }');
SELECT count(*) AS nested_array_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_nested_array_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_nested_array_case');

-- nested_array_order
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_nested_array_order", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_nested_array_order',
    '{ "_id": 1, "v": [ [ "a", "b" ] ] }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_nested_array_order',
    '{ "_id": 2, "v": [ [ "b", "a" ] ] }');
SELECT count(*) AS nested_array_order_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_nested_array_order');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_nested_array_order');

-- Ordered queries: matching and mismatching collations, forward and reverse scans
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "ordering", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "ordering", "documents": [ { "_id": 1, "v": "item1" }, { "_id": 2, "v": "item10" }, { "_id": 3, "v": "item2" }, { "_id": 4, "v": "item20" }, { "_id": 5, "v": "item3" } ], "ordered": true }');
SELECT documentdb_api.insert_one('unique_collation_db', 'ordering',
    '{ "_id": 6, "v": "ITEM02" }');
SELECT documentdb_api.compact('{ "compact": "ordering", "$db": "unique_collation_db", "mode": "updateStats" }');

SET enable_indexscan TO off;
SET enable_bitmapscan TO off;
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "sort": { "v": 1 }, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "filter": { "v": { "$gte": "ITEM02", "$lt": "item20" } }, "sort": { "v": 1 }, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }');
SET enable_indexscan TO on;
SET enable_bitmapscan TO on;
SET enable_seqscan TO off;
SET documentdb.forceDisableSeqScan TO on;
SELECT documentdb_test_helpers.explain_plan_contains($q$
    SELECT document FROM bson_aggregation_find('unique_collation_db',
        '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }')
$q$, 'Index (Only )?Scan using unique_v') AS ordered_index_used;
SELECT NOT documentdb_test_helpers.explain_plan_contains($q$
    SELECT document FROM bson_aggregation_find('unique_collation_db',
        '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }')
$q$, 'Sort') AS index_provides_order;
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "sort": { "v": -1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "filter": { "v": { "$gte": "ITEM02", "$lt": "item20" } }, "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "filter": { "v": { "$in": [ "ITEM02", "ITEM010" ] } }, "sort": { "v": 1 }, "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "sort": { "v": 1 }, "skip": 1, "limit": 3, "hint": "unique_v", "collation": { "locale": "en", "strength": 2, "numericOrdering": true } }');
-- A forced-index rejection is not the normal mismatched-collation fallback.
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "simple" } }');
RESET documentdb.forceDisableSeqScan;
RESET enable_seqscan;
SELECT documentdb_test_helpers.explain_plan_contains($q$
    SELECT document FROM bson_aggregation_find('unique_collation_db',
        '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "simple" } }')
$q$, 'Index (Only )?Scan using unique_v') AS mismatched_collation_uses_ordered_index;
SELECT documentdb_test_helpers.explain_plan_contains($q$
    SELECT document FROM bson_aggregation_find('unique_collation_db',
        '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "simple" } }')
$q$, 'Sort') AS mismatched_collation_uses_runtime_sort;
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "simple" } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "filter": { "v": "ITEM02" }, "hint": "unique_v", "collation": { "locale": "simple" } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "ordering", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 2, "numericOrdering": false } }');

-- Compound uniqueness and all four key-direction combinations
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "compound", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "asc_asc", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "compound", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "asc_desc", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "compound", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "desc_asc", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "compound", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "desc_desc", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "compound", "documents": [ { "_id": 1, "v": "alpha", "n": 1 }, { "_id": 2, "v": "ALPHA", "n": 2 }, { "_id": 3, "v": "beta", "n": 1 }, { "_id": 4, "v": "BETA", "n": 2 } ], "ordered": true }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound',
    '{ "_id": 5, "v": "aLpHa", "n": 2.0 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound',
    '{ "_id": 6, "v": "alpha", "n": 3 }');
SET enable_seqscan TO off;
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "compound", "sort": { "v": 1, "n": 1 }, "hint": "asc_asc", "collation": { "locale": "en", "strength": 2 } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "compound", "sort": { "v": 1, "n": -1 }, "hint": "asc_desc", "collation": { "locale": "en", "strength": 2 } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "compound", "sort": { "v": -1, "n": 1 }, "hint": "desc_asc", "collation": { "locale": "en", "strength": 2 } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "compound", "sort": { "v": -1, "n": -1 }, "hint": "desc_desc", "collation": { "locale": "en", "strength": 2 } }');
RESET enable_seqscan;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "compound_strings", "indexes": [ { "key": { "left": 1, "right": -1 }, "name": "unique_strings", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 1 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_strings',
    '{ "_id": 1, "left": "caf\u00e9", "right": "blue" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_strings',
    '{ "_id": 2, "left": "CAFE", "right": "BLUE" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_strings',
    '{ "_id": 3, "left": "CAFE", "right": "green" }');

-- Coexisting unique collations constrain writes independently
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "coexisting", "indexes": [ { "key": { "v": 1 }, "name": "unique_primary", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 1 } } ] }',
    true);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "coexisting", "indexes": [ { "key": { "v": 1 }, "name": "unique_tertiary", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'coexisting',
    '{ "_id": 1, "v": "cafe" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'coexisting',
    '{ "_id": 2, "v": "CAF\u00c9" }');
CALL documentdb_api.drop_indexes('unique_collation_db', '{ "dropIndexes": "coexisting", "index": "unique_primary" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'coexisting',
    '{ "_id": 2, "v": "CAF\u00c9" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'coexisting',
    '{ "_id": 3, "v": "CAF\u00c9" }');
SELECT count(*) AS remaining_tertiary_rows
FROM documentdb_api.collection('unique_collation_db', 'coexisting');

-- Locale-specific ordering and caseFirst
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "case_first", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 3, "caseFirst": "upper" } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "case_first", "documents": [ { "_id": 1, "v": "a" }, { "_id": 2, "v": "A" }, { "_id": 3, "v": "b" }, { "_id": 4, "v": "B" } ], "ordered": true }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "case_first", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 3, "caseFirst": "upper" } }');
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "case_first", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "en", "strength": 3, "caseFirst": "lower" } }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "french_order", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "fr", "strength": 2, "backwards": true } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "french_order", "documents": [ { "_id": 1, "v": "cote" }, { "_id": 2, "v": "c\u00f4te" }, { "_id": 3, "v": "cot\u00e9" }, { "_id": 4, "v": "c\u00f4t\u00e9" } ], "ordered": true }');
SET enable_indexscan TO off;
SET enable_bitmapscan TO off;
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "french_order", "sort": { "v": 1 }, "collation": { "locale": "fr", "strength": 2, "backwards": true } }');
SET enable_indexscan TO on;
SET enable_bitmapscan TO on;
SELECT document FROM bson_aggregation_find('unique_collation_db',
    '{ "find": "french_order", "sort": { "v": 1 }, "hint": "unique_v", "collation": { "locale": "fr", "strength": 2, "backwards": true } }');

-- Null, missing, undefined, empty arrays and compound null keys
-- missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_missing_null", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_missing_null',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_missing_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_missing_null');

-- missing_empty_array
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_missing_empty_array", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_missing_empty_array',
    '{ "_id": 1 }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_missing_empty_array',
    '{ "_id": 2, "v": [] }');
SELECT count(*) AS missing_empty_array_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_missing_empty_array');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_missing_empty_array');

-- empty_array_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_empty_array_null", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_array_null',
    '{ "_id": 1, "v": [] }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_array_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS empty_array_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_empty_array_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_empty_array_null');

-- empty_array_duplicate
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_empty_array_duplicate", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_array_duplicate',
    '{ "_id": 1, "v": [] }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_array_duplicate',
    '{ "_id": 2, "v": [] }');
SELECT count(*) AS empty_array_duplicate_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_empty_array_duplicate');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_empty_array_duplicate');

-- missing_undefined
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_missing_undefined", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_missing_undefined',
    '{ "_id": 1 }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_missing_undefined',
    '{ "_id": 2, "v": { "$undefined": true } }');
SELECT count(*) AS missing_undefined_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_missing_undefined');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_missing_undefined');

-- undefined_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_undefined_missing", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_undefined_missing',
    '{ "_id": 1, "v": { "$undefined": true } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_undefined_missing',
    '{ "_id": 2 }');
SELECT count(*) AS undefined_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_undefined_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_undefined_missing');

-- null_undefined
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_null_undefined", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_null_undefined',
    '{ "_id": 1, "v": null }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_null_undefined',
    '{ "_id": 2, "v": { "$undefined": true } }');
SELECT count(*) AS null_undefined_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_null_undefined');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_null_undefined');

-- undefined_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_undefined_null", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_undefined_null',
    '{ "_id": 1, "v": { "$undefined": true } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_undefined_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS undefined_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_undefined_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_undefined_null');

-- empty_array_undefined
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_empty_array_undefined", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_array_undefined',
    '{ "_id": 1, "v": [] }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_empty_array_undefined',
    '{ "_id": 2, "v": { "$undefined": true } }');
SELECT count(*) AS empty_array_undefined_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_empty_array_undefined');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_empty_array_undefined');

-- undefined_array_element
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_undefined_array_element", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_undefined_array_element',
    '{ "_id": 1, "v": { "$undefined": true } }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_undefined_array_element',
    '{ "_id": 2, "v": [ { "$undefined": true } ] }');
SELECT count(*) AS undefined_array_element_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_undefined_array_element');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_undefined_array_element');

-- array_null_scalar
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_array_null_scalar", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_array_null_scalar',
    '{ "_id": 1, "v": [ null ] }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_array_null_scalar',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS array_null_scalar_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_array_null_scalar');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_array_null_scalar');

-- array_undefined_empty
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_array_undefined_empty", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_array_undefined_empty',
    '{ "_id": 1, "v": [ { "$undefined": true } ] }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_array_undefined_empty',
    '{ "_id": 2, "v": [] }');
SELECT count(*) AS array_undefined_empty_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_array_undefined_empty');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_array_undefined_empty');

-- Missing paths and explicit nulls must compare identically in every key direction.
-- dense_asc_asc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_asc_missing_null", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_asc_asc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_asc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_asc_missing_null');

-- dense_asc_asc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_asc_null_missing", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_asc_asc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_asc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_asc_null_missing');

-- dense_asc_asc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_asc_same_case", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS dense_asc_asc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_asc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_asc_same_case');

-- dense_asc_asc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_asc_both_missing", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_asc_asc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_asc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_asc_both_missing');

-- dense_asc_asc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_asc_both_null", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_asc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_asc_asc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_asc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_asc_both_null');

-- dense_asc_desc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_desc_missing_null", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_asc_desc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_desc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_desc_missing_null');

-- dense_asc_desc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_desc_null_missing", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_asc_desc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_desc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_desc_null_missing');

-- dense_asc_desc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_desc_same_case", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS dense_asc_desc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_desc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_desc_same_case');

-- dense_asc_desc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_desc_both_missing", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_asc_desc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_desc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_desc_both_missing');

-- dense_asc_desc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_asc_desc_both_null", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_asc_desc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_asc_desc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_asc_desc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_asc_desc_both_null');

-- dense_desc_asc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_asc_missing_null", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_desc_asc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_asc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_asc_missing_null');

-- dense_desc_asc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_asc_null_missing", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_desc_asc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_asc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_asc_null_missing');

-- dense_desc_asc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_asc_same_case", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS dense_desc_asc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_asc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_asc_same_case');

-- dense_desc_asc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_asc_both_missing", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_desc_asc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_asc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_asc_both_missing');

-- dense_desc_asc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_asc_both_null", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_asc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_desc_asc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_asc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_asc_both_null');

-- dense_desc_desc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_desc_missing_null", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_desc_desc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_desc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_desc_missing_null');

-- dense_desc_desc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_desc_null_missing", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_desc_desc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_desc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_desc_null_missing');

-- dense_desc_desc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_desc_same_case", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS dense_desc_desc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_desc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_desc_same_case');

-- dense_desc_desc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_desc_both_missing", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS dense_desc_desc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_desc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_desc_both_missing');

-- dense_desc_desc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_desc_desc_both_null", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_desc_desc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS dense_desc_desc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_desc_desc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_desc_desc_both_null');

-- sparse_asc_asc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_asc_missing_null", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_asc_asc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_asc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_asc_missing_null');

-- sparse_asc_asc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_asc_null_missing", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_asc_asc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_asc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_asc_null_missing');

-- sparse_asc_asc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_asc_same_case", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS sparse_asc_asc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_asc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_asc_same_case');

-- sparse_asc_asc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_asc_both_missing", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_asc_asc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_asc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_asc_both_missing');

-- sparse_asc_asc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_asc_both_null", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_asc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_asc_asc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_asc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_asc_both_null');

-- sparse_asc_desc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_desc_missing_null", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_asc_desc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_desc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_desc_missing_null');

-- sparse_asc_desc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_desc_null_missing", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_asc_desc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_desc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_desc_null_missing');

-- sparse_asc_desc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_desc_same_case", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS sparse_asc_desc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_desc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_desc_same_case');

-- sparse_asc_desc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_desc_both_missing", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_asc_desc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_desc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_desc_both_missing');

-- sparse_asc_desc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_asc_desc_both_null", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_asc_desc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_asc_desc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_asc_desc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_asc_desc_both_null');

-- sparse_desc_asc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_asc_missing_null", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_desc_asc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_asc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_asc_missing_null');

-- sparse_desc_asc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_asc_null_missing", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_desc_asc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_asc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_asc_null_missing');

-- sparse_desc_asc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_asc_same_case", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS sparse_desc_asc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_asc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_asc_same_case');

-- sparse_desc_asc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_asc_both_missing", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_desc_asc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_asc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_asc_both_missing');

-- sparse_desc_asc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_asc_both_null", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_asc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_desc_asc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_asc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_asc_both_null');

-- sparse_desc_desc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_desc_missing_null", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_missing_null',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_missing_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_desc_desc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_desc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_desc_missing_null');

-- sparse_desc_desc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_desc_null_missing", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_null_missing',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_null_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_desc_desc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_desc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_desc_null_missing');

-- sparse_desc_desc_same_case
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_desc_same_case", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_same_case',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_same_case',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS sparse_desc_desc_same_case_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_desc_same_case');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_desc_same_case');

-- sparse_desc_desc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_desc_both_missing", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_both_missing',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_both_missing',
    '{ "_id": 2, "v": "RED" }');
SELECT count(*) AS sparse_desc_desc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_desc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_desc_both_missing');

-- sparse_desc_desc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_desc_desc_both_null", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_both_null',
    '{ "_id": 1, "v": "red", "n": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_desc_desc_both_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS sparse_desc_desc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_desc_desc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_desc_desc_both_null');

-- simple_compound_distinct
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_simple_compound_distinct", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "simple" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_compound_distinct',
    '{ "_id": 1, "v": "red" }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_compound_distinct',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT count(*) AS simple_compound_distinct_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_simple_compound_distinct');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_simple_compound_distinct');

-- simple_compound_exact
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_simple_compound_exact", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "simple" } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_compound_exact',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_simple_compound_exact',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS simple_compound_exact_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_simple_compound_exact');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_simple_compound_exact');

-- dense_all_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_dense_all_missing", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_all_missing',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_dense_all_missing',
    '{ "_id": 2, "v": null, "n": null }');
SELECT count(*) AS dense_all_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_dense_all_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_dense_all_missing');

-- sparse_all_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_sparse_all_missing", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_all_missing',
    '{ "_id": 1 }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_sparse_all_missing',
    '{ "_id": 2 }');
SELECT count(*) AS sparse_all_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_sparse_all_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_sparse_all_missing');

-- Ordered unique-index gaps: null/missing and undefined semantics
-- Collated single-field descending keys must retain null/missing uniqueness.
-- gap_collated_desc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_collated_desc_missing_null", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_missing_null',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_missing_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS gap_collated_desc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_collated_desc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_collated_desc_missing_null');

-- gap_collated_desc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_collated_desc_null_missing", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_null_missing',
    '{ "_id": 1, "v": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_null_missing',
    '{ "_id": 2 }');
SELECT count(*) AS gap_collated_desc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_collated_desc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_collated_desc_null_missing');

-- gap_collated_desc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_collated_desc_both_missing", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_both_missing',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_both_missing',
    '{ "_id": 2 }');
SELECT count(*) AS gap_collated_desc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_collated_desc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_collated_desc_both_missing');

-- gap_collated_desc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_collated_desc_both_null", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_both_null',
    '{ "_id": 1, "v": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_both_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS gap_collated_desc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_collated_desc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_collated_desc_both_null');

-- Non-collated controls omit the collation property rather than requesting simple.
-- gap_plain_asc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_asc_missing_null", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_missing_null',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_missing_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS gap_plain_asc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_asc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_asc_missing_null');

-- gap_plain_asc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_asc_null_missing", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_null_missing',
    '{ "_id": 1, "v": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_null_missing',
    '{ "_id": 2 }');
SELECT count(*) AS gap_plain_asc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_asc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_asc_null_missing');

-- gap_plain_asc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_asc_both_missing", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_both_missing',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_both_missing',
    '{ "_id": 2 }');
SELECT count(*) AS gap_plain_asc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_asc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_asc_both_missing');

-- gap_plain_asc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_asc_both_null", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_both_null',
    '{ "_id": 1, "v": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_asc_both_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS gap_plain_asc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_asc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_asc_both_null');

-- gap_plain_desc_missing_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_desc_missing_null", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_missing_null',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_missing_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS gap_plain_desc_missing_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_desc_missing_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_desc_missing_null');

-- gap_plain_desc_null_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_desc_null_missing", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_null_missing',
    '{ "_id": 1, "v": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_null_missing',
    '{ "_id": 2 }');
SELECT count(*) AS gap_plain_desc_null_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_desc_null_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_desc_null_missing');

-- gap_plain_desc_both_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_desc_both_missing", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_both_missing',
    '{ "_id": 1 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_both_missing',
    '{ "_id": 2 }');
SELECT count(*) AS gap_plain_desc_both_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_desc_both_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_desc_both_missing');

-- gap_plain_desc_both_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_desc_both_null", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_both_null',
    '{ "_id": 1, "v": null }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_both_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS gap_plain_desc_both_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_desc_both_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_desc_both_null');

-- Non-collated compound controls distinguish leading and trailing direction.
-- gap_plain_compound_asc_asc
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_compound_asc_asc", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_asc_asc',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_asc_asc',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS gap_plain_compound_asc_asc_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_compound_asc_asc');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_compound_asc_asc');

-- gap_plain_compound_asc_desc
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_compound_asc_desc", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_asc_desc',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_asc_desc',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS gap_plain_compound_asc_desc_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_compound_asc_desc');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_compound_asc_desc');

-- gap_plain_compound_desc_asc
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_compound_desc_asc", "indexes": [ { "key": { "v": -1, "n": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_desc_asc',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_desc_asc',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS gap_plain_compound_desc_asc_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_compound_desc_asc');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_compound_desc_asc');

-- gap_plain_compound_desc_desc
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_compound_desc_desc", "indexes": [ { "key": { "v": -1, "n": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_desc_desc',
    '{ "_id": 1, "v": "red" }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_compound_desc_desc',
    '{ "_id": 2, "v": "red", "n": null }');
SELECT count(*) AS gap_plain_compound_desc_desc_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_compound_desc_desc');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_compound_desc_desc');

-- Defined descending keys retain duplicate rejection with and without collation.
-- gap_collated_desc_number_duplicate
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_collated_desc_number_duplicate", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_number_duplicate',
    '{ "_id": 1, "v": 5 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_collated_desc_number_duplicate',
    '{ "_id": 2, "v": 5 }');
SELECT count(*) AS gap_collated_desc_number_duplicate_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_collated_desc_number_duplicate');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_collated_desc_number_duplicate');

-- gap_plain_desc_number_duplicate
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_desc_number_duplicate", "indexes": [ { "key": { "v": -1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_number_duplicate',
    '{ "_id": 1, "v": 5 }');
-- Equivalent indexed keys are rejected.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_desc_number_duplicate',
    '{ "_id": 2, "v": 5 }');
SELECT count(*) AS gap_plain_desc_number_duplicate_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_desc_number_duplicate');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_desc_number_duplicate');

-- Non-collated undefined controls preserve type distinctions and insertion order.
-- gap_plain_missing_undefined
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_missing_undefined", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_missing_undefined',
    '{ "_id": 1 }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_missing_undefined',
    '{ "_id": 2, "v": { "$undefined": true } }');
SELECT count(*) AS gap_plain_missing_undefined_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_missing_undefined');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_missing_undefined');

-- gap_plain_undefined_missing
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_undefined_missing", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_undefined_missing',
    '{ "_id": 1, "v": { "$undefined": true } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_undefined_missing',
    '{ "_id": 2 }');
SELECT count(*) AS gap_plain_undefined_missing_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_undefined_missing');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_undefined_missing');

-- gap_plain_null_undefined
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_null_undefined", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_null_undefined',
    '{ "_id": 1, "v": null }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_null_undefined',
    '{ "_id": 2, "v": { "$undefined": true } }');
SELECT count(*) AS gap_plain_null_undefined_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_null_undefined');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_null_undefined');

-- gap_plain_undefined_null
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "pair_gap_plain_undefined_null", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": false, "enableOrderedIndex": true } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_undefined_null',
    '{ "_id": 1, "v": { "$undefined": true } }');
-- Distinct indexed keys are accepted.
SELECT documentdb_api.insert_one('unique_collation_db', 'pair_gap_plain_undefined_null',
    '{ "_id": 2, "v": null }');
SELECT count(*) AS gap_plain_undefined_null_rows
FROM documentdb_api.collection('unique_collation_db', 'pair_gap_plain_undefined_null');
SELECT documentdb_api.drop_collection('unique_collation_db', 'pair_gap_plain_undefined_null');

-- Batched null and compound writes.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "nulls", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'nulls',
    '{ "_id": 1 }');
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "nulls", "documents": [ { "_id": 2, "v": null }, { "_id": 3, "v": { "$undefined": true } }, { "_id": 4, "v": [ null ] }, { "_id": 5, "v": [ { "$undefined": true } ] } ], "ordered": false }');
SELECT documentdb_api.insert_one('unique_collation_db', 'nulls',
    '{ "_id": 6, "v": [] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'nulls',
    '{ "_id": 7, "v": [] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'nulls',
    '{ "_id": 8, "v": "" }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "compound_null", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_vn", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_null',
    '{ "_id": 1, "v": "red" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_null',
    '{ "_id": 2, "v": "RED", "n": null }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_null',
    '{ "_id": 3, "v": "RED", "n": 1 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_null',
    '{ "_id": 4, "n": 1 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'compound_null',
    '{ "_id": 5, "v": null, "n": 1 }');

-- Sparse single, compound and dotted indexes; moving into and out of coverage
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "sparse", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "sparse", "documents": [ { "_id": 1 }, { "_id": 2 } ], "ordered": true }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse',
    '{ "_id": 3, "v": null }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse',
    '{ "_id": 4, "v": null }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse',
    '{ "_id": 5, "v": "red" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse',
    '{ "_id": 6, "v": "RED" }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "sparse", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "v": "RED" } } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "sparse", "updates": [ { "q": { "_id": 5 }, "u": { "$unset": { "v": 1 } } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "sparse", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "v": "RED" } } } ] }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'sparse') ORDER BY object_id;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "sparse_compound", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_vn", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "sparse_compound", "documents": [ { "_id": 1 }, { "_id": 2 } ], "ordered": true }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_compound',
    '{ "_id": 3, "v": "red" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_compound',
    '{ "_id": 4, "v": "RED", "n": null }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_compound',
    '{ "_id": 5, "n": 1 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_compound',
    '{ "_id": 6, "v": null, "n": 1 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_compound',
    '{ "_id": 7, "v": null, "n": 2 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_compound',
    '{ "_id": 8, "n": 2 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "sparse_dotted", "indexes": [ { "key": { "p.q": -1 }, "name": "unique_pq", "unique": true, "sparse": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "sparse_dotted", "documents": [ { "_id": 1, "p": {} }, { "_id": 2, "p": [ { "other": 1 } ] } ], "ordered": true }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_dotted',
    '{ "_id": 3, "p": [ { "q": "red" }, { "other": 1 } ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_dotted',
    '{ "_id": 4, "p": { "q": null } }');
SELECT documentdb_api.insert_one('unique_collation_db', 'sparse_dotted',
    '{ "_id": 5, "p": { "q": "RED" } }');

-- Partial indexes: membership uses the index collation and writes remain atomic
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "partial", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "partialFilterExpression": { "active": true }, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "partial", "documents": [ { "_id": 1, "v": "red", "active": true }, { "_id": 2, "v": "RED", "active": false }, { "_id": 3, "v": "Red" } ], "ordered": true }');
SELECT documentdb_api.insert_one('unique_collation_db', 'partial',
    '{ "_id": 4, "v": "RED", "active": true }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "partial", "updates": [ { "q": { "_id": 2 }, "u": { "$set": { "active": true } } } ] }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'partial') WHERE document @@ '{ "_id": 2 }';
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "partial", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "active": false } } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "partial", "updates": [ { "q": { "_id": 2 }, "u": { "$set": { "active": true } } } ] }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'partial') ORDER BY object_id;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "partial_string", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "partialFilterExpression": { "state": "ACTIVE" }, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'partial_string',
    '{ "_id": 1, "v": "red", "state": "active" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'partial_string',
    '{ "_id": 2, "v": "RED", "state": "ACTIVE" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'partial_string',
    '{ "_id": 3, "v": "RED", "state": "inactive" }');

-- Multikey uniqueness, duplicate elements, nested paths and correlated tuples
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "multikey", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey',
    '{ "_id": 1, "v": [ "Red", "RED", "Green" ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey',
    '{ "_id": 2, "v": "red" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey',
    '{ "_id": 3, "v": [ "GREEN", "Blue" ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey',
    '{ "_id": 4, "v": [ "Blue", "Yellow" ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "multikey", "updates": [ { "q": { "_id": 4 }, "u": { "$set": { "v": [ "YELLOW", "RED" ] } } } ] }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'multikey') WHERE document @@ '{ "_id": 4 }';
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "multikey", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "v": [ "Green" ] } } } ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey',
    '{ "_id": 5, "v": "RED" }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "dotted", "indexes": [ { "key": { "p.q": 1 }, "name": "unique_pq", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'dotted',
    '{ "_id": 1, "p": [ { "q": "Red" }, { "other": 1 } ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'dotted',
    '{ "_id": 2, "p": { "q": "RED" } }');
SELECT documentdb_api.insert_one('unique_collation_db', 'dotted',
    '{ "_id": 3, "p": { "q": null } }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "multikey_compound", "indexes": [ { "key": { "v": 1, "n": 1 }, "name": "unique_vn", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey_compound',
    '{ "_id": 1, "v": [ "Red", "Green" ], "n": 1 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey_compound',
    '{ "_id": 2, "v": "RED", "n": 1 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey_compound',
    '{ "_id": 3, "v": "RED", "n": 2 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "correlated", "indexes": [ { "key": { "items.v": 1, "items.n": 1 }, "name": "unique_items", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'correlated',
    '{ "_id": 1, "items": [ { "v": "Red", "n": 1 }, { "v": "Blue", "n": 2 } ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'correlated',
    '{ "_id": 2, "items": [ { "v": "RED", "n": 1 } ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'correlated',
    '{ "_id": 3, "items": [ { "v": "RED", "n": 2 } ] }');
SET documentdb.enableFailureOnParallelIndexArrays TO on;
SELECT documentdb_api.insert_one('unique_collation_db', 'multikey_compound',
    '{ "_id": 4, "v": [ "white", "black" ], "n": [ 3, 4 ] }');
RESET documentdb.enableFailureOnParallelIndexArrays;

-- Direct, ordered and unordered inserts; failed rows do not reserve unique keys
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "writes", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'writes', '{ "_id": 1, "v": "Alice", "counter": 0 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'writes', '{ "_id": 2, "v": "Bob", "counter": 0 }');
SELECT documentdb_api.insert_one('unique_collation_db', 'writes', '{ "_id": 3, "v": "ALICE" }');
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "writes", "documents": [ { "_id": 4, "v": "Carol" }, { "_id": 5, "v": "BOB" }, { "_id": 6, "v": "Dave" } ], "ordered": true }');
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "writes", "documents": [ { "_id": 7, "v": "Eve" }, { "_id": 8, "v": "ALICE" }, { "_id": 9, "v": "Frank" }, { "_id": 10, "v": "EVE" } ], "ordered": false }');
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 5, "v": "Grace" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 6, "v": "Dave" }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'writes') ORDER BY object_id;
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "v": "Helen" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "v": "HELEN" }');
-- Generated identifiers vary between runs; retain their type and document value.
SELECT bson_dollar_project(document, '{ "_id": { "$type": "$_id" }, "v": 1 }') AS document
FROM documentdb_api.collection('unique_collation_db', 'writes')
WHERE document @@ '{ "v": { "$in": [ "Helen", "HELEN" ] } }'
ORDER BY object_id;

-- Updates, replacements, pipelines and upserts preserve index-based uniqueness
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "v": "ALICE" } } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 2 }, "u": { "$set": { "v": "alice" } } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 2 }, "u": { "v": "Alice" } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 2 }, "u": [ { "$set": { "v": "ALICE" } } ] } ] }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'writes') WHERE document @@ '{ "_id": 2 }';
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 20 }, "u": { "$set": { "v": "ALICE" } }, "upsert": true } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 21 }, "u": { "v": "BOB" }, "upsert": true } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 22 }, "u": [ { "$set": { "v": "Ivy" } } ], "upsert": true } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "v": "aLiCe" }, "u": { "$inc": { "counter": 1 } }, "upsert": true, "collation": { "locale": "en", "strength": 2 } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "v": "aLiCe" }, "u": { "$set": { "_id": 23, "v": "ALICE" } }, "upsert": true, "collation": { "locale": "simple" } } ] }');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "ordered": false, "updates": [ { "q": { "_id": 2 }, "u": { "$set": { "v": "ALICE" } } }, { "q": { "_id": 4 }, "u": { "$inc": { "counter": 1 } } } ] }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'writes') WHERE document @@ '{ "_id": { "$in": [ 1, 2, 4, 22 ] } }' ORDER BY object_id;

-- findAndModify, key release and collation changes in write commands
SELECT documentdb_api.find_and_modify('unique_collation_db',
    '{ "findAndModify": "writes", "query": { "v": "alice" }, "update": { "$inc": { "counter": 1 } }, "new": true, "collation": { "locale": "en", "strength": 2 } }');
SELECT documentdb_api.find_and_modify('unique_collation_db',
    '{ "findAndModify": "writes", "query": { "_id": 2 }, "update": { "$set": { "v": "ALICE" } }, "new": true }');
SELECT documentdb_api.find_and_modify('unique_collation_db',
    '{ "findAndModify": "writes", "query": { "_id": 24 }, "update": { "v": "alice" }, "upsert": true, "new": true }');
SELECT documentdb_api.find_and_modify('unique_collation_db',
    '{ "findAndModify": "writes", "query": { "_id": 25 }, "update": { "v": "Jack" }, "upsert": true, "new": true }');
SELECT documentdb_api.delete('unique_collation_db',
    '{ "delete": "writes", "deletes": [ { "q": { "v": "jAcK" }, "limit": 1, "collation": { "locale": "en", "strength": 2 } } ] }');
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 26, "v": "JACK" }');

-- $out preserves target uniqueness and leaves the target unchanged on failure
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "out_target", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'out_target',
    '{ "_id": 1, "v": "retained" }');
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "out_source", "documents": [ { "_id": 2, "v": "red" }, { "_id": 3, "v": "RED" } ], "ordered": true }');
SELECT cursorPage
FROM documentdb_api.aggregate_cursor_first_page('unique_collation_db',
    '{ "aggregate": "out_source", "pipeline": [ { "$out": "out_target" } ], "cursor": {} }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'out_target')
ORDER BY object_id;
SELECT documentdb_api.delete('unique_collation_db',
    '{ "delete": "out_source", "deletes": [ { "q": { "_id": 3 }, "limit": 1 } ] }');
SELECT cursorPage
FROM documentdb_api.aggregate_cursor_first_page('unique_collation_db',
    '{ "aggregate": "out_source", "pipeline": [ { "$out": "out_target" } ], "cursor": {} }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'out_target')
ORDER BY object_id;
SELECT documentdb_api.insert_one('unique_collation_db', 'out_target',
    '{ "_id": 4, "v": "RED" }');

-- Transactions, savepoints and retryable writes
BEGIN;
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 30, "v": "transaction" }');
SAVEPOINT duplicate_insert;
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 31, "v": "TRANSACTION" }');
ROLLBACK TO SAVEPOINT duplicate_insert;
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 32, "v": "transaction_two" }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'writes')
WHERE document @@ '{ "_id": { "$in": [ 30, 32 ] } }'
ORDER BY object_id;
ROLLBACK;
SELECT document FROM documentdb_api.collection('unique_collation_db', 'writes')
WHERE document @@ '{ "_id": { "$in": [ 30, 31, 32 ] } }'
ORDER BY object_id;
BEGIN;
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 35, "v": "committed" }');
COMMIT;
SELECT documentdb_api.insert_one('unique_collation_db', 'writes',
    '{ "_id": 36, "v": "COMMITTED" }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'writes')
WHERE document @@ '{ "_id": { "$in": [ 35, 36 ] } }'
ORDER BY object_id;
BEGIN;
SELECT * FROM documentdb_api.insert('unique_collation_db',
    '{ "insert": "writes", "documents": [ { "_id": 33, "v": "Retry" } ] }', p_transaction_id => 'unique-collation-insert');
SELECT * FROM documentdb_api.insert('unique_collation_db',
    '{ "insert": "writes", "documents": [ { "_id": 33, "v": "Retry" } ] }', p_transaction_id => 'unique-collation-insert');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 1 }, "u": { "$inc": { "counter": 1 } } } ] }',
    p_transaction_id => 'unique-collation-update');
SELECT documentdb_api.update('unique_collation_db',
    '{ "update": "writes", "updates": [ { "q": { "_id": 1 }, "u": { "$inc": { "counter": 1 } } } ] }',
    p_transaction_id => 'unique-collation-update');
SELECT documentdb_api.find_and_modify('unique_collation_db',
    '{ "findAndModify": "writes", "query": { "_id": 34 }, "update": { "$set": { "v": "RetryFam", "counter": 1 } }, "upsert": true, "new": true }',
    'unique-collation-fam');
SELECT documentdb_api.find_and_modify('unique_collation_db',
    '{ "findAndModify": "writes", "query": { "_id": 34 }, "update": { "$set": { "v": "RetryFam", "counter": 1 } }, "upsert": true, "new": true }',
    'unique-collation-fam');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'writes') WHERE document @@ '{ "_id": { "$in": [ 1, 33, 34 ] } }' ORDER BY object_id;
ROLLBACK;

-- Truncation guards and full-value rechecks beyond the stored key boundary
SET documentdb.indexTermLimitOverride TO 50;
SET documentdb.fail_on_collated_index_term_truncation TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "guarded_long", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'guarded_long',
    bson_build_document('_id', 1, 'v', repeat('a', 200) || 'x'));
SELECT document FROM documentdb_api.collection('unique_collation_db', 'guarded_long')
ORDER BY object_id;
SET documentdb.fail_on_collated_index_term_truncation TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "long_keys", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'long_keys',
    bson_build_document('_id', 1, 'v', repeat('a', 2000) || 'suffix_x'));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_keys',
    bson_build_document('_id', 2, 'v', repeat('A', 2000) || 'SUFFIX_X'));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_keys',
    bson_build_document('_id', 3, 'v', repeat('a', 2000) || 'suffix_y'));
SELECT document FROM documentdb_api.collection('unique_collation_db', 'long_keys')
ORDER BY object_id;
SET enable_seqscan TO off;
CREATE TEMP TABLE full_value_query AS
SELECT document FROM bson_aggregation_find('unique_collation_db',
    bson_build_document('find', 'long_keys'::text,
        'filter', bson_build_document('v', repeat('A', 2000) || 'SUFFIX_Y'),
        'hint', 'unique_v'::text, 'collation', '{ "locale": "en", "strength": 2 }'::bson));
SELECT document FROM full_value_query ORDER BY document;
DROP TABLE full_value_query;
RESET enable_seqscan;
SELECT documentdb_api.insert_one('unique_collation_db', 'long_keys',
    bson_build_document('_id', 4, 'v', repeat(chr(233), 1000) || 'multibyte_x'));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_keys',
    bson_build_document('_id', 5, 'v', repeat(chr(201), 1000) || 'MULTIBYTE_X'));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_keys',
    bson_build_document('_id', 6, 'v', repeat(chr(233), 1000) || 'multibyte_y'));
SELECT document FROM documentdb_api.collection('unique_collation_db', 'long_keys')
ORDER BY object_id;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "long_compound", "indexes": [ { "key": { "v": 1, "n": -1 }, "name": "unique_vn", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'long_compound',
    bson_build_document('_id', 1, 'v', repeat('a', 1000), 'n', 'red'::text));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_compound',
    bson_build_document('_id', 2, 'v', repeat('A', 1000), 'n', 'RED'::text));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_compound',
    bson_build_document('_id', 3, 'v', repeat('A', 1000), 'n', 'blue'::text));
SELECT document FROM documentdb_api.collection('unique_collation_db', 'long_compound')
ORDER BY object_id;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "long_nested", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'long_nested',
    bson_build_document('_id', 1, 'v', bson_build_document('padding', repeat('a', 1000), 'tail', 'red'::text)));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_nested',
    bson_build_document('_id', 2, 'v', bson_build_document('padding', repeat('A', 1000), 'tail', 'RED'::text)));
SELECT documentdb_api.insert_one('unique_collation_db', 'long_nested',
    bson_build_document('_id', 3, 'v', bson_build_document('padding', repeat('a', 1000), 'tail', 'blue'::text)));
SELECT document FROM documentdb_api.collection('unique_collation_db', 'long_nested')
ORDER BY object_id;
SELECT documentdb_api.update('unique_collation_db',
    bson_build_document('update', 'long_keys'::text, 'updates',
        ARRAY[bson_build_document('q', '{ "_id": 3 }'::bson,
              'u', bson_build_document('$set', bson_build_document('v', repeat('A', 2000) || 'SUFFIX_X')))]));
SELECT document
FROM documentdb_api.collection('unique_collation_db', 'long_keys')
WHERE document @@ bson_build_document('v', repeat('a', 2000) || 'suffix_y')
ORDER BY object_id;
RESET documentdb.indexTermLimitOverride;
RESET documentdb.fail_on_collated_index_term_truncation;

-- Build over existing data: success, duplicate cleanup and retry
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "build_ok", "documents": [ { "_id": 1, "v": "red" }, { "_id": 2, "v": "blue" } ], "ordered": true }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "build_ok", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'build_ok',
    '{ "_id": 3, "v": "RED" }');
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "build_duplicate", "documents": [ { "_id": 1, "v": "red" }, { "_id": 2, "v": "RED" } ], "ordered": true }');
\set VERBOSITY TERSE
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "build_duplicate", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
\set VERBOSITY DEFAULT
SELECT * FROM documentdb_test_helpers.get_collection_indexes('unique_collation_db', 'build_duplicate')
ORDER BY index_id;
SELECT document FROM documentdb_api.collection('unique_collation_db', 'build_duplicate')
ORDER BY object_id;
SELECT documentdb_api.delete('unique_collation_db',
    '{ "delete": "build_duplicate", "deletes": [ { "q": { "_id": 2 }, "limit": 1 } ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "build_duplicate", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'build_duplicate',
    '{ "_id": 3, "v": "RED" }');

-- Unique-index hide changes are unsupported; drop and recreate rechecks the data
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "maintenance", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "maintenance", "documents": [ { "_id": 1, "v": "red" }, { "_id": 2, "v": "blue" } ], "ordered": true }');
SELECT documentdb_api.coll_mod('unique_collation_db', 'maintenance',
    '{ "collMod": "maintenance", "index": { "name": "unique_v", "hidden": true } }');
SELECT documentdb_api.insert_one('unique_collation_db', 'maintenance',
    '{ "_id": 3, "v": "RED" }');
SELECT documentdb_api.coll_mod('unique_collation_db', 'maintenance',
    '{ "collMod": "maintenance", "index": { "name": "unique_v", "hidden": false } }');
CALL documentdb_api.drop_indexes('unique_collation_db', '{ "dropIndexes": "maintenance", "index": "unique_v" }');
SELECT documentdb_api.insert_one('unique_collation_db', 'maintenance',
    '{ "_id": 3, "v": "RED" }');
\set VERBOSITY TERSE
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "maintenance", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
\set VERBOSITY DEFAULT
SELECT documentdb_api.delete('unique_collation_db',
    '{ "delete": "maintenance", "deletes": [ { "q": { "_id": 3 }, "limit": 1 } ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "maintenance", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);

-- Reindex preserves locale, physical constraints and full-value uniqueness
SELECT c.collection_id AS maintenance_collection_id, i.index_id AS maintenance_index_id
FROM documentdb_api_catalog.collections c
JOIN documentdb_api_catalog.collection_indexes i USING (collection_id)
WHERE c.database_name = 'unique_collation_db' AND c.collection_name = 'maintenance'
  AND (i.index_spec).index_name = 'unique_v' \gset
SELECT pg_relation_filenode(('documentdb_data.documents_rum_index_' || :maintenance_index_id)::regclass) AS old_filenode \gset
REINDEX INDEX documentdb_data.documents_rum_index_:maintenance_index_id;
-- Relation file numbers vary between runs; compare them rather than printing them.
SELECT pg_relation_filenode(('documentdb_data.documents_rum_index_' || :maintenance_index_id)::regclass) <> :old_filenode AS physical_index_rebuilt;
SELECT documentdb_api.insert_one('unique_collation_db', 'maintenance',
    '{ "_id": 4, "v": "RED" }');

SET documentdb.enableUniqueReindex TO on;
SET documentdb.enableNonBlockingUniqueIndexBuild TO on;
SELECT documentdb_api.coll_mod('unique_collation_db', 'maintenance',
    '{ "collMod": "maintenance", "index": { "name": "unique_v", "reindex": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT documentdb_api.insert_one('unique_collation_db', 'maintenance',
    '{ "_id": 5, "v": "RED" }');
SELECT documentdb_api.coll_mod('unique_collation_db', 'maintenance',
    '{ "collMod": "maintenance", "index": { "name": "unique_v", "reindex": true, "updateOptions": true } }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT documentdb_api.insert_one('unique_collation_db', 'maintenance',
    '{ "_id": 6, "v": "RED" }');
SELECT index_id, index_cmd_status
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = :maintenance_collection_id
ORDER BY index_id;
SELECT conname, convalidated
FROM pg_constraint
WHERE conrelid = ('documentdb_data.documents_' || :maintenance_collection_id)::regclass AND contype = 'x'
ORDER BY conname;
SELECT indexname
FROM pg_indexes WHERE schemaname = 'documentdb_data' AND tablename = 'documents_' || :maintenance_collection_id
  AND (indexname LIKE '%ccold%' OR indexname LIKE '%ccnew%')
ORDER BY indexname;
SELECT indexname, indexdef
FROM pg_indexes WHERE schemaname = 'documentdb_data' AND indexname = 'documents_rum_index_' || :maintenance_index_id;

-- Background builds over distinct and collation-equivalent data
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "background_ok", "documents": [ { "_id": 1, "v": "red" }, { "_id": 2, "v": "blue" } ], "ordered": true }');
SELECT documentdb_api.create_indexes_background('unique_collation_db',
    '{ "createIndexes": "background_ok", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "storageEngine": { "enableOrderedIndex": true }, "collation": { "locale": "en", "strength": 2 } } ] }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT documentdb_api.insert_one('unique_collation_db', 'background_ok',
    '{ "_id": 3, "v": "RED" }');
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "background_duplicate", "documents": [ { "_id": 1, "v": "red" }, { "_id": 2, "v": "RED" } ], "ordered": true }');
SELECT documentdb_api.create_indexes_background('unique_collation_db',
    '{ "createIndexes": "background_duplicate", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "storageEngine": { "enableOrderedIndex": true }, "collation": { "locale": "en", "strength": 2 } } ] }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (SELECT collection_id FROM documentdb_api_catalog.collections
                      WHERE database_name = 'unique_collation_db' AND collection_name = 'background_duplicate')
ORDER BY index_id;
SELECT * FROM documentdb_test_helpers.get_collection_indexes('unique_collation_db', 'background_duplicate')
ORDER BY index_id;
SELECT documentdb_api.delete('unique_collation_db',
    '{ "delete": "background_duplicate", "deletes": [ { "q": { "_id": 2 }, "limit": 1 } ] }');
SELECT documentdb_api.create_indexes_background('unique_collation_db',
    '{ "createIndexes": "background_duplicate", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "storageEngine": { "enableOrderedIndex": true }, "collation": { "locale": "en", "strength": 2 } } ] }');
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);
SELECT documentdb_api.insert_one('unique_collation_db', 'background_duplicate',
    '{ "_id": 3, "v": "RED" }');

-- Creation flags and execution flags must not silently change an existing constraint
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'unique_collation_db',
    '{ "createIndexes": "flag_writes", "indexes": [ { "key": { "v": 1 }, "name": "unique_v", "unique": true, "enableOrderedIndex": true, "collation": { "locale": "en", "strength": 2 } } ] }',
    true);
SELECT documentdb_api.insert_one('unique_collation_db', 'flag_writes',
    '{ "_id": 1, "v": "red" }');
BEGIN;
SET LOCAL documentdb.enable_collated_unique_indexes TO off;
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "flag_writes", "documents": [ { "_id": 2, "v": "RED" } ], "ordered": true }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'flag_writes')
ORDER BY object_id;
ROLLBACK;
BEGIN;
SET LOCAL documentdb.enable_composite_unique_optional_key TO off;
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "flag_writes", "documents": [ { "_id": 3, "v": "RED" } ], "ordered": true }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'flag_writes')
ORDER BY object_id;
ROLLBACK;
BEGIN;
SET LOCAL documentdb_core.enableCollation TO off;
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "flag_writes", "documents": [ { "_id": 4, "v": "RED" } ], "ordered": true }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'flag_writes')
ORDER BY object_id;
ROLLBACK;
BEGIN;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO off;
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "flag_writes", "documents": [ { "_id": 5, "v": "RED" } ], "ordered": true }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'flag_writes')
ORDER BY object_id;
ROLLBACK;
BEGIN;
SET LOCAL documentdb.enableCompositeUniqueHash TO off;
SELECT * FROM documentdb_api.insert(
    'unique_collation_db',
    '{ "insert": "flag_writes", "documents": [ { "_id": 7, "v": "RED" } ], "ordered": true }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'flag_writes')
ORDER BY object_id;
ROLLBACK;
SELECT documentdb_api.insert_one('unique_collation_db', 'flag_writes',
    '{ "_id": 6, "v": "blue" }');
SELECT document FROM documentdb_api.collection('unique_collation_db', 'flag_writes')
ORDER BY object_id;

-- Fixture isolation and cleanup
SELECT collection_name, shard_key
FROM documentdb_api_catalog.collections WHERE database_name = 'unique_collation_db'
ORDER BY collection_name;
SELECT documentdb_api.drop_database('unique_collation_db');
SELECT collection_name FROM documentdb_api_catalog.collections WHERE database_name = 'unique_collation_db'
ORDER BY collection_name;
RESET documentdb.enableNonBlockingUniqueIndexBuild;
RESET documentdb.enableUniqueReindex;
RESET documentdb.enable_collated_unique_indexes;
RESET documentdb.enable_composite_unique_optional_key;
RESET documentdb.enableCompositeUniqueHash;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;
RESET documentdb_core.bsonUseEJson;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET search_path;
