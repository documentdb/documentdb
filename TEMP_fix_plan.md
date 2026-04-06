# Gateway Packaging: Fix Plan for Suggestions 1 & 2

## Background

Branch `gateway-packages` overhauled gateway packaging (DEB + RPM + Docker images).
Two gaps were identified:

1. **Suggestion 1 (partially package-driven image):** The Docker image installs the
   gateway `.deb`, but still COPYs `SetupConfiguration.json` from the repo and symlinks
   the binary into legacy paths because startup scripts hardcode
   `/home/documentdb/gateway/pg_documentdb_gw/...` paths.

2. **Suggestion 2 (DEB missing user creation):** RPM spec creates `documentdb`
   user/group in `%pre`, but the DEB package has no maintainer scripts. The systemd unit
   runs as `User=documentdb` but bare-metal installs would fail. Additionally, the
   systemd unit lacks `WorkingDirectory`, so TLS cert auto-generation writes to `/`
   (unwritable).

---

## Part A: Fix bare-metal systemd + user creation (Suggestion 2)

### A1. Fix systemd unit — `pg_documentdb_gw/documentdb_gateway/documentdb-gateway.service`

Add `WorkingDirectory=/var/lib/documentdb` so the gateway binary has a writable CWD for
auto-generated TLS certs (`./pkey.pem`, `./cert.pem`).

**Current:**
```ini
[Service]
Type=simple
User=documentdb
Group=documentdb
ExecStart=/usr/bin/documentdb_gateway /etc/documentdb/SetupConfiguration.json
```

**Target:**
```ini
[Service]
Type=simple
User=documentdb
Group=documentdb
WorkingDirectory=/var/lib/documentdb
ExecStart=/usr/bin/documentdb_gateway /etc/documentdb/SetupConfiguration.json
```

### A2. Add DEB maintainer scripts — new file + Cargo.toml update

Create `pg_documentdb_gw/documentdb_gateway/maintainer-scripts/preinst`:

```bash
#!/bin/sh
set -e

# Create documentdb system user/group (idempotent)
if ! getent group documentdb >/dev/null; then
    groupadd -r documentdb
fi
if ! getent passwd documentdb >/dev/null; then
    useradd -r -g documentdb -d /var/lib/documentdb -s /usr/sbin/nologin \
        -c "DocumentDB Gateway" documentdb
fi

# Ensure working directory exists and is owned by the service user
mkdir -p /var/lib/documentdb
chown documentdb:documentdb /var/lib/documentdb

#DEBHELPER#
```

**IMPORTANT:** The `#DEBHELPER#` token is required by cargo-deb if `systemd-units` is
ever enabled. Include it for forward compatibility.

Update `pg_documentdb_gw/documentdb_gateway/Cargo.toml`:

```toml
[package.metadata.deb]
name = "documentdb_gateway"
maintainer = "documentdb-packaging-maintainers@microsoft.com"
depends = []
maintainer-scripts = "maintainer-scripts/"
assets = [
 ["target/release-with-symbols/documentdb_gateway", "usr/bin/", "755"],
 ["../SetupConfiguration.json", "etc/documentdb/", "644"],
 ["documentdb-gateway.service", "lib/systemd/system/", "644"],
]
```

**NOTE:** The key name is `maintainer-scripts` (hyphen, not underscore).

### A3. Update RPM spec `%pre` — `packaging/rpm/spec/documentdb_gateway.spec`

Add `/var/lib/documentdb` creation to match DEB behavior:

**Current:**
```spec
%pre
getent group documentdb >/dev/null || groupadd -r documentdb
getent passwd documentdb >/dev/null || useradd -r -g documentdb -d /var/lib/documentdb -s /sbin/nologin -c "DocumentDB Gateway" documentdb
exit 0
```

**Target:**
```spec
%pre
getent group documentdb >/dev/null || groupadd -r documentdb
getent passwd documentdb >/dev/null || useradd -r -g documentdb -d /var/lib/documentdb -s /sbin/nologin -c "DocumentDB Gateway" documentdb
mkdir -p /var/lib/documentdb
chown documentdb:documentdb /var/lib/documentdb
exit 0
```

