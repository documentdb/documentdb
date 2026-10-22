-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog;
SET documentdb.next_collection_id TO 28010000;
SET documentdb.next_collection_index_id TO 28010000;
SET documentdb_core.enableCollation TO on;
SHOW documentdb.enable_collation_with_create_collection;
SET documentdb.enable_collation_with_create_collection TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.enable_collated_unique_indexes TO on;
SET documentdb.enable_composite_unique_optional_key TO on;
SET documentdb.defaultUseCompositeOpClass TO off;

-- One logical _id_ retains the binary primary key and adds a collated unique backing.
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"ids","collation":{"locale":"en","strength":2}}');
SELECT collection_id AS cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation' AND collection_name = 'ids' \gset
SELECT options FROM documentdb_api_catalog.collections
    WHERE collection_id = :cid;
SELECT cursorpage FROM documentdb_api.list_indexes_cursor_first_page(
    'collated_creation', '{"listIndexes":"ids"}');
SELECT index_spec FROM documentdb_api_catalog.collection_indexes
    WHERE collection_id = :cid;
SELECT count(*) AS logical_indexes FROM documentdb_api_catalog.collection_indexes
    WHERE collection_id = :cid;
SELECT contype, count(*) FROM pg_constraint
    WHERE conrelid = ('documentdb_data.documents_' || :cid)::regclass
    AND contype IN ('p','x') GROUP BY contype ORDER BY contype;

-- Collation-equal identifiers conflict, including nested strings and numeric equivalents.
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":"ALPHA"}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":"Bravo"}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":"echo"}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":"Zulu"}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":1}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":1.0}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":{"nested":"Value"}}');
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":{"nested":"VALUE"}}');

-- Confirm hinted matching and ordering, including explicit collation overrides.
SET enable_seqscan TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"ALPHA"},"hint":"_id_"}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"ALPHA"},"hint":"_id_"}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"missing"},"hint":"_id_"}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"ALPHA"},"collation":{"locale":"simple"}}');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":1},"hint":"_id_"}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":1},"hint":"_id_"}');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":-1},"hint":"_id_"}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":-1},"hint":"_id_"}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"ALPHA"},"hint":"_id_","collation":{"locale":"simple"}}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":1},"hint":"_id_","collation":{"locale":"simple"}}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":1},"collation":{"locale":"en","strength":3}}');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"ALPHA"},"hint":"_id_","collation":{"locale":"en","strength":3}}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"ALPHA"},"hint":"_id_","collation":{"locale":"en","strength":3}}');
RESET enable_seqscan;
-- Sequential execution must return the same collated matches and ordering.
SET enable_indexscan TO off;
SET enable_bitmapscan TO off;
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":"ALPHA"}}');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":1}}');
SELECT document FROM bson_aggregation_find(
    'collated_creation', '{"find":"ids","filter":{"_id":{"$type":"string"}},"sort":{"_id":1}}');
RESET enable_indexscan;
RESET enable_bitmapscan;

-- Dropping _id_ is rejected; validation and statistics report one logical _id_ index.
CALL documentdb_api.drop_indexes('collated_creation',
    '{"dropIndexes":"ids","index":"_id_"}');
SELECT documentdb_api.validate('collated_creation', '{"validate":"ids"}');
SELECT document FROM bson_aggregation_pipeline(
    'collated_creation', '{"aggregate":"ids","pipeline":[{"$indexStats":{}},{"$count":"logical_indexes"}]}');
SELECT document FROM bson_aggregation_pipeline(
    'collated_creation', '{"aggregate":"ids","pipeline":[{"$collStats":{"storageStats":{}}},{"$project":{"logical_indexes":"$storageStats.nindexes","_id":0}}]}');

-- Updates find collated identifiers, but forced upserts still enforce uniqueness.
BEGIN;
SELECT documentdb_api.update('collated_creation',
    '{"update":"ids","updates":[{"q":{"_id":"ALPHA"},"u":{"$set":{"value":1}},"collation":{"locale":"en","strength":2}}]}');
SELECT documentdb_api.find_and_modify('collated_creation',
    '{"findAndModify":"ids","query":{"_id":"alpha"},"update":{"$set":{"value":2}},"collation":{"locale":"en","strength":2},"new":true}');
