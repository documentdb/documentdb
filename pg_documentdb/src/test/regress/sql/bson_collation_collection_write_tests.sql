-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core,documentdb_api_internal,pg_catalog;

SET documentdb.next_collection_id TO 25900100;
SET documentdb.next_collection_index_id TO 25900100;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

-- delete command: collection-default collation inheritance.
SELECT documentdb_api.create_collection(
    'collation_write_db', 'delete_defaults');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_db'
  AND collection_name = 'delete_defaults';

SELECT documentdb_api.insert(
    'collation_write_db',
    '{
        "insert": "delete_defaults",
        "documents": [
            { "_id": 1, "batch": "single", "value": "café" },
            { "_id": 2, "batch": "single", "value": "tea" },
            { "_id": 3, "batch": "multi", "value": "café" },
            { "_id": 4, "batch": "multi", "value": "Cafe" },
            { "_id": 5, "batch": "override", "value": "café" },
            { "_id": 6, "batch": "override", "value": "cafe" },
            { "_id": 7, "batch": "simple", "value": "café" },
            { "_id": 8, "batch": "mixed_inherit", "value": "café" },
            { "_id": 9, "batch": "mixed_override", "value": "café" },
            { "_id": 10, "batch": "empty", "value": "café" },
            { "_id": 11, "batch": "null", "value": "café" },
            { "_id": 12, "batch": "retry", "value": "café" }
        ]
    }');

-- An omitted operation collation inherits the collection default for deleteOne.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        { "q": { "batch": "single", "value": "CAFE" }, "limit": 1 }
    ] }');
-- The generated plan carries the inherited effective collation.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        { "q": { "batch": "single", "value": "CAFE" }, "limit": 1 }
    ] }')
$cmd$);
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "single" }';
ROLLBACK;

-- The inherited default applies independently to deleteMany.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        { "q": { "batch": "multi", "value": "CAFE" }, "limit": 0 }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "multi" }';
ROLLBACK;

-- An explicit operation collation overrides the collection default.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        {
            "q": { "batch": "override", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "en", "strength": 2 }
        }
    ] }');
-- The generated plan carries the explicit operation override.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        {
            "q": { "batch": "override", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "en", "strength": 2 }
        }
    ] }')
$cmd$);
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "override" }'
ORDER BY object_id;
ROLLBACK;

-- Explicit simple collation retains binary comparison semantics.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        {
            "q": { "batch": "simple", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "simple" }
        }
    ] }');
-- The generated plan preserves explicit binary semantics.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        {
            "q": { "batch": "simple", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "simple" }
        }
    ] }')
$cmd$);
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "simple" }';
ROLLBACK;

-- Empty and null operation collations are omitted and inherit the default.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        {
            "q": { "batch": "empty", "value": "CAFE" },
            "limit": 0,
            "collation": {}
        },
        {
            "q": { "batch": "null", "value": "CAFE" },
            "limit": 0,
            "collation": null
        }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@)
    '{ "batch": { "$in": [ "empty", "null" ] } }';
ROLLBACK;

-- Ordered mixed batches do not leak an explicit override into a later operation.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "ordered": true, "deletes": [
        {
            "q": { "batch": "mixed_override", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "simple" }
        },
        {
            "q": { "batch": "mixed_inherit", "value": "CAFE" },
            "limit": 0
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@)
    '{ "batch": { "$in": [ "mixed_inherit", "mixed_override" ] } }'
ORDER BY object_id;
ROLLBACK;

-- Unordered mixed batches resolve each operation independently with inheritance first.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "ordered": false, "deletes": [
        {
            "q": { "batch": "mixed_inherit", "value": "CAFE" },
            "limit": 0
        },
        {
            "q": { "batch": "mixed_override", "value": "CAFE" },
            "limit": 0,
            "collation": { "locale": "simple" }
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@)
    '{ "batch": { "$in": [ "mixed_inherit", "mixed_override" ] } }'
ORDER BY object_id;
ROLLBACK;

-- Retryable deleteOne uses the same inherited effective collation.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        { "q": { "_id": 12, "value": "CAFE" }, "limit": 1 }
    ] }',
    NULL,
    'default-collation-retry');
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        { "q": { "_id": 12, "value": "CAFE" }, "limit": 1 }
    ] }',
    NULL,
    'default-collation-retry');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": 12 }';
