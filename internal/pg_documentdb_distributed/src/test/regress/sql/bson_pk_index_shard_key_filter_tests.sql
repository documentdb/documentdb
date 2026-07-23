SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 1840000;
SET documentdb.next_collection_id TO 18400;
SET documentdb.next_collection_index_id TO 18400;

-- This test exercises the documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters GUC.
-- When enabled, for an unsharded collection we no longer unconditionally inject the
-- 'shard_key_value = <collectionId>' constant filter on the base table. Instead the
-- shard_key_value filter is only added together with a primary key (_id) filter so that
-- the primary key index (_id_, a btree over (shard_key_value, object_id)) can still be
-- used. This test verifies that the scenarios that touch the primary key index keep
-- selecting / pushing to the _id_ index when the GUC is enabled, both for a collection
-- created with native colocation on (the default) and one created with it off.
--
-- Behavior summary (GUC enabled, bitmap scans disabled) - does the stage push to the _id_ index?
-- The native-colocation collection plans locally on the coordinator; the colocation-off
-- collection plans as a Citus Adaptive (distributed) query whose shard sub-plan is shown.
-- With the GUC enabled the 'shard_key_value = <collectionId>' constant predicate is dropped
-- on the base table (under local execution) for any query that does NOT carry an _id filter,
-- EXCEPT for stages that order by _id ($group / $sort / $distinct on _id): there the order-by
-- pushdown re-adds the shard_key_value qual solely to anchor the _id_ index's leading column.
-- For a distributed (colocation-off) collection Citus independently re-adds shard_key_value as
-- its mandatory shard-routing predicate on the shard query, which anchors the _id_ index's
-- leading column even when no _id filter is supplied.
--
-- This test also disables bitmap scans (SET enable_bitmapscan = off) so that an _id order-by is
-- served by an ORDERED Index Scan using _id_ with the sort pushed down to the index, rather than
-- an unordered Bitmap Index Scan that would force an explicit Sort node on top. This keeps the
-- plans deterministic across PostgreSQL versions and row-count estimates.
--
--   Stage / query                          | colocated (pk_native)   | non-colocated (pk_nocolo)
--   ---------------------------------------+-------------------------+--------------------------
--   (1) count, no filter ($count)          | YES (Index Only Scan    | YES (Index Only Scan
--                                          |      using _id_)         |      using _id_)
--   (2) match/find with _id filter ($in)   | YES (Index Scan _id_)   | YES (Index Scan _id_)
--   (3) $lookup join on _id                | YES (driving Seq Scan,  | YES (colocated join,
--                                          |      probe Index Scan    |      Index Scan _id_,
--                                          |      _id_ with Index Cond |      Index Cond carries
--                                          |      carrying shard_key  |      shard_key_value +
--                                          |      _value + object_id) |      object_id)
--   (3b) $lookup non-_id local field ->    | YES (right-id-only path, | YES (right-id-only path,
--        foreign _id (localField "a")      |      probe object_id via |      probe object_id via
--                                          |      bson_dollar_in with |      bson_dollar_in with
--                                          |      shard_key_value +    |      shard_key_value +
--                                          |      object_id)          |      object_id)
--   (4a) $group on _id, no _id filter      | YES (ordered Index Scan | YES (ordered Index Scan
--                                          |      _id_ feeds the       |      _id_ feeds the
--                                          |      GroupAggregate, no   |      GroupAggregate, no
--                                          |      inner sort; $sort    |      inner sort; $sort
--                                          |      materialized on top) |      materialized on top)
--   (4b) $group on _id, with _id filter     | YES (Index Scan _id_)   | YES (Index Scan _id_)
--   (5a) $sort on _id, no _id filter       | YES (Index Scan _id_,   | YES (Index Scan _id_,
--                                          |      sort pushed down -   |      sort pushed down -
--                                          |      no Sort node)        |      no Sort node)
--   (5b) $sort on _id, with _id filter     | YES (Index Scan _id_,   | YES (Index Scan _id_,
--                                          |      sort pushed down)  |      sort pushed down)
--   (6) $merge keyed on _id                | YES (Index Scan _id_)   | YES (Index Scan _id_)
--   (7) $out keyed on _id                  | YES (Index Scan _id_)   | YES (Index Scan _id_)
--   (8) $unionWith + trailing $match _id   | NO  (trailing _id match | NO  (trailing _id match
--                                          |      stays a post-union  |      stays a post-union
--                                          |      document filter on  |      document filter; each
--                                          |      a Seq Scan of each   |      branch's _id_ Index
--                                          |      branch - not pushed  |      Scan carries only
--                                          |      to the _id_ index)   |      Citus's shard_key
--                                          |                          |      routing, _id=5 is a
--                                          |                          |      heap filter)
--   (9) $distinct on _id, no filter        | YES (Index Scan _id_)   | YES (Index Scan _id_)
--
-- Key takeaway: with the GUC enabled, every stage that carries an _id (primary key) filter
-- uses the _id_ index in both colocation modes - scenarios (2), (4b), (5b), (6) and (7). A
-- filter-less $group / $sort / $distinct on _id also uses the _id_ index: the order-by pushdown
-- path re-adds the 'shard_key_value = <collectionId>' qual on the base table (solely to anchor
-- the _id_ index's leading column) even though no _id filter was supplied. Because bitmap scans
-- are disabled, the planner picks an ORDERED Index Scan using _id_ whose index order satisfies
-- the requested _id ordering - so a filter-less $sort has no Sort node at all, a $group feeds the
-- GroupAggregate directly with no inner Sort (only the explicit trailing $sort is materialized),
-- and $distinct streams the _id_ index. For a non-colocated (distributed) collection, Citus
-- independently re-adds shard_key_value as its mandatory shard-routing predicate on the shard
-- query, so the same stages keep the ordered _id_ index. Because each remote EXPLAIN runs on a
-- worker, the GUCs (including enable_bitmapscan = off) must be propagated with SET LOCAL inside a
-- transaction (see citus.propagate_set_commands below); a plain session-level SET would NOT reach
-- the worker and the remote plan would reflect the GUC defaults instead.
--
-- Note on bitmap scans: without disabling them, a filter-less _id order-by still uses the _id_
-- index but as an unordered Bitmap Index Scan, which cannot preserve index order - so PostgreSQL
-- adds an explicit Sort node even though the index is used. The ordered Index Scan that eliminates
-- that Sort is only chosen when a bitmap scan is not an option (as here) or when an _id filter
-- narrows the scan (scenarios 4b / 5b). This test disables bitmap scans so the sort is pushed to
-- the _id_ index in every filter-less _id order-by case.
--
-- Scenario (8) is a known exception: an _id $match placed AFTER a $unionWith is not pushed into
-- the per-branch object_id _id_ index. The branches project only the document column, so the
-- trailing match is applied on the union output as a document-level BSON filter that Postgres
-- pushes down through the UNION ALL onto each branch scan - but as a 'document @= { _id: 5 }'
-- filter, never as an object_id Index Cond. The colocated branches fall back to a Seq Scan; the
-- distributed branches still scan the _id_ index, but only for Citus's 'shard_key_value =' routing
-- predicate, with _id = 5 remaining a heap filter. (To use the _id_ index for the value, the _id
-- match must be inside the $unionWith sub-pipeline / before the union so it is inlined into each
-- base table query - see scenarios (2) and (6).)
--
-- INVARIANT (now upheld by scenario 3 in both modes): the _id_ primary key index is a btree over
-- (shard_key_value, object_id). Any Index Cond / Recheck Cond that filters object_id MUST also
-- carry the matching 'shard_key_value =' qual. The native $lookup probe plan below pushes the
-- join key on object_id together with its 'shard_key_value = <collId>' anchor, so the scan is
-- confined to the correct shard_key_value (it can no longer range over every shard_key_value in
-- the index, nor match rows from a different logical collection sharing the shard). The
-- non-colocated $lookup (scenario 3, right column) likewise carries
-- '(shard_key_value = <collId>) AND (object_id = ...)'.

SET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters TO on;

-- Pushing a $group / sort on _id down to the primary key index requires this companion GUC.
SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;

-- avoid sequential scans being preferred on small tables so the index choice is visible
SET enable_seqscan TO off;
SET documentdb.forceUseIndexIfAvailable TO on;
-- Disable bitmap scans so an _id order-by ($group / $sort / $distinct on _id) is served by an
-- ordered Index Scan using the _id_ primary key index (with the sort pushed down to the index)
-- instead of an unordered Bitmap Index Scan that would force an explicit Sort node on top. A
-- bitmap scan can never satisfy the requested ordering, so keeping it enabled leaves a residual
-- Sort even though the _id_ index is used; disabling it also keeps the plans stable across
-- PostgreSQL versions / row-count estimates.
SET enable_bitmapscan TO off;

-- A session-level SET is NOT propagated to Citus worker tasks, so any EXPLAIN whose plan is a
-- remote 'Custom Scan (Citus Adaptive)' would otherwise be generated on the worker with the
-- GUC defaults (i.e. as if the feature were off). Enable propagation of SET LOCAL commands so
-- that the remote EXPLAINs below - which re-apply the GUCs with SET LOCAL inside a
-- transaction - plan the shard fragment with the feature actually enabled.
SET citus.propagate_set_commands TO 'local';

----------------------------------------------------------------------------------------
-- Scenario set 1: default (native colocation enabled) unsharded collection
----------------------------------------------------------------------------------------
SELECT documentdb_api.create_collection('pkdb', 'pk_native');

SELECT COUNT(documentdb_api.insert_one('pkdb', 'pk_native', bson_build_document('_id'::text, i, 'a'::text, i % 10, 'val'::text, i))) FROM generate_series(1, 5000) i;

ANALYZE documentdb_data.documents_18400;

-- (1) count with no filters. The count command path is served from the collection-stats
-- fast path, so to exercise the base-table count we run a $count aggregation pipeline; the
-- underlying count over the unsharded collection uses the _id index (index only scan over
-- _id_) rather than a sequential scan when the GUC is enabled.
SELECT document FROM bson_aggregation_pipeline('pkdb', '{ "aggregate": "pk_native", "pipeline": [ { "$count": "total" } ], "cursor": {} }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb', '{ "aggregate": "pk_native", "pipeline": [ { "$count": "total" } ], "cursor": {} }');

-- (2) match (find) with an _id filter should use the primary key index. The shard key
-- filter is re-added alongside the _id filter so the index cond covers (shard_key_value, object_id).
SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native", "filter": { "_id": 5 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native", "filter": { "_id": 5 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native", "filter": { "_id": { "$in": [ 5, 6, 7 ] } } }');

-- (3) $lookup joining on _id. With the GUC enabled the driving side is a Seq Scan and the probe
-- (inner) side joins on object_id via an Index Scan on _id_. This plan runs on a remote (Citus
-- Adaptive) task, so the GUCs are re-applied with SET LOCAL inside a transaction (propagated to
-- the worker) before the EXPLAIN.
-- The probe-side Index Cond reads
--   '(shard_key_value = <collId>) AND (object_id = collection.object_id)'.
-- The _id_ primary key index is a btree over (shard_key_value, object_id), so an Index Cond that
-- filters object_id MUST also carry the matching shard_key_value qual; the $lookup base table now
-- pairs the join key on object_id with its 'shard_key_value =' anchor, so the probe is confined to
-- the correct shard_key_value (it can no longer scan every shard_key_value in the index, nor match
-- rows from a different logical collection sharing the shard).
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_native", "pipeline": [ { "$lookup": { "from": "pk_native", "localField": "_id", "foreignField": "_id", "as": "matched" } } ], "cursor": {} }')
$cmd$);
ROLLBACK;

-- (3b) $lookup joining a non-_id local field onto the foreign _id (foreignField = "_id",
-- localField = "a"). This takes the right-id-only path: the probe matches object_id with a
-- bson_dollar_in (ScalarArrayOp) over the extracted local values rather than the direct
-- equality used when both sides are _id. The same shard_key_value anchor must still accompany
-- the object_id filter on the probe-side _id_ index.
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_native", "pipeline": [ { "$lookup": { "from": "pk_native", "localField": "a", "foreignField": "_id", "as": "matched" } } ], "cursor": {} }')
$cmd$);
ROLLBACK;