### A4. Fix Docker user creation conflict

**Problem:** Both `Dockerfile_gateway` (line 63) and `Dockerfile_deb_gateway_test`
(line 54) do:
```dockerfile
RUN useradd -ms /bin/bash documentdb -G sudo
```
This runs AFTER `dpkg -i` of the gateway package. If the DEB `preinst` now creates
the `documentdb` system user first, this `useradd` will FAIL because user already exists.

**Fix:** Change `useradd` to `usermod` when user already exists. Replace in both files:

```dockerfile
# Create or adapt documentdb user for interactive Docker use.
# The gateway .deb preinst may have already created a system user;
# ensure it has a login shell, home dir, and sudo access.
RUN if id documentdb >/dev/null 2>&1; then \
        usermod -m -d /home/documentdb -s /bin/bash -aG sudo documentdb; \
    else \
        useradd -ms /bin/bash documentdb -G sudo; \
    fi
```

**Files affected:**
- `.github/containers/Build-Ubuntu/Dockerfile_gateway` (line 63)
- `packaging/test_packages/deb/Dockerfile_deb_gateway_test` (line 54)

The RPM build Dockerfiles (`Dockerfile-gateway-rhel8/9`) create the user BEFORE
building, so they are unaffected (user exists before any RPM is installed).

---

## Part B: Eliminate legacy path bridge in Docker image (Suggestion 1)

### B1. Update `scripts/build_and_start_gateway.sh`

**Current behavior (lines 129-135):**
```bash
cd $scriptDir/../pg_documentdb_gw/
if [ -z "$configFile" ]; then
    ./target/release-with-symbols/documentdb_gateway
else
    ./target/release-with-symbols/documentdb_gateway "$configFile"
fi &
```

**Target behavior:**
```bash
# Prefer source-tree binary (dev mode), fall back to package-installed binary.
# Source-tree first avoids accidentally running a stale packaged binary during dev.
gateway_bin="$scriptDir/../pg_documentdb_gw/target/release-with-symbols/documentdb_gateway"
if [ ! -x "$gateway_bin" ] && [ -x "/usr/bin/documentdb_gateway" ]; then
    gateway_bin="/usr/bin/documentdb_gateway"
fi

# Set CWD for TLS cert generation.
# When using source-tree binary, CWD is the pg_documentdb_gw dir (existing behavior).
# When using packaged binary, CWD is the directory containing the config file.
if [ "$gateway_bin" = "/usr/bin/documentdb_gateway" ] && [ -n "$configFile" ]; then
    cd "$(dirname "$configFile")"
else
    cd "$scriptDir/../pg_documentdb_gw/"
fi

if [ -z "$configFile" ]; then
    "$gateway_bin"
else
    "$gateway_bin" "$configFile"
fi &
```

**Key design decisions:**
- Source-tree binary takes precedence over package binary. This prevents devs with an
  old package installed from accidentally running the wrong binary.
- CWD is set explicitly in both modes so TLS certs land in a predictable place.

### B2. Update `scripts/emulator_entrypoint.sh`

**Current behavior (lines 393-395):**
```bash
mkdir -p /home/documentdb/gateway/pg_documentdb_gw/target
configFile="/home/documentdb/gateway/pg_documentdb_gw/target/SetupConfiguration_temp.json"
cp /home/documentdb/gateway/pg_documentdb_gw/SetupConfiguration.json $configFile
```

**Target behavior:**
```bash
mkdir -p /home/documentdb/gateway/pg_documentdb_gw/target
configFile="/home/documentdb/gateway/pg_documentdb_gw/target/SetupConfiguration_temp.json"

# Prefer package-installed config, fall back to legacy Docker layout
if [ -f /etc/documentdb/SetupConfiguration.json ]; then
    configSource="/etc/documentdb/SetupConfiguration.json"
else
    configSource="/home/documentdb/gateway/pg_documentdb_gw/SetupConfiguration.json"
fi
cp "$configSource" "$configFile"
```

