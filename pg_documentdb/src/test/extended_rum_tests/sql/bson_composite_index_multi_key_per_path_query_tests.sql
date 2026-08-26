SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 13100;
SET documentdb.next_collection_index_id TO 13100;

-- Enable the composite index planner, which is responsible for pushing equality
-- prefixes and order-by clauses down into ordered composite index scans.
set documentdb.enableCompositeIndexPlanner to on;

-- Enable global index metadata tracking. With this on, the composite index records
-- per-path multi-key state in its opclass metadata. The intent is for the planner to
-- eventually decide order-by pushdown based on whether the *sort* path itself is
-- multi-key, rather than on a single index-wide multi-key flag.
set documentdb.enableIndexMetadataGlobalTracking to on;

-- This suite intentionally exercises independent multi-key paths. Parallel-array
-- rejection is covered by dedicated tests.
set documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking to off;

set documentdb.enableExtendedExplainPlans to on;
-- Suppress per-index cost details so explain output is stable across runs.
set documentdb.enableExplainScanIndexCosts to off;
-- Force index usage so the scan/sort plan shape surfaces deterministically.
set enable_seqscan to off;
-- Disable bitmap scans so the planner picks the ordered index-scan path; a bitmap
-- scan cannot carry the index ordering, which would force a Sort node regardless of
-- whether order-by pushdown is otherwise possible.
set enable_bitmapscan to off;

-- ============================================================================
-- Scenario A: order-by pushdown on a composite (a, b) index.
--
-- Reading the plans below:
--   * Order-by IS pushed down  => the index scan carries an "Order By:" line and
--     there is NO Sort/Incremental Sort node above the Custom Scan.
--   * Order-by is NOT pushed    => a Sort (or Incremental Sort) node sits above the
--     Custom Scan and the index scan has no "Order By:" line.
--
-- With per-path multi-key tracking enabled, the order-by pushdown decision for a
-- multi-key index is driven by the per-path multi-key state of the *sort* column,
-- not by a single index-wide multi-key flag. The documented semantics are:
--   * If the sort column is NOT multi-key, the order by can be pushed when a prefix
--     is an equality or range (the classic ordered-index rule).
--   * If the sort column IS multi-key, the order by can be pushed only when that
--     column carries no filter.
-- Case A2 below exercises the second rule when it permits the push (a multi-key sort
-- column with no filter, which is pushed). Cases A1/A3/A4 exercise the first rule (a
-- non-multi-key sort column, pushed even when it carries a filter, because per-path
-- tracking sees the sort column is scalar). Cases A5/A6 exercise the second rule when
-- it blocks the push (a multi-key sort column that carries a filter -- range or
-- equality -- is not pushed). Scenario C shows the remaining limitation: a
-- non-contiguous equality prefix (a gap before the sort column) still blocks
-- pushdown, independent of multi-key state.
-- ============================================================================

SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');

SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_coll', '{ "_id": 1, "a": 1, "b": 1 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_coll', '{ "_id": 2, "a": 1, "b": 2 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_coll', '{ "_id": 3, "a": 2, "b": 3 }');

-- Case A0 (positive control): order by on the LEADING column "a". A sort on the index
-- prefix is pushed down: the index scan carries an "Order By:" line and there is no
-- Sort node above the Custom Scan. This anchors the "pushed down" plan shape.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll", "filter": { "a": { "$gte": 1 } }, "sort": { "a": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case A1: filter on "a" (equality prefix), order by the SECONDARY column "b".
-- Neither "a" nor "b" is multi-key here.
--
-- Correct and expected: because "a" is pinned to a single value and "b" is not
-- multi-key, the index yields rows already ordered by "b" within a=1, so the order by
-- on "b" is pushed down (Order By line on the scan, no Sort node).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll", "filter": { "a": 1 }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case A2 (correct, by design): make the SORT path "b" multi-key by inserting an
-- array value for "b". Explain reports "multiKeyPaths: b".
--
-- A multi-key sort column CAN have its order by pushed down as long as that column
-- carries no filter -- here "b" has only a sort and no filter -- so the order by on
-- "b" is pushed (Order By line on the scan, no Sort node). This is the documented
-- semantics: a multi-key column with no filter is still safe to order on.
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_coll', '{ "_id": 4, "a": 1, "b": [ 4, 5 ] }');

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll", "filter": { "a": 1 }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case A3: only the PREFIX path "a" is multi-key; the sort path "b" is scalar.
-- Explain reports "multiKeyPaths: a" (not "b").
--
-- Correct and expected: because the sort column "b" is not multi-key, the order by on
-- "b" is pushed down (Order By line, no Sort node) even though the leading path "a" is
-- multi-key. This is the case the per-path multi-key metadata is meant to preserve,
-- distinguishing it from the multi-key sort column in Case A2.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_coll_a3", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_coll_a3', '{ "_id": 1, "a": [ 1, 2 ], "b": 1 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_coll_a3', '{ "_id": 2, "a": [ 1, 3 ], "b": 2 }');

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll_a3", "filter": { "a": 1 }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case A4: leading path "a" is multi-key, the sort path "b" is scalar (not
-- multi-key), and "b" carries BOTH a range filter and the sort. Reuses the
-- mkpq_coll_a3 collection, so explain still reports "multiKeyPaths: a" (not "b").
--
-- Correct and expected: because the sort column "b" is not multi-key, the order by on
-- "b" is pushed down (Order By line, no Sort node) even though it carries a range
-- filter. The prefix "a" is an equality and "b" is not multi-key, so the index yields
-- "b" already ordered within a=1. Per-path tracking consults the multi-key state of
-- "b" (not the index-wide flag), so the multi-key leading path "a" does not block the
-- push. (The filter -- the a=1 equality prefix plus the "b" range -- is pushed into
-- the index bounds.)
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll_a3", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case A5: multi-key sort column "b" WITH a range filter. Back on mkpq_coll where
-- "b" is multi-key (explain reports "multiKeyPaths: b"). filter { a: 1, b: { $gte:
-- 1 } }, sort { b: 1 }.
--
-- Correct and expected: because the sort column "b" IS multi-key and also carries a
-- filter (the range on "b"), the order by must NOT be pushed -- a single document can
-- expand to several "b" index entries, so an index-ordered scan restricted by the "b"
-- range could emit the document at the wrong position or more than once. A Sort node
-- sits above the Custom Scan and the scan has no "Order By:" line. This is the
-- counterpart to Case A2 (same multi-key "b", but A2 has no filter on "b" and so does
-- push).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case A6 (corner case): multi-key sort column "b" WITH an EQUALITY filter.
-- filter { a: 1, b: 1 }, sort { b: 1 }.
--
-- Correct and expected: an equality on the multi-key sort column is still a filter on
-- that column, so the order by is NOT pushed (a Sort node sits above the Custom
-- Scan). Even though "b" is pinned to a single value in the bounds, a multi-key
-- document matching b=1 may also contain other "b" values, so the index ordering
-- cannot be trusted for the sort. This confirms the "no filter" rule for a multi-key
-- sort column covers equality filters, not just ranges.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll", "filter": { "a": 1, "b": 1 }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- ============================================================================
-- Scenario B: $elemMatch equality prefix + order by on a non-array field.
--
-- Index: { "contacts.ref_id": 1, "logged_at": 1 }. The filter pins
-- "contacts.ref_id" via an $elemMatch equality (the equality prefix) and ranges over
-- "logged_at"; the query sorts by "logged_at".
--
-- Correct and expected: both the filter (equality prefix on contacts.ref_id) and the
-- order by on "logged_at" are pushed to the index, since "logged_at" is not an array
-- (not multi-key). "contacts" is an array, so the index is multi-key on the
-- contacts.ref_id path (explain reports "multiKeyPaths: contacts.ref_id"), but
-- per-path tracking sees that the sort column "logged_at" is scalar, so the multi-key
-- leading path does not block the push. The plan carries an "Order By:" line (a
-- backward/ordered scan for the descending sort) with no Sort node above the Custom
-- Scan. (The filter -- equality prefix on contacts.ref_id plus the logged_at range --
-- is pushed into the index bounds.)
-- ============================================================================

SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_events", "indexes": [ { "key": { "contacts.ref_id": 1, "logged_at": 1 }, "name": "idx_ref_id_logged_at", "enableOrderedIndex": 1 } ] }');

SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_events', '{ "_id": 1, "logged_at": { "$date": { "$numberLong": "1325376000000" } }, "contacts": [ { "ref_id": "4235", "ref_type": "CUSTOMER", "ref_admin": "2" } ] }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_events', '{ "_id": 2, "logged_at": { "$date": { "$numberLong": "1356998400000" } }, "contacts": [ { "ref_id": "4235", "ref_type": "CUSTOMER", "ref_admin": "2" } ] }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_events', '{ "_id": 3, "logged_at": { "$date": { "$numberLong": "1388534400000" } }, "contacts": [ { "ref_id": "9999", "ref_type": "VENDOR", "ref_admin": "1" } ] }');

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_events", "filter": { "$and": [ { "logged_at": { "$gte": { "$date": { "$numberLong": "1136073600000" } }, "$lte": { "$date": { "$numberLong": "1798761599999" } } } }, { "$or": [ { "contacts": { "$elemMatch": { "ref_id": "4235", "ref_type": { "$regex": "^CUSTOMER$", "$options": "i" }, "ref_admin": "2" } } } ] } ] }, "sort": { "logged_at": -1 }, "hint": "idx_ref_id_logged_at", "skip": 0, "limit": 20 }') $cmd$);

-- ============================================================================
-- Scenario C: three-column composite (a, b, c) index with a gap in the prefix.
--
-- Query shape: equality on "a", NO filter on "b", range on "c", order by "c".
-- Data: "a" and "b" are arrays (multi-key); "c" is scalar (not multi-key). Explain
-- reports "multiKeyPaths: a, b" (not "c").
--
-- Behavior: the order by on "c" is NOT pushed (a Sort node sits above the Custom
-- Scan), and this is correct. The blocker is the gap in the equality prefix, NOT
-- multi-key state:
--   * Per-path tracking correctly does NOT block on multi-key here -- the sort column
--     "c" is not multi-key (explain reports "multiKeyPaths: a, b", not "c"), so the
--     multi-key gate does not fire even though the leading paths "a" and "b" are
--     multi-key.
--   * "b" has no filter, so the equality prefix is not contiguous up to the sort
--     column. With "b" unbounded the index orders rows by ("a", "b", "c"), so "c" is
--     not globally ordered across the different "b" values; the index ordering cannot
--     satisfy the sort and a Sort node is required. Order-by pushdown requires every
--     prefix column before the sort column to be an equality, which "b" is not here.
-- A Sort node appears above the Custom Scan. (The filter -- the a=1 equality prefix
-- plus the "c" range -- is still pushed into the index bounds.)
-- ============================================================================

SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_abc", "indexes": [ { "key": { "a": 1, "b": 1, "c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }');

SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_abc', '{ "_id": 1, "a": [ 1, 2 ], "b": [ 10, 11 ], "c": 100 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_abc', '{ "_id": 2, "a": [ 1, 3 ], "b": [ 12, 13 ], "c": 200 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_abc', '{ "_id": 3, "a": [ 4, 5 ], "b": [ 14 ], "c": 300 }');

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_abc", "filter": { "a": 1, "c": { "$gte": 100 } }, "sort": { "c": 1 }, "hint": "a_b_c_1" }') $cmd$);

-- ============================================================================
-- Scenario D: two indexes on one collection -- one built WITH per-path metadata
-- tracking, one built WITHOUT it -- to show the order-by pushdown decision differs.
--
-- The per-path multi-key metadata is recorded on the index at CREATE INDEX time, and
-- only when documentdb.enableIndexMetadataGlobalTracking is on. An index created
-- while the GUC is off has no per-path metadata, so the planner falls back to the
-- single index-wide multi-key flag for that index even if the GUC is later on.
--
-- Collection mkpq_two_idx: "a" is multi-key (arrays); "b" and "c" are scalar.
--   * Index a_b_1 is created WITH tracking on  (per-path metadata present).
--   * Index a_c_1 is created WITH tracking off (no per-path metadata).
-- The two queries below have the same shape -- equality on "a", range on the scalar
-- secondary column, sort on that secondary column -- and differ only in which index
-- they use, isolating the effect of per-path tracking.
-- ============================================================================

SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_two_idx', '{ "_id": 1, "a": [ 1, 2 ], "b": 10, "c": 100 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_two_idx', '{ "_id": 2, "a": [ 1, 3 ], "b": 20, "c": 200 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_two_idx', '{ "_id": 3, "a": [ 4, 5 ], "b": 30, "c": 300 }');

-- Index a_b_1 built WHILE tracking is on -> gets per-path metadata.
set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_two_idx", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }', true);

-- Index a_c_1 built WHILE tracking is off -> no per-path metadata.
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_two_idx", "indexes": [ { "key": { "a": 1, "c": 1 }, "name": "a_c_1", "enableOrderedIndex": 1 } ] }', true);

-- Re-enable tracking for the query phase so the difference is attributable to the
-- per-index metadata (present on a_b_1, absent on a_c_1), not the session GUC.
set documentdb.enableIndexMetadataGlobalTracking to on;

-- Case D1 (tracked index a_b_1): equality on "a", range on scalar "b", sort "b".
-- Because a_b_1 has per-path metadata, the planner sees the sort column "b" is not
-- multi-key and pushes the order by down (Order By line, no Sort node), even though
-- the leading path "a" is multi-key. (Same outcome as Case A4.)
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_two_idx", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case D2 (untracked index a_c_1): equality on "a", range on scalar "c", sort "c".
-- a_c_1 was built with tracking off, so it has no per-path metadata; explain reports
-- "isMultiKey: true" with NO "multiKeyPaths" breakdown (the per-path detail D1 shows).
-- The planner falls back to the index-wide multi-key flag, which is set because "a"
-- is multi-key. The sort column "c" carries a filter, so the multi-key gate fires and
-- the order by is NOT pushed (a Sort node sits above the Custom Scan) -- even though
-- "c" itself is scalar. This is the difference: the identical-shaped query pushes down
-- on the tracked index (D1) but not on the untracked index (D2).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_two_idx", "filter": { "a": 1, "c": { "$gte": 1 } }, "sort": { "c": 1 }, "hint": "a_c_1" }') $cmd$);

-- ============================================================================
-- Scenario E: the enablePerPathMultiKeySortPushdown feature flag (default on).
--
-- This flag gates whether the per-path multi-key bitmask is respected at query time
-- when deciding order-by pushdown. Unlike Scenario D (which removed the per-path
-- metadata from the index at build time), here the index DOES carry per-path metadata
-- (built with tracking on); we toggle the query-time flag to show it controls whether
-- that metadata is honored. Reuses mkpq_coll_a3 (leading "a" multi-key, scalar "b")
-- with the Case A4 query (filter { a: 1, b: { $gte: 1 } }, sort { b: 1 }).
-- ============================================================================

-- Case E1 (flag off): with the flag off the bitmask is ignored, so every order-by
-- column of a multi-key index is treated as multi-key. The sort column "b" carries a
-- range filter, so the order by is NOT pushed (a Sort node sits above the Custom
-- Scan) -- the same outcome as before per-path tracking existed. Contrast with Case
-- A4, which pushes this exact query down with the flag on (the default).
set documentdb.enablePerPathMultiKeySortPushdown to off;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll_a3", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Case E2 (flag back on): restoring the flag re-enables per-path awareness, so the
-- sort column "b" (not multi-key) again pushes the order by down (Order By line, no
-- Sort node), matching Case A4.
set documentdb.enablePerPathMultiKeySortPushdown to on;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_coll_a3", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- ============================================================================
-- Scenario F: upgrade an existing index's opclass options in place via collMod
-- "reindex".
--
-- An index built while documentdb.enableIndexMetadataGlobalTracking was OFF
-- carries no per-path metadata opclass option ("mkp"). Turning the option on at
-- the collection level and reindexing rebuilds the physical index with the new
-- opclass options (mkp=true) and drops the old physical index, all without
-- dropping the logical index.
--
-- This drives the components the background framework would otherwise run on a
-- schedule (the cron job is intentionally not used here):
--   1. coll_mod queues a reindex request (carrying the updated options) in the
--      index queue.
--   2. build_index_concurrently drains the queue: it builds the replacement
--      physical index concurrently, swaps it in, and drops the old one.
-- ============================================================================

-- Isolate the index queue so the assertions below only observe this scenario.
DELETE FROM documentdb_api_catalog.documentdb_index_queue;

-- Build the index while metadata tracking is OFF, so it is created WITHOUT the
-- per-path metadata opclass option. "a" is multi-key (arrays); "b" is scalar.
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api.create_collection('mkpq_db', 'mkpq_reindex');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_reindex', '{ "_id": 1, "a": [ 1, 2 ], "b": 10 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_reindex', '{ "_id": 2, "a": [ 1, 3 ], "b": 20 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_reindex', '{ "_id": 3, "a": [ 4, 5 ], "b": 30 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_reindex", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }', true);

-- Capture the collection id so the assertions can target its data table.
SELECT collection_id AS mkpq_rx_cid FROM documentdb_api_catalog.collections WHERE database_name = 'mkpq_db' AND collection_name = 'mkpq_reindex' \gset

-- Before the upgrade: a single physical index exists with no "mkp" opclass
-- option (tracking was off at build time).
SELECT relname, (pg_get_indexdef(indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking
    FROM pg_index
    JOIN pg_class ON pg_class.oid = pg_index.indexrelid
    WHERE indrelid = ('documentdb_data.documents_' || :'mkpq_rx_cid')::regclass
      AND relname LIKE 'documents_rum_index%'
    ORDER BY relname;

-- Without per-path metadata the index is treated as wholly multi-key, so the
-- order by on scalar "b" (which also carries a range filter) is NOT pushed down
-- (a Sort node sits above the Custom Scan).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_reindex", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- Turn metadata tracking on, then upgrade the index in place via collMod reindex.
-- updateOptions:true requests that the rebuild regenerate the index options from
-- the current configuration (picking up the now-enabled per-path metadata opclass
-- option) instead of recreating the index as-is.
set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.coll_mod('mkpq_db', 'mkpq_reindex', '{ "collMod": "mkpq_reindex", "index": { "name": "a_b_1", "reindex": true, "updateOptions": true } }');

-- The reindex request is queued as a concurrent rebuild that recreates the
-- physical index with the new opclass options (mkp=true).
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = :mkpq_rx_cid ORDER BY index_id;

-- Drain the queue using the build components directly (no cron job).
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Queue is empty after processing.
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = :mkpq_rx_cid ORDER BY index_id;

-- After the upgrade: a single physical index remains (the old one was dropped)
-- and it now carries the per-path metadata opclass option (mkp=true).
SELECT relname, (pg_get_indexdef(indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking
    FROM pg_index
    JOIN pg_class ON pg_class.oid = pg_index.indexrelid
    WHERE indrelid = ('documentdb_data.documents_' || :'mkpq_rx_cid')::regclass
      AND relname LIKE 'documents_rum_index%'
    ORDER BY relname;

-- With per-path metadata now present, scalar sort column "b" is recognized as
-- non-multi-key, so the order by on "b" IS pushed down (Order By line, no Sort
-- node). The in-place reindex changed the query plan.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_reindex", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_1" }') $cmd$);

-- ============================================================================
-- Scenario G: upgrade a UNIQUE index's opclass options in place via collMod
-- "reindex".
--
-- This mirrors Scenario F but for a unique composite index, which is backed by a
-- table constraint rather than a plain index. The reindex must:
--   * rebuild the replacement physical index with the new opclass options
--     (mkp=true),
--   * keep the replacement constraint-backed (uniqueness still enforced), and
--   * drop the old physical index/constraint so no "_ccold"/"_ccnew" artifacts
--     and no duplicate constraints are left behind.
-- ============================================================================

-- Isolate the index queue so the assertions below only observe this scenario.
DELETE FROM documentdb_api_catalog.documentdb_index_queue;

-- Use the constraint-backed unique layout for composite indexes.
set documentdb.enableCompositeUniqueHash to on;

-- Build the unique index while metadata tracking is OFF, so it is created WITHOUT
-- the per-path metadata opclass option. "a" is multi-key (arrays); "b" is scalar.
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api.create_collection('mkpq_db', 'mkpq_uniq_reindex');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_uniq_reindex', '{ "_id": 1, "a": [ 1, 2 ], "b": 10 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_uniq_reindex', '{ "_id": 2, "a": [ 1, 3 ], "b": 20 }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_uniq_reindex', '{ "_id": 3, "a": [ 4, 5 ], "b": 30 }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_uniq_reindex", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_uniq", "unique": true, "enableOrderedIndex": 1 } ] }', true);

-- Capture the collection id so the assertions can target its data table.
SELECT collection_id AS mkpq_urx_cid FROM documentdb_api_catalog.collections WHERE database_name = 'mkpq_db' AND collection_name = 'mkpq_uniq_reindex' \gset

-- Before the upgrade: a single physical index exists with no "mkp" opclass option
-- (tracking was off at build time), and it IS backed by a constraint (unique).
SELECT cls.relname,
       (pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking,
       EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = idx.indexrelid) AS constraint_backed
    FROM pg_index idx
    JOIN pg_class cls ON cls.oid = idx.indexrelid
    WHERE idx.indrelid = ('documentdb_data.documents_' || :'mkpq_urx_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%'
    ORDER BY cls.relname;

-- Uniqueness is enforced: a duplicate on (a, b) is rejected.
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_uniq_reindex', '{ "_id": 4, "a": 1, "b": 10 }');

-- Turn metadata tracking on, then upgrade the unique index in place via collMod
-- reindex with updateOptions:true so the rebuild regenerates the opclass options
-- from the current configuration (picking up the per-path metadata option).
set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT documentdb_api.coll_mod('mkpq_db', 'mkpq_uniq_reindex', '{ "collMod": "mkpq_uniq_reindex", "index": { "name": "a_b_uniq", "reindex": true, "updateOptions": true } }');

-- The reindex request is queued as a concurrent rebuild.
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = :mkpq_urx_cid ORDER BY index_id;

-- Drain the queue using the build components directly (no cron job).
CALL documentdb_api_internal.build_index_concurrently(1);
CALL documentdb_api_internal.build_index_background(1);

-- Queue is empty after processing.
SELECT cmd_type, index_cmd FROM documentdb_api_catalog.documentdb_index_queue WHERE collection_id = :mkpq_urx_cid ORDER BY index_id;

-- After the upgrade: exactly one physical index remains (no "_ccold"/"_ccnew"
-- leftovers), it now carries the per-path metadata opclass option (mkp=true), and
-- it is still backed by a constraint (the replacement is constraint-backed and the
-- old constraint was dropped).
SELECT cls.relname,
       (pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking,
       EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = idx.indexrelid) AS constraint_backed
    FROM pg_index idx
    JOIN pg_class cls ON cls.oid = idx.indexrelid
    WHERE idx.indrelid = ('documentdb_data.documents_' || :'mkpq_urx_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%'
    ORDER BY cls.relname;

-- Exactly one unique constraint remains on the data table (the old one was
-- cleaned up; no duplicate constraint was left behind).
SELECT count(*) AS unique_constraint_count
    FROM pg_constraint con
    JOIN pg_class cls ON cls.oid = con.conindid
    WHERE con.conrelid = ('documentdb_data.documents_' || :'mkpq_urx_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%';

-- Uniqueness is still enforced after the in-place reindex: the duplicate is
-- rejected by the replacement constraint-backed index.
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_uniq_reindex', '{ "_id": 5, "a": 1, "b": 10 }');

-- The per-path metadata now drives order-by pushdown for the unique index too:
-- scalar sort column "b" is recognized as non-multi-key, so the order by on "b"
-- IS pushed down (Order By line, no Sort node).
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkpq_db', '{ "find": "mkpq_uniq_reindex", "filter": { "a": 1, "b": { "$gte": 1 } }, "sort": { "b": 1 }, "hint": "a_b_uniq" }') $cmd$);

-- ============================================================================
-- Scenario H: index-only scans on the opclass-metadata-based composite index.
--
-- Index-only-scan support for a composite index is gated on the index being
-- non-multi-key and non-truncated. With metadata tracking on, that multi-key state
-- is read from the opclass metadata (the per-path metadata blob this branch adds),
-- not from a probe of the live index. The extended explain plans surface that state
-- on the Custom Scan ("isMultiKey" / "multiKeyPaths"), so the plans below show the
-- metadata alongside the resulting scan node. This scenario demonstrates both
-- directions:
--   * H1: a scalar (non-multi-key) metadata-bearing index serves an Index Only
--         Scan for a covered aggregate (the Custom Scan reports isMultiKey: false),
--         and
--   * H2: a multi-key metadata-bearing index correctly does NOT (it falls back to a
--         regular Index Scan) because the metadata records the multi-key path (the
--         Custom Scan reports isMultiKey: true with the multiKeyPaths).
-- ============================================================================

-- The unique-hash layout from Scenario G is not relevant here.
set documentdb.enableCompositeUniqueHash to off;

-- Metadata tracking stays on (set earlier) so each new index carries the per-path
-- opclass option and the index-only-scan gate reads multi-key state from it. Force
-- index-only scans when available so the plan shape is deterministic regardless of
-- cost estimates on this tiny collection.
set documentdb.forceIndexOnlyScanIfAvailable to on;

-- --- H1: scalar metadata-bearing index supports index-only scans -------------
-- All indexed paths are scalar, so the opclass metadata records the index as
-- non-multi-key and index-only scans are allowed.
SELECT documentdb_api.create_collection('mkpq_db', 'mkpq_ios');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_ios', '{ "_id": 1, "country": "USA", "city": "Seattle" }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_ios', '{ "_id": 2, "country": "USA", "city": "Boston" }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_ios', '{ "_id": 3, "country": "Mexico", "city": "Cancun" }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_ios', '{ "_id": 4, "country": "India", "city": "Pune" }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_ios', '{ "_id": 5, "country": "Brazil", "city": "Recife" }');
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_ios', '{ "_id": 6, "country": "USA", "city": "Austin" }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('mkpq_db', '{ "createIndexes": "mkpq_ios", "indexes": [ { "key": { "country": 1, "city": 1 }, "name": "country_city_1", "enableOrderedIndex": 1 } ] }', true);

-- Capture the collection id so the data table can be vacuumed/analyzed below.
SELECT collection_id AS mkpq_ios_cid FROM documentdb_api_catalog.collections WHERE database_name = 'mkpq_db' AND collection_name = 'mkpq_ios' \gset

-- The index carries the per-path metadata opclass option (mkp=true): this is the
-- new opclass-metadata-based index whose index-only-scan support is under test.
SELECT cls.relname,
       (pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking
    FROM pg_index idx
    JOIN pg_class cls ON cls.oid = idx.indexrelid
    WHERE idx.indrelid = ('documentdb_data.documents_' || :'mkpq_ios_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%'
    ORDER BY cls.relname;

-- Freeze the heap so index-only scans report no heap fetches (visibility map all-
-- visible). Disable autovacuum so the visibility map stays stable for the test.
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'mkpq_ios_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'mkpq_ios_cid') \gexec

-- Covered $count over the leading scalar path "country": served by an Index Only
-- Scan on the metadata-bearing index (Heap Fetches normalized away).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('mkpq_db', '{ "aggregate" : "mkpq_ios", "pipeline" : [{ "$match" : { "country": { "$eq": "USA" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Covered $group {$sum: 1} over the leading scalar path: also an Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('mkpq_db', '{ "aggregate" : "mkpq_ios", "pipeline" : [{ "$match" : { "country": { "$gte": "Brazil" } } }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- Control: with index-only scans disabled, the same covered $count falls back to a
-- regular Index Scan over the same metadata-bearing index (no "Index Only Scan").
set enable_indexonlyscan to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('mkpq_db', '{ "aggregate" : "mkpq_ios", "pipeline" : [{ "$match" : { "country": { "$eq": "USA" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
set enable_indexonlyscan to on;

-- --- H2: making the SAME index multi-key removes index-only-scan eligibility ---
-- Insert one document into the SAME collection whose "city" value is an array. This
-- makes the "city" path of the existing country_city_1 index multi-key, and the
-- opclass metadata is updated to record it. The very same covered $count that got an
-- Index Only Scan in H1 now falls back to a regular Index Scan, even with
-- forceIndexOnlyScanIfAvailable on, because the metadata now marks the index
-- multi-key (the Custom Scan reports isMultiKey: true / multiKeyPaths: city). This
-- proves the metadata multi-key state -- not a separate index -- gates index-only-
-- scan eligibility.
SELECT documentdb_api.insert_one('mkpq_db', 'mkpq_ios', '{ "_id": 7, "country": "USA", "city": [ "Reno", "Tahoe" ] }');

-- Re-freeze the heap so index-only-scan eligibility is judged on the metadata
-- multi-key state and not on heap visibility.
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'mkpq_ios_cid') \gexec

-- Covered $count on the now-multi-key index: still an Index Only Scan, because the
-- filtered/covered path "country" is not multi-key (only "city" is). Per-path
-- multi-key tracking gates index-only eligibility per column, not index-wide.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('mkpq_db', '{ "aggregate" : "mkpq_ios", "pipeline" : [{ "$match" : { "country": { "$eq": "USA" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

reset documentdb.forceIndexOnlyScanIfAvailable;
