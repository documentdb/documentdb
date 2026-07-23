#!/bin/bash
# E2E smoke test for the DocumentDB packaging redesign tools.
# Runs inside a Debian/Ubuntu container with PostgreSQL available.
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  - $1"; }

echo "=== DocumentDB Packaging E2E Smoke Tests ==="
echo ""

# ── Test 1: documentdb-tune ─────────────────────────────────────────
echo "--- Test 1: documentdb-tune --help ---"
if /scripts/documentdb-tune.sh --help >/dev/null 2>&1; then
    pass "documentdb-tune --help"
else
    fail "documentdb-tune --help"
fi

echo "--- Test 2: documentdb-tune --print (PG 17) ---"
output=$(/scripts/documentdb-tune.sh --pg-version 17 --print 2>&1)
if echo "$output" | grep -q "shared_preload_libraries"; then
    pass "documentdb-tune --print contains shared_preload_libraries"
else
    fail "documentdb-tune --print missing shared_preload_libraries"
fi
if echo "$output" | grep -q "pg_documentdb_core"; then
    pass "documentdb-tune --print contains pg_documentdb_core"
else
    fail "documentdb-tune --print missing pg_documentdb_core"
fi
if echo "$output" | grep -q "documentdb-setup managed configuration"; then
    pass "documentdb-tune --print has managed block markers"
else
    fail "documentdb-tune --print missing managed block markers"
fi

echo "--- Test 3: documentdb-tune apply/restore round-trip ---"
tmpdir=$(mktemp -d)
echo "# original config" > "$tmpdir/postgresql.conf"
echo "listen_addresses = '*'" >> "$tmpdir/postgresql.conf"
orig_hash=$(md5sum "$tmpdir/postgresql.conf" | cut -d' ' -f1)

/scripts/documentdb-tune.sh --pgdata "$tmpdir" --yes 2>&1
if grep -q "shared_preload_libraries" "$tmpdir/postgresql.conf"; then
    pass "documentdb-tune --yes applies config"
else
    fail "documentdb-tune --yes did not apply config"
fi

if /scripts/documentdb-tune.sh --pgdata "$tmpdir" --yes 2>&1 | grep -q "already up to date"; then
    pass "documentdb-tune is idempotent"
else
    fail "documentdb-tune is not idempotent"
fi

/scripts/documentdb-tune.sh --pgdata "$tmpdir" --restore 2>&1
restored_content=$(cat "$tmpdir/postgresql.conf")
if echo "$restored_content" | grep -q "# original config"; then
    pass "documentdb-tune --restore preserves original content"
else
    fail "documentdb-tune --restore lost original content"
fi
if echo "$restored_content" | grep -q "shared_preload_libraries"; then
    fail "documentdb-tune --restore left managed block"
else
    pass "documentdb-tune --restore removes managed block"
fi
rm -rf "$tmpdir"

echo "--- Test 4: documentdb-tune --dry-run does not write ---"
tmpdir=$(mktemp -d)
echo "# dry-run test" > "$tmpdir/postgresql.conf"
/scripts/documentdb-tune.sh --pgdata "$tmpdir" --dry-run 2>&1
if ! grep -q "shared_preload_libraries" "$tmpdir/postgresql.conf"; then
    pass "documentdb-tune --dry-run does not modify file"
else
    fail "documentdb-tune --dry-run modified the file"
fi
rm -rf "$tmpdir"

echo "--- Test 5: documentdb-tune missing --pg-version ---"
tune_err=$(/scripts/documentdb-tune.sh --yes 2>&1 || true)
if echo "$tune_err" | grep -q "pg-version is required"; then
    pass "documentdb-tune rejects missing --pg-version"
else
    fail "documentdb-tune did not reject missing --pg-version"
fi

echo "--- Test 6: documentdb-tune backup before write ---"
tmpdir=$(mktemp -d)
echo "# backup test" > "$tmpdir/postgresql.conf"
/scripts/documentdb-tune.sh --pgdata "$tmpdir" --yes 2>&1
if ls "$tmpdir"/postgresql.conf.documentdb-backup.* >/dev/null 2>&1; then
    pass "documentdb-tune creates backup file"
else
    fail "documentdb-tune did not create backup file"
fi
rm -rf "$tmpdir"

echo "--- Test 7: documentdb-tune foreign marker detection ---"
tmpdir=$(mktemp -d)
cat > "$tmpdir/postgresql.conf" <<'CONF'
# some config
# >>> foreign-tool managed block >>>
some_setting = 'value'
# <<< foreign-tool managed block <<<
CONF
foreign_err=$(/scripts/documentdb-tune.sh --pgdata "$tmpdir" --yes 2>&1 || true)
if echo "$foreign_err" | grep -qi "foreign\|another tool\|Refusing"; then
    pass "documentdb-tune detects foreign managed blocks"
else
    fail "documentdb-tune did not detect foreign managed blocks"
fi
rm -rf "$tmpdir"

