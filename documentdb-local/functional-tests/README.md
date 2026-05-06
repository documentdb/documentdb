# DocumentDB functional test gate

This directory contains DocumentDB-owned tooling for running the pinned upstream
`functional-tests` suite against `documentdb-local`.

The upstream tests are not stored in this repository. They are pulled from the
pinned Docker image in `config/image.yml`; `config/allowlist.yml` defines the
tests that must pass in the PR gate.

For the design rationale, see the companion
[RFC-0007 design PR](https://github.com/documentdb/documentdb/pull/601).

## Phase 1 implementation notes

The draft RFC uses illustrative paths and examples. This implementation uses the
following concrete choices:

- Tooling lives under `documentdb-local/functional-tests/`.
- Allowlist entries use pytest node IDs as emitted by the pinned image. In the
  current image, those IDs are rootdir-relative, for example
  `compatibility/tests/...`, not `documentdb_tests/compatibility/tests/...`.
- CI uses bounded, configurable xdist workers with a default of `4`, rather than
  unbounded `-n auto`.
- Allowlist removals and replacements are reviewer-governed in normal PR review.
  CI intentionally does not run a dedicated removal-blocking job because
  legitimate coverage changes need human context.
- Phase 1 summaries do not run a `main` causality comparison or detailed
  product-vs-infra mismatch taxonomy. Those are deferred operational polish; the
  Phase 1 gate remains strict for allowlisted tests.

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
- A running DocumentDB endpoint, normally `documentdb-local` on port `10260`,
  unless you use the runner's managed DocumentDB options

Validate the local gate configuration:

```bash
python3 documentdb-local/functional-tests/tools/functional_gate.py validate-config
```

## Build/start DocumentDB locally

For the closest local reproduction of CI, let the test runner build the
`documentdb-local` image, start it, wait for the readiness log, and then run the
selected test mode:

```bash
./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist \
  --build-and-start-documentdb
```

This uses the same package-build plus `Dockerfile_documentdb_local` flow as the
GitHub Actions workflow. The managed container is removed after the run and its
logs are written to `documentdb.log` in the result directory.

Useful managed DocumentDB options:

```bash
--build-documentdb               Build the documentdb-local Docker image
--start-documentdb               Start the image, wait for readiness, then run tests
--build-and-start-documentdb     Build, start, wait, and run tests in one command
--use-existing-documentdb-image <image>
                                 Start a prebuilt image ref without rebuilding;
                                 pulls if missing locally
--documentdb-image <image>       Image ref, default documentdb-local:functional-tests
--documentdb-container <name>    Container name, default documentdb-functional-tests
--documentdb-port <port>         Host port mapped to container port 10260
--pg-version <ver>               PostgreSQL version for package/image build, default 17
--package-os <os>                Package OS for build, default deb13
--build-dir <path>               Repo-local build artifact directory
--ready-timeout <seconds>        Startup readiness timeout, default 180
--keep-documentdb                Keep the managed container running after tests
```

Examples:

```bash
# Build, start, wait, and run the PR gate.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist \
  --build-and-start-documentdb

# Start a previously built/published image reference and run the PR gate without rebuilding.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist \
  --use-existing-documentdb-image ghcr.io/documentdb/documentdb/documentdb-local:latest

# Reuse an already built image and keep the container for manual debugging.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh single \
  compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents \
  --start-documentdb \
  --keep-documentdb
```

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
| `daily` | Run the full upstream suite and write `daily-summary.md/json`. CI runs this on the schedule or by manual dispatch with `test_scope=all`. |
| `bootstrap` | Generate an allowlist candidate from tests that pass every run. |

Common options:

```bash
--connection-string <url>  Override the DocumentDB connection string, including
                           managed-container runs
--engine-name <name>       Engine name passed to upstream pytest and allowlist
                           validation, default documentdb
--workers <n>              Number of pytest-xdist workers, default 4
--results-dir <path>       Output directory
--test <nodeid>            Test ID for single mode
--runs <n>                 Bootstrap run count
--output <path>            Bootstrap candidate output path
--build-and-start-documentdb
                           Build/start managed documentdb-local before tests
-- <pytest args>           Extra arguments passed to pytest
```

Examples:

```bash
# Run the same allowlist gate used by PR validation.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist

# Build/start local DocumentDB and then run the PR gate.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist \
  --build-and-start-documentdb

# Reproduce one failing test from a gate summary.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh single \
  compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents

# Run smoke tests with the same parallelism used by CI.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh smoke --workers 4

# Run full-suite visibility locally. In CI this mode runs from the schedule or manual dispatch with test_scope=all.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh daily --workers 4

# Generate a candidate allowlist from tests that pass in all three runs.
./documentdb-local/functional-tests/scripts/run-functional-tests.sh bootstrap \
  --runs 3 \
  --output allowlist-candidate.yml
```

If the default connection string does not work on your Docker setup, pass the
connection explicitly:

```bash
DOCUMENTDB_USER=docdb_admin
DOCUMENTDB_PASSWORD='<local-password>'
CONNECTION_STRING="mongodb://${DOCUMENTDB_USER}:${DOCUMENTDB_PASSWORD}@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true" \
  ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist
```

## Debug a CI failure

Start with the generated artifacts, then reproduce locally. The simplest path is:
read the summary, run one failed test locally, then inspect raw artifacts only if
the single-test repro is not enough.

1. Identify which job failed:
   - PR gate: `functional-pr-gate`
   - Full-suite visibility: `daily-functional-delta`
   - Config-only failure: `validate-config`

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

   The PR gate summary explains whether the failure is a failed test, a
   missing allowlisted test, or another non-pass outcome. It includes a local
   reproduction command. The daily summary separates allowlisted regressions
   from outside-allowlist promotion candidates and lists any allowlisted tests
   missing from the full-suite report. Daily promotion candidates come from one
   scheduled or manually dispatched run, so re-run or use `bootstrap --runs <n>`
   before promoting them.

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

   If you already have a prebuilt `documentdb-local` image, reuse it to avoid a
   rebuild:

   ```bash
   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh single <pytest-node-id> \
     --use-existing-documentdb-image <image>
   ```

   If many allowlisted tests failed, or the summary reports missing/non-pass
   allowlisted tests, reproduce the whole gate:

   ```bash
   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist \
     --build-and-start-documentdb
   ```

6. If artifacts are missing or the test container failed before producing
   `report.json`, inspect the job log:

   ```bash
   gh run view <run-id> --job <job-id> --log
   ```

   Common causes are image pull failures, DocumentDB readiness failures, or a
   result directory permission problem before pytest writes artifacts.
   Daily runs intentionally fail with a clear error if `report.json` is missing,
   so a pre-report infrastructure failure is not mistaken for a healthy
   promotion report.

## Updating the allowlist

Use `bootstrap` to generate a candidate file, review the diff, then copy only
the intended stable tests into `config/allowlist.yml`.

```bash
./documentdb-local/functional-tests/scripts/run-functional-tests.sh bootstrap \
  --runs 3 \
  --output /tmp/allowlist-candidate.yml
```

Allowlist additions still use the normal promotion flow. Allowlist removals or
replacements are handled through normal PR review: explain the coverage change
in the PR, and let reviewers decide whether it is appropriate. CI
intentionally does not run a dedicated removal-blocking job.
