SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 1972000;
SET documentdb.next_collection_id TO 19720;
SET documentdb.next_collection_index_id TO 19720;

SET documentdb_api.forceUseIndexIfAvailable to on;

SET documentdb.enableCollationWithIndexes TO off;
ALTER SYSTEM SET documentdb_core.enablecollation='on';
SELECT pg_reload_conf();

-- ======== SECTION 1: Partial Filter Expression Composite Index Tests (unsharded) ========

SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 1, "a": "Cat" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 2, "a": "cat" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 3, "a": "Dog" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 4, "a": "dog" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 5, "a": { "b" : "cAt"} }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 6, "a": ["Cat", "cat", "dog"] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 7, "a": [{ "b": "CAT"}] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 9, "a": "Dog", "b": "Chien" }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 10, "a": "cat", "b": ["Chien", "Chat"] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 11, "a": "dog", "c": "kraman"  }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 12, "a": "cat", "c":{ "d": "Okra" } }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 13, "a": "cat", "c":[ "Okra", "Kraman", "okra" ] }');
SELECT documentdb_api.insert_one('db', 'coll_pfe_cmp_1', '{ "_id": 14, "a": "cat", "b": {"c": "chat"} }');

-- partial indexes with collation - composite term enabled
-- partialFilterExpression is collation-sensitive
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_pfe_cmp_1",
     "indexes": [
       {
         "key": {"a": -1}, "name": "index_pfe_cmp_a_partial",
         "partialFilterExpression": { "a": { "$lte": "cat" } },
         "collation" : {"locale" : "en", "strength" : 1 },
         "enableCompositeTerm": true
       },
      {
          "key": {"c": 1}, "name": "index_pfe_cmp_c_partial",
          "partialFilterExpression": { "c": { "$eq": "DOG" } },
          "collation" : {"locale" : "en", "strength" : 3 },
          "enableCompositeTerm": true
      }
     ]
   }',
   TRUE
);

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $eq for value outside partial filter
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match with $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
-- $match with $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

