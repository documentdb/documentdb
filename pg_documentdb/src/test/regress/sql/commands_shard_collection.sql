-- Copyright (c) Microsoft Corporation. All rights reserved.
-- Licensed under the MIT License. See LICENSE in the project root for license information.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_api_catalog,documentdb_core;
SET documentdb.next_collection_id TO 5000;
SET documentdb.next_collection_index_id TO 5000;

-- before reshard
SELECT documentdb_api.insert_one('db','reshard','{"_id":"1", "value": { "$numberInt" : "11" }}');

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11}' $cmd$);
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11}';
ROLLBACK;

-- invalid inputs
SELECT documentdb_api.shard_collection('db','reshard', '{"value":1}');
SELECT documentdb_api.shard_collection('db','reshard', '{"value":"hash"}');

-- create two indexes before re-sharding
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "reshard",
     "indexes": [
       {"key": {"a.b.c.$**": 1}, "name": "idx_1"},
       {"key": {"z": 1}, "name": "idx_2"}
     ]
   }',
   true
);

SELECT collection_id AS reshard_collection_id FROM documentdb_api_catalog.collections
WHERE collection_name = 'reshard' AND database_name = 'db' \gset

\d documentdb_data.documents_:reshard_collection_id

-- insert an invalid index metadata entry before re-sharding
INSERT INTO documentdb_api_catalog.collection_indexes (collection_id, index_id, index_spec, index_is_valid)
VALUES (:reshard_collection_id, 2020, ('invalid_index', '{"c": 1}', null, null, null, null, 2, null, null, null), false);

-- shard based on value key
SELECT documentdb_api.shard_collection('db','reshard', '{"value":"hashed"}', false);

\d documentdb_data.documents_:reshard_collection_id

SELECT 'documentdb_data.documents_' || collection_id AS db_shard_data_table_name FROM documentdb_api_catalog.collections WHERE database_name = 'db' AND collection_name = 'reshard' \gset

-- make plans (more) deterministic
VACUUM (ANALYZE) :db_shard_data_table_name;

SELECT * FROM documentdb_test_helpers.get_collection_indexes('db', 'reshard') ORDER BY index_id;

SELECT documentdb_api.insert_one('db','reshard','{"value":{"$numberLong" : "134311"}, "_id":"2" }');
SELECT documentdb_api.insert_one('db','reshard','{"_id":"3", "value": 11}');

-- documents without a shard key are allowed
SELECT documentdb_api.insert_one('db','reshard','{"_id":"4", "novalue": 0}');
SELECT count(*) FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":{"$exists":false}}';

-- documents with an object shard key are allowed
SELECT documentdb_api.insert_one('db','reshard','{"_id":"5", "value": {"hello":"world"}}');
SELECT count(*) FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":{"hello":"world"}}';

-- documents with an array shard key are not allowed
SELECT documentdb_api.insert_one('db','reshard','{"_id":"6", "value": ["hello","world"]}');

-- documents with regex shard key are not allowed
SELECT documentdb_api.insert_one('db','reshard','{"_id":"6", "value":  {"$regularExpression":{"pattern":"foo","options":""}}}');

-- documents with double shard key are allowed
SELECT documentdb_api.insert_one('db','reshard','{"_id":"6", "value": 15.0}');

-- after reshard
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11}' ORDER BY document->'id' $cmd$);
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11}' ORDER BY document->'id';
ROLLBACK;

-- small longs have the same hash as ints
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":{"$numberLong" : "134311"}}' ORDER BY document->'id' $cmd$);
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":{"$numberLong" : "134311"}}' ORDER BY document->'id';
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":{"$numberInt" : "134311"}}' ORDER BY document->'id' $cmd$);
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":{"$numberInt" : "134311"}}' ORDER BY document->'id';
ROLLBACK;

-- should find doubles too when looking for int
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":15}' ORDER BY document->'id' $cmd$);
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":15}' ORDER BY document->'id';
ROLLBACK;

-- reshard based on value and _id key
SELECT documentdb_api.shard_collection('db','reshard', '{"value":"hashed","_id":"hashed"}', true);

-- after reshard
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SET LOCAL documentdb.ForceUseIndexIfAvailable to OFF;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"$and":[{"value":{"$eq":11}},{"_id":{"$eq":"1"}}]}' $cmd$);
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"$and":[{"value":{"$eq":11}},{"_id":{"$eq":"1"}}]}';
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SET LOCAL documentdb.ForceUseIndexIfAvailable to OFF;
EXPLAIN (COSTS OFF)
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11,"_id":"1"}';
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11,"_id":"1"}';
ROLLBACK;

