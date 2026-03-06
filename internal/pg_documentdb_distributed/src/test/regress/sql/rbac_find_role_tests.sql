-- Tests for custom role operations with documentdb_api_find_role
-- This file verifies that users inheriting from documentdb_api_find_role can perform
-- find operations when granted SELECT permissions on specific collections.

SET documentdb.next_collection_id TO 1983900;
SET documentdb.next_collection_index_id TO 1983900;
\set VERBOSITY TERSE

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SHOW documentdb.enableRbacCompliantSchemas;
-- Save the original user for switching back
SELECT current_user AS original_user \gset

-- =============================================================================
-- Setup: Create test collections and find_test_user
-- =============================================================================

-- Create test collection (will get collection_id 1983901)
SELECT documentdb_api.create_collection('rbac_find_test_db', 'test_collection');

-- Create second test collection (will get collection_id 1983902) - user will NOT have access
SELECT documentdb_api.create_collection('rbac_find_test_db', 'restricted_collection');
 
-- Insert test data for find tests
SELECT documentdb_api.insert_one('rbac_find_test_db', 'test_collection', '{"_id": 1, "name": "doc1", "value": 100}');
SELECT documentdb_api.insert_one('rbac_find_test_db', 'restricted_collection', '{"_id": 1, "name": "restricted_doc"}');

-- Create find test user
CREATE ROLE find_test_user WITH LOGIN PASSWORD 'TestPass123!';

-- Grant collection RBAC role to test user
GRANT documentdb_api_find_role TO find_test_user;

-- Grant table permissions on test_collection (collection_id = 1983901)
-- When next_collection_id is set to X, the first collection gets ID X+1
-- find_test_user: only SELECT
GRANT SELECT ON TABLE documentdb_data.documents_1983901 TO find_test_user;

-- =============================================================================
-- Test: Find operation with documentdb_api_find_role role
-- A user inheriting from documentdb_api_find_role should only need SELECT on the
-- collection table to perform find operations.
-- =============================================================================

\c regression find_test_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Count should work
SELECT document FROM documentdb_api_v2.count_query('rbac_find_test_db', '{"count": "test_collection", "query": {}}');

-- Distinct should work
SELECT document FROM documentdb_api_v2.distinct_query('rbac_find_test_db', '{"distinct": "test_collection", "key": "name"}');

-- Aggregate should work
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid
FROM documentdb_api_v2.aggregate_cursor_first_page('rbac_find_test_db', '{"aggregate": "test_collection", "pipeline": [{"$match": {"_id": 1}}], "cursor": {}}', 0);

-- =============================================================================
-- Test: Geospatial find operations with documentdb_api_find_role role
-- Verify geospatial queries work with documentdb_api_find_role
-- =============================================================================

-- Switch back to admin to create geospatial collection
\c regression :original_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Create geospatial test collection
SELECT documentdb_api.create_collection('rbac_find_test_db', 'geo_collection');

-- Insert geospatial test data
SELECT documentdb_api.insert_one('rbac_find_test_db', 'geo_collection', '{"_id": 1, "name": "point1", "location": [10, 10], "geo": {"type": "Point", "coordinates": [15, 15]}}');

-- Create 2d index for legacy coordinate queries
SELECT documentdb_api_internal.create_indexes_non_concurrently('rbac_find_test_db', '{"createIndexes": "geo_collection", "indexes": [{"key": {"location": "2d"}, "name": "location_2d_idx"}]}', true);

-- Create 2dsphere index for GeoJSON queries
SELECT documentdb_api_internal.create_indexes_non_concurrently('rbac_find_test_db', '{"createIndexes": "geo_collection", "indexes": [{"key": {"geo": "2dsphere"}, "name": "geo_2dsphere_idx"}]}', true);

-- Grant SELECT on geo_collection to find_test_user using dynamic SQL to get the actual table name
DO $$
DECLARE
    coll_id bigint;
BEGIN
    SELECT collection_id INTO coll_id
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'rbac_find_test_db' AND collection_name = 'geo_collection';

    EXECUTE format('GRANT SELECT ON TABLE documentdb_data.documents_%s TO find_test_user', coll_id);
