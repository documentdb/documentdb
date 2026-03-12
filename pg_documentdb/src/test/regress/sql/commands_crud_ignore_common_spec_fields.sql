-- These tests make sure that we ignore the common spec fields/actions that are not implemented for various commands

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb.next_collection_id TO 1600;
SET documentdb.next_collection_index_id TO 1600;

-- create index tests
SELECT documentdb_api_internal.create_indexes_non_concurrently('db',
    '{
        "createIndexes": "ignoreCommonSpec",
        "indexes": [
            {
                "key": {"$**": 1}, "name": "idx_1",
                "wildcardProjection": {"a.b": 1, "a.b": {"c.d": 1}}
            }
        ],
		"commitQuorum" : 100,
		"writeConcern": { "w": "majority", "wtimeout": 5000 },
		"apiVersion": 1,
		"$db" : "db",
		"db": "test2"
    }'
);

-- insert tests
select documentdb_api.insert('db', '{
	"insert":"ignoreCommonSpec", 
	"documents":[{"_id":99,"a":99}], "ordered": false,
        "writeConcern": { "w": "majority", "wtimeout": 5000 },
	"bypassDocumentValidation": true, 
	"comment": "NoOp"
	}');
select documentdb_api.insert('db', '{
	"insert":"ignoreCommonSpec", 
	"documents":[{"_id":21,"a":99}], 
	"ordered": false,
        "bypassDocumentValidation": true, 
	"comment": "NoOp2",
	"apiVersion": 1
	}');

-- insert again
select documentdb_api.insert('db', '{
	"insert":"ignoreCommonSpec", 
	"documents":[{"_id":1,"a":"id1"}], 
	"ordered": false,
        "bypassDocumentValidation": true, 
	"comment": "NoOp1",
	"apiVersion": 1
	}');
select documentdb_api.insert('db', '{
	"insert":"ignoreCommonSpec", 
	"documents":[{"_id":2,"a":"id2"}],
	"ordered": false,
        "bypassDocumentValidation": true,
	"comment": "NoOp2"}');

-- Tests for $db fallback: when database arg is NULL, extract from $db in spec

-- insert with $db in spec and NULL database arg
SELECT documentdb_api.insert(NULL::text, '{
	"insert": "ignoreCommonSpec",
	"documents": [{"_id": 3, "a": "from_db_spec"}],
	"$db": "db"
}');

-- delete with $db in spec and NULL database arg
SELECT documentdb_api.delete(NULL::text, '{
	"delete": "ignoreCommonSpec",
	"deletes": [{"q": {"_id": 3}, "limit": 1}],
	"$db": "db"
}');

-- update with $db in spec and NULL database arg
SELECT documentdb_api.update(NULL::text, '{
	"update": "ignoreCommonSpec",
	"updates": [{"q": {"_id": 2}, "u": {"$set": {"a": "updated_via_db_spec"}}}],
	"$db": "db"
}');

-- findAndModify with $db in spec and NULL database arg
SELECT documentdb_api.find_and_modify(NULL::text, '{
	"findAndModify": "ignoreCommonSpec",
	"query": {"_id": 1},
	"update": {"$set": {"a": "fam_via_db_spec"}},
	"$db": "db"
}');

-- insert with NULL database and no $db should error
SELECT documentdb_api.insert(NULL::text, '{
	"insert": "ignoreCommonSpec",
	"documents": [{"_id": 100}]
}');

-- insert with matching $db and database arg should succeed
SELECT documentdb_api.insert('db', '{
	"insert": "ignoreCommonSpec",
	"documents": [{"_id": 4, "a": "matching_db"}],
	"$db": "db"
}');

-- insert with mismatching $db and database arg should error
SELECT documentdb_api.insert('db', '{
	"insert": "ignoreCommonSpec",
	"documents": [{"_id": 5}],
	"$db": "other_db"
}');

-- update with mismatching $db should error
SELECT documentdb_api.update('db', '{
	"update": "ignoreCommonSpec",
	"updates": [{"q": {}, "u": {"$set": {"x": 1}}}],
	"$db": "wrong_db"
}');

