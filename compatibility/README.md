# Ecosystem compatibility

This registry-driven runner tests ecosystem integrations against a released
DocumentDB image. PyMongo is the first reference integration. Shared execution,
artifact verification, and result contracts are separate from the integration's
scenario suite.

Only the synchronous PyMongo profile is implemented here. A manual workflow
selects enabled integrations and combines their validated results as Markdown,
HTML, and JSON. An opt-in upstream watcher can request that same profile for
eligible PyMongo releases. Additional runtimes and durable result publication
are separate additions. A registry entry alone does not implement a new runtime.

## Reviewed baseline

[`registry.yaml`](registry.yaml) selects DocumentDB **0.117.0**, PostgreSQL
major **17**, and extension version **0.117-0**. Database and client base images
are pinned by digest.

| Integration | Package version | Runtime | Profile |
| --- | --- | --- | --- |
| `pymongo` | 4.18.0 | Python 3.12 | `python312-linux-x64-sync` |

These are reproducible reviewed baselines, not claims about the newest releases.
Stable PyMongo 4.9 and later 4.x versions can be selected explicitly. Use three
numeric components, such as `--version 4.9.0`; equivalent published versions
such as `4.9` are matched using package-version semantics. A version without an
eligible Python 3.12 Linux x64 wheel is Not tested, not Working.

Before executing scenarios, the controller checks the actual extension and
PostgreSQL major versions. It verifies the selected wheel's filename and SHA-256
against non-yanked PyPI metadata. The client records installed package and
dependency versions and hashes, its runtime version, and its image identity.
An execution-input digest includes the suite, controller, schemas, and runtime
recipe, including uncommitted local changes.

## Coverage

The profile declares 17 required scenarios and calls real PyMongo APIs:

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
for async APIs, transactions, vector search, or other unlisted features.

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
```

Each invocation requires a fresh output path and creates fresh credentials,
containers, an internal Docker network, and disposable databases. Only the
controller has Docker access. The integration client receives no checkout mount,
Docker socket, publication credential, or external network access.

The runner builds the client without build-time network access after downloading
verified wheels. `--wheelhouse /path/to/wheels` reuses downloaded wheels, but PyPI
metadata verification still requires network access. Do not disable TLS
verification for package downloads.

The output includes `result.json`, a sanitized `result.log`, and `result.xml`
when tests execute. Setup failures still produce a validated JSON envelope and
diagnostics. Cleanup targets only the invocation's labeled Docker resources.
The runner refuses to overwrite existing results or diagnostic files.

To verify the nonpassing path:

```bash
python -m compatibility.runner --integration pymongo --demonstration \
  --output compatibility/.test-results/pymongo-demo-001/result.json
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

New runs use runtime-neutral schema version 2. Historical schema-version-1 Python
records remain readable without rewriting their immutable provenance.

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

**Ecosystem compatibility** runs through manual dispatch. Once the workflow
exists on the repository's default branch, select it in the Actions tab and
choose the branch and reviewed database release to exercise. The integration
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
Markdown report to a GitHub step-summary file. Upstream-triggered reports also
carry their detection ID and `upstream_release` trigger through JSON and the
dashboard; the Markdown summary labels the trigger.

## Opt-in upstream release watcher

The reviewed source is
[compatibility-watcher.md](../.github/workflows/compatibility-watcher.md).
Its generated `.lock.yml` runs GitHub Agentic Workflows with the Copilot engine.
It is disabled unless both repository or organization variables are configured:

| Variable | Required value |
| --- | --- |
| `COMPATIBILITY_WATCHER_ENABLED` | The literal string `true` |
| `COMPATIBILITY_WATCHER_MODEL` | An organization-approved Copilot model ID |

Before enabling it, maintainers must approve the model and organization Copilot
authentication, including the `copilot-requests: write` permission, Actions
budgets, and the dedicated state branch. No PAT or new secret is required by
the authored workflow. It does not configure subscriptions, credentials,
variables, branch rules, or hosting.

Merge both workflows onto the default branch before enabling them. The watcher
accepts only scheduled or manual execution on that branch. It runs daily at
08:23 UTC and can also be started with **Run workflow**. Its invocations are
serialized. Disable the enablement variable to stop future work, and explicitly
cancel an in-flight run when immediate suspension is needed.

Deterministic discovery reads at most the latest 30 releases from the official
`mongodb/mongo-python-driver` GitHub repository and verifies their PyPI metadata.
Only stable releases at least as new as the reviewed baseline, within the
registry's version policy, and with eligible non-yanked wheels are considered.
The wheel tags match the runner's Python 3.12 Linux x64 download policy.
`Requires-Python` must admit **3.12.0**, a conservative floor: a release requiring
a newer 3.12 patch is not automatically selected even if a particular image
could run it. Unpublished metadata is recorded and reconsidered on later scans.

At most three new version pairs are recorded per invocation. Each detection
includes the upstream artifacts and hashes, DocumentDB image and version,
profile, execution-input digest, source revision, release evidence, and discovery
run. The key covers the execution identity, not just the latest version string.

The read-only AI agent receives at most three bounded public release excerpts
and known scenario IDs. It provides an advisory summary and optional scenario
references, not commands, eligibility decisions, or compatibility verdicts.
It cannot reduce coverage. Its assessment retains the model, prompt hash, and
run URL. The release-analysis agent has a four-turn, ten-minute inference limit;
framework validation has separate bounded jobs. These limits are not a monetary
budget.

