#!/bin/bash
# Smoke tests for scripts/run_pytest_split.sh's collection guards (OSS lane).
#
# Twin of the internal backend gate's harness (scripts/docdb_tests/
# test_run_pytest_split.sh in the pgmongo repo) — same tests, pointed at the
# OSS split runner. These exist because the guards are the part of the script
# that must FAIL CLOSED, and two of them were once silently disabled by
# pure-bash mistakes that no amount of reading caught:
#   * `grep -c ... || echo 0` emitted "0\n0", so the callers' `-eq 0` tests died
#     with "integer expression expected" and the zero-collection guard never ran.
#   * `X=$(collect_count ...)` ran the function in a command-substitution
#     SUBSHELL, so the collect exit code it stored in a global never reached the
#     parent and the collect-error guard always compared the initial 0.
# Both are invisible unless the script is actually executed, hence this file.
#
# `python3 -m pytest` is stubbed so the guards can be driven without an engine;
# everything else (functional_gate.py, python3 -c) runs for real.
#
# Usage (from the repository root, the tree that holds documentdb-local/):
#   bash documentdb-local/functional-tests/tests/test_run_pytest_split.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUT="${REPO}/documentdb-local/functional-tests/scripts/run_pytest_split.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
REAL_PYTHON3="$(command -v python3)"
export REAL_PYTHON3
FAILS=0

# --- python3 stub: fakes `-m pytest`, no-ops `-m pip`, delegates the rest ------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/python3" <<'STUB'
#!/bin/bash
is_pytest=0; is_pip=0
for a in "$@"; do
  [ "$a" = "pytest" ] && is_pytest=1
  [ "$a" = "pip" ] && is_pip=1
done
[ "$is_pip" = 1 ] && exit 0
if [ "$is_pytest" = 1 ]; then
  case " $* " in
    *" --collect-only "*)
      [ -n "${STUB_COLLECT_OUT:-}" ] && [ -f "${STUB_COLLECT_OUT}" ] && cat "${STUB_COLLECT_OUT}"
      exit "${STUB_COLLECT_RC:-0}" ;;
    *) exit 0 ;;   # main pass: these tests never get that far
  esac
fi
exec "${REAL_PYTHON3}" "$@"
STUB
chmod +x "${WORK}/bin/python3"
export PATH="${WORK}/bin:${PATH}"

# A manifest that looks exactly like a real partial collection: healthy node IDs
# listed, then pytest's ERRORS section on STDOUT.
cat > "${WORK}/partial.txt" <<'EOF'
compatibility/tests/a/test_a.py::test_one[documentdb]
compatibility/tests/a/test_a.py::test_two[documentdb]
compatibility/tests/b/test_b.py::test_three[documentdb]

=================================== ERRORS ====================================
_______________________ ERROR collecting test_broken.py _______________________
E   ModuleNotFoundError: No module named 'a_module_that_does_not_exist'
!!!!!!!!!!!!!!!!!!! Interrupted: 1 error during collection !!!!!!!!!!!!!!!!!!!!
3 tests collected, 1 error in 0.42s
EOF
: > "${WORK}/empty.txt"

run_sut() {  # $1=mode $2=collect-rc $3=stub manifest ; echoes output, sets SUT_RC
  # Also publishes SUT_RESULTS (this run's RESULTS_DIR) so a test can assert on
  # the artifacts the leg leaves behind, e.g. universe.txt.
  local mode="$1" rc="$2" man="$3"
  local rd="${WORK}/results.$$.${RANDOM}" td="${WORK}/tmp.$$.${RANDOM}"
  mkdir -p "$rd" "$td"
  SUT_RESULTS="$rd"
  SUT_OUT=$(cd "${REPO}" && \
    SPLIT_MODE="$mode" SPLIT_ID=0 SPLIT_TOTAL=4 SPLIT_TAG=t \
    RESULTS_DIR="$rd" TMPDIR="$td" \
    CONN_USER=u CONN_PASS=p CONN_PORT=1 \
    SPLIT_TESTPATH="compatibility/tests" \
    STUB_COLLECT_RC="$rc" STUB_COLLECT_OUT="$man" \
    bash "${SUT}" 2>&1)
  SUT_RC=$?
}

