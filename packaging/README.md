# Building DocumentDB Packages With Docker

The OSS packaging contract mirrors the design in
`packaging/gateway/packaging-design.md`:

| Package | Role |
|---|---|
| `postgresql-N-documentdb` | The PostgreSQL extension for major N. File-only. |
| `documentdb-postgresql-tools` | Administrator helpers (`documentdb-tune`, `documentdb-createcluster`, `documentdb-register-gateway`, `documentdb-gateway-admin`). |
| `documentdb-gateway` | Wire-protocol translation runtime (binary + systemd unit). |
| `documentdb-common` | PG-agnostic shared payload owned once: `documentdb-setup`, `documentdb-local-reset`, the systemd template units (`documentdb-local@.target`, `documentdb-postgresql@.service`, `documentdb-gateway-local@.service`), the sysusers.d/tmpfiles.d drop-ins, helper scripts, and sample data. |
| `documentdb-N` (+ `documentdb` meta) | Per-major stand-alone package — pins PostgreSQL major N + its extension, depends on `documentdb-common` (and the gateway/tools it pulls in), and owns the per-major systemd instance lifecycle. |

The paved-road combination built and tested by CI is **Ubuntu 24.04 LTS +
PostgreSQL 18**. Other OS/PG combinations are exposed by the build scripts
below for community packagers and validation runs.

## User-facing install paths

The design (`packaging/gateway/packaging-design.md` §5) defines three
install paths, all served by the four packages above:

- **Workflow C — Full stand-alone install (recommended default):**
  `apt install documentdb && sudo documentdb-setup --admin-user admin`.
  The meta package pulls everything in; `documentdb-setup` runs the
  greenfield or brownfield setup wizard with backup-and-rollback
  safety around every PostgreSQL-side change, and enables
  `documentdb-local.target` itself on success (pass `--no-enable` to
  defer that). There is no separate `systemctl enable --now` step.

- **Workflow A — Extension only into a managed PostgreSQL instance
  (advanced):** `apt install postgresql-18-documentdb documentdb-postgresql-tools`
  then `sudo documentdb-tune --pg-version 18 --cluster main --yes`.
  No gateway runtime, no wire-protocol endpoint — useful for ops /
  migration tooling that talks SQL directly.

- **Workflow B — Extension + gateway with BYO local PostgreSQL
  (advanced):** Workflow A plus `apt install documentdb-gateway` and
  `sudo documentdb-register-gateway --target-postgres-instance 18/main
  --admin-user admin --admin-password-file <file> --yes`. Suitable when
  the operator wants to own the PostgreSQL lifecycle themselves but
  still expose the wire protocol via a packaged gateway service.

See the design doc for the full prerequisite and rollback semantics of
each workflow.

> **RHEL / Rocky / AlmaLinux prerequisite (before any `dnf install`).**
> The DocumentDB RPMs depend on PGDG-provided PostgreSQL extension packages
> (`pgvector_N`, `pg_cron_N`, `postgis36_N`), which live in the PGDG, EPEL, and
> CodeReady Builder (CRB) repositories. On a stock RHEL-family host `dnf install
> documentdb` fails dependency resolution until those repos are enabled. Enable
> them once (adjust the EL major/arch for your host; use `powertools` instead of
> `crb` on EL8):
>
> ```bash
> sudo dnf install -y dnf-plugins-core
> sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
> sudo dnf install -y epel-release
> sudo dnf config-manager --set-enabled crb
> sudo dnf -qy module disable postgresql
> ```
>
> On EL8 replace `EL-9` with `EL-8` in the PGDG URL and use `--set-enabled
> powertools` instead of `crb`; on arm64 replace `x86_64` with `aarch64`.
> Then the RHEL install commands mirror the Debian workflows above with `dnf`
> (for example `sudo dnf install documentdb` for Workflow C). This guidance is
> also embedded in the `%description` of the extension and meta RPMs, so it is
> visible via `dnf info` before install.

> **Multi-major side-by-side on Debian/Ubuntu (advanced capability).**
> The major-agnostic files (`documentdb-setup`, the `@`-templated units, helper
> scripts, sample data, …) are owned once by the `documentdb-common` package,
> which every `documentdb-N` depends on. Because the per-major packages ship
> none of these files themselves, multiple majors co-install cleanly and
> removing one major never removes shared files a surviving major needs — the
> shared payload is removed only when the last `documentdb-N` is gone and
> `documentdb-common` is autoremoved. Each stand-alone still owns exactly one
> underlying PostgreSQL instance and one gateway, so side-by-side installs
> require the administrator to assign distinct public gateway ports for the
> non-default instances (manual configuration, not automatic allocation).