SELECT documentdb_api_internal.get_shard_key_value('{"value":1,"_id":1}',1,'{"_id":"1","value":11}');
SELECT documentdb_api_internal.get_shard_key_value('{"value":1,"_id":1}',1,'{"value":11,"_id":"1"}');

-- different order of fields
SELECT documentdb_api_internal.get_shard_key_value('{"_id":1,"value":1}', 1,'{"_id":"1","value":11}');
SELECT documentdb_api_internal.get_shard_key_value('{"_id":1,"value":1}', 1,'{"value":11,"_id":"1"}');

-- should produce different hash values because type is taken into account
SELECT documentdb_api_internal.get_shard_key_value('{"a":1,"b":1}', 1,'{"_id":"1","a":1,"b":true}');
SELECT documentdb_api_internal.get_shard_key_value('{"a":1,"b":1}', 1,'{"_id":"1","a":true,"b":1}');

-- only 1 part of shard key specified, goes to multiple shards
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11}' ORDER BY document->'id' $cmd$);
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":11}' ORDER BY document->'id';
ROLLBACK;

-- no shard key filter specified
SELECT count(*) FROM documentdb_api.collection('db','reshard') WHERE true;
SELECT count(*) FROM documentdb_api.collection('db','reshard') WHERE false;
SELECT count(*) FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"value":{"$exists":1}}';

-- reshard based on nested path
SELECT documentdb_api.shard_collection('db','reshard', '{"a.b":"hashed"}', true);

-- we should not allow arrays in the path even if the value is not an array
SELECT documentdb_api.insert_one('db','reshard','{"_id":"10", "a": [{"b":22}]}');

-- nested objects should be fine
SELECT documentdb_api.insert_one('db','reshard','{"_id":"10", "a": {"b":22}}');

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SET LOCAL seq_page_cost TO 9999999;
EXPLAIN (COSTS OFF)
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"a.b":22}' ORDER BY document->'id';
SELECT document FROM documentdb_api.collection('db','reshard') WHERE document @@ '{"a.b":22}' ORDER BY document->'id';
ROLLBACK;

-- try to shard a non-existent collection
SELECT documentdb_api.shard_collection('db','not_exists', '{"value":"hashed"}', false);

-- shard a collection that has no user-created indexes
SELECT documentdb_api.insert_one('db','shard_collection_no_indexes','{"_id":"1", "value": { "$numberInt" : "11" }}');

BEGIN;
  -- Shard it twice within a xact block to test whether we drop the temp table
  -- (v_saved_index_entries) before completing documentdb_api.shard_collection().
  SELECT documentdb_api.shard_collection('db','shard_collection_no_indexes', '{"value":"hashed"}', false);
  SELECT documentdb_api.shard_collection('db','shard_collection_no_indexes', '{"value":"hashed"}', false);
COMMIT;

-- shard creates a new collection.
BEGIN;
  SELECT documentdb_api.shard_collection('db', 'newCollectionToCreate', '{ "value": "hashed" }', false);

  SELECT database_name, collection_name FROM documentdb_api_catalog.collections WHERE collection_name = 'newCollectionToCreate' ORDER BY database_name, collection_name;
ROLLBACK;

-- shard collection with indexes with bson text as hex binary still works.
BEGIN;
set local documentdb_core.bsonUseEJson to false;
SELECT documentdb_api.insert_one('db','reshardwithindexes2','{"_id":"1", "value": 11, "otherValue": 15 }');

-- create some indexes
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{
      "createIndexes": "reshardwithindexes2",
      "indexes": [
        {"key": { "value": 1 }, "name": "idx1"},
        {"key": { "otherValue": 1 }, "name": "idx2"}
      ]
  }',
  true
);

-- now shard the collection
SELECT documentdb_api.shard_collection('db', 'reshardwithindexes2', '{ "value": "hashed" }', false);

SELECT collection_id AS reshard_collection_id FROM documentdb_api_catalog.collections
WHERE collection_name = 'reshardwithindexes2' AND database_name = 'db' \gset

set local documentdb_core.bsonUseEJson to true;
SELECT index_spec from documentdb_api_catalog.collection_indexes WHERE collection_id = :reshard_collection_id order by index_id ASC;
SELECT database_name, collection_name, shard_key from documentdb_api_catalog.collections WHERE collection_id = :reshard_collection_id;
ROLLBACK;

-- create a new sharded collection
SELECT documentdb_api.create_collection('db', 'reshardoptions');

-- now shard it.
SELECT documentdb_api.shard_collection('db', 'reshardoptions', '{ "a.b": "hashed" }', false);

-- shard with the same key
SELECT documentdb_api.shard_collection('db', 'reshardoptions', '{ "a.b": "hashed" }');

-- shard with a new key with reshard:false (should fail)
SELECT documentdb_api.shard_collection('db', 'reshardoptions', '{ "c.d": "hashed" }', false);

