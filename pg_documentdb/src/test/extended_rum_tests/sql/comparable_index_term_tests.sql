
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 1500;
SET documentdb.next_collection_index_id TO 1500;

CREATE SCHEMA comparable_indexterm_test_schema;

CREATE TABLE comparable_indexterm_test_schema.test_round_trip_table (data bson);
INSERT INTO comparable_indexterm_test_schema.test_round_trip_table VALUES 
    ('{ "$": { "$minKey": 1 }, "$flags": 5 }'), ('{ "$": { "$maxKey": 1 }, "$flags": 5 }'),
    ('{ "$": null, "$flags": 5 }'), ('{ "$": true, "$flags": 5 }'), ('{ "$": false, "$flags": 5 }'),
    ('{ "$": { "$numberInt": "42" }, "$flags": 5 }'),
    ('{ "$": "hello", "$flags": 5 }'), 
    ('{ "$": { "$undefined": true }, "$flags": 12 }'), -- partial undefined value
    ('{ "$": { "$oid": "507f1f77bcf86cd799439011" }, "$flags": 5 }'),
    ('{ "$": { "a": 1, "b": "text" }, "$flags": 5 }'),
    ('{ "$": [ 1, "two", { "three": 3 } ], "$flags": 5 }'),
    ('{ "$": { "$code": "mystringCode" }, "$flags": 5 }'),
    ('{ "$": { "$binary": { "base64": "SGVsbG8=", "subType": "00" } }, "$flags": 5 }'), 
    ('{ "$": { "$date": { "$numberLong": "1627846267000" } }, "$flags": 5 }'),
    ('{ "$": { "$timestamp": { "t": 1627846267, "i": 1 } }, "$flags": 5 }'),
    ('{ "$": { "$undefined": true }, "$flags": 8 }'), -- undefined value
    ('{ "$": { "$regularExpression": { "pattern": "pattern", "options": "i" } }, "$flags": 5 }'),
    ('{ "$": { "$dbPointer": { "$ref": "collection", "$id": { "$oid": "507f1f77bcf86cd799439011" } } }, "$flags": 5 }'),
    ('{ "$": { "$numberLong": "41" }, "$flags": 5 }'),
    ('{ "$": { "$undefined": true }, "$flags": 5 }'),
    ('{ "$": { "$numberDouble": "3.14" }, "$flags": 5 }'), 
    ('{ "$": { "$numberDecimal": "123.456" }, "$flags": 5 }');

-- test round tripping of comparable terms.
SELECT documentdb_api_internal.bson_to_bsonindexterm(data), 
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)),
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)) = data AS round_trips
FROM comparable_indexterm_test_schema.test_round_trip_table ORDER BY documentdb_api_internal.bson_to_bsonindexterm(data) ASC;

set documentdb.enableComparableTerms to on;
SELECT documentdb_api_internal.bson_to_bsonindexterm(data), 
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)),
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)) = data AS round_trips
FROM comparable_indexterm_test_schema.test_round_trip_table ORDER BY documentdb_api_internal.bson_to_bsonindexterm(data) ASC;

-- now update this for descending terms.
UPDATE comparable_indexterm_test_schema.test_round_trip_table set data = bson_build_document('$', data->'$', '$flags', (data->>'$flags')::int + 128);

-- test round tripping of value only terms.
set documentdb.enableComparableTerms to off;
SELECT documentdb_api_internal.bson_to_bsonindexterm(data), 
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)),
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)) = data AS round_trips
FROM comparable_indexterm_test_schema.test_round_trip_table ORDER BY documentdb_api_internal.bson_to_bsonindexterm(data) ASC;

-- test round tripping of comparable terms.
set documentdb.enableComparableTerms to on;
SELECT documentdb_api_internal.bson_to_bsonindexterm(data), 
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)),
       documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)) = data AS round_trips
FROM comparable_indexterm_test_schema.test_round_trip_table ORDER BY documentdb_api_internal.bson_to_bsonindexterm(data) ASC;

-- ===================================================================
-- Power-of-2 roundtrip tests
-- Powers of 2 produce IEEE 754 representations with many trailing zero
-- bits, which stress the variable-length continuation byte encoding in
-- EncodeSortableDouble. Values like 2.0 where the lower 56 bits are
-- all zero previously caused a 1-byte encoding bug.
-- ===================================================================
SET documentdb.enableComparableTerms TO on;

