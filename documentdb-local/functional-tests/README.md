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

> **Note:** `bootstrap` output is always written as bare-string entries
> (= "all engines"). It cannot infer per-engine scoping from a single
> engine's run. If a bootstrap candidate should only run on one engine,
> convert it manually to the `{id, engines: [<engine>]}` form before
> promoting. The candidate file's header contains a reminder of this.
> Likewise, the daily run's `promotion-candidates.yml` only suggests
> truly-new IDs as bare strings; any ID already scoped to another engine
> is reported separately under "scoped to a different engine on this run"
> so the snippet never produces a `DUPLICATE_TEST_ID` on copy-paste.

### Allowlist schema (v1 and v2)

`config/allowlist.yml` declares its schema version in the `schema_version`
field. Two versions are supported:

- **`schema_version: 1`** — flat list of pytest node IDs. Every entry applies
  to every engine. Still accepted forever for back-compat.
- **`schema_version: 2`** — entries may be either bare strings (= "all
  engines", identical to v1) or a `{id, engines: [...]}` mapping that scopes
  the entry to a subset of engines.

The on-disk file is at `schema_version: 2`, but **almost every entry is a
bare string**. The dict form exists for the rare cases where a single test
must diverge between engines.

### Adding an engine-scoped test (v2)

The default expectation is that the gate tests **parity**: every entry runs
against every supported engine. Before adding an engine-scoped entry, prefer
adding a bare-string entry that runs against both engines.

```yaml
schema_version: 2
tests:
  # Preferred form: applies to every engine.
  - compatibility/tests/some/test_x.py::test_x

  # Engine-scoped form: only run as part of the pgmongo PR gate.
  - id: compatibility/tests/some/test_y.py::test_y
    engines: [pgmongo]

  # Multiple engines are allowed; equivalent to a bare string when both
  # supported engines are listed.
  - id: compatibility/tests/some/test_z.py::test_z
    engines: [documentdb, pgmongo]
```

Workflow when you genuinely need divergence:

1. Write the test upstream and run it against both engines locally
   (`run-functional-tests.sh single <node-id>` against each `--engine-name`).
2. If it passes on both, add it as a **bare string** entry. This is the
   default and what 99% of entries look like.
3. If it diverges, decide whether the divergence is intentional:
   - **Scope it to the engine(s) where it should be enforced** → add the
     test as `{id, engines: [<engine>]}`. On the other engine's gate the
     test is silently out of scope (no UNKNOWN_TEST_ID, no required pass).
     This is the supported way to express divergence in the allowlist.
   - **Keep parity but acknowledge a known xfail on one engine** → mark
     the test `@pytest.mark.engine_xfail(engine="<engine>", reason=...)`
     upstream and **do not add it to the allowlist on either engine**.
     `engine_xfail` removes the test from the gate-required set on the
     marked engine; it is not compatible with a bare-string allowlist
     entry (the plugin rejects an allowlisted test with
     `engine_xfail(engine=<current>)` because the test cannot satisfy the
     allowlist contract on that engine).

In short: `engines:` is for "this test only matters on engine X"; `engine_xfail`
is for "this test exists but is expected to fail on engine X — don't gate on
it". Do not combine them via a bare-string allowlist entry.

Schema-level rules enforced by `validate-config`:

- `engines: []` (empty list) is **rejected** — omit the field instead to mean
  "all engines".
- Unknown keys on a dict entry are **rejected** (catches typos like the
  singular `engine:`).
- Duplicate `id` is **rejected** regardless of whether the duplicate has a
  different `engines:` list. Combine into one entry with both engines listed.
- Engine names must be non-empty strings; any value can be used (no fixed
  allow-list), so a new engine can be introduced without changing the
  schema.

### Recipe: enforcing a newly-merged upstream test on one engine

A worked example for the workflow above. Assumes your test has already merged
into `documentdb/functional-tests:main` and a new image digest has been
published.

1. **Bump the pinned image** in `config/image.yml`:

   ```yaml
   image: ghcr.io/documentdb/functional-tests@sha256:<new-digest>
   source_ref: documentdb/functional-tests@main
   source_sha: <upstream-git-sha>
   updated_by: <your alias>
   ```

2. **Find the new test node IDs** by collecting against the new image:

   ```bash
   OLD_IMAGE=$(yq -r .image config/image.yml.bak)  # the digest you replaced
   NEW_IMAGE=$(yq -r .image config/image.yml)
   docker run --rm "$OLD_IMAGE" pytest documentdb_tests --collect-only -q \
       | sort > /tmp/old.txt
   docker run --rm "$NEW_IMAGE" pytest documentdb_tests --collect-only -q \
       | sort > /tmp/new.txt
   comm -13 /tmp/old.txt /tmp/new.txt > /tmp/added.txt
   ```

   `/tmp/added.txt` now lists every node ID introduced in the new image. Note
   that upstream node IDs are emitted with the `documentdb_tests/` prefix; the
   allowlist drops that prefix, so an entry like
   `documentdb_tests/compatibility/tests/foo.py::test_bar` is referenced as
   `compatibility/tests/foo.py::test_bar`.

3. **Decide which lane(s) each added test belongs to.** Three possibilities:

   - The test passes on both engines today → add as a **bare string**.
   - The test is wire-protocol-divergent and should only run on pgmongo →
     add as `{id, engines: [pgmongo]}`. The documentdb gate will silently
     ignore it.
   - The test passes on documentdb and upstream already marked it
     `@pytest.mark.engine_xfail(engine="pgmongo")` → leave it out of the
     allowlist entirely. The pgmongo gate will not require it; the documentdb
     gate would reject it as `ALLOWLISTED_ENGINE_XFAIL` if you tried to add
     it.

   To verify a candidate locally before submitting the PR:

   ```bash
   ./scripts/run-functional-tests.sh single <node-id> \
       --engine-name pgmongo --build-and-start-documentdb
   ./scripts/run-functional-tests.sh single <node-id> \
       --engine-name documentdb --build-and-start-documentdb
   ```

4. **Edit `config/allowlist.yml`** with the chosen form. Group new scoped
   entries with a short header comment so reviewers can see why divergence
   was chosen.

5. **Validate locally** — catches schema bugs and engine-xfail contradictions
   before the pipeline runs:

   ```bash
   python3 tools/functional_gate.py \
       --image config/image.yml \
       --allowlist config/allowlist.yml \
       validate-config
   ```

6. **Run the gate locally** for the engine(s) you scoped to:

   ```bash
   ./scripts/run-functional-tests.sh allowlist \
       --engine-name pgmongo --build-and-start-documentdb
   ```

   `--build-and-start-documentdb` bootstraps a **DocumentDB-local** backend —
   the only engine `run-functional-tests.sh` can start itself. With
   `--engine-name pgmongo` this validates the allowlist *scoping* (the
   `selected` count below) but still runs the tests against the DocumentDB
   backend. To exercise the pgmongo engine itself, drop
   `--build-and-start-documentdb` and point the script at a running pgmongo
   gateway with `--connection-string <url>` instead.

   `selected` in the printed `gate-summary.md` should equal (previous total)
   − (entries you scoped *out* of this engine) + (entries you scoped *in* to
   this engine).

7. **Submit the PR.** Pipeline 54672 reruns both engine lanes and produces a
   per-lane `gate-summary.md` showing the same delta. If you get
   `UNKNOWN_TEST_ID` only on one lane, you either typed the node ID wrong or
   the test isn't in that engine's image; if you get `ALLOWLISTED_ENGINE_XFAIL`,
   the test carries an `engine_xfail` marker for the lane you scoped it to.

### Known UX rough edges (follow-up work)

The schema and pipeline plumbing are complete. The authoring workflow above is
manual at three points and would benefit from tooling in a follow-up PR:

- **Discovery is by hand.** Steps 2 + 3 above would collapse to one command if
  `functional_gate.py` grew a `discover --old <digest> --new <digest>`
  subcommand that emitted the delta grouped by file and pre-classified by
  marker (e.g. flags tests already marked `engine_xfail(<engine>)`).
- **Bootstrap is single-engine.** `run-functional-tests.sh bootstrap` runs
  against one engine and emits bare-string entries. A
  `bootstrap --engines <list>` mode could run against each engine, intersect
  passing sets, and emit a pre-classified v2 YAML snippet.
- **No "verify-against-image" validation.** `validate-config` checks YAML
  shape and the duplicate / engine-xfail-contradiction guards, but it does
  not pull the pinned image to confirm every allowlisted node ID actually
  exists in the collection. Typos and stale entries only surface in CI.

None of these block adding scoped tests today; they would make the workflow
faster and shift feedback left.

### CI matrix and engine name plumbing

The `--engine-name` argument flows from
`oss/.github/workflows/functional_tests.yml` (`env.ENGINE_NAME`) through:

- the upstream pytest container (`--engine-name` selects engine-specific
  test variants),
- this directory's pytest plugin (`--allowlist-engine-name` filters the
  allowlist before running), and
- `functional_gate.py summarize-{gate,daily}` (filters which allowlist
  entries are in scope for the report).

All three see the same engine name on every job; engine-scoping is a single
axis end-to-end.
