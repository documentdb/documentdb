# PyMongo compatibility pilot

This directory tests a released DocumentDB image with a selected PyMongo wheel.
It exercises real synchronous driver methods and return objects, rather than
substituting raw commands for driver APIs. It is self-contained: it does not
import the separate functional-test framework or build the database from this
checkout.

The initial integration is **PyMongo only**. A result covers only its exact
version pair, runtime profile, and listed scenarios, not every driver API or
database feature. Async APIs, vector search, other integrations, scheduled
discovery, and automatic release watching are outside this pilot.

## Reviewed baseline

[`registry.yaml`](registry.yaml) selects DocumentDB **0.117.0**, PostgreSQL **17**,
PyMongo **4.18.0**, and the `python312-linux-x64-sync` profile. These are a
reproducible baseline, not a claim about the newest releases.

The database image and Python 3.12 base image are pinned by digest. Before running
tests, the controller verifies the installed extension and PostgreSQL major
version. It verifies the selected wheel's filename and SHA-256 against non-yanked
PyPI release metadata, then checks the installed driver version and wheel hash.
Dependency versions and hashes, the actual Python version, the client image ID,
and a digest of the execution inputs are retained in each result.

Stable PyMongo 4.9 and later 4.x versions can be selected explicitly. A version
without an eligible Python 3.12 Linux x64 wheel is **Not tested**, not Working.
Other database releases must first be added to the reviewed registry with an
immutable image reference and expected installed versions.

## Coverage

The 17 required scenarios are individually named in the registry:

| Area | Driver behavior checked |
| --- | --- |
| Connection | Authenticated administrative ping over TLS |
| Writes | `insert_one`, `insert_many`, identifiers, acknowledgement, exact readback |
| Reads | `find_one`, missing document, filter, projection, sort, limit, counts |
| Cursor batching | Seven documents with batch size two, exact output, observed `getMore` |
| Updates | `update_one` result counts and `find_one_and_update(ReturnDocument.AFTER)` |
| Deletion | `delete_one` and `delete_many` counts plus remaining documents |
| Aggregation | Exact `$unwind` / `$group` counts and sorted output |
| Indexes | Scalar/compound definitions, uniqueness, listing, dropping |
| Errors | Unique-index rejection as `DuplicateKeyError`, code 11000, no unintended insert |
| BSON | Object identifiers, integers, int64, doubles, decimals, UTC dates, bytes, arrays, booleans |