CREATE TABLE comparable_indexterm_test_schema.test_pow2_round_trip (id serial, data bson);
INSERT INTO comparable_indexterm_test_schema.test_pow2_round_trip (data) VALUES
    -- Fractional powers of 2 (doubles, not integers, roundtrip as double)
    ('{ "$": { "$numberDouble": "0.0625" }, "$flags": 5 }'),     -- 2^-4
    ('{ "$": { "$numberDouble": "0.125" }, "$flags": 5 }'),      -- 2^-3
    ('{ "$": { "$numberDouble": "0.25" }, "$flags": 5 }'),       -- 2^-2
    ('{ "$": { "$numberDouble": "0.5" }, "$flags": 5 }'),        -- 2^-1
    -- Positive powers of 2 as int32 (roundtrip preserves int32 type)
    ('{ "$": { "$numberInt": "1" }, "$flags": 5 }'),             -- 2^0
    ('{ "$": { "$numberInt": "2" }, "$flags": 5 }'),             -- 2^1
    ('{ "$": { "$numberInt": "4" }, "$flags": 5 }'),             -- 2^2
    ('{ "$": { "$numberInt": "8" }, "$flags": 5 }'),             -- 2^3
    ('{ "$": { "$numberInt": "16" }, "$flags": 5 }'),            -- 2^4
    ('{ "$": { "$numberInt": "32" }, "$flags": 5 }'),            -- 2^5
    ('{ "$": { "$numberInt": "64" }, "$flags": 5 }'),            -- 2^6
    ('{ "$": { "$numberInt": "128" }, "$flags": 5 }'),           -- 2^7
    ('{ "$": { "$numberInt": "256" }, "$flags": 5 }'),           -- 2^8
    ('{ "$": { "$numberInt": "512" }, "$flags": 5 }'),           -- 2^9
    ('{ "$": { "$numberInt": "1024" }, "$flags": 5 }'),          -- 2^10
    ('{ "$": { "$numberInt": "1048576" }, "$flags": 5 }'),       -- 2^20
    ('{ "$": { "$numberInt": "1073741824" }, "$flags": 5 }'),    -- 2^30
    -- Positive powers of 2 as int64 (within comparable threshold < 2^52)
    ('{ "$": { "$numberLong": "1099511627776" }, "$flags": 5 }'),    -- 2^40
    ('{ "$": { "$numberLong": "2251799813685248" }, "$flags": 5 }'), -- 2^51
    -- Boundary: 2^52 as int64 falls back to ValueOnly
    ('{ "$": { "$numberLong": "4503599627370496" }, "$flags": 5 }'), -- 2^52
    -- Large powers of 2 as double (bypass int64 limit check, gets comparable term)
    ('{ "$": { "$numberDouble": "4503599627370496" }, "$flags": 5 }'),      -- 2^52 as double
    ('{ "$": { "$numberDouble": "9007199254740992" }, "$flags": 5 }'),      -- 2^53
    ('{ "$": { "$numberDouble": "18014398509481984" }, "$flags": 5 }'),     -- 2^54
    ('{ "$": { "$numberDouble": "1152921504606846976" }, "$flags": 5 }'),   -- 2^60
    ('{ "$": { "$numberDouble": "4611686018427387904" }, "$flags": 5 }'),   -- 2^62
    -- Negative fractional powers of 2
    ('{ "$": { "$numberDouble": "-0.5" }, "$flags": 5 }'),       -- -2^-1
    ('{ "$": { "$numberDouble": "-0.25" }, "$flags": 5 }'),      -- -2^-2
    ('{ "$": { "$numberDouble": "-0.125" }, "$flags": 5 }'),     -- -2^-3
    -- Negative powers of 2 as int32
    ('{ "$": { "$numberInt": "-1" }, "$flags": 5 }'),            -- -2^0
    ('{ "$": { "$numberInt": "-2" }, "$flags": 5 }'),            -- -2^1
    ('{ "$": { "$numberInt": "-4" }, "$flags": 5 }'),            -- -2^2
    ('{ "$": { "$numberInt": "-8" }, "$flags": 5 }'),            -- -2^3
    ('{ "$": { "$numberInt": "-16" }, "$flags": 5 }'),           -- -2^4
    ('{ "$": { "$numberInt": "-64" }, "$flags": 5 }'),           -- -2^6
    ('{ "$": { "$numberInt": "-256" }, "$flags": 5 }'),          -- -2^8
    ('{ "$": { "$numberInt": "-1024" }, "$flags": 5 }'),         -- -2^10
    ('{ "$": { "$numberInt": "-1048576" }, "$flags": 5 }'),      -- -2^20
    ('{ "$": { "$numberInt": "-1073741824" }, "$flags": 5 }'),   -- -2^30
    -- Negative powers of 2 as int64
    ('{ "$": { "$numberLong": "-1099511627776" }, "$flags": 5 }'),    -- -2^40
    ('{ "$": { "$numberLong": "-2251799813685248" }, "$flags": 5 }'), -- -2^51
    -- Boundary: -2^52 as int64 falls back to ValueOnly (negative bound check)
    ('{ "$": { "$numberLong": "-4503599627370496" }, "$flags": 5 }'), -- -2^52
    -- Large negative powers of 2 as double
    ('{ "$": { "$numberDouble": "-4503599627370496" }, "$flags": 5 }'),     -- -2^52 as double
    ('{ "$": { "$numberDouble": "-9007199254740992" }, "$flags": 5 }'),     -- -2^53
    ('{ "$": { "$numberDouble": "-4611686018427387904" }, "$flags": 5 }');  -- -2^62

