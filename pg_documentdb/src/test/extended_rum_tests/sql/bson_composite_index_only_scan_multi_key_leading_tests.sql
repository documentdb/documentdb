SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 96500;
SET documentdb.next_collection_index_id TO 96500;

-- Enable the composite index planner (equality prefixes, ranges, order-by pushdown).
set documentdb.enableCompositeIndexPlanner to on;

-- Enable opclass metadata tracking so the composite index records per-path multi-key
-- state (the mkp=true opclass option) instead of a single index-wide multi-key term.
set documentdb.enableIndexMetadataGlobalTracking to on;

-- Pin the per-path multi-key gate on so the plan shapes below are deterministic
-- regardless of the default.
set documentdb.enablePerPathMultiKeySortPushdown to on;

-- Covered find projections are only considered for index-only scan when this is
-- on, so pin it: without it the projection cases below would report false for a
-- reason that has nothing to do with multi-key state.
set documentdb.enableIndexOnlyScanForFindProject to on;

-- Pin the multi-key index-only relaxation on so the plan shapes below are
-- deterministic regardless of the default.
SHOW documentdb.enable_multi_key_filter_index_only_scan;
set documentdb.enable_multi_key_filter_index_only_scan to on;

set documentdb.enableExtendedExplainPlans to on;
-- Suppress per-index cost details so explain output is stable across runs.
set documentdb.enableExplainScanIndexCosts to off;
-- Force index usage so the scan shape surfaces deterministically.
set enable_seqscan to off;
set enable_bitmapscan to off;

-- ============================================================================
-- Composite index (grouping.code, detail.label) where the LEADING path
-- "grouping.code" is multi-key (some documents carry an array under "grouping")
-- and the TRAILING path "detail.label" is only ever a scalar (NOT multi-key).
--
-- This is the mirror image of the coverage in
-- bson_composite_index_only_scan_multi_key_per_path_tests, which pins the
-- multi-key path in the trailing position.
--
-- Index-only-scan eligibility now consults the per-path multi-key breakdown
-- against the columns a query actually references, so an equality filter on the
-- multi-key leading path combined with a projection reading ONLY the
-- non-multi-key trailing path is served without touching the heap.
--
-- TODO: two safe cases below are not yet served by an Index Only Scan and are
-- reported as MISSING OPTIMIZATION:
--
--   1. Equality against a short, non-truncated string when other stored terms
--      are truncated.
--   2. An existence-true filter when stored terms are truncated.
--
-- Both operations are exact from the index terms and should become index-only.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmkl_db', '{ "createIndexes": "coll", "indexes": [ { "key": { "grouping.code": 1, "detail.label": 1 }, "name": "grouping_code_detail_label_1", "enableOrderedIndex": 1 } ] }', true);

