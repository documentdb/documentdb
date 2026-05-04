---
rfc: 0007
title: "Functional Test PR Gating with Allow-List and Pinned Upstream Image"
status: Draft
owner: "@guanzhousongmicrosoft"
issue: "https://github.com/documentdb/documentdb/issues/567"
discussion: ""
version-target: TBD
implementations: []
---

# RFC-0007: Functional Test PR Gating with Allow-List and Pinned Upstream Image

## TL;DR

Use a pinned upstream `functional-tests` image plus a DocumentDB-owned `allowlist.yml` as the Phase 1 PR gate.

For each allow-listed test, the rule is strict: **collected + executed + PASS**. Missing, skipped, xfailed, deselected, errored, or non-passing tests fail the gate. Tests outside the allow-list are not rejected; they remain visible through promotion-candidate full-suite reports that maintainers run when they are prepared to review and promote newly passing tests.

If a PR adds DocumentDB functionality that makes pinned `functional-tests` cases newly pass, the PR must add those test IDs to `allowlist.yml` in the same PR.

This gives normal PR authors a stable gate, lets test contributors add upstream tests without being blocked by DocumentDB compatibility gaps, and keeps coverage growth reviewable instead of automatic.

## Relationship to RFC-0005

[RFC-0005](0005-functional-testing.md) defines the end-to-end functional-testing framework and the shared `functional-tests` repository. RFC-0007 defines how the core `documentdb` repo consumes that framework as a pinned, required PR gate with explicit allow-list ownership.

## Problem

DocumentDB needs a functional-test PR gate to catch regressions in supported behavior without forcing every contributor to triage every upstream compatibility gap.

The `functional-tests` repository is a black-box test framework for document databases, hosted in the DocumentDB GitHub organization and intended to accept contributions from multiple engines. DocumentDB the engine should not treat upstream tests as invalid simply because they do not currently pass.

At the same time, DocumentDB PRs need stable and reproducible gating. If a required PR gate always pulls a moving upstream test image, unrelated DocumentDB PRs can fail because upstream tests changed after the PR was opened.


### Goals

1. Keep the normal PR author workflow simple.
2. Catch regressions in behavior that DocumentDB already supports.
3. Preserve reproducibility by pinning the upstream test image.
4. Treat `functional-tests` as a black-box upstream suite.
5. Require feature PRs to add relevant newly passing pinned tests to `allowlist.yml` when they expand supported behavior.
6. Grow functional coverage over time through reviewable allow-list promotion.
7. Use positive allow-list gating: if an allow-listed test fails, fix the regression or update the allow-list to match the intended support boundary.
8. Avoid turning non-passing upstream tests into a DocumentDB-maintained deny list.
9. Avoid blocking unrelated DocumentDB PRs when upstream tests change.

### Non-goals

1. Do not classify every upstream failure by DocumentDB root cause.
2. Do not require DocumentDB to approve or reject upstream tests before they exist.
3. Do not make normal product PRs triage unrelated upstream test changes.
4. Do not use the allow-list as a way to hide regressions in behavior already supported by DocumentDB.

---

## Approach

DocumentDB should use a positive allow-list model with a pinned upstream test image.

Short version:

```text
functional-tests provides shared black-box tests.
DocumentDB owns the set of pinned tests required in this repo's PR gate.
```

The allow-list does not say that tests outside the list are bad, invalid, or rejected. It only says that the listed tests are part of DocumentDB's current required PR gate.

If a PR adds functionality that makes tests in the pinned image pass, and those tests represent intended supported behavior, the same PR should add the relevant test IDs to `allowlist.yml`. That makes the new behavior part of the PR gate instead of waiting for a later bulk promotion.

An allow-list failure is a regression signal. The PR should either repair DocumentDB behavior or update `allowlist.yml` to match the intended support boundary.

```text
Allowed test
  = currently expected to pass on DocumentDB
  = required in PR gate
  = failure is a regression or bug to fix

Outside allow-list
  = upstream test not currently required in DocumentDB PR gate
  = still useful signal in scheduled or on-demand promotion-candidate full-suite runs
  = candidate for future promotion when maintainers are ready to review it
```

The pinned image is the reproducibility boundary.

```text
DocumentDB PR gate input:
  - DocumentDB PR code
  - DocumentDB allow-list from the PR branch
  - pinned upstream functional-tests image

The upstream test image does not change underneath an unrelated PR.
```

---

## Detailed Design

### Rollout phases

This RFC is intended to start with a small, usable framework rather than a complete compatibility-management system.

#### Phase 1: Minimal PR gate and visibility report

Phase 1 establishes the core contract:

```text
Pinned upstream image + allowlist.yml source of truth + required PR gate.
```

Phase 1 includes:

1. `image.yml` records the pinned upstream `functional-tests` image.
2. `allowlist.yml` is the source of truth for tests required in the PR gate.
3. PR CI runs only allow-listed tests from the pinned image.
4. CI fails if any allow-listed test is missing, skipped, deselected, not executed, or not passing.
5. Local reproduction scripts exist for running the full allow-list or one failed test.
6. A scheduled or on-demand promotion-candidate full-suite run generates a report when the team is prepared to review newly passing tests:
   - allow-listed tests that failed,
   - tests outside the allow-list that passed,
   - tests outside the allow-list that still do not pass.