-- key should now be { "a.b": "hashed" }
SELECT database_name, collection_name, shard_key FROM documentdb_api_catalog.collections WHERE database_name = 'db' AND collection_name = 'reshardoptions';

-- shard with a new key with reshard:true (should work)
SELECT documentdb_api.shard_collection('db', 'reshardoptions', '{ "c.d": "hashed" }', true);

-- key should now be { "c.d": "hashed" }
SELECT database_name, collection_name, shard_key FROM documentdb_api_catalog.collections WHERE database_name = 'db' AND collection_name = 'reshardoptions';

-- reshard on non existing collections or non-sharded collections should fail
SELECT documentdb_api.shard_collection('db', 'nonExistingCollection', '{ "a.b": "hashed" }', true);
SELECT documentdb_api.create_collection('db', 'nonShardedCollection');
SELECT documentdb_api.shard_collection('db', 'nonShardedCollection', '{ "a.b": "hashed" }', true);

-- shard_collection should not crash when implicit CreateCollection fails (issue #462)
-- Force a collection ID collision by resetting next_collection_id
SET documentdb.next_collection_id TO 5000;
SELECT documentdb_api.shard_collection('db', 'shard_462_crash_test', '{ "_id": "hashed" }', false);

-- Rebuilding a collection must preserve its options and pre-image storage.
SET documentdb.next_collection_id TO 99010300;
SET documentdb.next_collection_index_id TO 99010300;
SET documentdb.enablePreImages TO on;

DO $$
DECLARE
    target_collection text;
    operation text;
    original_options documentdb_core.bson;
    current_options documentdb_core.bson;
    expected_identity "char";
    current_identity "char";
    document_count bigint;
BEGIN
    FOREACH target_collection IN ARRAY ARRAY['preimages', 'update_only', 'disabled']
    LOOP
        PERFORM documentdb_api.create_collection_view('sharding_options',
            format('{"create": "%s", "enableUpdateDescription": true,
                     "changeStreamPreAndPostImages": {"enabled": %s}}',
                   target_collection, (target_collection != 'update_only')::text)::documentdb_core.bson);
        IF target_collection = 'disabled' THEN
            PERFORM documentdb_api.coll_mod('sharding_options', target_collection,
                format('{"collMod": "%s", "changeStreamPreAndPostImages": {"enabled": false},
                         "enableUpdateDescription": false}', target_collection)::documentdb_core.bson);
        END IF;
        PERFORM documentdb_api.insert_one('sharding_options', target_collection,
            '{"_id": 1, "a": 1, "b": 2}'::documentdb_core.bson);
        SELECT c.options INTO STRICT original_options
        FROM documentdb_api_catalog.collections c
        WHERE c.database_name = 'sharding_options' AND c.collection_name = target_collection;
        expected_identity := CASE WHEN target_collection = 'preimages' THEN 'f' ELSE 'd' END;

        FOREACH operation IN ARRAY ARRAY['shard', 'reshard', 'redistribute', 'unshard']
        LOOP
            IF operation = 'shard' THEN
                PERFORM documentdb_api.shard_collection(
                    format('{"shardCollection": "sharding_options.%s", "key": {"a": "hashed"}}',
                           target_collection)::documentdb_core.bson);
            ELSIF operation = 'unshard' THEN
                PERFORM documentdb_api.unshard_collection(
                    format('{"unshardCollection": "sharding_options.%s"}',
                           target_collection)::documentdb_core.bson);
            ELSE
                PERFORM documentdb_api.reshard_collection(
                    format('{"reshardCollection": "sharding_options.%s", "key": {"b": "hashed"},
                             "forceRedistribution": %s}', target_collection,
                           (operation = 'redistribute')::text)::documentdb_core.bson);
            END IF;

            SELECT c.options, p.relreplident INTO STRICT current_options, current_identity
            FROM documentdb_api_catalog.collections c
            JOIN pg_class p ON p.oid =
                format('documentdb_data.documents_%s', c.collection_id)::regclass
            WHERE c.database_name = 'sharding_options' AND c.collection_name = target_collection;
            SELECT count(*) INTO document_count
            FROM documentdb_api.collection('sharding_options', target_collection)
            WHERE document = '{"_id": 1, "a": 1, "b": 2}'::documentdb_core.bson;
            RAISE NOTICE '% %: options preserved %, replica identity preserved %, document preserved %',
                target_collection, operation, current_options IS NOT DISTINCT FROM original_options,
                current_identity = expected_identity, document_count = 1;
        END LOOP;
        PERFORM documentdb_api.drop_collection('sharding_options', target_collection);
    END LOOP;
END;
$$;

RESET documentdb.enablePreImages;
