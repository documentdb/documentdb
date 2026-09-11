SET search_path TO documentdb_api_catalog;

SET documentdb.next_collection_id TO 14200;
SET documentdb.next_collection_index_id TO 14200;

SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl','{ "_id": 1, "year": 2020, "category": "X", "stats": { "2020A": 10, "2020B": 20 } }', NULL);
SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl','{ "_id": 2, "year": 2019, "category": "X", "stats": { "2019A": 30, "2019B": 40, "2019C": 0, "2019D": 0 } }', NULL);
SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl','{ "_id": 3, "year": 2020, "category": "Y", "stats": { "2020A": 50 } }', NULL);
SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl','{ "_id": 4, "year": 2019, "category": "Y", "stats": { "2019C": 60, "2019D": 70 } }', NULL);
SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl','{ "_id": 5, "year": 2020, "category": "Z", "stats": { "2019C": 80, "2019D": 90 } }', NULL);

/* running multiple $mergeObjects accumulators with different expressions */
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$group": { "_id": "$year", "mergedStats": { "$mergeObjects": "$stats" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$group": { "_id": "$category", "mergedStats": { "$mergeObjects": "$stats" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$group": { "_id": "$year", "lastCategory": { "$mergeObjects": { "category": "$category" } } } } ] }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$group": { "_id": "$year", "mergedStats": { "$mergeObjects": "$stats" } } } ] }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$group": { "_id": "$category", "mergedStats": { "$mergeObjects": "$stats" } } } ] }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$group": { "_id": "$year", "lastCategory": { "$mergeObjects": { "category": "$category" } } } } ] }');

SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl2','{ "_id": 13, "group": 1, "obj": {}, "val": null }', NULL);
SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl2','{ "_id": 14, "group": 1, "obj": { "x": 2, "y": 2 } }', NULL);
SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl2','{ "_id": 15, "group": 1, "obj": { "x": 1, "z": 3, "y": null } }', NULL);
SELECT documentdb_api.insert_one('db','mergeObjectsGroupColl2','{ "_id": 16, "group": 2, "obj": { "x": 1, "y": 1 }, "val": null }', NULL);

/* running multiple $mergeObjects accumulators with different expressions */
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": "$obj" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": "$obj.x" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": { "result": "$obj.y" } } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": "$val" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$group": { "_id": null, "mergedObj": { "$mergeObjects": "$missing" } } } ] }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": "$obj" } } } ] }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": "$obj.x" } } } ] }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": { "result": "$obj.y" } } } } ] }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl2", "pipeline": [ { "$group": { "_id": "$group", "mergedObj": { "$mergeObjects": "$val" } } } ] }');

/* shard collections and test for order and validations */
SELECT documentdb_api.shard_collection('db', 'mergeObjectsGroupColl', '{ "_id": "hashed" }', false);

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$sort": { "category": 1 } }, { "$group": { "_id": "$year", "mergedStats": { "$mergeObjects": "$stats" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$sort": { "category": 1 } }, { "$group": { "_id": "$category", "mergedStats": { "$mergeObjects": "$stats" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$sort": { "category": 1 } }, { "$group": { "_id": "$year", "lastCategory": { "$mergeObjects": { "category": "$category" } } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$sort": { "category": 1 } }, { "$group": { "_id": "$year", "shouldFail": { "$mergeObjects": "$category" } } } ] }');

/* The combined sort/group stage keeps the user sort for order-sensitive
 * $mergeObjects accumulators. */
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mergeObjectsGroupColl", "pipeline": [ { "$sort": { "category": 1 } }, { "$group": { "_id": "$year", "mergedStats": { "$mergeObjects": "$stats" } } } ] }');

select documentdb_api.drop_collection('db','mergeObjectsGroupColl');
select documentdb_api.drop_collection('db','mergeObjectsGroupColl2');

