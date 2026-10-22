-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core;
SET documentdb.next_collection_id TO 27200000;
SET documentdb.next_collection_index_id TO 27200000;

-- A text index can be specified with field names or with the key format that
-- listIndexes returns. Both formats should build the same text index, including
-- when ordered indexes are enabled by default.
SET documentdb.defaultUseCompositeOpClass TO on;

SELECT documentdb_api_internal.create_indexes_non_concurrently('text_key_formats',
  '{"createIndexes":"field_names","indexes":[{"key":{"body":"text"},"name":"body_text"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('text_key_formats',
  '{"createIndexes":"listed_format","indexes":[{"key":{"_fts":"text","_ftsx":1},"weights":{"body":1},"name":"body_text"}]}', true);

SELECT documentdb_api.insert_one('text_key_formats', 'field_names', '{"_id":1,"body":"hello world"}');
SELECT documentdb_api.insert_one('text_key_formats', 'listed_format', '{"_id":1,"body":"hello world"}');

-- Both indexes should be built as text indexes.
SELECT c.collection_name,
       d.index_def LIKE '%text_path_ops%' AS is_text_index,
       d.index_def LIKE '%composite_path_ops%' AS is_composite_index
FROM (VALUES ('field_names'), ('listed_format')) AS c(collection_name)
CROSS JOIN LATERAL documentdb_test_helpers.documentdb_index_get_pg_def(
    'text_key_formats', c.collection_name, 'body_text') AS d(index_def)
ORDER BY c.collection_name;

-- Both collections should answer $text queries.
SELECT document FROM bson_aggregation_find('text_key_formats',
  '{"find":"field_names","filter":{"$text":{"$search":"hello"}}}');
SELECT document FROM bson_aggregation_find('text_key_formats',
  '{"find":"listed_format","filter":{"$text":{"$search":"hello"}}}');

-- The listIndexes format can also combine text with other keys, use wildcard
-- weights, and carry language options. Each should build a text index that
-- keeps the other keys and the text options.
SELECT documentdb_api_internal.create_indexes_non_concurrently('text_key_formats',
  '{"createIndexes":"text_then_key","indexes":[{"key":{"_fts":"text","_ftsx":1,"c":1},"weights":{"a":1,"b":1},"name":"text_idx"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('text_key_formats',
  '{"createIndexes":"key_then_text","indexes":[{"key":{"a":1,"_fts":"text","_ftsx":1},"weights":{"b":1},"name":"text_idx"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('text_key_formats',
  '{"createIndexes":"wildcard_weights","indexes":[{"key":{"_fts":"text","_ftsx":1},"weights":{"$**":1},"name":"text_idx"}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('text_key_formats',
  '{"createIndexes":"language_options","indexes":[{"key":{"_fts":"text","_ftsx":1},"weights":{"body":1},"default_language":"es","language_override":"idioma","name":"text_idx"}]}', true);

-- Older builds stored the ordered default on text indexes in this format, and
-- listIndexes reports that as storageEngine.enableOrderedIndex: true. Recreating
-- such an index from listIndexes output should still build a text index.
SELECT documentdb_api_internal.create_indexes_non_concurrently('text_key_formats',
  '{"createIndexes":"explicit_ordered","indexes":[{"key":{"_fts":"text","_ftsx":1},"weights":{"body":1},"storageEngine":{"enableOrderedIndex":true},"name":"text_idx"}]}', true);

SELECT c.collection_name,
       substring(d.index_def FROM ' USING (.*)$') AS index_def
FROM (VALUES ('text_then_key'), ('key_then_text'), ('wildcard_weights'), ('language_options'), ('explicit_ordered')) AS c(collection_name)
CROSS JOIN LATERAL documentdb_test_helpers.documentdb_index_get_pg_def(
    'text_key_formats', c.collection_name, 'text_idx') AS d(index_def)
ORDER BY c.collection_name;

-- A compound text index should still answer $text queries.
SELECT documentdb_api.insert_one('text_key_formats', 'text_then_key', '{"_id":1,"a":"hello world","c":1}');
SELECT document FROM bson_aggregation_find('text_key_formats',
  '{"find":"text_then_key","filter":{"$text":{"$search":"hello"}}}');

RESET documentdb.defaultUseCompositeOpClass;