The trusted dispatcher runs the complete affected profile even if AI analysis
fails or omits a release. Missing analysis is explicitly marked `unavailable`,
with a warning; failed AI jobs are not turned green. Before dispatch, the code
revalidates the reviewed execution inputs and official release artifacts.
An unexpected downloaded artifact is rejected before Docker build or execution.
Only the planning step reads watcher state. No GitHub or inference token is
passed to the isolated test client.

### State, retries, and recovery

The orphan `compatibility-watcher-state` branch contains a single `ledger.json`.
Non-force Git reference updates reject concurrent writers. Each reservation is
persisted before contacting the dispatch API, and the resulting workflow receipt
is saved afterward. Git history retains earlier scans and state transitions.
Allow the workflow's GitHub token to create and update this data branch; a denied
write stops the operation rather than falling back to ephemeral deduplication.

There are at most three automatic dispatch requests per invocation and three
automatic attempts per detection. Only definite rate-limit rejections are
automatically retried on later invocations. Unknown outcomes are reconciled by
receipt or the exact detection/dispatch nonce in the workflow title, never
blindly resent. The bounded lookup covers up to seven days and 1,000 runs.
Incomplete lookups and duplicate nonces require attention.

| Ledger status | Meaning |
| --- | --- |
| `pending` | Durable eligible work waiting for dispatch, possibly after a rate limit |
| `dispatching` | A reservation exists but its API outcome is not yet established |
| `dispatched` | A validated workflow receipt is recorded |
| `completed` | The associated workflow is terminal, not a compatibility pass |
| `blocked` | Automatic processing stopped and requires maintainer investigation |
| `superseded` | The reviewed execution inputs, policy, or upstream artifacts changed |

For a known workflow receipt, use **Re-run all jobs** to repeat the full selected
profile. If dispatch was rejected or its outcome is unknown, first inspect the
recorded watcher run and search the compatibility workflow for the exact nonce.
If no run was accepted, manually dispatch **Ecosystem compatibility** on the
default branch with the recorded integration/version/database, `detection_id`,
and last attempt's `dispatch_id`. Keep demonstration disabled and do not create
a new nonce. The consumer validates these inputs against the ledger, and the next
watcher invocation can associate the manual run. After execution inputs change,
use a new discovery rather than overriding the identity checks. An ordinary
manual run with both IDs blank remains available independently of the watcher.

Inspect compatibility artifacts and use the reporting guidance above for
conclusive scenario failures. `completed`, successful dispatch, or AI analysis
does not establish Working. Watcher failures remain visible as failed Actions
jobs and ledger errors; this version does not automatically create issues.

The ledger is bounded to 1,000 entries and 2 MiB. Exhaustion stops new writes
and requires a reviewed retention strategy preserving the audit and deduplication
identities. Do not delete the state branch or old detection IDs to retry work.
Watcher state is not the compatibility-result history or an automatically
published dashboard.

The initial watcher supports only the reviewed PyMongo path. Newer Node.js or
Mongoose releases require a reviewed manifest/lockfile update and metadata
adapter before automatic execution can be added. DocumentDB release/RC fan-out,
public hosting, and automatic result publication remain separate follow-ups.

### Regenerate the watcher

Use the pinned `gh-aw` **v0.89.21** compiler and release action mode. The
infrastructure workflow downloads its Linux x64 binary, verifies its SHA-256,
validates the workflow, and rejects generated-file drift. Make authored changes
in the Markdown file, then compile with that same binary:

```bash
gh-aw compile compatibility-watcher \
  --action-mode release --strict --validate --no-check-update
```

Commit the Markdown, generated lock workflow, and `.github/aw/actions-lock.json`
together. Do not hand-edit the generated YAML. The pinned compiler's schema
validation understands the Copilot permission and queued-concurrency fields;
older standalone Actions linters may not. Local unit tests simulate inference,
GitHub receipts, interruptions, and real Git conflicts without production
dispatches or live inference.

## Extend and maintain

Add a reviewed adapter directory, pinned image and package requirements, normal
and deliberate-failure suites, and a registry entry naming every required
scenario. Keep package preparation, runtime validation, and provenance support
with any new runtime. Enable an integration only when its real adapter exists.
Expose it in the workflow's integration selector as well as the registry.

Run infrastructure checks in a prepared Python 3.12 tooling container:

```bash
python -m pip install -r compatibility/requirements-dev.txt
python -m black --check --config compatibility/pyproject.toml compatibility
python -m isort --check-only --settings-path compatibility/pyproject.toml compatibility
python -m flake8 --max-line-length=100 --extend-ignore=E203 compatibility
python -m mypy --config-file compatibility/pyproject.toml compatibility
python -m pytest -c compatibility/pyproject.toml compatibility/unit
node --test compatibility/unit/test_freshness.cjs
```

Run the JavaScript freshness checks with Node 24 in a tooling container. They do
not require a database or installed integration packages.

Also exercise normal and deliberate-failure runs against the selected released
database image. Assertions and fixtures should derive selected configuration
from the registry rather than duplicate version pins. No unchanged database or
gateway build is required for compatibility-only changes.
