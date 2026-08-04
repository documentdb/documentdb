#!/bin/bash
# Split DocDB functional-test runner + known-failures gate for one matrix leg —
# OSS-gateway lane (the GitHub Actions gate in .github/workflows/functional_tests.yml).
#
# This is the OSS twin of the internal backend gate's split runner
# (scripts/docdb_tests/run_pytest_split.sh in the pgmongo repo). The mechanism —
# collection guards, universe records, stride slices, floors, limits, timeout
# methods, recover-and-gate — is kept IDENTICAL; only the lane-specific inputs
# differ (this lane's failing/flaky pair, oss_pytest.args, GitHub ::error::
# annotations instead of ADO ##vso). When the backend runner's mechanism
# changes, port the change here in the same PR.
#
# "Split" here means TEST SPLITTING — dividing the pytest suite across parallel
# CI jobs. It has nothing to do with DocumentDB/Mongo sharded (hash-partitioned)
# collections; no naming in this file refers to data sharding.
#
# The suite is too large to finish inside the job cap on a single runner, so it
# is split across matrix legs:
#   SPLIT_MODE=parallel  : one interleaved slice of the non-no_parallel suite,
#                          run with -n auto. SPLIT_ID/SPLIT_TOTAL pick the slice
#                          via functional_gate.py split-collection.
#   SPLIT_MODE=noparallel: the dedicated leg that runs every no_parallel test
#                          serially (-p no:xdist -m no_parallel).
#
# After the main pass each leg does the same crash-cascade recovery: the -n auto
# pass is stochastic — an engine crash restarts the cluster and a batch of
# concurrent tests cascade with connection errors. report-failures picks the
# still-failing set, it is re-run sequentially (-n=0, no contention -> transient
# victims pass), and the outcome is merged. The GATE is report-failures on the
# MERGED report: any residual failed/error (real regression or XPASS(strict))
# fails the leg -> workflow -> gate.
#
# Required env: SPLIT_MODE SPLIT_ID SPLIT_TOTAL SPLIT_TAG RESULTS_DIR TMPDIR
#               CONN_USER CONN_PASS CONN_PORT
# Optional env: SPLIT_TESTPATH (override test root; local testing)
#               ENGINE_NAME (default documentdb)
#               CRASH_LIST  (crash/skip list, relative to config/; default
#                            github_ci_crash_tests.txt — the engine-level set.
#                            ci_crash_tests.txt is the ADO mirror and adds that
#                            environment's index-build-convoy sections.)
# CWD must be the repository root (the tree that holds documentdb-local/ and
# docdb_functional_tests/).
set -uo pipefail

err() {  # GitHub error annotation + plain stderr line (twin of ADO's ##vso).
  echo "::error::$1"
  echo "ERROR: $1" >&2
}

REPO="$(pwd)"
FT="${REPO}/documentdb-local/functional-tests"
PFX="docdb_functional_tests/documentdb_tests/"
ROOTDIR="docdb_functional_tests/documentdb_tests"
TESTPATH="${SPLIT_TESTPATH:-${PFX}compatibility/tests}"
ENGINE="${ENGINE_NAME:-documentdb}"
CS="mongodb://${CONN_USER}:${CONN_PASS}@localhost:${CONN_PORT}/?tls=true&tlsAllowInvalidCertificates=true"
GATE="python3 ${FT}/tools/functional_gate.py"
REPORT="${RESULTS_DIR}/report.json"
JUNIT="${RESULTS_DIR}/results.xml"

mkdir -p "${RESULTS_DIR}"

