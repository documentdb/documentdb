SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET citus.next_shard_id TO 1890000;
SET documentdb.next_collection_id TO 189000;
SET documentdb.next_collection_index_id TO 189000;

SET documentdb.forceUseIndexIfAvailable TO on;

SET documentdb.enableCollationWithIndexes TO off;
ALTER SYSTEM SET documentdb_core.enablecollation='on';
SELECT pg_reload_conf();

-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

-- ======== SECTION 1: Single-path index tests on coll_sort_1 ========

-- Section 1a: Unsharded tests
SELECT documentdb_api.create_collection('db', 'coll_sort_1');


SELECT documentdb_api.insert_one('db', 'coll_sort_1', '{"_id": 1, "a": "apple", "b": "dog", "c": "zebra", "nested": {"x": "hello", "y": "world"}}');
SELECT documentdb_api.insert_one('db', 'coll_sort_1', '{"_id": 2, "a": "APPLE", "b": "DOG", "c": "ZEBRA", "tags": ["red", "GREEN", "Blue"]}');
SELECT documentdb_api.insert_one('db', 'coll_sort_1', '{"_id": 3, "a": "Apple", "b": "Dog", "c": "Zebra", "nested": {"deep": {"value": "test"}}}');
SELECT documentdb_api.insert_one('db', 'coll_sort_1', '{"_id": 4, "a": "cat", "b": "rabbit", "c": "bird", "items": [{"name": "first"}, {"name": "SECOND"}]}');
SELECT documentdb_api.insert_one('db', 'coll_sort_1', '{"_id": 5, "a": "CAT", "b": "RABBIT", "c": "BIRD"}');
SELECT documentdb_api.insert_one('db', 'coll_sort_1', '{"_id": 6, "a": "Cat", "b": "Rabbit", "c": "Bird", "meta": {"label": "Mixed Case"}}');

-- Create index with collation
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_sort_1",
     "indexes": [
       { "key": {"a": 1}, "name": "index_1_a",
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Sort ascending
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$gte": "APPLE" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$gte": "APPLE" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Sort descending
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$lte": "DOG" } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$lte": "DOG" } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Aggregation with $match and $sort ascending
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "coll_sort_1",
     "pipeline": [
       { "$match": { "a": { "$gt": "apple" } } },
       { "$sort": { "a": 1 } }
     ],
     "collation": { "locale": "en", "strength": 1 },
     "cursor": {}
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "coll_sort_1",
     "pipeline": [
       { "$match": { "a": { "$gt": "apple" } } },
       { "$sort": { "a": 1 } }
     ],
     "collation": { "locale": "en", "strength": 1 },
     "cursor": {}
   }');
ROLLBACK;

-- Aggregation with $match and $sort descending
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "coll_sort_1",
     "pipeline": [
       { "$match": { "a": { "$ne": "rabbit" } } },
       { "$sort": { "a": -1 } }
     ],
     "collation": { "locale": "en", "strength": 1 },
     "cursor": {}
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "coll_sort_1",
     "pipeline": [
       { "$match": { "a": { "$ne": "rabbit" } } },
       { "$sort": { "a": -1 } }
     ],
     "collation": { "locale": "en", "strength": 1 },
     "cursor": {}
   }');
ROLLBACK;

-- Section 1b: Sharded tests
SELECT documentdb_api.shard_collection('db', 'coll_sort_1', '{ "_id": "hashed" }', false);

