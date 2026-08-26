/*
 * Native-stats btree operators (*=, *<, *<=, *>, *>=): cross-type bson OP
 * bsonquery. The '*' prefix marks them as cost-estimation-only. They mirror the
 * plain bson/bson comparison semantics but declare the builtin scalar
 * selectivity estimators as RESTRICT, so clauselist_selectivity merges matching
 * bounds into a range instead of multiplying them independently.
 */

CREATE OPERATOR __CORE_SCHEMA__.*= (
    LEFTARG = __CORE_SCHEMA__.bson,
    RIGHTARG = __CORE_SCHEMA__.bsonquery,
    PROCEDURE = __CORE_SCHEMA__.bson_equal,
    RESTRICT = pg_catalog.eqsel
);

CREATE OPERATOR __CORE_SCHEMA__.*<> (
    LEFTARG = __CORE_SCHEMA__.bson,
    RIGHTARG = __CORE_SCHEMA__.bsonquery,
    PROCEDURE = __CORE_SCHEMA__.bson_not_equal,
    RESTRICT = pg_catalog.neqsel,
    NEGATOR = OPERATOR(__CORE_SCHEMA__.*=)
);

CREATE OPERATOR __CORE_SCHEMA__.*< (
    LEFTARG = __CORE_SCHEMA__.bson,
    RIGHTARG = __CORE_SCHEMA__.bsonquery,
    PROCEDURE = __CORE_SCHEMA__.bson_lt,
    RESTRICT = pg_catalog.scalarltsel
);

CREATE OPERATOR __CORE_SCHEMA__.*>= (
    LEFTARG = __CORE_SCHEMA__.bson,
    RIGHTARG = __CORE_SCHEMA__.bsonquery,
    PROCEDURE = __CORE_SCHEMA__.bson_gte,
    RESTRICT = pg_catalog.scalargesel,
    NEGATOR = OPERATOR(__CORE_SCHEMA__.*<)
);

CREATE OPERATOR __CORE_SCHEMA__.*<= (
    LEFTARG = __CORE_SCHEMA__.bson,
    RIGHTARG = __CORE_SCHEMA__.bsonquery,
    PROCEDURE = __CORE_SCHEMA__.bson_lte,
    RESTRICT = pg_catalog.scalarlesel
);

CREATE OPERATOR __CORE_SCHEMA__.*> (
    LEFTARG = __CORE_SCHEMA__.bson,
    RIGHTARG = __CORE_SCHEMA__.bsonquery,
    PROCEDURE = __CORE_SCHEMA__.bson_gt,
    RESTRICT = pg_catalog.scalargtsel,
    NEGATOR = OPERATOR(__CORE_SCHEMA__.*<=)
);
