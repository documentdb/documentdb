SET search_path TO documentdb_api;

SET citus.next_shard_id TO 7830000;
SET documentdb.next_collection_id TO 783000;
SET documentdb.next_collection_index_id TO 783000;

CREATE SCHEMA cache_schema;

CREATE OR REPLACE FUNCTION cache_schema.validate_collection_cache(
    p_database_name text,
    p_collection_name text)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'pg_documentdb', $function$validate_collection_cache_entry$function$;

SELECT documentdb_api.create_collection('db', 'cache_test_collection');

-- SET options here, any new option included in the collection should be added here.
SET documentdb.enablePreImages to on;
SELECT documentdb_api.coll_mod('db', 'cache_test_collection','{"collMod": "cache_test_collection", "changeStreamPreAndPostImages": { "enabled": true }}'::documentdb_core.bson);

SELECT options FROM documentdb_api_catalog.collections WHERE collection_name = 'cache_test_collection';

SELECT cache_schema.validate_collection_cache('db', 'cache_test_collection');