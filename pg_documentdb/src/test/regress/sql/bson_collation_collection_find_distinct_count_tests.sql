-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core;

SET documentdb.next_collection_id TO 782200;
SET documentdb.next_collection_index_id TO 782200;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_api.create_collection('collation_find_db', 'default_match');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "fr", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_find_db' AND collection_name = 'default_match';

SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_match', '{ "_id": 1, "value": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_match', '{ "_id": 2, "value": "CAFÉ" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_match', '{ "_id": 3, "value": "CAFE" }');

-- An omitted or empty command collation inherits the collection default.
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 } }')
$cmd$);
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 }, "collation": {} }');

-- An explicit command collation takes precedence over the collection default.
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 }, "collation": { "locale": "simple" } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 }, "collation": { "locale": "simple" } }')
$cmd$);
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 2 } }')
$cmd$);

-- Distinct inherits the collection default for both filtering and value comparison.
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value" }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value" }')
$cmd$);
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "_id", "query": { "value": "cafe" } }');

-- Empty collation inherits the default, while explicit simple collation overrides it.
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value", "collation": {} }');
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value", "collation": { "locale": "simple" } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value", "collation": { "locale": "simple" } }')
$cmd$);
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value", "collation": { "locale": "fr", "strength": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value", "collation": { "locale": "fr", "strength": 2 } }')
$cmd$);

SELECT documentdb_api.create_collection('collation_find_db', 'default_turkish');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "tr", "strength": 2 } }'::documentdb_core.bson
WHERE database_name = 'collation_find_db' AND collection_name = 'default_turkish';

SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_turkish', '{ "_id": 1, "value": "i" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_turkish', '{ "_id": 2, "value": "İ" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_turkish', '{ "_id": 3, "value": "I" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_turkish', '{ "_id": 4, "value": "ı" }');

-- Turkish collation keeps dotted and dotless I in separate equivalence classes.
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_turkish", "filter": { "value": "i" }, "sort": { "_id": 1 } }');
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_turkish", "key": "value" }');
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_turkish", "key": "value", "collation": { "locale": "simple" } }');

SELECT documentdb_api.create_collection('collation_find_db', 'default_sort');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "de", "numericOrdering": true } }'::documentdb_core.bson
WHERE database_name = 'collation_find_db' AND collection_name = 'default_sort';

SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_sort', '{ "_id": 1, "value": "10" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_sort', '{ "_id": 2, "value": "2" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'default_sort', '{ "_id": 3, "value": "1" }');

-- The inherited default applies to sorting as well as matching.
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_sort", "filter": {}, "sort": { "value": 1 } }');
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_sort", "filter": {}, "sort": { "value": 1 }, "collation": { "locale": "simple" } }');

SELECT documentdb_api.create_collection('collation_find_db', 'no_default');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'no_default', '{ "_id": 1, "value": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'no_default', '{ "_id": 2, "value": "CAFE" }');

-- Collections without a default retain binary comparison behavior.
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "no_default", "filter": { "value": "cafe" }, "sort": { "_id": 1 } }');
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "no_default", "key": "value" }');

SELECT documentdb_api.create_collection('collation_find_db', 'explicit_simple');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "simple" } }'::documentdb_core.bson
WHERE database_name = 'collation_find_db' AND collection_name = 'explicit_simple';

SELECT documentdb_api.insert_one(
    'collation_find_db', 'explicit_simple', '{ "_id": 1, "value": "cafe" }');
SELECT documentdb_api.insert_one(
    'collation_find_db', 'explicit_simple', '{ "_id": 2, "value": "CAFE" }');

-- A collection created with an explicit simple collation uses binary comparisons.
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "explicit_simple", "filter": { "value": "cafe" }, "sort": { "_id": 1 } }');
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "explicit_simple", "key": "value" }');

-- Count inherits the collection default when command collation is omitted, null, or empty.
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" } }')
$cmd$);
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" }, "collation": null }');
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" }, "collation": {} }');

-- Meaningful explicit command collations override the collection default.
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" }, "collation": { "locale": "simple" } }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_count(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" }, "collation": { "locale": "simple" } }')
$cmd$);
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" }, "collation": { "locale": "fr", "strength": 2 } }');

-- Collections without an applicable default and missing collections retain existing behavior.
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "no_default", "query": { "value": "cafe" } }');
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "missing_default", "query": { "value": "cafe" } }');
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "explicit_simple", "query": { "value": "cafe" } }');

-- Disabling collation also retains binary comparison behavior.
SET documentdb_core.enableCollation TO off;
SELECT document FROM bson_aggregation_find(
    'collation_find_db',
    '{ "find": "default_match", "filter": { "value": "cafe" }, "sort": { "_id": 1 } }');
SELECT bson_dollar_project(document, '{ "count": { "$size": "$values" } }')
FROM documentdb_api.distinct_query(
    'collation_find_db',
    '{ "distinct": "default_match", "key": "value" }');
SELECT document FROM documentdb_api.count_query(
    'collation_find_db',
    '{ "count": "default_match", "query": { "value": "cafe" } }');

RESET documentdb_core.enableCollation;
RESET documentdb.enableExtendedExplainPlans;
RESET search_path;