-- "grouping" is an array on some documents, so the leading path "grouping.code"
-- is multi-key. "detail.label" is always a scalar, so it is not.
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 1, "grouping": [ { "code": "alpha" }, { "code": "beta" } ], "detail": { "label": "first" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 2, "grouping": [ { "code": "alpha" } ], "detail": { "label": "second" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 3, "grouping": { "code": "gamma" }, "detail": { "label": "third" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 4, "grouping": [ { "code": "beta" }, { "code": "gamma" } ], "detail": { "label": "fourth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 5, "grouping": { "code": "alpha" }, "detail": { "label": "fifth" } }');
-- Matches the "alpha" filter through two separate array entries, so it exercises
-- deduplication on the multi-key leading path.
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 6, "grouping": [ { "code": "alpha" }, { "code": "alpha" }, { "code": "delta" } ], "detail": { "label": "sixth" } }');
-- Numeric codes, so the filter-safety cases below can cover a non-string,
-- non-array term as well.
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 7, "grouping": [ { "code": 7 }, { "code": 8 } ], "detail": { "label": "seventh" } }');
-- The four documents below give the "unsafe" filter-safety cases something to
-- match, so those rows assert that the shape is rejected rather than that it
-- happens to select nothing.
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 8, "grouping": { "code": [ "alpha" ] }, "detail": { "label": "eighth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 9, "grouping": { "code": [] }, "detail": { "label": "ninth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 10, "grouping": { "code": null }, "detail": { "label": "tenth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'coll', '{ "_id": 11, "detail": { "label": "eleventh" } }');

SELECT collection_id AS coll_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmkl_db' AND collection_name = 'coll' \gset

-- Confirm the index carries the per-path metadata opclass option (mkp=true).
SELECT (pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking
    FROM pg_index idx
    JOIN pg_class cls ON cls.oid = idx.indexrelid
    WHERE idx.indrelid = ('documentdb_data.documents_' || :'coll_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%'
    ORDER BY cls.relname;

-- Freeze the heap so an index-only scan would report no heap fetches; disable
-- autovacuum so the visibility map stays stable for the test.
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'coll_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'coll_cid') \gexec

-- Disabling the feature restores the prior conservative behavior for a
-- multi-key filter path.
set documentdb.enable_multi_key_filter_index_only_scan to off;
SELECT documentdb_test_helpers.explain_uses_index_only_scan(
    $cmd$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": "alpha" }, "projection": { "_id": 0, "detail.label": 1 } }') $cmd$,
    '[a-z0-9_]+') AS multi_key_filter_index_only_scan_disabled;
set documentdb.enable_multi_key_filter_index_only_scan to on;

-- ----------------------------------------------------------------------------
-- The per-path metadata records exactly one of the two paths as multi-key.
-- Explain reports "multiKeyPaths: grouping.code" and not "detail.label".
-- ----------------------------------------------------------------------------
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": "alpha", "detail.label": { "$gt": "a" } }}') $cmd$);

-- ----------------------------------------------------------------------------
-- The reproduction: equality on the multi-key leading path, projecting only the
-- non-multi-key trailing path.
-- ----------------------------------------------------------------------------

-- With the feature enabled, this is an Index Only Scan.
SELECT documentdb_test_helpers.explain_uses_index_only_scan(
    $cmd$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": "alpha" }, "projection": { "_id": 0, "detail.label": 1 } }') $cmd$,
    '[a-z0-9_]+') AS projection_on_non_multi_key_path_is_index_only;

-- The plan shape behind that assertion.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": "alpha" }, "projection": { "_id": 0, "detail.label": 1 } }') $cmd$, p_ignore_heap_fetches => true);

-- The results themselves are correct either way: _id 6 matches "alpha" through two
-- separate array entries and must still be returned exactly once.
SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": "alpha" }, "projection": { "_id": 0, "detail.label": 1 } }');

-- A $count over the same equality bound reads no field and is also index-only.
SELECT documentdb_test_helpers.explain_uses_index_only_scan(
    $cmd$ SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "grouping.code": "alpha" } }, { "$count": "count" }]}') $cmd$,
    '[a-z0-9_]+') AS count_on_multi_key_leading_path_is_index_only;

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "grouping.code": "alpha" } }, { "$count": "count" }]}') $cmd$, p_ignore_heap_fetches => true);