7. Promotion is manual: contributors or maintainers update `allowlist.yml` in a normal PR after reviewing the promotion report.
8. The PR summary shows the coverage boundary: allow-listed tests run, total upstream tests discovered, and outside allow-list tests not run in the PR gate.

#### Phase 2: Image freshness and operational polish

Phase 2 adds automation and better operational UX after the basic gate is working.

Phase 2 includes:

1. Scheduled image freshness checks.
2. Automated image bump PRs when the candidate image passes the existing allow-list.
3. Blocked-adoption reports when the candidate image fails existing allow-list validation.
4. Better failure diagnosis in PR summaries.
5. Additional coverage dashboards or trend reports if needed.
6. Maintainer tooling to validate, sort, deduplicate, and add allow-list entries.
7. Optional stale-ID tooling to suggest replacements when upstream tests are renamed, moved, or re-parameterized.
8. Optional allow-list sharding if the single file becomes too large.
9. Runtime budget tracking and suite sharding if the PR gate grows too slow.

---

### Repository responsibility split

Terminology:

```text
PR-gate image     pinned digest in image.yml; what every PR uses
Candidate image   newer upstream image being evaluated for adoption
Upstream image    any image published by the functional-tests repo
```

```text
+------------------------------------------------+
| functional-tests repo (DocumentDB org)         |
|                                                |
| Shared black-box test framework                |
| Maintained by the wider DocumentDB team        |
| Publishes immutable test images                |
| Does not define this repo's support boundary   |
+-----------------------+------------------------+
                        |
                        | pinned image digest
                        v
+------------------------------------------------+
| documentdb repo                                |
|                                                |
| Owns pinned image used by DocumentDB PR gate   |
| Owns allow-list of required passing tests      |
| Owns PR gate policy and promotion workflow     |
| Consumes upstream test results as black-box    |
+------------------------------------------------+
```

Important boundary:

```text
DocumentDB should not deny an upstream test just because DocumentDB fails it.
DocumentDB should only decide whether that upstream test is required in the
DocumentDB PR gate today.
```

---

### Proposed DocumentDB configuration

Recommended layout:

```text
test-config/functional-tests/
  image.yml               # pinned upstream functional-tests image
  allowlist.yml           # source of truth for required passing tests
```

#### Image pin

`image.yml` records the upstream image used by the required PR gate.

```yaml
image: ghcr.io/documentdb/functional-tests@sha256:abc123
source_ref: refs/heads/main
source_sha: abcdef123456
updated_by: https://github.com/documentdb/documentdb/pull/NNNN
```

This file answers:

```text
Which upstream test suite did this PR gate use?
Can we reproduce the same gate later?
```

#### Allow-list

`allowlist.yml` is the source of truth for the upstream tests that DocumentDB currently requires to pass.

```yaml
schema_version: 1

tests:
  - documentdb_tests/compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_eq
  - documentdb_tests/compatibility/tests/core/query-and-write/commands/insert/test_insert_operations.py::test_insert_one
```

The allow-list should stay positive and simple. It should not become a catalog of every unsupported feature or every known upstream failure.

Required fields:

```text
test id   exact upstream pytest node id
```

Phase 1 uses exact pytest node IDs as the machine key. Parameterized tests must be listed with their full parameter suffix, for example:

```yaml
tests:
  - documentdb_tests/compatibility/tests/core/query-and-write/commands/find/test_find_comparison.py::test_find_comparison[$gt]
```

The allow-list should not use path globs, function-level wildcards, or marker-level matching in Phase 1. Those shortcuts are easier to write, but they can silently include new upstream cases without review. If upstream renames or rewrites parameter IDs, the gate should report missing IDs and require a reviewed replacement.

Reporting metadata such as area, short name, and tags should be derived automatically from upstream test paths, pytest markers, or result metadata. It should not be manually repeated on every allow-list entry.

Example derived areas:

```text
.../commands/find/...        -> find
.../commands/insert/...      -> insert
.../commands/update/...      -> update
.../operator/stages/...      -> aggregate
.../collections/...          -> collection_mgmt
.../sessions/...             -> sessions
unrecognized path/marker     -> unknown
```

If the tooling cannot infer an area, it should report `unknown`; this should not block the PR gate.

Phase 1 keeps `allowlist.yml` intentionally small. Per-area ownership, richer taxonomy, and sharded files can be added later if the allow-list grows large enough to need them.

#### Test selection mechanism

With 9,000+ upstream tests and an allow-list that may grow over time, the selection mechanism must handle scale without hitting OS argument-length limits.

The recommended approach is a `pytest_collection_modifyitems` conftest hook. This is the same pattern the upstream `functional-tests` framework already uses for `no_parallel` deselection.

The DocumentDB allow-list hook must run before upstream deselection hooks, using `@pytest.hookimpl(tryfirst=True)`, so missing-ID validation compares the allow-list against the full collection before upstream `no_parallel` filtering mutates the item list.

The hook:

1. Lets pytest collect all tests normally.
2. Reads `allowlist.yml` to get the set of required test IDs.
3. Detects missing allow-listed IDs against the full collection and fails with a config error.
4. Detects allow-listed tests marked `no_parallel`.
5. Deselects any collected test not in the allow-list.

This hook is maintained in the DocumentDB repo and mounted into the upstream container at runtime.

