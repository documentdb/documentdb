# DocumentDB functional tests

Runs the upstream `documentdb/functional-tests` wire-protocol suite against
DocumentDB under the **known-failures xfail model** — the same framework both CI
systems use (the ADO functional pipeline and `.github/workflows/functional_tests.yml`).

There is **no allowlist**. The full suite runs under
`tools/conftest_known_failures.py`, which marks a per-gateway **failing** list as
`xfail(strict=True)` and a **flaky** list as `xfail(strict=False)`. The gate
fails on any residual `failed`/`error` — a real regression, or an `XPASS(strict)`
where a listed expected-failure now passes (the baseline must then be updated).
A third list, `config/ci_crash_tests.txt`, holds **engine-crasher** tests,
applied as `skip` (never executed): an xfailed crasher would still run, crash
the backend, and cascade connection errors onto every concurrent test. Unlike
the failing/flaky pair it is engine-level, not per-gateway — one list serves
every lane — and it also accepts file (`.py`) and directory (`/`) prefix
entries so it survives suite pin bumps.

## Layout

```
config/    Pinned upstream image + source_sha (image.yml); the OSS gateway's
           failing/flaky pair (oss_ci_failing_tests.txt, oss_ci_flaky_tests.txt),
           the engine-level crash skip list (ci_crash_tests.txt), and pytest
           args (oss_pytest.args).
tools/     conftest_known_failures.py (the xfail plugin) and functional_gate.py
           (report-failures / merge-reports / reconcile / split-collection /
           recover-and-gate / verify-split-universes / compare-engines).
scripts/   run-functional-tests.sh — local runner;
           run_pytest_split.sh — one CI matrix leg (slice + gate), used by
           .github/workflows/functional_tests.yml.
tests/     Unit tests for functional_gate.py + the split runner's guard tests
           (test_run_pytest_split.sh).
```

The suite version is pinned by `source_sha` in `config/image.yml`. Each gateway
maintains its own failing/flaky pair; the OSS pair here is calibrated for the
documentdb-local (OSS gateway) environment.

## The CI gate: full suite, split across matrix legs

The pinned suite is ~50k tests — too large for one CI job — so
`.github/workflows/functional_tests.yml` splits it ("split" = test splitting
across CI jobs, nothing to do with sharded collections):

- **Parallel legs** (`p0`..`pN`): each collects the non-`no_parallel` universe,
  runs its deterministic stride slice (`ids[SPLIT_ID::SPLIT_TOTAL]` of the
  sorted universe) with `-n auto`, then recovers transient crash-cascade
  victims by re-running the still-failing set serially and gates on the merged
  report (`functional_gate.py recover-and-gate`). `--expected-ids` makes green
  require a recorded outcome for every assigned test — lost xdist workers
  cannot silently drop coverage.
- **`no_parallel` leg** (`np`): every `no_parallel` test, serially
  (`-p no:xdist`), same recovery + gate.
- **`verify-splits` job**: asserts every parallel leg collected an IDENTICAL
  universe (each leg publishes a `universe.txt` fingerprint). Without this, a
  leg whose collection silently omitted a node would shift its stride and part
  of the suite would run on no leg while every leg scored green.

Each leg fails CLOSED on: a collection error (pytest exit ≠ 0/5), a
suspiciously small universe (`MIN_MANIFEST`), an empty slice, a missing
`report.json`, or fewer than half the assigned tests recording an outcome.

## Run locally

Bring up an engine and run the gate in one command:

```bash
./documentdb-local/functional-tests/scripts/run-functional-tests.sh gate --build-and-start-documentdb
```

Or against an already-running engine (set `CONNECTION_STRING` or `--connection-string`):

```bash
./documentdb-local/functional-tests/scripts/run-functional-tests.sh gate
```

Modes: `gate` (full suite under the xfail model — the CI gate), `single`
(one node ID), `smoke`, `full` (raw results, no gate). `--help` lists all options.

## Triage a gate failure

The gate prints the residual failures (`gate-failures.txt`). Each is either:

- **failed/error** — a real regression (or a new upstream test the engine
  doesn't pass yet): fix the engine, or add the node ID to the failing list.
- **XPASS(strict)** — a listed expected-failure now passes: remove it from the
  failing list (the baseline improved).

## Update the baseline (source_sha bump or after a fix)

Fold a gate run's merged `report.json` back into the pair mechanically. A CI
run publishes one report per leg (`functional-test-results-<tag>` artifacts);
combine them first so the reconcile sees the full suite:

```bash
# Combine the per-leg reports (p0..pN + np) into one full-suite report.
cp p0/report.json combined.json
for leg in p1 p2 p3 p4 p5 np; do
  python3 documentdb-local/functional-tests/tools/functional_gate.py merge-reports \
    --base combined.json --overlay "$leg/report.json" --out combined.json
done

python3 documentdb-local/functional-tests/tools/functional_gate.py reconcile \
  --report combined.json \
  --failing config/oss_ci_failing_tests.txt \
  --flaky   config/oss_ci_flaky_tests.txt \
  --prune-uncollected
```

(`--prune-uncollected` is only valid on a full-suite report — never reconcile a
single leg's report with it, or every other leg's entries would be pruned.)

`reconcile` adds new failures, drops `XPASS(strict)` entries, prunes deleted
tests, preserves comments/prefix style, and flags anything needing a human
(listed tests that *errored*, failures already on the flaky list). Re-run the
gate afterward — strict xfail proves the list is exactly right (an over- or
under-edited list cannot pass).
