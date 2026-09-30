-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET citus.next_shard_id TO 299990000;
SET documentdb.next_collection_id TO 29999000;
SET documentdb.next_collection_index_id TO 29999000;

DELETE FROM documentdb_api_catalog.documentdb_index_queue;
SELECT documentdb_distributed_test_helpers.change_index_jobs_status(false);
SHOW documentdb_distributed.enable_non_blocking_unique_index_build_on_multi_node;
SET documentdb_distributed.enable_non_blocking_unique_index_build_on_multi_node TO true;
SET documentdb.enableNonBlockingUniqueIndexBuild TO true;
SET documentdb.enable_composite_unique_optional_key TO true;

CREATE FUNCTION documentdb_distributed_test_helpers.unique_constraint_state(
	p_database_name text,
	p_collection_name text,
	p_index_name text)
RETURNS TABLE(
	base_constraint_on_coordinator boolean,
	base_constraints_on_all_workers boolean,
	shard_constraints_on_all_placements boolean)
LANGUAGE SQL
AS $$
	WITH index_metadata AS MATERIALIZED (
		SELECT FORMAT('documentdb_data.documents_%s', collection.collection_id) AS table_name,
			   FORMAT('documents_rum_index_%s', index.index_id) AS constraint_name
		FROM documentdb_api_catalog.collections collection
		JOIN documentdb_api_catalog.collection_indexes index
			ON index.collection_id = collection.collection_id
		WHERE collection.database_name = p_database_name
			AND collection.collection_name = p_collection_name
			AND (index.index_spec).index_name = p_index_name
	),
	coordinator_base_constraint_state AS (
		SELECT EXISTS (
			SELECT 1
			FROM pg_catalog.pg_constraint constraint_entry
			WHERE constraint_entry.conrelid = table_name::regclass
				AND constraint_entry.conname = constraint_name
				AND constraint_entry.contype = 'x') AS state
		FROM index_metadata
	),
	worker_base_constraint_state AS (
		SELECT bool_and(command.success AND command.result = 't') AS state
		FROM index_metadata
		CROSS JOIN LATERAL run_command_on_workers(FORMAT($command$
			SELECT EXISTS (
				SELECT 1
				FROM pg_catalog.pg_constraint constraint_entry
				WHERE constraint_entry.conrelid = %L::regclass
					AND constraint_entry.conname = %L
					AND constraint_entry.contype = 'x')
		$command$, table_name, constraint_name)) command
	),
	shard_constraint_state AS (
		SELECT bool_and(command.success AND command.result = 't') AS state
		FROM index_metadata
		CROSS JOIN LATERAL run_command_on_placements(
			table_name,
			FORMAT($command$
				SELECT EXISTS (
					SELECT 1
					FROM pg_catalog.pg_constraint constraint_entry
					WHERE constraint_entry.conrelid = '%%s'::regclass
						AND constraint_entry.conname ~ %L
						AND constraint_entry.contype = 'x')
			$command$, '^' || constraint_name || '(_[0-9]+)?$')) command
	)
	SELECT coordinator_base_constraint_state.state,
		   worker_base_constraint_state.state,
		   shard_constraint_state.state
	FROM coordinator_base_constraint_state,
		 worker_base_constraint_state,
		 shard_constraint_state;
$$;

------------------------------------------------------------
-- Background unique index with the collection on coordinator
------------------------------------------------------------
SELECT documentdb_api.create_collection(
	'bg_unique_hook_db', 'multinode_coordinator_unique');
CALL documentdb_distributed_test_helpers.place_collection_on_node(
	'bg_unique_hook_db', 'multinode_coordinator_unique', 0);

SELECT bool_and(node.groupid = 0) AS collection_on_coordinator
FROM pg_dist_shard shard
JOIN pg_dist_shard_placement placement ON placement.shardid = shard.shardid
JOIN pg_dist_node node
	ON node.nodename = placement.nodename AND node.nodeport = placement.nodeport
WHERE shard.logicalrelid = (
	SELECT FORMAT('documentdb_data.documents_%s', collection_id)::regclass
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_coordinator_unique');

SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_coordinator_unique',
	'{ "_id": 1, "a": 1 }');

SELECT (documentdb_api.create_indexes_background(
	'bg_unique_hook_db',
	'{ "createIndexes": "multinode_coordinator_unique", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }')).ok;

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT count(*) AS pending_creates
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_coordinator_unique');

SELECT *
FROM documentdb_distributed_test_helpers.unique_constraint_state(
	'bg_unique_hook_db', 'multinode_coordinator_unique', 'a_1_unique');

SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_coordinator_unique',
	'{ "_id": 2, "a": 1 }');

SELECT documentdb_api.drop_collection(
	'bg_unique_hook_db', 'multinode_coordinator_unique');

------------------------------------------------------------
-- Reindex submitted from an MX worker for a coordinator collection
------------------------------------------------------------
SELECT documentdb_api.create_collection(
	'bg_unique_hook_db', 'multinode_mx_reindex');
CALL documentdb_distributed_test_helpers.place_collection_on_node(
	'bg_unique_hook_db', 'multinode_mx_reindex', 0);

