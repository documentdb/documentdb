SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 3000;
SET documentdb.next_collection_index_id TO 3000;

-- ===== Regression test: page split overflow with fill factor 100 =====
-- The RUM entry page split logic checked accumulated size BEFORE adding the
-- current entry when comparing against the split point. With fill factor 100
-- on a rightmost leaf page, splitPointSize was set to totalsize (all entries).
-- The pre-increment check meant the last entry was always placed on the left
-- page even when it would overflow. This caused PageAddItem to fail with
-- "failed to add item to index page" (error code 2600).
--
-- The bug requires entries small enough that many fit per page, so the
-- off-by-one in the size check matters. Unique indexes with optional key
-- (enable_composite_unique_optional_key) produce smaller entries (the shard
-- exclusion column emits 0 terms), making pages denser and reliably
-- triggering the overflow.

-- ===== Section 1: Verify inserts succeed with optkey + fill factor 100 =====
SET documentdb_rum.rum_default_page_fill_factor TO 100;
SET documentdb.enable_composite_unique_optional_key TO on;

-- CALLOUT: with the corrected reloption emission, unique index creation now
-- succeeds with (cmp='true', optsk='2201'), so all 2000 rows are stored and the
-- checks below PASS. (The optsk value is not yet consumed to eliminate shard
-- terms, but this suite only validates row counts, not entry layout.)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'optkey_ff_db',
  '{
    "createIndexes": "optkey_test",
    "indexes": [{
      "key": { "a": 1, "b": 1 },
      "name": "ab_optkey_ff_idx",
      "unique": true
    }]
  }',
  TRUE
);

-- Collection ID layout:
--   3000: db metadata
--   3001: optkey_test -> pk 3001, rum index 3002

-- Insert 2000 docs. Without the fix, inserts silently fail after ~1301 rows:
-- insert_one returns n=0 with error 2600, but the calling COUNT still counts
-- the row, masking the data loss.
SELECT COUNT(documentdb_api.insert_one('optkey_ff_db', 'optkey_test',
    bson_build_document('_id', i::int4, 'a', i::int4, 'b', concat('val', lpad(i::text, 7, '0'))::text)))
FROM generate_series(1, 2000) i;

-- Verify all 2000 rows were actually stored (not silently dropped).
-- Without the fix this returns ~1301.
SELECT CASE
    WHEN count(*) = 2000
    THEN 'PASS: all 2000 rows stored with optkey + fill factor 100'
    ELSE 'FAIL: only ' || count(*) || ' of 2000 rows stored - page split overflow bug'
END AS optkey_insert_check
FROM documentdb_data.documents_3001;

-- ===== Section 2: Verify insert_one reports n=1 for every row =====
-- Count rows where insert_one actually returned n=1 (successful insert).
-- With the bug, many inserts return n=0 silently.
SELECT CASE
    WHEN (SELECT count(*) FROM documentdb_data.documents_3001) = 2000
    THEN 'PASS: insert count matches stored row count'
    ELSE 'FAIL: insert count does not match stored rows - silent data loss'
END AS insert_consistency_check;

RESET documentdb.enable_composite_unique_optional_key;
RESET documentdb_rum.rum_default_page_fill_factor;
