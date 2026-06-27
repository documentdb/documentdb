SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,pg_catalog;

SET citus.next_shard_id TO 87100000;
SET documentdb.next_collection_id TO 87100;
SET documentdb.next_collection_index_id TO 87100;

-- ============================================================================
-- Project push-up before $unwind (with $group) — distributed tests
--
-- Coverage in this file (single-node coverage is in:
--   oss/pg_documentdb/src/test/regress/sql/
--     bson_aggregation_pipeline_tests_project_pushup_before_unwind.sql)
--
--   Section D1 — sharded basic correctness (4 cases)
--   Section D2 — single-shard routing
--   Section D4 — bail-outs preserved on sharded data
--
-- Index pushdown on sharded data (originally Section D3) is omitted: the
-- structural property — that the upstream $match's filter stays bound to
-- the base column even when the synthetic project is injected above it —
-- is already visible in every D1.x EXPLAIN, and is exercised concretely
-- by the single-node test Section 5.1.
--
-- For every positive case we run the pipeline with the GUC off (baseline)
-- and then on, so the result rows in the two outputs document equivalence.
-- A trailing $sort: { _id: 1 } keeps row ordering deterministic across
-- distributed execution.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Dataset (≥4 rows so a hash shard split produces non-trivial groups per
-- worker). Uses the same shape as the single-node test for easy comparison.
-- ----------------------------------------------------------------------------
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'orders_coll',
    '{ "_id": 1, "regionId": "north", "ownerId": "A",
       "noise": "wide-payload-aaaaa",
       "items": [ {"kind": "x", "qty": 1}, {"kind": "y", "qty": 2} ] }');
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'orders_coll',
    '{ "_id": 2, "regionId": "north", "ownerId": "B",
       "noise": "wide-payload-bbbbb",
       "items": [ {"kind": "x", "qty": 3} ] }');
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'orders_coll',
    '{ "_id": 3, "regionId": "south", "ownerId": "A",
       "noise": "wide-payload-ccccc",
       "items": [ {"kind": "x", "qty": 4}, {"kind": "z", "qty": 5} ] }');
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'orders_coll',
    '{ "_id": 4, "regionId": "north", "ownerId": "B",
       "noise": "wide-payload-ddddd",
       "items": [ {"kind": "y", "qty": 6}, {"kind": "x", "qty": 7} ] }');


-- ============================================================================
-- Section D1 — sharded basic correctness
-- ============================================================================

-- D1.1 Sharded by _id (hash). Canonical pipeline; per-shard project applies
-- locally, cross-shard hash aggregate combines results.
SELECT documentdb_api.shard_collection('proj_pushup_dist_db', 'orders_coll', '{ "_id": "hashed" }', false);

SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO off;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$match": { "regionId": "north" } },
        { "$unwind": "$items" },
        { "$match": { "items.kind": "x" } },
        { "$group": { "_id": "$ownerId" } },
        { "$sort": { "_id": 1 } }
    ],
    "cursor": {}
}');

SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO on;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$match": { "regionId": "north" } },
        { "$unwind": "$items" },
        { "$match": { "items.kind": "x" } },
        { "$group": { "_id": "$ownerId" } },
        { "$sort": { "_id": 1 } }
    ],
    "cursor": {}
}');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$match": { "regionId": "north" } },
        { "$unwind": "$items" },
        { "$match": { "items.kind": "x" } },
        { "$group": { "_id": "$ownerId" } }
    ],
    "cursor": {}
}');


-- D1.2 Sharded by ownerId (the group key) — co-located group. Each worker
-- owns one group's full data; no cross-shard combine needed.
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'orders_colocated',
    '{ "_id": 1, "ownerId": "A", "items": [ {"qty": 1}, {"qty": 2} ] }');
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'orders_colocated',
    '{ "_id": 2, "ownerId": "B", "items": [ {"qty": 3}, {"qty": 4} ] }');
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'orders_colocated',
    '{ "_id": 3, "ownerId": "A", "items": [ {"qty": 5} ] }');
SELECT documentdb_api.shard_collection('proj_pushup_dist_db', 'orders_colocated', '{ "ownerId": "hashed" }', false);

SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO off;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_colocated",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId", "total": { "$sum": "$items.qty" } } },
        { "$sort": { "_id": 1 } }
    ],
    "cursor": {}
}');

SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO on;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_colocated",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId", "total": { "$sum": "$items.qty" } } },
        { "$sort": { "_id": 1 } }
    ],
    "cursor": {}
}');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_colocated",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId", "total": { "$sum": "$items.qty" } } }
    ],
    "cursor": {}
}');


-- D1.3 Sharded by _id, grouping by a non-shard-key (ownerId). Citus must
-- compute partial groups per worker, then reduce on the coordinator.
SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO off;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId", "total": { "$sum": "$items.qty" } } },
        { "$sort": { "_id": 1 } }
    ],
    "cursor": {}
}');

SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO on;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId", "total": { "$sum": "$items.qty" } } },
        { "$sort": { "_id": 1 } }
    ],
    "cursor": {}
}');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId", "total": { "$sum": "$items.qty" } } }
    ],
    "cursor": {}
}');


-- D1.4 Sharded by _id, universal aggregate ($group _id: null). Every
-- worker contributes a partial count; coordinator sums them.
SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO off;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": null, "n": { "$sum": 1 } } }
    ],
    "cursor": {}
}');

SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO on;
SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": null, "n": { "$sum": 1 } } }
    ],
    "cursor": {}
}');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$unwind": "$items" },
        { "$group": { "_id": null, "n": { "$sum": 1 } } }
    ],
    "cursor": {}
}');


-- ============================================================================
-- Section D2 — single-shard routing
-- ============================================================================

-- D2.1 Sharded by _id; $match{_id:<const>} pins the query to one shard.
-- Citus should route to a single worker; verify the synthetic project still
-- appears in the per-worker plan.
SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO on;

SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$match": { "_id": 1 } },
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId" } }
    ],
    "cursor": {}
}');

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$match": { "_id": 1 } },
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId" } }
    ],
    "cursor": {}
}');


-- ============================================================================
-- Section D4 — bail-outs preserved on sharded data
-- ============================================================================

-- D4.1 Sharded + $lookup. joinStatus = HasJoinsOrUnions bail must still
-- fire — no synthetic $project between scan and $unwind.
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'lookup_target',
    '{ "_id": 1, "ownerId": "A", "name": "Alice" }');
SELECT documentdb_api.insert_one('proj_pushup_dist_db', 'lookup_target',
    '{ "_id": 2, "ownerId": "B", "name": "Bob" }');

SET documentdb.enableProjectPushUpBeforeUnwindWithGroup TO on;

EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$lookup": { "from": "lookup_target", "localField": "ownerId", "foreignField": "ownerId", "as": "owner_doc" } },
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId" } }
    ],
    "cursor": {}
}');


-- D4.2 Sharded + $unionWith — same bail must fire.
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('proj_pushup_dist_db', '{
    "aggregate": "orders_coll",
    "pipeline": [
        { "$unionWith": { "coll": "lookup_target" } },
        { "$unwind": "$items" },
        { "$group": { "_id": "$ownerId" } }
    ],
    "cursor": {}
}');


-- ============================================================================
-- Clean up
-- ============================================================================

SELECT documentdb_api.drop_collection('proj_pushup_dist_db', 'orders_coll');
SELECT documentdb_api.drop_collection('proj_pushup_dist_db', 'orders_colocated');
SELECT documentdb_api.drop_collection('proj_pushup_dist_db', 'lookup_target');
