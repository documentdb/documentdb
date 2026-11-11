-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

SET search_path TO documentdb_core;

SELECT pg_typeof(bson_to_bson_external('{}'::bson)) AS result_type;
SELECT typname, typlen, typbyval, typalign, typstorage
FROM pg_catalog.pg_type
WHERE oid = 'bson_external'::regtype;

SELECT bson_to_bson_external(NULL::bson) IS NULL AS compress_null,
       bson_external_to_bson(NULL::bson_external) IS NULL AS decompress_null;

-- Every document is compressed, even when frame overhead makes it larger.
SELECT pg_column_size(bson_to_bson_external('{}'::bson)) >
       pg_column_size('{}'::bson) AS small_document_uses_zstd;

-- Reference dictionary-free frames verify the four-byte header and one-byte flag.
WITH fixtures(name, document, zstd_frame) AS (
    VALUES
        ('empty', '{}'::bson, '\x28b52ffd20052900000500000000'::bytea),
        ('int32', '{"value":42}'::bson, '\x28b52ffd2010810000100000001076616c7565002a00000000'::bytea)
)
SELECT name,
       octet_length(bson_to_bytea(document)) AS bson_bytes,
       octet_length(zstd_frame) AS zstd_frame_bytes,
       pg_column_size(bson_to_bson_external(document)) AS compressed_size,
       pg_column_size(bson_to_bson_external(document)) - octet_length(zstd_frame)
           AS storage_overhead_bytes,
       bson_external_send(bson_to_bson_external(document)) = '\x01'::bytea || zstd_frame
           AS binary_format_matches
FROM fixtures ORDER BY name;

CREATE TABLE bson_external_test (id integer, document bson, compressed bson_external);
ALTER TABLE bson_external_test ALTER COLUMN document SET STORAGE EXTERNAL;

INSERT INTO bson_external_test (id, document) VALUES
    (1, '{}'),
    (2, '{"i":42,"n":null,"b":true,"a":[1,"two",{"x":3}],"d":{"$date":{"$numberLong":"123"}}}'),
    (3, '{"bin":{"$binary":{"base64":"AAECA/8=","subType":"00"}},"oid":{"$oid":"5d505646cf6d4fe581014ab2"}}'),
    (4, '{"unicode":"caf\u00e9 \u4e2d\u6587","long":{"$numberLong":"9223372036854775807"}}');
INSERT INTO bson_external_test (id, document)
SELECT 5, format('{"value":"%s"}', repeat('abc', 30000))::bson;
INSERT INTO bson_external_test (id, document)
SELECT 6, format('{"value":"%s"}', string_agg(md5(i::text), '' ORDER BY i))::bson
FROM generate_series(1, 8192) AS i;

UPDATE bson_external_test SET compressed = bson_to_bson_external(document);

SELECT id,
       bson_to_bytea(bson_external_to_bson(compressed)) = bson_to_bytea(document) AS round_trip,
       get_byte(bson_external_send(compressed), 0) = 1 AS binary_send_uses_zstd,
       bson_to_bytea(compressed::bson) = bson_to_bytea(document) AS explicit_cast
FROM bson_external_test ORDER BY id;

SELECT pg_column_size(bson_to_bson_external(document)) < octet_length(bson_to_bytea(document)) / 10
       AS compression_reduces_size
FROM bson_external_test WHERE id = 5;

-- Exercise both packed inline values and externally stored, incompressible input.
SELECT id, pg_column_size(compressed) > 0 AS compressed_size_available,
       bson_to_bytea(bson_external_to_bson(bson_to_bson_external(document))) =
           bson_to_bytea(document)
       AS recompress_round_trip
FROM bson_external_test ORDER BY id;

SET documentdb_core.bsonUseEJson TO true;
SELECT '{"value":42}'::bson_external;
SELECT 'BSONHEX100000001076616c7565002a00000000'::bson_external;
SET documentdb_core.bsonUseEJson TO false;
SELECT '{"value":42}'::bson_external;

