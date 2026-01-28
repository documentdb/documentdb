SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 972000;
SET documentdb.next_collection_id TO 9720;
SET documentdb.next_collection_index_id TO 9720;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithIndexes TO off;
SET documentdb_api.forceUseIndexIfAvailable to on;

ALTER SYSTEM SET documentdb_core.enablecollation='on';
SELECT pg_reload_conf();

-- ======== SECTION 1: Partial Filter Expression Index Tests (unsharded) ========

SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 1, "a": "Cat" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 2, "a": "cat" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 3, "a": "Dog" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 4, "a": "dog" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 5, "a": { "b" : "cAt"} }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 6, "a": ["Cat", "cat", "dog"] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 7, "a": [{ "b": "CAT"}] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 9, "a": "Dog", "b": "Chien" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 10, "a": "cat", "b": ["Chien", "Chat"] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 11, "a": "dog", "c": "kraman"  }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 12, "a": "cat", "c":{ "d": "Okra" } }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 13, "a": "cat", "c":[ "Okra", "Kraman", "okra" ] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_1', '{ "_id": 14, "a": "cat", "b": {"c": "chat"} }');

-- partial indexes with collation
-- partialFilterExpression is collation-sensitive
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_pfe_1",
     "indexes": [
       {
         "key": {"a": -1}, "name": "index_pfe_a_partial",
         "partialFilterExpression": { "a": { "$lte": "cat" } },
         "collation" : {"locale" : "en", "strength" : 1 }
       },
      {
          "key": {"c.$**": 1}, "name": "index_pfe_c_wildcard_partial",
          "partialFilterExpression": { "c": { "$eq": "DOG" } },
          "collation" : {"locale" : "en", "strength" : 3 }
      }
     ]
   }',
   TRUE
);

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $eq for value outside partial filter
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match with $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
-- $match with $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

