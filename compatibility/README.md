# Ecosystem compatibility

This registry-driven runner tests ecosystem integration profiles against reviewed
DocumentDB releases. Execution, artifact verification, and result contracts are
shared; each integration adapter implements its own scenario suite.

The manual workflow selects enabled profiles and combines validated results as
Markdown, HTML, and JSON. A trusted publisher can append results to Git history
with the persistence helper.

## Profiles and reviewed artifacts

[`registry.yaml`](registry.yaml) defines profiles, enablement, default package
versions, version policies, required scenarios, and reviewed DocumentDB releases.
Adapter directories under [`integrations/`](integrations/) contain runtime recipes
and scenario suites. These definitions identify the package, runtime, and database
combination for a run, not the newest upstream releases. Database and client base
images are pinned by digest.

Version overrides must match the integration's registry policy and have eligible
artifacts for its runtime. PyMongo versions use three numeric components, such as
`--version 4.9.0`; equivalent published versions such as `4.9` are matched using
package-version semantics. A version without an eligible Python 3.12 Linux x64
wheel is Not tested, not Working.

Before executing scenarios, the controller checks the actual extension and
PostgreSQL major versions. It verifies the selected wheel's filename and SHA-256
against non-yanked PyPI metadata. The client records installed package and
dependency versions and hashes, its runtime version, and its image identity.
An execution-input digest includes the suite, controller, schemas, and runtime
recipe, including uncommitted local changes.

For Node.js, every npm archive must match the SHA-512 integrity in the reviewed
`package-lock.json`. Installation is offline with lifecycle scripts and optional
packages disabled. The client verifies installed dependency versions and records
their SHA-256 hashes. Shared JavaScript execution and reporting live in
`compatibility/client.cjs` and `compatibility/report.cjs`, separate from adapters.

The Node.js and Mongoose profiles accept only their reviewed locked versions.
To select another, update the manifest in `compatibility/integrations/nodejs` or
`compatibility/integrations/mongoose`, regenerate that adapter's lockfile using Node 24 and
`npm install --package-lock-only --ignore-scripts --engine-strict --omit=optional`,
and update the registry default and version policy. Review dependency changes and
rerun both the normal and demonstration profiles.
Mongoose's transitive MongoDB driver is independently locked and recorded as a
dependency, never substituted for the Mongoose package version.

## Coverage

The PyMongo and native Node.js profiles exercise synchronous Python and
asynchronous JavaScript driver APIs, respectively. Each profile's required
scenarios are declared in the registry's `expected_tests` list and cover the
following behavior:

| Area | Behavior |
| --- | --- |
| Connection | Authenticated administrative ping over TLS |
| Inserts and reads | `insert_one`, `insert_many`, `find_one`, filters, projection, sorting, limits, and exact readback |
| Cursor and counts | Observed `getMore` with bounded batches and exact document counts |
| Updates and deletes | `update_one`, `find_one_and_update`, `delete_one`, `delete_many`, result objects, and persisted effects |
| Aggregation and indexes | Aggregation results, index creation/listing/removal, and duplicate-key rejection |
| BSON | ObjectId, integers, Decimal128, dates, binary values, arrays, booleans, and nested documents |

Each scenario has a fresh disposable database. Required cases cannot be silently
skipped or exempted. A result applies only to its exact version pair, runtime,
execution inputs, and declared scenarios. It does not establish compatibility
for Python async APIs, transactions, vector search, or other unlisted features.

The Node.js profile uses the corresponding camel-case APIs (`insertOne`, `findOne`,
`findOneAndUpdate`, and others), promises, and `for await` cursor iteration. It
checks native driver return shapes and BSON representations rather than replaying
raw commands through another client. Python async APIs, optional native Node.js
modules, transactions, vector search, and unlisted APIs remain out of scope.

### Mongoose model coverage

The Mongoose profile's `expected_tests` list names its required model and document
scenarios. They exercise ODM behavior rather than bypassing it through raw driver
collections:

| Area | Behavior checked |
| --- | --- |
| Connection | Authenticated administrative ping through the model connection |
| Creation | `Model.create`, `insertMany`, identifiers, casting, defaults, timestamps, hydration, and exact readback |
| Reads and cursors | `findById` with string-ID casting, missing documents, filters, projection, sorting, counts, and observed `getMore` |
| Writes | Document `save` and dirty tracking, `updateOne`, `findOneAndUpdate`, deletes, result objects, and persisted effects |
| Aggregation and indexes | Exact aggregation output, schema-driven indexes, index listing, and duplicate-key rejection |
| Validation and BSON | Required/minimum validators on inserts and updates, ObjectId, BigInt, Decimal128, dates, buffers, arrays, booleans, and nested documents |

Each scenario uses a fresh connection and database with automatic index and
collection creation and command buffering disabled. Every declared scenario must
pass; there are no known-failure exemptions. Transactions, population,
plugins, middleware, vector search, and unlisted model APIs are outside this profile.