# Assemble the plugin + this lane's lists under the canonical names the plugin
# reads from its own directory (the backend gate keeps them pre-assembled in
# scripts/docdb_tests/; this lane's pair carries the oss_ prefix, so stage a
# kf dir per leg).
#
# CRASH_LIST defaults to the ENGINE-LEVEL skip set. The ADO mirror
# (ci_crash_tests.txt) additionally skips that environment's index-build-convoy
# families; those 2,564 tests run clean here (measured, run 30667428483: zero
# tests over 60s, no worker deaths, ~1-2 min added per leg), so skipping them on
# this runner would drop real coverage for a problem this environment does not
# have. Point CRASH_LIST at ci_crash_tests.txt to reproduce the ADO lane exactly.
KF="${TMPDIR}/kf-oss-${SPLIT_TAG}"
mkdir -p "${KF}"
cp "${FT}/tools/conftest_known_failures.py" "${KF}/conftest_known_failures.py"
cp "${FT}/config/oss_ci_failing_tests.txt"  "${KF}/ci_failing_tests.txt"
cp "${FT}/config/oss_ci_flaky_tests.txt"    "${KF}/ci_flaky_tests.txt"
cp "${FT}/config/${CRASH_LIST:-github_ci_crash_tests.txt}" "${KF}/ci_crash_tests.txt"
echo "crash/skip list: ${CRASH_LIST:-github_ci_crash_tests.txt} ($(grep -cv '^#\|^$' "${KF}/ci_crash_tests.txt" || echo 0) entries)"
export PYTHONPATH="${KF}:${PYTHONPATH:-}"
export PYTEST_ADDOPTS="-p conftest_known_failures"

# json-report drives report-failures/merge; pytest-timeout bounds the serial re-run
# (--timeout=600 --timeout-method=signal below). Install if the runner lacks them
# (no-op if already present).
#
# --timeout-method=signal matters: the gate's re-run sessions report
# `timeout method: thread` (selected upstream of this script, by the pinned
# suite's pytest config -- pytest-timeout itself defaults to signal wherever
# SIGALRM exists). The thread method dumps stacks and kills the interpreter
# outright, so json-report writes nothing and recover-and-gate loses the WHOLE
# batch's recovery to one hanging test. The re-run is always -n=0, i.e. tests
# run on the main thread, which is where SIGALRM is deliverable, so the signal
# method is available there and makes a hang fail just that test while the
# session finishes and still writes its report. functional_gate.py falls back
# to one process per test if a report is still lost.
python3 -m pip install --user --quiet pytest-json-report pytest-timeout 2>/dev/null || true

# Fail CLOSED with a named error if a known-failure list is not valid UTF-8: the
# conftest_known_failures hook reads them during collection, and a stray non-UTF-8
# byte (e.g. a CP1252 em-dash from a Windows edit) raises UnicodeDecodeError -> an
# opaque INTERNALERROR with 0 tests run.
for L in "${KF}/ci_failing_tests.txt" "${KF}/ci_flaky_tests.txt" "${KF}/ci_crash_tests.txt"; do
  if ! python3 -c "import sys; open(sys.argv[1], encoding='utf-8').read()" "$L" 2>/dev/null; then
    err "$L is not valid UTF-8 — re-author it as UTF-8/ASCII (a bad byte crashes conftest collection)."; exit 1
  fi
done

# --ignore flags are the single source of truth in oss_pytest.args
IGN=$(grep -- '--ignore=' "${FT}/config/oss_pytest.args" | tr '\n' ' ')

run_pytest() {  # $1 = json report path ; rest = parallelism + markers + targets
  local jsonout="$1"; shift
  # shellcheck disable=SC2086
  python3 -m pytest -p conftest_known_failures -q --color=no ${IGN} \
    --engine-name="${ENGINE}" --connection-string="${CS}" --rootdir="${ROOTDIR}" \
    --json-report --json-report-file="${jsonout}" "$@"
}

