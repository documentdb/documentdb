# To Build Your Own Packages With Docker

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

Supported PG versions: 16, 17, 18

## Building RPM Packages

For Red Hat-based distributions, you can build RPM packages:

```sh
./packaging/build_packages.sh --os rhel8 --pg 17
```

Supported RPM distributions:
- rhel8 (Red Hat Enterprise Linux 8 compatible)
- rhel9 (Red Hat Enterprise Linux 9 compatible)

Supported PG versions: 16, 17, 18

### RPM Build Prerequisites

[Optional] Before building RPM packages, you can validate your environment:

```sh
./packaging/validate_rpm_build.sh
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

Gateway packages are **PG-version-independent** — a single gateway package per OS/architecture works with any supported PostgreSQL version. The `--pg` flag selects the PostgreSQL version used in the build and test environment, but the resulting package has no PG-specific dependency. CI and release workflows build/test gateway packages on the latest supported PG version (currently 18), while `documentdb-local` images remain available for older PG versions for compatibility.

To build gateway packages, use the `build_gateway_packages.sh` script.

### Gateway DEB Packages

```sh
./packaging/build_gateway_packages.sh --os deb12 --pg 18
```

Supported DEB/Ubuntu distributions:
- deb11 — Debian 11 (bullseye)
- deb12 — Debian 12 (bookworm)
- deb13 — Debian 13 (trixie)
- ubuntu22.04 — Ubuntu 22.04 (jammy)
- ubuntu24.04 — Ubuntu 24.04 (noble)

Supported architectures: amd64, arm64

This produces 5 OS x 2 arch = **10 DEB packages**.

### Gateway RPM Packages

```sh
./packaging/build_gateway_packages.sh --os rhel8 --pg 18
./packaging/build_gateway_packages.sh --os rhel9 --pg 18 --test-clean-install
```

Supported RPM distributions:
- rhel8 (Red Hat Enterprise Linux 8 compatible)
- rhel9 (Red Hat Enterprise Linux 9 compatible)

Supported architectures: x86_64, aarch64

This produces 2 OS x 2 arch = **4 RPM packages**.

### Gateway Package Contents

Gateway packages install the following files:

- `/usr/bin/documentdb_gateway` — the gateway binary
- `/etc/documentdb/SetupConfiguration.json` — default configuration
- Systemd service unit:
  - DEB: `/lib/systemd/system/documentdb-gateway.service`
  - RPM: `/usr/lib/systemd/system/documentdb-gateway.service`

### Gateway Output

The resulting gateway packages will be placed in the output directory (default: `packaging`). You can change the output location with the `--output-dir` option.

## Using Existing Packages on a Local Machine

These steps assume you already have the extension and gateway packages for your OS, architecture, and PostgreSQL version, and that you are running from a repo checkout so the helper scripts under `scripts/` are available.

### Install the packages

Debian/Ubuntu:

```sh
sudo apt-get install -y \
  ./path/to/deb13-postgresql-18-documentdb_<version>_<arch>.deb \
  ./path/to/deb13-documentdb_gateway_<version>_<arch>.deb
```

RHEL:

```sh
sudo dnf install -y \
  ./path/to/rhel9-postgresql18-documentdb-<version>.<arch>.rpm \
  ./path/to/rhel9-documentdb-gateway-<version>.<arch>.rpm
```

If you are using PG16 or PG17 packages instead, use that version in the next step.

### Initialize PostgreSQL and Launch the Gateway

Run these commands from the repo root after the packages are installed:

```sh
export PG_VERSION_USED=18
./scripts/start_oss_server.sh -c -d "$HOME/.documentdb/data" -p 9712
./scripts/build_and_start_gateway.sh -u docdb_user -p Admin100 -P 9712
```

Keep `build_and_start_gateway.sh` running and open a second terminal for `mongosh`.

When the gateway package is installed, `build_and_start_gateway.sh` automatically uses:

- `/usr/bin/documentdb_gateway`
- `/etc/documentdb/SetupConfiguration.json`

### Connect with Mongosh

```sh
mongosh localhost:10260 -u docdb_user -p Admin100 \
  --authenticationMechanism SCRAM-SHA-256 \
  --tls \
  --tlsAllowInvalidCertificates
```

## Docker Images

Docker images (`documentdb-local`) install prebuilt extension and gateway `.deb` packages instead of compiling from source. Images are based on Debian 13 (trixie) and are built for each supported PG version and architecture.

## Complete Artifact Matrix

| Family | OS | PG | Arch | Count |
|--------|----|----|------|-------|
| Extension DEB | deb11, deb12, deb13, ubuntu22.04, ubuntu24.04 | 16, 17, 18 | amd64, arm64 | 28* |
| Extension RPM | rhel8, rhel9 | 16, 17, 18 | x86_64, aarch64 | 12 |
| Gateway DEB | deb11, deb12, deb13, ubuntu22.04, ubuntu24.04 | N/A | amd64, arm64 | 10 |
| Gateway RPM | rhel8, rhel9 | N/A | x86_64, aarch64 | 4 |
| Docker images | deb13 | 16, 17, 18 | amd64, arm64 | 6 |

*deb11 + PG18 is excluded because `postgresql-18-postgis-3` is not available in the PGDG repo for Debian Bullseye (EOL Aug 2024). deb11 extension packages are built for PG16 and PG17 only.