-- delete with mismatching $db should error
SELECT documentdb_api.delete('db', '{
	"delete": "ignoreCommonSpec",
	"deletes": [{"q": {"_id": 1}, "limit": 1}],
	"$db": "wrong_db"
}');

-- create collection with $db in spec and NULL database arg
SELECT documentdb_api.create_collection_view(NULL::text, '{
	"create": "ignoreCommonSpec_db_test",
	"$db": "db"
}');

-- drop the created collection
SELECT documentdb_api.drop_collection('db', 'ignoreCommonSpec_db_test');

-- Note: find, count, distinct, aggregate entry points are declared STRICT in SQL,
-- so NULL database args are handled by PG (returns NULL without calling C).
-- The $db parsing in the C layer handles the case where the gateway sends NULL
-- via internal function calls.

-- Test: with enableDbNameValidation off, mismatching $db should not error
SET documentdb.enableDbNameValidation TO off;

-- update with mismatching $db succeeds when validation is off
SELECT documentdb_api.update('db', '{
	"update": "ignoreCommonSpec",
	"updates": [{"q": {"_id": 100}, "u": {"$set": {"x": 1}}}],
	"$db": "wrong_db"
}');

-- delete with mismatching $db succeeds when validation is off
SELECT documentdb_api.delete('db', '{
	"delete": "ignoreCommonSpec",
	"deletes": [{"q": {"_id": 100}, "limit": 1}],
	"$db": "wrong_db"
}');

SET documentdb.enableDbNameValidation TO on;

-- Tests for bson_aggregation_find/pipeline/count with $db in spec
-- These functions are STRICT, so NULL db arg returns empty, but $db in spec
-- should work alongside a valid database argument.

-- find with matching $db should succeed
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('db',
    '{ "find": "ignoreCommonSpec", "filter": {"_id": 4}, "$db": "db" }');

-- find with mismatching $db should error
SELECT document FROM documentdb_api_catalog.bson_aggregation_find('db',
    '{ "find": "ignoreCommonSpec", "filter": {"_id": 4}, "$db": "wrong_db" }');

-- aggregate with matching $db should succeed
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db',
    '{ "aggregate": "ignoreCommonSpec", "pipeline": [{"$match": {"_id": 4}}], "cursor": {}, "$db": "db" }');

-- aggregate with mismatching $db should error
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db',
    '{ "aggregate": "ignoreCommonSpec", "pipeline": [{"$match": {"_id": 4}}], "cursor": {}, "$db": "wrong_db" }');

-- count with matching $db should succeed
SELECT document FROM documentdb_api_catalog.bson_aggregation_count('db',
    '{ "count": "ignoreCommonSpec", "$db": "db" }');

-- count with mismatching $db should error
SELECT document FROM documentdb_api_catalog.bson_aggregation_count('db',
    '{ "count": "ignoreCommonSpec", "$db": "wrong_db" }');

-- Tests for find/aggregate/count with NULL database arg and $db in spec.
-- The planner rewrites these calls, so STRICT doesn't prevent NULL arg from reaching C.

-- find with NULL database arg and $db in spec should succeed
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(NULL,
    '{ "find": "ignoreCommonSpec", "filter": {"_id": 4}, "$db": "db" }');

-- aggregate with NULL database arg and $db in spec should succeed
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline(NULL,
    '{ "aggregate": "ignoreCommonSpec", "pipeline": [{"$match": {"_id": 4}}], "cursor": {}, "$db": "db" }');

-- count with NULL database arg and $db in spec should succeed
SELECT document FROM documentdb_api_catalog.bson_aggregation_count(NULL,
    '{ "count": "ignoreCommonSpec", "$db": "db" }');

-- find with NULL database arg and no $db should error
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(NULL,
    '{ "find": "ignoreCommonSpec", "filter": {"_id": 4} }');

SELECT * FROM documentdb_api.list_indexes_cursor_first_page('newdb', '{ "Let": "tar" }');

-- cleanup
SELECT documentdb_api.drop_collection('db', 'ignoreCommonSpec');