CREATE TABLE bson_external_copy (LIKE bson_external_test);
\copy bson_external_test TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_copy FROM 'bson_external_type.bin' WITH (FORMAT binary)
SELECT count(*) = 6 AND bool_and(
           bson_external_send(c.compressed) = bson_external_send(t.compressed) AND
           bson_to_bytea(bson_external_to_bson(c.compressed)) = bson_to_bytea(t.document))
       AS binary_copy_round_trip
FROM bson_external_copy c JOIN bson_external_test t USING (id);

TRUNCATE bson_external_copy;
\copy bson_external_test TO 'bson_external_type.txt'
\copy bson_external_copy FROM 'bson_external_type.txt'
SELECT count(*) = 6 AND bool_and(
           bson_to_bytea(bson_external_to_bson(c.compressed)) = bson_to_bytea(t.document))
       AS hex_copy_round_trip
FROM bson_external_copy c JOIN bson_external_test t USING (id);

SET documentdb_core.bsonUseEJson TO true;
TRUNCATE bson_external_copy;
\copy bson_external_test TO 'bson_external_type.txt'
\copy bson_external_copy FROM 'bson_external_type.txt'
SELECT count(*) = 6 AND bool_and(
           bson_to_bytea(bson_external_to_bson(c.compressed)) = bson_to_bytea(t.document))
       AS json_copy_round_trip
FROM bson_external_copy c JOIN bson_external_test t USING (id);

-- A test-only binary-compatible cast constructs stored flag-0 payloads.
CREATE CAST (bytea AS bson_external) WITHOUT FUNCTION;
CREATE TABLE bson_external_uncompressed AS
SELECT id, document, ('\x00'::bytea || bson_to_bytea(document))::bson_external AS external
FROM bson_external_test;

SELECT id,
       bson_to_bytea(bson_external_to_bson(external)) = bson_to_bytea(document)
           AS uncompressed_round_trip,
       bson_external_send(external) = '\x00'::bytea || bson_to_bytea(document)
           AS uncompressed_binary_send,
       bson_to_bytea(external::bson) = bson_to_bytea(document) AS uncompressed_cast,
       bson_to_bytea(external::text::bson) = bson_to_bytea(document) AS uncompressed_text
FROM bson_external_uncompressed ORDER BY id;

TRUNCATE bson_external_copy;
\copy bson_external_uncompressed TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_copy FROM 'bson_external_type.bin' WITH (FORMAT binary)
SELECT count(*) = 6 AND bool_and(
           bson_external_send(c.compressed) = bson_external_send(t.external) AND
           bson_to_bytea(bson_external_to_bson(c.compressed)) = bson_to_bytea(t.document))
       AS uncompressed_binary_copy_round_trip
FROM bson_external_copy c JOIN bson_external_uncompressed t USING (id);

-- Binary COPY from bytea supplies exact encoded bytes to the receive function.
CREATE TABLE bson_external_binary_input (id integer, encoded bytea);
CREATE TABLE bson_external_binary_received (id integer, external bson_external);
INSERT INTO bson_external_binary_input VALUES
    (1, '\x000500000000'),
    (2, '\x0128b52ffd20052000000500000009000000');
\copy bson_external_binary_input TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_binary_received FROM 'bson_external_type.bin' WITH (FORMAT binary)
SELECT r.id, bson_external_send(r.external) = i.encoded AS binary_bytes_preserved,
       bson_to_bytea(bson_external_to_bson(r.external)) = bson_to_bytea('{}'::bson)
           AS binary_document_preserved
FROM bson_external_binary_received r JOIN bson_external_binary_input i USING (id)
ORDER BY r.id;

\set VERBOSITY terse
SELECT 'not json'::bson_external;
SELECT 'BSONHEX00000000'::bson_external;
SELECT bson_external_to_bson('\x00'::bytea::bson_external);
SELECT bson_external_to_bson('\x000800000010780000'::bytea::bson_external);
SELECT bson_external_to_bson('\x02'::bytea::bson_external);
SELECT bson_external_to_bson('\x'::bytea::bson_external);