-- Sort ascending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$gte": "APPLE" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$gte": "APPLE" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Sort descending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$lte": "DOG" } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_1",
     "filter": { "a": { "$lte": "DOG" } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Aggregation with $match and $sort (sharded)
BEGIN;
SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "coll_sort_1",
     "pipeline": [
       { "$match": { "a": { "$gt": "apple" } } },
       { "$sort": { "a": 1 } }
     ],
     "collation": { "locale": "en", "strength": 1 },
     "cursor": {}
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db',
  '{ "aggregate": "coll_sort_1",
     "pipeline": [
       { "$match": { "a": { "$gt": "apple" } } },
       { "$sort": { "a": 1 } }
     ],
     "collation": { "locale": "en", "strength": 1 },
     "cursor": {}
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_sort_1" }');

-- ======== SECTION 2: Single-path index tests on coll_sort_2 ========

-- Section 2a: Unsharded tests
SELECT documentdb_api.create_collection('db', 'coll_sort_2');


SELECT documentdb_api.insert_one('db', 'coll_sort_2', '{"_id": 1, "a": "dog", "b": "cat", "c": "rabbit", "info": {"breed": "labrador", "color": "GOLDEN"}}');
SELECT documentdb_api.insert_one('db', 'coll_sort_2', '{"_id": 2, "a": "DOG", "b": "CAT", "c": "RABBIT", "colors": ["black", "WHITE", "Brown"]}');
SELECT documentdb_api.insert_one('db', 'coll_sort_2', '{"_id": 3, "a": "Dog", "b": "Cat", "c": "Rabbit"}');
SELECT documentdb_api.insert_one('db', 'coll_sort_2', '{"_id": 4, "a": "cat", "b": "dog", "c": "zebra", "details": {"sub": {"name": "whiskers"}}}');
SELECT documentdb_api.insert_one('db', 'coll_sort_2', '{"_id": 5, "a": "CAT", "b": "DOG", "c": "ZEBRA", "arr": [{"k": "val1"}, {"k": "VAL2"}]}');
SELECT documentdb_api.insert_one('db', 'coll_sort_2', '{"_id": 6, "a": "Cat", "b": "Dog", "c": "Zebra"}');

-- Create index
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_sort_2",
     "indexes": [
       { "key": {"a": 1}, "name": "index_2_a",
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Sort ascending with range filter
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$gte": "cat" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$gte": "cat" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Sort descending with $in filter
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$in": ["CAT", "dog"] } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$in": ["CAT", "dog"] } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Section 2b: Sharded tests
SELECT documentdb_api.shard_collection('db', 'coll_sort_2', '{ "_id": "hashed" }', false);

-- Sort ascending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$gte": "cat" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$gte": "cat" } },
     "sort": { "a": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Sort descending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$in": ["CAT", "dog"] } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_2",
     "filter": { "a": { "$in": ["CAT", "dog"] } },
     "sort": { "a": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_sort_2" }');

-- ======== SECTION 3: Truncation with Collation and Ordering ========

-- Section 3a: Unsharded tests
SELECT documentdb_api.create_collection('db', 'coll_sort_trunc');

-- Create index with truncation
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_sort_trunc",
     "indexes": [
       { "key": {"longField": 1}, "name": "index_trunc_long",
         "enableLargeIndexKeys": true,
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Insert documents with long strings
SELECT documentdb_api.insert_one('db', 'coll_sort_trunc', FORMAT('{ "_id": 10, "longField": "%s" }', 'abcde' || repeat('z', 3000) || '2')::bson);
SELECT documentdb_api.insert_one('db', 'coll_sort_trunc', FORMAT('{ "_id": 11, "longField": "%s" }', 'abcde' || repeat('z', 3000) || '1')::bson);
SELECT documentdb_api.insert_one('db', 'coll_sort_trunc', FORMAT('{ "_id": 9, "longField": "%s" }', 'abcde' || repeat('z', 3000) || '3')::bson);
SELECT documentdb_api.insert_one('db', 'coll_sort_trunc', FORMAT('{ "_id": 12, "longField": "%s" }', 'ABCDE' || repeat('z', 3000) || '1')::bson);

-- Sort ascending with truncated fields
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$regex": "^abc" } },
     "sort": { "longField": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$regex": "^abc" } },
     "sort": { "longField": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Sort descending with truncated fields
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$exists": true } },
     "sort": { "longField": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$exists": true } },
     "sort": { "longField": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Section 3b: Sharded tests
SELECT documentdb_api.shard_collection('db', 'coll_sort_trunc', '{ "_id": "hashed" }', false);

-- Sort ascending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$regex": "^abc" } },
     "sort": { "longField": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$regex": "^abc" } },
     "sort": { "longField": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Sort descending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$exists": true } },
     "sort": { "longField": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_trunc",
     "projection": { "_id": 1 },
     "filter": { "longField": { "$exists": true } },
     "sort": { "longField": -1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_sort_trunc" }');

-- ======== SECTION 4: Numeric Ordering with Index ========

-- Section 4a: Unsharded tests
SELECT documentdb_api.create_collection('db', 'coll_sort_numeric');

SELECT documentdb_api.insert_one('db', 'coll_sort_numeric', '{ "_id": 1, "code": "2" }');
SELECT documentdb_api.insert_one('db', 'coll_sort_numeric', '{ "_id": 2, "code": "10" }');
SELECT documentdb_api.insert_one('db', 'coll_sort_numeric', '{ "_id": 3, "code": "100" }');
SELECT documentdb_api.insert_one('db', 'coll_sort_numeric', '{ "_id": 4, "code": "3" }');
SELECT documentdb_api.insert_one('db', 'coll_sort_numeric', '{ "_id": 5, "code": "20" }');

-- Create index with numeric ordering
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_sort_numeric",
     "indexes": [
       { "key": {"code": 1}, "name": "code_numeric",
         "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
       }
     ]
   }', TRUE);

-- Sort ascending with numeric ordering
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": { "code": { "$gte": "2" } },
     "sort": { "code": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": { "code": { "$gte": "2" } },
     "sort": { "code": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');
ROLLBACK;

-- Sort descending with numeric ordering
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": {},
     "sort": { "code": -1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": {},
     "sort": { "code": -1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');
ROLLBACK;

-- Section 4b: Sharded tests
SELECT documentdb_api.shard_collection('db', 'coll_sort_numeric', '{ "_id": "hashed" }', false);

-- Sort ascending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": { "code": { "$gte": "2" } },
     "sort": { "code": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": { "code": { "$gte": "2" } },
     "sort": { "code": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');
ROLLBACK;

-- Sort descending (sharded)
BEGIN;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": {},
     "sort": { "code": -1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_sort_numeric",
     "filter": {},
     "sort": { "code": -1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_sort_numeric" }');

-- Cleanup
SELECT documentdb_api.drop_collection('db', 'coll_sort_1');
SELECT documentdb_api.drop_collection('db', 'coll_sort_2');
SELECT documentdb_api.drop_collection('db', 'coll_sort_trunc');
SELECT documentdb_api.drop_collection('db', 'coll_sort_numeric');

RESET documentdb.enableCollationWithIndexes;
RESET documentdb.forceUseIndexIfAvailable;

ALTER SYSTEM SET documentdb_core.enablecollation='off';
SELECT pg_reload_conf();