// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const assert = require("node:assert/strict");
const { Decimal128, Long, ObjectId } = require("mongodb");
const { register } = require("./profile.cjs");

async function test_authenticated_ping({ client }) {
    assert.equal((await client.db("admin").command({ ping: 1 })).ok, 1);
}

async function test_insert_one({ collection }) {
    const document = { value: 3 };
    const result = await collection.insertOne(document);
    assert.equal(result.acknowledged, true);
    assert.ok(result.insertedId instanceof ObjectId);
    assert.deepEqual(await collection.findOne({ _id: result.insertedId }), document);
}

async function test_insert_many({ collection }) {
    const documents = [{ _id: 1, value: 3 }, { _id: 2, value: 7 }];
    const result = await collection.insertMany(documents);
    assert.equal(result.acknowledged, true);
    assert.deepEqual(Object.values(result.insertedIds), [1, 2]);
    assert.deepEqual(await collection.find().sort({ _id: 1 }).toArray(), documents);
}

async function test_find_one({ collection }) {
    const document = { _id: 1, value: 3 };
    await collection.insertOne(document);
    assert.deepEqual(await collection.findOne({ _id: 1 }), document);
    assert.equal(await collection.findOne({ _id: 2 }), null);
}

async function test_find_filter_projection_sort_limit({ collection }) {
    await collection.insertMany([{ _id: 1, price: 3 }, { _id: 2, price: 7 }, { _id: 3, price: 11 }]);
    const documents = await collection.find({ price: { $gte: 5 } }, { projection: { _id: 0, price: 1 } })
        .sort({ price: -1 }).limit(1).toArray();
    assert.deepEqual(documents, [{ price: 11 }]);
}

async function test_cursor_batches({ collection, commands }) {
    const documents = Array.from({ length: 7 }, (_, _id) => ({ _id }));
    await collection.insertMany(documents);
    commands.length = 0;
    const cursor = collection.find().sort({ _id: 1 }).batchSize(2);
    const actual = [];
    try {
        for await (const document of cursor) actual.push(document);
    } finally {
        await cursor.close();
    }
    assert.deepEqual(actual, documents);
    assert.ok(commands.includes("find"));
    assert.ok(commands.includes("getMore"));
}

async function test_count_documents({ collection }) {
    await collection.insertMany([{ _id: 1, value: 3 }, { _id: 2, value: 7 }]);
    assert.equal(await collection.countDocuments({}), 2);
    assert.equal(await collection.countDocuments({ value: { $gte: 5 } }), 1);
    assert.equal(await collection.countDocuments({ value: 99 }), 0);
}

async function test_update_one({ collection }) {
    await collection.insertOne({ _id: 1, value: 3 });
    const result = await collection.updateOne({ _id: 1 }, { $set: { value: 7 } });
    assert.equal(result.acknowledged, true);
    assert.deepEqual([result.matchedCount, result.modifiedCount, result.upsertedId], [1, 1, null]);
    assert.deepEqual(await collection.findOne({ _id: 1 }), { _id: 1, value: 7 });
}

async function test_find_one_and_update({ collection }) {
    await collection.insertOne({ _id: 1, tags: ["alpha"] });
    const document = await collection.findOneAndUpdate(
        { _id: 1 }, { $push: { tags: "beta" } },
        { returnDocument: "after", includeResultMetadata: false },
    );
    assert.deepEqual(document, { _id: 1, tags: ["alpha", "beta"] });
    assert.deepEqual(await collection.findOne({ _id: 1 }), document);
}

async function test_delete_one({ collection }) {
    await collection.insertMany([{ _id: 1 }, { _id: 2 }]);
    const result = await collection.deleteOne({ _id: 1 });
    assert.equal(result.acknowledged, true);
    assert.equal(result.deletedCount, 1);
    assert.deepEqual(await collection.find().toArray(), [{ _id: 2 }]);
}

