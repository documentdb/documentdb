
/*
 * __API_SCHEMA_V2__.delete processes a mongo wire protocol delete command.
 */
CREATE OR REPLACE FUNCTION __API_SCHEMA_V2__.delete(
    p_database_name text,
    p_delete __CORE_SCHEMA_V2__.bson,
    p_insert_documents __CORE_SCHEMA_V2__.bsonsequence default NULL,
    p_transaction_id text default NULL,
    p_result OUT __CORE_SCHEMA_V2__.bson,
    p_success OUT boolean)
 RETURNS record
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_delete$$;
COMMENT ON FUNCTION __API_SCHEMA_V2__.delete(text,__CORE_SCHEMA_V2__.bson,__CORE_SCHEMA_V2__.bsonsequence,text)
    IS 'deletes documents from a collection';

/* Command: delete */
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.delete_one(
    p_collection_id bigint,
    p_shard_key_value bigint,
    p_query __CORE_SCHEMA_V2__.bson,
    p_sort __CORE_SCHEMA_V2__.bson,
    p_return_document bool,
    p_return_fields __CORE_SCHEMA_V2__.bson,
    p_transaction_id text,
    OUT o_is_row_deleted bool,
    OUT o_result_deleted_document __CORE_SCHEMA_V2__.bson)
 RETURNS record
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_delete_one$$;
COMMENT ON FUNCTION __API_SCHEMA_INTERNAL_V2__.delete_one(bigint,bigint,__CORE_SCHEMA_V2__.bson,__CORE_SCHEMA_V2__.bson,bool,__CORE_SCHEMA_V2__.bson,text)
    IS 'deletes a single document from a collection';


/* Command: delete */
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.delete_worker(
    p_collection_id bigint,
    p_shard_key_value bigint,
    p_shard_oid regclass,
    p_update_internal_spec __CORE_SCHEMA_V2__.bson,
    p_update_internal_docs __CORE_SCHEMA_V2__.bsonsequence,
    p_transaction_id text)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_delete_worker$$;

/* delete procedure for use outside transactions */
CREATE OR REPLACE PROCEDURE __API_SCHEMA_V2__.delete_txn_proc(
    IN p_database_name text,
    IN p_delete __CORE_SCHEMA_V2__.bson,
    IN p_insert_documents __CORE_SCHEMA_V2__.bsonsequence default NULL,
    IN p_transaction_id text default NULL,
    INOUT p_result __CORE_SCHEMA_V2__.bson default NULL,
    INOUT p_success boolean default NULL)
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_delete_txn_proc$$;
COMMENT ON PROCEDURE __API_SCHEMA_V2__.delete_txn_proc(text,__CORE_SCHEMA_V2__.bson,__CORE_SCHEMA_V2__.bsonsequence,text,__CORE_SCHEMA_V2__.bson,boolean)
    IS 'deletes documents from a collection using a stored procedure, can be run inside a transaction';

#ifdef __RBAC_SCHEMA_ENABLED__
/*
 * documentdb_api_v2.delete processes a mongo wire protocol delete command.
 */
CREATE OR REPLACE FUNCTION documentdb_api_v2.delete(
    p_database_name text,
    p_delete __CORE_SCHEMA_V2__.bson,
    p_insert_documents __CORE_SCHEMA_V2__.bsonsequence default NULL,
    p_transaction_id text default NULL,
    p_result OUT __CORE_SCHEMA_V2__.bson,
    p_success OUT boolean)
 RETURNS record
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_delete$$;
COMMENT ON FUNCTION documentdb_api_v2.delete(text,__CORE_SCHEMA_V2__.bson,__CORE_SCHEMA_V2__.bsonsequence,text)
    IS 'deletes documents from a collection';

/* Command: delete */
CREATE OR REPLACE FUNCTION documentdb_api_internal_readwrite.delete_one(
    p_collection_id bigint,
    p_shard_key_value bigint,
    p_query __CORE_SCHEMA_V2__.bson,
    p_sort __CORE_SCHEMA_V2__.bson,
    p_return_document bool,
    p_return_fields __CORE_SCHEMA_V2__.bson,
    p_transaction_id text,
    OUT o_is_row_deleted bool,
    OUT o_result_deleted_document __CORE_SCHEMA_V2__.bson)
 RETURNS record
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_delete_one$$;
COMMENT ON FUNCTION documentdb_api_internal_readwrite.delete_one(bigint,bigint,__CORE_SCHEMA_V2__.bson,__CORE_SCHEMA_V2__.bson,bool,__CORE_SCHEMA_V2__.bson,text)
    IS 'deletes a single document from a collection';


/* Command: delete */
CREATE OR REPLACE FUNCTION documentdb_api_internal_readwrite.delete_worker(
    p_collection_id bigint,
    p_shard_key_value bigint,
    p_shard_oid regclass,
    p_update_internal_spec __CORE_SCHEMA_V2__.bson,
    p_update_internal_docs __CORE_SCHEMA_V2__.bsonsequence,
    p_transaction_id text)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE C
AS 'MODULE_PATHNAME', $$command_delete_worker$$;
#endif
