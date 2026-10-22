SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 99800;
SET documentdb.next_collection_index_id TO 99800;

-- Test: $densify with partitionByFields on shard key should not crash (issue #464)
-- When partitionByFields matches the shard key, the partition expression uses INT8
-- shard_key_value column. The sort/eq operators must match that type.

SELECT insert_one('db','densify_shard_test','{ "_id": 1, "a": "abc", "cost": 10 }', NULL);
SELECT insert_one('db','densify_shard_test','{ "_id": 2, "a": "abc", "cost": 5 }', NULL);
SELECT insert_one('db','densify_shard_test','{ "_id": 3, "a": "def", "cost": 3 }', NULL);
SELECT insert_one('db','densify_shard_test','{ "_id": 4, "a": "def", "cost": 7 }', NULL);

-- Shard the collection on the field used as partitionByFields
SELECT documentdb_api.shard_collection('db', 'densify_shard_test', '{"a": "hashed"}', false);

-- Partition mode: should densify within each partition without crashing
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$densify": { "field": "cost", "partitionByFields": ["a"], "range": { "bounds": "partition", "step": 1 } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Range mode with shard key partition
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$densify": { "field": "cost", "partitionByFields": ["a"], "range": { "bounds": [4, 8], "step": 1 } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Full mode with shard key partition
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$densify": { "field": "cost", "partitionByFields": ["a"], "range": { "bounds": "full", "step": 1 } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Full mode must initialize fresh state when a correlated lookup rescans its pipeline.
SELECT insert_one('db','densify_rescan_outer','{ "_id": 1, "k": 0 }', NULL);
SELECT insert_one('db','densify_rescan_outer','{ "_id": 2, "k": 0 }', NULL);
SELECT insert_one('db','densify_rescan_inner','{ "_id": 1, "v": 0 }', NULL);
SELECT insert_one('db','densify_rescan_inner','{ "_id": 2, "v": 5 }', NULL);

SELECT document FROM bson_aggregation_pipeline(
        'db',
        $pipeline$
        {
            "aggregate": "densify_rescan_outer",
            "pipeline": [
                {
                    "$lookup": {
                        "from": "densify_rescan_inner",
                        "let": { "kk": "$k" },
                        "pipeline": [
                            { "$match": { "$expr": { "$gte": [ "$v", "$$kk" ] } } },
                            { "$densify": { "field": "v", "range": { "bounds": "full", "step": 1 } } }
                        ],
                        "as": "values"
                    }
                },
                { "$project": { "_id": 1, "count": { "$size": "$values" } } },
                { "$sort": { "_id": 1 } }
            ]
        }
        $pipeline$
);

SELECT insert_one('db','densify_rescan_inner','{ "_id": 3, "v": 10 }', NULL);

SELECT document FROM bson_aggregation_pipeline(
        'db',
        $pipeline$
        {
            "aggregate": "densify_rescan_outer",
            "pipeline": [
                {
                    "$lookup": {
                        "from": "densify_rescan_inner",
                        "let": { "kk": "$k" },
                        "pipeline": [
                            { "$match": { "$expr": { "$gte": [ "$v", "$$kk" ] } } },
                            { "$densify": { "field": "v", "range": { "bounds": "full", "step": 1 } } },
                            { "$limit": 2 }
                        ],
                        "as": "values"
                    }
                },
                { "$project": { "_id": 1, "values": "$values.v" } },
                { "$sort": { "_id": 1 } }
            ]
        }
        $pipeline$
);

SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_rescan_outer", "pipeline": [
        { "$lookup": { "from": "densify_rescan_inner", "let": { "kk": "$k" }, "pipeline": [
            { "$match": { "$expr": { "$gte": [ "$v", "$$kk" ] } } },
            { "$addFields": { "group.kind": "$_id", "v": { "$toDate": { "$multiply": ["$v", { "$numberLong": "86400000" }] } } } },
            { "$densify": { "field": "v", "partitionByFields": ["group.kind"], "range": { "bounds": "full", "step": 1, "unit": "day" } } }
        ], "as": "values" } },
        { "$project": { "_id": 1, "count": { "$size": "$values" } } },
        { "$sort": { "_id": 1 } }
    ] }');

SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_rescan_outer", "pipeline": [
        { "$lookup": { "from": "densify_rescan_inner", "let": { "kk": "$k" }, "pipeline": [
            { "$match": { "$expr": { "$gte": [ "$v", "$$kk" ] } } },
            { "$addFields": { "group.kind": "$_id", "v": { "$toDate": { "$multiply": ["$v", { "$numberLong": "86400000" }] } } } },
            { "$densify": { "field": "v", "partitionByFields": ["group.kind"], "range": { "bounds": "full", "step": 1, "unit": "day" } } },
            { "$limit": 2 }
        ], "as": "values" } },
        { "$project": { "_id": 1, "values": "$values.v", "groups": "$values.group.kind" } },
        { "$sort": { "_id": 1 } }
    ] }');

SELECT drop_collection('db', 'densify_rescan_outer');
SELECT drop_collection('db', 'densify_rescan_inner');

-- Test: $setWindowFields with partitionBy on shard key should not crash
-- Same root cause as $densify: INT8 shard_key_value used as partition expression
-- with BSON sort operators causes a segfault.
SELECT document FROM bson_aggregation_pipeline('db',
    '{ "aggregate": "densify_shard_test", "pipeline": [{"$setWindowFields": { "partitionBy": "$a", "sortBy": {"cost": 1}, "output": { "runningTotal": { "$sum": "$cost" } } } }, {"$sort": {"a": 1, "cost": 1}}]}');

-- Cleanup
SELECT drop_collection('db', 'densify_shard_test');

WITH specs AS MATERIALIZED (
    SELECT '{ "field": "v", "range": { "bounds": "full", "step": 1 } }'::bson AS spec
)
SELECT bson_densify_full('{ "v": 0 }'::bson, spec) OVER () FROM specs;
