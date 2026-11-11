-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

CREATE TYPE __CORE_SCHEMA__.bson_external;

#include "../udfs/bson_external/bson_external_io--1.4-0.sql"

CREATE TYPE __CORE_SCHEMA__.bson_external (
    input = __CORE_SCHEMA__.bson_external_in,
    output = __CORE_SCHEMA__.bson_external_out,
    send = __CORE_SCHEMA__.bson_external_send,
    receive = __CORE_SCHEMA__.bson_external_recv,
    alignment = int4,
    storage = external
);

COMMENT ON TYPE __CORE_SCHEMA__.bson_external IS
    'BSON compressed with dictionary-free Zstandard. Text I/O uses uncompressed BSON representations. Binary I/O preserves the format flag and encoded BSON bytes, excluding the PostgreSQL varlena header.';

CREATE CAST (__CORE_SCHEMA__.bson_external AS __CORE_SCHEMA__.bson)
 WITH FUNCTION __CORE_SCHEMA__.bson_external_to_bson(__CORE_SCHEMA__.bson_external);