SELECT bool_and(hasmetadata AND metadatasynced) AS workers_have_synced_metadata
FROM pg_dist_node
WHERE groupid > 0 AND noderole = 'primary' AND isactive;

SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_mx_reindex',
	'{ "_id": 1, "a": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
	'bg_unique_hook_db',
	'{ "createIndexes": "multinode_mx_reindex", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }',
	true);

SELECT bool_and(success) AS mx_worker_reindex_submitted
FROM run_command_on_workers($worker$
	WITH settings AS MATERIALIZED (
		SELECT set_config('documentdb.enableUniqueReindex', 'on', true),
			   set_config(
				   'documentdb_distributed.enable_non_blocking_unique_index_build_on_multi_node',
				   'on',
				   true)
	)
	SELECT documentdb_api.coll_mod(
		'bg_unique_hook_db',
		'multinode_mx_reindex',
		'{ "collMod": "multinode_mx_reindex", "index": { "name": "a_1_unique", "reindex": true, "updateOptions": true } }')
	FROM settings
$worker$);

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT count(*) AS pending_mx_reindexes
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_mx_reindex');

SELECT *
FROM documentdb_distributed_test_helpers.unique_constraint_state(
	'bg_unique_hook_db', 'multinode_mx_reindex', 'a_1_unique');

SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_mx_reindex',
	'{ "_id": 2, "a": 1 }');

SELECT documentdb_api.drop_collection(
	'bg_unique_hook_db', 'multinode_mx_reindex');

------------------------------------------------------------
-- Background unique index on an unsharded collection
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_hook_db', 'multinode_unique');
CALL documentdb_distributed_test_helpers.place_collection_on_node(
	'bg_unique_hook_db', 'multinode_unique', 1);
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

SELECT index_cmd LIKE 'CREATE INDEX CONCURRENTLY %' AS uses_concurrent_index,
	   index_cmd NOT LIKE '%WITH OPERATOR%' AS omits_exclusion_operators,
	   index_cmd LIKE '%optsk=%' AS uses_optional_key
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_unique');

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT count(*) AS pending_creates
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_unique');

SELECT *
FROM documentdb_distributed_test_helpers.unique_constraint_state(
	'bg_unique_hook_db', 'multinode_unique', 'a_1_unique');

SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_unique',
	'{ "_id": 2, "a": 1 }');

SELECT documentdb_api.drop_collection('bg_unique_hook_db', 'multinode_unique');

------------------------------------------------------------
-- Existing duplicates fail during the unsharded heap walk
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_hook_db', 'multinode_unique_dup');
SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_unique_dup',
	'{ "_id": 1, "a": 1 }');
SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_unique_dup',
	'{ "_id": 2, "a": 1 }');

SELECT (documentdb_api.create_indexes_background(
	'bg_unique_hook_db',
	'{ "createIndexes": "multinode_unique_dup", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }')).ok;

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_unique_dup');

SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch')
FROM documentdb_api.list_indexes_cursor_first_page(
	'bg_unique_hook_db',
	'{ "listIndexes": "multinode_unique_dup" }');

DELETE FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_unique_dup');

SELECT documentdb_api.drop_collection('bg_unique_hook_db', 'multinode_unique_dup');

------------------------------------------------------------
-- Background unique index on a sharded collection
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_hook_db', 'multinode_sharded_unique');
SELECT COUNT(documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_sharded_unique',
	FORMAT('{ "_id": %s, "a": %s }', i, i)::documentdb_core.bson))
FROM generate_series(1, 10) i;

SELECT documentdb_api.shard_collection(
	'{ "shardCollection": "bg_unique_hook_db.multinode_sharded_unique", "key": { "a": "hashed" }, "numInitialChunks": 2 }');

SELECT COUNT(DISTINCT node.groupid) > 1 AS has_shards_on_multiple_nodes
FROM pg_dist_shard shard
JOIN pg_dist_shard_placement placement ON placement.shardid = shard.shardid
JOIN pg_dist_node node
	ON node.nodename = placement.nodename AND node.nodeport = placement.nodeport
WHERE shard.logicalrelid = (
	SELECT FORMAT('documentdb_data.documents_%s', collection_id)::regclass
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_sharded_unique');

SELECT (documentdb_api.create_indexes_background(
	'bg_unique_hook_db',
	'{ "createIndexes": "multinode_sharded_unique", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }')).ok;

SELECT index_cmd LIKE 'CREATE INDEX CONCURRENTLY %' AS uses_concurrent_index,
	   index_cmd NOT LIKE '%WITH OPERATOR%' AS omits_exclusion_operators
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_sharded_unique');

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT count(*) AS pending_creates
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_sharded_unique');

SELECT *
FROM documentdb_distributed_test_helpers.unique_constraint_state(
	'bg_unique_hook_db', 'multinode_sharded_unique', 'a_1_unique');

SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_sharded_unique',
	'{ "_id": 100, "a": 1 }');

SELECT documentdb_api.drop_collection('bg_unique_hook_db', 'multinode_sharded_unique');

