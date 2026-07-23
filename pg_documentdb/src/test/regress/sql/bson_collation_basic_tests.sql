SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 8300;
SET documentdb.next_collection_index_id TO 8300;

SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;

-- ============================================================================
-- Basic collation index support matrix.
--
-- Validates which index types accept a collation specification. Collation is
-- only supported on ordered (composite) indexes, and only when
-- enableCollationWithNonUniqueOrderedIndexes is enabled. Unique, non-ordered,
-- hashed, 2d, text and 2dsphere indexes must all reject collation.
-- ============================================================================

-- ordered/composite index with collation should fail when
-- enableCollationWithNonUniqueOrderedIndexes is OFF
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_guc_off_fail",
    "indexes": [{
      "key": { "a": 1 },
      "name": "a_coll_guc_off_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;

-- unique ordered index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_unique_fail",
    "indexes": [{
      "key": { "a": 1, "b": 1 },
      "name": "a_b_unique_coll_idx",
      "unique": true,
      "collation": { "locale": "en", "numericOrdering": true }
    }]
  }',
  TRUE
);

-- non-ordered index with collation should fail
SET documentdb.defaultUseCompositeOpClass TO off;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_non_ordered_fail",
    "indexes": [{
      "key": { "a": 1 },
      "name": "a_non_ordered_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

SET documentdb.defaultUseCompositeOpClass TO on;

-- hashed index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_hashed_fail",
    "indexes": [{
      "key": { "a": "hashed" },
      "name": "a_hashed_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- 2d index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_2d_fail",
    "indexes": [{
      "key": { "loc": "2d" },
      "name": "loc_2d_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- text index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_text_fail",
    "indexes": [{
      "key": { "content": "text" },
      "name": "content_text_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);

-- 2dsphere index with collation should fail
SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'ord_coll_ordered_db',
  '{
    "createIndexes": "ord_2dsphere_fail",
    "indexes": [{
      "key": { "loc": "2dsphere" },
      "name": "loc_2dsphere_coll_idx",
      "collation": { "locale": "en", "strength": 1 }
    }]
  }',
  TRUE
);
