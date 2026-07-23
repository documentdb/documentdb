SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 199000;
SET documentdb.next_collection_id TO 1990;
SET documentdb.next_collection_index_id TO 1990;

-- Call delete procedure for a non-existent collection (should succeed with 0 deletes)
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"$and":[{"a":5},{"a":{"$gt":0}}]},"limit":0}]}');

-- insert test data
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":1,"_id":1}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":2,"_id":2}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":3,"_id":3}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":4,"_id":4}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":5,"_id":5}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":6,"_id":6}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":7,"_id":7}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":8,"_id":8}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":9,"_id":9}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":10,"_id":10}');

-- exercise invalid delete syntax errors
CALL documentdb_api.delete_txn_proc('delProcDB', NULL);
CALL documentdb_api.delete_txn_proc(NULL, '{"delete":"removeme", "deletes":[{"q":{},"limit":0}]}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"deletes":[{"q":{},"limit":0}]}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme"}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":["removeme"], "deletes":[{"q":{},"limit":0}]}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":{"q":{},"limit":0}}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":0}], "extra":1}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{}}]}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"limit":0}]}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":[],"limit":0}]}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":0,"extra":1}]}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":0}],"ordered":1}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":5}]}');

-- Disallow writes to system.views
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"system.views", "deletes":[{"q":{},"limit":0}]}');

-- delete all
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":0}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- re-insert test data for further tests
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":1,"_id":1}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":2,"_id":2}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":3,"_id":3}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":4,"_id":4}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":5,"_id":5}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":6,"_id":6}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":7,"_id":7}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":8,"_id":8}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":9,"_id":9}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":10,"_id":10}');

-- delete some
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$lte":3}},"limit":0}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- delete all from non-existent collection
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"notexists", "deletes":[{"q":{},"limit":0}]}');

-- query syntax errors are added to the response
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$ltr":5}},"limit":0}]}');

-- when ordered, expect only first delete to be executed
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":4},"limit":0},{"q":{"$a":5},"limit":0},{"q":{"a":6},"limit":0}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":5},"limit":0},{"q":{"$a":6},"limit":0},{"q":{"a":7},"limit":0}],"ordered":true}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- when not ordered, expect first and last delete to be executed
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":6},"limit":0},{"q":{"$a":7},"limit":0},{"q":{"a":8},"limit":0}],"ordered":false}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- delete 1 without filters is supported for unsharded collections
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- delete 1 is retryable on unsharded collection (second call is a noop)
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":1}]}', NULL, 'xact-1');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":1}]}', NULL, 'xact-1');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- delete 1 is supported in the _id case
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":10},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"_id":10}';

-- delete 1 is supported in the multiple identical _id case
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"$and":[{"_id":9},{"_id":9}]},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"_id":9}';

-- delete 1 is supported in the multiple distinct _id case (but a noop)
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"$and":[{"_id":9},{"_id":5}]},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- delete with spec in special section
select count(*) from documentdb_api.collection('delProcDB', 'removeme');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":20,"_id":20}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme"}', '{ "":[{"q":{"a":{"$eq":20}},"limit":1}] }');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"a":20}';

-- deletes with both specs specified
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes": [{"q":{"a":{"$eq":20}},"limit":1}] }', '{ "":[{"q":{"a":{"$eq":20}},"limit":1}] }');

-- shard the collection
select documentdb_api.shard_collection('delProcDB', 'removeme', '{"a":"hashed"}', false);

-- make sure we get the expected results after sharding a collection
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$lte":3}},"limit":0}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"a":1}';
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- test pruning logic in delete
set citus.log_remote_commands to on;
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$eq":5}},"limit":0}]}');
reset citus.log_remote_commands;
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"a":5}';

set citus.log_remote_commands to on;
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"$and":[{"a":7},{"a":{"$gt":0}}]},"limit":0}]}');
reset citus.log_remote_commands;
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"a":7}';

-- delete 1 without filters is unsupported for sharded collections
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":1}]}');

-- delete 1 with shard key filters is supported for sharded collections
set citus.log_remote_commands to on;
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":5,"_id":5}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$eq":5}},"limit":1}]}');
reset citus.log_remote_commands;
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"a":5}';

-- delete 1 with shard key filters is retryable
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":5,"_id":5}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$eq":5}},"limit":1}]}', NULL, 'xact-2');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$eq":5}},"limit":1}]}', NULL, 'xact-2');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"a":5}';

-- delete 1 that does not match any rows is still retryable
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$eq":15}},"limit":1}]}', NULL, 'xact-3');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":15,"_id":15}');
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"a":{"$eq":15}},"limit":1}]}', NULL, 'xact-3');

-- delete 1 is supported in the _id case even on sharded collections
-- add an additional _id 10
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":11,"_id":10}');
-- delete first row where _id = 10
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":10},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"_id":10}';
-- delete second row where _id = 10 (the original)
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":10},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"_id":10}';
-- no more row where _id = 10
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":10},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"_id":10}';

-- delete 1 with _id filter on a sharded collection is retryable
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":11,"_id":10}');
-- delete first row where _id = 10
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":10},"limit":1}]}', NULL, 'xact-4');
-- second time is a noop
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":10},"limit":1}]}', NULL, 'xact-4');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"_id":10}';

-- delete 1 is supported in the multiple identical _id case
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"$and":[{"_id":15},{"_id":15}]},"limit":1}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme') where document @@ '{"_id":15}';

-- delete 1 is unsupported in the multiple distinct _id case
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"$and":[{"_id":15},{"_id":5}]},"limit":1}]}');

