SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal, public;

SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.next_collection_id TO 25900;
SET documentdb.next_collection_index_id TO 25900;

-- $group index pushdown with a $match on a non-group key.
-- Pipeline: $match equality on meta.ownerKey, $group by meta.category with
-- $max of updatedAt, then $sort on the accumulated value and $limit.
-- Two candidate indexes:
--   idx_cat_region_ts: { meta.category: 1, meta.region: 1, updatedAt: -1 }
--       group key is the leading field; the $match filter cannot be pushed.
--   idx_owner_cat_ts:  { meta.ownerKey: 1, meta.category: 1, updatedAt: -1 }
--       $match equality on the leading field followed by the group key, so
--       both the filter and the group ordering can be served by the index.
-- No per-collection planner statistics are collected for the collection.
SELECT COUNT(documentdb_api.insert_one('grp_idx_push_db', 'grp_idx_push',
    bson_build_document(
        '_id'::text, i,
        'meta'::text, bson_build_document(
            'ownerKey'::text, 'owner-' || (i % 2000)::text,
            'category'::text, (i % 30),
            'region'::text, (i % 10)),
        'updatedAt'::text, i)))
FROM generate_series(1, 20000) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('grp_idx_push_db',
  '{ "createIndexes": "grp_idx_push", "indexes": [{ "key": { "meta.category": 1, "meta.region": 1, "updatedAt": -1 }, "name": "idx_cat_region_ts" }] }', true);

SELECT documentdb_api_internal.create_indexes_non_concurrently('grp_idx_push_db',
  '{ "createIndexes": "grp_idx_push", "indexes": [{ "key": { "meta.ownerKey": 1, "meta.category": 1, "updatedAt": -1 }, "name": "idx_owner_cat_ts" }] }', true);

-- Mirror autovacuum: populate table size and default ANALYZE data. Per-collection
-- planner statistics are not enabled for this collection.
VACUUM ANALYZE documentdb_data.documents_25901;

SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SET random_page_cost TO 1.1;

-- Expected results.
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db',
  '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$group": { "_id": "$meta.category", "updatedAt": { "$max": "$updatedAt" } } }, { "$sort": { "updatedAt": -1 } }, { "$limit": 5 } ], "cursor": {} }');

-- idx_owner_cat_ts shares the "meta" prefix, so it uses reduced correlated
-- terms. With order by on its non-leading meta.category path disabled:
-- With enable_full_scan_cost_and_selectivity on, the planner picks
-- idx_cat_region_ts: the group is pushed to the index (ordered scan on
-- meta.category) but meta.ownerKey is evaluated as a runtime filter.
SET documentdb.enable_reduced_correlated_non_multikey_order_by TO off;
SET documentdb.enable_full_scan_cost_and_selectivity TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db',
  '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$group": { "_id": "$meta.category", "updatedAt": { "$max": "$updatedAt" } } }, { "$sort": { "updatedAt": -1 } }, { "$limit": 5 } ], "cursor": {} }');

-- With enable_full_scan_cost_and_selectivity off, the planner picks
-- idx_owner_cat_ts: the filter is pushed as an index condition but the group
-- is not pushed (the scan is not ordered on meta.category, so a Sort or a
-- HashAggregate is needed).
SET documentdb.enable_full_scan_cost_and_selectivity TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db',
  '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$group": { "_id": "$meta.category", "updatedAt": { "$max": "$updatedAt" } } }, { "$sort": { "updatedAt": -1 } }, { "$limit": 5 } ], "cursor": {} }');
RESET documentdb.enable_reduced_correlated_non_multikey_order_by;

-- Reduced correlated terms only exist for array values, so while the index is
-- not multi-key the equality on meta.ownerKey makes idx_owner_cat_ts ordered on
-- meta.category: the planner picks it with both the filter and the group pushed,
-- regardless of enable_full_scan_cost_and_selectivity.
SET documentdb.enable_full_scan_cost_and_selectivity TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db',
  '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$group": { "_id": "$meta.category", "updatedAt": { "$max": "$updatedAt" } } }, { "$sort": { "updatedAt": -1 } }, { "$limit": 5 } ], "cursor": {} }');
SET documentdb.enable_full_scan_cost_and_selectivity TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db',
  '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$group": { "_id": "$meta.category", "updatedAt": { "$max": "$updatedAt" } } }, { "$sort": { "updatedAt": -1 } }, { "$limit": 5 } ], "cursor": {} }');

