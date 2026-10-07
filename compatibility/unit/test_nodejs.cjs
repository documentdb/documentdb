// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { classify, collect, junit, runScenario } = require("../report.cjs");
const reporter = path.resolve(__dirname, "../report.cjs");

function execute(source) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "compat-node-unit-"));
    const profile = path.join(directory, "profile.cjs");
    fs.writeFileSync(profile, source);
    const environment = { ...process.env };
    delete environment.NODE_TEST_CONTEXT;
    try {
        return spawnSync(process.execPath, ["-e", `
            const { run } = require("node:test");
            const { collect } = require(${JSON.stringify(reporter)});
            collect(run({ files: [process.argv[1]], concurrency: 1, isolation: "none" }))
                .then(tests => {
                    process.stdout.write(JSON.stringify(tests));
                    process.exitCode = tests.some(test => ["failed", "error"].includes(test.outcome)) ? 1 : 0;
                })
                .catch(error => { console.error(error); process.exitCode = 2; });
        `, profile], { encoding: "utf8", timeout: 10000, env: environment });
    } finally {
        fs.rmSync(directory, { recursive: true });
    }
}

for (const [name, body, outcome] of [
    ["pass", "", "passed"],
    ["assertion", "require('node:assert/strict').fail('Mismatch')", "failed"],
    ["missing-exception", "await require('node:assert/strict').rejects(Promise.resolve())", "failed"],
    ["operation", "throw Object.assign(new Error('Unsupported'), {name:'MongoServerError', code:115})", "failed"],
    ["timeout", "throw Object.assign(new Error('Timed out'), {name:'MongoServerError', code:50})", "error"],
    ["network", "throw Object.assign(new Error('Unavailable'), {name:'MongoNetworkError'})", "error"],
    ["runtime", "throw new TypeError('Invalid execution')", "error"],
]) {
    test(`production reporter classifies ${name}`, () => {
        const result = execute(`require("node:test").test("test_profile", async () => { ${body}; });`);
        assert.equal(result.status, outcome === "passed" ? 0 : 1, result.stderr);
        const records = JSON.parse(result.stdout);
        assert.equal(records.length, 1);
        assert.equal(records[0].id, "test_profile");
        assert.equal(records[0].outcome, outcome);
    });
}

for (const option of ["skip", "todo"]) {
    test(`${option} is not a passing scenario`, () => {
        const result = execute(`require("node:test").test("test_profile", {${option}:true}, () => {});`);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(JSON.parse(result.stdout)[0].outcome, "skipped");
    });
}

for (const [active, demonstration, demoScenario, outcome] of [
    [false, false, false, "skipped"],
    [true, false, false, "passed"],
    [true, false, true, "skipped"],
    [true, true, true, "passed"],
]) {
    test(`shared registration gates active=${active} demonstration=${demonstration} scenario=${demoScenario}`, () => {
        const result = execute(`
            process.env.COMPATIBILITY_ACTIVE = ${JSON.stringify(active ? "1" : "0")};
            process.env.COMPATIBILITY_DEMONSTRATION = ${JSON.stringify(demonstration ? "1" : "0")};
            const {register} = require(${JSON.stringify(reporter)});
            register({ test_profile() {} }, () => ({ close() {} }), ${demoScenario});
        `);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(JSON.parse(result.stdout)[0].outcome, outcome);
    });
}

test("duplicate scenario names are rejected", () => {
    const result = execute(`
        const {test} = require("node:test");
        test("test_profile", () => {});
        test("test_profile", () => {});
    `);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Duplicate scenario/);
});

test("collection errors cannot pass", () => {
    const result = execute("throw new Error('Collection failed');");
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Collection failed/);
});

for (const body of [
    "throw new Error('Late asynchronous failure')",
    "Promise.reject(new Error('Late asynchronous failure'))",
]) {
    test(`late asynchronous errors cannot pass: ${body}`, () => {
        const result = execute(`
            require("node:test").test("test_profile", () => {
                setImmediate(() => { ${body}; });
            });
        `);
        assert.equal(result.status, 2, result.stdout + result.stderr);
        assert.match(result.stderr, /Late asynchronous failure/);
    });
}

test("assertions survive a later asynchronous error", () => {
    const result = execute(`
        require("node:test").test("test_profile", () => {
            setImmediate(() => { throw new Error("Late asynchronous failure"); });
            require("node:assert/strict").fail("Assertion mismatch");
        });
    `);
    assert.equal(result.status, 1, result.stderr);
    assert.equal(JSON.parse(result.stdout)[0].outcome, "failed");
    assert.match(result.stderr, /Late asynchronous failure/);
});

test("missing runner summary cannot pass", async () => {
    await assert.rejects(collect([
        { type: "test:pass", data: { name: "test_profile", details: {} } },
    ]), /did not complete successfully/);
});

test("fixture setup errors do not become compatibility failures", async () => {
    await assert.rejects(runScenario(
        () => { throw Object.assign(new Error("Setup failed"), { name: "MongoServerError" }); },
        () => {},
    ), error => classify(error) === "error");
});

test("fixture cleanup errors do not become compatibility failures", async () => {
    await assert.rejects(runScenario(
        () => ({ close() { throw new Error("Cleanup failed"); } }),
        () => {},
    ), error => classify(error) === "error");
});

test("assertions survive a subsequent fixture cleanup failure", async () => {
    await assert.rejects(runScenario(
        () => ({ close() { throw new Error("Cleanup failed"); } }),
        () => assert.fail("Assertion mismatch"),
    ), error => classify(error) === "failed" && /Assertion mismatch/.test(error.message));
});

test("falsy scenario exceptions cannot become passes", async () => {
    for (const value of [null, undefined, false, 0, ""]) {
        await assert.rejects(runScenario(
            () => ({ close() {} }),
            () => { throw value; },
        ));
    }
});

test("JUnit preserves outcomes and escapes diagnostics", () => {
    const output = junit([
        { id: "test_pass", outcome: "passed", message: "" },
        { id: "test_failure", outcome: "failed", message: "<mismatch> & \"value\"" },
        { id: "test_error", outcome: "error", message: "Unavailable" },
        { id: "test_skip", outcome: "skipped", message: "Skipped" },
    ], "driver & integration");
    assert.match(output, /name="driver &amp; integration"/);
    assert.match(output, /tests="4" failures="1" errors="1" skipped="1"/);
    assert.match(output, /&lt;mismatch&gt; &amp; &quot;value&quot;/);
    assert.match(output, /<error>Unavailable<\/error>/);
    assert.match(output, /<skipped>Skipped<\/skipped>/);
});
