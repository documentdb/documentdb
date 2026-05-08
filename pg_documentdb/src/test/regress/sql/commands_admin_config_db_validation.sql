SET search_path TO documentdb_core, documentdb_api, documentdb_api_internal, public;
SET documentdb.next_collection_id TO 25708000;
SET documentdb.next_collection_index_id TO 25708000;

-- Ensure the feature flag is on
SET documentdb.enableNewNamespaceValidation TO on;

-- ===================================================================
-- 1. createCollection on config database - restricted collections
-- ===================================================================
-- restricted collections should fail
SELECT documentdb_api.create_collection('config', 'chunks');
SELECT documentdb_api.create_collection('config', '_shards');
SELECT documentdb_api.create_collection('config', 'shards');
SELECT documentdb_api.create_collection('config', 'version');
SELECT documentdb_api.create_collection('config', 'databases');
SELECT documentdb_api.create_collection('config', 'collections');
SELECT documentdb_api.create_collection('config', 'settings');

-- non-restricted config collections should succeed
SELECT documentdb_api.create_collection('config', 'my_config_coll');
SELECT documentdb_api.create_collection('config', 'user_custom_coll');

-- ===================================================================
-- 2. create_collection_view on config database
-- ===================================================================
-- restricted collections should fail
SELECT documentdb_api.create_collection_view('config', '{ "create": "chunks" }');
SELECT documentdb_api.create_collection_view('config', '{ "create": "_shards" }');
SELECT documentdb_api.create_collection_view('config', '{ "create": "shards" }');
-- non-restricted config collection view should succeed
SELECT documentdb_api.create_collection_view('config', '{ "create": "my_config_view_coll" }');

-- ===================================================================
-- 3. dropCollection on config database
-- ===================================================================
-- restricted collections should fail
SELECT documentdb_api.drop_collection('config', 'chunks');
SELECT documentdb_api.drop_collection('config', '_shards');
SELECT documentdb_api.drop_collection('config', 'version');

-- dropping non-restricted config collections should succeed
SELECT documentdb_api.drop_collection('config', 'my_config_coll');
SELECT documentdb_api.drop_collection('config', 'user_custom_coll');
SELECT documentdb_api.drop_collection('config', 'my_config_view_coll');

-- dropping non-existent non-restricted collection returns false (no error)
SELECT documentdb_api.drop_collection('config', 'nonexistent_config');

-- ===================================================================
-- 4. $out on config database - should be blocked for all collections
-- ===================================================================
-- create a source collection with data for $out/$merge tests
SELECT documentdb_api.create_collection('testdb', 'source_coll');
SELECT documentdb_api.insert_one('testdb', 'source_coll', '{"_id": 1, "a": 1}');

-- $out to config.chunks should fail (config db blocked entirely)
SELECT * FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "source_coll", "pipeline": [{"$out": {"db": "config", "coll": "chunks"}}], "cursor": {"batchSize": 1} }', 4294967294);

-- $out to config.my_allowed_coll should also fail (config db blocked entirely)
SELECT * FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "source_coll", "pipeline": [{"$out": {"db": "config", "coll": "my_allowed_coll"}}], "cursor": {"batchSize": 1} }', 4294967294);

-- $out to normal db should succeed
SELECT * FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "source_coll", "pipeline": [{"$out": "out_target_coll"}], "cursor": {"batchSize": 1} }', 4294967294);

-- ===================================================================
-- 5. $merge on config database - should be blocked for all collections
-- ===================================================================
-- $merge to config.chunks should fail
SELECT * FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "source_coll", "pipeline": [{"$merge": {"into": {"db": "config", "coll": "chunks"}}}], "cursor": {"batchSize": 1} }', 4294967294);

-- $merge to config.my_allowed_coll should also fail (config db blocked entirely)
SELECT * FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "source_coll", "pipeline": [{"$merge": {"into": {"db": "config", "coll": "my_allowed_coll"}}}], "cursor": {"batchSize": 1} }', 4294967294);

-- $merge to normal db should succeed
SELECT * FROM aggregate_cursor_first_page('testdb', '{ "aggregate": "source_coll", "pipeline": [{"$merge": {"into": "merge_target_coll"}}], "cursor": {"batchSize": 1} }', 4294967294);

-- ===================================================================
-- 6. renameCollection to restricted config collections should fail
-- ===================================================================
-- create a source collection to rename
SELECT documentdb_api.create_collection('config', 'rename_source');

-- rename to restricted collection should fail
SELECT documentdb_api.rename_collection('config', 'rename_source', 'chunks');
SELECT documentdb_api.rename_collection('config', 'rename_source', '_shards');
SELECT documentdb_api.rename_collection('config', 'rename_source', 'version');
SELECT documentdb_api.rename_collection('config', 'rename_source', 'databases');

