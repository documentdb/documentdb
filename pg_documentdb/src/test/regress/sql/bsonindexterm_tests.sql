SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET documentdb.next_collection_id TO 800;
SET documentdb.next_collection_index_id TO 800;

-- test input output functions for bsonindexterm
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT 'BSONITERMHEX000c0000001024000100000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEX000c0000001024000100000000');

-- truncated flag is preserved
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 1 }');
SELECT 'BSONITERMHEX010c0000001024000100000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEX010c0000001024000100000000');

-- value only is preserved and the serialized form is smaller
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 5 }');
SELECT 'BSONITERMHEX05100001000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEX05100001000000');

-- descending is persisted too
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 128 }');
SELECT 'BSONITERMHEX800c0000001024000100000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEX800c0000001024000100000000');

-- truncated flag is preserved
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 129 }');
SELECT 'BSONITERMHEX810c0000001024000100000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEX810c0000001024000100000000');

-- value only is preserved and the serialized form is smaller
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 133 }');
SELECT 'BSONITERMHEX85100001000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEX85100001000000');

-- serialization + deserialization with collation:
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 133, "$collation": "en_US" }');
SELECT 'BSONITERMHEXff656e5f55530085100001000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEXff656e5f55530085100001000000');

-- composite term serialization
SELECT bson_to_bsonindexterm('{ "$$COMP": [{ "$": 1, "$flags": 133 }, { "$": 0, "$flags": 0 }, { "$": 3, "$flags": 0 }] }');
SELECT 'BSONITERMHEX0411851000010000001d000c00000010240000000000001d000c0000001024000300000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEX0411851000010000001d000c00000010240000000000001d000c0000001024000300000000');

-- composite term with collation:
SELECT bson_to_bsonindexterm('{ "$$COMP": [{ "$": 1, "$flags": 133 }, { "$": 0, "$flags": 0 }, { "$": 3, "$flags": 0 }], "$collation": "en_US" }');
SELECT 'BSONITERMHEXff656e5f5553000411851000010000001d000c00000010240000000000001d000c0000001024000300000000'::bsonindexterm;
SELECT bsonindexterm_to_bson('BSONITERMHEXff656e5f5553000411851000010000001d000c00000010240000000000001d000c0000001024000300000000');

-- check btree comparisons
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 5 }') = bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 5 }') >= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 5 }') > bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 5 }') < bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 5 }') <= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');

-- values being different
SELECT bson_to_bsonindexterm('{ "$": 2, "$flags": 5 }') = bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 2, "$flags": 5 }') >= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 2, "$flags": 5 }') > bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 2, "$flags": 5 }') < bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 2, "$flags": 5 }') <= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');

-- truncation flag being different
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 1 }') = bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 1 }') >= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 1 }') > bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 1 }') < bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": 1, "$flags": 1 }') <= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');

-- undefined value is less than numbers.
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') = bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') >= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') > bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') < bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') <= bson_to_bsonindexterm('{ "$": 1, "$flags": 0 }');

-- undefined value is greater than MinKey.
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') = bson_to_bsonindexterm('{ "$": { "$minKey": 1 }, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') >= bson_to_bsonindexterm('{ "$": { "$minKey": 1 }, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') > bson_to_bsonindexterm('{ "$": { "$minKey": 1 }, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') < bson_to_bsonindexterm('{ "$": { "$minKey": 1 }, "$flags": 0 }');
SELECT bson_to_bsonindexterm('{ "$": null, "$flags": 8 }') <= bson_to_bsonindexterm('{ "$": { "$minKey": 1 }, "$flags": 0 }');

-- collation based comparison
set documentdb_core.enablecollation to on;
SELECT bson_to_bsonindexterm('{ "$": "Apple", "$flags": 0, "$collation": "en-u-ks-level1" }') = bson_to_bsonindexterm('{ "$": "apple", "$flags": 0, "$collation": "en-u-ks-level2" }');
SELECT bson_to_bsonindexterm('{ "$": "Apple", "$flags": 0, "$collation": "en-u-ks-level1" }') = bson_to_bsonindexterm('{ "$": "apple", "$flags": 0, "$collation": "en-u-ks-level1" }');