Phase 1 keeps the PR gate simple by running only parallel-safe allow-listed tests under `-n auto`. If an allow-listed test is marked `no_parallel`, CI must fail with a clear allow-list configuration error instead of letting upstream deselection make the test look missing or skipped.

A later phase may add a second sequential invocation for allow-listed `no_parallel` tests. Until that exists, they should be excluded from bootstrap output and rejected during allow-list validation.

Why this over alternatives:

```text
Pass IDs as CLI args          can hit OS arg length limits with many long node IDs
--collect-only + second pass  still needs a way to pass selected IDs to the run step
--deselect for non-listed     inverting thousands of IDs is worse than selecting required IDs
conftest hook                 no arg limit, works with -n auto for parallel-safe tests,
                              detects missing IDs, reports deselect count natively
```

#### Bootstrap: initial allow-list generation

The initial allow-list cannot be built manually for 9,000+ tests. Phase 1 includes a one-time bootstrap script that:

1. Runs the full upstream suite against current DocumentDB.
2. Collects all parallel-safe tests with outcome `PASS`.
3. Outputs a candidate `allowlist.yml`.
4. Maintainers review and merge the initial list in a normal PR.

After bootstrap, the allow-list grows through the normal promotion workflow.

---

### User workflows

#### 1. Normal DocumentDB PR

This is the most important workflow to keep simple.

```text
+------------------------+
| Developer opens PR     |
+-----------+------------+
            |
            v
+------------------------+
| CI pulls pinned image  |
+-----------+------------+
            |
            v
+------------------------+
| CI runs allow-list only|
+-----------+------------+
            |
            v
+------------------------+
| Did allowed tests pass?|
+-----+-------------+----+
      |             |
      | yes         | no
      v             v
+----------+   +------------------------+
| Green    |   | Red: supported behavior|
| proceed  |   | may have regressed     |
+----------+   +-----------+------------+
                           |
                           v
                +-----------------------+
                | Fix DocumentDB code   |
                | or update allow-list  |
                +-----------------------+
```

Expected PR summary when the gate passes:

```text
Functional gate passed

Image:
  ghcr.io/documentdb/functional-tests@sha256:abc123

Allow-list:
  512 tests selected
  512 passed
  0 failed
  0 missing

Coverage boundary:
  upstream tests discovered in pinned image: 9,943
  outside allow-list and not run in PR gate: 9,431

Outside allow-list:
  not run in PR gate
```

Expected PR summary when an allowed test fails:

```text
Functional gate failed

1 allow-listed test failed.

Meaning:
  This test is already required for DocumentDB PRs.
  Treat this as a regression in supported behavior.

Action:
  Fix DocumentDB code or update allowlist.yml if the support boundary changed.

Failed:
  short name: test_find_basic_queries.py::test_find_eq
  full id: documentdb_tests/compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_eq
```

#### 2. Feature PR where tests already exist in the pinned image

```text
+-------------------------+
| Implement feature       |
+-----------+-------------+
            |
            v
+-------------------------+
| Add passing upstream    |
| tests to allow-list     |
+-----------+-------------+
            |
            v
+-------------------------+
| PR gate runs old + new  |
| allow-listed tests      |
+-----------+-------------+
            |
            v
+-------------------------+
| Merge when all pass     |
+-------------------------+
```

This is the preferred path when possible. The contributor only changes DocumentDB code and the allow-list. If the PR makes pinned tests newly pass and those tests cover intended supported behavior, adding them to `allowlist.yml` is required, not optional.

#### 3. Feature PR where tests require a newer upstream image

If the required tests are not in the current pinned image, use either a split workflow or a combined workflow.

Preferred split workflow:

```text
PR 1: image adoption
  - bump pinned functional-tests image
  - prove existing allow-list still passes
  - do not require every new upstream test to pass

PR 2: feature support
  - implement DocumentDB feature
  - add relevant newly passing tests to allow-list
```

Combined workflow when splitting is too expensive:

```text
Single feature PR:
  - bump pinned image
  - implement feature
  - add only feature-related passing tests to allow-list
  - prove existing allow-list still passes
  - prove newly added allow-list tests pass
```

Key rule:

```text
New upstream tests do not automatically block DocumentDB PRs.
Only allow-listed tests block DocumentDB PRs.
```

#### 4. Upstream test contributor workflow

Because `functional-tests` is a shared framework in the DocumentDB organization, contributors should be able to add tests there without waiting for DocumentDB the engine to support them.

```text
+-----------------------------+
| Contributor adds upstream   |
| black-box tests             |
+-------------+---------------+
              |
              v
+-----------------------------+
| functional-tests publishes  |
| immutable image             |
+-------------+---------------+
              |
              v
+-----------------------------+
| DocumentDB image adoption   |
| evaluates the new image     |
+-------------+---------------+
              |
              v
+-----------------------------+
| Passing DocumentDB behavior |
| can be promoted to allow-list|
+-----------------------------+
```

DocumentDB should not block upstream test creation because a test does not currently pass on DocumentDB.

#### 5. Initial allow-list seeding

Phase 1 needs a practical way to create the first allow-list. The initial allow-list should be generated from tests that pass against a chosen pinned image and then reviewed before committing.