# A collection that silently under-collects (transient engine hiccup, or a marker
# renamed/removed by a source_sha bump) must RED the leg, never score green. Both
# modes derive an EXPECTED count and the main-pass floor is applied UNCONDITIONALLY.
# MIN_MANIFEST guards the parallel collect against a partial/skewed universe; a
# short manifest on one leg desyncs its ids[split_id::total] stride from the
# others and drops tests at some positions on no leg.
# The non-no_parallel suite is ~48k; bump MIN_MANIFEST if a source_sha update
# legitimately shrinks it.
MIN_MANIFEST=30000
COLLECT_RC=0
COLLECT_N=0
collect_count() {  # $1 = out manifest ; rest = -m marker + targets.
  # Returns NOTHING on stdout; publishes COLLECT_RC (pytest's exit code) and
  # COLLECT_N (the node-ID count) as globals.
  #
  # MUST be called directly -- never as `X=$(collect_count ...)`. Command
  # substitution forks a SUBSHELL, so the globals set here would die with it and
  # the caller would keep reading the initialized values. That is precisely how
  # the collect-error guard below once got silently disabled: it compared a
  # COLLECT_RC that was always 0. tests/test_run_pytest_split.sh T1 pins this.
  local out="$1"; shift
  # -o addopts= neutralizes pytest.ini's -vv so --collect-only -q emits flat node IDs.
  # pytest writes BOTH the node IDs and (on failure) its ERRORS section to STDOUT;
  # stderr is captured separately for a hard crash.
  # shellcheck disable=SC2086
  python3 -m pytest --collect-only -q -o addopts="" ${IGN} \
    --engine-name="${ENGINE}" --connection-string="${CS}" --rootdir="${ROOTDIR}" "$@" \
    > "${out}" 2>"${out}.err"
  COLLECT_RC=$?
  # `|| true`, NOT `|| echo 0`: grep -c already prints 0 when nothing matches (and
  # exits 1), so `|| echo 0` produced "0\n0" — which made the numeric guards die
  # with "integer expression expected" and SKIP the zero-collection check.
  COLLECT_N=$(grep -c '::' "${out}" 2>/dev/null || true)
  COLLECT_N=${COLLECT_N:-0}
}

dump_collect_diag() {  # $1 = manifest. pytest's ERRORS section lands on STDOUT, so
  # the manifest (not .err, which is empty in the import-error case) carries the
  # diagnosis — and it is at the END of the file, hence tail.
  echo "--- collect stdout, last 40 lines (pytest's ERRORS section lands here) ---"
  tail -n 40 "$1" 2>/dev/null
  echo "--- collect stderr, last 20 lines ---"
  tail -n 20 "$1.err" 2>/dev/null
}

guard_collection() {  # $1 = manifest. Reds the leg on an incomplete collection.
  # pytest exit codes: 0 = ok, 5 = "no tests collected" (the count guards below own
  # that case and print a better message). Anything else — notably 2, e.g. an
  # ImportError in ONE test module — means the universe is INCOMPLETE: pytest still
  # lists every healthy module's IDs and exits non-zero, so the broken module's
  # tests would silently vanish from every leg's slice while the counts still look
  # plausible (one module is far below the MIN_MANIFEST margin). Never gate on that.
  if [ "${COLLECT_RC}" -ne 0 ] && [ "${COLLECT_RC}" -ne 5 ]; then
    err "pytest collection exited ${COLLECT_RC} — the collected universe is incomplete (import/collection error); those tests would be dropped from every leg. Refusing to gate."
    dump_collect_diag "$1"; exit 1
  fi
}

universe_hash() {  # $1 = manifest. Stable fingerprint of the collected universe.
  # Node-ID lines ONLY: the trailing "N tests collected in X.XXs" summary carries
  # timing and would differ on every leg, defeating the comparison. Equal hashes
  # across the parallel legs prove they sliced the SAME universe (the no_parallel
  # leg collects a different marker set by design, so its hash differs).
  local h
  h=$(grep '::' "$1" 2>/dev/null | sort -u | sha256sum 2>/dev/null | cut -c1-16) || h=""
  printf '%s' "${h:-unavailable}"
}

