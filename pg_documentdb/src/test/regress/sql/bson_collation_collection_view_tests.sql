-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core;
SET documentdb.next_collection_id TO 25705300;
SET documentdb.next_collection_index_id TO 25705300;

SELECT documentdb_api.create_collection('db', 'collated_view_source');
SELECT documentdb_api.create_collection('db', 'simple_view_source');
SELECT documentdb_api.create_collection_view('db', '{ "create": "collated_view_source_view", "viewOn": "collated_view_source" }');

-- A non-simple source default rejects new views, including chained views and pipeline references.
SELECT documentdb_api.create_collection_view('db', '{ "create": "simple_source_view", "viewOn": "simple_view_source" }');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"en","strength":1}}'::documentdb_core.bson
WHERE database_name = 'db' AND collection_name = 'collated_view_source';
SELECT documentdb_api_internal.invalidate_collection_cache();

SET documentdb_core.enableCollation TO off;
SELECT documentdb_api.create_collection_view('db', '{ "create": "collated_source_view_off", "viewOn": "collated_view_source" }');
SET documentdb_core.enableCollation TO on;
SELECT documentdb_api.create_collection_view('db', '{ "create": "collated_source_view_on", "viewOn": "collated_view_source" }');
SELECT documentdb_api.create_collection_view('db', '{ "create": "collated_chained_view", "viewOn": "collated_view_source_view" }');
SELECT documentdb_api.create_collection_view('db', '{ "create": "collated_lookup_view", "viewOn": "simple_view_source", "pipeline": [ { "$lookup": { "from": "collated_view_source", "localField": "a", "foreignField": "a", "as": "matches" } } ] }');
SELECT documentdb_api.coll_mod('db', 'simple_source_view', '{ "collMod": "simple_source_view", "viewOn": "collated_view_source", "pipeline": [] }');
SELECT collection_name FROM documentdb_api_catalog.collections
WHERE database_name = 'db' AND collection_name IN ('collated_source_view_off', 'collated_source_view_on', 'collated_chained_view', 'collated_lookup_view')
ORDER BY collection_name;

-- A simple source default still permits direct and chained views.
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"simple"}}'::documentdb_core.bson
WHERE database_name = 'db' AND collection_name = 'collated_view_source';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.create_collection_view('db', '{ "create": "simple_default_view", "viewOn": "collated_view_source" }');
SELECT documentdb_api.create_collection_view('db', '{ "create": "simple_default_chained_view", "viewOn": "collated_view_source_view" }');
RESET documentdb_core.enableCollation;