-- ======== SECTION 2: Partial Filter Expression Composite Index Tests (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_pfe_cmp_1', '{ "_id": "hashed" }', false);

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $eq for value outside partial filter
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_pfe_cmp_1", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match with $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
-- $match with $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_pfe_cmp_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_cmp_1",
     "filter": { "a": { "$ne": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_pfe_cmp_1",
     "deletes": [
       { "q": { "_id": 1, "a": { "$ne": "rabbit" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_cmp_1",
     "filter": { "a": { "$ne": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_cmp_1",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "Dog"] } }, { "a": { "$lt": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_pfe_cmp_1",
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
  '{ "find": "coll_pfe_cmp_1",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "Dog"] } }, { "a": { "$lt": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_cmp_1",
     "filter": { "a": { "$eq": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_pfe_cmp_1",
     "deletes": [
       { "q": { "a": { "$eq": "cat" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_pfe_cmp_1",
     "filter": { "a": { "$eq": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Cleanup pfe collection
SELECT documentdb_api.drop_collection('db', 'coll_pfe_cmp_1');

-- ======== SECTION 3: Unique Composite Index with Collation Tests (unsharded) ========

-- Section: Basic unique composite index with collation (unsharded)
SELECT documentdb_api.create_collection('db', 'coll_unique_cmp');

-- Create unique composite index with collation (case-insensitive)
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_cmp",
     "indexes": [
       { "key": {"username": 1}, "name": "unique_username_cmp_ci",
         "unique": true,
         "enableCompositeTerm": true,
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Insert initial documents
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 1, "username": "Microsoft"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 2, "username": "Google"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 3, "username": "Amazon"}');

-- Insert with different case should fail (case-insensitive uniqueness)
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 4, "username": "microsoft"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 5, "username": "MICROSOFT"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 6, "username": "MiCrOsOfT"}');

-- Insert with different value should succeed
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 7, "username": "Oracle"}');

-- Query with collation should use index
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_cmp",
     "filter": { "username": "microsoft" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_cmp",
     "filter": { "username": "microsoft" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Query without collation should not match case-insensitively
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_cmp",
     "filter": { "username": "microsoft" },
     "sort": { "_id": 1 }
   }');
ROLLBACK;

-- Section: Unique sparse composite index with collation
SELECT documentdb_api.create_collection('db', 'coll_unique_sparse_cmp');

-- Create unique sparse composite index with collation
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_sparse_cmp",
     "indexes": [
       { "key": {"email": 1}, "name": "unique_email_sparse_cmp_ci",
         "unique": true,
         "sparse": true,
         "enableCompositeTerm": true,
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Insert documents with and without email
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_cmp', '{"_id": 1, "email": "Support@CloudProvider.com"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_cmp', '{"_id": 2, "name": "No Email User 1"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_cmp', '{"_id": 3, "name": "No Email User 2"}');

-- Insert with different case should fail
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_cmp', '{"_id": 4, "email": "support@cloudprovider.com"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_cmp', '{"_id": 5, "email": "SUPPORT@CLOUDPROVIDER.COM"}');

-- Insert without email should succeed (sparse allows missing field)
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_cmp', '{"_id": 6, "name": "No Email User 3"}');

-- Insert with null email should succeed (sparse)
SELECT documentdb_api.insert_one('db', 'coll_unique_sparse_cmp', '{"_id": 7, "email": null}');

-- Query sparse index with collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_sparse_cmp",
     "filter": { "email": "support@cloudprovider.com" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_sparse_cmp",
     "filter": { "email": "support@cloudprovider.com" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Section: Unique multi-key composite index with collation
SELECT documentdb_api.create_collection('db', 'coll_unique_multikey_cmp');

-- Create unique composite index on multiple fields with collation
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_multikey_cmp",
     "indexes": [
       { "key": {"firstName": 1, "lastName": 1}, "name": "unique_name_cmp_ci",
         "unique": true,
         "enableCompositeTerm": true,
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }', TRUE);

-- Insert initial documents
SELECT documentdb_api.insert_one('db', 'coll_unique_multikey_cmp', '{"_id": 1, "firstName": "Azure", "lastName": "Cloud"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_multikey_cmp', '{"_id": 2, "firstName": "AWS", "lastName": "Cloud"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_multikey_cmp', '{"_id": 3, "firstName": "Azure", "lastName": "Storage"}');

-- Insert with same combo different case should fail
SELECT documentdb_api.insert_one('db', 'coll_unique_multikey_cmp', '{"_id": 4, "firstName": "azure", "lastName": "cloud"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_multikey_cmp', '{"_id": 5, "firstName": "AZURE", "lastName": "CLOUD"}');

-- Insert with different combo should succeed
SELECT documentdb_api.insert_one('db', 'coll_unique_multikey_cmp', '{"_id": 6, "firstName": "Azure", "lastName": "Functions"}');

-- Query multi-key unique index with collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_multikey_cmp",
     "filter": { "firstName": "azure", "lastName": "cloud" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_multikey_cmp",
     "filter": { "firstName": "azure", "lastName": "cloud" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- ======== SECTION 4: Unique Composite Index with Collation Tests (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_unique_cmp', '{ "_id": "hashed" }', false);

-- Insert with different case should still fail (sharded)
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 10, "username": "google"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 11, "username": "GOOGLE"}');

-- Insert with new value should succeed (sharded)
SELECT documentdb_api.insert_one('db', 'coll_unique_cmp', '{"_id": 12, "username": "Alibaba"}');

-- Query on sharded collection with collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_cmp",
     "filter": { "username": "google" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_cmp",
     "filter": { "username": "google" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- Range query on sharded unique index with collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_cmp",
     "filter": { "username": { "$gte": "a", "$lte": "d" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_cmp",
     "filter": { "username": { "$gte": "a", "$lte": "d" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_unique_cmp" }');

-- ======== SECTION 5: Unique Composite Index with Numeric Ordering Collation ========

SELECT documentdb_api.create_collection('db', 'coll_unique_numeric_cmp');

-- Create unique composite index with numeric ordering
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_numeric_cmp",
     "indexes": [
       { "key": {"code": 1}, "name": "unique_code_numeric_cmp",
         "unique": true,
         "enableCompositeTerm": true,
         "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
       }
     ]
   }', TRUE);

-- Insert documents with numeric strings
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric_cmp', '{"_id": 1, "code": "1"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric_cmp', '{"_id": 2, "code": "2"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric_cmp', '{"_id": 3, "code": "10"}');

-- Duplicate numeric string should fail
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric_cmp', '{"_id": 4, "code": "1"}');

-- "01" with numeric ordering should be considered equal to "1"
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric_cmp', '{"_id": 5, "code": "01"}');

-- Different numeric string should succeed
SELECT documentdb_api.insert_one('db', 'coll_unique_numeric_cmp', '{"_id": 6, "code": "100"}');

-- Query with numeric ordering collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_numeric_cmp",
     "filter": { "code": "1" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_numeric_cmp",
     "filter": { "code": "1" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1, "numericOrdering": true }
   }');
ROLLBACK;

-- ======== SECTION 6: Unique Composite Index with Different Collation Strengths ========

SELECT documentdb_api.create_collection('db', 'coll_unique_strength_cmp');

-- Create unique composite index with strength 2 (case-insensitive, but accent-sensitive)
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
  '{ "createIndexes": "coll_unique_strength_cmp",
     "indexes": [
       { "key": {"name": 1}, "name": "unique_name_strength2_cmp",
         "unique": true,
         "enableCompositeTerm": true,
         "collation": { "locale": "en", "strength": 2 }
       }
     ]
   }', TRUE);

-- Insert initial document
SELECT documentdb_api.insert_one('db', 'coll_unique_strength_cmp', '{"_id": 1, "name": "cafe"}');

-- Different case should fail (strength 2 is case-insensitive)
SELECT documentdb_api.insert_one('db', 'coll_unique_strength_cmp', '{"_id": 2, "name": "CAFE"}');
SELECT documentdb_api.insert_one('db', 'coll_unique_strength_cmp', '{"_id": 3, "name": "Cafe"}');

-- Different accent should succeed (strength 2 is accent-sensitive)
SELECT documentdb_api.insert_one('db', 'coll_unique_strength_cmp', '{"_id": 4, "name": "café"}');

-- Query with strength 2 collation
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_strength_cmp",
     "filter": { "name": "CAFE" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 2 }
   }');

EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_unique_strength_cmp",
     "filter": { "name": "CAFE" },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 2 }
   }');
ROLLBACK;

-- Cleanup unique composite index test collections
SELECT documentdb_api.drop_collection('db', 'coll_unique_cmp');
SELECT documentdb_api.drop_collection('db', 'coll_unique_sparse_cmp');
SELECT documentdb_api.drop_collection('db', 'coll_unique_multikey_cmp');
SELECT documentdb_api.drop_collection('db', 'coll_unique_numeric_cmp');
SELECT documentdb_api.drop_collection('db', 'coll_unique_strength_cmp');

RESET documentdb_api.forceUseIndexIfAvailable;

RESET documentdb.enableCollationWithIndexes;
ALTER SYSTEM SET documentdb_core.enablecollation='off';
SELECT pg_reload_conf();