-- Hinting idx_owner_cat_ts also pushes the group to the index.
\set hintedQuery '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$group": { "_id": "$meta.category", "updatedAt": { "$max": "$updatedAt" } } }, { "$sort": { "updatedAt": -1 } }, { "$limit": 5 } ], "hint": "idx_owner_cat_ts", "cursor": {} }'
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'hintedQuery');
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'hintedQuery');

-- With the feature disabled, the group is not pushed.
SET documentdb.enable_reduced_correlated_non_multikey_order_by TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'hintedQuery');
RESET documentdb.enable_reduced_correlated_non_multikey_order_by;

-- A $sort on the non-leading dotted path is pushed in both directions.
\set sortAsc '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$sort": { "meta.category": 1 } }, { "$project": { "c": "$meta.category" } } ], "hint": "idx_owner_cat_ts", "cursor": {} }'
\set sortDesc '{ "aggregate": "grp_idx_push", "pipeline": [ { "$match": { "meta.ownerKey": "owner-7" } }, { "$sort": { "meta.category": -1 } }, { "$project": { "c": "$meta.category" } } ], "hint": "idx_owner_cat_ts", "cursor": {} }'
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'sortAsc');
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'sortAsc');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'sortDesc');
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'sortDesc');

-- Once the index has correlated array terms, the group is no longer pushed.
-- Results remain correct.
SELECT documentdb_api.insert_one('grp_idx_push_db', 'grp_idx_push',
  '{ "_id": "arr", "meta": [ { "ownerKey": "owner-7", "category": 100 }, { "ownerKey": "owner-8", "category": -1 } ], "updatedAt": 50000 }');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'hintedQuery');
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'hintedQuery');
\set sortQuery '{ "aggregate": "grp_idx_push", "pipeline": [ { "$sort": { "meta.category": 1, "_id": 1 } }, { "$limit": 3 }, { "$project": { "meta.category": 1 } } ], "hint": "idx_owner_cat_ts", "cursor": {} }'
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'sortQuery');
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'sortQuery');

RESET documentdb.enable_full_scan_cost_and_selectivity;
RESET random_page_cost;
RESET documentdb.enableCursorsOnAggregationQueryRewrite;

-- A matching non-default collation keeps the pushed order on the non-leading
-- dotted path: with strength 1, "a" and "A" (and "b" and "B") are equal.
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('grp_idx_push_db',
  '{ "createIndexes": "grp_idx_coll", "indexes": [{ "key": { "meta.ownerKey": 1, "meta.category": 1 }, "name": "idx_owner_cat_coll", "collation": { "locale": "en", "strength": 1 } }] }', true);
SELECT documentdb_api.insert_one('grp_idx_push_db', 'grp_idx_coll', '{ "_id": 1, "meta": { "ownerKey": "o", "category": "b" } }');
SELECT documentdb_api.insert_one('grp_idx_push_db', 'grp_idx_coll', '{ "_id": 2, "meta": { "ownerKey": "o", "category": "A" } }');
SELECT documentdb_api.insert_one('grp_idx_push_db', 'grp_idx_coll', '{ "_id": 3, "meta": { "ownerKey": "o", "category": "C" } }');
SELECT documentdb_api.insert_one('grp_idx_push_db', 'grp_idx_coll', '{ "_id": 4, "meta": { "ownerKey": "o", "category": "a" } }');
SELECT documentdb_api.insert_one('grp_idx_push_db', 'grp_idx_coll', '{ "_id": 5, "meta": { "ownerKey": "o", "category": "B" } }');
\set collSort '{ "aggregate": "grp_idx_coll", "pipeline": [ { "$match": { "meta.ownerKey": "o" } }, { "$sort": { "meta.category": 1 } }, { "$project": { "c": "$meta.category" } } ], "collation": { "locale": "en", "strength": 1 }, "hint": "idx_owner_cat_coll", "cursor": {} }'
\set collGroup '{ "aggregate": "grp_idx_coll", "pipeline": [ { "$match": { "meta.ownerKey": "o" } }, { "$group": { "_id": "$meta.category", "n": { "$sum": 1 } } } ], "collation": { "locale": "en", "strength": 1 }, "hint": "idx_owner_cat_coll", "cursor": {} }'
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'collSort');
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'collSort');
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'collGroup');
SELECT document FROM bson_aggregation_pipeline('grp_idx_push_db', :'collGroup');
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;

SELECT documentdb_api.drop_database('grp_idx_push_db');
