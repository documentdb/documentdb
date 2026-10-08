# Ecosystem compatibility pilot

This configuration-driven pilot tests ecosystem integrations against a released
DocumentDB image. Its initial integrations are PyMongo, the Node.js driver, and Mongoose;
the workflow and reporting are shared rather than specific to a driver.
It exercises real driver and model methods and return objects, rather than
substituting raw commands for integration APIs. It is self-contained: it does not
import the separate functional-test framework or build the database from this
checkout.

The profiles cover synchronous Python, asynchronous Node.js, and Mongoose model APIs.
A result covers only its exact version pair, runtime profile, and listed scenarios, not every API or
database feature. Python async APIs, optional native driver modules, vector search, scheduled
discovery, and automatic release watching are outside this pilot.

## Reviewed baseline

[`registry.yaml`](registry.yaml) selects DocumentDB **0.117.0** and PostgreSQL **17**:

| Integration | Package version | Runtime | Profile |
| --- | --- | --- | --- |
| `pymongo` | 4.18.0 | Python 3.12 | `python312-linux-x64-sync` |
| `nodejs` | 7.7.0 | Node.js 24 | `node24-linux-x64-async` |
| `mongoose` | 9.11.0 | Node.js 24 | `node24-linux-x64-mongoose` |

These are reviewed reproducible baselines, not a claim about the newest releases.
The database and client base images are pinned by digest. Before running
tests, the controller verifies the installed extension and PostgreSQL major
version. It verifies the selected wheel's filename and SHA-256 against non-yanked
PyPI release metadata. For Node.js, every npm archive must match the SHA-512
integrity in the reviewed `package-lock.json`; installation runs offline with
lifecycle scripts and optional packages disabled. All clients verify their
installed integration version and retain the selected artifact's SHA-256.
Dependency versions and hashes, the actual runtime version, the client image ID,
and a digest of the execution inputs are retained in each result.

Stable PyMongo 4.9 and later 4.x versions can be selected explicitly. Specify three
numeric components, for example `--version 4.9.0`; equivalent published versions
such as `4.9` are matched using package-version semantics. A version without an
eligible Python 3.12 Linux x64 wheel is **Not tested**, not Working.
The Node.js driver and Mongoose profiles accept the version pinned in each
integration's manifest and lockfile. To select another version, update the manifest in
`compatibility/integrations/nodejs` or `compatibility/integrations/mongoose`,
regenerate that integration's lockfile there using Node 24
and `npm install --package-lock-only --ignore-scripts --engine-strict --omit=optional`,
and update the registry default and version policy.
Review the dependency changes and rerun the normal and demonstration profiles.
Mongoose's transitive MongoDB driver version is pinned in its own lockfile and
retained in dependency provenance; it is not substituted for the Mongoose package version.
Other database releases must first be added to the reviewed registry with an
immutable image reference and expected installed versions.

## Coverage

The PyMongo and Node.js driver profiles each declare the same 17 required scenarios
in the registry:

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
| Errors | Driver-specific duplicate-key exception, code 11000, no unintended insert |
| BSON | Object identifiers, integers, int64, doubles, decimals, UTC dates, bytes, arrays, booleans |

The Node.js profile uses the corresponding camel-case APIs (`insertOne`, `findOne`,
`findOneAndUpdate`, and others), promises, and `for await` cursor iteration.
It checks Node-specific return shapes and BSON representations rather than
replaying raw commands through a different client.

