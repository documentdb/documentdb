// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const { randomUUID } = require("node:crypto");
const mongoose = require("mongoose");

async function createFixture() {
    const connection = mongoose.createConnection();
    try {
        await connection.openUri("mongodb://db:10260", {
            auth: { username: process.env.USERNAME, password: process.env.PASSWORD },
            authSource: "admin",
            dbName: `compat_${randomUUID().replaceAll("-", "")}`,
            directConnection: true,
            tls: true,
            tlsAllowInvalidCertificates: true,
            serverSelectionTimeoutMS: 15000,
            connectTimeoutMS: 10000,
            socketTimeoutMS: 15000,
            monitorCommands: true,
            autoCreate: false,
            autoIndex: false,
            bufferCommands: false,
            appName: "documentdb-mongoose-compatibility",
        });
        const commands = [];
        connection.getClient().on("commandStarted", event => commands.push(event.commandName));
        const schema = new mongoose.Schema({
            sku: String,
            name: { type: String, required: true },
            price: { type: Number, min: 0 },
            tags: { type: [String], default: [] },
            active: { type: Boolean, default: true },
            big: mongoose.Schema.Types.BigInt,
            decimal: mongoose.Schema.Types.Decimal128,
            date: Date,
            binary: Buffer,
            nested: { label: String, value: Number },
        }, { timestamps: true, autoCreate: false, autoIndex: false, bufferCommands: false });
        schema.index({ sku: 1 }, { name: "sku_unique", unique: true });
        schema.index({ name: 1, price: -1 }, { name: "name_price" });
        const model = connection.model("Item", schema, "items");
        return {
            connection, model, commands,
            async close() {
                try {
                    await connection.dropDatabase();
                } finally {
                    await connection.destroy();
                }
            },
        };
    } catch (error) {
        try {
            await connection.destroy();
        } catch (cleanupError) {
            throw new AggregateError([error, cleanupError], "Mongoose setup and cleanup failed");
        }
        throw error;
    }
}

module.exports = { createFixture };