-- ======== SECTION 2: Partial Filter Expression Index Tests (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_pfe_1', '{ "_id": "hashed" }', false);

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $eq for value outside partial filter
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match with $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
-- $match with $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_1",
     "filter": { "a": { "$ne": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_pfe_1",
     "deletes": [
       { "q": { "_id": 1, "a": { "$ne": "rabbit" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_1",
     "filter": { "a": { "$ne": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_1",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "Dog"] } }, { "a": { "$lt": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_pfe_1",
     "deletes": [
       { "q": { "a": { "$in": ["CAT", "Dog"] } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "a": { "$lt": "RABBIT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_1",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "Dog"] } }, { "a": { "$lt": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_1",
     "filter": { "a": { "$eq": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_pfe_1",
     "deletes": [
       { "q": { "a": { "$eq": "cat" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_1",
     "filter": { "a": { "$eq": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Cleanup pfe collection
SELECT documentdb_api.drop_collection('db', 'coll_pfe_1');

-- ======== SECTION 3: Unique Index with Collation Tests (unsharded) ========

-- Section: Basic unique index with collation (unsharded)
SELECT documentdb_api.create_collection('db', 'coll_unique_collation');

-- Create unique index with collation (case-insensitive)
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_collation",
     "indexes": [
       { "key": {"username": 1}, "name": "unique_username_ci",
         "unique": true,
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Insert initial documents
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 1, "username": "Alice"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 2, "username": "Bob"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 3, "username": "Charlie"}');

-- Insert with different case should fail (case-insensitive uniqueness)
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 4, "username": "alice"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 5, "username": "ALICE"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 6, "username": "AlIcE"}');

-- Insert with different value should succeed
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 7, "username": "David"}');

-- Query with collation should use index
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_collation",
     "filter": { "username": "alice" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_collation",
     "filter": { "username": "alice" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Query without collation should not match case-insensitively
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_collation",
     "filter": { "username": "alice" },
     "sort": { "_id": 1 }
   }');
ROLLBACK;

-- Section: Unique sparse index with collation
SELECT documentdb_api.create_collection('db', 'coll_unique_sparse_collation');

-- Create unique sparse index with collation
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_sparse_collation",
     "indexes": [
       { "key": {"email": 1}, "name": "unique_email_sparse_ci",
         "unique": true,
         "sparse": true,
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Insert documents with and without email
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_collation', '{"_id": 1, "email": "Test@Example.com"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_collation', '{"_id": 2, "name": "No Email User 1"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_collation', '{"_id": 3, "name": "No Email User 2"}');

-- Insert with different case should fail
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_collation', '{"_id": 4, "email": "test@example.com"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_collation', '{"_id": 5, "email": "TEST@EXAMPLE.COM"}');

-- Insert without email should succeed (sparse allows missing field)
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_collation', '{"_id": 6, "name": "No Email User 3"}');

-- Insert with null email should succeed (sparse)
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_collation', '{"_id": 7, "email": null}');

-- Query sparse index with collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_sparse_collation",
     "filter": { "email": "test@example.com" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_sparse_collation",
     "filter": { "email": "test@example.com" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- ======== SECTION 4: Unique Index with Collation Tests (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_unique_collation', '{ "_id": "hashed" }', false);

-- Insert with different case should still fail (sharded)
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 10, "username": "bob"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 11, "username": "BOB"}');

-- Insert with new value should succeed (sharded)
SELECT documentdb_api.insert_one('db', 'coll_unique_collation', '{"_id": 12, "username": "Eve"}');

-- Query on sharded collection with collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_collation",
     "filter": { "username": "bob" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_collation",
     "filter": { "username": "bob" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Range query on sharded unique index with collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_collation",
     "filter": { "username": { "$gte": "a", "$lte": "d" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_collation",
     "filter": { "username": { "$gte": "a", "$lte": "d" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_unique_collation" }');

-- ======== SECTION 5: Unique Index with Numeric Ordering Collation ========

SELECT documentdb_api.create_collection('db', 'coll_unique_numeric');

-- Create unique index with numeric ordering
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_numeric",
     "indexes": [
       { "key": {"code": 1}, "name": "unique_code_numeric",
         "unique": true,
         "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
       }
     ]
   }', TRUE);

-- Insert documents with numeric strings
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric', '{"_id": 1, "code": "1"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric', '{"_id": 2, "code": "2"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric', '{"_id": 3, "code": "10"}');

-- Duplicate numeric string should fail
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric', '{"_id": 4, "code": "1"}');

-- "01" with numeric ordering should be considered equal to "1"
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric', '{"_id": 5, "code": "01"}');

-- Different numeric string should succeed
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric', '{"_id": 6, "code": "100"}');

-- Query with numeric ordering collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_numeric",
     "filter": { "code": "1" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_numeric",
     "filter": { "code": "1" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');
ROLLBACK;

-- ======== SECTION 6: Unique Index with Different Collation Strengths ========

SELECT documentdb_api.create_collection('db', 'coll_unique_strength');

-- Create unique index with strength 2 (case-insensitive, but accent-sensitive)
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_strength",
     "indexes": [
       { "key": {"name": 1}, "name": "unique_name_strength2",
         "unique": true,
         "collation": { "locale": "en", "strength": 2 }
       }
     ]
   }', TRUE);

-- Insert initial document
SELECT documentdb_api.insert_one('db', 'coll_unique_strength', '{"_id": 1, "name": "cafe"}');

-- Different case should fail (strength 2 is case-insensitive)
SELECT documentdb_api.insert_one('db', 'coll_unique_strength', '{"_id": 2, "name": "CAFE"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_strength', '{"_id": 3, "name": "Cafe"}');

-- Different accent should succeed (strength 2 is accent-sensitive)
SELECT documentdb_api.insert_one('db', 'coll_unique_strength', '{"_id": 4, "name": "café"}');

-- Query with strength 2 collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_strength",
     "filter": { "name": "CAFE" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 2 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_strength",
     "filter": { "name": "CAFE" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 2 }
   }');
ROLLBACK;

-- Cleanup unique index test collections
SELECT documentdb_api.drop_collection('db', 'coll_unique_collation');
SELECT documentdb_api.drop_collection('db', 'coll_unique_sparse_collation');
SELECT documentdb_api.drop_collection('db', 'coll_unique_numeric');
SELECT documentdb_api.drop_collection('db', 'coll_unique_strength');

RESET documentdb_api.forceUseIndexIfAvailable;

RESET documentdb.enableCollationWithIndexes;
ALTER SYSTEM SET documentdb_core.enablecollation='off';
SELECT pg_reload_conf();