```text
+-----------------------------+
| Choose pinned upstream image|
+-------------+---------------+
              |
              v
+-----------------------------+
| Run broad/full suite against|
| DocumentDB main             |
+-------------+---------------+
              |
              v
+-----------------------------+
| Generate candidate          |
| allowlist.yml from passes   |
+-------------+---------------+
              |
              v
+-----------------------------+
| Human review keeps stable   |
| supported-behavior tests    |
+-------------+---------------+
              |
              v
+-----------------------------+
| Commit image.yml and        |
| allowlist.yml               |
+-----------------------------+
```

If any existing skip, deselect, or expectation files exist, they can be used as input to understand current test coverage, but `allowlist.yml` should become the source of truth for the PR gate. No `deselect.list` PR-gate control exists in this repo today; if one is introduced before migration, it should be retired or ignored after migration because the allow-list is the inverse model and becomes authoritative.

#### 6. Image bump workflow

Image bumps should be separate and reviewable. Their primary question is:

```text
Do all existing allow-listed tests still pass on the candidate image?
```

```text
+------------------------------+
| Scheduled/manual job checks  |
| latest upstream image        |
+--------------+---------------+
               |
               v
+------------------------------+
| Run existing allow-list      |
| against candidate image      |
+--------------+---------------+
               |
               v
+------------------------------+
| Did existing allow-list pass?|
+------+-------------------+---+
       |                   |
       | yes               | no
       v                   v
+----------------+   +--------------------------+
| Open image     |   | Do not update PR gate    |
| bump PR        |   | Open investigation report|
+-------+--------+   +--------------------------+
        |
        v
+------------------------------+
| Human reviews that required  |
| behavior still passes        |
+--------------+---------------+
               |
               v
+------------------------------+
| Merge image bump             |
+------------------------------+
```

Expected blocked image bump summary:

```text
Functional test image bump blocked

Old image:
  sha256:old

Candidate image:
  sha256:new

Existing allow-list:
  512 tests
  509 passed
  3 failed

Meaning:
  The candidate upstream image changes behavior for tests that DocumentDB
  already requires.

Action:
  Investigate before promoting the image.
  Existing PR gate remains on the old image.
```

#### 7. Image freshness automation (Phase 2)

Pinned images protect PRs from moving upstream tests, but a pinned image can become stale. Phase 2 should automate image freshness and make it visible so the safe default does not become permanent stagnation.

A scheduled image freshness job should:

1. Check the latest published upstream `functional-tests` image.
2. Compare it with the current `image.yml` digest and source SHA.
3. Run the existing DocumentDB allow-list against the candidate image.
4. Open or update an image bump PR when the candidate image passes the existing allow-list.
5. Open or update a blocked-adoption report when the candidate image fails existing allow-list validation.
6. Report pinned image age, upstream commits behind, and candidate adoption status.

```text
+-----------------------------+
| Scheduled freshness job     |
+-------------+---------------+
              |
              v
+-----------------------------+
| Find latest upstream image  |
+-------------+---------------+
              |
              v
+-----------------------------+
| Run current allow-list      |
| against candidate image     |
+-------------+---------------+
              |
              +--> existing allow-list passes
              |       |
              |       v
              |   open/update image bump PR
              |
              +--> existing allow-list fails
                      |
                      v
                  keep current PR-gate image
                  open/update blocked report
```

Expected freshness report:

```text
Functional test image freshness

Current PR-gate image:
  ghcr.io/documentdb/functional-tests@sha256:old
  source sha: abc123
  age: 14 days
  upstream commits behind: 37

Latest candidate image:
  ghcr.io/documentdb/functional-tests@sha256:new
  source sha: def456

Adoption status:
  blocked

Reason:
  2 existing allow-listed tests fail on the candidate image.

Action:
  Current PR gate remains on sha256:old.
  Test-infra owner should investigate the blocked image adoption report.
```

This automation keeps image update work out of normal product PRs while ensuring the pinned image does not silently fall behind upstream.

#### 8. Scheduled or on-demand promotion-candidate full-suite report

Full-suite runs provide visibility and coverage growth, but they should happen when maintainers are prepared to review and promote newly passing tests. They should not directly block normal product PRs.

Cadence is a Phase 1 operational decision, not a contract. Start weekly or on demand, then move to a higher cadence only when promotion bandwidth justifies it.

The promotion-candidate report should run the broader/full upstream suite from the current pinned PR-gate image. This keeps coverage promotion tied to the same reproducible image used by PRs. The separate image freshness workflow evaluates the latest candidate image.

```text
+-----------------------------+
| Promotion run               |
+-------------+---------------+
              |
              v
+-----------------------------+
| Run broader/full upstream   |
| suite without allow-list    |
+-------------+---------------+
              |
              v
+-----------------------------+
| Generate promotion report   |
+-------------+---------------+
              |
              +--> allow-listed tests pass
              |       |
              |       v
              |   Healthy
              |
              +--> allow-listed tests fail
              |       |
              |       v
              |   Urgent regression, recent image bump,
              |   or infra investigation
              |
              +--> outside allow-list tests pass
              |       |
              |       v
              |   Manual promotion candidates
              |
              +--> outside allow-list tests fail
                      |
                      v
                  Compatibility visibility only
```

Expected promotion-candidate report:

