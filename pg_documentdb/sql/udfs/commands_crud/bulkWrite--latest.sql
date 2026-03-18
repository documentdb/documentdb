
/*
 * __API_SCHEMA_V2__.bulkWrite processes a documentdb bulkWrite wire-protocol command.
 */
CREATE OR REPLACE PROCEDURE __API_SCHEMA_V2__.bulkWrite(
    IN p_command __CORE_SCHEMA_V2__.bson,
    IN p_ops __CORE_SCHEMA_V2__.bsonsequence DEFAULT NULL,
    IN p_ns_info __CORE_SCHEMA_V2__.bsonsequence DEFAULT NULL,
    INOUT p_result __CORE_SCHEMA_V2__.bson DEFAULT NULL,
    INOUT p_success boolean DEFAULT NULL)
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_bulkWrite$$;
COMMENT ON PROCEDURE __API_SCHEMA_V2__.bulkWrite(__CORE_SCHEMA_V2__.bson, __CORE_SCHEMA_V2__.bsonsequence, __CORE_SCHEMA_V2__.bsonsequence, __CORE_SCHEMA_V2__.bson, boolean)
    IS 'bulkWrite in a non-transactional manner';
