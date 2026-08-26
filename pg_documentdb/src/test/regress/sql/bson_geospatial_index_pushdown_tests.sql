SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 88200;
SET documentdb.next_collection_index_id TO 88200;

-- Force the planner to prefer the geospatial index over a sequential scan so a
-- failure to push the geo predicate down is visible as an _id_ scan with a
-- residual filter instead of a masked sequential scan.
SET documentdb.forceDisableSeqScan TO on;

SELECT documentdb_api.create_collection('geodb', 'geopushdown');

-- A plain 2dsphere index carries an implicit partial-filter-expression
-- (bson_validate_geography(document, 'loc') IS NOT NULL). The find (local
-- execution shard query) path must still generate a geo predicate whose
-- bson_validate_geography FuncExpr matches that PFE so the index is eligible.
SELECT documentdb_api_internal.create_indexes_non_concurrently('geodb', '{"createIndexes": "geopushdown", "indexes": [{"key": {"loc": "2dsphere"}, "name": "loc_2dsphere_idx" }]}', true);

SELECT documentdb_api.insert_one('geodb','geopushdown','{ "_id": 1, "loc": { "type": "Point", "coordinates": [ 0, 0 ] } }');
SELECT documentdb_api.insert_one('geodb','geopushdown','{ "_id": 2, "loc": { "type": "Point", "coordinates": [ 5, 5 ] } }');
SELECT documentdb_api.insert_one('geodb','geopushdown','{ "_id": 3, "loc": { "type": "Point", "coordinates": [ -5, -5 ] } }');
SELECT documentdb_api.insert_one('geodb','geopushdown','{ "_id": 4, "loc": { "type": "Point", "coordinates": [ 40, 40 ] } }');
SELECT documentdb_api.insert_one('geodb','geopushdown','{ "_id": 5, "loc": { "type": "Point", "coordinates": [ -40, -40 ] } }');

-- =============================================
-- $geoWithin $geometry through the find (local execution) path
-- Must use the 2dsphere index, not _id_ with a residual filter.
-- =============================================
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('geodb', '{ "find": "geopushdown", "filter": { "loc": { "$geoWithin": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ -10, -10 ], [ 10, -10 ], [ 10, 10 ], [ -10, 10 ], [ -10, -10 ] ] ] } } } } }');

-- $geoIntersects $geometry through the find path - must use the 2dsphere index.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('geodb', '{ "find": "geopushdown", "filter": { "loc": { "$geoIntersects": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ -10, -10 ], [ 10, -10 ], [ 10, 10 ], [ -10, 10 ], [ -10, -10 ] ] ] } } } } }');

-- Same predicate through the collection() + @@ path for parity.
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('geodb', 'geopushdown') WHERE document @@ '{ "loc": { "$geoWithin": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ -10, -10 ], [ 10, -10 ], [ 10, 10 ], [ -10, 10 ], [ -10, -10 ] ] ] } } } }';

-- Results are correct and identical across the find and @@ paths.
SELECT document FROM bson_aggregation_find('geodb', '{ "find": "geopushdown", "filter": { "loc": { "$geoWithin": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ -10, -10 ], [ 10, -10 ], [ 10, 10 ], [ -10, 10 ], [ -10, -10 ] ] ] } } } }, "sort": { "_id": 1 } }');

SELECT document FROM documentdb_api.collection('geodb', 'geopushdown') WHERE document @@ '{ "loc": { "$geoWithin": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ -10, -10 ], [ 10, -10 ], [ 10, 10 ], [ -10, 10 ], [ -10, -10 ] ] ] } } } }' ORDER BY object_id;

-- =============================================
-- 2dsphere index with an explicit partialFilterExpression still pushes down
-- when the query satisfies the PFE.
-- =============================================
SELECT documentdb_api.create_collection('geodb', 'geopushdown_pfe');
SELECT documentdb_api_internal.create_indexes_non_concurrently('geodb', '{"createIndexes": "geopushdown_pfe", "indexes": [{"key": {"loc": "2dsphere"}, "name": "loc_2dsphere_region_pfe", "partialFilterExpression": { "region": { "$eq": "west" } } }]}', true);

SELECT documentdb_api.insert_one('geodb','geopushdown_pfe','{ "_id": 1, "region": "west", "loc": { "type": "Point", "coordinates": [ 1, 1 ] } }');
SELECT documentdb_api.insert_one('geodb','geopushdown_pfe','{ "_id": 2, "region": "east", "loc": { "type": "Point", "coordinates": [ 2, 2 ] } }');

-- Query matches the PFE (region = west) - uses the partial 2dsphere index.
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('geodb', '{ "find": "geopushdown_pfe", "filter": { "region": "west", "loc": { "$geoWithin": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ -10, -10 ], [ 10, -10 ], [ 10, 10 ], [ -10, 10 ], [ -10, -10 ] ] ] } } } } }');

-- Geospatial predicates inside query and projection $elemMatch evaluate each
-- array element using the BSON-value runtime path.
SET documentdb.forceDisableSeqScan TO off;
SELECT documentdb_api.insert_one('geodb','geopushdown','{ "_id": 6, "locations": [ { "type": "Point", "coordinates": [ 0, 0 ] }, { "type": "Point", "coordinates": [ 50, 50 ] } ], "places": [ { "loc": { "type": "Point", "coordinates": [ 40, 40 ] } }, { "loc": { "type": "Point", "coordinates": [ 0, 0 ] } } ] }');

SELECT document FROM bson_aggregation_find('geodb', '{ "find": "geopushdown", "filter": { "locations": { "$elemMatch": { "$geoWithin": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ -10, -10 ], [ 10, -10 ], [ 10, 10 ], [ -10, 10 ], [ -10, -10 ] ] ] } } } } }, "projection": { "places": { "$elemMatch": { "loc": { "$geoWithin": { "$centerSphere": [ [ 0, 0 ], 0.01 ] } } } } } }');

SELECT document FROM bson_aggregation_find('geodb', '{ "find": "geopushdown", "filter": { "_id": 6 }, "projection": { "places": { "$elemMatch": { "loc": { "$geoIntersects": { "$geometry": { "type": "Polygon", "coordinates": [ [ [ 39, 39 ], [ 41, 39 ], [ 41, 41 ], [ 39, 41 ], [ 39, 39 ] ] ] } } } } } } }');

SELECT documentdb_api.drop_collection('geodb', 'geopushdown');
SELECT documentdb_api.drop_collection('geodb', 'geopushdown_pfe');
