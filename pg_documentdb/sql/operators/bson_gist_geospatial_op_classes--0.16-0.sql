
#ifdef __POSTGIS_SCHEMA_NAME__
set search_path to pg_catalog,public,__POSTGIS_SCHEMA_NAME__;
#endif

-- This is a bson type operator class wrapper around `gist_geometry_ops_2d` which is implemented for 2d geometries,
-- This operator class has following updates:
--    i) This works for `bson` type instead of `geometry`
--    ii) `compress` support function is changed to support extracting geometries and then converting them to `box2df`
--    iii) This also has `options` support which takes care of storing documentdb 2d index options and validating them e.g. bounds
CREATE OPERATOR CLASS __API_CATALOG_SCHEMA__.bson_gist_geometry_ops_2d
	FOR TYPE __CORE_SCHEMA__.bson USING GIST AS
        OPERATOR        23       __API_CATALOG_SCHEMA__.@|-| ,
        FUNCTION        1        __API_CATALOG_SCHEMA__.bson_gist_geometry_consistent_2d (internal, __CORE_SCHEMA__.bson, integer),
        FUNCTION        2        geometry_gist_union_2d (bytea, internal),
        FUNCTION        3        __API_CATALOG_SCHEMA__.bson_gist_geometry_2d_compress (internal),
        FUNCTION        4        geometry_gist_decompress_2d (internal),
        FUNCTION        5        geometry_gist_penalty_2d (internal, internal, internal),
        FUNCTION        6        geometry_gist_picksplit_2d (internal, internal),
        FUNCTION        7        geometry_gist_same_2d (geom1 geometry, geom2 geometry, internal),
        FUNCTION        8        __API_CATALOG_SCHEMA__.bson_gist_geometry_distance_2d (internal, __CORE_SCHEMA__.bson, integer),
        FUNCTION        10       (__CORE_SCHEMA__.bson) __API_CATALOG_SCHEMA__.bson_gist_geometry_2d_options(internal),
    STORAGE box2df;


-- This is a bson type operator class wrapper around `gist_geography_ops` which is implemented for geographies,
--    i) `compress` support function is changed to support extracting geographies and then converting them to `gidx` for storage
--    ii) This also has `options` support which takes care of storing documentdb 2dsphere index options
CREATE OPERATOR CLASS __API_CATALOG_SCHEMA__.bson_gist_geography_ops_2d
	FOR TYPE __CORE_SCHEMA__.bson USING GIST AS
        OPERATOR        23       __API_CATALOG_SCHEMA__.@|-| ,
        OPERATOR        24       __API_CATALOG_SCHEMA__.@|#| ,
        FUNCTION        1        __API_CATALOG_SCHEMA__.bson_gist_geography_consistent (internal, __CORE_SCHEMA__.bson, integer),
        FUNCTION        2        geography_gist_union (bytea, internal),
        FUNCTION        3        __API_CATALOG_SCHEMA__.bson_gist_geography_compress (internal),
        FUNCTION        4        geography_gist_decompress (internal),
        FUNCTION        5        geography_gist_penalty (internal, internal, internal),
        FUNCTION        6        geography_gist_picksplit (internal, internal),
        FUNCTION        7        geography_gist_same (box2d,box2d, internal),
        FUNCTION        8        __API_CATALOG_SCHEMA__.bson_gist_geography_distance (internal, __CORE_SCHEMA__.bson, integer),
        FUNCTION        10       (__CORE_SCHEMA__.bson)__API_CATALOG_SCHEMA__.bson_gist_geography_options(internal),
    STORAGE gidx;

#ifdef __POSTGIS_SCHEMA_NAME__
reset search_path;
#endif