ok(){ echo "  PASS $1"; }
no(){ echo "  FAIL $1"; FAILS=$((FAILS+1)); }
has(){ echo "${SUT_OUT}" | grep -q "$1"; }

echo "T1: a collect error (rc=2) must RED the leg, naming the collection failure"
echo "    [regression: the guard was dead because collect_count ran in a \$( ) subshell]"
run_sut parallel 2 "${WORK}/partial.txt"
[ "${SUT_RC}" -ne 0 ] && ok "exits non-zero (got ${SUT_RC})" || no "exits non-zero (got ${SUT_RC})"
has "collection exited 2" && ok "names the collect exit code" \
  || no "names the collect exit code -- guard did not fire; the partial universe was accepted"
has "ModuleNotFoundError" && ok "surfaces the real cause from stdout" \
  || no "surfaces the real cause from stdout"

echo "T2: rc=0 but an EMPTY collection must RED the leg"
echo "    [regression: 'grep -c || echo 0' emitted \"0\\n0\" and broke this guard]"
run_sut noparallel 0 "${WORK}/empty.txt"
[ "${SUT_RC}" -ne 0 ] && ok "exits non-zero (got ${SUT_RC})" || no "exits non-zero (got ${SUT_RC})"
has "collected 0 tests" && ok "names the empty collection" || no "names the empty collection"

echo "T3: rc=5 ('no tests collected') defers to the count guards, not the rc guard"
run_sut parallel 5 "${WORK}/empty.txt"
[ "${SUT_RC}" -ne 0 ] && ok "still reds (empty universe)" || no "still reds (empty universe)"
has "collection exited 5" && no "must NOT report rc=5 as a collect error" \
  || ok "rc=5 left to the count guards"

echo "T4: a healthy collection (rc=0, ids present) passes the collection guards"
run_sut parallel 0 "${WORK}/partial.txt"
has "collection exited" && no "no false collect-error on a clean collect" \
  || ok "no false collect-error on a clean collect"
has "universe-hash:" && ok "logs the universe hash" || no "logs the universe hash"

echo "T5: the leg writes universe.txt for the cross-leg skew check"
# The verify job (functional_gate.py verify-split-universes) can only fail a
# skewed run if every leg actually leaves this record behind, so pin the shape.
UF="${SUT_RESULTS}/universe.txt"
if [ -f "${UF}" ]; then
  ok "writes universe.txt"
  REC=$(cat "${UF}")
  set -- ${REC}
  [ "$#" -eq 4 ] && ok "record has 4 fields (got: ${REC})" \
    || no "record has 4 fields (got: ${REC})"
  [ "$1" = "t" ] && ok "field 1 is the split tag" || no "field 1 is the split tag (got $1)"
  [ "$2" = "parallel" ] && ok "field 2 is the mode" || no "field 2 is the mode (got $2)"
  [ -n "$3" ] && [ "$3" != "unavailable" ] && ok "field 3 is a real hash" \
    || no "field 3 is a real hash (got $3)"
  case "$4" in (*[!0-9]*|"") no "field 4 is numeric (got $4)";; (*) ok "field 4 is numeric";; esac
else
  no "writes universe.txt"
fi

echo "T6: the no_parallel leg records mode=noparallel (its hash differs by design)"
run_sut noparallel 0 "${WORK}/partial.txt"
if [ -f "${SUT_RESULTS}/universe.txt" ]; then
  set -- $(cat "${SUT_RESULTS}/universe.txt")
  [ "$2" = "noparallel" ] && ok "no_parallel leg tagged noparallel" \
    || no "no_parallel leg tagged noparallel (got $2)"
else
  no "no_parallel leg writes universe.txt"
fi

echo
if [ "${FAILS}" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES: ${FAILS}"; fi
exit "${FAILS}"