SELECT documentdb_api.update('collated_creation',
    '{"update":"ids","updates":[{"q":{"_id":"ALPHA","missing":true},"u":{"$set":{"value":3}},"upsert":true}]}');
SELECT documentdb_api.find_and_modify('collated_creation',
    '{"findAndModify":"ids","query":{"_id":"alpha","missing":true},"update":{"$set":{"value":4}},"upsert":true}');
ROLLBACK;

-- Creation-only flags do not weaken uniqueness on an existing collated backing.
SET documentdb.enable_collation_with_create_collection TO off;
SET documentdb.enable_collated_unique_indexes TO off;
SET documentdb.enable_composite_unique_optional_key TO off;
SELECT documentdb_api.insert_one('collated_creation', 'ids', '{"_id":"alpha"}');
SELECT document FROM bson_aggregation_find('collated_creation',
    '{"find":"ids","filter":{"_id":"ALPHA"},"hint":"_id_"}');
SET documentdb.enable_collated_unique_indexes TO on;
SET documentdb.enable_composite_unique_optional_key TO on;
SET documentdb.enable_collation_with_create_collection TO on;

-- Validation must mark _id_ invalid if either physical backing, or both, are missing.
SELECT index_id AS iid FROM documentdb_api_catalog.collection_indexes
    WHERE collection_id = :cid AND (index_spec).index_name = '_id_' \gset
BEGIN;
SELECT format('ALTER TABLE documentdb_data.documents_%s DROP CONSTRAINT documents_rum_index_%s',
    :cid, :iid) \gexec
SELECT documentdb_api.validate('collated_creation', '{"validate":"ids"}');
ROLLBACK;
BEGIN;
SELECT format('ALTER TABLE documentdb_data.documents_%s DROP CONSTRAINT collection_pk_%s',
    :cid, :cid) \gexec
SELECT documentdb_api.validate('collated_creation', '{"validate":"ids"}');
SELECT format('ALTER TABLE documentdb_data.documents_%s DROP CONSTRAINT documents_rum_index_%s',
    :cid, :iid) \gexec
SELECT documentdb_api.validate('collated_creation', '{"validate":"ids"}');
ROLLBACK;

-- Equivalent collection recreation is a no-op; a different default cannot replace it.
-- Collation checks must also run when schema validation is disabled.
SET documentdb.enableSchemaValidation TO off;
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"ids","collation":{"strength":2,"locale":"en"}}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"ids","collation":{"locale":"en","strength":3}}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"ids","collation":{"locale":"simple"}}');
SELECT documentdb_api.create_collection_view('collated_creation', '{"create":"ids"}');
SELECT documentdb_api.create_collection_with_options('collated_creation', 'ids',
    '{"collation":{"locale":"simple"}}');
SELECT options FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation' AND collection_name = 'ids';
RESET documentdb.enableSchemaValidation;

-- Case-sensitive, simple, and omitted defaults preserve their respective uniqueness rules.
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"sensitive","collation":{"locale":"en","strength":3}}');
SELECT documentdb_api.insert_one('collated_creation', 'sensitive', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation', 'sensitive', '{"_id":"ALPHA"}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"simple","collation":{"locale":"simple"}}');
SELECT documentdb_api.insert_one('collated_creation', 'simple', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation', 'simple', '{"_id":"ALPHA"}');
SELECT documentdb_api.validate('collated_creation', '{"validate":"simple"}');
SELECT documentdb_api.create_collection_view('collated_creation', '{"create":"binary"}');
SELECT documentdb_api.insert_one('collated_creation', 'binary', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation', 'binary', '{"_id":"ALPHA"}');
SELECT documentdb_api.validate('collated_creation', '{"validate":"binary"}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"binary","collation":{"locale":"en","strength":2}}');
SELECT count(*) AS converted_binary_defaults FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation' AND collection_name = 'binary'
    AND options::text LIKE '%"collation"%';

-- Views without collation remain equivalent when collation is enabled.
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"binary_view","viewOn":"binary"}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"binary_view","viewOn":"binary"}');

-- Malformed options fail before collection metadata or index backings are created.
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"bad","collation":null}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"bad","collation":{}}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"bad","collation":{"strength":2}}');
-- Views reject a collation before any metadata is created.
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"bad","viewOn":"ids","collation":{"locale":"en","strength":2}}');
SELECT documentdb_api.create_collection_with_options('collated_creation', 'bad',
    '{"unknown":true}');