async function test_delete_many({ collection }) {
    await collection.insertMany([{ _id: 0 }, { _id: 1 }, { _id: 2 }]);
    const result = await collection.deleteMany({ _id: { $lt: 2 } });
    assert.equal(result.acknowledged, true);
    assert.equal(result.deletedCount, 2);
    assert.deepEqual(await collection.find().toArray(), [{ _id: 2 }]);
}

async function test_aggregate({ collection }) {
    await collection.insertMany([{ _id: 1, tags: ["alpha", "beta"] }, { _id: 2, tags: ["beta"] }]);
    const documents = await collection.aggregate([
        { $unwind: "$tags" },
        { $group: { _id: "$tags", count: { $sum: 1 } } },
        { $sort: { _id: 1 } },
    ]).toArray();
    assert.deepEqual(documents, [{ _id: "alpha", count: 1 }, { _id: "beta", count: 2 }]);
}

async function test_create_indexes({ collection }) {
    const names = await collection.createIndexes([
        { key: { sku: 1 }, name: "sku_unique", unique: true },
        { key: { name: 1, price: -1 }, name: "name_price" },
    ]);
    assert.deepEqual(names, ["sku_unique", "name_price"]);
    const indexes = Object.fromEntries((await collection.indexes()).map(index => [index.name, index]));
    assert.deepEqual(indexes.sku_unique.key, { sku: 1 });
    assert.equal(indexes.sku_unique.unique, true);
    assert.deepEqual(indexes.name_price.key, { name: 1, price: -1 });
}

async function test_list_indexes({ collection }) {
    await collection.insertOne({ _id: 1, value: 3 });
    await collection.createIndex({ value: 1 }, { name: "value_1" });
    const indexes = Object.fromEntries((await collection.listIndexes().toArray()).map(index => [index.name, index]));
    assert.deepEqual(Object.keys(indexes).sort(), ["_id_", "value_1"]);
    assert.deepEqual(indexes.value_1.key, { value: 1 });
}

async function test_drop_index({ collection }) {
    await collection.insertOne({ _id: 1, value: 3 });
    await collection.createIndex({ value: 1 }, { name: "value_1" });
    await collection.dropIndex("value_1");
    assert.deepEqual((await collection.listIndexes().toArray()).map(index => index.name), ["_id_"]);
}

async function test_duplicate_key_error({ collection }) {
    await collection.createIndex({ sku: 1 }, { unique: true });
    await collection.insertOne({ _id: 1, sku: "one" });
    await assert.rejects(
        collection.insertOne({ _id: 2, sku: "one" }),
        { name: "MongoServerError", code: 11000 },
    );
    assert.deepEqual(await collection.find().toArray(), [{ _id: 1, sku: "one" }]);
}

async function test_bson_round_trip({ collection }) {
    const document = {
        _id: new ObjectId(),
        integer: 7,
        long: Long.fromBigInt(2n ** 40n),
        double: 2.5,
        decimal: Decimal128.fromString("3.14"),
        date: new Date("2024-01-01T00:00:00.000Z"),
        binary: Buffer.from([0, 255]),
        array: [1, "two", null],
        boolean: true,
    };
    await collection.insertOne(document);
    const actual = await collection.findOne(
        { _id: document._id }, { promoteLongs: false, promoteBuffers: true },
    );
    assert.deepEqual(actual, document);
    assert.ok(actual._id instanceof ObjectId);
    assert.ok(actual.long instanceof Long);
    assert.ok(actual.decimal instanceof Decimal128);
    assert.ok(actual.date instanceof Date);
    assert.ok(Buffer.isBuffer(actual.binary));
}

register({
    test_authenticated_ping, test_insert_one, test_insert_many, test_find_one,
    test_find_filter_projection_sort_limit, test_cursor_batches, test_count_documents,
    test_update_one, test_find_one_and_update, test_delete_one, test_delete_many,
    test_aggregate, test_create_indexes, test_list_indexes, test_drop_index,
    test_duplicate_key_error, test_bson_round_trip,
});
