SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core;
SET citus.next_shard_id TO 33700;
SET documentdb.next_collection_id TO 3370;
SET documentdb.next_collection_index_id TO 3370;

-- Note: enableLocalRetryTable is a backend-only GUC. It is not yet wired up in
-- the gateway, so the gateway does not set or rely on this flag. These tests
-- validate the backend behavior directly via SQL.
SET documentdb.enableLocalRetryTable to on;

SELECT documentdb_api.create_collection('db', 'collection_without_retry_table');

SELECT collection_id FROM collections where collection_name = 'collection_without_retry_table' AND database_name = 'db' \gset

-- Verify there is no retry_table for this collection
\d documentdb_data.retry_:collection_id;

-- Insert a retry record
SELECT documentdb_api.insert_one('db','collection_without_retry_table','{"_id": 1, "hello":"world"}','xact-retry-1');
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id AND transaction_id = 'xact-retry-1';

-- Retry the same write, should report insert as successful and delete the entry from retryable_writes
SELECT documentdb_api.insert_one('db','collection_without_retry_table','{"_id": 1, "hello":"world"}','xact-retry-1');
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id AND transaction_id = 'xact-retry-1';

-- Retry again should treat this as a new write and should fail with duplicate key error
SELECT documentdb_api.insert_one('db','collection_without_retry_table','{"_id": 1, "hello":"world"}','xact-retry-1');

-- new Id with same transaction id should be treated as a new write and should succeed
SELECT documentdb_api.insert_one('db','collection_without_retry_table','{"_id": 2, "hello":"world"}','xact-retry-1');

SELECT documentdb_api.insert_one('db','collection_without_retry_table','{"_id": 3, "hello":"world"}','xact-retry-2');

SELECT document FROM collection('db', 'collection_without_retry_table');

-- Test update and delete with retryable writes
SELECT documentdb_api.update('db', '{"update": "collection_without_retry_table", "updates":[{"q": {"_id": 1},"u":{"$set":{"hello": "massive_world"}},"multi":false}]}', NULL, 'xact-update-1');
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id AND transaction_id = 'xact-update-1';

-- treated as retry
SELECT documentdb_api.update('db', '{"update": "collection_without_retry_table", "updates":[{"q": {"_id": 1},"u":{"$set":{"hello": "massive_world_2"}},"multi":false}]}', NULL, 'xact-update-1');
SELECT document FROM collection('db', 'collection_without_retry_table') where object_id = '{ "" : 1 }';
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id AND transaction_id = 'xact-update-1';

-- new update with same transaction id should be treated as a new write and should succeed
SELECT documentdb_api.update('db', '{"update": "collection_without_retry_table", "updates":[{"q": {"_id": 1},"u":{"$set":{"hello": "massive_world_2"}},"multi":false}]}', NULL, 'xact-update-1');
SELECT document FROM collection('db', 'collection_without_retry_table') where object_id = '{ "" : 1 }';
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id AND transaction_id = 'xact-update-1';

-- Retryable delete
SELECT documentdb_api.delete('db', '{ "delete": "collection_without_retry_table", "deletes": [ {"q": {"_id": 1 }, "limit": 1 } ]}', NULL, 'xact-delete-1');
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id AND transaction_id = 'xact-delete-1';

SELECT documentdb_api.delete('db', '{ "delete": "collection_without_retry_table", "deletes": [ {"q": {"_id": 1 }, "limit": 1 } ]}', NULL, 'xact-delete-1');
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id AND transaction_id = 'xact-delete-1';

SELECT document FROM collection('db', 'collection_without_retry_table');

-- drop the collection and verify the retryable writes are still not deleted until TTL is added for them
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id;
SELECT drop_collection('db', 'collection_without_retry_table');
SELECT collection_id, shard_key_value, transaction_id, rows_affected FROM documentdb_data.retryable_writes WHERE collection_id = :collection_id;

RESET documentdb.enableLocalRetryTable;