ROLLBACK;

SELECT documentdb_api.create_collection(
    'collation_write_db', 'delete_no_default');
SELECT documentdb_api.insert_one(
    'collation_write_db',
    'delete_no_default',
    '{ "_id": 1, "value": "café" }');

-- A collection without a default retains binary comparison semantics.
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_no_default", "deletes": [
        { "q": { "value": "CAFE" }, "limit": 0 }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_no_default');
ROLLBACK;

SELECT documentdb_api.create_collection(
    'collation_write_db', 'delete_indexed');
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_db'
  AND collection_name = 'delete_indexed';
SELECT documentdb_api.insert(
    'collation_write_db',
    '{
        "insert": "delete_indexed",
        "documents": [
            { "_id": 1, "value": "café" },
            { "_id": 2, "value": "tea" }
        ]
    }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'collation_write_db',
    '{
        "createIndexes": "delete_indexed",
        "indexes": [
            {
                "key": { "value": 1 },
                "name": "delete_value_en_s1",
                "collation": { "locale": "en", "strength": 1 }
            }
        ]
    }',
    true);

-- A matching collation index remains eligible under an inherited default.
SET enable_seqscan TO off;
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_indexed", "deletes": [
        { "q": { "value": "CAFE" }, "limit": 0 }
    ] }');
-- The generated plan uses the matching collation index.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_delete(
    'collation_write_db',
    '{ "delete": "delete_indexed", "deletes": [
        { "q": { "value": "CAFE" }, "limit": 0 }
    ] }')
$cmd$);
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_indexed');
ROLLBACK;
RESET enable_seqscan;

-- Disabling collation prevents collection-default inheritance.
SET documentdb_core.enableCollation TO off;
BEGIN;
SELECT documentdb_api.delete(
    'collation_write_db',
    '{ "delete": "delete_defaults", "deletes": [
        { "q": { "batch": "single", "value": "CAFE" }, "limit": 0 }
    ] }');
SELECT count(*) FROM documentdb_api.collection(
    'collation_write_db', 'delete_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "single" }';
ROLLBACK;
SET documentdb_core.enableCollation TO on;

SELECT documentdb_api.drop_collection(
    'collation_write_db', 'delete_defaults');
SELECT documentdb_api.drop_collection(
    'collation_write_db', 'delete_no_default');
SELECT documentdb_api.drop_collection(
    'collation_write_db', 'delete_indexed');

-- update command: collection-default collation inheritance.
SELECT documentdb_api.create_collection(
    'collation_write_db', 'update_defaults');

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_db'
  AND collection_name = 'update_defaults';

SELECT documentdb_api.insert(
    'collation_write_db',
    '{
        "insert": "update_defaults",
        "documents": [
            { "_id": 1, "batch": "single", "value": "café" },
            { "_id": 2, "batch": "multi", "value": "café" },
            { "_id": 3, "batch": "multi", "value": "Cafe" },
            { "_id": 4, "batch": "override", "value": "café" },
            { "_id": 5, "batch": "override", "value": "cafe" },
            { "_id": 6, "batch": "simple", "value": "café" },
            { "_id": 7, "batch": "mixed_inherit", "value": "café" },
            { "_id": 8, "batch": "mixed_override", "value": "café" },
            { "_id": 9, "batch": "empty", "value": "café" },
            { "_id": 10, "batch": "null", "value": "café" },
            { "_id": 11, "batch": "retry", "value": "café" }
        ]
    }');

-- An omitted operation collation inherits the collection default for updateOne.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        { "q": { "batch": "single", "value": "CAFE" }, "u": { "$set": { "hit": true } } }
    ] }');
