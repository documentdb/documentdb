SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 49400;
SET documentdb.next_collection_index_id TO 49400;

SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enable_composite_reduced_correlated_bounds_planning TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET documentdb.enable_merge_sort_for_in_prefix TO on;
-- Allow group-by pushdown onto a compound _id index (the group scenarios below).
SET documentdb.enableGroupByCompoundIdIndexPushdown TO on;
SET documentdb_core.enableWriteDocumentsInRepath TO on;
-- Required to build the case-insensitive (collation) composite index below.
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

-- ============================================================================
-- COUNT and AGGREGATE ($group) plan tests for a range + $or/$and workload whose
-- queries time out. These are the count/aggregate counterparts of the find plan
-- tests: each query is a range predicate on a scalar ordered key (ord) ANDed with
-- either a scalar $or-of-$and or an array $elemMatch predicate, then either counted
-- or grouped by the scalar (cat, sub) keys. Field names/values are neutral and all
-- index-hitting queries carry a "hint".
--
-- Data shape:
--   * ord            scalar integer  -> range / order-by key.
--   * cat / sub      scalar strings  -> equality predicates and $group keys.
--   * tags           ARRAY of { name, val } sub-documents -> tags.name / tags.val
--                                       are MULTI-KEY.
-- ============================================================================

-- Non-multi-key composite index over the scalar (cat, sub, ord) predicate keys.
SELECT documentdb_api_internal.create_indexes_non_concurrently('grpq_db',
    '{ "createIndexes": "docs", "indexes": [ { "key": { "cat": 1, "sub": 1, "ord": -1 }, "name": "idx_cat_sub_ord", "enableOrderedIndex": 1 } ] }', TRUE);
-- Multi-key (rct) composite index over the array tags.name / tags.val + ord.
SELECT documentdb_api_internal.create_indexes_non_concurrently('grpq_db',
    '{ "createIndexes": "docs", "indexes": [ { "key": { "tags.name": 1, "tags.val": 1, "ord": -1 }, "name": "idx_tags_ord", "enableOrderedIndex": 1 } ] }', TRUE);
-- CASE-INSENSITIVE (collation strength: 1) copy of the same multi-key key shape.
-- Under strength 1 the collation folds case, so an anchored case-insensitive
-- /^NAME1$/i regex is logically an equality on this index. Used by the CI-index
-- sections below to test whether the planner lowers a /i regex onto it.
SELECT documentdb_api_internal.create_indexes_non_concurrently('grpq_db',
    '{ "createIndexes": "docs", "indexes": [ { "key": { "tags.name": 1, "tags.val": 1, "ord": -1 }, "name": "idx_tags_ord_ci", "enableOrderedIndex": 1, "collation": { "locale": "en", "strength": 1 } } ] }', TRUE);

-- Seed data. Wrapped in COUNT() to avoid per-row output spew. Every 7th doc carries
-- the "NAME1"/"V1" tag pair and every 11th the "NAME2"/"V2" pair so the $elemMatch
-- branches match a deterministic subset.
SELECT COUNT(documentdb_api.insert_one('grpq_db', 'docs',
    ('{ "_id": ' || i::text ||
     ', "ord": ' || (i % 200)::text ||
     ', "cat": "c' || (i % 4)::text || '"' ||
     ', "sub": "s' || (i % 3)::text || '"' ||
     ', "tags": [ { "name": "' || (CASE WHEN i % 7 = 0 THEN 'NAME1' ELSE 'n' || (i % 13)::text END) ||
        '", "val": "' || (CASE WHEN i % 7 = 0 THEN 'V1' ELSE 'x' || (i % 5)::text END) || '" }, ' ||
        '{ "name": "' || (CASE WHEN i % 11 = 0 THEN 'NAME2' ELSE 'm' || (i % 9)::text END) ||
        '", "val": "' || (CASE WHEN i % 11 = 0 THEN 'V2' ELSE 'y' || (i % 4)::text END) || '" } ] }')::bson))
FROM generate_series(1, 200) i;

-- VACUUM (ANALYZE) the collection heap (not a bare ANALYZE) so the visibility
-- map is populated in addition to refreshing statistics. Without an up-to-date
-- visibility map the planner's index-only-scan vs. bitmap-heap-scan choice can
-- diverge across PostgreSQL versions; vacuuming first makes the chosen plan
-- stable. Scoped to the collection we created rather than the whole instance.
VACUUM (ANALYZE) documentdb_data.documents_49401;

