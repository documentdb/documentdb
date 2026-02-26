SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 1970000;
SET documentdb.next_collection_id TO 19700;
SET documentdb.next_collection_index_id TO 19700;

SET documentdb_api.forceUseIndexIfAvailable to on;

SET documentdb.enableCollationWithIndexes TO off;
ALTER SYSTEM SET documentdb_core.enablecollation='on';
SELECT pg_reload_conf();

-- ======== SECTION 1: Single-path index tests on coll_index_1_cmp ========

SELECT documentdb_api.insert_one('db','coll_index_1_cmp', '{"_id": 1, "a" : "DOG" }', NULL);
SELECT documentdb_api.insert_one('db','coll_index_1_cmp', '{"_id": 2, "a" : "dog" }', NULL);
SELECT documentdb_api.insert_one('db','coll_index_1_cmp', '{"_id": 3, "a" : "Cat" }', NULL);
SELECT documentdb_api.insert_one('db','coll_index_1_cmp', '{"_id": 4, "a" : "Dog" }', NULL);

-- single path indexes
-- non-concurrent index creation
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_1_cmp",
     "indexes": [
       {
         "key": {"a": 1}, "name": "index_1_a_cmp",
         "collation" : {"locale" : "en", "strength" : 1},
         "enableCompositeTerm": true
       }
     ]
   }',
   TRUE
);

-- no collation: index not used
-- find
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1_cmp", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1_cmp", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }');
ROLLBACK;