-- delete with index hint specified by name and by key object
SELECT documentdb_api_internal.create_indexes_non_concurrently('delProcDB', '{ "createIndexes": "removeme", "indexes": [ { "key" : { "a": 1 }, "name": "validIndex"}] }', true);

CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":0,"hint": "validIndex"}]}');
select count(*) from documentdb_api.collection('delProcDB', 'removeme');

-- show that we validate "query" document even if collection doesn't exist
-- i) ordered=true
CALL documentdb_api.delete_txn_proc(
    'delProcDB',
    '{
        "delete": "dne",
        "deletes": [
            {"q": {"a": 1}, "limit": 0 },
            {"q": {"$b": 1}, "limit": 0 },
            {"q": {"c": 1}, "limit": 0 },
            {"q": {"$d": 1}, "limit": 0 },
            {"q": {"e": 1}, "limit": 0 }
        ],
        "ordered": true
     }'
);
-- ii) ordered=false
CALL documentdb_api.delete_txn_proc(
    'delProcDB',
    '{
        "delete": "dne",
        "deletes": [
            {"q": {"a": 1}, "limit": 0 },
            {"q": {"$b": 1}, "limit": 0 },
            {"q": {"c": 1}, "limit": 0 },
            {"q": {"$d": 1}, "limit": 0 },
            {"q": {"e": 1}, "limit": 0 }
        ],
        "ordered": false
     }'
);

SELECT documentdb_api.create_collection('delProcDB', 'no_match');

-- show that we validate "query" document even if we can't match any documents
-- i) ordered=true
CALL documentdb_api.delete_txn_proc(
    'delProcDB',
    '{
        "delete": "no_match",
        "deletes": [
            {"q": {"a": 1}, "limit": 0 },
            {"q": {"$b": 1}, "limit": 0 },
            {"q": {"c": 1}, "limit": 0 },
            {"q": {"$d": 1}, "limit": 0 },
            {"q": {"e": 1}, "limit": 0 }
        ],
        "ordered": true
     }'
);
-- ii) ordered=false
CALL documentdb_api.delete_txn_proc(
    'delProcDB',
    '{
        "delete": "no_match",
        "deletes": [
            {"q": {"a": 1}, "limit": 0 },
            {"q": {"$b": 1}, "limit": 0 },
            {"q": {"c": 1}, "limit": 0 },
            {"q": {"$d": 1}, "limit": 0 },
            {"q": {"e": 1}, "limit": 0 }
        ],
        "ordered": false
     }'
);

-- test subtransaction behavior via DEBUG1 messages
-- re-insert some data
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":30,"_id":30}');
select 1 from documentdb_api.insert_one('delProcDB', 'removeme', '{"a":31,"_id":31}');

SET client_min_messages TO 'DEBUG1';

-- single delete with transaction id should use subtransaction
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":30},"limit":1}]}', NULL, 'subtxn-test');

-- single delete without transaction id should not use subtransaction
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"_id":31},"limit":1}]}');

-- test failed delete with non-subtransactional path (query error)
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{"$a":1},"limit":0}]}');

RESET client_min_messages;

-- Run inside transaction should fail
BEGIN;
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"removeme", "deletes":[{"q":{},"limit":0}]}');
END;

-- Operator-intervention errors (error class 57, e.g. statement cancellation) that
-- occur while a delete is executing must propagate out of the procedure
-- (ReThrowError) instead of being captured as a per-statement writeErrors entry.
-- Make the cancellation deterministic: attach a slow BEFORE DELETE trigger to the
-- backing data table so the delete blocks in pg_sleep, then set a statement_timeout
-- far below the sleep. The timeout fires inside the delete on every host, so the
-- CALL always errors with ERRCODE_QUERY_CANCELED and leaves the documents in place.
SELECT documentdb_api.create_collection('delProcDB', 'timeout_test');
select 1 from documentdb_api.insert_one('delProcDB', 'timeout_test', '{"_id":1,"a":1}');
select 1 from documentdb_api.insert_one('delProcDB', 'timeout_test', '{"_id":2,"a":2}');
select 1 from documentdb_api.insert_one('delProcDB', 'timeout_test', '{"_id":3,"a":3}');

-- Citus requires unsafe triggers to be enabled to place a trigger on a
-- distributed table; it propagates the trigger to the shards.
SET citus.enable_unsafe_triggers TO on;
CREATE FUNCTION delproc_delete_delay() RETURNS trigger LANGUAGE plpgsql AS
$fn$ BEGIN PERFORM pg_sleep(60); RETURN OLD; END; $fn$;
DO $do$
DECLARE data_table text;
BEGIN
    SELECT format('documentdb_data.documents_%s', collection_id)
      INTO data_table
      FROM documentdb_api_catalog.collections
     WHERE database_name = 'delProcDB' AND collection_name = 'timeout_test';
    EXECUTE format('CREATE TRIGGER delproc_delete_delay_trg BEFORE DELETE ON %s '
                   'FOR EACH ROW EXECUTE FUNCTION delproc_delete_delay()', data_table);
END;
$do$;

SET statement_timeout TO 1000;
\set VERBOSITY terse
CALL documentdb_api.delete_txn_proc('delProcDB', '{"delete":"timeout_test", "deletes":[{"q":{},"limit":0}]}');
\set VERBOSITY default
RESET statement_timeout;
-- All documents remain because the aborted delete committed nothing.
select count(*) from documentdb_api.collection('delProcDB', 'timeout_test');

-- cleanup
select documentdb_api.drop_collection('delProcDB','removeme');
select documentdb_api.drop_collection('delProcDB','no_match');
select documentdb_api.drop_collection('delProcDB','timeout_test');