write_universe_record() {  # $1 = universe hash, $2 = collected count.
  # Published with this leg's results artifact and consumed by the verify job
  # (functional_gate.py verify-split-universes), which fails the workflow unless
  # every parallel leg reports the SAME hash. Written before the main pass so it
  # exists even if the run itself dies.
  local mode="parallel"
  [ "${SPLIT_MODE}" = "noparallel" ] && mode="noparallel"
  printf '%s %s %s %s\n' "${SPLIT_TAG}" "${mode}" "$1" "$2" \
    > "${RESULTS_DIR}/universe.txt"
  echo "wrote universe record: ${SPLIT_TAG} ${mode} $1 $2"
}

ASSIGNED=0
if [ "${SPLIT_MODE}" = "noparallel" ]; then
  echo "=== no_parallel leg: serial run of all no_parallel tests ==="
  MAN="${TMPDIR}/pytest_manifest_np.txt"
  # Direct call (NOT `$(...)`) so COLLECT_RC/COLLECT_N survive into this shell.
  collect_count "${MAN}" -m no_parallel "${TESTPATH}"
  guard_collection "${MAN}"
  EXPECTED=${COLLECT_N}
  echo "no_parallel leg: ${EXPECTED} no_parallel tests collected"
  UH=$(universe_hash "${MAN}")
  echo "universe-hash: ${UH}"
  write_universe_record "${UH}" "${EXPECTED}"
  if [ "${EXPECTED}" -eq 0 ]; then
    err "no_parallel leg collected 0 tests — the no_parallel marker/tests may be gone. Refusing to score green."
    dump_collect_diag "${MAN}"; exit 1
  fi
  # This leg is already serial (-p no:xdist), so there is no worker contention to
  # cascade; a genuine breakage must fail fast rather than be re-run 3x.
  TRANSIENT_LIMIT=50
  # Serial leg has no xdist workers to die, so unrecorded tests mean the session
  # itself collapsed — keep the recovery window small.
  MISSING_LIMIT=200
  # The manifest doubles as the assigned set (recover-and-gate ignores the
  # trailing "N tests collected" noise lines).
  EXPECTED_IDS="${MAN}"
  # -o addopts= so an xdist flag added to pytest.ini can't reach the -p no:xdist run.
  # --timeout bounds a hang to 15 min instead of the leg's job cap; this leg is
  # serial (main thread), so the signal method applies and a timeout fails only
  # the hanging test while the session and its report survive.
  MAIN_ARGS=(-o addopts="" -p no:xdist --timeout=900 --timeout-method=signal \
             -m no_parallel "${TESTPATH}")