-- (4) $group on _id. With the GUC enabled, the order-by pushdown re-adds the shard_key_value
-- qual on the base table (only to anchor the _id_ index) even without an _id filter. Because
-- bitmap scans are disabled, the group is served by an ordered Index Scan using _id_ that feeds
-- the GroupAggregate directly (the grouping is satisfied by the index order, so no inner Sort is
-- needed); the explicit $sort on the _id ordering expression is still materialized on top.
-- Adding an _id filter keeps the same ordered Index Scan using _id_.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_native", "pipeline": [ { "$group": { "_id": "$_id", "c": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_native", "pipeline": [ { "$match": { "_id": { "$gt": 0 } } }, { "$group": { "_id": "$_id", "c": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }');

-- (5) $sort on just _id. With the GUC enabled the order-by pushdown re-adds the shard_key_value
-- qual (only to anchor the _id_ index) and, with bitmap scans disabled, a filter-less $sort is
-- served directly by an ordered Index Scan using _id_ (Index Scan Backward for descending) with
-- the sort pushed down to the index - no separate Sort node. Supplying an _id filter keeps the
-- same ordered Index Scan using _id_ for both filtering and ordering.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native", "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native", "sort": { "_id": -1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native", "filter": { "_id": { "$gt": 0 } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native", "filter": { "_id": { "$gt": 0 } }, "sort": { "_id": -1 } }');

-- (6) $merge relying on _id should work with the primary key index.
SELECT documentdb_api.create_collection('pkdb', 'pk_native_merge_target');
SELECT * FROM documentdb_api.aggregate_cursor_first_page('pkdb',
    '{ "aggregate": "pk_native", "pipeline": [ { "$match": { "_id": { "$lte": 5 } } }, { "$merge": { "into": "pk_native_merge_target", "on": "_id" } } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native_merge_target", "sort": { "_id": 1 } }');

-- (7) $out relying on _id should work with the primary key index.
SELECT * FROM documentdb_api.aggregate_cursor_first_page('pkdb',
    '{ "aggregate": "pk_native", "pipeline": [ { "$match": { "_id": { "$lte": 5 } } }, { "$out": "pk_native_out_target" } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_native_out_target", "sort": { "_id": 1 } }');

-- (8) $unionWith followed by a $match on _id. The trailing _id match is NOT pushed into the
-- per-branch object_id _id_ index: the $unionWith branches project only the document column, so
-- the match is applied on the union output as a 'document @= { _id: 5 }' BSON filter that Postgres
-- pushes down through the UNION ALL onto each branch as a recheck filter (not an object_id Index
-- Cond). For the colocated branches this falls back to a Seq Scan with that document filter.
SELECT documentdb_api.create_collection('pkdb', 'pk_native_union');
SELECT COUNT(documentdb_api.insert_one('pkdb', 'pk_native_union', bson_build_document('_id'::text, i, 'a'::text, i % 10, 'val'::text, i))) FROM generate_series(1, 5000) i;
SELECT collection_id AS native_union_id FROM documentdb_api_catalog.collections WHERE database_name = 'pkdb' AND collection_name = 'pk_native_union' \gset
SELECT FORMAT('ANALYZE documentdb_data.documents_%s', :native_union_id) \gexec
SELECT document FROM bson_aggregation_pipeline('pkdb', '{ "aggregate": "pk_native", "pipeline": [ { "$unionWith": { "coll": "pk_native_union" } }, { "$match": { "_id": 5 } } ], "cursor": {} }');
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_native", "pipeline": [ { "$unionWith": { "coll": "pk_native_union" } }, { "$match": { "_id": 5 } } ], "cursor": {} }')
$cmd$);
ROLLBACK;

-- (9) $distinct on _id. Distinct on the primary key extracts an ordered stream of _id values,
-- so it takes the same order-by pushdown path as $sort / $group: with the GUC enabled and no
-- query filter the shard key filter is re-added on the base table (only for the _id order-by
-- pushdown), and with bitmap scans disabled the _id_ primary key index feeds the distinct via an
-- ordered Index Scan using _id_ instead of a Seq Scan. Adding a query predicate on _id keeps the
-- same ordered Index Scan using _id_.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('pkdb', '{ "distinct": "pk_native", "key": "_id" }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('pkdb', '{ "distinct": "pk_native", "key": "_id", "query": { "_id": { "$gt": 0 } } }');

----------------------------------------------------------------------------------------
-- Scenario set 2: same characteristics for a collection created with native colocation off
----------------------------------------------------------------------------------------
SET documentdb.enableNativeColocation TO off;
SELECT documentdb_api.create_collection('pkdb', 'pk_nocolo');

SELECT COUNT(documentdb_api.insert_one('pkdb', 'pk_nocolo', bson_build_document('_id'::text, i, 'a'::text, i % 10, 'val'::text, i))) FROM generate_series(1, 5000) i;

SELECT collection_id AS nocolo_id FROM documentdb_api_catalog.collections WHERE database_name = 'pkdb' AND collection_name = 'pk_nocolo' \gset
SELECT FORMAT('ANALYZE documentdb_data.documents_%s', :nocolo_id) \gexec

-- All queries against the colocation-off collection plan as remote (Citus Adaptive) tasks, so
-- every EXPLAIN below re-applies the GUCs with SET LOCAL inside a transaction (propagated to
-- the worker) so the shard fragment is planned with the feature enabled.

-- (1) count with no filters (via a $count aggregation pipeline). On the distributed shard Citus
-- supplies the shard_key_value routing predicate, which anchors the _id_ index, so the count
-- over the distributed shard uses the _id index (Index Only Scan using _id_) rather than a Seq Scan.
SELECT document FROM bson_aggregation_pipeline('pkdb', '{ "aggregate": "pk_nocolo", "pipeline": [ { "$count": "total" } ], "cursor": {} }');
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb', '{ "aggregate": "pk_nocolo", "pipeline": [ { "$count": "total" } ], "cursor": {} }');
ROLLBACK;

-- (2) match with _id filter uses the primary key index.
SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo", "filter": { "_id": 5 } }');
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo", "filter": { "_id": 5 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo", "filter": { "_id": { "$in": [ 5, 6, 7 ] } } }');
ROLLBACK;

-- (3) $lookup joining on _id. On the distributed shard Citus supplies the shard_key_value
-- routing predicate, so the two sides stay colocated and the join uses the _id_ index. Unlike
-- the colocated/local case (scenario 3 above), the probe-side Index Cond here correctly carries
-- '(shard_key_value = <collId>) AND (object_id = ...)' - i.e. the object_id filter is paired
-- with its shard_key_value, as the (shard_key_value, object_id) index requires.
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_nocolo", "pipeline": [ { "$lookup": { "from": "pk_nocolo", "localField": "_id", "foreignField": "_id", "as": "matched" } } ], "cursor": {} }')
$cmd$);
ROLLBACK;

-- (3b) $lookup joining a non-_id local field onto the foreign _id (foreignField = "_id",
-- localField = "a"). Right-id-only path with a bson_dollar_in (ScalarArrayOp) probe. On the
-- distributed shard Citus supplies the shard_key_value routing predicate, so the probe-side
-- Index Cond carries '(shard_key_value = <collId>) AND (object_id = ...)'.
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_nocolo", "pipeline": [ { "$lookup": { "from": "pk_nocolo", "localField": "a", "foreignField": "_id", "as": "matched" } } ], "cursor": {} }')
$cmd$);
ROLLBACK;