END $$;

-- Switch to find_test_user for geospatial queries
\c regression find_test_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- $geoWithin with $box should work
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid
FROM documentdb_api_v2.find_cursor_first_page('rbac_find_test_db', '{"find": "geo_collection", "filter": {"location": {"$geoWithin": {"$box": [[5, 5], [25, 25]]}}}}', 0);

-- $geoWithin with $center should work
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid
FROM documentdb_api_v2.find_cursor_first_page('rbac_find_test_db', '{"find": "geo_collection", "filter": {"location": {"$geoWithin": {"$center": [[20, 20], 15]}}}}', 0);

-- $geoWithin with $polygon should work
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid
FROM documentdb_api_v2.find_cursor_first_page('rbac_find_test_db', '{"find": "geo_collection", "filter": {"location": {"$geoWithin": {"$polygon": [[0, 0], [0, 50], [50, 50], [50, 0]]}}}}', 0);

-- $geoWithin with $geometry (GeoJSON) should work
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid
FROM documentdb_api_v2.find_cursor_first_page('rbac_find_test_db', '{"find": "geo_collection", "filter": {"geo": {"$geoWithin": {"$geometry": {"type": "Polygon", "coordinates": [[[0, 0], [0, 30], [30, 30], [30, 0], [0, 0]]]}}}}}', 0);

-- $geoIntersects with GeoJSON should work
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid
FROM documentdb_api_v2.find_cursor_first_page('rbac_find_test_db', '{"find": "geo_collection", "filter": {"geo": {"$geoIntersects": {"$geometry": {"type": "Point", "coordinates": [15, 15]}}}}}', 0);

-- Aggregate with geospatial $match should work
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch._id": 1, "cursor.id": 1 }'), continuation, persistconnection, cursorid
FROM documentdb_api_v2.aggregate_cursor_first_page('rbac_find_test_db', '{"aggregate": "geo_collection", "pipeline": [{"$match": {"location": {"$geoWithin": {"$box": [[5, 5], [35, 35]]}}}}], "cursor": {}}', 0);

-- Count with geospatial filter should work
SELECT document FROM documentdb_api_v2.count_query('rbac_find_test_db', '{"count": "geo_collection", "query": {"location": {"$geoWithin": {"$box": [[0, 0], [50, 50]]}}}}');

-- =============================================================================
-- Test: Verify find_test_user cannot access restricted_collection
-- =============================================================================

-- find_test_user should NOT be able to find on restricted_collection (no SELECT grant)
SELECT cursorpage FROM documentdb_api_v2.find_cursor_first_page('rbac_find_test_db', '{"find": "restricted_collection", "filter": {}}', 0);

-- =============================================================================
-- Test: Verify find_test_user cannot perform other operations
-- =============================================================================

-- find_test_user should NOT be able to insert (no INSERT grant and no documentdb_api_insert_role role)
SELECT documentdb_api_v2.insert_one('rbac_find_test_db', 'test_collection', '{"_id": 100, "name": "should_fail"}', NULL);

-- find_test_user should NOT be able to update (no UPDATE grant and no documentdb_api_update_role role)
SELECT documentdb_api_v2.update('rbac_find_test_db', '{"update": "test_collection", "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 0}}}]}', NULL, NULL);

-- find_test_user should NOT be able to delete (no DELETE grant and no documentdb_api_remove_role role)
SELECT documentdb_api_v2.delete('rbac_find_test_db', '{"delete": "test_collection", "deletes": [{"q": {"_id": 1}, "limit": 1}]}', NULL, NULL);

-- =============================================================================
-- Cleanup
-- =============================================================================
 
\c regression :original_user
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

-- Drop test collections first (removes table privilege dependencies that block DROP ROLE)
SELECT documentdb_api.drop_collection('rbac_find_test_db', 'test_collection');
SELECT documentdb_api.drop_collection('rbac_find_test_db', 'restricted_collection');
SELECT documentdb_api.drop_collection('rbac_find_test_db', 'geo_collection');

-- Drop test role (required due to 100 user limit)
DROP ROLE IF EXISTS find_test_user;