The scenarios follow the kinds of driver operations demonstrated by the
[`documentdb-playground` PyMongo example](https://github.com/documentdb/documentdb-playground/blob/1a36d28aea9f78a7ca833903e400a7cc4e842e55/playgrounds/pymongo/app/pymongo_crud_test.py).
The example's mutable launcher defaults and vector-search steps are not used.

## Run locally

Use Python 3.12 and a Linux Docker daemon with Linux x64 image support. For local
development, run Python and its dependencies inside a prepared development or
tooling container rather than installing toolchains on the host. Only the trusted
controller needs Docker access. There is no backend build prerequisite.

From the repository root in that environment:

```bash
python -m pip install -r compatibility/requirements.txt
python -m compatibility.runner \
  --version 4.18.0 --documentdb-version 0.117.0 \
  --output compatibility/.test-results/run-001/result.json
```

The runner downloads wheels, builds the client without build-time network access,
creates an isolated database, runs the selected profile, and removes its own
containers, network, anonymous volumes, and client image. Use a fresh output path
for each invocation. `--wheelhouse /path/to/wheels` can reuse downloaded wheels;
PyPI metadata verification still requires network access. Never disable TLS
verification for package downloads.

The client has no Docker socket, checkout mount, publishing token, or
host-published port. It connects only to this run's internal Docker network. Its
root filesystem is read-only, with bounded temporary storage, CPU, memory, and
execution time. Only the fixture's self-signed certificate is accepted without
CA validation. Credentials are generated per run, passed outside the image build
context, and redacted from retained diagnostics.

Completed execution writes `result.json`, `result.xml` (JUnit), and `result.log`.
Setup failures retain a result envelope and controller diagnostics, including the
terminal cause of long tracebacks. They cannot provide JUnit for tests that never
ran. Existing results or diagnostics are never intentionally overwritten. The CLI
exits nonzero for failures, incomplete coverage, or execution/cleanup errors.

To exercise the failure-reporting path deliberately:

```bash
python -m compatibility.runner --demonstration \
  --output compatibility/.test-results/demo-001/result.json
```

This executes the normal profile and one intentionally incorrect driver
assertion. It must exit nonzero. The result is explicitly labeled as a
demonstration and cannot replace a real compatibility verdict.

## Results and preview

```bash
python -m compatibility.publish \
  --result compatibility/.test-results/run-001/result.json \
  --store compatibility/.test-results/history \
  --site compatibility/.test-results/site
python -m compatibility.publish \
  --result compatibility/.test-results/demo-001/result.json \
  --store compatibility/.test-results/history \
  --site compatibility/.test-results/site
```

Open `compatibility/.test-results/site/index.html`. The same validated history
produces HTML, `current.json`, and `history.json`. Appends are immutable,
conflicting run IDs are rejected, and identical replays are idempotent.
Demonstrations are displayed separately. Local runs have no fabricated pipeline
URL; issue links point to the product repository's compatibility report form.

| State | Meaning |
| --- | --- |
| Working | All required scenarios ran and passed with verified artifacts |
| Failing | At least one test assertion or non-timeout operation/protocol failure |
| Not tested | Missing/skipped scenarios, timeouts, setup errors, unavailable artifacts, or other incomplete execution |
| Stale | The last conclusive result is over seven days old, or its execution inputs/artifacts no longer match |

Missing expected exceptions are assertion failures, not infrastructure errors.
Fixture setup/teardown errors are execution errors. A conclusive assertion or
operation failure survives a later cleanup error. If a newer attempt cannot
execute, the dashboard keeps the previous conclusive result while exposing the
new attempt's failure separately. Browser-side freshness also ages already
rendered results.

## GitHub Actions workflow

For the pre-merge demo, pushes to `users/urismiley/pymongo-compatibility` run
**PyMongo compatibility** using the runner's default version pair, without the
failure demonstration. Results record `push` as their trigger. No other branch
or tag has a push trigger.

Once the workflow exists on the repository's default branch, it can also be run
manually from the Actions tab. Select a reviewed database release, optionally
supply a PyMongo version, and leave the failure demonstration disabled for real
results. Manual runs retain the `manual` trigger. Remove the branch-specific
push trigger and update its guard test when the pre-merge demo is no longer needed.

The workflow has read-only repository permissions. It retains JSON, available
JUnit/logs, and a dashboard preview as a per-attempt artifact for 30 days,
including when the suite fails. A non-passing suite still fails the workflow.
It does not commit history, create issues, deploy Pages, or change any existing
site. Durable cross-run hosted history and public dashboard publication require
a separate hosting and ownership decision. Downloaded artifacts alone are not
an indefinitely retained public service.

## Maintaining the pilot

Normal repository CI checks the infrastructure without starting a database.
Run those scoped checks with:

```bash
python -m pip install -r compatibility/requirements-dev.txt
python -m pytest -c compatibility/pyproject.toml compatibility/unit
python -m black --check --config compatibility/pyproject.toml compatibility
python -m isort --check-only --settings-path compatibility/pyproject.toml compatibility
python -m flake8 --max-line-length=100 --extend-ignore=E203 compatibility
python -m mypy --config-file compatibility/pyproject.toml compatibility
node --test compatibility/unit/test_freshness.cjs
```

The JavaScript check uses Node's built-in test runner. It is not a client runtime
dependency. Python configuration is scoped to this directory.

For scenario changes, update the explicit registry coverage, keep unique
non-parameterized test function names, and run the real normal and demonstration
profiles again. Unit tests protect report classification, declared coverage,
provenance, cleanup boundaries, immutable history, freshness, and workflow failure
handling. `suite_files` defines the execution files copied into the client and
hashed for provenance; include any new execution file type there. Previous
results do not prove compatibility for a changed suite.
