// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { run } = require("node:test");
const { collect, junit } = require("./report.cjs");

async function main() {
    const report = JSON.parse(fs.readFileSync("/install-report.json", "utf8"));
    const dependencies = report.install.map(entry => {
        const installed = JSON.parse(fs.readFileSync(path.join(entry.path, "package.json"), "utf8"));
        if (installed.name !== entry.name || installed.version !== entry.version) {
            throw new Error("Installed dependency does not match the verified archive");
        }
        return { name: installed.name, version: installed.version, sha256: entry.sha256 };
    });
    const installed = dependencies.find(entry => entry.name === process.env.COMPATIBILITY_PACKAGE);
    if (!installed) throw new Error("Selected driver is missing from the installation report");
    const files = [process.env.COMPATIBILITY_TEST_FILE];
    if (process.env.COMPATIBILITY_DEMONSTRATION === "1") {
        files.push(process.env.COMPATIBILITY_DEMONSTRATION_FILE);
    }
    const tests = await collect(run({ files, concurrency: 1, isolation: "none" }));
    const exitCode = tests.some(test => ["failed", "error"].includes(test.outcome)) ? 1 : 0;
    process.stdout.write(JSON.stringify({
        version: installed.version,
        runtime: { name: "nodejs", version: process.versions.node },
        artifact_sha256: installed.sha256,
        dependencies,
        exit_code: exitCode,
        tests,
        junit: junit(tests),
    }) + "\n");
    process.exitCode = exitCode;
}

main().catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 2;
});
