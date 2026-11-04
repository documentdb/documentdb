SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 29300;
SET documentdb.next_collection_index_id TO 29300;

SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableFailureOnParallelIndexArrays TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_mkp_db',
    '{"createIndexes":"docs","indexes":[{"key":{"a.b":1,"a.c":1},"name":"ab_ac_idx","enableOrderedIndex":1}]}',
    true);

-- Independent leaf arrays are parallel and fail by default on an MKP index.
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'docs',
    '{"_id":1,"a":{"b":[1,2],"c":[3,4]}}');

-- Correlated paths under one shared array remain valid.
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'docs',
    '{"_id":2,"a":[{"b":1,"c":10},{"b":2,"c":20}]}');

-- The scoped GUC provides an emergency opt-out for metadata-backed indexes.
SET documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking TO off;
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'docs',
    '{"_id":3,"a":{"b":[1,2],"c":[3,4]}}');
RESET documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking;

SELECT document
FROM documentdb_api.collection('parallel_mkp_db', 'docs')
ORDER BY object_id;

-- Parent-child paths keep legacy tracking, regardless of key order or position.
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_mkp_db',
    '{"createIndexes":"parent_child","indexes":[
        {"key":{"a":1,"a.b":1},"name":"parent_first","enableOrderedIndex":1},
        {"key":{"a.b":1,"a":1},"name":"child_first","enableOrderedIndex":1},
        {"key":{"a.b":1,"c":1,"a":1},"name":"parent_last","enableOrderedIndex":1}
    ]}', true);
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'parent_child',
    '{"_id":1,"a":[{"b":1},{"b":2}]}');
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'parent_child',
    '{"_id":2,"a":[{"b":[1,2]},{"b":3}]}');

-- Ordinary predicates may match different parent-array elements.
SELECT document FROM bson_aggregation_count('parallel_mkp_db',
    '{"count":"parent_child","query":{"a":{"b":1},"a.b":2},"hint":"parent_first"}');
SELECT document FROM bson_aggregation_count('parallel_mkp_db',
    '{"count":"parent_child","query":{"a":{"b":1},"a.b":2},"hint":"child_first"}');
SELECT document FROM bson_aggregation_count('parallel_mkp_db',
    '{"count":"parent_child","query":{"a":{"b":[1,2]},"a.b":3},"hint":"parent_last"}');

-- Dotted parent-child paths are excluded even when RCT is enabled.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_mkp_db',
    '{"createIndexes":"nested_parent_child","indexes":[
        {"key":{"a.b":1,"a.b.c":1},"name":"nested_parent","enableOrderedIndex":1}
    ]}', true);
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'nested_parent_child',
    '{"_id":1,"a":{"b":[{"c":1},{"c":2}]}}');
SELECT document FROM bson_aggregation_count('parallel_mkp_db',
    '{"count":"nested_parent_child","query":{"a.b":{"c":1},"a.b.c":2},"hint":"nested_parent"}');

-- Four dot boundaries are traversed before finding the indexed ancestor.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_mkp_db',
    '{"createIndexes":"deep_parent_child","indexes":[
        {"key":{"a.b.c.d.e":1,"a.b.c.d":1},"name":"deep_child_first","enableOrderedIndex":1}
    ]}', true);
SELECT 'documentdb_data.documents_' || collection_id AS deep_table
FROM documentdb_api_catalog.collections
WHERE database_name = 'parallel_mkp_db'
    AND collection_name = 'deep_parent_child' \gset
\d :deep_table

SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'deep_parent_child',
    '{"_id":1,"a":{"b":{"c":{"d":[{"e":1},{"e":2}]}}}}');
SELECT document FROM bson_aggregation_count('parallel_mkp_db',
    '{"count":"deep_parent_child","query":{"a.b.c.d":{"e":1},"a.b.c.d.e":2},"hint":"deep_child_first"}');

-- A lexical prefix without a dot boundary does not exclude MKP.
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_mkp_db',
    '{"createIndexes":"boundary_paths","indexes":[
        {"key":{"a":1,"ab":1},"name":"top_level_boundary","enableOrderedIndex":1},
        {"key":{"a.b":1,"a.bc":1},"name":"dotted_boundary","enableOrderedIndex":1}
    ]}', true);

-- Collated parent-child indexes use the same fallback and retain matching semantics.
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'parallel_mkp_db',
    '{"createIndexes":"collated_parent_child","indexes":[
        {"key":{"a":1,"a.b":1},"name":"parent_child_ci","enableOrderedIndex":1,
         "collation":{"locale":"en","strength":2}}
    ]}', true);
SELECT documentdb_api.insert_one(
    'parallel_mkp_db', 'collated_parent_child',
    '{"_id":1,"a":[{"b":"Alpha"},{"b":"Zulu"}]}');
SELECT document FROM bson_aggregation_count('parallel_mkp_db',
    '{"count":"collated_parent_child","query":{"a.b":"ALPHA"},
      "hint":"parent_child_ci","collation":{"locale":"en","strength":2}}');

SELECT coll.collection_name, cls.relname,
       pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%' AS has_per_path_tracking,
       pg_get_indexdef(idx.indexrelid) LIKE '%rct=''true''%' AS has_rct
FROM documentdb_api_catalog.collections coll
JOIN pg_class tbl ON tbl.relname = 'documents_' || coll.collection_id
    AND tbl.relnamespace = 'documentdb_data'::regnamespace
JOIN pg_index idx ON idx.indrelid = tbl.oid
JOIN pg_class cls ON cls.oid = idx.indexrelid
WHERE coll.database_name = 'parallel_mkp_db'
    AND cls.relname LIKE 'documents_rum_index%'
ORDER BY coll.collection_name, cls.relname;

SELECT documentdb_api.drop_collection('parallel_mkp_db', 'docs');
SELECT documentdb_api.drop_collection('parallel_mkp_db', 'parent_child');
SELECT documentdb_api.drop_collection('parallel_mkp_db', 'nested_parent_child');
SELECT documentdb_api.drop_collection('parallel_mkp_db', 'deep_parent_child');
SELECT documentdb_api.drop_collection('parallel_mkp_db', 'boundary_paths');
SELECT documentdb_api.drop_collection('parallel_mkp_db', 'collated_parent_child');