-- The generated plan carries the inherited effective collation.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        { "q": { "batch": "single", "value": "CAFE" }, "u": { "$set": { "hit": true } } }
    ] }')
$cmd$);
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "single" }'
ORDER BY object_id;
ROLLBACK;

-- The inherited default applies independently to a multi update.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        {
            "q": { "batch": "multi", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "multi" }'
ORDER BY object_id;
ROLLBACK;

-- An explicit operation collation overrides the collection default.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        {
            "q": { "batch": "override", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "en", "strength": 2 }
        }
    ] }');
-- The generated plan carries the explicit operation override.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        {
            "q": { "batch": "override", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "en", "strength": 2 }
        }
    ] }')
$cmd$);
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "override" }'
ORDER BY object_id;
ROLLBACK;

-- Explicit simple collation retains binary comparison semantics.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        {
            "q": { "batch": "simple", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "simple" }
        }
    ] }');
-- The generated plan preserves explicit binary semantics.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        {
            "q": { "batch": "simple", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "simple" }
        }
    ] }')
$cmd$);
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "simple" }'
ORDER BY object_id;
ROLLBACK;

-- Empty and null operation collations are omitted and inherit the default.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        {
            "q": { "batch": "empty", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": {}
        },
        {
            "q": { "batch": "null", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": null
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@)
    '{ "batch": { "$in": [ "empty", "null" ] } }'
ORDER BY object_id;
ROLLBACK;

-- Ordered mixed batches do not leak an explicit override into a later operation.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "ordered": true, "updates": [
        {
            "q": { "batch": "mixed_override", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "simple" }
        },
        {
            "q": { "batch": "mixed_inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@)
    '{ "batch": { "$in": [ "mixed_inherit", "mixed_override" ] } }'
ORDER BY object_id;
ROLLBACK;

-- Unordered mixed batches resolve each operation independently with inheritance first.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "ordered": false, "updates": [
        {
            "q": { "batch": "mixed_inherit", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        },
        {
            "q": { "batch": "mixed_override", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "collation": { "locale": "simple" }
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@)
    '{ "batch": { "$in": [ "mixed_inherit", "mixed_override" ] } }'
ORDER BY object_id;
ROLLBACK;

-- Retryable updateOne uses the same inherited effective collation.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        { "q": { "_id": 11, "value": "CAFE" }, "u": { "$inc": { "hits": 1 } } }
    ] }',
    NULL,
    'default-collation-update-retry');
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        { "q": { "_id": 11, "value": "CAFE" }, "u": { "$inc": { "hits": 1 } } }
    ] }',
    NULL,
    'default-collation-update-retry');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "_id": 11 }';
ROLLBACK;

SELECT documentdb_api.create_collection(
    'collation_write_db', 'update_no_default');
SELECT documentdb_api.insert_one(
    'collation_write_db',
    'update_no_default',
    '{ "_id": 1, "value": "café" }');

-- A collection without a default retains binary comparison semantics.
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_no_default", "updates": [
        {
            "q": { "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_no_default')
ORDER BY object_id;
ROLLBACK;

-- A missing collection is unaffected by inheritance.
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_missing", "updates": [
        {
            "q": { "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');

-- A malformed request against a missing collection keeps reporting the
-- request validation error rather than the missing collection.
SELECT document FROM bson_aggregation_update(
    'collation_write_db',
    '{ "update": "update_missing", "updates": [
        {
            "q": { "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true,
            "sort": { "value": 1 }
        }
    ] }');
SELECT document FROM bson_aggregation_delete(
    'collation_write_db',
    '{ "delete": "delete_missing", "deletes": [
        {
            "q": { "value": "CAFE" },
            "limit": 5
        }
    ] }');

-- A well-formed request against a missing collection still reports it.
SELECT document FROM bson_aggregation_update(
    'collation_write_db',
    '{ "update": "update_missing", "updates": [
        {
            "q": { "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM bson_aggregation_delete(
    'collation_write_db',
    '{ "delete": "delete_missing", "deletes": [
        {
            "q": { "value": "CAFE" },
            "limit": 0
        }
    ] }');

SELECT documentdb_api.create_collection(
    'collation_write_db', 'update_indexed');
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "en", "strength": 1 } }'::documentdb_core.bson
WHERE database_name = 'collation_write_db'
  AND collection_name = 'update_indexed';
SELECT documentdb_api.insert(
    'collation_write_db',
    '{
        "insert": "update_indexed",
        "documents": [
            { "_id": 1, "value": "café" },
            { "_id": 2, "value": "tea" }
        ]
    }');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'collation_write_db',
    '{
        "createIndexes": "update_indexed",
        "indexes": [
            {
                "key": { "value": 1 },
                "name": "update_value_en_s1",
                "collation": { "locale": "en", "strength": 1 }
            }
        ]
    }',
    true);

-- A matching collation index remains eligible under an inherited default.
SET enable_seqscan TO off;
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_indexed", "updates": [
        {
            "q": { "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
-- The generated plan uses the matching collation index.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM documentdb_api_catalog.bson_aggregation_update(
    'collation_write_db',
    '{ "update": "update_indexed", "updates": [
        {
            "q": { "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }')
$cmd$);
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_indexed')
ORDER BY object_id;
ROLLBACK;
RESET enable_seqscan;

-- Disabling collation prevents collection-default inheritance.
SET documentdb_core.enableCollation TO off;
BEGIN;
SELECT documentdb_api.update(
    'collation_write_db',
    '{ "update": "update_defaults", "updates": [
        {
            "q": { "batch": "single", "value": "CAFE" },
            "u": { "$set": { "hit": true } },
            "multi": true
        }
    ] }');
SELECT document FROM documentdb_api.collection(
    'collation_write_db', 'update_defaults')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{ "batch": "single" }'
ORDER BY object_id;
ROLLBACK;
SET documentdb_core.enableCollation TO on;

-- findAndModify: an omitted collation inherits the collection default.
BEGIN;
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_defaults", "query": { "batch": "single", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true }');
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_defaults", "query": { "batch": "multi", "value": "CAFE" },
       "sort": { "_id": 1 }, "remove": true }');
ROLLBACK;

-- findAndModify: empty and null collations inherit the collection default.
BEGIN;
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_defaults", "query": { "batch": "empty", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true, "collation": {} }');
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_defaults", "query": { "batch": "null", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true, "collation": null }');
ROLLBACK;

-- findAndModify: an explicit collation overrides the default; simple stays binary.
BEGIN;
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_defaults", "query": { "batch": "override", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true,
       "collation": { "locale": "en", "strength": 2 } }');
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_defaults", "query": { "batch": "simple", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true,
       "collation": { "locale": "simple" } }');
ROLLBACK;

-- findAndModify: no default, missing collection, and disabled support are unaffected.
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_no_default", "query": { "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true }');
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_missing", "query": { "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true }');
SET documentdb_core.enableCollation TO off;
SELECT documentdb_api.find_and_modify('collation_write_db',
    '{ "findAndModify": "update_defaults", "query": { "batch": "single", "value": "CAFE" },
       "update": { "$set": { "hit": true } }, "new": true }');
SET documentdb_core.enableCollation TO on;

SELECT documentdb_api.drop_collection(
    'collation_write_db', 'update_defaults');
SELECT documentdb_api.drop_collection(
    'collation_write_db', 'update_no_default');
SELECT documentdb_api.drop_collection(
    'collation_write_db', 'update_indexed');

RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;
RESET search_path;