else
  echo "=== parallel split ${SPLIT_ID}/${SPLIT_TOTAL}: collect -> slice ==="
  MAN="${TMPDIR}/pytest_manifest_${SPLIT_ID}.txt"
  SL="${TMPDIR}/pytest_split_${SPLIT_ID}.txt"
  # Direct call (NOT `$(...)`) so COLLECT_RC/COLLECT_N survive into this shell.
  collect_count "${MAN}" -m "not no_parallel" "${TESTPATH}"
  guard_collection "${MAN}"
  COLLECTED=${COLLECT_N}
  # Logged per leg for humans AND written to universe.txt for the cross-leg
  # check: skew here desyncs the ids[split_id::total] stride and drops tests at
  # some positions on NO leg, which no per-leg guard can see. The verify job
  # (functional_gate.py verify-split-universes) turns that from detectable-in-
  # hindsight into a hard failure.
  UH=$(universe_hash "${MAN}")
  echo "universe-hash: ${UH} (${COLLECTED} ids)"
  write_universe_record "${UH}" "${COLLECTED}"
  # MIN_MANIFEST guards the full-suite gate run; skip it under a SPLIT_TESTPATH
  # override (local subset testing intentionally collects far fewer than the suite).
  if [ -z "${SPLIT_TESTPATH:-}" ] && [ "${COLLECTED}" -lt "${MIN_MANIFEST}" ]; then
    err "split ${SPLIT_ID} collected only ${COLLECTED} tests (< ${MIN_MANIFEST}) — a partial/skewed collection would silently drop coverage across the legs. Refusing to gate."
    dump_collect_diag "${MAN}"; exit 1
  fi
  ${GATE} split-collection --manifest "${MAN}" --num-splits "${SPLIT_TOTAL}" --split-id "${SPLIT_ID}" \
    --strip-prefix "${PFX}" --prefix "${PFX}" --output "${SL}"
  ASSIGNED=$(grep -c '::' "${SL}" || true); ASSIGNED=${ASSIGNED:-0}
  echo "split ${SPLIT_ID} assigned ${ASSIGNED} tests (of ${COLLECTED} collected)"
  if [ "${ASSIGNED}" -eq 0 ]; then
    err "split ${SPLIT_ID} slice empty — test splitting failed?"; exit 1
  fi
  EXPECTED="${ASSIGNED}"
  # Per-LEG limit: the worst crash-cascade residual observed on the backend gate
  # was 14, so 100 keeps ample headroom for a cascade while making a real
  # breakage (which must NOT be masked by re-run recovery) fail fast.
  # Deliberately absolute, not scaled by SPLIT_TOTAL: a cascade costs ~1 in-flight
  # test per killed xdist worker (~16), which tracks core count, not split width.
  TRANSIENT_LIMIT=100
  # xdist worker deaths (OOM kills in the memory-heavy geospatial region) can
  # lose part of a dead worker's queue: those tests end the session with NO
  # recorded outcome — and without this guard the leg would score green.
  # recover-and-gate re-runs them serially from the slice file; above the limit
  # the loss is systemic.
  MISSING_LIMIT=1500
  EXPECTED_IDS="${SL}"
  # -m "not no_parallel" makes conftest Phase 2 a no-op here (dedicated leg owns no_parallel).
  #
  # --max-worker-restart=200: xdist's DEFAULT cap is numprocesses*4 (16 on a
  # 4-cpu runner), and hitting it triggershutdown()s the session, ABANDONING the
  # whole unexecuted tail (observed on the backend gate: ~1,200-1,700 of a leg's
  # ~12k assigned outcomes lost exactly this way; workers OOM-killed in the
  # memory-heavy geo/planCache/diagnostic region). With a high cap, xdist
  # replaces every dead worker and re-queues its pending tests, so the session
  # always completes; the errored in-flight tests are healed by the serial
  # recovery below and recover-and-gate's --expected-ids check still fails
  # closed if outcomes are lost some other way.
  #
  # --timeout=240 --timeout-method=thread bounds a main-pass hang: the thread
  # method kills the worker interpreter, which under a high restart cap is just
  # one more replaced worker + an errored test for serial recovery — vs the
  # whole leg burning to its job cap. signal-method is not deliverable on xdist
  # worker threads, so thread is correct HERE (the serial re-run uses signal).
  #
  # 240, not 900: when the engine's 2-executor index-build queue wedges (the
  # convoy — see the internal gate-stabilization notes), every waiting worker
  # burns the FULL timeout before its slot frees, so the timeout IS the
  # per-stall price. 240s caps a stall at ~5 min while still being far above
  # any healthy test (the suite's tests run in seconds). A convoy victim killed
  # at 240s is re-run serially by recover-and-gate, where the queue is idle and
  # it passes; a test that cannot finish in 600s even serially is genuinely
  # broken and must red the gate.
  MAIN_ARGS=(-n auto --max-worker-restart=200 --timeout=240 --timeout-method=thread \
             -m "not no_parallel" "@${SL}")
fi