-- Roundtrip: every value must roundtrip correctly (round_trips = t)
SELECT
    documentdb_api_internal.bson_to_bsonindexterm(data),
    documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)),
    documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)) = data AS round_trips
FROM comparable_indexterm_test_schema.test_pow2_round_trip
ORDER BY id;

-- Ordering: for comparable terms (metadata 0x07), btree and binary ordering
-- must match. Filter to comparable terms only since ValueOnly (0x05) uses a
-- different comparison path. Should return 0 rows (no mismatches).
SELECT l.id AS left_id, r.id AS right_id,
    (l.term < r.term) AS btree_lt,
    (l.term::bytea < r.term::bytea) AS binary_lt
FROM (SELECT id, documentdb_api_internal.bson_to_bsonindexterm(data) AS term
      FROM comparable_indexterm_test_schema.test_pow2_round_trip
      WHERE get_byte(documentdb_api_internal.bson_to_bsonindexterm(data)::bytea, 0) = 7) l,
     (SELECT id, documentdb_api_internal.bson_to_bsonindexterm(data) AS term
      FROM comparable_indexterm_test_schema.test_pow2_round_trip
      WHERE get_byte(documentdb_api_internal.bson_to_bsonindexterm(data)::bytea, 0) = 7) r
WHERE l.id < r.id
  AND (l.term < r.term) != (l.term::bytea < r.term::bytea)
ORDER BY l.id, r.id;

-- ===================================================================
-- Negative int64 boundary tests
-- Validates that large negative int64 values that cannot roundtrip
-- through double without precision loss fall back to ValueOnly terms.
-- Without the negative bound check, values like -(2^53+1) would lose
-- precision when cast to double and produce incorrect comparable terms.
-- ===================================================================

CREATE TABLE comparable_indexterm_test_schema.test_neg_int64_boundary (id serial, data bson);
INSERT INTO comparable_indexterm_test_schema.test_neg_int64_boundary (data) VALUES
    -- Within comparable range (absolute value < 2^52): gets comparable term (0x07)
    ('{ "$": { "$numberLong": "-4503599627370495" }, "$flags": 5 }'),  -- -(2^52 - 1)
    ('{ "$": { "$numberLong": "4503599627370495" }, "$flags": 5 }'),   -- 2^52 - 1
    -- At boundary: falls back to ValueOnly (0x05)
    ('{ "$": { "$numberLong": "-4503599627370496" }, "$flags": 5 }'),  -- -2^52
    ('{ "$": { "$numberLong": "4503599627370496" }, "$flags": 5 }'),   -- 2^52
    -- Well beyond boundary: definitely falls back
    ('{ "$": { "$numberLong": "-9007199254740993" }, "$flags": 5 }'),  -- -(2^53 + 1)
    ('{ "$": { "$numberLong": "9007199254740993" }, "$flags": 5 }'),   -- 2^53 + 1
    ('{ "$": { "$numberLong": "-9223372036854775808" }, "$flags": 5 }'), -- INT64_MIN
    ('{ "$": { "$numberLong": "9223372036854775807" }, "$flags": 5 }');  -- INT64_MAX

-- Verify which values get comparable terms (0x07) vs ValueOnly (0x05)
SELECT id,
    data,
    documentdb_api_internal.bson_to_bsonindexterm(data),
    get_byte(documentdb_api_internal.bson_to_bsonindexterm(data)::bytea, 0) AS metadata_byte,
    CASE get_byte(documentdb_api_internal.bson_to_bsonindexterm(data)::bytea, 0)
        WHEN 7 THEN 'ComparableV1'
        WHEN 5 THEN 'ValueOnly'
        ELSE 'Unknown'
    END AS term_type
FROM comparable_indexterm_test_schema.test_neg_int64_boundary
ORDER BY id;

-- Roundtrip: all values must roundtrip regardless of term type
SELECT id,
    documentdb_api_internal.bsonindexterm_to_bson(documentdb_api_internal.bson_to_bsonindexterm(data)) = data AS round_trips
FROM comparable_indexterm_test_schema.test_neg_int64_boundary
ORDER BY id;

DROP SCHEMA comparable_indexterm_test_schema CASCADE;