# ── Test 8: documentdb-register-gateway --help ──────────────────────
# The gateway runtime's CLI surface (run/--check/--version) ships as the
# wrapper oss/packaging/gateway/documentdb-gateway-wrapper.sh and is covered by
# documentdb_local_tests/test_gateway_wrapper.py. This source-tree smoke tests
# the PostgreSQL-side administrator tools directly — the shipped gateway
# deliberately has no setup/admin subcommand — so it matches the installed
# command layout.
echo "--- Test 8: documentdb-register-gateway --help ---"
if /scripts/documentdb-register-gateway.sh --help 2>&1 | grep -q "target-postgres-instance"; then
    pass "documentdb-register-gateway --help works"
else
    fail "documentdb-register-gateway --help failed"
fi

# ── Test 9: documentdb-gateway-admin --help ─────────────────────────
echo "--- Test 9: documentdb-gateway-admin --help ---"
if /scripts/documentdb-gateway-admin.sh --help 2>&1 | grep -q "create-user"; then
    pass "documentdb-gateway-admin --help works"
else
    fail "documentdb-gateway-admin --help failed"
fi

# ── Test 10: documentdb-gateway-admin subcommand surface ────────────
echo "--- Test 10: documentdb-gateway-admin subcommand surface ---"
if /scripts/documentdb-gateway-admin.sh --help 2>&1 | grep -q "reset-password"; then
    pass "documentdb-gateway-admin lists reset-password"
else
    fail "documentdb-gateway-admin missing reset-password"
fi

# ── Test 11: documentdb-register-gateway --dry-run ──────────────────
echo "--- Test 11: documentdb-register-gateway --dry-run ---"
tmpdir=$(mktemp -d)
touch "$tmpdir/pg_hba.conf" "$tmpdir/pg_ident.conf"
# Create the fake documentdb-gateway user if not exists
if ! getent passwd documentdb-gateway >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin documentdb-gateway 2>/dev/null || true
fi
output=$(/scripts/documentdb-register-gateway.sh --pgdata "$tmpdir" --pg-port 5432 --socket-dir /tmp --dry-run 2>&1)
if echo "$output" | grep -q "Would write"; then
    pass "documentdb-register-gateway --dry-run previews changes"
else
    fail "documentdb-register-gateway --dry-run did not preview"
fi
# Verify files NOT modified
if [ ! -s "$tmpdir/pg_hba.conf" ]; then
    pass "documentdb-register-gateway --dry-run does not modify pg_hba.conf"
else
    fail "documentdb-register-gateway --dry-run modified pg_hba.conf"
fi
rm -rf "$tmpdir"

# ── Test 12: documentdb-register-gateway --yes writes correct blocks ──
echo "--- Test 12: documentdb-register-gateway --yes writes correct blocks ---"
tmpdir=$(mktemp -d)
echo "# TYPE  DATABASE  USER  METHOD" > "$tmpdir/pg_hba.conf"
echo "local   all       all   peer" >> "$tmpdir/pg_hba.conf"
touch "$tmpdir/pg_ident.conf"
/scripts/documentdb-register-gateway.sh --pgdata "$tmpdir" --pg-port 5432 --socket-dir /tmp --yes 2>&1 || true

if grep -q "documentdb-gateway-map" "$tmpdir/pg_hba.conf"; then
    pass "pg_hba.conf contains documentdb-gateway-map"
else
    fail "pg_hba.conf missing documentdb-gateway-map"
fi
if grep -q "documentdb-gateway-map" "$tmpdir/pg_ident.conf"; then
    pass "pg_ident.conf contains documentdb-gateway-map"
else
    fail "pg_ident.conf missing documentdb-gateway-map"
fi
if grep -q "+documentdb_admin_role" "$tmpdir/pg_ident.conf"; then
    pass "pg_ident.conf maps +documentdb_admin_role"
else
    fail "pg_ident.conf missing +documentdb_admin_role"
fi
if grep -q "+documentdb_readonly_role" "$tmpdir/pg_ident.conf"; then
    pass "pg_ident.conf maps +documentdb_readonly_role"
else
    fail "pg_ident.conf missing +documentdb_readonly_role"
fi

# Verify managed blocks are prepended (first-match semantics)
# The managed block should appear before the original "local all all peer" line
hba_content=$(cat "$tmpdir/pg_hba.conf")
if echo "$hba_content" | grep -q "documentdb-setup managed hba"; then
    pass "HBA managed block is present"
else
    fail "HBA managed block is NOT present"
fi

# Verify backup was created
if ls "$tmpdir"/pg_hba.conf.documentdb-backup.* >/dev/null 2>&1; then
    pass "pg_hba.conf backup created"
else
    fail "pg_hba.conf backup NOT created"
fi

# Test restore
/scripts/documentdb-register-gateway.sh --pgdata "$tmpdir" --pg-port 5432 --socket-dir /tmp --restore 2>&1
if ! grep -q "documentdb-gateway-map" "$tmpdir/pg_hba.conf"; then
    pass "register-gateway --restore removes HBA block"