# --- engine observer: 5s sampler of active/waiting backends and the background
#     index-build queue, published with the leg's artifact. Diagnostic only —
#     failures inside it are silenced so it can never affect the gate. The OSS
#     engine listens on the local 9712 coordinator port; peer auth as the
#     runner user. Wait events name what a wedged CreateIndexes waits on, and
#     queue rows carry per-build attempts/status. ---
OBSERVER_LOG="${RESULTS_DIR}/engine-observer.log"
if command -v psql >/dev/null 2>&1; then
  (
    while true; do
      date -u +%FT%TZ
      psql -p 9712 -d postgres -tA -F' | ' -c \
        "SELECT 'ACT', pid, state, wait_event_type, wait_event, left(regexp_replace(coalesce(query,''), E'[\n\r]+', ' ', 'g'),120) \
           FROM pg_stat_activity WHERE state <> 'idle' AND pid <> pg_backend_pid()" 2>&1
      # queue table name varies by stack (helio_index_queue / documentdb_index_queue);
      # discover it and dump raw rows, schema-agnostically.
      psql -p 9712 -d postgres -tA -c \
        "SELECT format('SELECT ''QUEUE'', * FROM %s LIMIT 8', n.nspname||'.'||c.relname) \
           FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace \
          WHERE c.relname LIKE '%index_queue' AND c.relkind='r' LIMIT 1" 2>/dev/null \
        | psql -p 9712 -d postgres -tA -F' | ' 2>&1 | head -8
      sleep 5
    done
  ) >> "${OBSERVER_LOG}" 2>&1 &
  OBSERVER_PID=$!
else
  echo "psql not found; engine observer disabled" > "${OBSERVER_LOG}"
  OBSERVER_PID=""
fi

# --- main pass. Native --junitxml is the reporting artifact; the GATE is the
#     recover-and-gate exit code below, so a recovered victim showing failed in
#     results.xml is informational. ---
run_pytest "${REPORT}" --junitxml="${JUNIT}" "${MAIN_ARGS[@]}" || true

# Stop the observer before exec below replaces this shell (its output is
# complete once the main pass ends; the serial recovery is single-threaded and
# not convoy-prone).
[ -n "${OBSERVER_PID}" ] && kill "${OBSERVER_PID}" 2>/dev/null || true

# --- fail CLOSED on a missing/partial run (never let a collapse score green) ---
if [ ! -f "${REPORT}" ]; then
  err "no report.json — suite did not run (engine down / collection error)."; exit 1
fi
RAN=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('tests',[])))" "${REPORT}" 2>/dev/null || echo 0)
echo "recorded outcomes in main pass: ${RAN} (expected ~${EXPECTED})"
# Unconditional floor — both parallel and no_parallel legs must run a real fraction.
FLOOR=$(( EXPECTED / 2 ))
if [ "${RAN}" -lt "${FLOOR}" ]; then
  err "only ${RAN} tests ran (< ${FLOOR} floor of ${EXPECTED}) — refusing to gate on a partial run."; exit 1
fi

# --- sequential re-run recovery + gate on the merged report ---
# functional_gate.py recover-and-gate is the single shared implementation: it
# re-runs the still-failing set serially (-n=0, no contention -> transient
# crash victims pass), merges each pass (bounded to 3; over the transient limit
# = real breakage), and exits 1 on any residual failed/error (real regression
# or XPASS(strict)). The re-run command mirrors the main pass minus the
# marker/targets; recover-and-gate appends --json-report and the @argfile of
# failing IDs. exec so the leg's exit status is recover-and-gate's verdict.
# --output goes straight into RESULTS_DIR (the upload-artifact path) so the
# residual list ships with the artifact; TMPDIR is never published. It cannot
# be a copy AFTER the gate: this exec replaces the shell, so nothing below it
# would ever run.
# shellcheck disable=SC2086
exec ${GATE} recover-and-gate \
  --report "${REPORT}" --strip-prefix "${PFX}" --prefix "${PFX}" \
  --transient-limit "${TRANSIENT_LIMIT}" \
  --expected-ids "${EXPECTED_IDS}" --missing-limit "${MISSING_LIMIT}" \
  --workdir "${TMPDIR}" --output "${RESULTS_DIR}/gate-failures.txt" \
  -- python3 -m pytest -p conftest_known_failures -q --color=no ${IGN} \
     --engine-name="${ENGINE}" --connection-string="${CS}" --rootdir="${ROOTDIR}" \
     -n=0 --timeout=600 --timeout-method=signal
