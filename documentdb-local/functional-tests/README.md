# DocumentDB functional test gate

This directory contains DocumentDB-owned tooling for running the pinned upstream
`functional-tests` suite against `documentdb-local`.

The upstream tests are not stored in this repository. They are pulled from the
pinned Docker image in `config/image.yml`; `config/allowlist.yml` defines the
tests that must pass in the PR gate.

## Layout

```text
documentdb-local/functional-tests/
  config/   Pinned upstream image and PR-gate allowlist
  scripts/  Local entry points
  tools/    Pytest allowlist plugin and report summarizer
  tests/    Unit tests for this tooling
```

## Prerequisites

- Docker
- Python 3 with `pyyaml`
- A running DocumentDB endpoint, normally `documentdb-local` on port `10260`

Validate the local gate configuration:

```bash
python3 documentdb-local/functional-tests/tools/functional_gate.py validate-config
```

## Start DocumentDB locally

If you do not already have a local DocumentDB endpoint running, use:

```bash
./documentdb-local/functional-tests/scripts/start-documentdb-for-functional-tests.sh
```

The script builds/starts DocumentDB and prints a `CONNECTION_STRING=...` value
when the gateway is ready. Use that value with the runner if it differs from the
default.

## Run functional tests locally

Use one entry point for all local functional-test workflows:

```bash
./documentdb-local/functional-tests/scripts/run-functional-tests.sh <mode> [options]
```

Modes:

| Mode | Purpose |
| --- | --- |
| `allowlist` | Run the PR-gate allowlist and write `gate-summary.md/json`. |
| `single` | Run one pytest node ID for failure diagnosis. |
| `smoke` | Run upstream smoke tests, excluding `no_parallel`. |
| `full` | Run the full upstream suite. |
| `daily` | Run the full upstream suite and write `daily-summary.md/json`. |
| `bootstrap` | Generate an allowlist candidate from tests that pass every run. |

Common options:

```bash
--connection-string <url>  Override the DocumentDB connection string
--workers <n>              Number of pytest-xdist workers, default 4
--results-dir <path>       Output directory
--test <nodeid>            Test ID for single mode
--runs <n>                 Bootstrap run count
--output <path>            Bootstrap candidate output path
-- <pytest args>           Extra arguments passed to pytest
```

Examples:

```bash
# Run the same allowlist gate used by PR validation.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist

# Reproduce one failing test from a gate summary.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh single \
  compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents

# Run smoke tests with the same parallelism used by CI.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh smoke --workers 4

# Run full-suite visibility locally.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh daily --workers 4

# Generate a candidate allowlist from tests that pass in all three runs.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh bootstrap \
  --runs 3 \
  --output allowlist-candidate.yml
```

If the default connection string does not work on your Docker setup, pass the
connection explicitly:

```bash
CONNECTION_STRING='mongodb://docdb_admin:Admin100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true' \
  ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist
```

## Debug a CI failure

Start with the generated artifacts, then reproduce locally.

1. Identify which job failed:
   - PR gate: `functional-pr-gate`
   - Daily visibility: `daily-functional-delta`
   - Config-only failure: `validate-config` or `check-allowlist-removals`

2. Download artifacts from the failed run:

   ```bash
   gh run download <run-id> -n functional-test-results -D .test-results/functional-tests
   gh run download <run-id> -n daily-functional-test-results -D .test-results/functional-tests-daily
   ```

   Use the first command for PR-gate failures and the second command for daily
   failures.

3. Inspect the summary first:

   ```bash
   less .test-results/functional-tests/gate-summary.md
   less .test-results/functional-tests-daily/daily-summary.md
   ```

   The PR gate summary includes the first failed test and a local reproduction
   command. The daily summary separates allowlisted regressions from outside
   allowlist promotion candidates.

4. Inspect raw test and server details when needed:

   ```bash
   less .test-results/functional-tests/report.json
   less .test-results/functional-tests/results.xml
   less .test-results/functional-tests/documentdb.log
   ```

   For daily failures, use `.test-results/functional-tests-daily/`.

5. Reproduce the failing test locally:

   ```bash
   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh single <pytest-node-id>
   ```

   If many allowlisted tests failed, reproduce the whole gate:

   ```bash
   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist
   ```

6. If artifacts are missing or the test container failed before producing
   `report.json`, inspect the job log:

   ```bash
   gh run view <run-id> --job <job-id> --log
   ```

   Common causes are image pull failures, DocumentDB readiness failures, or a
   result directory permission problem before pytest writes artifacts.

## Updating the allowlist

Use `bootstrap` to generate a candidate file, review the diff, then copy only
the intended stable tests into `config/allowlist.yml`.

```bash
./documentdb-local/functional-tests/scripts/run-functional-tests.sh bootstrap \
  --runs 3 \
  --output /tmp/allowlist-candidate.yml
```

Allowlist removals are blocked in PRs unless explicitly justified.