-- aggregate
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_1_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$addFields": { "x": "mANgO" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_1_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$addFields": { "x": "mANgO" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- different collation than index: index not used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1_cmp", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1_cmp", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- same collation as index : index used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1_cmp", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_1_cmp", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_1_cmp",
     "filter": { "a": { "$gt": "Cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_1_cmp",
     "deletes": [
       { "q": { "_id": 1, "a": { "$gt": "Cat" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_1_cmp",
     "filter": { "a": { "$gt": "Cat" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_1_cmp",
     "filter": { "$or": [{ "a": { "$lt": "DOG" } }, { "a": { "$gte": "Dog" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_1_cmp",
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
  '{ "find": "coll_index_1_cmp",
     "filter": { "$or": [{ "a": { "$lt": "DOG" } }, { "a": { "$gte": "Dog" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- ======== SECTION 2: Single-path index tests on coll_index_2_cmp (unsharded) ========

-- (1) insert some docs
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 1, "a": "Cat" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 2, "a": "cat" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 3, "a": "Dog" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 4, "a": "dog" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 5, "a": { "b" : "cAt"} }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 6, "a": ["Cat", "cat", "dog"] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 7, "a": [{ "b": "CAT"}] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 9, "a": "Dog", "b": "Chien" }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 10, "a": "cat", "b": ["Chien", "Chat"] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 11, "a": "dog", "c": "kraman"  }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 12, "a": "cat", "c":{ "d": "Okra" } }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 13, "a": "cat", "c":[ "Okra", "Kraman", "okra" ] }');
SELECT documentdb_api.insert_one('db', 'coll_index_2_cmp', '{ "_id": 14, "a": "cat", "b": {"c": "chat"} }');


SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_2_cmp",
     "indexes": [
       {
         "key": {"a": 1}, "name": "index_2_cmp_a",
         "collation" : {"locale" : "en", "strength" : 1},
         "enableCompositeTerm": true
       }
     ]
   }',
   TRUE
);

-- find: unsharded
BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $nin
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$nin" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $nin with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: basic test with two values (case-insensitive match)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: single value (equivalent to $eq for arrays)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: on scalar field should return empty when multiple distinct values required
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "_id": 1, "a": { "$all": ["CAT", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: three values with case variations - tests AND semantics are preserved
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: no matches (value not in any document)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["ELEPHANT", "LION"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $and on different field
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $elemMatch
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $elemMatch with range
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;


BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- aggregate: unsharded
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $unwind
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $addFields
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $sort after $match
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2_cmp",
     "deletes": [
       { "q": { "_id": 1, "a": { "$gte": "rabbit" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2_cmp",
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
  '{ "find": "coll_index_2_cmp",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- ======== SECTION 3: Single-path index tests on coll_index_2_cmp (sharded) ========

-- shard the collection
SELECT documentdb_api.shard_collection('db', 'coll_index_2_cmp', '{ "_id": "hashed" }', false);

-- find: sharded
BEGIN;
-- $eq
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $lt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$lt": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $gt
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gt": "CAT", "$lt" : "RABBIT"} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- $gte
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $in with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$in": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $nin
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$nin" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $nin with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$nin": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: basic test with two values (case-insensitive match)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: single value (equivalent to $eq for arrays)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: on scalar field should return empty when multiple distinct values required
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "_id": 1, "a": { "$all": ["CAT", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: three values with case variations - tests AND semantics are preserved
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["CAT", "cat", "DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: no matches (value not in any document)
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": ["ELEPHANT", "LION"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $and on different field
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and": [{ "a": { "$all": ["CAT"] } }, { "b": { "$exists": true } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all: combined with $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or": [{ "a": { "$all": ["CAT", "DOG"] } }, { "_id": 1 }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $all with regex
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$all": [{"$regex": "DOG", "$options": ""}, {"$regex": "CAT", "$options": ""}, "dog"] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;


BEGIN;
-- $elemMatch
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$eq": "CAT" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $elemMatch with range
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN(VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "a": { "$elemMatch": { "$gte": "cat", "$lte": "dog" } } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$or" : [{ "a": { "$lte": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

-- aggregate: sharded
BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "DOG" } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
ROLLBACK;

BEGIN;
-- $match followed by $project
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $unwind
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } }, { "$unwind": "$a" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $match then $addFields
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "dog" } } },  { "$addFields": { "x": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- $sort after $match
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$in": ["cat", "dog"] } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1} }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2_cmp",
     "deletes": [
       { "q": { "_id": 1, "a": { "$gte": "rabbit" } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "a": { "$gte": "rabbit" } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2_cmp",
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
  '{ "find": "coll_index_2_cmp",
     "filter": { "$or": [{ "a": { "$in": ["CAT", "dog"] } }, { "a": { "$lte": "RABBIT" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- unshard and drop indexes
SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_index_2_cmp" }');
CALL documentdb_api.drop_indexes('db', '{ "dropIndexes": "coll_index_2_cmp", "index": ["*"]}');

-- ======== SECTION 6: Multiple indexes (unsharded) ========

-- multiple indexes
-- index_2_cmp_a is case-sensitive, index_2_cmp_a_b is case-insensitive, index_2_cmp_c is case-insensitive
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'db',
  '{
     "createIndexes": "coll_index_2_cmp",
     "indexes": [
        {
         "key": {"a": 1}, "name": "index_2_cmp_a",
         "collation" : {"locale" : "en", "strength" : 3},
         "enableCompositeTerm": true
        },
        {
        "key": {"a": 1, "b": -1}, "name": "index_2_cmp_a_b",
        "collation" : {"locale" : "en", "strength" : 1},
        "enableCompositeTerm": true
        },
        {
        "key": {"c": 1}, "name": "index_2_cmp_c",
        "collation" : {"locale" : "en", "strength" : 2},
        "enableCompositeTerm": true
        }
     ]
   }',
   TRUE
);

BEGIN;
-- index_2_cmp_a is used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
ROLLBACK;

BEGIN;
-- index_2_cmp_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_cmp_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_cmp_c used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c": { "$eq": "KRAMAN" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c": { "$eq": "kraMAn" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
ROLLBACK;

BEGIN;
-- $match with $and and $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "KRAMAN" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
ROLLBACK;

-- ======== SECTION 7: Multiple indexes (sharded) ========

SELECT documentdb_api.shard_collection('db', 'coll_index_2_cmp', '{ "_id": "hashed" }', false);

BEGIN;
-- index_2_cmp_a is used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 3 } }');
ROLLBACK;

BEGIN;
-- index_2_cmp_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_cmp_a_b used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
-- index_2_cmp_c used
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c": { "$eq": "KRAMAN" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "b": { "$gte": "cat" } }, { "c": { "$eq": "kraMAn" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 2 } }');
ROLLBACK;

BEGIN;
-- $match with $and and $or
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('db', '{ "find": "coll_index_2_cmp", "filter": { "$and" : [{ "a": { "$gte": "cat" } }, { "c": { "$eq": "okra" } }, { "$or" : [{ "b": { "$eq": "DOG" } }, { "b": { "$eq": "cat" } }] }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "c": { "$eq": "KRAMAN" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
ROLLBACK;

BEGIN;
SET LOCAL enable_seqscan TO OFF;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "coll_index_2_cmp", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "cat" }, "b": "DOG" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 2}  }');
ROLLBACK;

BEGIN;
-- deleteOne
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "a": { "$ne": "rabbit" }, "b": { "$in": ["Dog", "CAT"] } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2_cmp",
     "deletes": [
       { "q": { "_id": 1, "a": { "$ne": "rabbit" }, "b": { "$in": ["Dog", "CAT"] } },
         "limit": 1,
         "collation": { "locale": "en", "strength": 1 }
       }
     ]
   }');

SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "a": { "$ne": "rabbit" }, "b": { "$in": ["Dog", "CAT"] } },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

BEGIN;
-- deleteMany
SELECT document FROM bson_aggregation_find('db',
  '{ "find": "coll_index_2_cmp",
     "filter": { "$or": [{ "a": { "$gt": "Cat" }, "b": { "$lte": "DOG" } }, { "a": { "$lt": "DOG" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');

SELECT documentdb_api.delete('db',
  '{ "delete": "coll_index_2_cmp",
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
  '{ "find": "coll_index_2_cmp",
     "filter": { "$or": [{ "a": { "$gt": "Cat" }, "b": { "$lte": "DOG" } }, { "a": { "$lt": "DOG" } }] },
     "sort": { "_id": 1 },
     "collation": { "locale": "en", "strength": 1 }
   }');
ROLLBACK;

-- unshard and drop indexes
SELECT documentdb_api.unshard_collection('{ "unshardCollection": "db.coll_index_2_cmp" }');
CALL documentdb_api.drop_indexes('db', '{"dropIndexes": "coll_index_2_cmp", "index": ["*"]}');

RESET documentdb_api.forceUseIndexIfAvailable;

RESET documentdb.enableCollationWithIndexes;
ALTER SYSTEM SET documentdb_core.enablecollation='off';
SELECT pg_reload_conf();