-- (4) $group on _id. On the distributed shard Citus always supplies the shard_key_value
-- routing predicate, which anchors the ordered _id_ index; with bitmap scans disabled the group
-- is served by an ordered Index Scan using _id_ that feeds the GroupAggregate directly (no inner
-- Sort). The explicit $sort on the _id ordering expression is still materialized on top. Adding
-- an _id filter keeps the same ordered Index Scan using _id_.
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_nocolo", "pipeline": [ { "$group": { "_id": "$_id", "c": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_nocolo", "pipeline": [ { "$match": { "_id": { "$gt": 0 } } }, { "$group": { "_id": "$_id", "c": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }');
ROLLBACK;

-- (5) $sort on just _id. Unlike the colocated/local case (Seq Scan + Sort), the distributed
-- shard query carries Citus's shard_key_value routing predicate, which anchors the ordered
-- _id_ index - so even a filter-less $sort is served by an Index Scan using _id_ (Index Scan
-- Backward for descending) with the sort pushed down. Supplying an _id filter keeps the
-- ordered Index Scan using _id_.
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo", "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo", "sort": { "_id": -1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo", "filter": { "_id": { "$gt": 0 } }, "sort": { "_id": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo", "filter": { "_id": { "$gt": 0 } }, "sort": { "_id": -1 } }');
ROLLBACK;

-- (6) $merge relying on _id works with the primary key index.
SELECT * FROM documentdb_api.aggregate_cursor_first_page('pkdb',
    '{ "aggregate": "pk_nocolo", "pipeline": [ { "$match": { "_id": { "$lte": 5 } } }, { "$merge": { "into": "pk_nocolo_merge_target", "on": "_id" } } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo_merge_target", "sort": { "_id": 1 } }');

-- (7) $out relying on _id works with the primary key index.
SELECT * FROM documentdb_api.aggregate_cursor_first_page('pkdb',
    '{ "aggregate": "pk_nocolo", "pipeline": [ { "$match": { "_id": { "$lte": 5 } } }, { "$out": "pk_nocolo_out_target" } ], "cursor": { "batchSize": 1 } }', 4294967294);
SELECT document FROM bson_aggregation_find('pkdb', '{ "find": "pk_nocolo_out_target", "sort": { "_id": 1 } }');

-- (8) $unionWith followed by a $match on _id. As in the colocated case, the trailing _id match is
-- not pushed into the per-branch object_id _id_ index. Each distributed branch still scans the
-- _id_ index, but only for Citus's mandatory 'shard_key_value =' routing predicate; the _id = 5
-- value stays a 'document @= { _id: 5 }' heap filter on top of the ordered Index Scan using _id_.
SELECT documentdb_api.create_collection('pkdb', 'pk_nocolo_union');
SELECT COUNT(documentdb_api.insert_one('pkdb', 'pk_nocolo_union', bson_build_document('_id'::text, i, 'a'::text, i % 10, 'val'::text, i))) FROM generate_series(1, 5000) i;
SELECT collection_id AS nocolo_union_id FROM documentdb_api_catalog.collections WHERE database_name = 'pkdb' AND collection_name = 'pk_nocolo_union' \gset
SELECT FORMAT('ANALYZE documentdb_data.documents_%s', :nocolo_union_id) \gexec
SELECT document FROM bson_aggregation_pipeline('pkdb', '{ "aggregate": "pk_nocolo", "pipeline": [ { "$unionWith": { "coll": "pk_nocolo_union" } }, { "$match": { "_id": 5 } } ], "cursor": {} }');
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('pkdb',
    '{ "aggregate": "pk_nocolo", "pipeline": [ { "$unionWith": { "coll": "pk_nocolo_union" } }, { "$match": { "_id": 5 } } ], "cursor": {} }')
$cmd$);
ROLLBACK;

-- (9) $distinct on _id. On the distributed shard Citus supplies the shard_key_value routing
-- predicate, which anchors the ordered _id_ index, so distinct on the primary key is served by
-- an Index Scan using _id_ (as with $sort / $group above). Supplying an _id query predicate
-- keeps the ordered Index Scan using _id_.
BEGIN;
set local documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters to on;
set local documentdb.enableGroupByCompoundIdIndexPushdown to on;
set local documentdb.forceUseIndexIfAvailable to on;
set local enable_seqscan to off;
set local enable_bitmapscan to off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('pkdb', '{ "distinct": "pk_nocolo", "key": "_id" }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_distinct('pkdb', '{ "distinct": "pk_nocolo", "key": "_id", "query": { "_id": { "$gt": 0 } } }');
ROLLBACK;

RESET documentdb.enableNativeColocation;
RESET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters;
RESET documentdb.enableGroupByCompoundIdIndexPushdown;
RESET enable_seqscan;
RESET documentdb.forceUseIndexIfAvailable;
RESET citus.propagate_set_commands;