-- Header-only frames declare 100 MiB + 1 and 1 GiB of output. Reject their
-- declared sizes before allocating or attempting to decompress missing blocks.
SELECT bson_external_to_bson('\x0128b52ffda001004006'::bytea::bson_external);
SELECT bson_external_to_bson('\x0128b52ffda000000040'::bytea::bson_external);

TRUNCATE bson_external_binary_input;
INSERT INTO bson_external_binary_input VALUES (1, '\x0128b52ffda001004006');
\copy bson_external_binary_input TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_binary_received FROM 'bson_external_type.bin' WITH (FORMAT binary)

-- A BSON document with one "value" string has 17 bytes of encoding overhead.
-- Reuse a valid document exactly one byte above the limit for both other paths.
CREATE TEMP TABLE bson_external_oversized AS
SELECT bson_build_document('value', repeat('a', 100 * 1024 * 1024 - 16)) AS document;
SELECT octet_length(bson_to_bytea(document)) = 100 * 1024 * 1024 + 1
       AS oversized_document_is_one_byte_above_limit
FROM bson_external_oversized;

SELECT bson_external_to_bson(('\x00'::bytea || bson_to_bytea(document))::bson_external)
FROM bson_external_oversized;
SELECT bson_to_bson_external(document) FROM bson_external_oversized;
DROP TABLE bson_external_oversized;

-- Exactly 100 MiB remains valid through raw decoding and compression.
CREATE TEMP TABLE bson_external_at_limit AS
SELECT bson_build_document('value', repeat('a', 100 * 1024 * 1024 - 17)) AS document;
SELECT octet_length(bson_to_bytea(document)) = 100 * 1024 * 1024
       AS document_is_exactly_at_limit
FROM bson_external_at_limit;

SELECT bson_to_bytea(bson_external_to_bson(
           ('\x00'::bytea || bson_to_bytea(document))::bson_external))
       = bson_to_bytea(document) AS raw_at_limit_round_trip
FROM bson_external_at_limit;
SELECT bson_to_bytea(bson_external_to_bson(bson_to_bson_external(document)))
       = bson_to_bytea(document) AS compressed_at_limit_round_trip
FROM bson_external_at_limit;
DROP TABLE bson_external_at_limit;

TRUNCATE bson_external_binary_input;
INSERT INTO bson_external_binary_input VALUES (1, '\x02');
\copy bson_external_binary_input TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_binary_received FROM 'bson_external_type.bin' WITH (FORMAT binary)

TRUNCATE bson_external_binary_input;
INSERT INTO bson_external_binary_input VALUES (1, '\x000800000010780000');
\copy bson_external_binary_input TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_binary_received FROM 'bson_external_type.bin' WITH (FORMAT binary)

TRUNCATE bson_external_binary_input;
INSERT INTO bson_external_binary_input VALUES (1, '\x0128b52ffd200529000005');
\copy bson_external_binary_input TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_binary_received FROM 'bson_external_type.bin' WITH (FORMAT binary)

TRUNCATE bson_external_binary_input;
INSERT INTO bson_external_binary_input VALUES (1, '\x0128b52ffd20052900000500000001');
\copy bson_external_binary_input TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_binary_received FROM 'bson_external_type.bin' WITH (FORMAT binary)

TRUNCATE bson_external_binary_input;
INSERT INTO bson_external_binary_input VALUES (1, '\x');
\copy bson_external_binary_input TO 'bson_external_type.bin' WITH (FORMAT binary)
\copy bson_external_binary_received FROM 'bson_external_type.bin' WITH (FORMAT binary)
\set VERBOSITY default

SELECT count(*) = 2 AS rejected_binary_rows_not_stored FROM bson_external_binary_received;

DROP TABLE bson_external_binary_received, bson_external_binary_input,
           bson_external_uncompressed, bson_external_copy, bson_external_test;
DROP CAST (bytea AS bson_external);
\! rm bson_external_type.bin bson_external_type.txt
