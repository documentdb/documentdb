SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 970000;
SET documentdb.next_collection_id TO 9700;
SET documentdb.next_collection_index_id TO 9700;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithIndexes TO off;
SET documentdb_api.forceUseIndexIfAvailable to on;

ALTER SYSTEM SET documentdb_core.enablecollation='on';
SELECT pg_reload_conf();

-- ======== SECTION 0: Unsupported index types with collation ========

-- text indexes: unsupported with collation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_0",
     "indexes": [
        {
         "key": {"a": "text"}, "name": "index_0_a_text",
         "collation" : {"locale" : "en", "strength" : 1}
        }
     ]
   }',
   TRUE
);

-- 2d indexes: unsupported with collation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_0",
     "indexes": [
        {
         "key": {"a": "2d"}, "name": "index_0_a_2d",
         "collation" : {"locale" : "en", "strength" : 1}
        }
     ]
   }',
   TRUE
);

-- hash indexes: unsupported with collation YET
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_0",
     "indexes": [
        {
         "key": {"a": "hashed"}, "name": "index_0_a_hashed",
         "collation" : {"locale" : "en", "strength" : 1}
        }
     ]
   }',
   TRUE
);

-- ======== SECTION 1: Single-path index tests on coll_index_1 ========

SELECT documentdb_api.insert_one('db','coll_index_1', '{"_id": 1, "a" : "DOG" }', NULL);
SELECT documentdb_api.insert_one('db','coll_index_1', '{"_id": 2, "a" : "dog" }', NULL);
SELECT documentdb_api.insert_one('db','coll_index_1', '{"_id": 3, "a" : "Cat" }', NULL);
SELECT documentdb_api.insert_one('db','coll_index_1', '{"_id": 4, "a" : "Dog" }', NULL);

-- single path indexes
-- non-concurrent index creation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_1",
     "indexes": [
       {
         "key": {"a": 1}, "name": "index_1_a",
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }',
   TRUE
);

-- no collation: index not used
-- find
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }');
ROLLBACK;

