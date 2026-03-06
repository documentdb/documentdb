CREATE OPERATOR CLASS __API_SCHEMA_INTERNAL_V2__.bsonindexterm_btree_ops
    DEFAULT FOR TYPE __API_SCHEMA_INTERNAL_V2__.bsonindexterm USING btree AS
        OPERATOR 1 __API_SCHEMA_INTERNAL_V2__.< (__API_SCHEMA_INTERNAL_V2__.bsonindexterm, __API_SCHEMA_INTERNAL_V2__.bsonindexterm),
        OPERATOR 2 __API_SCHEMA_INTERNAL_V2__.<= (__API_SCHEMA_INTERNAL_V2__.bsonindexterm, __API_SCHEMA_INTERNAL_V2__.bsonindexterm),
        OPERATOR 3 __API_SCHEMA_INTERNAL_V2__.= (__API_SCHEMA_INTERNAL_V2__.bsonindexterm, __API_SCHEMA_INTERNAL_V2__.bsonindexterm),
        OPERATOR 4 __API_SCHEMA_INTERNAL_V2__.>= (__API_SCHEMA_INTERNAL_V2__.bsonindexterm, __API_SCHEMA_INTERNAL_V2__.bsonindexterm),
        OPERATOR 5 __API_SCHEMA_INTERNAL_V2__.> (__API_SCHEMA_INTERNAL_V2__.bsonindexterm, __API_SCHEMA_INTERNAL_V2__.bsonindexterm),
        FUNCTION 1 __API_SCHEMA_INTERNAL_V2__.bsonindexterm_compare_btree(__API_SCHEMA_INTERNAL_V2__.bsonindexterm, __API_SCHEMA_INTERNAL_V2__.bsonindexterm);