## Building Debian/Ubuntu Packages

Run `./packaging/build_packages.sh -h` and follow the instructions.
E.g. to build for Debian 12 and PostgreSQL 16, run:

```sh
./packaging/build_packages.sh --os deb12 --pg 16
```

Supported DEB/Ubuntu distributions:
- deb11 — Debian 11 (bullseye)
- deb12 — Debian 12 (bookworm)
- deb13 — Debian 13 (trixie)
- ubuntu22.04 — Ubuntu 22.04 (jammy)
- ubuntu24.04 — Ubuntu 24.04 (noble)

Supported PG versions: 15, 16, 17, 18

## Building RPM Packages

For Red Hat-based distributions, you can build RPM packages:

```sh
./packaging/build_packages.sh --os rhel8 --pg 17
```

Supported RPM distributions:
- rhel8 (Red Hat Enterprise Linux 8 compatible)
- rhel9 (Red Hat Enterprise Linux 9 compatible)

Supported PG versions: 15, 16, 17, 18

### RPM Build Prerequisites

[Optional] Before building RPM packages, you can validate your environment:

```sh
./packaging/rpm/validate_rpm_build.sh
```

This script checks:
- Docker installation and availability
- Network connectivity for package repositories
- Access to required base images

### Example RPM Build Commands

```sh
# Build for RHEL 9 with PostgreSQL 16
./packaging/build_packages.sh --os rhel9 --pg 16

# Build with testing enabled
./packaging/build_packages.sh --os rhel8 --pg 17 --test-clean-install
```

## Output

Packages can be found at the `packages` directory by default, but it can be configured with the `--output-dir` option.

**Note:** The packages do not include pg_documentdb_distributed in the `internal` directory.


## Building Gateway Packages

To build gateway packages, use the `build_gateway_packages.sh` script. This script supports the same OS and PostgreSQL version options as the main package builder.

For example, to build a gateway package for Debian 12 and PostgreSQL 18, run:

```sh
./packaging/gateway/build_gateway_packages.sh --os deb12 --pg 18 --version 0.114.0
```

To build a gateway RPM package for RHEL 9, run:

```sh
./packaging/gateway/build_gateway_packages.sh --os rhel9 --pg 18 --version 0.114.0
```

The `--version` argument is required: it pins the package version and the gateway
binary's reported version, so the build fails fast if it is omitted.

Supported DEB/Ubuntu distributions:
- deb11 — Debian 11 (bullseye)
- deb12 — Debian 12 (bookworm)
- deb13 — Debian 13 (trixie)
- ubuntu22.04 — Ubuntu 22.04 (jammy)
- ubuntu24.04 — Ubuntu 24.04 (noble)

Supported RPM distributions:
- rhel8 (Red Hat Enterprise Linux 8 compatible)
- rhel9 (Red Hat Enterprise Linux 9 compatible)

Supported PG versions: 15, 16, 17, 18

> **Gateway PostgreSQL 16+ requirement.** The gateway binary is
> PostgreSQL-version-agnostic and builds for any version above, but the
> package-managed local gateway registration — `documentdb-register-gateway` and
> the `documentdb-setup` stand-alone wizard — requires **PostgreSQL 16 or newer**.
> The gateway authenticates each client's data-pool connection *as that client's
> role* over the local socket with an empty password, relying on `pg_ident.conf`
> group membership (`+role`) to map the gateway OS user to the member role — a
> feature PostgreSQL introduced in 16, with no password-based fallback for
> SCRAM-authenticated users. `documentdb-register-gateway` and `documentdb-setup`
> therefore reject PostgreSQL 15 (its `--restore` path still works). PostgreSQL 15
> remains fully supported for **extension-only** use (`CREATE EXTENSION
> documentdb`). The legacy `documentdb-local` container image uses a separate
> container-local trust model and is unaffected.

The resulting gateway packages will be placed in the output directory (default: `packaging`). You can change the output location with the `--output-dir` option.

### Gateway package test coverage

Pass `--test-clean-install` to build the package, clean-install it in a fresh
container, and run an install smoke:

```sh
./packaging/gateway/build_gateway_packages.sh --os rhel8 --pg 17 --version 0.114.0 --test-clean-install
```

> **Host build tooling:** `--test-clean-install` assembles the stand-alone
> "extras" (`documentdb-postgresql-tools`, `documentdb-common`, `documentdb-N`,
> and the `documentdb` meta package) **on the host** — DEB via `dpkg-deb`, RPM
> via `rpmbuild` (plus `systemd-rpm-macros` on RHEL/Fedora) — while only the
> extension and gateway packages are built inside Docker. Install the matching
> host tool first (`sudo apt install dpkg` or `sudo apt install rpm` on
> Debian/Ubuntu, `brew install dpkg` on macOS) or the build fails when it
> reaches the extras step.
> `build_extra_packages.sh --type {deb|rpm} --check-build-deps-only` preflights
> this for you and fails early with an actionable message. The per-package DEB
> builders avoid GNU-only constructs (`sed -i`, `date -d`) so they also work
> under BSD/macOS Bash and minimal container shells. The overall local smoke,
> however, targets a Linux host — the build relies on a Bash 4+ /
> GNU-coreutils userland and the RPM extras need `rpmbuild` — so on macOS run it
> inside a Linux container or WSL rather than natively.

| Family | Targets | What the clean-install test does |
|--------|---------|----------------------------------|
| DEB | deb11 / deb12 / deb13 / ubuntu22.04 / ubuntu24.04 | Installs the extension + gateway packages on a real PostgreSQL, starts the service, and exercises the wire protocol end to end (`packaging/gateway/test/Dockerfile_deb_gateway_test`). |
| RPM | rhel8 / rhel9 | Clean-installs all four Track 1 RPMs and runs the full RPM E2E suite (`packaging/test_packages/Dockerfile-rhel-gateway-test` → `test-gateway-install-entrypoint-rpm.sh`): package-boundary/manifest checks, `%preun`/`%posttrans` scriptlets against a fake `systemctl`, static unit verification, `documentdb-setup` greenfield provisioning, ident-map/peer-auth checks, wire-protocol CRUD, `--load-sample-data`, and `rpm -e` cleanup. This also exercises the wrapper's privilege-drop path as root, which is sensitive to the EL8 `runuser` differences. |

Both the DEB and RPM gateway build/test paths are wired into `build_gateway_packages.sh`.

Gateway runtime packages install the gateway binary, packaged configuration, and its systemd unit. (The `documentdb-setup` wizard, the helper scripts, and the sample data used by stand-alone package installs are shipped by `documentdb-common`, pulled in by `documentdb-N`.) They do not choose a PostgreSQL major for you. Install `documentdb-gateway` together with the DocumentDB extension package for the PostgreSQL major you want (for example, `apt install documentdb-gateway postgresql-18-documentdb` on Debian/Ubuntu or `dnf install documentdb-gateway postgresql18-documentdb` on RHEL-family systems). If more than one PostgreSQL major is installed, pass `--pg-version` to `documentdb-setup` to pin the version you want. Packaged sample data is optional: use `documentdb-setup --load-sample-data` to enable it, or `--skip-init-data` to disable it explicitly in scripts. `--load-sample-data` requires `mongosh` to be installed. When `documentdb-setup` provisions a self-managed PostgreSQL instance, it uses the per-major private Unix socket directory `/run/documentdb-local/N/postgresql` and persists the startup state so packaged installs restart cleanly after a reboot.

## Building the PostgreSQL Administrator Tools Package

The `documentdb-postgresql-tools` package ships `documentdb-tune`,
`documentdb-createcluster`, `documentdb-register-gateway`, and
`documentdb-gateway-admin`. These are administrator helpers that mutate
PostgreSQL state (postgresql.conf, pg_hba.conf, pg_ident.conf, gateway
role) and are required by both Workflow B (BYO local PG + gateway) and
Workflow C (stand-alone). The package only Suggests the gateway and
extension runtime packages — it can be installed first for preview /
dry-run use.

To build the DEB:

```sh
./packaging/postgresql-tools/build-postgresql-tools-deb.sh --version 0.114.0 --output-dir packaging
```

`documentdb-register-gateway` checks at runtime that the
`documentdb-gateway` OS user exists (created by installing the
`documentdb-gateway` runtime package) and exits with a clear prerequisite
error otherwise. This keeps the boundary explicit: tools mutate
PostgreSQL on behalf of an already-installed gateway.