/* Sorted merges must overwrite fields in sort order, independently per group. */
SET documentdb.enableOrderByIndexTerm TO on;
SELECT documentdb_api.insert_one('db', 'sortedMergeObjects', '{"_id":1,"group":"a","rank":2,"obj":{"value":2,"nested":{"new":2}}}');
SELECT documentdb_api.insert_one('db', 'sortedMergeObjects', '{"_id":2,"group":"b","rank":3,"obj":null}');
SELECT documentdb_api.insert_one('db', 'sortedMergeObjects', '{"_id":3,"group":"a","rank":1,"obj":{"value":1,"nested":{"old":1},"onlyFirst":true}}');
SELECT documentdb_api.insert_one('db', 'sortedMergeObjects', '{"_id":4,"group":"b","rank":1,"obj":{"value":10}}');
SELECT documentdb_api.insert_one('db', 'sortedMergeObjects', '{"_id":5,"group":"a","rank":3,"obj":{"value":null,"last":true}}');
SELECT documentdb_api.insert_one('db', 'sortedMergeObjects', '{"_id":6,"group":"b","rank":2}');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"rank":1,"_id":1}},{"$group":{"_id":"$group","merged":{"$mergeObjects":"$obj"}}},{"$sort":{"_id":1}}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"group":1,"rank":-1}},{"$group":{"_id":"$group","merged":{"$mergeObjects":"$obj"}}},{"$sort":{"_id":1}}]}');

/* Multiple merge and order-sensitive accumulators share the original input. */
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"rank":1,"_id":1}},{"$group":{"_id":"$group","merged":{"$mergeObjects":"$obj"},"lastDocument":{"$mergeObjects":"$$ROOT"},"first":{"$first":"$_id"},"last":{"$last":"$_id"},"ids":{"$push":"$_id"}}},{"$sort":{"_id":1}}]}');

/* Missing fields in constructed objects remain absent, rather than becoming null. */
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"rank":1,"_id":1}},{"$group":{"_id":null,"merged":{"$mergeObjects":{"missing":"$missing","value":"$obj.value"}}}}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$match":{"_id":-1}},{"$sort":{"rank":1}},{"$group":{"_id":null,"merged":{"$mergeObjects":"$obj"}}}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"rank":1}},{"$group":{"_id":null,"merged":{"$mergeObjects":"$rank"}}}]}');

/* A limit between sorting and grouping must still restrict the input. */
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"rank":1,"_id":1}},{"$skip":1},{"$limit":3},{"$group":{"_id":null,"merged":{"$mergeObjects":"$obj"}}}]}');

/* Exercise the alternate BSON sort representation in both directions. */
SET documentdb.enableOrderByIndexTerm TO off;
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"rank":1,"_id":1}},{"$group":{"_id":"$group","merged":{"$mergeObjects":"$obj"}}},{"$sort":{"_id":1}}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"group":1,"rank":-1}},{"$group":{"_id":"$group","merged":{"$mergeObjects":"$obj"}}},{"$sort":{"_id":1}}]}');
RESET documentdb.enableOrderByIndexTerm;

/* A sorted merge uses the executor's ORDER BY, not the bounded N accumulator. */
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"sortedMergeObjects","pipeline":[{"$sort":{"rank":1,"_id":1}},{"$group":{"_id":null,"merged":{"$mergeObjects":"$obj"}}}]}');

/* Keep per-group results correct when the executor must spill sorted input. */
SELECT count(documentdb_api.insert_one('db', 'mergeObjectsSpill',
    json_build_object('_id', i, 'group', i % 2, 'obj', json_build_object('version', i, 'padding', repeat('x', 128)))::text::documentdb_core.bson))
FROM generate_series(1, 2000) i;
SET work_mem TO '64kB';
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"mergeObjectsSpill","pipeline":[{"$sort":{"_id":-1}},{"$group":{"_id":"$group","merged":{"$mergeObjects":"$obj"}}},{"$project":{"merged.padding":0}},{"$sort":{"_id":1}}]}');
RESET work_mem;
/* The final object can stay small while cumulative overwritten input exceeds 100 MiB. */
SELECT count(documentdb_api.insert_one('db', 'mergeObjectsLargeInput',
    json_build_object('_id', i, 'obj', json_build_object('version', i, 'padding', repeat('x', 2097152)))::text::documentdb_core.bson))
FROM generate_series(1, 51) i;
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{"aggregate":"mergeObjectsLargeInput","pipeline":[{"$sort":{"_id":1}},{"$group":{"_id":null,"merged":{"$mergeObjects":"$obj"}}},{"$project":{"merged.padding":0}}]}');
SELECT documentdb_api.drop_collection('db', 'mergeObjectsLargeInput');

SELECT documentdb_api.drop_collection('db', 'sortedMergeObjects');
SELECT documentdb_api.drop_collection('db', 'mergeObjectsSpill');
