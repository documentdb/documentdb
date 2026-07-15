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

To build gateway packages, use the `build_gateway_packages.sh` script. This script supports the same OS and PostgreSQL version options as the main package builder.

For example, to build a gateway package for Debian 12 and PostgreSQL 16, run:

```sh
./packaging/gateway/build_gateway_packages.sh --os deb12 --pg 16 --version 0.114.0
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

The resulting gateway packages will be placed in the output directory (default: `packaging`). You can change the output location with the `--output-dir` option.

### Gateway package test coverage

Pass `--test-clean-install` to build the package, clean-install it in a fresh
container, and run an install smoke:

```sh
./packaging/gateway/build_gateway_packages.sh --os rhel8 --pg 17 --version 0.114.0 --test-clean-install
```

| Family | Targets | What the clean-install test does |
|--------|---------|----------------------------------|
| DEB | deb11 / deb12 / deb13 / ubuntu22.04 / ubuntu24.04 | Installs the extension + gateway packages on a real PostgreSQL, starts the service, and exercises the wire protocol end to end (`packaging/gateway/test/Dockerfile_deb_gateway_test`). |
| RPM | rhel8 / rhel9 | Clean-installs the gateway RPM and runs a root-shell install smoke (`packaging/gateway/test/Dockerfile_rpm_gateway_test`) asserting the system user, file layout, and the wrapper's privilege-drop path (`documentdb-gateway --version` / `--check` as root) — the path that is sensitive to the EL8 `runuser` differences. |

Both the DEB and RPM gateway build/test paths are wired into `build_gateway_packages.sh`.
