// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const assert = require("node:assert/strict");
const mongoose = require("mongoose");
const { register } = require("../../report.cjs");
const { createFixture } = require("./profile.cjs");

async function test_authenticated_ping({ connection }) {
    assert.equal((await connection.getClient().db("admin").command({ ping: 1 })).ok, 1);
}

async function test_model_create({ model }) {
    const created = await model.create({ sku: "one", name: "Item", price: "3.5" });
    assert.ok(created instanceof model);
    assert.ok(created._id instanceof mongoose.Types.ObjectId);
    assert.equal(created.isNew, false);
    assert.equal(created.price, 3.5);
    assert.equal(created.active, true);
    assert.ok(created.createdAt instanceof Date);
    assert.ok(created.updatedAt instanceof Date);
    const actual = await model.findById(created._id);
    assert.ok(actual instanceof model);
    assert.deepEqual(actual.toObject(), created.toObject());
}

async function test_insert_many({ model }) {
    const inserted = await model.insertMany([
        { sku: "one", name: "First", price: 3 },
        { sku: "two", name: "Second", price: 7 },
    ]);
    assert.equal(inserted.length, 2);
    assert.ok(inserted.every(document => document instanceof model && !document.isNew));
    assert.deepEqual(
        await model.find().sort({ sku: 1 }).select({ _id: 0, sku: 1, price: 1 }).lean(),
        [{ sku: "one", price: 3 }, { sku: "two", price: 7 }],
    );
}

async function test_find_by_id({ model }) {
    const created = await model.create({ name: "Item", price: 3 });
    const actual = await model.findById(created._id.toString());
    assert.ok(actual instanceof model);
    assert.equal(actual.name, "Item");
    assert.ok(actual._id.equals(created._id));
    assert.equal(await model.findById(new mongoose.Types.ObjectId()), null);
}

async function test_find_filter_projection_sort_limit({ model }) {
    await model.insertMany([
        { name: "First", price: 3 }, { name: "Second", price: 7 }, { name: "Third", price: 11 },
    ]);
    const documents = await model.find({ price: { $gte: "5" } })
        .select({ _id: 0, price: 1 }).sort({ price: -1 }).limit(1).lean();
    assert.deepEqual(documents, [{ price: 11 }]);
}

async function test_cursor_batches({ model, commands }) {
    await model.insertMany(Array.from({ length: 7 }, (_, price) => ({ name: "Item", price })));
    commands.length = 0;
    const cursor = model.find().sort({ price: 1 }).cursor({ batchSize: 2 });
    const prices = [];
    try {
        for await (const document of cursor) {
            assert.ok(document instanceof model);
            prices.push(document.price);
        }
    } finally {
        await cursor.close();
    }
    assert.deepEqual(prices, [0, 1, 2, 3, 4, 5, 6]);
    assert.ok(commands.includes("find"));
    assert.ok(commands.includes("getMore"));
}

async function test_count_documents({ model }) {
    await model.insertMany([{ name: "First", price: 3 }, { name: "Second", price: 7 }]);
    assert.equal(await model.countDocuments({}), 2);
    assert.equal(await model.countDocuments({ price: { $gte: 5 } }), 1);
    assert.equal(await model.countDocuments({ price: 99 }), 0);
}

async function test_document_save({ model }) {
    const document = new model({ name: "Original", price: 3 });
    await document.save();
    document.name = "Updated";
    assert.equal(document.isModified("name"), true);
    await document.save();
    assert.equal(document.isModified("name"), false);
    const actual = await model.findById(document._id);
    assert.equal(actual.name, "Updated");
    assert.equal(actual.price, 3);
    assert.ok(actual.updatedAt >= actual.createdAt);
    assert.equal(await model.countDocuments({}), 1);
}

async function test_update_one({ model }) {
    await model.create({ sku: "one", name: "Item", price: 3 });
    const result = await model.updateOne({ sku: "one" }, { $set: { price: 7 } });
    assert.equal(result.acknowledged, true);
    assert.deepEqual([result.matchedCount, result.modifiedCount, result.upsertedId], [1, 1, null]);
    assert.equal((await model.findOne({ sku: "one" })).price, 7);
}

async function test_find_one_and_update({ model }) {
    await model.create({ sku: "one", name: "Item", tags: ["alpha"] });
    const document = await model.findOneAndUpdate(
        { sku: "one" }, { $push: { tags: "beta" } }, { returnDocument: "after" },
    );
    assert.ok(document instanceof model);
    assert.deepEqual(Array.from(document.tags), ["alpha", "beta"]);
    assert.deepEqual((await model.findOne({ sku: "one" })).toObject(), document.toObject());
}