SELECT documentdb_api.create_collection_with_options('collated_creation', 'bad',
    '{"collation":null}');
SELECT documentdb_api.create_collection_with_options('collated_creation', 'bad',
    '{"collation":{"locale":"en"},"collation":{"locale":"simple"}}');
SELECT documentdb_api.create_collection_with_options('collated_creation', 'strict_null',
    NULL) IS NULL AS strict_options_null;
SELECT count(*) AS null_options_collections FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation' AND collection_name = 'strict_null';

-- Unsupported access methods and disabled creation capabilities leave no partial collection.
SET documentdb.alternate_index_handler_name TO '';
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"plain_am","collation":{"locale":"en","strength":2}}');
SET documentdb.alternate_index_handler_name TO 'extended_rum';

SET documentdb.enable_composite_unique_optional_key TO off;
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"gated","collation":{"locale":"en","strength":2}}');
SET documentdb.enable_composite_unique_optional_key TO on;
SET documentdb.enable_collated_unique_indexes TO off;
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"gated","collation":{"locale":"en","strength":2}}');
SET documentdb.enable_collated_unique_indexes TO on;

-- Both creation entrypoints reject collation when its creation gate is disabled.
SET documentdb.enable_collation_with_create_collection TO off;
SET documentdb.skipFailOnCollation TO off;
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"creation_gated","collation":{"locale":"en","strength":2}}');
SELECT documentdb_api.create_collection_with_options('collated_creation', 'creation_gated_sql',
    '{"collation":{"locale":"en","strength":2}}');
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"creation_gated_simple","collation":{"locale":"simple"}}');
SELECT documentdb_api.create_collection('collated_creation', 'binary_gate_off');
SELECT documentdb_api.insert_one('collated_creation', 'binary_gate_off', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation', 'binary_gate_off', '{"_id":"ALPHA"}');

-- Compatibility mode still ignores unsupported command collation.
SET documentdb.skipFailOnCollation TO on;
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"ignored_default","collation":{"locale":"en","strength":2}}');
SELECT count(*) AS ignored_collations FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation' AND collection_name = 'ignored_default'
    AND options::text LIKE '%"collation"%';
SELECT documentdb_api.insert_one('collated_creation', 'ignored_default', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation', 'ignored_default', '{"_id":"ALPHA"}');
RESET documentdb.skipFailOnCollation;
SET documentdb.enable_collation_with_create_collection TO on;
SELECT count(*) AS failed_creations FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation'
    AND collection_name IN ('bad','gated','plain_am',
        'creation_gated','creation_gated_sql','creation_gated_simple');
SELECT count(*) AS collated_sentinels FROM documentdb_api_catalog.collections
    WHERE collection_name = 'system.dbSentinel' AND options::text LIKE '%"collation"%';

-- A later simple command collation must clear an earlier non-simple value.
SELECT documentdb_api.create_collection_view('collated_creation',
    '{"create":"simple_last","collation":{"locale":"en","strength":2},"collation":{"locale":"simple"}}');
SELECT count(*) AS stale_collations FROM documentdb_api_catalog.collections
    WHERE database_name = 'collated_creation' AND collection_name = 'simple_last'
    AND options::text LIKE '%"collation"%';
SELECT documentdb_api.insert_one('collated_creation', 'simple_last', '{"_id":"Alpha"}');
SELECT documentdb_api.insert_one('collated_creation', 'simple_last', '{"_id":"ALPHA"}');

SELECT documentdb_api.drop_collection('collated_creation', 'ids');
SELECT documentdb_api.drop_collection('collated_creation', 'sensitive');
SELECT documentdb_api.drop_collection('collated_creation', 'simple');
SELECT documentdb_api.drop_collection('collated_creation', 'binary');
SELECT documentdb_api.drop_collection('collated_creation', 'binary_view');
SELECT documentdb_api.drop_collection('collated_creation', 'binary_gate_off');
SELECT documentdb_api.drop_collection('collated_creation', 'ignored_default');
SELECT documentdb_api.drop_collection('collated_creation', 'simple_last');
RESET documentdb.enable_collation_with_create_collection;
