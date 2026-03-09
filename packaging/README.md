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

Supported PG versions: 15, 16, 17

## Building RPM Packages

For Red Hat-based distributions, you can build RPM packages:

```sh
./packaging/build_packages.sh --os rhel8 --pg 17
```

Supported RPM distributions:
- rhel8 (Red Hat Enterprise Linux 8 compatible)
- rhel9 (Red Hat Enterprise Linux 9 compatible)

Supported PG versions: 15, 16, 17

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
./packaging/build_gateway_packages.sh --os deb12 --pg 16
```

Supported DEB/Ubuntu distributions:
- deb11 — Debian 11 (bullseye)
- deb12 — Debian 12 (bookworm)
- deb13 — Debian 13 (trixie)
- ubuntu22.04 — Ubuntu 22.04 (jammy)
- ubuntu24.04 — Ubuntu 24.04 (noble)

Supported PG versions: 15, 16, 17, 18

The resulting gateway packages will be placed in the output directory (default: `packaging`). You can change the output location with the `--output-dir` option.

## Copr RPM Distribution

[Copr](https://copr.fedorainfracloud.org) provides hosted RPM builds for Fedora and EPEL. This section describes how to set up a Copr project that builds DocumentDB directly from the Git repository.

### Copr Project Setup

1. Go to <https://copr.fedorainfracloud.org> and create a new project (or use an existing one).
2. Under **Settings → Chroots**, enable:
   - `fedora-42-x86_64`
   - `epel-9-x86_64`
   - `epel-9-aarch64`
   > **Note:** PGDG does not publish aarch64 packages for Fedora, so Fedora is x86_64 only.
   > For aarch64 support, use the EPEL-9 chroots (RHEL 9 / Rocky 9 / Alma 9).
3. Under **Settings → External Repositories**, add the PGDG repos:

   **For Fedora chroots:**
   ```
   https://download.postgresql.org/pub/repos/yum/18/fedora/fedora-42-x86_64/
   ```

   **For EPEL-9 chroots:**
   ```
   https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-9-$basearch/
   ```
   > **Note:** The EPEL-9 repo URL uses `$basearch` which expands to `x86_64` or `aarch64`
   > depending on the build chroot.

### SCM Integration

Configure the package source in the Copr project:

| Setting    | Value |
|------------|-------|
| Source type | SCM |
| SCM type   | git |
| Clone URL  | `https://github.com/documentdb/documentdb` |
| SRPM build method | `make_srpm` |
| Spec file  | `packaging/rpm/spec/documentdb-copr.spec` |

The `.copr/Makefile` in the repository root handles SRPM generation automatically — Copr invokes `make srpm` and the Makefile takes care of the rest.

Optionally, configure a webhook in **Settings → Webhooks** to trigger automatic rebuilds on push.

### Packages Produced

| Package | Description |
|---------|-------------|
| `postgresql18-documentdb` | PostgreSQL 18 extensions (`documentdb_core`, `documentdb`, `documentdb_extended_rum`) |
| `documentdb-gateway` | MongoDB wire protocol gateway binary |
| `documentdb-server` | Meta-package that installs everything above |

### User Installation

Enable the Copr repo and install:

```sh
dnf copr enable <owner>/<project>
dnf install documentdb-server
```

Or install individual packages:

```sh
dnf install postgresql18-documentdb
dnf install documentdb-gateway
```

### Spec Files

| File | Purpose |
|------|---------|
| `packaging/rpm/spec/documentdb.spec` | Docker-based RPM build (existing) |
| `packaging/rpm/spec/documentdb-copr.spec` | Copr-compatible spec for Fedora builds |

### Testing Copr Builds Locally

Before pushing to Copr, you can test the SRPM build locally in a Fedora container:

```sh
./packaging/test_copr_srpm.sh
```

This requires Docker and replicates the Copr mock chroot environment. The resulting SRPM
is placed in the `packaging/` directory by default (override with `--output-dir`).