**Note:** In the Docker image, BOTH paths will exist (the .deb installs to /etc/documentdb/
and the Dockerfile currently COPYs to the legacy path). After Part B3 removes the legacy
COPY, only the package path will exist, which is the desired end state.

### B3. Simplify `Dockerfile_gateway`

**Remove these lines** (currently around lines 110-115):
```dockerfile
# Symlink the gateway binary installed by the .deb to the path scripts expect
RUN sudo mkdir -p /home/documentdb/gateway/pg_documentdb_gw/target/release-with-symbols && \
    ln -s /usr/bin/documentdb_gateway /home/documentdb/gateway/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway

COPY pg_documentdb_gw/SetupConfiguration.json /home/documentdb/gateway/pg_documentdb_gw/SetupConfiguration.json
```

**Replace with** (just the gateway directory for scripts):
```dockerfile
RUN sudo mkdir -p /home/documentdb/gateway/pg_documentdb_gw/target
```

The `target` dir is still needed as a scratch space for the temp config file that
`emulator_entrypoint.sh` creates.

---

## File Change Summary

| File | Change |
|------|--------|
| `pg_documentdb_gw/documentdb_gateway/documentdb-gateway.service` | Add `WorkingDirectory=/var/lib/documentdb` |
| `pg_documentdb_gw/documentdb_gateway/maintainer-scripts/preinst` | **NEW** — user/group creation + working dir |
| `pg_documentdb_gw/documentdb_gateway/Cargo.toml` | Add `maintainer-scripts` key |
| `packaging/rpm/spec/documentdb_gateway.spec` | Add mkdir+chown in `%pre` |
| `.github/containers/Build-Ubuntu/Dockerfile_gateway` | Adapt useradd to handle existing user; remove symlink + config COPY |
| `packaging/test_packages/deb/Dockerfile_deb_gateway_test` | Adapt useradd to handle existing user |
| `scripts/build_and_start_gateway.sh` | Prefer source binary, fall back to /usr/bin/; explicit CWD |
| `scripts/emulator_entrypoint.sh` | Prefer /etc/documentdb/ config, fall back to legacy |

## Implementation Order

1. A1 + A2 + A3 (systemd fix + maintainer scripts) — independent, no deps
2. A4 (Docker useradd fix) — depends on A2 (preinst must exist for the conflict to arise)
3. B1 + B2 (script updates) — independent of Part A
4. B3 (Dockerfile cleanup) — depends on B1 + B2

## Test Plan

### Existing test infrastructure

| Test artifact | Type | What it does |
|---|---|---|
| `packaging/test_packages/deb/Dockerfile_deb_gateway_test` | Functional | Installs PG + extension DEB + gateway DEB, boots emulator, runs PyMongo CRUD |
| `packaging/test_packages/test-gateway-install-entrypoint.sh` | Harness | Creates venv, pip installs pymongo, starts emulator, waits for readiness, runs test_gateway.py |
| `packaging/test_packages/test_gateway.py` | CRUD test | Connects to gateway on :10260, creates collection, insert_one, insert_many, find, find_one |
| `packaging/test_packages/rhel-8/Dockerfile-rhel8-gateway-test` | Smoke | `rpm -i` then checks 3 files exist + binary is executable |
| `packaging/test_packages/rhel-9/Dockerfile-rhel9-gateway-test` | Smoke | Same as rhel-8 |

### Test changes needed for Part A

#### T-A1: Verify DEB preinst creates user and working dir

The existing DEB test (`Dockerfile_deb_gateway_test`) already runs `dpkg -i` which
executes the preinst. Add assertions AFTER the `dpkg -i` of the gateway DEB to verify:

In `packaging/test_packages/deb/Dockerfile_deb_gateway_test`, after the gateway
`dpkg -i` line, add:

```dockerfile
# Verify preinst side effects
RUN id documentdb && \
    test -d /var/lib/documentdb && \
    test "$(stat -c '%U:%G' /var/lib/documentdb)" = "documentdb:documentdb"
```