async function test_delete_one({ model }) {
    await model.insertMany([{ sku: "one", name: "First" }, { sku: "two", name: "Second" }]);
    const result = await model.deleteOne({ sku: "one" });
    assert.equal(result.acknowledged, true);
    assert.equal(result.deletedCount, 1);
    assert.deepEqual(await model.find().select({ _id: 0, sku: 1 }).lean(), [{ sku: "two" }]);
}

async function test_delete_many({ model }) {
    await model.insertMany([
        { name: "First", price: 0 }, { name: "Second", price: 1 }, { name: "Third", price: 2 },
    ]);
    const result = await model.deleteMany({ price: { $lt: 2 } });
    assert.equal(result.acknowledged, true);
    assert.equal(result.deletedCount, 2);
    assert.deepEqual(await model.find().select({ _id: 0, price: 1 }).lean(), [{ price: 2 }]);
}

async function test_aggregate({ model }) {
    await model.insertMany([
        { name: "First", tags: ["alpha", "beta"] }, { name: "Second", tags: ["beta"] },
    ]);
    const documents = await model.aggregate([
        { $unwind: "$tags" },
        { $group: { _id: "$tags", count: { $sum: 1 } } },
        { $sort: { _id: 1 } },
    ]);
    assert.deepEqual(documents, [{ _id: "alpha", count: 1 }, { _id: "beta", count: 2 }]);
}

async function test_schema_indexes({ model }) {
    await model.createCollection();
    await model.syncIndexes();
    const indexes = Object.fromEntries((await model.listIndexes()).map(index => [index.name, index]));
    assert.deepEqual(Object.keys(indexes).sort(), ["_id_", "name_price", "sku_unique"]);
    assert.deepEqual(indexes.sku_unique.key, { sku: 1 });
    assert.equal(indexes.sku_unique.unique, true);
    assert.deepEqual(indexes.name_price.key, { name: 1, price: -1 });
}

async function test_duplicate_key_error({ model }) {
    await model.createCollection();
    await model.createIndexes();
    await model.create({ sku: "one", name: "Original" });
    await assert.rejects(
        model.create({ sku: "one", name: "Duplicate" }),
        { name: "MongoServerError", code: 11000 },
    );
    assert.deepEqual(
        await model.find().select({ _id: 0, sku: 1, name: 1 }).lean(),
        [{ sku: "one", name: "Original" }],
    );
}

async function test_schema_validation({ model }) {
    await assert.rejects(model.create({ price: -1 }), error => {
        assert.ok(error instanceof mongoose.Error.ValidationError);
        assert.equal(error.errors.name?.kind, "required");
        assert.equal(error.errors.price?.kind, "min");
        return true;
    });
    assert.equal(await model.countDocuments({}), 0);
    await model.create({ sku: "one", name: "Valid", price: 3 });
    await assert.rejects(
        model.updateOne({ sku: "one" }, { $set: { price: -1 } }, { runValidators: true }),
        error => {
            assert.ok(error instanceof mongoose.Error.ValidationError);
            assert.equal(error.errors.price?.kind, "min");
            return true;
        },
    );
    assert.equal((await model.findOne({ sku: "one" })).price, 3);
    assert.equal(await model.countDocuments({}), 1);
}

async function test_bson_round_trip({ model }) {
    const document = {
        _id: new mongoose.Types.ObjectId(),
        name: "Typed",
        price: 2.5,
        big: (2n ** 60n) + 7n,
        decimal: mongoose.Types.Decimal128.fromString("3.14"),
        date: new Date("2024-01-01T00:00:00.000Z"),
        binary: Buffer.from([0, 255]),
        tags: ["one", "two"],
        active: false,
        nested: { label: "Child", value: 7 },
    };
    await model.create(document);
    const actual = await model.findById(document._id);
    assert.ok(actual instanceof model);
    assert.ok(actual._id instanceof mongoose.Types.ObjectId);
    assert.ok(actual._id.equals(document._id));
    assert.equal(actual.price, document.price);
    assert.equal(actual.big, document.big);
    assert.ok(actual.decimal instanceof mongoose.Types.Decimal128);
    assert.equal(actual.decimal.toString(), "3.14");
    assert.ok(actual.date instanceof Date);
    assert.equal(actual.date.toISOString(), document.date.toISOString());
    assert.ok(Buffer.isBuffer(actual.binary));
    assert.deepEqual(Buffer.from(actual.binary), document.binary);
    assert.deepEqual(Array.from(actual.tags), document.tags);
    assert.equal(actual.active, false);
    assert.deepEqual(actual.toObject().nested, document.nested);
}

register({
    test_authenticated_ping, test_model_create, test_insert_many, test_find_by_id,
    test_find_filter_projection_sort_limit, test_cursor_batches, test_count_documents,
    test_document_save, test_update_one, test_find_one_and_update, test_delete_one,
    test_delete_many, test_aggregate, test_schema_indexes, test_duplicate_key_error,
    test_schema_validation, test_bson_round_trip,
}, createFixture);
