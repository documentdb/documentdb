-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core;
SET documentdb.next_collection_id TO 25705100;
SET documentdb.next_collection_index_id TO 25705100;

-- A non-simple collection default rejects sharding with or without command collation.
SELECT documentdb_api.create_collection('db', 'collated_shard');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"en","strength":1}}'::documentdb_core.bson
WHERE database_name = 'db' AND collection_name = 'collated_shard';
SELECT documentdb_api_internal.invalidate_collection_cache();

SET documentdb_core.enableCollation TO off;
SELECT documentdb_api.shard_collection('db', 'collated_shard', '{"_id":"hashed"}', false);
SET documentdb_core.enableCollation TO on;
SELECT documentdb_api.shard_collection('{"shardCollection":"db.collated_shard","key":{"_id":"hashed"}}');
SELECT documentdb_api.shard_collection('{"shardCollection":"db.collated_shard","key":{"_id":"hashed"},"collation":{"locale":"simple"}}');
SELECT collection_name, shard_key IS NULL AS unsharded
FROM documentdb_api_catalog.collections
WHERE database_name = 'db' AND collection_name = 'collated_shard';

SELECT documentdb_api.create_collection('db', 'collated_reshard');
SELECT documentdb_api.shard_collection('db', 'collated_reshard', '{"_id":"hashed"}', false);
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"en","strength":1}}'::documentdb_core.bson
WHERE database_name = 'db' AND collection_name = 'collated_reshard';
SELECT documentdb_api_internal.invalidate_collection_cache();

-- The same-key shortcut and forced redistribution must both honor the default.
SELECT documentdb_api.reshard_collection('{"reshardCollection":"db.collated_reshard","key":{"_id":"hashed"}}');
SELECT documentdb_api.reshard_collection('{"reshardCollection":"db.collated_reshard","key":{"_id":"hashed"},"collation":{"locale":"simple"}}');
SELECT documentdb_api.reshard_collection('{"reshardCollection":"db.collated_reshard","key":{"other":"hashed"},"forceRedistribution":true}');
SELECT documentdb_api.shard_collection('db', 'collated_reshard', '{"other":"hashed"}', true);
SELECT collection_name, shard_key
FROM documentdb_api_catalog.collections
WHERE database_name = 'db' AND collection_name = 'collated_reshard';
SELECT documentdb_api.unshard_collection('{"unshardCollection":"db.collated_reshard"}');

-- A simple collection default does not prevent sharding.
SELECT documentdb_api.create_collection('db', 'simple_collation_shard');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"simple"}}'::documentdb_core.bson
WHERE database_name = 'db' AND collection_name = 'simple_collation_shard';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.shard_collection('{"shardCollection":"db.simple_collation_shard","key":{"_id":"hashed"}}');
SELECT documentdb_api.unshard_collection('{"unshardCollection":"db.simple_collation_shard"}');
RESET documentdb_core.enableCollation;