-- ============================================================================
-- 1. COUNT: ord range AND an $or of two scalar equality $and branches
--    (cat, sub), all covered by the non-multi-key idx_cat_sub_ord.
--    OBSERVED: a Bitmap Heap Scan (BitmapOr of two Bitmap Index Scans) with a heap
--    Recheck Cond -- heap pages are fetched even though only the count is needed.
--    TODO: this SHOULD be an index-only scan. idx_cat_sub_ord is non-multi-key
--    (isMultiKey: false) and every $or branch (equality on cat + sub, range on ord)
--    is fully covered by it, so the union of the two branch ranges can be counted
--    straight from the index -- a union / append of two index-only scans with no
--    heap access, instead of the Bitmap Heap Scan.
--    VERSION NOTE: on PostgreSQL <= 17 the planner picks the Bitmap Heap Scan
--    described above; on PostgreSQL >= 18 the cost model instead collapses the
--    two branches into a single ord-range Index Only Scan with a residual Filter
--    (the desired shape). Because the plan legitimately differs by server version,
--    PG18 uses the _pg18 expected variant (see the !PG18_OR_HIGHER! tag in
--    basic_schedule); PG15-17 use the base expected file.
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] }, "hint": "idx_cat_sub_ord" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] }, "hint": "idx_cat_sub_ord" }');

-- ============================================================================
-- 2. AGGREGATE $group: same scalar range + $or-of-$and filter, then drop empty
--    cat, then $group by { type: $cat, subType: $sub } with $sum, then $sort on the
--    count. The (cat, sub) group keys exactly match the leading columns of
--    idx_cat_sub_ord.
--    OBSERVED: the good index is NOT used at all -- the plan falls back to a full
--    _id_ index scan with the whole predicate applied as a heap Filter (note the
--    large "Rows Removed by Filter"), then an explicit Sort feeds a GroupAggregate,
--    then a final Sort on count. This is the timing-out shape.
--    TODO: the $or-of-$and branches SHOULD be pushed to idx_cat_sub_ord (each branch
--    an ordered scan already grouped by (cat, sub)); sort-merged on (cat, sub) that
--    feeds a STREAMING GroupAggregate with no pre-group Sort, then only the final
--    Sort on count -- eliminating both the full _id_ scan and the pre-group Sort.
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('grpq_db',
        '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }')
$cmd$);
SELECT document FROM bson_aggregation_pipeline('grpq_db',
    '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }');

-- ============================================================================
-- 3. COUNT: ord range AND an $and of two $elemMatch over the multi-key tags array,
--    each with case-insensitive $regex on name and val (hint idx_tags_ord).
--    OBSERVED: a single ordered Index Scan (scanType: regular). BOTH $elemMatch name
--    predicates are pushed onto tags.name, but each is a union of its anchored /i
--    $regex AND the all-strings range ["", { }) -- a /i $regex cannot lower to a
--    tight equality -- so the effective tags.name bound is the whole string range.
--    tags.val collapses to the fully-unbounded (MinKey, MaxKey) for both. Both
--    $elemMatch are then re-applied in full as a recheck Filter (the actual $and
--    intersection). Note the tags.name Index Cond lacks the "rctBoundsPlanApplied"
--    marker that the single-$elemMatch $or branches in section 4 carry.
--    TODO: (a) tags.val should be bounded to the correlated per-element string range
--    ["", { )) rather than dropped to (MinKey, MaxKey); (b) the /i $regex should
--    lower to an equality on a case-insensitive index so tags.name/tags.val form
--    tight bounds instead of widening to the all-strings range and forcing the
--    full recheck. (Section 6 hints idx_tags_ord_ci and confirms (b) is not done yet;
--    section 8 shows equality alone achieves the tight tags.name bound.)
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }');

-- ============================================================================
-- 4. COUNT: ord range AND an $or of two $elemMatch over the multi-key tags array,
--    each with case-insensitive $regex on name and val (hint idx_tags_ord).
--    OBSERVED: a Bitmap Heap Scan (BitmapOr of two Bitmap Index Scans) with a heap
--    Recheck Cond. Each single-$elemMatch branch keeps tags.name/tags.val at the
--    string range ["", { }) (the /i $regex cannot lower to an equality) and carries
--    the "rctBoundsPlanApplied" marker; heap pages are fetched for the count.
--    TODO: with a case-insensitive index the anchored /i $regex would be an equality,
--    so both branches could be covered index-only scans union-ed for the count with
--    no heap access -- instead of the Bitmap Heap Scan over the widened ranges.
--    (Section 7 hints idx_tags_ord_ci and shows the /i regex is still not lowered;
--    section 9 shows equality alone pins both tags.name and tags.val to point bounds.)
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }');