## Run locally

Use the repository dev container or a prepared Python 3.12 tooling container,
with a Linux Docker daemon capable of running Linux x64 images. Install trusted
controller dependencies there, not in the disposable integration client:

```bash
python -m pip install -r compatibility/requirements.txt
python -m compatibility.runner --integration pymongo \
  --output compatibility/.test-results/pymongo-001/result.json
python -m compatibility.runner --integration pymongo --version 4.9.0 \
  --output compatibility/.test-results/pymongo-4.9.0/result.json
python -m compatibility.runner --integration nodejs \
  --output compatibility/.test-results/nodejs-001/result.json
python -m compatibility.runner --integration mongoose \
  --output compatibility/.test-results/mongoose-001/result.json
```

Each invocation requires a fresh output path and creates fresh credentials,
containers, an internal Docker network, and disposable databases. Only the
controller has Docker access. The integration client receives no checkout mount,
Docker socket, publication credential, or external network access.

The runner builds the client without build-time network access after downloading
verified wheels. `--wheelhouse /path/to/wheels` reuses downloaded wheels, but PyPI
metadata verification still requires network access. Do not disable TLS
verification for package downloads.

For Node.js profiles, `--package-cache /path/to/cache` reuses archives named
`<sha256-of-the-lockfile-integrity-string>.tgz`. Every cached archive is verified
against the reviewed lockfile; a complete cache needs no registry access.
`--wheelhouse` is Python-only and `--package-cache` is Node-only. Node.js is needed
only inside the pinned client container, not on the controller host.

The output includes `result.json`, a sanitized `result.log`, and `result.xml`
when tests execute. Setup failures still produce a validated JSON envelope and
diagnostics. Cleanup targets only the invocation's labeled Docker resources.
The runner refuses to overwrite existing results or diagnostic files.

To verify the nonpassing path:

```bash
python -m compatibility.runner --integration pymongo --demonstration \
  --output compatibility/.test-results/pymongo-demo-001/result.json
python -m compatibility.runner --integration nodejs --demonstration \
  --output compatibility/.test-results/nodejs-demo-001/result.json
python -m compatibility.runner --integration mongoose --demonstration \
  --output compatibility/.test-results/mongoose-demo-001/result.json
```

This runs the normal scenarios plus one labeled intentional assertion failure
and must exit nonzero. Demonstration evidence cannot replace a compatibility
verdict. Use only synthetic data; do not supply production credentials.

## Interpret results

Working requires verified identities and every required scenario to pass.
A conclusive assertion or operation failure produces Failing. Missing, skipped,
incomplete, or infrastructure-failed execution cannot become Working and is
reported as Not tested unless a conclusive compatibility failure is present.

Inspect the scenario diagnostics and declared coverage before reporting a
compatibility problem. Distinguish an operation mismatch from a package-download,
readiness, or cleanup failure. Include a minimal synthetic reproduction, the
integration and database versions, the profile, and sanitized result/log details.
Never share credentials or customer data.

Runs emit runtime-neutral schema version 2. Schema-version-1 Python records remain
readable without rewriting their immutable provenance.

## Results and dashboard preview

Append locally produced normal and demonstration records to an immutable store:

```bash
python -m compatibility.publish \
  --result compatibility/.test-results/pymongo-001/result.json \
  --store compatibility/.test-results/history \
  --site compatibility/.test-results/site --preview
python -m compatibility.publish \
  --result compatibility/.test-results/pymongo-demo-001/result.json \
  --store compatibility/.test-results/history \
  --site compatibility/.test-results/site --preview
```

Open `compatibility/.test-results/site/index.html`. The same validated history
produces HTML, `current.json`, and `history.json`. Conflicting run IDs are rejected;
identical replays are idempotent. Demonstrations remain separate from normal
compatibility evidence. Local runs have no fabricated pipeline URL.

| State | Meaning |
| --- | --- |
| Working | All required scenarios passed with verified artifacts |
| Failing | A conclusive assertion or non-timeout operation/protocol failure |
| Not tested | Missing or skipped coverage, timeouts, setup errors, or other incomplete execution |
| Stale | The last conclusive result is older than the profile's freshness policy or no longer matches its execution inputs/artifacts |

If a newer attempt cannot execute, retain the previous conclusive result while
exposing the new attempt's failure separately. Keep version pairs and profiles
distinct. Browser-side freshness also ages previously rendered results.

The `--preview` option labels review prototypes and hides public issue links.
Without it, the renderer provides prefilled links to the product repository's
compatibility issue form. A report should include the actual version pair,
runtime/profile, relevant run, and a minimal synthetic reproduction, never
credentials or customer data.

This renderer does not push Git history, deploy a site, create issues, or change
repository settings. Public hosting and durable publication require a separately
approved destination, publisher, operational owner, and reporting route.

## GitHub Actions workflow

