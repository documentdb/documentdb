-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET citus.next_shard_id TO 299990000;
SET documentdb.next_collection_id TO 29999000;
SET documentdb.next_collection_index_id TO 29999000;

DELETE FROM documentdb_api_catalog.documentdb_index_queue;
SELECT documentdb_distributed_test_helpers.change_index_jobs_status(false);
SET documentdb.enableNonBlockingUniqueIndexBuild TO true;

SELECT documentdb_api.create_collection('bg_unique_hook_db', 'multinode_unique');
SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_unique',
	'{ "_id": 1, "a": 1 }');

SELECT (documentdb_api.create_indexes_background(
	'bg_unique_hook_db',
	'{ "createIndexes": "multinode_unique", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }')).ok;

SELECT COUNT(*) > 1 AS has_multiple_active_primaries
FROM pg_dist_node
WHERE nodecluster = 'default' AND noderole = 'primary' AND isactive;

SELECT index_cmd LIKE 'ALTER TABLE % ADD CONSTRAINT %' AS uses_blocking_unique_index
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_unique');

DELETE FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_unique');

SELECT documentdb_api.drop_collection('bg_unique_hook_db', 'multinode_unique');