-- ============================================================================
-- 5. AGGREGATE $group: ord range + $or of two $elemMatch (regex) filter, drop empty
--    cat, then $group by { type: $cat, subType: $sub } with $sum, then $sort on
--    count. Like section 2 but the filter is an array $elemMatch $or.
--    OBSERVED: same timing-out shape as section 2 -- a full _id_ index scan with the
--    predicate as a heap Filter, an explicit Sort, a GroupAggregate, then the final
--    Sort on count. Neither idx_tags_ord (for the filter) nor the (cat, sub) group
--    keys are exploited.
--    TODO: the $elemMatch $or branches should push to idx_tags_ord (see the count in
--    section 4), and the (cat, sub) group should stream off an ordered scan on those
--    keys, avoiding both the full _id_ scan and the pre-group Sort.
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('grpq_db',
        '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }')
$cmd$);
SELECT document FROM bson_aggregation_pipeline('grpq_db',
    '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }');

-- ============================================================================
-- 6. COUNT (CASE-INSENSITIVE INDEX): section 3's $and of two $elemMatch /i regex
--    query, but hinting the case-insensitive idx_tags_ord_ci instead of idx_tags_ord.
--    Question: does hinting a case-insensitive index let the anchored /i regex lower
--    to a tight equality bound?
--    OBSERVED: NO. tags.name AND tags.val both stay fully unbounded (MinKey, MaxKey);
--    only ord is bounded on the index. The whole $and of $elemMatch is re-applied as a
--    heap recheck Filter (note the large "Rows Removed by Filter"). The planner does
--    not recognise the anchored /i regex as a collation-equality against the
--    case-folding index, so the CI index gives an even looser bound than idx_tags_ord
--    in section 3 (which at least pinned tags.name to the all-strings range).
--    TODO: lower an anchored /i regex to a collation-equality on idx_tags_ord_ci so
--    tags.name/tags.val form tight point bounds instead of (MinKey, MaxKey).
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }');

-- ============================================================================
-- 7. COUNT (CASE-INSENSITIVE INDEX): section 4's $or of two $elemMatch /i regex
--    query, but hinting idx_tags_ord_ci.
--    OBSERVED: NO lowering here either. A single ordered Index Scan with tags.name and
--    tags.val at (MinKey, MaxKey) and the $or of $elemMatch as a heap recheck Filter.
--    Unlike section 4 on idx_tags_ord -- which produced a BitmapOr of two branches,
--    each with the "rctBoundsPlanApplied" marker and tags.name/tags.val pinned to the
--    all-strings range ["", { )) -- the case-insensitive index hint produces a strictly
--    worse plan: no per-branch bounds at all, everything rechecked.
--    TODO: same as section 6 -- the anchored /i regex should lower to a collation-
--    equality on idx_tags_ord_ci, yielding tight per-branch bounds (ideally index-only).
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }');

-- ============================================================================
-- 8. COUNT (EQUALITY companion to section 3): the same $and of two $elemMatch, but
--    each name/val predicate is a plain string equality instead of a /i regex
--    (hint idx_tags_ord). Confirms the /i regex -- not the $elemMatch shape -- was the
--    thing blocking a tight bound.
--    OBSERVED: a single ordered Index Scan (scanType: regular). tags.name now lowers to
--    a UNION of two point equalities ["NAME1", "NAME1"], ["NAME2", "NAME2"] -- exactly
--    the tight bound the /i regex could not produce in section 3. tags.val still
--    collapses to (MinKey, MaxKey) (the $and of two $elemMatch does not get the
--    per-element correlated bound; there is no "rctBoundsPlanApplied" marker), so both
--    $elemMatch are re-applied in full as a recheck Filter.
--    TODO: tags.val should also be bounded to the correlated per-element equality for
--    the $and-of-two-$elemMatch form (the single-$elemMatch $or form in section 9 does).
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }');

-- ============================================================================
-- 9. COUNT (EQUALITY companion to section 4): the same $or of two $elemMatch with
--    string equality instead of /i regex (hint idx_tags_ord).
--    OBSERVED: a Bitmap Heap Scan (BitmapOr of two Bitmap Index Scans). Each branch now
--    pins BOTH tags.name AND tags.val to tight point equalities (["NAME1","NAME1"],
--    ["V1","V1"] / ["NAME2","NAME2"], ["V2","V2"]) and carries "rctBoundsPlanApplied".
--    This is the fully-lowered bound the /i regex form in section 4 could not reach --
--    equality alone unlocks it, confirming the only remaining gap for the regex form is
--    lowering the /i regex (via a case-insensitive index, sections 6-7).
--    TODO: this is still a Bitmap Heap Scan (heap fetched for a count); the two tightly-
--    bounded branches should union index-only (same index-only TODO as section 4).
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }');