-- aggregate
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$addFields": { "x": "mANgO" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_1", "pipeline": [ { "$sort": { "_id": 1 } }, { "$addFields": { "x": "mANgO" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- different collation than index: index not used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- same collation as index : index used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_1",
     "filter": { "a": { "$gt": "Cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_1",
     "deletes": [
       { "q": { "_id": 1, "a": { "$gt": "Cat" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_1",
     "filter": { "a": { "$gt": "Cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_1",
     "filter": { "$or": [{ "a": { "$lt": "DOG" } }, { "a": { "$gte": "Dog" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_1",
     "deletes": [
       { "q": { "a": { "$lt": "DOG" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "a": { "$gte": "Dog" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_1",
     "filter": { "$or": [{ "a": { "$lt": "DOG" } }, { "a": { "$gte": "Dog" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- ======== SECTION 2: Single-path index tests on coll_index_2 (unsharded) ========

-- (1) insert some docs
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 1, "a": "Cat" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 2, "a": "cat" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 3, "a": "Dog" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 4, "a": "dog" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 5, "a": { "b" : "cAt"} }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 6, "a": ["Cat", "cat", "dog"] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 7, "a": [{ "b": "CAT"}] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 9, "a": "Dog", "b": "Chien" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 10, "a": "cat", "b": ["Chien", "Chat"] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 11, "a": "dog", "c": "kraman"  }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 12, "a": "cat", "c":{ "d": "Okra" } }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 13, "a": "cat", "c":[ "Okra", "Kraman", "okra" ] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2', '{ "_id": 14, "a": "cat", "b": {"c": "chat"} }');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_2",
     "indexes": [
       {
         "key": {"a": 1}, "name": "index_2_a",
         "collation" : {"locale" : "en", "strength" : 1}
       }
     ]
   }',
   TRUE
);

-- find: unsharded
BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $nin
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$nin" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $nin with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: basic test with two values (case-insensitive match)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: single value (equivalent to $eq for arrays)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: on scalar field should return empty when multiple distinct values required
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "_id": 1, "a": { "$all": ["CAT", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: three values with case variations - tests AND semantics are preserved
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: no matches (value not in any document)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["ELEPHANT", "LION"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $and on different field
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $elemMatch
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $elemMatch with range
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;


BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- aggregate: unsharded
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $unwind
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $addFields
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $sort after $match
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "a": { "$gte": "rabbit" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "a": { "$in": ["CAT", "dog"] } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "a": { "$lte": "RABBIT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- ======== SECTION 3: Single-path index tests on coll_index_2 (sharded) ========

-- shard the collection
SELECT documentdb_api.shard_collection('db', 'coll_index_2', '{ "_id": "hashed" }', false);

-- find: sharded
BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $nin
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$nin" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $nin with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: basic test with two values (case-insensitive match)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: single value (equivalent to $eq for arrays)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: on scalar field should return empty when multiple distinct values required
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "_id": 1, "a": { "$all": ["CAT", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: three values with case variations - tests AND semantics are preserved
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: no matches (value not in any document)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": ["ELEPHANT", "LION"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $and on different field
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;


BEGIN;
-- $elemMatch
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $elemMatch with range
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- aggregate: sharded
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $unwind
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $addFields
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $sort after $match
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "a": { "$gte": "rabbit" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "a": { "$in": ["CAT", "dog"] } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "a": { "$lte": "RABBIT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- unshard and drop indexes
SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_index_2" }');
CALL documentdb_api.drop_indexes('db', '{ "dropIndexes": "coll_index_2", "index": ["*"]}');

-- ======== SECTION 4: Wildcard indexes (unsharded) ========

-- wildcard indexes
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_2",
     "indexes": [
       {
         "key": {"c.$**": 1}, "name": "index_2_c_wildcard",
         "collation" : {"locale" : "en", "strength" : 1 }
       }
     ]
   }',
   TRUE
);

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK; 

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gt": "CAT" }, "a" : {"$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gt": "CAT" }, "a" : {"$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

-- wildcard indexes: aggregation pipeline
BEGIN;
-- $match with $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
-- $match with $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "c": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$lte": "Dog" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "c": { "$lte": "Dog" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$lte": "Dog" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "c": { "$nin": ["ZEBRA", "ELEPHANT"] } }, { "c": { "$lt": "rabbit" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "c": { "$nin": ["ZEBRA", "ELEPHANT"] } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "c": { "$lt": "rabbit" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "c": { "$nin": ["ZEBRA", "ELEPHANT"] } }, { "c": { "$lt": "rabbit" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- ======== SECTION 5: Wildcard indexes (sharded) ========

-- wildcard indexes: sharded collection
SELECT documentdb_api.shard_collection('db', 'coll_index_2', '{ "_id": "hashed" }', false);

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK; 

BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$eq": "dog" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gt": "CAT" }, "a" : {"$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gt": "CAT" }, "a" : {"$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

-- wildcard indexes: aggregation pipeline
BEGIN;
-- $match with $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
-- $match with $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "c": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$lte": "Dog" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "c": { "$lte": "Dog" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$lte": "Dog" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "c": { "$nin": ["ZEBRA", "ELEPHANT"] } }, { "c": { "$lt": "rabbit" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "c": { "$nin": ["ZEBRA", "ELEPHANT"] } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "c": { "$lt": "rabbit" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "c": { "$nin": ["ZEBRA", "ELEPHANT"] } }, { "c": { "$lt": "rabbit" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- unshard and drop indexes
SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_index_2" }');
CALL documentdb_api.drop_indexes('db', '{ "dropIndexes": "coll_index_2", "index": ["*"]}');

-- ======== SECTION 6: Multiple indexes (unsharded) ========

-- multiple indexes
-- index_2_a is case-sensitive, index_2_a_b is case-insensitive, index_2_wildcard is case-insensitive wildcard index
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_2",
     "indexes": [
        {
         "key": {"a": 1}, "name": "index_2_a",
         "collation" : {"locale" : "en", "strength" : 3}
        },
        {
        "key": {"a": 1, "b": -1}, "name": "index_2_a_b",
        "collation" : {"locale" : "en", "strength" : 1}
        },
        {
        "key": {"c.$**": 1}, "name": "index_2_wildcard",
        "collation" : {"locale" : "en", "strength" : 2}
        }
     ]
   }',
   TRUE
);

BEGIN;
-- index_2_a is used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
ROLLBACK;

BEGIN;
-- index_2_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_wildcard used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c.d": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c.d": { "$eq": "kraMAn" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
ROLLBACK;

BEGIN;
-- $match with $and and $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c.d": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c.d": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "KRAMAN" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
ROLLBACK;

-- ======== SECTION 7: Multiple indexes (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_index_2', '{ "_id": "hashed" }', false);

BEGIN;
-- index_2_a is used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
ROLLBACK;

BEGIN;
-- index_2_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_wildcard used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c.d": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c.d": { "$eq": "kraMAn" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
ROLLBACK;

BEGIN;
-- $match with $and and $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c.d": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c.d": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "KRAMAN" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$ne": "rabbit" }, "b": { "$in": ["Dog", "CAT"] } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "a": { "$ne": "rabbit" }, "b": { "$in": ["Dog", "CAT"] } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$ne": "rabbit" }, "b": { "$in": ["Dog", "CAT"] } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$gt": "Cat" }, "b": { "$lte": "DOG" } }, { "a": { "$lt": "DOG" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "a": { "$gt": "Cat" }, "b": { "$lte": "DOG" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "a": { "$lt": "DOG" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$gt": "Cat" }, "b": { "$lte": "DOG" } }, { "a": { "$lt": "DOG" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- unshard and drop indexes
SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_index_2" }');
CALL documentdb_api.drop_indexes('db', '{"dropIndexes": "coll_index_2", "index": ["*"]}');

-- ======== SECTION 10: Wildcard with projection - exclusion (unsharded) ========

-- wildcard with projection: exclusion
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_2",
     "indexes": [
       {
         "key": {"$**": 1}, "name": "index_2_wildcard_projection_exclusion",
         "wildcardProjection": { "a": 0 },
         "collation" : {"locale" : "en", "strength" : 1 }
       }
     ]
   }',
   TRUE
);

-- wildcard with projection exclusion: find
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- wildcard with projection exclusion: aggregation pipeline
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$ne": "zebra" }, "b": { "$gte": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "a": { "$ne": "zebra" }, "b": { "$gte": "cat" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "a": { "$ne": "zebra" }, "b": { "$gte": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$in": ["cat", "DOG"] } }, { "b": { "$gt": "CAT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "a": { "$in": ["cat", "DOG"] } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "b": { "$gt": "CAT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$in": ["cat", "DOG"] } }, { "b": { "$gt": "CAT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

CALL documentdb_api.drop_indexes('db', '{ "dropIndexes": "coll_index_2", "index": ["*"]}');

-- ======== SECTION 11: Wildcard with projection - exclusion (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_index_2', '{ "_id": "hashed" }', false);

-- wildcard with projection exclusion: find
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- wildcard with projection exclusion: aggregation pipeline
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$eq": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "c": { "$eq": "cat" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$eq": "cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "c": { "$gte": "dog" } }, { "b": { "$lte": "CAT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "c": { "$gte": "dog" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "b": { "$lte": "CAT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "c": { "$gte": "dog" } }, { "b": { "$lte": "CAT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$lt": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "c": { "$lt": "rabbit" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$lt": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$gte": "CAT" } }, { "b": { "$in": ["dog", "CHAT"] } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "a": { "$gte": "CAT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "b": { "$in": ["dog", "CHAT"] } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$gte": "CAT" } }, { "b": { "$in": ["dog", "CHAT"] } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_index_2" }');
CALL documentdb_api.drop_indexes('db', '{ "dropIndexes": "coll_index_2", "index": ["*"]}');

-- ======== SECTION 12: Wildcard with projection - inclusion (unsharded) ========

-- wildcardProjection: inclusion
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_2",
     "indexes": [
       {
         "key": {"$**": 1}, "name": "index_2_wildcard_projection_inclusion",
         "wildcardProjection": { "b": 1, "c": 1 },
         "collation" : {"locale" : "en", "strength" : 1 }
       }
     ]
   }',
   TRUE
);


-- wildcard with projection: find
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- wildcard with projection: aggregation pipeline
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$ne": "zebra" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "c": { "$ne": "zebra" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$ne": "zebra" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$gt": "CAT" } }, { "b": { "$lte": "dog" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "a": { "$gt": "CAT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "b": { "$lte": "dog" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$gt": "CAT" } }, { "b": { "$lte": "dog" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

CALL documentdb_api.drop_indexes('db', '{ "dropIndexes": "coll_index_2", "index": ["*"]}');

-- ======== SECTION 13: Wildcard with projection - inclusion (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_index_2', '{ "_id": "hashed" }', false);

-- wildcard with projection: find
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "b": { "$eq": "chIen" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "c": { "$lt": "OKrA" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2", "filter": { "a": { "$gte": "CAT" }, "b" : {"$lte" : "cHaT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- wildcard with projection: aggregation pipeline
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "b": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$in": ["DOG", "Cat"] } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "_id": 1, "c": { "$in": ["DOG", "Cat"] } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "c": { "$in": ["DOG", "Cat"] } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$lte": "RABBIT" } }, { "c": { "$gte": "cat" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2",
     "deletes": [
       { "q": { "a": { "$lte": "RABBIT" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       },
       { "q": { "c": { "$gte": "cat" } },
         "limit": 0,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2",
     "filter": { "$or": [{ "a": { "$lte": "RABBIT" } }, { "c": { "$gte": "cat" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_index_2" }');
CALL documentdb_api.drop_indexes('db', '{ "dropIndexes": "coll_index_2", "index": ["*"]}');

RESET documentdb_api.forceUseIndexIfAvailable;

RESET documentdb.enableCollationWithIndexes;
ALTER SYSTEM SET documentdb_core.enablecollation='off';
SELECT pg_reload_conf();