```text
Functional-test promotion report

Image:
  ghcr.io/documentdb/functional-tests@sha256:abc123

Allow-list source:
  test-config/functional-tests/allowlist.yml

Required allow-list:
  512 total
  510 passed
  2 failed

Outside allow-list:
  9,431 total
  1,204 passed
  8,227 not passing

Findings:
  allow-listed tests failed: 2
  outside allow-list tests passed: 37

Manual promotion candidates:
  37 tests passed outside allow-list

Action:
  Investigate allow-listed failures.
  Maintainers may manually promote selected outside allow-list passing tests
  by adding them to allowlist.yml in a normal PR.
```

#### 9. Manual allow-list promotion workflow

Passing once in a promotion run should not automatically make a test required. Promotion is manual in the initial design.

```text
+------------------------------+
| Full-suite run finds outside |
| allow-list tests passing     |
+--------------+---------------+
               |
               v
+------------------------------+
| Maintainer reviews promotion |
| report                       |
+--------------+---------------+
               |
               v
+------------------------------+
| Maintainer opens normal PR   |
| updating allowlist.yml       |
+--------------+---------------+
               |
               v
+------------------------------+
| CI proves promoted tests pass|
+--------------+---------------+
               |
               v
+------------------------------+
| Merge; tests become required |
+------------------------------+
```

Expected promotion PR summary:

```text
Allow-list promotion

24 upstream tests passed outside the current allow-list and are proposed
for required PR gating.

Added:
  24 tests

Areas:
  find: 10
  insert: 6
  aggregate: 8

Required review:
  Confirm these are intended supported DocumentDB behaviors.
```

---

### Policy rules

#### Allow-list additions

Adding a test to the allow-list should be straightforward.

If a PR adds DocumentDB functionality that makes upstream `functional-tests` cases newly pass, the PR must add those test IDs to `allowlist.yml` in the same PR. New supported behavior and its required-passing tests land together.

For any allow-list addition, the test must:

1. Exist in the pinned image.
2. Pass in the PR.
3. Protect behavior that DocumentDB intends to support.

For a feature PR, newly added tests may pass only because the PR implements the feature. That is expected.

#### Pytest allow-list selection

Phase 1 should select allow-listed tests through a pytest collection hook, not by expanding thousands of node IDs on the command line.

Recommended approach:

```text
Use a DocumentDB-side pytest plugin/conftest that implements
pytest_collection_modifyitems and deselects non-allow-listed tests after
pytest collection.
```

This matches a pattern already used by upstream `functional-tests`: its `documentdb_tests/conftest.py` uses `pytest_collection_modifyitems` to deselect `no_parallel` tests when running under xdist. The allow-list gate should use the same pytest extension point, but it must run with `tryfirst=True` so it sees the full collection before upstream deselection hooks mutate the item list.

Phase 1 rejects allow-listed `no_parallel` tests with `ALLOWLISTED_NO_PARALLEL`. A later phase may add a separate sequential invocation for those tests.

Example wrapper:

```python
# conftest_allowlist.py, mounted into the container or loaded as a pytest plugin
import pytest
import yaml


MAX_REPORTED_IDS = 10


def _format_ids(ids):
    sorted_ids = sorted(ids)
    shown = sorted_ids[:MAX_REPORTED_IDS]
    remaining = len(sorted_ids) - len(shown)
    message = ", ".join(shown)
    if remaining:
        message += f", ... and {remaining} more"
    return message


def pytest_addoption(parser):
    parser.addoption("--allowlist", default=None, help="Path to allowlist.yml")


@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(session, config, items):
    allowlist_path = config.getoption("--allowlist")
    if not allowlist_path:
        raise pytest.UsageError(
            "--allowlist is required for the DocumentDB allow-list gate"
        )

    with open(allowlist_path) as f:
        data = yaml.safe_load(f)

    allowed_ids = set(data.get("tests", []))

    selected = []
    deselected = []
    matched_ids = set()
    no_parallel_ids = set()
    for item in items:
        if item.nodeid in allowed_ids:
            if item.get_closest_marker("no_parallel"):
                no_parallel_ids.add(item.nodeid)
            selected.append(item)
            matched_ids.add(item.nodeid)
        else:
            deselected.append(item)

    missing_ids = allowed_ids - matched_ids
    if missing_ids:
        raise pytest.UsageError(
            "allowlist.yml contains test IDs not found in the pinned image: "
            + _format_ids(missing_ids)
        )

    if no_parallel_ids:
        raise pytest.UsageError(
            "allowlist.yml contains tests marked no_parallel, but the Phase 1 "
            "PR gate runs with -n auto and has no sequential phase: "
            + _format_ids(no_parallel_ids)
        )

    if deselected:
        config.hook.pytest_deselected(items=deselected)
        items[:] = selected
```

The example truncates long ID lists so configuration errors stay readable when many IDs are missing or marked `no_parallel`.

Example invocation:

```bash
docker run --network host \
  -v "$(pwd)/test-config/functional-tests/allowlist.yml:/allowlist.yml" \
  -v "$(pwd)/scripts/functional-tests/conftest_allowlist.py:/extra/conftest_allowlist.py" \
  -e PYTHONPATH=/extra \
  ghcr.io/documentdb/functional-tests@sha256:abc123 \
  -p conftest_allowlist \
  --allowlist /allowlist.yml \
  -n auto \
  --connection-string "mongodb://localhost:10260"
```

