SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 19400;
SET documentdb.next_collection_index_id TO 19400;

-- Regression test for antimeridian-crossing GeoJSON polygons (issue #420).
-- A polygon whose ring crosses the antimeridian (longitude jumps e.g. 175 -> -175)
-- is valid on the sphere and is accepted by MongoDB. It must therefore be accepted by
-- DocumentDB as well, and queried using geodesic (spherical) semantics.

SELECT documentdb_api.create_collection('db', 'geoms') IS NOT NULL;
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', '{"createIndexes": "geoms", "indexes": [{"key": {"geometry": "2dsphere"}, "name": "geo_idx" }]}', true);

-- 3c) Non-crossing polygon: accepted (baseline, accepted before the fix too)
SELECT documentdb_api.insert_one('db','geoms','{ "_id": 1, "geometry": { "type": "Polygon", "coordinates": [ [ [160, -40], [165, -40], [175, -30], [175, -20], [165, -10], [160, -10], [160, -40] ] ] } }', NULL);

-- 3d) Antimeridian-crossing polygon (a +10 lon / +50 lat translation of 3c): now accepted
SELECT documentdb_api.insert_one('db','geoms','{ "_id": 2, "geometry": { "type": "Polygon", "coordinates": [ [ [170, 10], [175, 10], [-175, 20], [-175, 30], [175, 40], [170, 40], [170, 10] ] ] } }', NULL);

-- Another antimeridian-crossing polygon given in counter-clockwise order: accepted
SELECT documentdb_api.insert_one('db','geoms','{ "_id": 3, "geometry": { "type": "Polygon", "coordinates": [ [ [170, 10], [170, 40], [175, 40], [-175, 30], [-175, 20], [175, 10], [170, 10] ] ] } }', NULL);

-- Antimeridian-crossing polygon (shell) with an antimeridian-crossing hole: accepted
SELECT documentdb_api.insert_one('db','geoms','{ "_id": 4, "geometry": { "type": "Polygon", "coordinates": [ [ [170, 10], [175, 10], [-175, 10], [-175, 40], [175, 40], [170, 40], [170, 10] ], [ [172, 20], [178, 20], [-178, 20], [-178, 30], [178, 30], [172, 30], [172, 20] ] ] } }', NULL);

-- Genuinely self-intersecting (bowtie) polygon: still rejected
SELECT documentdb_api.insert_one('db','geoms','{ "_id": 5, "geometry": { "type": "Polygon", "coordinates": [ [ [0, 0], [10, 10], [10, 0], [0, 10], [0, 0] ] ] } }', NULL);

-- Self-intersecting polygon that also crosses the antimeridian: still rejected
SELECT documentdb_api.insert_one('db','geoms','{ "_id": 6, "geometry": { "type": "Polygon", "coordinates": [ [ [170, 0], [-175, 10], [-175, 0], [170, 10], [170, 0] ] ] } }', NULL);

-- Query: a point just east of the antimeridian inside the crossing polygons -> matches _id 2 and 3
SELECT document FROM documentdb_api.collection('db', 'geoms') WHERE document @@ '{"geometry": {"$geoIntersects": {"$geometry": {"type": "Point", "coordinates": [179, 25]}}}}' ORDER BY object_id;

-- Query: a point just west of the antimeridian inside the crossing polygons -> matches _id 2 and 3
SELECT document FROM documentdb_api.collection('db', 'geoms') WHERE document @@ '{"geometry": {"$geoIntersects": {"$geometry": {"type": "Point", "coordinates": [-178, 25]}}}}' ORDER BY object_id;

-- Query: a point on the far side of the globe -> matches nothing (no long-way wrap)
SELECT document FROM documentdb_api.collection('db', 'geoms') WHERE document @@ '{"geometry": {"$geoIntersects": {"$geometry": {"type": "Point", "coordinates": [0, 25]}}}}' ORDER BY object_id;

-- Query: a point inside the shell but within the antimeridian-crossing hole -> excluded from _id 4
SELECT document FROM documentdb_api.collection('db', 'geoms') WHERE document @@ '{"geometry": {"$geoIntersects": {"$geometry": {"type": "Point", "coordinates": [179, 25]}}}}' AND document @@ '{"_id": {"$eq": 4}}' ORDER BY object_id;

-- Cleanup
SELECT documentdb_api.drop_collection('db', 'geoms');
