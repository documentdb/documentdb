// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const assert = require("node:assert/strict");
const { register } = require("../../report.cjs");
const { createFixture } = require("./profile.cjs");

async function test_failure_demonstration({ model }) {
    await model.create({ name: "Item" });
    assert.equal(await model.countDocuments({}), 0,
        "Intentional failure demonstration; not a compatibility regression");
}

register({ test_failure_demonstration }, createFixture, true);