The scenarios follow the kinds of driver operations demonstrated by the
[`documentdb-playground` PyMongo example](https://github.com/documentdb/documentdb-playground/blob/1a36d28aea9f78a7ca833903e400a7cc4e842e55/playgrounds/pymongo/app/pymongo_crud_test.py).
The example's mutable launcher defaults and vector-search steps are not used.

### Mongoose model coverage

Mongoose declares its own 17 required scenarios. They exercise model APIs rather
than bypassing the ODM through raw driver collections:

| Area | Mongoose behavior checked |
| --- | --- |
| Connection | Authenticated administrative ping over the model connection |
| Creation and hydration | `Model.create`, `insertMany`, identifiers, casting, defaults, timestamps, hydrated documents, exact readback |
| Reads and cursors | `findById` with string-ID casting, missing documents, filters, projection, sort, limit, counts, and observed `getMore` during model cursor iteration |
| Writes | Document `save` and dirty tracking, `updateOne`, `findOneAndUpdate`, `deleteOne`, `deleteMany`, result counts and persisted changes |
| Aggregation and indexes | Exact aggregation output, schema-driven `syncIndexes`, index listing, and duplicate-key rejection without an unintended insert |
| Validation and BSON | Required/minimum validators on inserts and updates, ObjectId, BigInt, Decimal128, dates, buffers, arrays, booleans, and nested document round trips |

These scenarios adapt the core model operations from the
[`documentdb-playground` Mongoose example](https://github.com/documentdb/documentdb-playground/blob/1a36d28aea9f78a7ca833903e400a7cc4e842e55/playgrounds/mongoose/app/mongoose-crud-test.js).
The example's historical known-failure exemption and vector-search steps are
not carried over: every declared scenario must pass for the profile to be Working.
Transactions, population, plugins, middleware, and unlisted Mongoose APIs are
outside this initial profile.

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
python -m compatibility.runner --integration nodejs \
  --output compatibility/.test-results/node-001/result.json
python -m compatibility.runner --integration mongoose \
  --output compatibility/.test-results/mongoose-001/result.json
```

The runner downloads verified package archives, builds the client without build-time network access,
creates an isolated database, runs the selected profile, and removes its own
containers, network, anonymous volumes, and client image. Use a fresh output path
for each invocation. `--wheelhouse /path/to/wheels` can reuse downloaded wheels;
PyPI metadata verification still requires network access. Never disable TLS
verification for package downloads.

For both JavaScript integrations, `--package-cache /path/to/cache` stores and reuses archives named
`<sha256-of-the-lockfile-integrity-string>.tgz`. Cached bytes are verified against
the reviewed lockfile on every run; a complete cache needs no registry access.
`--wheelhouse` is Python-only and `--package-cache` is Node-only. Node.js itself
is needed only inside the pinned client container, not on the controller host.

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
python -m compatibility.runner --integration nodejs --demonstration \
  --output compatibility/.test-results/node-demo-001/result.json
python -m compatibility.runner --integration mongoose --demonstration \
  --output compatibility/.test-results/mongoose-demo-001/result.json
```

This executes the normal profile and one intentionally incorrect integration
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
New schema-version-2 records use `upstream.artifact_sha256` and
`upstream.runtime` (`name` and `version`). Schema-version-1 Python history
remains readable without rewriting the original records.

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

**Ecosystem compatibility** runs only through manual dispatch. Once the workflow
exists on the repository's default branch, select it in the Actions tab and
choose the branch and reviewed database release to exercise. The integration
defaults to `all`: a planning job expands every enabled registry entry using its
own reviewed default version. Select one integration for a focused run or a
version override. A version override with `all`, a disabled integration, a
version outside its registry policy, or an unknown database release is rejected
before test jobs start. Keep the failure demonstration disabled for real results.

Each matrix job runs its complete scenario suite against its own disposable
database. Matrix fail-fast is disabled, so a failure does not cancel the other
integrations. JSON and available JUnit/logs are retained in
`compatibility-results-<integration>-<attempt>` artifacts even when the job fails.
Results record the `manual` trigger and link to the exact workflow attempt.

After the matrix finishes, the reporting job validates each selected result's
identity, coverage, artifacts, suite digest, and workflow-attempt URL before
combining it. The workflow summary includes a row for every selected integration.
Missing or rejected results are **Not tested**, with a diagnostic; they do not
create fabricated result envelopes or inherit an earlier attempt's pass.
Compatibility failures remain **Failing**, and failed or incomplete reports exit
nonzero without suppressing the matrix jobs' failures.

The `compatibility-report-<attempt>` artifact contains `summary.md`, a
machine-readable `summary.json`, accepted envelopes in `results/`, and a combined
dashboard preview in `site/`. Only the selected profiles and versions appear in
that preview, including explicit version overrides and labeled demonstrations.
All artifacts have 30-day retention.

Use **Re-run all jobs** for a complete matrix rerun. The report deliberately
collects only the current attempt's artifacts, so rerunning only failed jobs can
leave other integrations without current-attempt evidence. Re-running an older
workflow also retains its original commit; dispatch a fresh run to test new code.

All jobs have read-only repository permissions. There are no branch-specific
push triggers, repository-variable failure overrides, or automatic publication
jobs.

To inspect the selection or combine locally produced records, run:

```bash
python -m compatibility.workflow matrix --integration all
python -m compatibility.workflow report --integration all \
  --input compatibility/.test-results/incoming \
  --output compatibility/.test-results/combined-001
```

Place each record under `incoming/<integration>/result.json`. Use the same
integration, version, database, and demonstration selection as the producing
runs, and a fresh output directory. `--expected-run-url` binds a combined report
to one workflow attempt; omit it for local results. `--summary` can append the
Markdown report to a GitHub step-summary file.

### Publishing results

The workflow produces artifacts and previews only. It does not write repository
history, deploy Pages, create issues, or change repository settings. A hosted
dashboard needs a separately approved destination, publisher, operational owner,
and reporting route; do not overwrite an existing site.

The generic history helper remains available for a trusted publisher:

```bash
bash compatibility/persist.sh /path/to/result.json "$EXPECTED_RUN_URL"
```

Run it from the trusted source checkout with write access to the intended
`origin`. Set `EXPECTED_RUN_URL` to the originating test attempt, not a later
publication retry. The helper verifies that URL, coverage, database artifact,
and execution-input digest, then appends `results/<id>.json` to
`compatibility-data`. It uses non-force pushes with bounded conflict retries and
initializes an orphan branch containing only result data. Identical replays are
idempotent; conflicting run IDs fail instead of overwriting history. Retain this
branch independently of artifact expiration.

Keep write credentials separate from integration execution. A publisher must
retain failed attempts and serialize deployment only after results are durably
stored. Render the complete history with `compatibility.publish`, using
`--preview` to label review prototypes and hide unprovisioned issue links.
Deployment retries must not delete or rewrite history. Cancellation before
persistence is not a compatibility verdict.

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
node --test compatibility/unit/test_freshness.cjs compatibility/unit/test_nodejs.cjs
shellcheck compatibility/persist.sh
```

Run the JavaScript checks with Node 24 in a tooling container. They use Node's
built-in test runner and need neither a database nor installed driver packages.
Python configuration is scoped to this directory.

JavaScript integrations share `compatibility/client.cjs` and
`compatibility/report.cjs` for dependency verification, scenario execution, and
JSON/JUnit reporting. These files are copied into each JavaScript client and
included in its execution-input digest.

Infrastructure fixtures read selected versions and artifact metadata from the
registry rather than duplicating the current release values. Assertions should
check coverage and outcomes, not the number of registered integrations, scenario
ordering, or dashboard row position. Fixed synthetic inputs are appropriate for
isolated argument and error cases. Keep the real image and action digest pins:
configuration-resilient tests must not weaken reproducibility or validation.

New integrations join `all` through their enabled registry entry, not a
hard-coded matrix. Add their key to the workflow's input choices as well to make
individual selection available in the Actions UI.

For scenario changes, update the explicit registry coverage, keep unique
non-parameterized test function names, and run the real normal and demonstration
profiles again. Unit tests protect report classification, declared coverage,
provenance, cleanup boundaries, immutable history, freshness, and workflow failure
handling. Persistence tests use local disposable Git repositories to exercise
initialization, replays, conflicting IDs, and concurrent-writer retries without
GitHub credentials. `suite_files` defines the execution files copied into the client and
hashed for provenance; include any new execution file type there. Previous
results do not prove compatibility for a changed suite.
