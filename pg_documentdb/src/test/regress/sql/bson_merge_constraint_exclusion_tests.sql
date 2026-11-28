SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 9700;
SET documentdb.next_collection_index_id TO 9700;

-- $merge and $out join the target and the source on shard_key_value, a bigint column.
-- With constraint_exclusion = on the planner compares that join clause with the
-- target's shard_key_value_check constraint, so the clause must use a bigint operator.
SELECT documentdb_api.insert_one('mergeCeDb', 'src', '{ "_id": 1, "a": 1 }', NULL);
SELECT documentdb_api.insert_one('mergeCeDb', 'src', '{ "_id": 2, "a": 2 }', NULL);

SET constraint_exclusion TO on;

-- $merge creates the target, then merges into the existing target
SELECT * FROM aggregate_cursor_first_page('mergeCeDb', '{ "aggregate": "src", "pipeline": [ { "$merge": { "into": "mergeTarget" } } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT document FROM documentdb_api.collection('mergeCeDb', 'mergeTarget') ORDER BY object_id;

SELECT * FROM aggregate_cursor_first_page('mergeCeDb', '{ "aggregate": "src", "pipeline": [ { "$addFields": { "b": 1 } }, { "$merge": { "into": "mergeTarget", "whenMatched": "replace" } } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT document FROM documentdb_api.collection('mergeCeDb', 'mergeTarget') ORDER BY object_id;

-- $out into a new and into an existing target
SELECT * FROM aggregate_cursor_first_page('mergeCeDb', '{ "aggregate": "src", "pipeline": [ { "$out": "outTarget" } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT * FROM aggregate_cursor_first_page('mergeCeDb', '{ "aggregate": "src", "pipeline": [ { "$match": { "a": 2 } }, { "$out": "outTarget" } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT document FROM documentdb_api.collection('mergeCeDb', 'outTarget') ORDER BY object_id;

RESET constraint_exclusion;
