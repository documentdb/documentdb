-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb.next_collection_id TO 2900;
SET documentdb.next_collection_index_id TO 2900;
SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enablePerPathMultiKeySortPushdown TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;
SET documentdb.enable_multi_key_filter_index_only_scan TO on;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

-- Independent predicates can match different elements of the same array.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_correctness',
    '{"createIndexes":"correlated_count","indexes":[{"key":{"a.x":1,"a.y":1,"_id":1},"name":"idx","enableOrderedIndex":true}]}', true);
SELECT documentdb_api.insert_one('mkp_correctness', 'correlated_count',
    '{"_id":1,"a":[{"x":1,"y":0},{"x":0,"y":2}]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'correlated_count',
    '{"_id":2,"a":[{"x":1,"y":2}]}');
SELECT document FROM bson_aggregation_pipeline('mkp_correctness',
    '{"aggregate":"correlated_count","pipeline":[{"$match":{"a.x":1,"a.y":2}},{"$count":"n"}],"hint":"idx"}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"correlated_count","filter":{"a.x":1,"a.y":2},"projection":{"_id":1},"sort":{"_id":1},"hint":"idx"}');

-- Sorting must consider every array element, not just elements matching a filter.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_correctness',
    '{"createIndexes":"correlated_sort","indexes":[{"key":{"a.x":1,"a.y":1,"_id":1},"name":"idx","enableOrderedIndex":true}]}', true);
SELECT documentdb_api.insert_one('mkp_correctness', 'correlated_sort',
    '{"_id":1,"a":[{"x":0,"y":0},{"x":9,"y":2}]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'correlated_sort',
    '{"_id":2,"a":[{"x":5,"y":2}]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'correlated_sort',
    '{"_id":3,"a":[{"x":100,"y":0},{"x":4,"y":2}]}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"correlated_sort","filter":{"a.y":2},"sort":{"a.x":1,"a.y":1,"_id":1},"projection":{"_id":1},"limit":1,"hint":"idx"}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"correlated_sort","filter":{"a.y":2},"sort":{"a.x":-1,"a.y":-1,"_id":-1},"projection":{"_id":1},"limit":1,"hint":"idx"}');

-- Case-insensitive matching must not change the correlation or array sort rules.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_correctness',
    '{"createIndexes":"collated","indexes":[{"key":{"a.x":1,"a.y":1,"_id":1},"name":"idx","enableOrderedIndex":true,"collation":{"locale":"en","strength":2}}]}', true);
SELECT documentdb_api.insert_one('mkp_correctness', 'collated',
    '{"_id":1,"a":[{"x":"Alpha","y":"other"},{"x":"Zulu","y":"match"}]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'collated',
    '{"_id":2,"a":[{"x":"Mike","y":"MATCH"}]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'collated',
    '{"_id":3,"a":[{"x":"ALPHA","y":"match"}]}');
SELECT document FROM bson_aggregation_pipeline('mkp_correctness',
    '{"aggregate":"collated","pipeline":[{"$match":{"a.x":"alpha","a.y":"MATCH"}},{"$count":"n"}],"hint":"idx","collation":{"locale":"en","strength":2}}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"collated","filter":{"a.y":"MATCH"},"sort":{"a.x":1,"a.y":1,"_id":1},"projection":{"_id":1},"limit":1,"hint":"idx","collation":{"locale":"en","strength":2}}');

-- Scalar $elemMatch bounds must work at leading and non-leading index positions.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_correctness',
    '{"createIndexes":"scalar_elemmatch","indexes":[
        {"key":{"b":1,"a":1,"_id":1},"name":"b_first","enableOrderedIndex":true},
        {"key":{"a":1,"b":1,"_id":1},"name":"b_second","enableOrderedIndex":true},
        {"key":{"a":1,"_id":1,"b":1},"name":"b_third","enableOrderedIndex":true},
        {"key":{"a":1,"_id":1,"b":1},"name":"b_third_ci","enableOrderedIndex":true,"collation":{"locale":"en","strength":2}}
    ]}', true);
SELECT documentdb_api.insert_one('mkp_correctness', 'scalar_elemmatch',
    '{"_id":1,"a":1,"b":[2,8]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'scalar_elemmatch',
    '{"_id":2,"a":2,"b":[0,9]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'scalar_elemmatch',
    '{"_id":3,"a":3,"b":[3,7]}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"scalar_elemmatch","filter":{"b":{"$elemMatch":{"$gt":1,"$lt":4}}},"projection":{"_id":1},"sort":{"_id":1},"hint":"b_first"}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"scalar_elemmatch","filter":{"b":{"$elemMatch":{"$gt":1,"$lt":4}}},"projection":{"_id":1},"sort":{"_id":1},"hint":"b_second"}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"scalar_elemmatch","filter":{"b":{"$elemMatch":{"$gt":1,"$lt":4}}},"projection":{"_id":1},"sort":{"_id":1},"hint":"b_third"}');
SELECT documentdb_api.insert_one('mkp_correctness', 'scalar_elemmatch',
    '{"_id":4,"a":4,"b":["Alpha","Zulu"]}');
SELECT documentdb_api.insert_one('mkp_correctness', 'scalar_elemmatch',
    '{"_id":5,"a":5,"b":["Aardvark","Zulu"]}');
SELECT document FROM bson_aggregation_find('mkp_correctness',
    '{"find":"scalar_elemmatch","filter":{"b":{"$elemMatch":{"$gt":"abc","$lt":"bravo"}}},"projection":{"_id":1},"hint":"b_third_ci","collation":{"locale":"en","strength":2}}');

-- A distinct re-seek can exhaust the index while truncated values still need processing.
SET documentdb.indexTermLimitOverride TO 96;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_correctness',
    '{"createIndexes":"truncated_distinct","indexes":[{"key":{"a":1,"_id":1},"name":"idx","enableOrderedIndex":true}]}', true);
SELECT documentdb_api.insert_one('mkp_correctness', 'truncated_distinct',
    format('{"_id":1,"a":"%sA"}', repeat('p', 160))::bson);
SELECT documentdb_api.insert_one('mkp_correctness', 'truncated_distinct',
    format('{"_id":2,"a":"%sB"}', repeat('p', 160))::bson);
RESET documentdb.indexTermLimitOverride;
SET documentdb.enableDistinctCustomScan TO on;
SET enable_hashagg TO off;
SELECT document FROM bson_aggregation_distinct('mkp_correctness',
    '{"distinct":"truncated_distinct","key":"a","query":{"_id":{"$gt":0}},"hint":{"a":1,"_id":1}}');