------------------------------------------------------------
-- Existing duplicates fail during the sharded heap walk
------------------------------------------------------------
SELECT documentdb_api.create_collection('bg_unique_hook_db', 'multinode_sharded_dup');
SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_sharded_dup',
	'{ "_id": 1, "a": 1 }');
SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_sharded_dup',
	'{ "_id": 2, "a": 1 }');

SELECT documentdb_api.shard_collection(
	'{ "shardCollection": "bg_unique_hook_db.multinode_sharded_dup", "key": { "a": "hashed" }, "numInitialChunks": 2 }');

SELECT (documentdb_api.create_indexes_background(
	'bg_unique_hook_db',
	'{ "createIndexes": "multinode_sharded_dup", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }')).ok;

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT index_cmd_status, comment
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_sharded_dup');

SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch')
FROM documentdb_api.list_indexes_cursor_first_page(
	'bg_unique_hook_db',
	'{ "listIndexes": "multinode_sharded_dup" }');

DELETE FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_sharded_dup');

SELECT documentdb_api.drop_collection('bg_unique_hook_db', 'multinode_sharded_dup');

SET documentdb.enableUniqueReindex TO true;
SET documentdb.enableNonBlockingUniqueIndexBuild TO false;

SELECT documentdb_api.create_collection('bg_unique_hook_db', 'multinode_reindex');
CALL documentdb_distributed_test_helpers.place_collection_on_node(
	'bg_unique_hook_db', 'multinode_reindex', 1);
SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_reindex',
	'{ "_id": 1, "a": 1 }');

SELECT documentdb_api_internal.create_indexes_non_concurrently(
	'bg_unique_hook_db',
	'{ "createIndexes": "multinode_reindex", "indexes": [ { "key": { "a": 1 }, "name": "a_1_unique", "unique": true, "storageEngine": { "enableOrderedIndex": true } } ] }',
	true);

SELECT documentdb_api.coll_mod(
	'bg_unique_hook_db',
	'multinode_reindex',
	'{ "collMod": "multinode_reindex", "index": { "name": "a_1_unique", "reindex": true, "updateOptions": true } }');

SELECT index_cmd LIKE 'CREATE INDEX CONCURRENTLY %' AS uses_concurrent_index,
	   index_cmd NOT LIKE '%WITH OPERATOR%' AS omits_exclusion_operators,
	   index_cmd LIKE '%optsk=%' AS uses_optional_key
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_reindex');

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT count(*) AS pending_reindexes
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_reindex');

SELECT *
FROM documentdb_distributed_test_helpers.unique_constraint_state(
	'bg_unique_hook_db', 'multinode_reindex', 'a_1_unique');

SELECT documentdb_api.shard_collection(
	'{ "shardCollection": "bg_unique_hook_db.multinode_reindex", "key": { "a": "hashed" }, "numInitialChunks": 2 }');

SELECT COUNT(DISTINCT node.groupid) > 1 AS has_shards_on_multiple_nodes
FROM pg_dist_shard shard
JOIN pg_dist_shard_placement placement ON placement.shardid = shard.shardid
JOIN pg_dist_node node
	ON node.nodename = placement.nodename AND node.nodeport = placement.nodeport
WHERE shard.logicalrelid = (
	SELECT FORMAT('documentdb_data.documents_%s', collection_id)::regclass
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_reindex');

SET documentdb_distributed.enable_non_blocking_unique_index_build_on_multi_node TO false;

SELECT documentdb_api.coll_mod(
	'bg_unique_hook_db',
	'multinode_reindex',
	'{ "collMod": "multinode_reindex", "index": { "name": "a_1_unique", "reindex": true, "updateOptions": true } }');

SELECT count(*) AS pending_reindexes
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_reindex');

SET documentdb_distributed.enable_non_blocking_unique_index_build_on_multi_node TO true;

SELECT documentdb_api.coll_mod(
	'bg_unique_hook_db',
	'multinode_reindex',
	'{ "collMod": "multinode_reindex", "index": { "name": "a_1_unique", "reindex": true, "updateOptions": true } }');

SELECT index_cmd LIKE 'CREATE INDEX CONCURRENTLY %' AS uses_concurrent_index,
	   index_cmd NOT LIKE '%WITH OPERATOR%' AS omits_exclusion_operators,
	   index_cmd LIKE '%optsk=%' AS uses_optional_key
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_reindex');

CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

SELECT count(*) AS pending_reindexes
FROM documentdb_api_catalog.documentdb_index_queue
WHERE collection_id = (
	SELECT collection_id
	FROM documentdb_api_catalog.collections
	WHERE database_name = 'bg_unique_hook_db'
		AND collection_name = 'multinode_reindex');

SELECT *
FROM documentdb_distributed_test_helpers.unique_constraint_state(
	'bg_unique_hook_db', 'multinode_reindex', 'a_1_unique');

SELECT documentdb_api.insert_one(
	'bg_unique_hook_db',
	'multinode_reindex',
	'{ "_id": 2, "a": 1 }');

SELECT documentdb_api.drop_collection('bg_unique_hook_db', 'multinode_reindex');
