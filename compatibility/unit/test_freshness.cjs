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

function status(state, conclusiveAt = new Date(tested).toISOString(), freshnessDays = 7) {
    return {
        dataset: { conclusiveAt, freshnessDays: String(freshnessDays), previousState: state },
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
            assert.ok(Number.isFinite(delay) && delay > 0);
            interval = callback;
        },
    });
    return (next) => {
        clock = next;
        interval();
    };
}

for (const freshnessDays of [1, 7, 30]) {
    test(`the ${freshnessDays}-day boundary stays fresh until a later timer tick`, () => {
        const element = status("Working", new Date(tested).toISOString(), freshnessDays);
        const boundary = tested + freshnessDays * day;
        const tick = load([element], boundary);
        assert.equal(element.textContent, "Working");
        tick(boundary + 1);
        assert.equal(element.textContent, "Stale (last: Working)");
        assert.equal(element.className, "Stale");
    });
}

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