**NOTE:** This RUN must come BEFORE the existing `useradd` line. Since we're also
changing `useradd` to handle existing users (task A4), the order is:
1. `dpkg -i` gateway (preinst creates system user)
2. New RUN: verify preinst created user + dir
3. Adapted `useradd`/`usermod`: upgrades system user to interactive Docker user

#### T-A2: Verify RPM preinst creates working dir

In `packaging/test_packages/rhel-8/Dockerfile-rhel8-gateway-test` and
`rhel-9/Dockerfile-rhel9-gateway-test`, add to the CMD:

```bash
test -d /var/lib/documentdb && echo "OK: /var/lib/documentdb exists" && \
test "$(stat -c '%U:%G' /var/lib/documentdb)" = "documentdb:documentdb" && echo "OK: /var/lib/documentdb owned by documentdb" && \
```

#### T-A3: Verify systemd unit has WorkingDirectory

Add to both DEB and RPM test CMDs:

```bash
grep -q "WorkingDirectory=/var/lib/documentdb" /lib/systemd/system/documentdb-gateway.service && echo "OK: WorkingDirectory set"
```

(Use `/usr/lib/systemd/system/` for RPM path.)

### Test changes needed for Part B

#### T-B1: Verify Docker image works without legacy bridge

The existing DEB functional test (`Dockerfile_deb_gateway_test`) already boots the
emulator and runs PyMongo CRUD. After we remove the symlink and config COPY from the
main `Dockerfile_gateway`, this test proves the package-driven path works.

No new test file needed -- but the test Dockerfile itself must be updated:
- Remove any remaining symlink/legacy-path setup if present
- Ensure it uses the same entrypoint flow as the real image

#### T-B2: Verify script fallback to source-tree paths (dev mode)

This is tested by the existing dev workflow: anyone running
`scripts/build_and_start_gateway.sh` from a source checkout without packages installed
will exercise the source-tree binary path.

No automated test change needed, but document this in the PR description as a manual
verification step:

```
Manual verification: from a clean source checkout (no gateway packages installed):
  1. cargo build --profile=release-with-symbols in pg_documentdb_gw/
  2. scripts/start_oss_server.sh -g
  3. Verify gateway starts and accepts connections
```

### Full test execution commands

After all changes, run:

```bash
# DEB functional test (deb12, PG18)
./packaging/build_gateway_packages.sh --os deb12 --pg 18 --test-clean-install

# DEB functional test (deb11, PG17 -- exercises the deb11+PG17 gate)
./packaging/build_gateway_packages.sh --os deb11 --pg 17 --test-clean-install

# RPM smoke test (rhel9)
./packaging/build_gateway_packages.sh --os rhel9 --pg 18 --test-clean-install

# RPM smoke test (rhel8)
./packaging/build_gateway_packages.sh --os rhel8 --pg 18 --test-clean-install

# Docker image build (local, no push)
# Verifies Dockerfile_gateway works without symlink bridge
docker build \
  --build-arg BASE_IMAGE=debian:trixie-slim \
  --build-arg POSTGRES_VERSION=18 \
  --build-arg DEB_PACKAGE_REL_PATH=<ext-deb-path> \
  --build-arg GATEWAY_DEB_PACKAGE_REL_PATH=<gw-deb-path> \
  -f .github/containers/Build-Ubuntu/Dockerfile_gateway .
```

### Test matrix summary

| Test | Validates | Changed? |
|---|---|---|
| DEB --test-clean-install (deb12/PG18) | preinst user creation, WorkingDirectory in unit, full emulator boot + CRUD | Yes -- add preinst assertions, adapt useradd |
| RPM --test-clean-install (rhel9/PG18) | %pre user+dir creation, WorkingDirectory in unit, file assertions | Yes -- add dir+ownership + WorkingDirectory checks |
| RPM --test-clean-install (rhel8/PG18) | Same as rhel9 on RHEL8 | Yes -- same changes |
| Docker image build | Dockerfile_gateway builds without legacy bridge | Yes -- remove symlink+COPY |
| Dev mode (manual) | Scripts work from source tree without packages | No -- manual verification |
