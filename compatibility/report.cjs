// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const { test } = require("node:test");

function classify(error) {
    if (error?.code === "ERR_TEST_FAILURE") {
        if (error.failureType !== "testCodeFailure") return "error";
        return classify(error.cause);
    }
    if (error?.code === "ERR_ASSERTION" || error?.name === "AssertionError") return "failed";
    if (["MongoServerError", "MongoBulkWriteError", "MongoUnexpectedServerResponseError"].includes(error?.name)) {
        return [50, 262].includes(error.code) ? "error" : "failed";
    }
    return "error";
}

async function runScenario(createFixture, body) {
    let fixture;
    try {
        fixture = await createFixture();
    } catch (error) {
        throw new Error(`Fixture setup failed: ${error}`, { cause: error });
    }
    let failure;
    let failed = false;
    try {
        await body(fixture);
    } catch (error) {
        failed = true;
        failure = error;
    }
    try {
        await fixture.close();
    } catch (error) {
        if (failed && classify(failure) === "failed") {
            process.stderr.write(`Fixture cleanup also failed: ${error}\n`);
        } else {
            failure = new Error(`Fixture cleanup failed: ${error}`, { cause: error });
            failed = true;
        }
    }
    if (failed) throw failure;
}

function register(scenarios, createFixture, demonstration = false) {
    const skip = process.env.COMPATIBILITY_ACTIVE !== "1"
        || (demonstration && process.env.COMPATIBILITY_DEMONSTRATION !== "1");
    for (const [name, body] of Object.entries(scenarios)) {
        test(name, { skip }, () => runScenario(createFixture, body));
    }
}

function message(error) {
    return [error?.stack || String(error), error?.cause?.stack || ""].filter(Boolean).join("\n").slice(0, 2000);
}

async function collect(events) {
    const tests = new Map();
    let successful = false;
    for await (const { type, data } of events) {
        if (type === "test:stderr" || type === "test:stdout") {
            process.stderr.write(data.message);
        }
        if (type === "test:diagnostic") process.stderr.write(`${data.message}\n`);
        if (type === "test:summary") successful = data.success === true;
        if (type !== "test:pass" && type !== "test:fail") continue;
        if (!/^test_[a-z0-9_]+$/.test(data.name)) {
            if (type === "test:fail" && data.details.error?.failureType !== "subtestsFailed") {
                throw data.details.error;
            }
            continue;
        }
        if (tests.has(data.name)) throw new Error("Duplicate scenario names are not supported");
        const outcome = data.skip || data.todo ? "skipped"
            : type === "test:pass" ? "passed" : classify(data.details.error);
        tests.set(data.name, {
            id: data.name,
            outcome,
            message: outcome === "passed" ? "" : data.skip || data.todo
                ? String(data.skip || data.todo) : message(data.details.error),
        });
    }
    const results = [...tests.values()];
    if (!successful && !results.some(test => ["failed", "error"].includes(test.outcome))) {
        throw new Error("Test execution did not complete successfully");
    }
    return results;
}

function xml(value) {
    return String(value).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "")
        .replace(/[&<>"']/g, character => ({
            "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&apos;",
        })[character]);
}

function junit(tests, integration) {
    const count = outcome => tests.filter(test => test.outcome === outcome).length;
    const cases = tests.map(test => {
        const tag = { failed: "failure", error: "error", skipped: "skipped" }[test.outcome];
        return `<testcase name="${xml(test.id)}">${tag ? `<${tag}>${xml(test.message)}</${tag}>` : ""}</testcase>`;
    }).join("");
    return `<testsuites><testsuite name="${xml(integration)}" tests="${tests.length}" failures="${count("failed")}" errors="${count("error")}" skipped="${count("skipped")}">${cases}</testsuite></testsuites>`;
}

module.exports = { classify, collect, junit, register, runScenario };