Benefits:

1. No command-line argument length limit from passing many test IDs.
2. Collection walks all upstream tests, then filters in memory.
3. Pytest reports deselected tests through its native deselection mechanism.
4. Missing allow-listed IDs can be detected during collection before upstream deselection hooks mutate the item list.
5. The approach follows an existing upstream `functional-tests` hook pattern.

Tradeoffs:

1. Requires mounting or packaging a small DocumentDB-side pytest plugin/conftest.
2. Pytest still collects the full upstream suite before filtering. For 9,000+ tests this is expected to be acceptable for Phase 1, but runtime should be observed.
3. Phase 1 rejects allow-listed `no_parallel` tests unless a separate sequential phase is added.

#### Missing allow-listed tests

Missing allow-listed tests are configuration errors and must fail CI.

```text
+-------------------------------+
| CI loads pinned image         |
+---------------+---------------+
                |
                v
+-------------------------------+
| Resolve allow-list test IDs   |
+---------------+---------------+
                |
                +--> all found
                |       |
                |       v
                |   run tests
                |
                +--> some missing
                        |
                        v
                    fail before test run
```

Expected error:

```text
Functional gate configuration error

3 allow-listed tests were not found in the pinned functional-tests image.

This usually means:
  - upstream renamed tests
  - upstream deleted tests
  - image.yml was bumped without updating allowlist.yml

Action:
  update allowlist.yml with replacement test IDs, or revert image bump.
```

The gate must not silently ignore missing allow-listed tests.

#### Strict pass validation

Allow-listed means collected + executed + PASS. Nothing else counts.

For every allow-listed test ID, CI must prove:

```text
collected = yes
executed  = yes
outcome   = PASS
```

The following outcomes must not satisfy the allow-list gate:

```text
SKIPPED
XFAIL
XPASS
DESELECTED
NOT FOUND
ERROR BEFORE CALL
NO TESTS COLLECTED
```

This prevents the PR gate from passing without actually validating every required test.

The gate must not strip or ignore upstream `engine_xfail` markers. If an allow-listed test is marked as an expected failure for `documentdb`, that test no longer satisfies the allow-list contract even if the underlying behavior now passes. CI should surface this as an allow-list or image-adoption problem, not as a generic product regression.

---

### User-facing CI outcomes

Normal PR authors should only need to understand a small set of outcomes.

```text
+------------------------+
| Functional gate result |
+-----------+------------+
            |
            +--> PASS
            |     You are done.
            |
            +--> ALLOWED TEST FAILED
            |     Fix DocumentDB code.
            |
            +--> ALLOWLIST ERROR
            |     Fix allowlist.yml or test selection.
            |
            +--> IMAGE ERROR
            |     Fix image.yml, image pull, or image metadata.
            |
            +--> INFRA ERROR
                  Rerun or route to test infrastructure.
```

This keeps normal PR workflow simple while still preserving correctness.

#### Configuration and image error subtypes

`ALLOWLIST ERROR` should include a subtype so the fix path is clear:

| Subtype | Meaning | Typical fix |
|---------|---------|-------------|
| `INVALID_SCHEMA` | `allowlist.yml` is malformed or uses unsupported fields. | Fix YAML/schema. |
| `DUPLICATE_TEST_ID` | The same upstream test ID appears more than once. | Delete the duplicate entry. |
| `UNKNOWN_TEST_ID` | The allow-listed ID is not present in the pinned image. | Replace ID or revert image bump. |
| `TEST_NOT_COLLECTED` | The test exists but was not collected by pytest. | Fix selection/tooling. |
| `TEST_NOT_EXECUTED` | The test was collected but did not run. | Fix selection/tooling. |
| `ALLOWLISTED_NO_PARALLEL` | The allow-listed test is marked `no_parallel`, but Phase 1 has no sequential gate phase. | Update `allowlist.yml` or add an explicit sequential phase before promotion. |
| `ALLOWLISTED_ENGINE_XFAIL` | The allow-listed test is marked `engine_xfail(engine="documentdb")`. | Do not treat it as validated coverage; update upstream marker/image or update `allowlist.yml`. |
| `ALLOWLISTED_XPASS` | The test was expected to fail but passed; strict xfail behavior treats that as a failure. | Update the upstream expected-failure marker or block the image bump until the marker is corrected. |
| `NON_PASS_OUTCOME` | The test was skipped, xfailed, xpassed, errored, or otherwise not `PASS`. | Fix test/product behavior or update `allowlist.yml`. |

`IMAGE ERROR` should also include a subtype:

| Subtype | Meaning | Typical fix |
|---------|---------|-------------|
| `IMAGE_PULL_FAILED` | CI could not pull the pinned image. | Retry or fix image reference/registry issue. |
| `IMAGE_METADATA_MISMATCH` | Image digest/source metadata does not match `image.yml`. | Fix `image.yml` or republish/adopt correct image. |
| `IMAGE_RUNTIME_ERROR` | The image starts but cannot run the expected test command. | Investigate upstream image or wrapper script. |

#### Failure diagnosis requirements

Every failed PR gate must tell the contributor what failed, whether the failure is likely caused by the PR, and what to do next. Contributors should not have to start with raw pytest logs.

A failed functional gate summary should answer:

1. Which allow-listed tests failed?
2. Did the same tests fail on `main` with the same pinned image and allow-list?
3. Is the failure product-shaped, configuration-shaped, or infrastructure-shaped?
4. What is the recommended next action?
5. How can the contributor reproduce the failure locally?

Recommended failure categories:

| Category | Meaning | Contributor action |
|----------|---------|--------------------|
| `RESULT_MISMATCH` | The command ran, but returned different data than expected. | Usually fix DocumentDB behavior. |
| `ERROR_MISMATCH` | The command failed differently than expected. | Check validation, error code, or error message behavior. |
| `UNEXPECTED_ERROR` | The test expected success, but DocumentDB returned an error. | Check whether the PR broke supported behavior. |
| `INFRA_ERROR` | Environment, connection, timeout, startup, or infrastructure failure. | Rerun or route to test infrastructure. |
| `ALLOWLIST_ERROR` | Allow-list schema, duplicate ID, missing ID, or test selection problem. | Fix `allowlist.yml` or selection tooling. |
| `IMAGE_ERROR` | Image pull, metadata, or runtime problem. | Fix `image.yml`, registry access, or image adoption. |

Expected PR-caused failure summary:

```text
Functional gate failed

Likely caused by this PR:
  yes

Causality check:
  failed on PR branch: yes
  failed on main with same image: no

Failure type:
  RESULT_MISMATCH

Failed required test:
  short name: test_find_basic_queries.py::test_find_eq
  full id: documentdb_tests/compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_eq

Action:
  Fix DocumentDB behavior.
```

Expected not-caused-by-PR summary:

```text
Functional gate failed

Likely caused by this PR:
  no

Causality check:
  failed on PR branch: yes
  failed on main with same image: yes

Failure type:
  INFRA_ERROR

Action:
  This is probably not caused by your PR.
  Route to test infrastructure or main-branch break investigation.
```

#### Local reproduction command

Every failed gate should provide a copy-paste reproduction command that uses the same pinned image and the same selected test ID.

The command should support both the full allow-list and one failed test:

```text
# Reproduce the full PR gate locally.
./scripts/functional-tests/run-allowlist.sh

# Reproduce one failed allow-listed test.
./scripts/functional-tests/run-one.sh \
  documentdb_tests/compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_eq
```

The reproduction command should print the image digest, connection target, selected test IDs, and result artifact paths:

```text
Using functional-tests image:
  ghcr.io/documentdb/functional-tests@sha256:abc123

Selected tests:
  1

Result artifacts:
  test-results/functional-tests/report.json
  test-results/functional-tests/summary.md
```

The script should read `image.yml` and `allowlist.yml` by default so local reproduction uses the same pinned image and selected test IDs as CI. If local reproduction requires environment variables, seed data, or a running DocumentDB instance, the script should fail with a clear message instead of silently running a different setup.

If the test cannot be reproduced locally because it requires CI-only infrastructure, the summary should say that explicitly and point to the relevant CI artifacts.

---

### Coverage and visibility

The allow-list PR gate intentionally runs only a subset of upstream tests. To avoid losing visibility, DocumentDB should track coverage separately.

Recommended metrics:

```text
Required gate coverage:
  allow-listed tests / total upstream tests

Promotion opportunity:
  outside allow-list passing tests

Regression health:
  allow-listed failing tests

Adoption freshness:
  pinned image age / upstream commits behind

Runtime health:
  PR gate duration and slowest allow-listed tests
```

The PR summary should show the coverage boundary so a green gate is not confused with full upstream compatibility:

```text
Required functional gate:
  allow-listed tests run: 512
  upstream tests discovered in pinned image: 9,943
  outside allow-list and not run in PR gate: 9,431
```

The promotion/full-suite report should use neutral language:

```text
outside allow-list
not required in DocumentDB PR gate
not yet promoted
not currently passing on DocumentDB
```

Avoid language that implies upstream tests are rejected:

```text
deny-listed
invalid
bad test
not DocumentDB's problem
```

---

### End-to-end workflow

```text
                         +----------------------------+
                         | upstream functional-tests  |
                         | black-box test framework   |
                         +-------------+--------------+
                                       |
                                       v
                         +----------------------------+
                         | immutable published image  |
                         +-------------+--------------+
                                       |
                         image bump PR |
                                       v
+----------------------+     +----------------------------+
| documentdb repo      |     | validate candidate image   |
| image.yml            |<----| against existing allow-list|
| allowlist.yml        |     +-------------+--------------+
+----------+-----------+                   |
           |                               |
           | PR gate                       | if pass
           v                               v
+----------------------+        +-------------------------+
| run pinned image     |        | merge image bump        |
| with allow-list only |        +-------------------------+
+----------+-----------+
           |
           v
+----------------------+
| protect supported    |
| DocumentDB behavior  |
+----------------------+

Promotion path:
+----------------------+
| run broader/full     |
| upstream suite       |
+----------+-----------+
           |
           v
+----------------------+
| report visibility    |
| and promotion        |
| candidates           |
+----------+-----------+
           |
           v
+----------------------+
| allow-list promotion |
| PRs grow coverage    |
+----------------------+
```

---

### Output surface

Phase 1 should keep result delivery simple and visible:

