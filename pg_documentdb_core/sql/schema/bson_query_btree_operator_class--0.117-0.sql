/*
 * Non-default btree opclass holding the cross-type bson/bsonquery native-stats
 * operators, added to the existing bson_btree_ops family so (bson_column OP
 * bsonquery_bound) quals stay indexable on the same btree indexes (e.g. _id_).
 */
CREATE OPERATOR CLASS __CORE_SCHEMA__.bson_query_btree_ops
    FOR TYPE __CORE_SCHEMA__.bson USING btree FAMILY __CORE_SCHEMA__.bson_btree_ops AS
        OPERATOR 1 __CORE_SCHEMA__.*< (__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery),
        OPERATOR 2 __CORE_SCHEMA__.*<= (__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery),
        OPERATOR 3 __CORE_SCHEMA__.*= (__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery),
        OPERATOR 4 __CORE_SCHEMA__.*>= (__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery),
        OPERATOR 5 __CORE_SCHEMA__.*> (__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery),
        FUNCTION 1 __CORE_SCHEMA__.bson_compare(__CORE_SCHEMA__.bson, __CORE_SCHEMA__.bsonquery);