-- rename to non-restricted collection should succeed
SELECT documentdb_api.rename_collection('config', 'rename_source', 'rename_target');

-- cleanup
SELECT documentdb_api.drop_collection('config', 'rename_target');
SELECT documentdb_api.drop_collection('testdb', 'source_coll');
SELECT documentdb_api.drop_collection('testdb', 'out_target_coll');
SELECT documentdb_api.drop_collection('testdb', 'merge_target_coll');

-- ===================================================================
-- 7. shard_collection on restricted config collections should fail
-- ===================================================================
SELECT documentdb_api.shard_collection('config', 'chunks', '{"_id": "hashed"}', false);
SELECT documentdb_api.shard_collection('config', '_shards', '{"_id": "hashed"}', false);
SELECT documentdb_api.shard_collection('config', 'version', '{"_id": "hashed"}', false);
SELECT documentdb_api.shard_collection('config', 'databases', '{"_id": "hashed"}', false);

-- shard_collection on non-restricted config collection should succeed
SELECT documentdb_api.shard_collection('config', 'shard_test_coll', '{"_id": "hashed"}', false);
SELECT documentdb_api.drop_collection('config', 'shard_test_coll');

-- ===================================================================
-- 8. Reserved system namespace creation tests (admin and config system.*)
-- ===================================================================
-- admin.system.roles - not in whitelist, should fail
SELECT documentdb_api.create_collection('admin', 'system.roles');
-- admin.system.users - in whitelist but non-writable, creation should fail
SELECT documentdb_api.create_collection('admin', 'system.users');
-- admin.system.version - not in whitelist, should fail
SELECT documentdb_api.create_collection('admin', 'system.version');
-- config.system.indexBuilds - not in whitelist, should fail
SELECT documentdb_api.create_collection('config', 'system.indexBuilds');
-- config.system.preimages - not in whitelist, should fail
SELECT documentdb_api.create_collection('config', 'system.preimages');

-- ===================================================================
-- 9. drop_collection on reserved system namespaces should fail
-- ===================================================================
SELECT documentdb_api.drop_collection('admin', 'system.roles');
SELECT documentdb_api.drop_collection('admin', 'system.users');
SELECT documentdb_api.drop_collection('admin', 'system.version');
SELECT documentdb_api.drop_collection('config', 'system.indexBuilds');
SELECT documentdb_api.drop_collection('config', 'system.preimages');

-- ===================================================================
-- 10. create_indexes_background on reserved namespaces should fail
-- ===================================================================
-- reserved config collection should fail
SELECT * FROM documentdb_api.create_indexes_background('config', '{"createIndexes": "chunks", "indexes": [{"key": {"a": 1}, "name": "my_idx_1"}]}');
SELECT * FROM documentdb_api.create_indexes_background('config', '{"createIndexes": "version", "indexes": [{"key": {"a": 1}, "name": "my_idx_2"}]}');

-- reserved system namespace should fail
SELECT * FROM documentdb_api.create_indexes_background('admin', '{"createIndexes": "system.roles", "indexes": [{"key": {"a": 1}, "name": "my_idx_3"}]}');
SELECT * FROM documentdb_api.create_indexes_background('config', '{"createIndexes": "system.indexBuilds", "indexes": [{"key": {"a": 1}, "name": "my_idx_4"}]}');

-- non-reserved collection should succeed (collection will be created)
SELECT * FROM documentdb_api.create_indexes_background('config', '{"createIndexes": "user_index_coll", "indexes": [{"key": {"a": 1}, "name": "my_idx_5"}]}');
SELECT documentdb_api.drop_collection('config', 'user_index_coll');

-- ===================================================================
-- 11. delete on reserved config collections should fail
-- ===================================================================
SELECT documentdb_api.delete('config', '{"delete": "chunks", "deletes": [{"q": {}, "limit": 0}]}');
SELECT documentdb_api.delete('config', '{"delete": "_shards", "deletes": [{"q": {}, "limit": 0}]}');
SELECT documentdb_api.delete('config', '{"delete": "version", "deletes": [{"q": {}, "limit": 0}]}');

-- ===================================================================
-- 12. delete on reserved system namespaces should fail
-- ===================================================================
SELECT documentdb_api.delete('admin', '{"delete": "system.roles", "deletes": [{"q": {}, "limit": 0}]}');
SELECT documentdb_api.delete('admin', '{"delete": "system.users", "deletes": [{"q": {}, "limit": 0}]}');
SELECT documentdb_api.delete('admin', '{"delete": "system.version", "deletes": [{"q": {}, "limit": 0}]}');
SELECT documentdb_api.delete('config', '{"delete": "system.indexBuilds", "deletes": [{"q": {}, "limit": 0}]}');
SELECT documentdb_api.delete('config', '{"delete": "system.preimages", "deletes": [{"q": {}, "limit": 0}]}');