```text
PR gate:
  GitHub Actions Check Run summary for pass/fail and key counts
  artifact for full JSON/JUnit/test details

Promotion report:
  workflow summary for high-level findings
  artifact for full result report
```

Dashboards, historical trend pages, and richer PR comments are useful later, but they are not required to start the framework.

---

## Implementation Tracking

### Implementation PRs

- [ ] PR #XXX: bootstrap script and initial `allowlist.yml`
- [ ] PR #XXX: pytest collection hook and `run-allowlist.sh`
- [ ] PR #XXX: PR gate workflow and summary formatter
- [ ] PR #XXX: scheduled or on-demand full-suite promotion report workflow
- [ ] PR #XXX: image freshness automation (Phase 2)

### Status updates

- [ ] Add status updates when implementation begins.

### Open questions

- [ ] Decide the Phase 1 cadence for full-suite promotion reports.
- [ ] Decide whether Phase 1 needs a sequential path for allow-listed `no_parallel` tests.

---

## Phase 2 and future hardening plan

The following concerns are real, but they should not block Phase 1. They are captured here so the design has a path to scale after the basic gate is working.

| Concern | Plan |
|---------|------|
| Manual promotion does not scale | Add CLI/tooling to generate promotion patches from promotion reports. |
| Allow-list file becomes too large | Shard the allow-list by path prefix or derived area, such as `allowlist/find.yml` and `allowlist/aggregate.yml`. |
| Test IDs are brittle | Add stale-ID detection and suggest likely replacements when image bumps rename, move, or rewrite parameterized test IDs. |
| Parameterized test IDs are verbose | Keep full IDs as machine keys, but generate short display names in summaries. |
| `no_parallel` tests need PR-gate coverage | Add a separate sequential invocation for allow-listed `no_parallel` tests. |
| Derived area mapping is inaccurate | Keep area inference in tooling and improve path/marker mapping over time; unknown area should not block the gate. |
| Flaky tests enter the gate | Keep promotion manual in Phase 1; later add flake history. |
| Emergency gate override is needed | Define an audited maintainer override workflow if the gate blocks urgent work. |
| PR gate gets slow | Track runtime; later split required smoke, required functional, and scheduled suites. |
| Image bump toil grows | Improve image bump diagnostics and reuse recent full-suite result history. |
| Contributors need easier editing | Add validation, sorting, deduplication, and insertion commands. |

---

## Benefits

| Benefit | Description |
|---------|-------------|
| Simple PR UX | Normal contributors only need to know whether allowed tests passed. |
| Stable gates | The pinned image prevents upstream changes from breaking unrelated PRs. |
| Black-box respect | DocumentDB consumes upstream tests without redefining or rejecting them. |
| Regression signal | Allowed tests represent supported behavior and make support-boundary changes visible in PRs. |
| Controlled coverage growth | Promotion reports show candidates without blocking normal PRs. |
| Reproducibility | Every PR gate records the exact upstream image used. |
| Actionable failures | Failed PR gates explain likely cause, next action, and whether the failure also happens on `main`. |
| Local reproduction | Failed PR gates provide copy-paste commands for reproducing the full gate or one failed test. |
| Freshness automation | Scheduled jobs keep image adoption visible and prevent the pinned image from silently getting stale. |
| Lower triage burden | DocumentDB does not need to classify every upstream failure before using the framework. |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Allow-list becomes too small and coverage stalls | Track promotion-candidate metrics and manually promote selected passing tests. |
| Green PR gate is mistaken for full compatibility | PR summaries show allow-listed count, total upstream count, and outside allow-list count. |
| Contributors cannot understand failures | CI summaries include failure category, causality check, recommended action, and reproduction command. |
| Config errors have unclear fix paths | Split allow-list and image errors into clear subtypes. |
| Area reporting is inaccurate | Derive area from path/markers and report `unknown` when inference is unclear. |
| Upstream renames tests | Treat missing allow-listed tests as config errors and require replacement review. |
| Pinned image gets stale | Run scheduled image freshness checks, open/update image bump PRs, and report upstream commits behind. |
| Single full-suite pass is flaky | Keep promotion manual instead of automatically promoting from one pass. |
| Local reproduction differs from CI | Reproduction commands must print the image digest, selected tests, connection target, and result artifacts. |
| PR gate becomes slow as allow-list grows | Split future allow-lists into required smoke, required functional, and scheduled broader suites if needed. |
| Upstream image changes existing allowed test behavior | Candidate image validation catches this before the image becomes the PR gate image. |

---

## Success Criteria

1. Normal DocumentDB PRs run a pinned upstream image with only allow-listed tests.
2. `allowlist.yml` is the source of truth and validates schema plus duplicate IDs.
3. PR summaries clearly show selected, passed, failed, missing, and outside allow-list counts.
4. Image bumps are reviewable and prove the existing allow-list still passes.
5. Failed PR gate summaries show failure category, likely causality, recommended action, and local reproduction command.
6. Phase 1 promotion-candidate full-suite reports show allow-listed failures and outside allow-list passing tests.
7. Phase 1 manual promotion PRs can grow the allow-list without surprising unrelated PRs.
8. Phase 2 image freshness automation opens or updates image bump PRs and blocked-adoption reports.
9. The design treats `functional-tests` as a shared black-box suite for many document databases, not as the core `documentdb` repo's compatibility inventory.
