// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const { randomUUID } = require("node:crypto");

function createFixture() {
    const { MongoClient } = require("mongodb");
    const client = new MongoClient("mongodb://db:10260", {
        auth: { username: process.env.USERNAME, password: process.env.PASSWORD },
        authSource: "admin",
        directConnection: true,
        tls: true,
        tlsAllowInvalidCertificates: true,
        serverSelectionTimeoutMS: 15000,
        connectTimeoutMS: 10000,
        socketTimeoutMS: 15000,
        monitorCommands: true,
        appName: "documentdb-nodejs-compatibility",
    });
    const commands = [];
    client.on("commandStarted", event => commands.push(event.commandName));
    const database = client.db(`compat_${randomUUID().replaceAll("-", "")}`);
    return {
        client, database, collection: database.collection("items"), commands,
        async close() {
            try {
                await database.dropDatabase();
            } finally {
                await client.close();
            }
        },
    };
}

module.exports = { createFixture };