-- ============================================================================
-- 10. AGGREGATE $group (EQUALITY companion to section 5): the section 5 $group pipeline
--     with string equality instead of /i regex in the $elemMatch $or filter.
--     OBSERVED: still the timing-out shape -- a full _id_ index scan with the whole
--     predicate as a heap Filter (large "Rows Removed by Filter"), an explicit pre-group
--     Sort, a GroupAggregate, then the final Sort on count. Equality tightens the count
--     bounds (section 9) but does NOT change the $group plan: neither idx_tags_ord (for
--     the filter) nor the (cat, sub) group keys are exploited.
--     TODO: same as sections 2 and 5 -- push the $elemMatch $or branches to idx_tags_ord
--     and stream the (cat, sub) group off an ordered scan, avoiding the full _id_ scan
--     and the pre-group Sort. Independent of whether the predicate is equality or regex.
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('grpq_db',
        '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }')
$cmd$);
SELECT document FROM bson_aggregation_pipeline('grpq_db',
    '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }');

-- ============================================================================
-- FORCE ORDERED INDEX SCAN + CORRECTNESS VALIDATION
-- Re-run every scenario above with documentdb_rum.forceRumOrderedIndexScan = on.
-- This forces the extended-RUM access method onto its ordered (streaming) index
-- scan path even where the natural plan chose a regular or bitmap index scan, so
-- the ordered-scan code path is exercised directly. For each scenario the forced
-- EXPLAIN shows the resulting plan (note where scanType flips from regular to
-- ordered) and the query result is printed; each forced result MUST match the
-- corresponding non-forced scenario's result above, validating that the ordered
-- scan path returns identical rows.
-- ============================================================================
SET documentdb_rum.forceRumOrderedIndexScan TO on;

-- Scenario 1 (forced ordered): plan + result must match section 1 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] }, "hint": "idx_cat_sub_ord" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] }, "hint": "idx_cat_sub_ord" }');

-- Scenario 2 (forced ordered): plan + result must match section 2 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('grpq_db',
        '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }')
$cmd$);
SELECT document FROM bson_aggregation_pipeline('grpq_db',
    '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "$and": [ { "cat": "c1" }, { "sub": "s1" } ] }, { "$and": [ { "cat": "c2" }, { "sub": "s2" } ] } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }');

-- Scenario 3 (forced ordered): plan + result must match section 3 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }');

-- Scenario 4 (forced ordered): plan + result must match section 4 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord" }');

-- Scenario 5 (forced ordered): plan + result must match section 5 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('grpq_db',
        '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }')
$cmd$);
SELECT document FROM bson_aggregation_pipeline('grpq_db',
    '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }');

-- Scenario 6 (forced ordered): plan + result must match section 6 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }');

-- Scenario 7 (forced ordered): plan + result must match section 7 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME1$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V1$", "options": "i" } } } } }, { "tags": { "$elemMatch": { "name": { "$regularExpression": { "pattern": "^NAME2$", "options": "i" } }, "val": { "$regularExpression": { "pattern": "^V2$", "options": "i" } } } } } ] } ] }, "hint": "idx_tags_ord_ci" }');

-- Scenario 8 (forced ordered): plan + result must match section 8 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$and": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }');

-- Scenario 9 (forced ordered): plan + result must match section 9 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('grpq_db',
        '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }')
$cmd$);
SELECT document FROM bson_aggregation_count('grpq_db',
    '{ "count": "docs", "query": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] }, "hint": "idx_tags_ord" }');

-- Scenario 10 (forced ordered): plan + result must match section 10 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_pipeline('grpq_db',
        '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }')
$cmd$);
SELECT document FROM bson_aggregation_pipeline('grpq_db',
    '{ "aggregate": "docs", "pipeline": [ { "$match": { "$and": [ { "ord": { "$gte": 50, "$lte": 150 } }, { "$or": [ { "tags": { "$elemMatch": { "name": "NAME1", "val": "V1" } } }, { "tags": { "$elemMatch": { "name": "NAME2", "val": "V2" } } } ] } ] } }, { "$match": { "$and": [ { "cat": { "$ne": null } }, { "cat": { "$ne": "" } } ] } }, { "$group": { "_id": { "type": "$cat", "subType": "$sub" }, "count": { "$sum": 1 } } }, { "$sort": { "count": -1 } } ], "cursor": {} }');

RESET documentdb_rum.forceRumOrderedIndexScan;