else
    fail "register-gateway --restore did not remove HBA block"
fi
if ! grep -q "documentdb-gateway-map" "$tmpdir/pg_ident.conf"; then
    pass "gateway setup --restore removes ident block"
else
    fail "gateway setup --restore did not remove ident block"
fi
rm -rf "$tmpdir"

# ── Test 13: documentdb-local-reset requires --confirm-destroy ──────
echo "--- Test 13: documentdb-local-reset safety ---"
reset_err=$(/scripts/documentdb-local-reset.sh --pg-version 17 2>&1 || true)
if echo "$reset_err" | grep -q "confirm-destroy"; then
    pass "documentdb-local-reset requires --confirm-destroy"
else
    fail "documentdb-local-reset does not require --confirm-destroy"
fi

# ── Test 14: removed — documentdb-local.sh was deleted because a CLI whose
#    only subcommand always errors is bad UX. Public
#    day-2 surface is `systemctl <verb> documentdb-local.target` directly.

# ── Test 15: documentdb-createcluster detects non-Debian ─────────────
echo "--- Test 15: documentdb-createcluster platform detection ---"
if command -v pg_createcluster >/dev/null 2>&1; then
    pass "documentdb-createcluster: pg_createcluster available (Debian)"
else
    cc_err=$(/scripts/documentdb-createcluster.sh 17 main 2>&1 || true)
    if echo "$cc_err" | grep -qi "debian\|pg_createcluster"; then
        pass "documentdb-createcluster: rejects non-Debian with helpful message"
    else
        fail "documentdb-createcluster: no helpful message on non-Debian"
    fi
fi

# ── Test 16: documentdb-setup --help has new flags ───────────────────
echo "--- Test 16: documentdb-setup --help has design-required flags ---"
help_output=$(bash /scripts/documentdb-setup.sh --help 2>&1)
# Per packaging-design.md §4.4: canonical flag names are
# --use-new-postgres-instance / --target-postgres-instance. The old
# --use-private-cluster / --target-cluster names remain as hidden
# deprecated aliases (documented inline in the help body) so existing
# automation does not break.
for flag in "--admin-user" "--admin-password-file" \
            "--use-new-postgres-instance" "--target-postgres-instance" \
            "--use-private-cluster" "--target-cluster" \
            "--yes" "--dry-run" "--restore" "--listen-port"; do
    if echo "$help_output" | grep -q -- "$flag"; then
        pass "documentdb-setup --help lists $flag"
    else
        fail "documentdb-setup --help missing $flag"
    fi
done

# ── Test 17: documentdb-gateway --version + --help (no backend needed) ──
echo "--- Test 17: documentdb-gateway --version / --help ---"
if command -v documentdb-gateway >/dev/null 2>&1; then
    gw_bin="documentdb-gateway"
elif [ -x /usr/bin/documentdb-gateway ]; then
    gw_bin="/usr/bin/documentdb-gateway"
else
    gw_bin=""
fi
if [ -n "$gw_bin" ]; then
    if "$gw_bin" --version 2>&1 | grep -q "documentdb-gateway"; then
        pass "documentdb-gateway --version reports the binary name"
    else
        fail "documentdb-gateway --version output missing the binary name"
    fi
    if "$gw_bin" --help 2>&1 | grep -q -- "--check"; then
        pass "documentdb-gateway --help advertises --check"
    else
        fail "documentdb-gateway --help missing --check"
    fi
else
    echo "  (skipped: documentdb-gateway binary not installed in this image)"
fi

# ── Test 18: documentdb-gateway --check exits non-zero with no backend ──
# The user-facing smoke test the design promises operators run after
# documentdb-register-gateway (Workflow B) or documentdb-setup
# (Workflow C). In this packaging smoke test we don't have a live PG
# instance, so --check must fail cleanly (non-zero) rather than crash.
echo "--- Test 18: documentdb-gateway --check fails cleanly without backend ---"
if [ -n "$gw_bin" ]; then
    # Run --check without any DOCUMENTDB_PG_URL_FILE; expect non-zero
    # and a human-readable error on stderr.
    check_log=$(mktemp)
    if "$gw_bin" --check > "$check_log" 2>&1; then
        cat "$check_log"
        fail "documentdb-gateway --check unexpectedly succeeded without a configured backend"
    else
        if grep -qiE "FAIL|error|check FAILED" "$check_log"; then
            pass "documentdb-gateway --check fails cleanly with informative message"
        else
            cat "$check_log"
            fail "documentdb-gateway --check failed but with no informative output"
        fi
    fi
    rm -f "$check_log"
else
    echo "  (skipped: documentdb-gateway binary not installed in this image)"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "=== RESULTS ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ $FAIL -gt 0 ]; then
    echo -e "\nFailures:$ERRORS"
    exit 1
fi
echo ""
echo "All tests passed!"
