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

### Strategy: Fedora (Native PG) + EL9 (PGDG)

A single spec file (`documentdb-copr.spec`) supports two platforms:

| Platform | PG Source | Extensions | Vendored |
|----------|-----------|------------|----------|
| **Fedora 42/43/Rawhide** | Native distro PG (F42=PG16, F43/Rawhide=PG18) | pgvector, PostGIS from Fedora repos | pg_cron (not in Fedora repos) |
| **EPEL 9** | PGDG PG 18 | All from PGDG (pgvector, pg_cron, PostGIS) | pcre2-static (CRB not in mock) |

The spec uses `%if 0%{?fedora}` conditionals to choose the right package names, paths, and vendored components for each platform.

### Copr Project Setup

1. Go to <https://copr.fedorainfracloud.org> and create a new project (or use an existing one).
2. Under **Settings → Chroots**, enable:
   - `fedora-42-x86_64`, `fedora-42-aarch64`
   - `fedora-43-x86_64`, `fedora-43-aarch64`
   - `fedora-rawhide-x86_64`, `fedora-rawhide-aarch64`
   - `epel-9-x86_64`, `epel-9-aarch64`
3. Under **Settings → External Repositories**:

   **For Fedora chroots:** No external repos needed — all dependencies come from native Fedora repos.

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

| Package | Platform | Description |
|---------|----------|-------------|
| `documentdb` | Fedora | PostgreSQL extensions + bundled pg_cron |
| `postgresql18-documentdb` | EL9 | PostgreSQL 18 extensions (PGDG) |
| `documentdb-gateway` | Both | MongoDB wire protocol gateway binary |
| `documentdb-server` | Both | Meta-package that installs everything above |

### User Installation

**Fedora (no external repos needed):**

```sh
dnf copr enable <owner>/<project>
dnf install documentdb-server
```

> **Fedora 42 (PG 16) Note:** After installing, add this line to `postgresql.conf`
> before starting PostgreSQL:
> ```
> documentdb.rum_library_load_option = 'require_documentdb_extended_rum'
> ```
> PG 16's default tries to load a standalone `rum.so` which is not packaged in Fedora.
> This setting uses the bundled `pg_documentdb_extended_rum_core` instead.
> Fedora 43+ ships PG 18 where this is already the default — no action needed.

**EL9 (requires PGDG repo):**

```sh
# First, add the PGDG repo
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpm/EL-9-$(arch)-pgdg-redhat-repo-latest.noarch.rpm

# Then install from Copr
dnf copr enable <owner>/<project>
dnf install documentdb-server
```

### Spec Files

| File | Purpose |
|------|---------|
| `packaging/rpm/spec/documentdb.spec` | Docker-based RPM build (existing) |
| `packaging/rpm/spec/documentdb-copr.spec` | Copr-compatible spec for Fedora and EPEL builds |

### Vendored Build Dependencies

The Copr spec vendors the following libraries from source:

| Library | Platform | Reason |
|---------|----------|--------|
| libbson (mongo-c-driver) | Both | Statically linked; not available as a system package |
| Intel Decimal Math Library | Both | Not packaged in any distro |
| pcre2 (static) | EL9 only | `pcre2-static` is not available on EL9 without enabling the CRB repo |
| pg_cron | Fedora only | Not packaged in Fedora native repos (PostgreSQL License, safe to vendor) |

### Testing Copr Builds Locally

Test with Docker using the provided Dockerfiles:

```sh
# Fedora (native PG, native arch — works on both x86_64 and aarch64)
docker build -f Dockerfile.fedora-test .

# EL9 (PGDG PG 18, native arch)
docker build -f Dockerfile.el9-test .
```