Manual dispatch requires the workflow on the repository's default branch.
Select **Ecosystem compatibility** in the Actions tab, then choose the branch
and reviewed database release to exercise. The integration
defaults to `all`: a planning job expands every enabled registry entry using its
own reviewed default version. Select one integration for a focused run or version
override. A version override with `all`, a disabled integration, a version outside
its registry policy, or an unknown database release is rejected before test jobs
start. Keep the failure demonstration disabled for real results.

Each matrix job runs its complete scenario suite against its own disposable
database. Matrix fail-fast is disabled. JSON and available JUnit/logs are retained
in `compatibility-results-<integration>-<attempt>` artifacts even when the job
fails. Results record the `manual` trigger and exact workflow-attempt URL.

After the matrix finishes, reporting validates each selected result's identity,
coverage, artifacts, suite digest, and workflow-attempt URL. The summary includes
every selected integration. Missing or rejected results are **Not tested**, with
a diagnostic, not fabricated envelopes or an earlier attempt's pass. Compatibility
failures remain **Failing**, and failed or incomplete reports exit nonzero without
suppressing matrix failures.

The `compatibility-report-<attempt>` artifact contains `summary.md`, machine-readable
`summary.json`, accepted envelopes in `results/`, and a combined preview in `site/`.
Only selected profiles and versions appear, including explicit overrides and
labeled demonstrations. All artifacts have 30-day retention.

Use **Re-run all jobs** for a complete matrix rerun. Reporting deliberately
collects only the current attempt's artifacts, so rerunning only failed jobs can
leave other integrations without current-attempt evidence. Re-running an older
workflow retains its original commit; dispatch a fresh run to test new code.

All jobs have read-only repository permissions. The workflow does not publish
Git history, deploy a site, create issues, or change repository settings.

To inspect selection or combine locally produced records:

```bash
python -m compatibility.workflow matrix --integration all
python -m compatibility.workflow report --integration all \
  --input compatibility/.test-results/incoming \
  --output compatibility/.test-results/combined-001
```

Place each record under `incoming/<integration>/result.json`. Use the same
integration, version, database, and demonstration selection as the producing
runs, and a fresh output directory. `--expected-run-url` binds a combined report
to one workflow attempt; omit it for local results. `--summary` appends the
Markdown report to a GitHub step-summary file.

## Durable Git history

The generic history helper is available for an explicitly configured trusted
publisher, not for integration clients:

```bash
bash compatibility/persist.sh /path/to/result.json "$EXPECTED_RUN_URL"
```

Run it from the trusted source checkout with write access to the intended
`origin`. Set `EXPECTED_RUN_URL` to the originating test attempt, not a later
publication retry. The helper verifies that URL, declared coverage, database
artifact, and execution-input digest, then appends `results/<id>.json` to
`compatibility-data`.

The helper uses non-force pushes with bounded conflict retries and initializes
an orphan branch containing only result data. Identical replays are idempotent;
conflicting run IDs fail rather than overwrite history. Concurrent writers'
records survive retry, and temporary worktrees are removed. Retain the data
branch independently of artifact expiration.

Keep write credentials separate from integration execution. A publisher must
retain failed attempts and serialize deployment only after results are durably
stored. Render complete history with `compatibility.publish`, using `--preview`
for review prototypes. Deployment retries must not delete or rewrite history.
Cancellation before persistence is not a compatibility verdict.

Invoke this helper explicitly from the trusted publisher; the compatibility
workflow does not call it. It does not configure hosting, GitHub Pages,
credentials, repository permissions, or a release-watcher ledger.

## Extend and maintain

Add a reviewed adapter directory, pinned image and package requirements, normal
and deliberate-failure suites, and a registry entry naming every required
scenario. Keep package preparation, runtime validation, and provenance support
with any new runtime. Enable an integration only when its real adapter exists.
A registry entry alone does not implement runtime support.
Expose it in the workflow's integration selector as well as the registry.

Run infrastructure checks in a prepared Python 3.12 tooling container:

```bash
python -m pip install -r compatibility/requirements-dev.txt
python -m black --check --config compatibility/pyproject.toml compatibility
python -m isort --check-only --settings-path compatibility/pyproject.toml compatibility
python -m flake8 --max-line-length=100 --extend-ignore=E203 compatibility
python -m mypy --config-file compatibility/pyproject.toml compatibility
python -m pytest -c compatibility/pyproject.toml compatibility/unit
shellcheck compatibility/persist.sh
node --test compatibility/unit/test_freshness.cjs compatibility/unit/test_nodejs.cjs
```

Run the JavaScript reporting and freshness checks with Node 24 in a tooling
container. They do not require a database or installed integration packages.

Also exercise normal and deliberate-failure runs against the selected released
database image. Assertions and fixtures should derive selected configuration
from the registry rather than duplicate version pins. No unchanged database or
gateway build is required for compatibility-only changes.
