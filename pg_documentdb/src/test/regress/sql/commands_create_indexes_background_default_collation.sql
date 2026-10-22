-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET documentdb.next_collection_id TO 782500;
SET documentdb.next_collection_index_id TO 782500;

SET search_path TO documentdb_core, documentdb_api, documentdb_api_catalog;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

SELECT documentdb_test_helpers.change_index_jobs_status(false);
DELETE FROM documentdb_api_catalog.documentdb_index_queue;

SELECT documentdb_api.create_collection('collation_index_db', 'background_default');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "fr", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_index_db' AND collection_name = 'background_default';

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{
     "createIndexes": "background_default",
     "indexes": [
       {"key": {"a": 1}, "name": "a_1"}
     ]
   }'
);

SELECT index_cmd LIKE '%cl=''fr-u-ks-level1''%' AS has_default_collation,
       cmd_type,
       index_cmd_status
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
);

SELECT documentdb_api_internal.index_spec_as_bson(index_spec, true) AS index_spec,
       index_is_valid
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
)
AND (index_spec).index_name = 'a_1';

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT index_cmd LIKE '%cl=''fr-u-ks-level1''%' AS has_default_collation,
       cmd_type,
       index_cmd_status
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
);

SELECT documentdb_api_internal.index_spec_as_bson(index_spec, true) AS index_spec,
       index_is_valid
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
)
AND (index_spec).index_name = 'a_1';

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{
     "createIndexes": "background_default",
     "indexes": [
       {
         "key": {"b": 1, "c": -1},
         "name": "b_1_c_-1",
         "collation": {"locale": "en", "strength": 2}
       }
     ]
   }'
);

SELECT index_cmd LIKE '%cl=''en-u-ks-level2''%' AS has_index_collation,
       index_cmd NOT LIKE '%cl=''fr-u-ks-level1''%' AS excludes_default_collation,
       cmd_type,
       index_cmd_status
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
);

SELECT documentdb_api_internal.index_spec_as_bson(index_spec, true) AS index_spec,
       index_is_valid
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
)
AND (index_spec).index_name = 'b_1_c_-1';

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT documentdb_api_internal.index_spec_as_bson(index_spec, true) AS index_spec,
       index_is_valid
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
)
AND (index_spec).index_name = 'b_1_c_-1';

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{
     "createIndexes": "background_default",
     "indexes": [
       {
         "key": {"binary_key": 1},
         "name": "binary_key_1",
         "collation": {"locale": "simple"}
       }
     ]
   }'
);

SELECT index_cmd NOT LIKE '%cl=%' AS uses_binary_comparison,
       cmd_type,
       index_cmd_status
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
);

SELECT documentdb_api_internal.index_spec_as_bson(index_spec, true) AS index_spec,
       index_is_valid
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
)
AND (index_spec).index_name = 'binary_key_1';

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT documentdb_api_internal.index_spec_as_bson(index_spec, true) AS index_spec,
       index_is_valid
FROM documentdb_api_catalog.collection_indexes
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
)
AND (index_spec).index_name = 'binary_key_1';

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{"createIndexes": "background_default", "indexes": [{"key": {"geo": "2d"}, "name": "geo_2d"}]}'
);

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{"createIndexes": "background_default", "indexes": [{"key": {"geo": "2dsphere"}, "name": "geo_2dsphere"}]}'
);

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{"createIndexes": "background_default", "indexes": [{"key": {"description": "text"}, "name": "description_text"}]}'
);

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{"createIndexes": "background_default", "indexes": [{"key": {"hashed_key": "hashed"}, "name": "hashed_key_hashed"}]}'
);

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{
     "createIndexes": "background_default",
     "indexes": [
       {
         "key": {"embedding": "cosmosSearch"},
         "name": "embedding_vector",
         "cosmosSearchOptions": {
           "kind": "vector-ivf",
           "numLists": 1,
           "similarity": "COS",
           "dimensions": 3
         }
       }
     ]
   }'
);

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{"createIndexes": "background_default", "indexes": [{"key": {"unique_key": 1}, "name": "unique_key_1", "unique": true}]}'
);

SET documentdb.defaultUseCompositeOpClass TO off;

SELECT documentdb_api.create_indexes_background(
  'collation_index_db',
  '{"createIndexes": "background_default", "indexes": [{"key": {"scalar_key": 1}, "name": "scalar_key_1", "enableOrderedIndex": false}]}'
);

SET documentdb.defaultUseCompositeOpClass TO on;

SELECT count(*) AS queued_failure_count
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
  SELECT collection_id
  FROM documentdb_api_catalog.collections
  WHERE database_name = 'collation_index_db' AND collection_name = 'background_default'
);

SELECT documentdb_test_helpers.change_index_jobs_status(true);

RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;
RESET documentdb.defaultUseCompositeOpClass;