-- ----------------------------------------------------------------------------
-- Control: the same shape against an index whose leading path is NOT multi-key
-- is already index-only, which isolates the multi-key leading path as the cause.
-- ----------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmkl_db', '{ "createIndexes": "scalar_coll", "indexes": [ { "key": { "grouping.code": 1, "detail.label": 1 }, "name": "grouping_code_detail_label_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmkl_db', 'scalar_coll', '{ "_id": 1, "grouping": { "code": "alpha" }, "detail": { "label": "first" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'scalar_coll', '{ "_id": 2, "grouping": { "code": "alpha" }, "detail": { "label": "second" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'scalar_coll', '{ "_id": 3, "grouping": { "code": "gamma" }, "detail": { "label": "third" } }');

SELECT collection_id AS scalar_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmkl_db' AND collection_name = 'scalar_coll' \gset

SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'scalar_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'scalar_cid') \gexec

SELECT documentdb_test_helpers.explain_uses_index_only_scan(
    $cmd$ SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grouping.code": "alpha" } }, { "$count": "count" }]}') $cmd$,
    '[a-z0-9_]+') AS scalar_leading_path_is_index_only;

-- The projection shape is index-only too once no path is multi-key, which pins
-- the multi-key leading path (and not the projection support) as the cause.
SELECT documentdb_test_helpers.explain_uses_index_only_scan(
    $cmd$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "scalar_coll", "filter": { "grouping.code": "alpha" }, "projection": { "_id": 0, "detail.label": 1 } }') $cmd$,
    '[a-z0-9_]+') AS scalar_leading_path_projection_is_index_only;

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grouping.code": "alpha" } }, { "$count": "count" }]}') $cmd$, p_ignore_heap_fetches => true);

-- ============================================================================
-- Filter safety contract.
--
-- Relaxing index-only-scan eligibility for a multi-key leading path is only
-- sound when the FILTER itself is index-only safe, that is when the scan can
-- decide a match from the index term alone with no heap recheck:
--
--   SAFE   equality on a non-truncated, non-array term (string, number, ...)
--          a SINGLE SIDED range on the same kinds of term
--          $exists true
--
--   UNSAFE anything whose index term is lossy or whose semantics need the
--          document: a truncated term, an array-valued comparand, negation
--          ($ne, $nin), $eq null, $eq [], $exists false, a strict bound against
--          MinKey or MaxKey, and MORE THAN ONE QUAL ON THE SAME COLUMN.
--
-- The last one is the broadest rule and subsumes several of the others: a two
-- sided range is two quals that the index collapses into a single bound, and on
-- a multi-key path that is lossy because different array elements may satisfy
-- different clauses. See the section at the end of this file, which shows the
-- resulting wrong answer directly.
--
-- The rows below pin that contract. Each case carries the REQUIRED value in
-- "expected_index_only", next to what the planner actually does today, so this
-- baseline states reality and passes.
--
-- TODO: every case reported as MISSING OPTIMIZATION must become "contract met"
-- as the multi-key leading path relaxation is extended, and this baseline must
-- be refreshed at that point. A case reported as UNSAFE PUSHDOWN is a
-- correctness defect and must become "contract met" by narrowing the
-- relaxation, never by relaxing the requirement. Cases already reported as
-- "contract met" are the guard rail that stops the relaxation going too far and
-- must stay that way. Any change in either direction shows up as a diff here.
--
-- Note the contrast with the reproduction section above, which deliberately
-- records today's behavior so the gap is visible in a passing baseline.
-- ============================================================================
-- Each "unsafe" filter below selects at least one document, so those rows assert
-- that the shape is rejected rather than that it happens to match nothing.
SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "coll", "pipeline": [ { "$match": { "$or": [ { "grouping.code": { "$eq": [ "alpha" ] } }, { "grouping.code": { "$eq": [] } }, { "grouping.code": { "$eq": null } } ] } }, { "$group": { "_id": 1, "ids": { "$addToSet": "$_id" } } } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": false } } }, { "$group": { "_id": 1, "ids": { "$addToSet": "$_id" } } } ], "cursor": {} }');

CREATE TEMP TABLE safety_cases_base(case_name text, query text, expected_index_only boolean);
INSERT INTO safety_cases_base VALUES
    ('safe: eq non-truncated string',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": "alpha" }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true),
    ('safe: eq non-truncated number',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": 7 }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true),
    -- A two sided range is two quals against the same index column, which the
    -- index collapses into a single bound. On a multi-key path that is lossy,
    -- because different array elements may satisfy different clauses. The
    -- "more than one qual on the same column" section at the end of this file
    -- demonstrates the resulting wrong answer directly.
    ('unsafe: range on string, two quals on the column',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$gte": "a", "$lt": "b" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: range on number, two quals on the column',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$gte": 5, "$lte": 9 } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    -- A single sided range is one qual, so it stays safe.
    ('safe: single sided range on number',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$gte": 5 } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true),
    ('safe: exists true',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$exists": true } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true),
    ('unsafe: eq array comparand',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$eq": [ "alpha" ] } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: eq empty array',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$eq": [] } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: eq null',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$eq": null } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: ne',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$ne": "alpha" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: nin',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$nin": [ "alpha", "beta" ] } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: exists false',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "coll", "filter": { "grouping.code": { "$exists": false } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false)
;

-- The case count is printed so a row cannot be dropped unnoticed.
SELECT count(*) AS cases_checked FROM safety_cases_base;

-- Every value below is one the planner actually produces, so this baseline
-- passes today. A case whose actual plan does not meet the requirement is
-- reported as MISSING OPTIMIZATION when a required pushdown is absent, and as
-- UNSAFE PUSHDOWN when a pushdown that must not happen did happen. A case
-- already reported as "contract met" must stay that way: those are the guard
-- rails.
SELECT s.case_name,
    s.expected_index_only AS required_index_only,
    e.actual_index_only,
    CASE WHEN s.expected_index_only = e.actual_index_only
        THEN 'contract met'
        WHEN s.expected_index_only THEN 'MISSING OPTIMIZATION'
        ELSE 'UNSAFE PUSHDOWN'
    END AS status
FROM safety_cases_base s,
    LATERAL (SELECT documentdb_test_helpers.explain_uses_index_only_scan(s.query, '[a-z0-9_]+')) e(actual_index_only)
ORDER BY 1;

-- ----------------------------------------------------------------------------
-- Truncated terms. A small indexTermLimitOverride forces truncation
-- deterministically. With value-only terms the composite metadata first
-- subtracts the two paths from the 50 byte limit, and the per-path budget is
-- then (48 / 2) - 4 = 20 serialized bytes. A UTF-8 term spends 12 of those on
-- fixed serialization overhead, leaving 8 bytes of value, so a 9 byte string is
-- the shortest one that is truncated. An equality whose term was truncated
-- cannot be decided from the index alone, so it must never become index-only,
-- even though the same equality on a shorter term is safe.
-- ----------------------------------------------------------------------------
SET documentdb.indexTermLimitOverride TO 50;

SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmkl_db', '{ "createIndexes": "trunc_coll", "indexes": [ { "key": { "grouping.code": 1, "detail.label": 1 }, "name": "grouping_code_detail_label_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmkl_db', 'trunc_coll', '{ "_id": 1, "grouping": [ { "code": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, { "code": "short" } ], "detail": { "label": "first" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'trunc_coll', '{ "_id": 2, "grouping": [ { "code": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab" } ], "detail": { "label": "second" } }');
-- Nine bytes is the shortest string that is truncated at this limit, and it
-- truncates to the same stored prefix as the two long values above, so an
-- equality filter on it has genuine false-positive candidates.
SELECT documentdb_api.insert_one('iosmkl_db', 'trunc_coll', '{ "_id": 3, "grouping": [ { "code": "aaaaaaaaa" } ], "detail": { "label": "third" } }');

SELECT collection_id AS trunc_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmkl_db' AND collection_name = 'trunc_coll' \gset

SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'trunc_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'trunc_cid') \gexec

-- The short comparand is not truncated, so it correctly returns only _id 1.
SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": "short" }, "projection": { "_id": 1 } }');

-- The boundary comparand truncates to the same stored prefix as _id 1 and _id 2,
-- so those two are false-positive candidates that only the document can rule out.
--
-- TODO: this is a separate defect from the index-only-scan gap this file is
-- about. The index scan below returns _id 1, 2 and 3, but only _id 3 actually
-- has a "grouping.code" equal to the comparand: the truncated candidates are
-- never rechecked against the document. The sequential scan immediately after
-- shows the correct answer. Once the recheck is fixed, the first result set
-- below collapses to _id 3 and matches the second.
SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": "aaaaaaaaa" }, "projection": { "_id": 1 } }');

set enable_seqscan to on;
set enable_indexscan to off;
SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": "aaaaaaaaa" }, "projection": { "_id": 1 } }');
set enable_seqscan to off;
set enable_indexscan to on;

CREATE TEMP TABLE safety_cases_truncated(case_name text, query text, expected_index_only boolean);
INSERT INTO safety_cases_truncated VALUES
    ('unsafe: eq truncated string',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: gt truncated string',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": { "$gt": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: gte truncated string',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": { "$gte": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: lt truncated string',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": { "$lt": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: lte truncated string',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": { "$lte": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: range between truncated strings',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": { "$gte": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "$lte": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: in with truncated string',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": { "$in": [ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    -- A comparand whose own term is truncated cannot be told apart from a stored
    -- truncated term that merely shares its prefix. It matches _id 3 exactly,
    -- with _id 1 and _id 2 as false-positive candidates on the same prefix.
    ('unsafe: eq string at the truncation boundary',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": "aaaaaaaaa" }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    -- A comparand well short of the truncation boundary is not lossy: no stored
    -- truncated term can compare equal to it, because every truncated term is
    -- longer than the comparand at the point where the comparison is decided.
    ('safe: eq short string against truncated terms',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": "short" }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true),
    -- $exists true is decided by the presence of a term, never by its value, so
    -- truncation does not make it lossy.
    ('safe: exists true against truncated terms',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "trunc_coll", "filter": { "grouping.code": { "$exists": true } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true)
;

-- The case count is printed so a row cannot be dropped unnoticed.
SELECT count(*) AS cases_checked FROM safety_cases_truncated;

-- Every value below is one the planner actually produces, so this baseline
-- passes today. A case whose actual plan does not meet the requirement is
-- reported as MISSING OPTIMIZATION when a required pushdown is absent, and as
-- UNSAFE PUSHDOWN when a pushdown that must not happen did happen. A case
-- already reported as "contract met" must stay that way: those are the guard
-- rails.
SELECT s.case_name,
    s.expected_index_only AS required_index_only,
    e.actual_index_only,
    CASE WHEN s.expected_index_only = e.actual_index_only
        THEN 'contract met'
        WHEN s.expected_index_only THEN 'MISSING OPTIMIZATION'
        ELSE 'UNSAFE PUSHDOWN'
    END AS status
FROM safety_cases_truncated s,
    LATERAL (SELECT documentdb_test_helpers.explain_uses_index_only_scan(s.query, '[a-z0-9_]+')) e(actual_index_only)
ORDER BY 1;

RESET documentdb.indexTermLimitOverride;

-- ============================================================================
-- Single path index on a multi-key path, where the pipeline reads NO document
-- field at all.
--
-- A $match on { "<path>": { "$exists": true } } followed by a $group that only
-- counts needs nothing but the set of matching row identifiers. No projected
-- value has to be reconstructed, so the multi-key state of the single indexed
-- path cannot make the answer lossy: existence is decided by the presence of a
-- term, and the scan already has to deduplicate row identifiers for a multi-key
-- path regardless of the plan shape.
--
-- The $exists count-only shape above now pushes down to an Index Only Scan.
-- Equality on the multi-key path still does not when the comparand is a string,
-- because string index terms can be truncated and a truncated term needs the
-- document to settle the match.
--
-- TODO: string comparands should also push down when the index term is known to
-- be non-truncated. Truncation is a property of the term, not of the type, so
-- banning the whole type is stricter than correctness requires. The cases below
-- reported as MISSING OPTIMIZATION are the ones this would fix.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmkl_db', '{ "createIndexes": "single_path_coll", "indexes": [ { "key": { "grouping.code": 1 }, "name": "grouping_code_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 1, "grouping": [ { "code": "alpha" }, { "code": "beta" } ], "detail": { "label": "first" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 2, "grouping": [ { "code": "alpha" } ], "detail": { "label": "second" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 3, "grouping": { "code": "gamma" }, "detail": { "label": "third" } }');
-- No "grouping" at all, so it must not be counted by the $exists filter.
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 4, "detail": { "label": "fourth" } }');
-- Edge values for the path: an empty array, an explicit null, a single element
-- array, an empty parent array, and an array whose second entry lacks the field.
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 5, "grouping": { "code": [] }, "detail": { "label": "fifth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 6, "grouping": { "code": null }, "detail": { "label": "sixth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 7, "grouping": { "code": [ "alpha" ] }, "detail": { "label": "seventh" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 8, "grouping": [ ], "detail": { "label": "eighth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'single_path_coll', '{ "_id": 9, "grouping": [ { "code": "alpha" }, { "other": 1 } ], "detail": { "label": "ninth" } }');

SELECT collection_id AS sp_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmkl_db' AND collection_name = 'single_path_coll' \gset

SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'sp_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'sp_cid') \gexec

-- The single indexed path is multi-key. The "Group Key" line is filtered out
-- because it is printed on some PostgreSQL versions and elided on others.
SELECT l FROM documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": true } } }, { "$group": { "_id": 1, "n": { "$sum": 1 } } } ], "cursor": {} }') $cmd$, p_ignore_heap_fetches => true) l
WHERE l !~ 'Group Key: ';

-- The count is over documents, not over index entries: _id 1 carries two array
-- entries and must still be counted once, and _id 4 and _id 8 have no value at
-- "grouping.code" at all.
SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": true } } }, { "$group": { "_id": 1, "n": { "$sum": 1 } } } ], "cursor": {} }');

-- These two filters are required to be index-only above. The check below
-- compares the documents selected under an index scan with the documents
-- selected under a sequential scan, across the edge values inserted above.
--
-- This is result equivalence between the two scan methods, not proof that the
-- index terms alone decided every match: an index scan is allowed to fetch the
-- document and recheck, so agreement would also hold if a recheck were being
-- applied. What it does pin is that the index path selects the correct set of
-- documents for these filters, which is a precondition for making them
-- index-only. If either pair ever diverges, the index path is producing a wrong
-- answer and the corresponding requirement below must be revisited.
CREATE TEMP TABLE ixs_exists AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": true } } }, { "$group": { "_id": "$_id" } } ], "cursor": {} }')) s;
CREATE TEMP TABLE ixs_eq AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": "alpha" } }, { "$group": { "_id": "$_id" } } ], "cursor": {} }')) s;

set enable_seqscan to on;
set enable_indexscan to off;
CREATE TEMP TABLE seq_exists AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": true } } }, { "$group": { "_id": "$_id" } } ], "cursor": {} }')) s;
CREATE TEMP TABLE seq_eq AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": "alpha" } }, { "$group": { "_id": "$_id" } } ], "cursor": {} }')) s;
set enable_seqscan to off;
set enable_indexscan to on;

SELECT NOT EXISTS (SELECT d FROM ixs_exists EXCEPT SELECT d FROM seq_exists)
   AND NOT EXISTS (SELECT d FROM seq_exists EXCEPT SELECT d FROM ixs_exists) AS exists_true_agrees,
       NOT EXISTS (SELECT d FROM ixs_eq EXCEPT SELECT d FROM seq_eq)
   AND NOT EXISTS (SELECT d FROM seq_eq EXCEPT SELECT d FROM ixs_eq) AS eq_alpha_agrees,
       (SELECT count(*) FROM seq_exists) AS exists_true_matches,
       (SELECT count(*) FROM seq_eq) AS eq_alpha_matches;

CREATE TEMP TABLE safety_cases_count_only(case_name text, query text, expected_index_only boolean);
INSERT INTO safety_cases_count_only VALUES
    ('safe: exists true with count only',
     $q$ SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": true } } }, { "$group": { "_id": 1, "n": { "$sum": 1 } } } ], "cursor": {} }') $q$,
     true),
    ('safe: exists true with count only and limit',
     $q$ SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": true } } }, { "$group": { "_id": 1, "n": { "$sum": 1 } } }, { "$limit": 20 } ], "cursor": {} }') $q$,
     true),
    ('safe: string eq on multi-key path with count only',
     $q$ SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": "alpha" } }, { "$group": { "_id": 1, "n": { "$sum": 1 } } } ], "cursor": {} }') $q$,
     true),
    -- Grouping BY the indexed multi-key path is not the same thing: the group key
    -- has to be reconstructed from the document, because an index term is per
    -- array element and may itself be truncated.
    ('unsafe: group by the multi-key path',
     $q$ SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "single_path_coll", "pipeline": [ { "$match": { "grouping.code": { "$exists": true } } }, { "$group": { "_id": "$grouping.code", "n": { "$sum": 1 } } } ], "cursor": {} }') $q$,
     false)
;

-- The case count is printed so a row cannot be dropped unnoticed.
SELECT count(*) AS cases_checked FROM safety_cases_count_only;

-- Every value below is one the planner actually produces, so this baseline
-- passes today. A case whose actual plan does not meet the requirement is
-- reported as MISSING OPTIMIZATION when a required pushdown is absent, and as
-- UNSAFE PUSHDOWN when a pushdown that must not happen did happen. A case
-- already reported as "contract met" must stay that way: those are the guard
-- rails.
SELECT s.case_name,
    s.expected_index_only AS required_index_only,
    e.actual_index_only,
    CASE WHEN s.expected_index_only = e.actual_index_only
        THEN 'contract met'
        WHEN s.expected_index_only THEN 'MISSING OPTIMIZATION'
        ELSE 'UNSAFE PUSHDOWN'
    END AS status
FROM safety_cases_count_only s,
    LATERAL (SELECT documentdb_test_helpers.explain_uses_index_only_scan(s.query, '[a-z0-9_]+')) e(actual_index_only)
ORDER BY 1;

-- ============================================================================
-- Extreme value bounds on a multi-key path.
--
-- A strict bound against MinKey or MaxKey is not the same as a strict bound
-- against an ordinary value. MinKey sorts below every value and MaxKey above
-- every value, so "$gt: MinKey" and "$lt: MaxKey" cannot exclude anything by
-- ordering alone. They are turned into an existence bound plus a runtime
-- recheck, because the only rows they exclude are the ones whose value IS the
-- literal extreme, while a document whose value is an ARRAY beginning with that
-- extreme still matches.
--
-- That distinction is invisible in the index: an array contributes one term per
-- element, so a document holding the literal MinKey and a document holding
-- [ MinKey, ... ] both produce a MinKey term. Only the document separates them,
-- so these shapes must not be served by an Index Only Scan.
--
-- The inclusive forms carry no such recheck: "$gte: MinKey" and "$lte: MaxKey"
-- match every document that has the path at all, so they reduce to an existence
-- test and are safe.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmkl_db', '{ "createIndexes": "extremes_coll", "indexes": [ { "key": { "grouping.code": 1, "detail.label": 1 }, "name": "extremes_code_label_1", "enableOrderedIndex": 1 } ] }', true);

-- _id 1 and 3 hold the literal extreme, so a strict bound must exclude them.
-- _id 2 and 4 hold an array that begins with the extreme, so a strict bound must
-- keep them. Both pairs produce the same leading index term.
SELECT documentdb_api.insert_one('iosmkl_db', 'extremes_coll', '{ "_id": 1, "grouping": { "code": { "$minKey": 1 } }, "detail": { "label": "first" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'extremes_coll', '{ "_id": 2, "grouping": { "code": [ { "$minKey": 1 }, "zulu" ] }, "detail": { "label": "second" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'extremes_coll', '{ "_id": 3, "grouping": { "code": { "$maxKey": 1 } }, "detail": { "label": "third" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'extremes_coll', '{ "_id": 4, "grouping": { "code": [ { "$maxKey": 1 }, "alpha" ] }, "detail": { "label": "fourth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'extremes_coll', '{ "_id": 5, "grouping": [ { "code": "alpha" }, { "code": "beta" } ], "detail": { "label": "fifth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'extremes_coll', '{ "_id": 6, "detail": { "label": "sixth" } }');

SELECT collection_id AS ex_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmkl_db' AND collection_name = 'extremes_coll' \gset

SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'ex_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'ex_cid') \gexec

-- The strict bounds must not degenerate into a plain existence test: each one
-- drops exactly the document holding the literal extreme and keeps the array.
SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "extremes_coll", "pipeline": [ { "$match": { "grouping.code": { "$gt": { "$minKey": 1 } } } }, { "$group": { "_id": 1, "ids": { "$addToSet": "$_id" } } } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "extremes_coll", "pipeline": [ { "$match": { "grouping.code": { "$lt": { "$maxKey": 1 } } } }, { "$group": { "_id": 1, "ids": { "$addToSet": "$_id" } } } ], "cursor": {} }');

CREATE TEMP TABLE safety_cases_extremes(case_name text, query text, expected_index_only boolean);
INSERT INTO safety_cases_extremes VALUES
    ('unsafe: gt minkey',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$gt": { "$minKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: lt maxkey',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$lt": { "$maxKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('safe: gte minkey',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$gte": { "$minKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true),
    ('safe: lte maxkey',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$lte": { "$maxKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true)
;

-- The case count is printed so a row cannot be dropped unnoticed.
SELECT count(*) AS cases_checked FROM safety_cases_extremes;

-- Every value below is one the planner actually produces, so this baseline
-- passes today. A case whose actual plan does not meet the requirement is
-- reported as MISSING OPTIMIZATION when a required pushdown is absent, and as
-- UNSAFE PUSHDOWN when a pushdown that must not happen did happen. A case
-- already reported as "contract met" must stay that way: those are the guard
-- rails.
SELECT s.case_name,
    s.expected_index_only AS required_index_only,
    e.actual_index_only,
    CASE WHEN s.expected_index_only = e.actual_index_only
        THEN 'contract met'
        WHEN s.expected_index_only THEN 'MISSING OPTIMIZATION'
        ELSE 'UNSAFE PUSHDOWN'
    END AS status
FROM safety_cases_extremes s,
    LATERAL (SELECT documentdb_test_helpers.explain_uses_index_only_scan(s.query, '[a-z0-9_]+')) e(actual_index_only)
ORDER BY 1;

-- The answer must not depend on the plan. If a strict extreme bound is served
-- without the document, the literal extreme and the array beginning with it stop
-- being distinguishable and these two sets diverge.
CREATE TEMP TABLE ixs_gt_min AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$gt": { "$minKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;
CREATE TEMP TABLE ixs_lt_max AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$lt": { "$maxKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;

set enable_seqscan to on;
set enable_indexscan to off;

CREATE TEMP TABLE seq_gt_min AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$gt": { "$minKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;
CREATE TEMP TABLE seq_lt_max AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "extremes_coll", "filter": { "grouping.code": { "$lt": { "$maxKey": 1 } } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;

set enable_seqscan to off;
set enable_indexscan to on;

SELECT NOT EXISTS (SELECT d FROM ixs_gt_min EXCEPT SELECT d FROM seq_gt_min)
   AND NOT EXISTS (SELECT d FROM seq_gt_min EXCEPT SELECT d FROM ixs_gt_min) AS gt_minkey_agrees,
       NOT EXISTS (SELECT d FROM ixs_lt_max EXCEPT SELECT d FROM seq_lt_max)
   AND NOT EXISTS (SELECT d FROM seq_lt_max EXCEPT SELECT d FROM ixs_lt_max) AS lt_maxkey_agrees,
       (SELECT count(*) FROM ixs_gt_min) AS gt_minkey_index_rows,
       (SELECT count(*) FROM seq_gt_min) AS gt_minkey_seqscan_rows,
       (SELECT count(*) FROM ixs_lt_max) AS lt_maxkey_index_rows,
       (SELECT count(*) FROM seq_lt_max) AS lt_maxkey_seqscan_rows;

-- Printed side by side so a divergence names the offending documents.
SELECT d AS gt_minkey_index_rows FROM ixs_gt_min ORDER BY 1;
SELECT d AS gt_minkey_seqscan_rows FROM seq_gt_min ORDER BY 1;

-- ============================================================================
-- More than one index qual on the same column.
--
-- A two sided range such as { "$gte": 5, "$lte": 9 } is not one qual, it is two
-- quals against the same index column, and the index collapses them into a
-- single bound [5, 9]. For a scalar path that is exact. For a MULTI-KEY path it
-- is not, because the documented semantics let DIFFERENT array elements satisfy
-- DIFFERENT clauses: [ 1, 100 ] matches, since 100 satisfies "$gte": 5 and 1
-- satisfies "$lte": 9, yet NO single element falls inside [5, 9].
--
-- An index entry is per array element, so the combined bound cannot represent
-- that. The document is required to settle it, which means a plan serving this
-- shape from the index alone silently drops matching rows.
--
-- The same argument applies to any column carrying more than one qual, whatever
-- the types involved, so it is a stronger and simpler rule than enumerating
-- which operator and type pairs happen to be safe.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmkl_db', '{ "createIndexes": "multiqual_coll", "indexes": [ { "key": { "grouping.code": 1, "detail.label": 1 }, "name": "multiqual_code_label_1", "enableOrderedIndex": 1 } ] }', true);

-- _id 1 and _id 5 are the spanning documents: they match only because the two
-- clauses are satisfied by different elements. Every other document either has a
-- single element inside the range or is outside it entirely.
SELECT documentdb_api.insert_one('iosmkl_db', 'multiqual_coll', '{ "_id": 1, "grouping": { "code": [ 1, 100 ] }, "detail": { "label": "first" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'multiqual_coll', '{ "_id": 2, "grouping": { "code": 7 }, "detail": { "label": "second" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'multiqual_coll', '{ "_id": 3, "grouping": { "code": [ 7, 200 ] }, "detail": { "label": "third" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'multiqual_coll', '{ "_id": 4, "grouping": { "code": [ 1, 2 ] }, "detail": { "label": "fourth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'multiqual_coll', '{ "_id": 5, "grouping": { "code": [ "aa", "zz" ] }, "detail": { "label": "fifth" } }');
SELECT documentdb_api.insert_one('iosmkl_db', 'multiqual_coll', '{ "_id": 6, "grouping": { "code": "am" }, "detail": { "label": "sixth" } }');

SELECT collection_id AS mq_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmkl_db' AND collection_name = 'multiqual_coll' \gset

SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'mq_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'mq_cid') \gexec

-- The spanning documents must be in the answer: _id 1 for the numeric range and
-- _id 5 for the string range.
SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "multiqual_coll", "pipeline": [ { "$match": { "grouping.code": { "$gte": 5, "$lte": 9 } } }, { "$group": { "_id": 1, "ids": { "$addToSet": "$_id" } } } ], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('iosmkl_db', '{ "aggregate": "multiqual_coll", "pipeline": [ { "$match": { "grouping.code": { "$gte": "ab", "$lte": "az" } } }, { "$group": { "_id": 1, "ids": { "$addToSet": "$_id" } } } ], "cursor": {} }');

CREATE TEMP TABLE safety_cases_multiqual(case_name text, query text, expected_index_only boolean);
INSERT INTO safety_cases_multiqual VALUES
    ('unsafe: two quals on the column, numeric range',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": 5, "$lte": 9 } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('unsafe: two quals on the column, string range',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": "ab", "$lte": "az" } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     false),
    ('safe: one qual on the column, single sided range',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": 5 } }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true),
    ('safe: one qual on the column, equality',
     $q$ SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": 7 }, "projection": { "_id": 0, "detail.label": 1 } }') $q$,
     true)
;

-- The case count is printed so a row cannot be dropped unnoticed.
SELECT count(*) AS cases_checked FROM safety_cases_multiqual;

-- Every value below is one the planner actually produces, so this baseline
-- passes today. A case whose actual plan does not meet the requirement is
-- reported as MISSING OPTIMIZATION when a required pushdown is absent, and as
-- UNSAFE PUSHDOWN when a pushdown that must not happen did happen. A case
-- already reported as "contract met" must stay that way: those are the guard
-- rails.
SELECT s.case_name,
    s.expected_index_only AS required_index_only,
    e.actual_index_only,
    CASE WHEN s.expected_index_only = e.actual_index_only
        THEN 'contract met'
        WHEN s.expected_index_only THEN 'MISSING OPTIMIZATION'
        ELSE 'UNSAFE PUSHDOWN'
    END AS status
FROM safety_cases_multiqual s,
    LATERAL (SELECT documentdb_test_helpers.explain_uses_index_only_scan(s.query, '[a-z0-9_]+')) e(actual_index_only)
ORDER BY 1;

-- The answer must not depend on the plan. A divergence here is a wrong answer,
-- not a missed optimization.
CREATE TEMP TABLE ixs_mq_num AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": 5, "$lte": 9 } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;
CREATE TEMP TABLE ixs_mq_str AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": "ab", "$lte": "az" } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;

set enable_seqscan to on;
set enable_indexscan to off;

CREATE TEMP TABLE seq_mq_num AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": 5, "$lte": 9 } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;
CREATE TEMP TABLE seq_mq_str AS SELECT s.document::text AS d FROM (SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": "ab", "$lte": "az" } }, "projection": { "_id": 0, "detail.label": 1 } }')) s;

set enable_seqscan to off;
set enable_indexscan to on;

SELECT NOT EXISTS (SELECT d FROM ixs_mq_num EXCEPT SELECT d FROM seq_mq_num)
   AND NOT EXISTS (SELECT d FROM seq_mq_num EXCEPT SELECT d FROM ixs_mq_num) AS numeric_range_agrees,
       NOT EXISTS (SELECT d FROM ixs_mq_str EXCEPT SELECT d FROM seq_mq_str)
   AND NOT EXISTS (SELECT d FROM seq_mq_str EXCEPT SELECT d FROM ixs_mq_str) AS string_range_agrees,
       (SELECT count(*) FROM ixs_mq_num) AS numeric_index_rows,
       (SELECT count(*) FROM seq_mq_num) AS numeric_seqscan_rows,
       (SELECT count(*) FROM ixs_mq_str) AS string_index_rows,
       (SELECT count(*) FROM seq_mq_str) AS string_seqscan_rows;

-- Printed side by side so a divergence names the offending documents.
SELECT d AS numeric_range_index_rows FROM ixs_mq_num ORDER BY 1;
SELECT d AS numeric_range_seqscan_rows FROM seq_mq_num ORDER BY 1;

-- The plans behind the two rows above, so the reason a shape is refused is
-- visible rather than inferred.
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": 7 }, "projection": { "_id": 0, "detail.label": 1 } }') $cmd$, p_ignore_heap_fetches => true);

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosmkl_db', '{ "find": "multiqual_coll", "filter": { "grouping.code": { "$gte": 5, "$lte": 9 } }, "projection": { "_id": 0, "detail.label": 1 } }') $cmd$, p_ignore_heap_fetches => true);
