// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../dashboard/freshness.js"), "utf8");
const day = 86400000;
const tested = Date.UTC(2024, 0, 1);

function status(state, conclusiveAt = new Date(tested).toISOString()) {
    return {
        dataset: { conclusiveAt, freshnessDays: "7", previousState: state },
        textContent: state,
        className: state,
    };
}

function load(elements, now) {
    let clock = now;
    let interval;
    vm.runInNewContext(source, {
        document: {
            querySelectorAll(selector) {
                assert.equal(selector, "[data-compatibility-status]");
                return elements;
            },
        },
        Date: { parse: Date.parse, now: () => clock },
        setInterval(callback, delay) {
            assert.equal(delay, 60000);
            interval = callback;
        },
    });
    return (next) => {
        clock = next;
        interval();
    };
}

test("the exact boundary stays fresh and a later timer tick expires it", () => {
    const element = status("Working");
    const tick = load([element], tested + 7 * day);
    assert.equal(element.textContent, "Working");
    tick(tested + 7 * day + 1);
    assert.equal(element.textContent, "Stale (last: Working)");
    assert.equal(element.className, "Stale");
});

test("failed results age without becoming a fabricated passing result", () => {
    const element = status("Failing");
    load([element], tested + 8 * day);
    assert.equal(element.textContent, "Stale (last: Failing)");
});

test("an untested entry has no conclusive timestamp to refresh", () => {
    const element = status("Not tested", "");
    load([element], tested + 8 * day);
    assert.equal(element.textContent, "Not tested");
});

test("fresh timestamps cannot undo server-side stale classification", () => {
    const element = status("Working");
    element.textContent = element.className = "Stale";
    load([element], tested + day);
    assert.equal(element.textContent, "Stale");
});
