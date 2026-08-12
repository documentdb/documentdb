SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 9700000;
SET documentdb.next_collection_id TO 970000;
SET documentdb.next_collection_index_id TO 970000;

-- Regression coverage for empty $in routing. An empty $in filter must still
-- route to the collection's placement instead of collapsing to a plain false,
-- which previously dropped the shard-key filter and made the write hit zero
-- shards (a shard-routing error). The fix lives in the Citus router, so this
-- suite is gated to the PostgreSQL versions that ship the fixed Citus.
select 1 from documentdb_api.insert_one('db', 'updateme_pg16', '{"a":1,"_id":1,"b":1}');

-- $in on an UNSHARDED collection must route to the collection's single placement
-- and return a clean result in this multinode deployment (the remote unsharded
-- update path), whether the $in has values or is empty. Insert one row, then run
-- updateMany and deleteMany with a filled $in (number, string, mixed) and an
-- empty $in; each should return a clean result.
begin;
-- insert a row
select 1 from documentdb_api.insert_one('db', 'updateme_pg16', '{"a":5, "_id":52, "c":"abc"}');
-- updateMany, non-empty $in that matches: number
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "b":{"$in":[5]}},"u":{"$set":{"u1":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: string
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "c":{"$in":["abc"]}},"u":{"$set":{"u2":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: mixed types (number and string)
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "b":{"$in":[5,"foo"]}},"u":{"$set":{"u3":1}},"multi":true}]}');
-- updateMany, empty $in matches nothing and is a clean no-op
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "c":{"$in":[]}},"u":{"$set":{"u4":1}},"multi":true}]}');
-- deleteMany, empty $in matches nothing, still routes
select documentdb_api.delete('db', '{"delete":"updateme_pg16", "deletes":[{"q":{"a":5, "c":{"$in":[]}},"limit":0}]}');
-- deleteMany, non-empty $in removes the inserted row
select documentdb_api.delete('db', '{"delete":"updateme_pg16", "deletes":[{"q":{"a":5, "c":{"$in":["abc"]}},"limit":0}]}');
select count(*) from documentdb_api.collection('db', 'updateme_pg16') where document @@ '{"a":5}';
rollback;

-- shard the collection
select documentdb_api.shard_collection('db', 'updateme_pg16', '{"a":"hashed"}', false);

-- $in with a shard key filter must route to the shard for updateMany,
-- whether the $in has values or is empty. Before the fix an empty $in became a
-- plain false, which dropped the shard key filter and made the write hit zero
-- shards (a shard-routing error). Insert one row, then run updateMany and
-- deleteMany with a filled $in (number, string, mixed) and an empty $in; each
-- should route to the shard and return a clean result.
begin;
-- insert a row on shard a=5
select 1 from documentdb_api.insert_one('db', 'updateme_pg16', '{"a":5, "_id":50, "c":"abc"}');
-- updateMany, non-empty $in that matches: number
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "b":{"$in":[5]}},"u":{"$set":{"u1":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: string
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "c":{"$in":["abc"]}},"u":{"$set":{"u2":1}},"multi":true}]}');
-- updateMany, non-empty $in that matches: mixed types (number and string)
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "b":{"$in":[5,"foo"]}},"u":{"$set":{"u3":1}},"multi":true}]}');
-- updateMany, empty $in matches nothing (the routing regression case)
select documentdb_api.update('db', '{"update":"updateme_pg16", "updates":[{"q":{"a":5, "c":{"$in":[]}},"u":{"$set":{"u4":1}},"multi":true}]}');
-- deleteMany, empty $in matches nothing, still routes
select documentdb_api.delete('db', '{"delete":"updateme_pg16", "deletes":[{"q":{"a":5, "c":{"$in":[]}},"limit":0}]}');
-- deleteMany, non-empty $in removes the inserted row
select documentdb_api.delete('db', '{"delete":"updateme_pg16", "deletes":[{"q":{"a":5, "c":{"$in":["abc"]}},"limit":0}]}');
select count(*) from documentdb_api.collection('db', 'updateme_pg16') where document @@ '{"a":5}';
rollback;

-- clean up
select documentdb_api.drop_collection('db', 'updateme_pg16');
