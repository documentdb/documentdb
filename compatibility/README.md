# Ecosystem compatibility

This registry-driven runner tests ecosystem integration profiles against reviewed
DocumentDB releases. Execution, artifact verification, and result contracts are
shared; each integration adapter implements its own scenario suite.

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

## Coverage

The PyMongo profile exercises synchronous driver APIs. Its required scenarios are
declared in the registry's `expected_tests` list and cover the following behavior:

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

Runs emit runtime-neutral schema version 2. Schema-version-1 Python records remain
readable without rewriting their immutable provenance.

## Extend and maintain

Add a reviewed adapter directory, pinned image and package requirements, normal
and deliberate-failure suites, and a registry entry naming every required
scenario. Keep package preparation, runtime validation, and provenance support
with any new runtime. Enable an integration only when its real adapter exists.
A registry entry alone does not implement runtime support.

Run infrastructure checks in a prepared Python 3.12 tooling container:

```bash
python -m pip install -r compatibility/requirements-dev.txt
python -m black --check --config compatibility/pyproject.toml compatibility
python -m isort --check-only --settings-path compatibility/pyproject.toml compatibility
python -m flake8 --max-line-length=100 --extend-ignore=E203 compatibility
python -m mypy --config-file compatibility/pyproject.toml compatibility
python -m pytest -c compatibility/pyproject.toml compatibility/unit
```

Also exercise normal and deliberate-failure runs against the selected released
database image. Assertions and fixtures should derive selected configuration
from the registry rather than duplicate version pins. No unchanged database or
gateway build is required for compatibility-only changes.
