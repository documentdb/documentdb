-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog;

SET documentdb.next_collection_id TO 782100;
SET documentdb.next_collection_index_id TO 782100;

CREATE SCHEMA collation_collection_cache_schema;

CREATE OR REPLACE FUNCTION collation_collection_cache_schema.validate_try_copy_collection_by_id(
    p_database_name text,
    p_collection_name text,
    p_expected_collation_string text)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'pg_documentdb', $function$validate_try_copy_collection_by_id$function$;

SELECT documentdb_api.create_collection('collation_db', 'collation_copy_test_en');

SELECT documentdb_api.shard_collection(
    'collation_db', 'collation_copy_test_en',
    '{ "_id": "hashed" }', false);

-- Seed immutable collection metadata before exercising the cache.
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_db' AND collection_name = 'collation_copy_test_en';

-- Collection metadata is hydrated independently of execution enablement.
SET documentdb_core.enableCollation TO off;

SELECT collation_collection_cache_schema.validate_try_copy_collection_by_id(
    'collation_db', 'collation_copy_test_en',
    'en-u-ks-level1');

SET documentdb_core.enableCollation TO on;

SELECT collation_collection_cache_schema.validate_try_copy_collection_by_id(
    'collation_db', 'collation_copy_test_en',
    'en-u-ks-level1');

RESET documentdb_core.enableCollation;

SELECT documentdb_api.create_collection('collation_db', 'collation_copy_test_fr');

SELECT documentdb_api.shard_collection(
    'collation_db', 'collation_copy_test_fr',
    '{ "_id": "hashed" }', false);

-- Seed immutable collection metadata before exercising the cache.
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "fr", "strength": 2 } }'::documentdb_core.bson
WHERE database_name = 'collation_db' AND collection_name = 'collation_copy_test_fr';

SELECT collation_collection_cache_schema.validate_try_copy_collection_by_id(
    'collation_db', 'collation_copy_test_fr',
    'fr-u-ks-level2');

RESET search_path;
